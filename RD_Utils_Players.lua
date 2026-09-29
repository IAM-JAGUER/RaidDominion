--[[
    RD_Utils_Players.lua
    PROPÓSITO: Utilidades de dominio para la opción "Jugador" del menú flotante.
              Recolecta el pool de jugadores que el usuario "tiene en sus
              listas" (asignaciones de roles/habilidades/buffs/auras y miembros
              de bandas) más uno mismo, y construye la ficha de un jugador
              (asignaciones por lista, bandas donde figura, datos de roster/
              registro). Puro (no crea UI): testeable desde el harness.
    API PÚBLICA:
        - RD.utils.players:GetSearchPool()      -> { { name, clean }, ... }
        - RD.utils.players:GetPlayerInfo(name)  -> tabla de ficha (o nil)
        - RD.utils.players:GetClassLookup(name) -> classFile o ""
        - RD.utils.players:ResolveDisplay(name) -> nombre canónico del pool o nil
    EVENTOS: Ninguno (solo lectura de RD.config / RD.utils.*).
]]

local addonName, private = ...
local RD = _G.RaidDominion or {}
_G.RaidDominion = RD

local Players = {}

-- Listas asignables cuyos valores son nombres de jugador asignado
local ASSIGNABLE_LISTS = { "roles", "abilities", "buffs", "auras" }

-- Normaliza un nombre (sin sufijo de reino, minúsculas, sin espacios)
local function CleanName(name)
    if RD.UIUtils and RD.UIUtils.CleanName then
        return RD.UIUtils.CleanName(name)
    end
    local clean = string.gsub(tostring(name or ""), "%-.*", "")
    clean = string.gsub(clean, "%s+", "")
    return string.lower(clean)
end

-- Capitaliza un nombre (para mostrar)
local function CapitalizeName(name)
    if RD.UIUtils and RD.UIUtils.CapitalizeName then
        return RD.UIUtils.CapitalizeName(name)
    end
    local clean = string.gsub(tostring(name or ""), "%-.*", "")
    return string.upper(string.sub(clean, 1, 1)) .. string.lower(string.sub(clean, 2))
end

-- Añade un nombre al pool sin duplicados (por clean). Self va primero.
local function AddToPool(pool, seen, name)
    if type(name) ~= "string" or name == "" then return end
    local clean = CleanName(name)
    if clean == "" or seen[clean] then return end
    seen[clean] = true
    pool[#pool + 1] = { name = name, clean = clean }
end

-- Pool de búsqueda: jugadores de las listas asignables + miembros de bandas +
-- uno mismo. Orden estable: self, luego asignados (por lista), luego bandas.
function Players:GetSearchPool()
    local pool = {}
    local seen = {}

    -- 1) Uno mismo
    local selfName
    if UnitName then selfName = UnitName("player") end
    AddToPool(pool, seen, selfName)

    -- 2) Jugadores asignados en las listas asignables
    for _, listKey in ipairs(ASSIGNABLE_LISTS) do
        local tbl = {}
        if RD.utils and RD.utils.assignments and RD.utils.assignments.Get then
            tbl = RD.utils.assignments:Get(listKey) or {}
        elseif RD.config and RD.config.Get then
            tbl = RD.config:Get("assignments." .. listKey, {})
        end
        if type(tbl) == "table" then
            for _, assigned in pairs(tbl) do
                AddToPool(pool, seen, assigned)
            end
        end
    end

    -- 3) Miembros de las bandas registradas
    local bands = (RD.utils and RD.utils.bands and RD.utils.bands.GetBands and RD.utils.bands:GetBands()) or {}
    if type(bands) == "table" then
        for _, band in ipairs(bands) do
            if type(band.players) == "table" then
                for _, member in ipairs(band.players) do
                    AddToPool(pool, seen, member and member.name)
                end
            end
        end
    end

    return pool
end

-- Devuelve el nombre canónico (display) del pool que coincide con `name`, o nil.
-- Útil para normalizar lo que escribe el usuario a un nombre conocido de las
-- listas (p.ej. si escribió en minúsculas).
function Players:ResolveDisplay(name)
    local target = CleanName(name)
    if target == "" then return nil end
    for _, entry in ipairs(self:GetSearchPool()) do
        if entry.clean == target then return entry.name end
    end
    return nil
end

-- Clase (classFile) de un jugador. Orden de resolución:
--   1. unidad en vivo (target / grupo / raid por nombre)
--   2. clase guardada en una banda
--   3. roster de personajes (characters)
--   4. registro detallado (registry)
-- IMPORTANTE (Lua 5.1): NO usar `X and X(...)` en asignaciones múltiples (colapsa
-- a un solo valor); llamar directo con guarda.
local function LookupClassFromUnits(name)
    if not name then return "" end
    local clean = CleanName(name)
    local selfName
    if UnitName then selfName = UnitName("player") end
    if clean ~= "" and clean == CleanName(selfName) then
        local _, classFile = UnitClass("player")
        return classFile or ""
    end
    if UnitName then
        local targetName = UnitName("target")
        if targetName and clean == CleanName(targetName) then
            local _, classFile = UnitClass("target")
            if classFile then return classFile end
        end
    end
    -- Buscar por nombre en el raid/grupo (GetRaidUnitByName es 3.3.5a-safe)
    if GetRaidUnitByName then
        local unit = GetRaidUnitByName(name)
        if unit and UnitExists(unit) then
            local _, classFile = UnitClass(unit)
            if classFile then return classFile end
        end
    end
    return ""
