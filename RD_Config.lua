--[[
    RD_Config.lua
    PROPÓSITO: Persistencia (SavedVariables) y acceso por path a la configuración.
    API PÚBLICA:
        - RD.config:Load(), RD.config:Save(), RD.config:ResetToDefaults()
        - RD.config:Get(key, default), RD.config:Set(key, value)
    EVENTOS: CONFIG_LOADED, CONFIG_CHANGED(key, value), CONFIG_RESET
]]

local addonName, private = ...
local RD = _G.RaidDominion or {}
_G.RaidDominion = RD

local Config = {}

local db          -- Referencia a RaidDominionDB
local DEFAULTS    -- Referencia a RD.constants.DEFAULT_CONFIG
local loaded = false  -- Load() es idempotente (una sola vez por sesión)

-- Copia profunda de una tabla
local function DeepCopy(orig)
    local origType = type(orig)
    if origType ~= "table" then return orig end
    local copy = {}
    for k, v in next, orig, nil do
        copy[DeepCopy(k)] = DeepCopy(v)
    end
    return setmetatable(copy, DeepCopy(getmetatable(orig)))
end

-- Merge profundo: src dentro de dest, preservando valores existentes en dest
local function MergeTable(dest, src)
    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dest[k]) ~= "table" then dest[k] = {} end
            MergeTable(dest[k], v)
        else
            if dest[k] == nil then
                dest[k] = v
            end
        end
    end
end

-- Limpia/actualiza la DB con las migraciones de dominio (viven en
-- RD_Utils_Migrations.lua para que la capa de persistencia no conozca reglas
-- de negocio): canal legacy, siembra de listas, booleanos 1/0, dedup de
-- reglas, sanciones legacy y asignaciones huérfanas.
local function RunMigrations(db, defaults)
    if RD.utils and RD.utils.migrations and RD.utils.migrations.Run then
        RD.utils.migrations:Run(db, defaults)
    end
end

-- Carga la DB y fusiona con los valores por defecto. Idempotente: las
-- migraciones solo corren una vez por sesión (RD_Init la invoca en ADDON_LOADED
-- y de nuevo en PLAYER_LOGIN; la segunda llamada es un no-op).
function Config:Load()
    if loaded then return end

    DEFAULTS = (RD.constants and RD.constants.DEFAULT_CONFIG) or {}

    if not RaidDominionDB then
        RaidDominionDB = DeepCopy(DEFAULTS)
    else
        MergeTable(RaidDominionDB, DEFAULTS)
        RunMigrations(RaidDominionDB, DEFAULTS)
    end

    db = RaidDominionDB
    loaded = true

    if RD.events and RD.events.Publish then
        RD.events:Publish("CONFIG_LOADED", db)
    end
end

-- Caché del split de paths: claves con muchos Get/Set seguidos (p.ej.
-- "chat.channel" en cada envío de mensaje, "ui.menu.scale" en cada render)
-- parsearían el string con gmatch en cada llamada. Se cachea la lista de nodos
-- por clave (acotada como CleanName: al superar el tope se vacía y se rellena
-- con las claves en uso).
local PATH_CACHE_MAX = 128
local pathCache = {}
local pathCacheCount = 0

local function SplitKey(key)
    local cached = pathCache[key]
    if cached then return cached end
    cached = {}
    for node in string.gmatch(key, "[^.]+") do
        cached[#cached + 1] = node
    end
    pathCache[key] = cached
    pathCacheCount = pathCacheCount + 1
    if pathCacheCount > PATH_CACHE_MAX then
        pathCache = {}
        pathCacheCount = 0
    end
    return cached
end

-- Recorre db y DEFAULTS en paralelo (una sola pasada por clave). Devuelve
-- (container, last, dtype): container es la tabla que contiene la hoja, last
-- el nombre del último nodo y dtype el type() de la hoja en DEFAULTS (nil si
-- no existe). Con create=true crea los nodos intermedios faltantes y clobberea
-- los no-tabla (uso de Set); sin él, un path no navegable devuelve (nil, nil).
local function ResolveNode(key, create)
    local container = db
    local last = nil
    local dcur = DEFAULTS
    local nodes = SplitKey(key)
    for i = 1, #nodes do
        local node = nodes[i]
        if type(dcur) == "table" then
            dcur = dcur[node]
        else
            dcur = nil
        end
        if type(container) ~= "table" then
            return nil, nil, type(dcur)
        end
        if last ~= nil then
            local nextContainer = container[last]
            if type(nextContainer) ~= "table" then
                if not create then return nil, nil, type(dcur) end
                container[last] = {}
                nextContainer = container[last]
            end
            container = nextContainer
        end
        last = node
    end
    return container, last, type(dcur)
end

-- Obtiene un valor por path ("ui.menu.scale")
function Config:Get(key, default)
    if not db then return default end
    if not key then return db end

    local container, last, dtype = ResolveNode(key)
    if last == nil then return container or default end
    if container == nil then return default end
    local value = container[last]
    if value == nil then return default end
    -- Normaliza legacy 1/0 a booleano nativo cuando el default es booleano
    if type(value) == "number" and dtype == "boolean" then
        return value ~= 0
    end
    return value
end

-- Lote de escrituras: dentro de BeginBatch/EndBatch, Set NO publica
-- CONFIG_CHANGED por cada clave; al cerrar el lote se publica UNA vez por clave
-- distinta tocada (orden de primera escritura). Útil en sincronizaciones bulk
-- (config del líder, asignaciones) donde N+ Sets dispararían N eventos y
-- N re-renders en cadena. Fuera del lote el comportamiento es idéntico.
local batchDepth = 0
local batchList
local batchSeen

function Config:BeginBatch()
    batchDepth = batchDepth + 1
    if batchDepth == 1 then
        batchList = {}
        batchSeen = {}
    end
end

function Config:EndBatch()
    if batchDepth == 0 then return end
    batchDepth = batchDepth - 1
    if batchDepth > 0 then return end
    local list, seen = batchList, batchSeen
    batchList, batchSeen = nil, nil
    if RD.events and RD.events.Publish then
        for i = 1, #list do
            RD.events:Publish("CONFIG_CHANGED", list[i])
        end
    end
end

-- Establece un valor por path ("ui.menu.scale")
function Config:Set(key, value)
    if not db or not key then return end

    local container, last, dtype = ResolveNode(key, true)
    if last == nil then return end

    -- Normaliza el valor cuando la hoja es booleana: guarda SIEMPRE true/false
    -- (nunca 1/0 ni nil) para que el desmarque no borre la clave y MergeTable
    -- no la re-siembre con el default.
    if dtype == "boolean" then
        if value == nil then value = false end
        if type(value) == "number" then value = value ~= 0 end
        value = value and true or false
    end

    if container[last] == value then return end

    container[last] = value
    self:Save()

    if RD.events and RD.events.Publish then
        if batchDepth > 0 then
            if not batchSeen[key] then
                batchSeen[key] = true
                batchList[#batchList + 1] = key
            end
        else
            RD.events:Publish("CONFIG_CHANGED", key, value)
        end
    end
end

-- Restaura los valores por defecto
function Config:ResetToDefaults()
    RaidDominionDB = DeepCopy(DEFAULTS)
    db = RaidDominionDB
    if RD.events and RD.events.Publish then
        RD.events:Publish("CONFIG_RESET")
    end
end

-- Guarda (WoW guarda las SavedVariables automáticamente al salir/recargar)
function Config:Save()
end

RD.config = Config
return Config
