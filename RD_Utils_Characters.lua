--[[
    RD_Utils_Characters.lua
    PROPÓSITO: Detección y registro de los personajes de la cuenta. RaidDominionDB
              es una SavedVariables account-wide, así que TODOS los personajes de
              la cuenta comparten la misma configuración; este módulo registra
              cada personaje que inicia sesión (clave "Nombre-Reino") para que el
              addon sepa qué personajes comparten esa configuración.
    API PÚBLICA:
        - RD.utils.characters:RegisterCurrent()      -- registra/actualiza al personaje actual
        - RD.utils.characters:Get(key)               -- datos de un personaje ("Nombre-Reino")
        - RD.utils.characters:GetAll()               -- tabla completa db.characters
        - RD.utils.characters:GetSorted()            -- lista ordenada por lastSeen desc
        - RD.utils.characters:Count()                -- número de personajes detectados
        - RD.utils.characters:GetCurrentKey()        -- clave del personaje actual
    EVENTOS: publica CHARACTER_REGISTERED(key, info) tras registrar.
]]

local addonName, private = ...
local RD = _G.RaidDominion or {}
_G.RaidDominion = RD

local Characters = {}

local currentKey  -- "Nombre-Reino" del personaje actual (cacheado en login)

-- Clave única del personaje: Nombre-Reino (evita colisiones entre reinos)
local function BuildKey(name, realm)
    return tostring(name or "?") .. "-" .. tostring(realm or "?")
end

-- Asegura que exista el contenedor characters en la DB compartida
local function EnsureContainer()
    if type(RaidDominionDB) ~= "table" then return nil end
    if type(RaidDominionDB.characters) ~= "table" then
        RaidDominionDB.characters = {}
    end
    return RaidDominionDB.characters
end

-- Registra (o actualiza) al personaje actual en la DB account-wide.
-- Idempotente por sesión: solo la primera llamada escribe; las siguientes son
-- no-op para no re-publicar el evento.
function Characters:RegisterCurrent()
    if not currentKey then
        local name = UnitName("player")
        if not name or name == "" then return nil end
        currentKey = BuildKey(name, GetRealmName())
    end

    local container = EnsureContainer()
    if not container then return nil end

    local now = time()

    local className, classFile = UnitClass("player")
    local raceName = UnitRace("player")
    local faction = UnitFactionGroup("player")

    local info = container[currentKey]
    if not info then
        info = {
            firstSeen = now,
        }
        container[currentKey] = info
    end

    -- Mantiene la versión del addon actual en cada login para que el portal
    -- pueda distinguir registros generados por esquemas anteriores.
    info.version       = RD.constants and RD.constants.VERSION or ""
    info.name          = UnitName("player") or "?"
    info.realm         = GetRealmName() or "?"
    info.className     = className or "?"
    info.classFile     = classFile or "?"
    info.raceName      = raceName or "?"
    info.faction       = faction or "?"
    info.level         = UnitLevel("player") or 0
    info.guildName     = GetGuildInfo("player")
    info.lastSeen      = now

    if RD.config and RD.config.Save then
        RD.config:Save()
    end

    if RD.events and RD.events.Publish then
        RD.events:Publish("CHARACTER_REGISTERED", currentKey, info)
    end

    return currentKey, info
end

-- Devuelve true si ya se registró el personaje en esta sesión (PLAYER_LOGIN)
function Characters:IsCurrentRegistered()
    return currentKey ~= nil and type(RaidDominionDB) == "table"
        and type(RaidDominionDB.characters) == "table" and RaidDominionDB.characters[currentKey] ~= nil
end

-- Datos de un personaje por clave ("Nombre-Reino"); nil si no existe
function Characters:Get(key)
    if type(RaidDominionDB) ~= "table" or type(RaidDominionDB.characters) ~= "table" then
        return nil
    end
    return RaidDominionDB.characters[key]
end

-- Tabla completa de personajes detectados (la DB compartida; NO copiar encima)
function Characters:GetAll()
    return EnsureContainer() or {}
end

-- Lista de personajes ordenada por última conexión (desc). Copia nueva cada vez.
function Characters:GetSorted()
    local list = {}
    for key, info in pairs(EnsureContainer() or {}) do
        list[#list + 1] = { key = key, info = info }
    end
    table.sort(list, function(a, b)
        return (a.info.lastSeen or 0) > (b.info.lastSeen or 0)
    end)
    return list
end

-- Número de personajes detectados en esta cuenta
function Characters:Count()
    local n = 0
    for _ in pairs(EnsureContainer() or {}) do
        n = n + 1
    end
    return n
end

-- Clave del personaje actual ("Nombre-Reino"), cacheada desde RegisterCurrent
function Characters:GetCurrentKey()
    return currentKey
end

RD.utils = RD.utils or {}
RD.utils.characters = Characters
return Characters
