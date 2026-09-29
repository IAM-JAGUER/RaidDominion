--[[
    RD_Utils_Migrations.lua
    PROPÓSITO: Migraciones y saneos de la DB de RaidDominion (migraciones de
              dominio que la capa de persistencia (RD_Config) no debe conocer:
              canal legacy, siembra de listas, booleanos 1/0, dedup de reglas,
              sanciones legacy, limpieza de asignaciones huérfanas, registro
              detallado por personaje y remapeo del estilo de título de reglas).
    API PÚBLICA:
        - RD.utils.migrations:Run(db, defaults)  -- aplica todas (idempotentes)
    EVENTOS: Ninguno (lo invoca RD.config:Load antes de publicar CONFIG_LOADED).
]]

local addonName, private = ...
local RD = _G.RaidDominion or {}
_G.RaidDominion = RD

local Migrations = {}

-- Copia profunda (helper central en RD.UIUtils.DeepCopy; RD_Config conserva el
-- suyo local porque se carga antes que RD_UI_Utils).
local DeepCopy = (RD.UIUtils and RD.UIUtils.DeepCopy) or function(orig)
    local origType = type(orig)
    if origType ~= "table" then return orig end
    local copy = {}
    for k, v in next, orig, nil do
        copy[DeepCopy(k)] = DeepCopy(v)
    end
    return setmetatable(copy, DeepCopy(getmetatable(orig)))
end

local LIST_KEYS = { "roles", "buffs", "auras", "abilities", "mechanics", "rules" }

-- Limpia asignaciones huérfanas: claves de "assignments.<lista>" que no
-- coinciden con ningún ítem de la lista actual (restos de versiones/estados
-- previos) se eliminan.
local function CleanAssignments(db)
    local assign = db and db.assignments
    if type(assign) ~= "table" then return end
    local lists = { "roles", "abilities", "buffs", "auras" }
    for _, listKey in ipairs(lists) do
        local tbl = assign[listKey]
        if type(tbl) == "table" then
            local items = db[listKey]
            local valid = {}
            if type(items) == "table" then
                for _, it in ipairs(items) do
                    local name = it.name or it.title
                    if name then valid[name] = true end
                end
            end
            local copy = {}
            for itemName, player in pairs(tbl) do
                if valid[itemName] then
                    copy[itemName] = player
                end
            end
            assign[listKey] = copy
        end
    end
end

-- Migración del registro detallado: antes era un slot único
-- (db.registry = árbol con .player en la raíz) que se sobrescribía entre
-- personajes de la misma cuenta; ahora es un contenedor por personaje
-- ("Nombre-Reino"). El árbol legacy se recoloca bajo SU dueño usando los datos
-- del propio registro; cualquier entrada ya migrada que conviviera se conserva.
local function MigrateRegistryPerCharacter(db)
    local reg = db.registry
    if type(reg) ~= "table" then return end

    -- ¿Formato nuevo ya? El contenedor por personaje no tiene .player en raíz
    if type(reg.player) ~= "table" then return end

    local legacy = reg.player
    local name = tostring(legacy.name or "")
    local realm = tostring(legacy.realm or "")
    local key = ((name ~= "") and name or "?") .. "-" .. ((realm ~= "") and realm or "?")

    -- Conserva entradas ya migradas ("Nombre-Reino") que pudieran coexistir
    local container = {}
    for k, v in pairs(reg) do
        if k ~= "player" and type(k) == "string" and type(v) == "table"
            and string.find(k, "-", 1, true) and v.savedAt then
            container[k] = v
        end
    end
    container[key] = legacy
    db.registry = container
end

