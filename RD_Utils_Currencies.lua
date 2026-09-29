--[[
    RD_Utils_Currencies.lua
    PROPÓSITO: Lectura EN VIVO del listado de monedas del cliente (GetMoney +
              GetCurrencyListSize/Info) y formato de dinero. Lógica PURA: sin
              frames, sin mensajes y sin eventos del juego; por tanto testeable
              con mocks del harness.
              Los iconos se leen de la POSICIÓN 8 de GetCurrencyListInfo: en
              3.3.5a devuelve 9 valores (name, isHeader, isExpanded, isUnused,
              isWatched, count, extraCurrencyType, icon, itemID); leer mal la
              posición pinta un cuadro negro (el path real se descarta).
              Es la fuente ÚNICA del dato en vivo para:
                - la sección "Monedas" del editor (RD_UI_BandsPlayerEditor_Sections_Currencies),
                - el watcher de metas (RD_Module_ItemGoalsWatch),
                - el seguimiento del tooltip del botón "Jugador" (vía RD_Utils_ItemGoals).
              El dinero del personaje siempre va primero como grupo "Dinero" con
              una única fila "Oro" (meta SOLO de oro; cantidades en COBRE, la UI
              las edita en ORO entero).
    API PÚBLICA:
        - RD.utils.currencies:Collect()     -> { { title, items = { { name, quantity, icon, money } } } }
        - RD.utils.currencies:Flatten(groups) -> lista plana de items (sin headers)
        - RD.utils.currencies:FormatMoney(copper) -> "Xg Ys Zc" (omite partes nulas)
        - RD.utils.currencies:Amount(entry, value) -> texto según entry.money
        - RD.utils.currencies.MONEY_KEY / MONEY_ICON / COPPER_PER_GOLD
    EVENTOS: Ninguno.
]]

local addonName, private = ...
local RD = _G.RaidDominion or {}
_G.RaidDominion = RD

RD.utils = RD.utils or {}
local Currencies = {}

-- Dinero del personaje como meta (solo oro): GetMoney() devuelve el total en
-- cobre; la meta se guarda en cobre (CheckCurrencies compara cobre con cobre)
-- y la UI la edita en ORO (entero). Plata/cobre solo se muestran (desglose).
Currencies.MONEY_KEY = "Oro"
Currencies.MONEY_ICON = "Interface\\MoneyFrame\\UI-GoldIcon"
Currencies.COPPER_PER_GOLD = 10000

-- Formatea un total en cobre a "Xg Ys Zc" (omite partes nulas).
function Currencies:FormatMoney(copper)
    copper = tonumber(copper) or 0
    local g = math.floor(copper / 10000)
    local s = math.floor((copper % 10000) / 100)
    local c = copper % 100
    local parts = {}
    if g > 0 then parts[#parts + 1] = tostring(g) .. "g" end
    if s > 0 then parts[#parts + 1] = tostring(s) .. "s" end
    if c > 0 or #parts == 0 then parts[#parts + 1] = tostring(c) .. "c" end
    return table.concat(parts, " ")
end

-- Texto de una cantidad según el tipo de fila (dinero → desglose; resto, entero).
function Currencies:Amount(entry, value)
    if entry and entry.money then
        return self:FormatMoney(value)
    end
    return tostring(value or 0)
end

-- Listado agrupado por las categorías (headers) del cliente. El dinero del
-- personaje va SIEMPRE primero, como grupo "Dinero" con una única meta: el oro.
function Currencies:Collect()
    local groups = {}
    local money = (GetMoney and GetMoney()) or 0
    groups[#groups + 1] = {
        title = "Dinero",
        items = {
            {
                name = self.MONEY_KEY,
                quantity = tonumber(money) or 0,
                icon = self.MONEY_ICON,
                money = true,
            },
        },
    }
    local current = "Monedas"
    local n = (GetCurrencyListSize and GetCurrencyListSize()) or 0
    for i = 1, n do
        local name, isHeader, _, _, _, quantity, _, icon
        if GetCurrencyListInfo then
            name, isHeader, _, _, _, quantity, _, icon = GetCurrencyListInfo(i)
        end
        if name then
            if isHeader then
                current = name
            else
                local g = groups[#groups]
                if not g or g.title ~= current then
                    groups[#groups + 1] = { title = current, items = {} }
                    g = groups[#groups]
                end
                g.items[#g.items + 1] = {
                    name = name,
                    quantity = tonumber(quantity) or 0,
                    icon = icon or "Interface\\Icons\\INV_Misc_Coin_01",
                }
            end
        end
    end
    return groups
end

-- Lista plana de ítems (sin headers): la consumen el watcher y el tooltip.
function Currencies:Flatten(groups)
    local out = {}
    for _, g in ipairs(groups or {}) do
        for _, it in ipairs(g.items or {}) do
            out[#out + 1] = it
        end
    end
    return out
end

RD.utils.currencies = Currencies
return Currencies