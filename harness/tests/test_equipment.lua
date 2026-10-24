-- Harness lógico para RD_Utils_Equipment.lua (equipamiento ACTUAL del
-- personaje: fuente única del snapshot PASIVO que el registro exporta al
-- portal como registry[key].player.equipment, sin ningún check de
-- seguimiento). Verifica: Get() (solo slots equipados, orden por slot, count
-- e iLvL medio; nombre rescatado del link cuando el ítem no está cacheado;
-- itemID extraído del link para que el portal pueda enlazar la pieza).

-- ---------------------------------------------------------------- mocks
_G.RaidDominion = {}
local RD = _G.RaidDominion
RD.constants = {
    EQUIP_SLOT_NAMES = {
        [1] = "Cabeza", [5] = "Pecho", [9] = "Pies", [16] = "Mano principal",
    },
}

local EQUIPPED = {
    [1] = "|cffa335ee|Hitem:51234:0:0:0:0:0:0:0|h[Corona de Fuego]|h|r",
    [5] = "|cff0070dd|Hitem:33456:0:0:0:0:0:0:0|h[Cota de Hielo]|h|r",
    [16] = "|cffa335ee|Hitem:50034:0:0:0:0:0:0:0|h[Hoja de guerra]|h|r",
}
-- Ítem equipado que el cliente NO tiene cacheado (GetItemInfo devuelve nil).
local NO_CACHE = "|cffa335ee|Hitem:99999:0:0:0:0:0:0:0|h[Arma Sin Caché]|h|r"

_G.GetInventoryItemLink = function(unit, slot)
    return EQUIPPED[slot]
end
_G.GetItemInfo = function(link)
    if link == EQUIPPED[1] then
        return "Corona de Fuego", link, 4, 277
    elseif link == EQUIPPED[5] then
        return "Cota de Hielo", link, 3, 245
    elseif link == EQUIPPED[16] then
        return "Hoja de guerra", link, 4, 264
    elseif link == NO_CACHE then
        return nil
    end
    return nil
end

-- ---------------------------------------------------------------- carga
local root = (arg[0]:match("^(.*)/harness/tests/") or "") .. "/"
local chunk = assert(loadfile(root .. "RD_Utils_Equipment.lua"))
chunk("RD_Utils_Equipment", {})
local Equip = RD.utils.equipment
assert(Equip and Equip.Get, "no registró RD.utils.equipment")

local failures = 0
local function Check(cond, label)
    if cond then
        print("  [OK]     " .. label)
    else
        failures = failures + 1
        print("  [FALLO]  " .. label)
    end
end

-- ---------------------------------------------------------------- Get()
print("== Get() ==")
local items, count, avg = Equip:Get()
Check(count == 3, "cuenta solo los slots equipados")
Check(items[1].slot == 1 and items[2].slot == 5 and items[3].slot == 16,
    "los ítems salen ordenados por slot")
Check(items[1].name == "Corona de Fuego" and items[1].ilvl == 277 and items[1].quality == 4,
    "extrae nombre, calidad e iLvL del link")
Check(items[1].itemID == 51234 and items[2].itemID == 33456 and items[3].itemID == 50034,
    "extrae el itemID del link")
Check(avg == math.floor((277 + 245 + 264) / 3 + 0.5), "el iLvL medio se redondea")

-- ---------------------------------------------------------------- sin caché
print("== ítem sin caché ==")
EQUIPPED[9] = NO_CACHE
local items2, count2 = Equip:Get()
Check(count2 == 4, "una pieza sin caché también cuenta")
Check(items2[3].slot == 9 and items2[3].name == "Arma Sin Caché" and items2[3].ilvl == nil,
    "sin caché: el nombre se rescata del link y el iLvL queda nil")
Check(items2[3].itemID == 99999, "sin caché: el itemID también se rescata del link")
EQUIPPED[9] = nil

-- ---------------------------------------------------------------- vacío
print("== sin equipo ==")
EQUIPPED[1], EQUIPPED[5], EQUIPPED[16] = nil, nil, nil
local _, countEmpty, avgEmpty = Equip:Get()
Check(countEmpty == 0 and avgEmpty == 0, "sin piezas: count 0 e iLvL medio 0")

-- ---------------------------------------------------------------- resumen
print("")
if failures == 0 then
    print("RESULTADO: OK (todos los checks pasaron)")
    os.exit(0)
else
    print("RESULTADO: FAIL (" .. failures .. " checks fallaron)")
    os.exit(1)
end