-- Aplica todas las migraciones y saneos. Son idempotentes: las de "una sola
-- vez" usan flags en la DB; el dedup de reglas/mecánicas se ejecuta en cada
-- carga porque es barato y distintos caminos pueden re-introducir duplicados.
function Migrations:Run(db, defaults)
    if not db or type(defaults) ~= "table" then return end

    MigrateRegistryPerCharacter(db)
    CleanAssignments(db)

    -- Migración (una sola vez): el antiguo default de canal era "SYSTEM";
    -- ahora el default es "DEFAULT" (auto-resolución por contexto, como la base).
    if db.chat and db.chat.channel == "SYSTEM" and not db._channelMigrated then
        db.chat.channel = "DEFAULT"
        db._channelMigrated = true
    end

    -- Sanitiza el canal: si no pertenece al conjunto de la base, se usa
    -- "DEFAULT" para no enviar un tipo de chat desconocido.
    local validChannels = {
        DEFAULT = true, SYSTEM = true, GUILD = true, SAY = true, YELL = true,
        PARTY = true, RAID = true, RAID_WARNING = true, BATTLEGROUND = true,
        CHANNEL = true, INN = true,
    }
    if db.chat and db.chat.channel
        and not validChannels[strtrim(strupper(tostring(db.chat.channel)))] then
        db.chat.channel = "DEFAULT"
    end

    -- Migración de listas configurables: se siembran SOLO una vez (primera
    -- carga, con flag). Así el usuario puede vaciar una lista a propósito sin
    -- que se re-siembre en el siguiente load (reglas duplicadas que reaparecen).
    if defaults.roles and not db._listsSeeded then
        for _, k in ipairs(LIST_KEYS) do
            local v = db[k]
            if type(v) ~= "table" or #v == 0 then
                db[k] = DeepCopy(defaults[k])
            end
        end
        db._listsSeeded = true
    end

    -- Migración (una sola vez): normaliza booleanos guardados como 1/0
    -- (formato legacy de la v2) a booleanos nativos, recorriendo los
    -- default actuales para saber qué hojas son booleanas.
    if not db._booleansNormalized then
        local function NormalizeBooleans(dest, src)
            for k, v in pairs(src) do
                if type(v) == "table" then
                    if type(dest[k]) == "table" then
                        NormalizeBooleans(dest[k], v)
                    end
                elseif type(v) == "boolean" and type(dest[k]) == "number" then
                    dest[k] = (dest[k] ~= 0)
                end
            end
        end
        NormalizeBooleans(db, defaults)
        db._booleansNormalized = true
    end

    -- Deduplicación de listas de contenido (reglas/mecánicas): conserva solo la
    -- primera ocurrencia de cada título; no re-añade reglas borradas.
    for _, listKey in ipairs({ "rules", "mechanics" }) do
        local list = db[listKey]
        if type(list) == "table" then
            local seen = {}
            local unique = {}
            for _, item in ipairs(list) do
                local title = item.title or item.name or ""
                if title == "" or not seen[title] then
                    if title ~= "" then seen[title] = true end
                    unique[#unique + 1] = item
                end
            end
            db[listKey] = unique
        end
    end

    -- Migración (una sola vez): el límite de dados del botín no puede superar
    -- 10 segundos (decisión de diseño del gestor de botín). Sanea configs que
    -- heredaron valores mayores de la antigua pestaña de configuración.
    if not db._lootLimitClamped then
        if type(db.loot) == "table" and db.loot.rollTimeLimit then
            db.loot.rollTimeLimit = math.min(10, math.floor(tonumber(db.loot.rollTimeLimit) or 10))
        end
        db._lootLimitClamped = true
    end

    -- Migración (una sola vez): sanciones de booleano (banned) a causal
    -- (sanction). Los jugadores legacy con banned=true pasan a "baneo".
    if not db._sanctionCausesMigrated then
        local bandsList = db.bands
        if type(bandsList) == "table" then
            for _, band in ipairs(bandsList) do
                for _, p in ipairs(band.players or {}) do
                    if p.banned and (p.sanction == nil or p.sanction == "") then
                        p.sanction = "baneo"
                    end
                end
            end
        end
        db._sanctionCausesMigrated = true
    end

    -- Migración (una sola vez): el estilo de título por defecto de las REGLAS
    -- pasa de "none" (Ninguno) a "equals" (= Nombre =) para que el spammer de
    -- regla muestre un título distinguible por defecto. Solo remapea el valor
    -- legacy "none" que quedó guardado por el antiguo default; si el usuario
    -- elige "Ninguno" después de esta migración, el flag ya está puesto y el
    -- saneo no vuelve a tocar nada.
    if not db._rulesWrapperEqualsMigrated then
        if type(db.announce) == "table" and type(db.announce.rules) == "table"
            and db.announce.rules.wrapper == "none" then
            db.announce.rules.wrapper = "equals"
        end
        db._rulesWrapperEqualsMigrated = true
    end

    -- Migración (una sola vez): el modo Auto de botín dejó de tener opciones
    -- (comportamiento fijo: recetas/materiales/dinero/basura al maestro, verde
    -- o mejor a la banda, ítems de misión se dejan; on/off solo por el clic
    -- izquierdo del botón "Auto"). Se purgan las claves legacy de loot.auto;
    -- el único control que queda es ui.showAutoLootButton.
    if not db._lootAutoSimplified then
        local auto = db.loot and db.loot.auto
        if type(auto) == "table" then
            local obsolete = {
                maxCorpses = true, persistent = true, minRarity = true,
                minValue = true, distributeRecipes = true, corpseDelay = true,
                itemDelay = true, verifyDelay = true, skipQuestItems = true,
                vaciar = true, moneyToMe = true, allowInCombat = true, debug = true,
            }
            local hasContent = false
            for k in pairs(auto) do
                if obsolete[k] then
                    auto[k] = nil
                else
                    hasContent = true
                end
            end
            if not hasContent then
                db.loot.auto = nil
            end
        end
        db._lootAutoSimplified = true
    end

    -- Migración (una sola vez): el ítem "Jugador" del submenú RaidDominion se
    -- reubicó a la barra inferior (ACTION_BAR) como botón con action
    -- "ActionBarPlayer" y actionRight "ActionBarPlayerFinder", justo antes de
    -- "Configuración". Quienes ya tenían un orden guardado en ui.actionBar.order
    -- no incluyen el id nuevo (OrderBarItems lo añadiría al FINAL); esta
    -- migración lo inserta delante de "ActionBarConfig" (o al final si ese id
    -- no existiera) para que la posición por defecto sea coherente.
    if not db._barPlayerInserted then
        if type(db.ui) == "table" and type(db.ui.actionBar) == "table"
            and type(db.ui.actionBar.order) == "table"
            and #db.ui.actionBar.order > 0 then
            local order = db.ui.actionBar.order
            local found = false
            for i = 1, #order do
                if order[i] == "ActionBarPlayer" then found = true break end
            end
            if not found then
                local insertAt = 0
                for i = 1, #order do
                    if order[i] == "ActionBarConfig" then insertAt = i break end
                end
                if insertAt == 0 then
                    insertAt = #order + 1
                end
                table.insert(order, insertAt, "ActionBarPlayer")
            end
        end
        db._barPlayerInserted = true
    end
end

RD.utils = RD.utils or {}
RD.utils.migrations = Migrations
return Migrations
