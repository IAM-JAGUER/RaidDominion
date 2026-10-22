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

-- Asegura que exista el contenedor characters en la DB compartida
local function EnsureContainer()
    if type(RaidDominionDB) ~= "table" then
        RaidDominionDB = {}
    end
    if type(RaidDominionDB.characters) ~= "table" then
        RaidDominionDB.characters = {}
    end
    return RaidDominionDB.characters
end

local function GetMoneyCopper()
    if type(GetMoney) == "function" then
        local ok, m = pcall(GetMoney)
        if ok and type(m) == "number" then return m end
    end
    if RD.utils and RD.utils.currencies and RD.utils.currencies.GetMoney then
        local ok, m = pcall(RD.utils.currencies.GetMoney, RD.utils.currencies)
        if ok and type(m) == "number" then return m end
    end
    return 0
end

-- Clave única del personaje: Nombre-Reino (evita colisiones entre reinos)
local function BuildKey(name, realm)
    return tostring(name or "?") .. "-" .. tostring(realm or "?")
end

-- Registra (o actualiza) al personaje actual en la DB account-wide.
-- Se invoca en login, al cambiar equipo/dinero/monedas y en logout. Al salir,
-- el cliente puede haber liberado la unidad "player": se conserva la clave
-- cacheada y NO se pisan los datos de identidad que ya estaban guardados.
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

    -- El equipamiento debe guardarse en characters (independiente de "Registrar"/registry).
    if RD.utils and RD.utils.equipment and RD.utils.equipment.Get then
        local ok, items, count, avg = pcall(RD.utils.equipment.Get, RD.utils.equipment)
        if ok and type(items) == "table" then
            local c = tonumber(count) or #items
            if c > 0 then
                info.equipment = items
                info.equipmentCount = c
                info.avgIlvl = tonumber(avg) or 0
            elseif type(info.equipment) ~= "table" or #info.equipment == 0 then
                info.equipment = items
                info.equipmentCount = 0
                info.avgIlvl = tonumber(avg) or 0
            end
            -- Si ya hay equipo guardado y el scan actual devuelve 0 (paperdoll no listo),
            -- NO sobreescribir con vacío para conservar el último snapshot válido.
        else
            -- Fallback: no machacar datos existentes si la lectura falla
            if type(info.equipment) ~= "table" then
                info.equipment = nil
                info.equipmentCount = nil
                info.avgIlvl = nil
            end
        end
    else
        if type(info.equipment) ~= "table" then
            info.equipment = nil
            info.equipmentCount = nil
            info.avgIlvl = nil
        end
    end

    -- Mantiene la versión del addon actual en cada login para que el portal
    -- pueda distinguir registros generados por esquemas anteriores.
    -- Los datos de identidad solo se sobrescriben si el cliente los da: en
    -- PLAYER_LOGOUT la unidad puede estar liberada y devolver nil.
    info.version = RD.constants and RD.constants.VERSION or ""
    local pname = UnitName("player")
    if pname and pname ~= "" then info.name = pname end
    local realm = GetRealmName()
    if realm and realm ~= "" then info.realm = realm end
    if className then info.className = className end
    if classFile then info.classFile = classFile end
    if raceName then info.raceName = raceName end
    if faction then info.faction = faction end
    local lvl = UnitLevel("player")
    if type(lvl) == "number" and lvl > 0 then info.level = lvl end
    local guildName = GetGuildInfo("player")
    if guildName then info.guildName = guildName end
    info.lastSeen = now

    if RD.config and RD.config.Save then
        RD.config:Save()
    end

    -- Monedas (TODAS: oro + todas las del cliente), sin seguimiento ni
    -- "Registrar". Fuente única: RD.utils.currencies:Collect() (misma que usa la
    -- UI y el watcher). Si la lectura llega a 0 se CONSERVA el último snapshot
    -- válido para no guardar ceros cuando el cliente aún no cargó las monedas.
    do
        local fresh = GetMoneyCopper()
        local prevMoney = tonumber(info.money)
        if type(fresh) == "number" and fresh > 0 then
            info.money = math.floor(fresh)
        elseif prevMoney == nil then
            info.money = 0
        end

        local scanned
        local cur = RD.utils and RD.utils.currencies
        if cur and cur.Collect then
            local ok, groups = pcall(cur.Collect, cur)
            if ok and type(groups) == "table" then
                scanned = {}
                for _, g in ipairs(groups) do
                    for _, it in ipairs(g.items or {}) do
                        if it and it.name and not it.money then
                            scanned[#scanned + 1] = {
                                name = it.name,
                                quantity = tonumber(it.quantity) or 0,
                                icon = it.icon,
                            }
                        end
                    end
                end
            end
        end

        local anyPositive = false
        for _, c in ipairs(scanned or {}) do
            if c.quantity > 0 then anyPositive = true break end
        end
        local prevCur = info.currencies
        local keepPrev = not anyPositive and type(prevCur) == "table" and #prevCur > 0
        if not keepPrev and scanned then
            local allCoins = {}
            allCoins[1] = { name = "Oro", quantity = tonumber(info.money) or 0, money = true }
            for _, c in ipairs(scanned) do
                allCoins[#allCoins + 1] = c
            end
            info.currencies = allCoins
        end
    end

    -- Instancias: guardado independiente de "Registrar".
    if RD.utils and RD.utils.instances and RD.utils.instances.Export then
        local ok, list = pcall(RD.utils.instances.Export, RD.utils.instances)
        if ok and type(list) == "table" then
            info.instances = list
        else
            info.instances = {}
        end
    else
        info.instances = {}
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