end

function Players:GetClassLookup(name)
    if not name then return "" end

    local classFile = LookupClassFromUnits(name)
    if classFile ~= "" then return classFile end

    -- Clase guardada en una banda
    local bands = (RD.utils and RD.utils.bands and RD.utils.bands.GetBands and RD.utils.bands:GetBands()) or {}
    if type(bands) == "table" then
        local clean = CleanName(name)
        for _, band in ipairs(bands) do
            if type(band.players) == "table" then
                for _, member in ipairs(band.players) do
                    if member and member.name and CleanName(member.name) == clean
                        and member.class and member.class ~= "" then
                        return member.class
                    end
                end
            end
        end
    end

    -- Roster de personajes (characters)
    if RD.utils and RD.utils.characters and RD.utils.characters.GetAll then
        local clean = CleanName(name)
        for _, info in pairs(RD.utils.characters:GetAll() or {}) do
            if info and info.name and CleanName(info.name) == clean and info.classFile and info.classFile ~= "" then
                return info.classFile
            end
        end
    end

    -- Registro detallado (registry)
    if RD.utils and RD.utils.registry and RD.utils.registry.GetAll then
        local clean = CleanName(name)
        for _, tree in pairs(RD.utils.registry:GetAll() or {}) do
            if tree and tree.player and tree.player.name and CleanName(tree.player.name) == clean
                and tree.player.classFile and tree.player.classFile ~= "" then
                return tree.player.classFile
            end
        end
    end

    return ""
end

-- Ficha completa de un jugador:
--   { display, clean, class, classFile,
--     assignments = { roles = {ítem,...}, abilities, buffs, auras },  -- solo listas no vacías
--     bands       = { { band, role, dual, leader, sanction, banned, class, points }, ... },
--     roster      = info de characters (o nil),
--     registry    = árbol de registry (o nil) }
-- Devuelve nil si el nombre está vacío. El jugador puede no existir en ninguna
-- lista (ficha mínima: solo display/clean) — la UI decide si ofrecer añadir.
function Players:GetPlayerInfo(name)
    if not name then return nil end
    local clean = CleanName(name)
    if clean == "" then return nil end

    local display = self:ResolveDisplay(name) or name
    local info = {
        display = CapitalizeName(display),
        clean = clean,
        classFile = self:GetClassLookup(name),
        assignments = {},
        bands = {},
    }

    -- Asignaciones: ítems de cada lista donde este jugador está asignado
    for _, listKey in ipairs(ASSIGNABLE_LISTS) do
        local tbl = {}
        if RD.utils and RD.utils.assignments and RD.utils.assignments.Get then
            tbl = RD.utils.assignments:Get(listKey) or {}
        elseif RD.config and RD.config.Get then
            tbl = RD.config:Get("assignments." .. listKey, {})
        end
        if type(tbl) == "table" then
            local mine = {}
            for itemName, assigned in pairs(tbl) do
                if assigned and assigned ~= "" and CleanName(assigned) == clean then
                    mine[#mine + 1] = itemName
                end
            end
            if #mine > 0 then
                table.sort(mine)
                info.assignments[listKey] = mine
            end
        end
    end

    -- Bandas donde figura este jugador
    local bands = (RD.utils and RD.utils.bands and RD.utils.bands.GetBands and RD.utils.bands:GetBands()) or {}
    if type(bands) == "table" then
        for _, band in ipairs(bands) do
            if type(band.players) == "table" then
                for _, member in ipairs(band.players) do
                    if member and member.name and CleanName(member.name) == clean then
                        info.bands[#info.bands + 1] = {
                            band = band.name or "Banda",
                            role = member.role or "",
                            dual = member.dual or "",
                            leader = member.leader or "",
                            sanction = member.sanction or "",
                            banned = member.banned or false,
                            class = member.class or "",
                            points = tonumber(member.points) or 0,
                        }
                    end
                end
            end
        end
    end

    -- Roster de personajes (characters)
    if RD.utils and RD.utils.characters and RD.utils.characters.GetAll then
        for _, entry in pairs(RD.utils.characters:GetAll() or {}) do
            if entry and entry.name and CleanName(entry.name) == clean then
                info.roster = entry
                break
            end
        end
    end

    -- Registro detallado (registry)
    if RD.utils and RD.utils.registry and RD.utils.registry.GetAll then
        for _, tree in pairs(RD.utils.registry:GetAll() or {}) do
            if tree and tree.player and tree.player.name and CleanName(tree.player.name) == clean then
                info.registry = tree
                break
            end
        end
    end

    return info
end

RD.utils = RD.utils or {}
RD.utils.players = Players
return Players