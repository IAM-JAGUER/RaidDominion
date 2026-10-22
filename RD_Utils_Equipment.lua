--[[
    RD_Utils_Equipment.lua
    PROPÓSITO: Equipamiento ACTUAL del personaje (paperdoll, slots 0..19) como
              fuente única del snapshot PASIVO que se guarda en el SV: el
              registro del portal (RD_Utils_Registry) exporta
              registry["Nombre-Reino"].player.equipment SIEMPRE, sin ningún
              check de seguimiento (es información propia del personaje, no un
              bloque de seguimiento del tooltip). Lógica PURA: solo lee APIs del
              juego, sin frames ni eventos, por lo que es testeable con mocks
              del harness.
    API PÚBLICA:
        - RD.utils.equipment:Get()    -> items { {slot,name,quality,ilvl}, ... },
                                         count, avgIlvl  (orden por slot)
    EVENTOS: Ninguno.
]]

local addonName, private = ...
local RD = _G.RaidDominion or {}
_G.RaidDominion = RD

RD.utils = RD.utils or {}
local Equipment = {}

-- Slots de inventario con equipo: 0 munición .. 19 tabardo
local EQUIP_SLOTS = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19 }

-- Equipamiento actual: una entrada por slot equipado, ordenado por slot.
-- Devuelve también el número de piezas y el iLvL medio redondeado (solo
-- cuenta las piezas cuyo iLvL está cacheado por el cliente).
function Equipment:Get()
    local items = {}
    local ilvlSum, ilvlCount = 0, 0
    for _, slot in ipairs(EQUIP_SLOTS) do
        local link = GetInventoryItemLink("player", slot)
        if link then
            local name, _, quality, iLevel = GetItemInfo(link)
            -- Ítem no cacheado: rescata al menos el nombre visible del link
            name = name or string.match(link, "%[([^%]]+)%]") or ("Slot " .. tostring(slot))
            items[#items + 1] = {
                slot = slot,
                name = name,
                quality = tonumber(quality),
                ilvl = tonumber(iLevel),
            }
            if iLevel then
                ilvlSum = ilvlSum + iLevel
                ilvlCount = ilvlCount + 1
            end
        end
    end
    table.sort(items, function(a, b) return a.slot < b.slot end)
    local avgIlvl = (ilvlCount > 0) and math.floor(ilvlSum / ilvlCount + 0.5) or 0
    return items, #items, avgIlvl
end

RD.utils.equipment = Equipment
return Equipment
