--[[
    RD_Module_RosterWatch.lua
    PROPÓSITO: Vigila la composición del grupo/raid. Cuando un jugador se va,
              limpia las asignaciones con su nombre en los submenús (roles,
              habilidades, buffs, auras), como el addon base v2.
    API PÚBLICA:
        - RD.modules.rosterWatch:Sync()  -- re-evalúa el roster (por eventos)
    EVENTOS: RAID_ROSTER_UPDATE, PARTY_MEMBERS_CHANGED.
]]

local addonName, private = ...
local RD = _G.RaidDominion or {}
_G.RaidDominion = RD

local RosterWatch = {}

-- Conjunto de nombres conocidos del roster anterior (nil = aún no sincronizado)
-- y mapa nombre -> classFileName (para colorear por clase al salir).
local known = nil
local knownClasses = {}

-- Colorea un nombre con el color de su clase (RAID_CLASS_COLORS).
local function ColorClassText(classFile, name)
    local c = classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
    if c then
        local hex = string.format("%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255)
        return string.format("|cff%s%s|r", hex, name)
    end
    return name
end

-- Roster actual como conjunto de nombres + mapa de clases (banda o grupo; nunca
-- se mezclan las unidades de raid con las de party, que se solapan en banda).
local function CurrentRoster()
    local set = {}
    local classes = {}
    local function Add(name, classFile)
        if name and name ~= "" then
            set[name] = true
            if classFile then classes[name] = classFile end
        end
    end
    local nRaid = GetNumRaidMembers()
    if nRaid > 0 then
        for i = 1, nRaid do
            local name, _, _, _, _, fileName = GetRaidRosterInfo(i)
            Add(name, fileName)
        end
    else
        local nParty = GetNumPartyMembers()
        for i = 1, nParty do
            local name = UnitName("party" .. i)
            local classFile = select(2, UnitClass("party" .. i))
            Add(name, classFile)
        end
    end
    local _, selfClass = UnitClass("player")
    Add(UnitName("player"), selfClass)
    return set, classes
end

-- Etiquetas (singular/plural) por submenú para el mensaje de abandono.
local ABANDON_LABELS = {
    roles     = { "Rol abandonado",     "Roles abandonados" },
    abilities = { "Habilidad abandonada", "Habilidades abandonadas" },
    buffs     = { "Buff abandonado",    "Buffs abandonados" },
    auras     = { "Aura abandonada",    "Auras abandonadas" },
}

-- Compara el roster previo con el actual y limpia las asignaciones de quienes
-- ya no están (la primera sincronización no limpia nada: no hay "previo").
-- Se reportan TODOS los elementos abandonados (roles, habilidades, buffs y
-- auras) con sus nombres completos, agrupados por submenú.
function RosterWatch:Sync()
    local current, currentClasses = CurrentRoster()
    if known then
        local assign = RD.utils and RD.utils.assignments
        for name in pairs(known) do
            if not current[name] then
                local abandoned = {}
                if assign and assign.ClearForPlayer then
                    abandoned = assign:ClearForPlayer(name)
                end
                local parts = {}
                local total = 0
                for _, listKey in ipairs({ "roles", "abilities", "buffs", "auras" }) do
                    local items = abandoned[listKey]
                    if items and #items > 0 then
                        total = total + #items
                        local label = ABANDON_LABELS[listKey]
                        parts[#parts + 1] = (label and (#items == 1 and label[1] or label[2]) or listKey) .. ": " .. table.concat(items, ", ")
                    end
                end
                if total > 0 and RD.messageManager and RD.messageManager.SendSystemMessage then
                    -- Informa QUIÉN dejó el grupo (con color de clase) + resumen de lo retirado
                    local plural = total == 1 and "1 asignación retirada" or (total .. " asignaciones retiradas")
                    RD.messageManager:SendSystemMessage("|cffff0000[RaidDominion]|r "
                        .. ColorClassText(knownClasses[name], name)
                        .. " dejó el grupo: " .. plural .. " (" .. table.concat(parts, " · ") .. ")")
                end
            end
        end
    end
    known = current
    knownClasses = currentClasses
end

-- Escucha los cambios de composición del grupo/raid.
local f = CreateFrame("Frame")
f:RegisterEvent("RAID_ROSTER_UPDATE")
f:RegisterEvent("PARTY_MEMBERS_CHANGED")
f:SetScript("OnEvent", function()
    RosterWatch:Sync()
end)

RD.modules = RD.modules or {}
RD.modules.rosterWatch = RosterWatch
return RosterWatch
