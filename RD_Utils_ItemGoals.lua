--[[
    RD_Utils_ItemGoals.lua
    PROPÓSITO: Objetivos ("meta") de equipamiento y monedas POR PERSONAJE
              (wishlist por slot + metas de cantidad de moneda) y SEGUIMIENTO de
              monedas y OBJETOS para el tooltip del botón "Jugador" de la barra
              inferior. Lógica PURA: sin frames, sin mensajes y sin eventos del
              juego, por lo que es testeable con mocks del harness. Los avisos y
              la escucha de eventos los disparan los módulos
              (RD_Module_ItemGoalsWatch) y las secciones del editor
              (RD_UI_BandsPlayerEditor_Sections_Grids).
              Persistencia: RaidDominionDB.itemGoals["Nombre-Reino"] = {
                  equip           = { [slot] = { name, itemID, quality, ilvl, icon, done } },
                  currency        = { [nombreMoneda] = { target, reached } },
                  currencyTracked = { [nombreMoneda] = true },  -- seguimiento (tooltip Jugador)
                  itemTracked     = { [itemID] = true },        -- seguimiento de objetivos (tooltip Jugador)
                  instancesTracked= true,                        -- seguimiento de instancias (check general)
              }
              Se escribe en BLOQUE por personaje (patrón RD_Utils_Bands). Es
              data PERSONAL del jugador: NO toca registry/characters/bands, así
              que el contrato con el portal web (AGENTS §14) NO cambia.
    API PÚBLICA:
        - RD.utils.itemGoals:GetKey()               -> "Nombre-Reino" actual (o "" sin jugador)
        - RD.utils.itemGoals:SlotLabel(slot)        -> nombre del slot (GetInventorySlotName + fallback esMX)
        - RD.utils.itemGoals:ItemFromLink(link)     -> { name, itemID, quality, ilvl, icon } | nil
        - RD.utils.itemGoals:GetSlotGoal(slot) / :SetSlotGoal(slot, item)
        - RD.utils.itemGoals:ClearSlotGoal(slot) / :SlotGoals() / :MarkSlotDone(slot)
        - RD.utils.itemGoals:MatchLink(link)        -> { slot, goal } | nil
        - RD.utils.itemGoals:ScanLoot(links)        -> hits no avisados aún (dedup por sesión de botín)
        - RD.utils.itemGoals:ResetLootSession()     -> limpia el dedup (LOOT_CLOSED)
        - RD.utils.itemGoals:GetCurrencyGoal(name) / :SetCurrencyGoal(name, target)
        - RD.utils.itemGoals:ClearCurrencyGoal(name) / :CurrencyGoals()
        - RD.utils.itemGoals:CheckCurrencies(list)  -> metas recién alcanzadas (marca reached; avisa UNA vez)
        - RD.utils.itemGoals:SetCurrencyTracked(name, on) / :IsCurrencyTracked(name)
        - RD.utils.itemGoals:TrackedCurrencies()    -> lista de monedas seguidas (orden alfabético)
        - RD.utils.itemGoals:TrackedCurrencyLines() -> líneas para el tooltip de "Jugador"
        - RD.utils.itemGoals:SetItemTracked(itemID, on) / :IsItemTracked(itemID)
        - RD.utils.itemGoals:TrackedItems()         -> lista de IDs seguidos (iLvL desc)
        - RD.utils.itemGoals:TrackedItemLines()     -> líneas para el tooltip de "Jugador"
        - RD.utils.itemGoals:SetInstancesTracked(on) / :IsInstancesTracked()
    EVENTOS: Ninguno.
]]

local addonName, private = ...
local RD = _G.RaidDominion or {}
_G.RaidDominion = RD

RD.utils = RD.utils or {}
local ItemGoals = {}

-- Copia profunda local (RD_Config la tiene privada; aquí se evita acoplarse a
-- su implementación y se mantiene el módulo autocontenido para los tests).
local function DeepCopy(orig)
    local t = type(orig)
    if t ~= "table" then return orig end
    local copy = {}
    for k, v in next, orig, nil do
        copy[DeepCopy(k)] = DeepCopy(v)
    end
    return setmetatable(copy, DeepCopy(getmetatable(orig)))
end

local function CleanName(s)
    if RD.UIUtils and RD.UIUtils.CleanName then
        return RD.UIUtils.CleanName(s)
    end
    return string.lower(string.gsub(tostring(s or ""), "%-.*", ""))
end

-- Clave "Nombre-Reino" del personaje actual. Reutiliza la del roster de cuenta
-- (RD_Utils_Characters) para que coincida con el resto del addon.
function ItemGoals:GetKey()
    if RD.utils and RD.utils.characters and RD.utils.characters.GetCurrentKey then
        local k = RD.utils.characters:GetCurrentKey()
        if k and k ~= "" then return k end
    end
    if UnitName then
        local name = UnitName("player")
        if name and name ~= "" then
            local realm = (GetRealmName and GetRealmName()) or "?"
            return tostring(name) .. "-" .. tostring(realm)
        end
    end
    return ""
end

-- Nombre localizado de un slot de equipamiento. En 3.3.5a no hay
-- GetInventorySlotName; GetInventorySlotInfo(token) devuelve (id, texture,
-- checkRelic), así que para el NOMBRE se usa la tabla esMX de
-- RD_Constants.EQUIP_SLOT_NAMES (la textura del paperdoll la usa
-- RD_UI_BandsPlayerEditor_Sections_Grids.SlotIcon vía GetInventorySlotInfo).
function ItemGoals:SlotLabel(slot)
    local s = tonumber(slot)
    if not s then return "Slot ?" end
    local names = (RD.constants and RD.constants.EQUIP_SLOT_NAMES) or {}
    return names[s] or ("Slot " .. tostring(s))
end

-- Extrae { name, itemID, quality, ilvl, icon } de un link de ítem. El icono
-- viene de GetItemInfo (10.º retorno); si el ítem no está cacheado se intenta
-- GetItemIcon por ID y, en último caso, el hueco de mochila (igual que
-- RD_Module_Loot:SetItem). Devuelve nil si no se pudo extraer ni siquiera un
-- nombre.
function ItemGoals:ItemFromLink(link)
    if not link or link == "" then return nil end
    local itemID = string.match(link, "|Hitem:(%d+):")
    local name, _, quality, ilvl, _, _, _, _, _, icon
    if GetItemInfo then
        name, _, quality, ilvl, _, _, _, _, _, icon = GetItemInfo(link)
    end
    if not name or name == "" then
        name = string.match(link, "%[([^%]]+)%]") or link
    end
    if not icon and itemID and GetItemIcon then
        local ok, tex = pcall(GetItemIcon, tonumber(itemID))
        if ok and tex then icon = tex end
    end
    return {
        name = name,
        itemID = itemID and tonumber(itemID) or nil,
        quality = tonumber(quality) or nil,
        ilvl = tonumber(ilvl) or nil,
        icon = icon or "Interface\\PaperDoll\\UI-Backpack-EmptySlot",
    }
end

-- ============================================================================
-- Persistencia por personaje (bloque "itemGoals.<key>")
-- ============================================================================

-- Carga la tabla de objetivos del personaje actual como copia de trabajo
-- (equip + currency asegurados). Devuelve nil si no hay jugador.
local function LoadGoals()
    local key = ItemGoals:GetKey()
    if key == "" then return nil end
    local t = {}
    if RD.config and RD.config.Get then
        t = RD.config:Get("itemGoals." .. key, {}) or {}
    end
    if type(t) ~= "table" then t = {} end
    if type(t.equip) ~= "table" then t.equip = {} end
    if type(t.currency) ~= "table" then t.currency = {} end
    if type(t.currencyTracked) ~= "table" then t.currencyTracked = {} end
    if type(t.itemTracked) ~= "table" then t.itemTracked = {} end
    if type(t.instancesTracked) ~= "boolean" then t.instancesTracked = false end
    return t, key
end

-- Guarda la copia de trabajo de un personaje (en bloque, patrón RD_Utils_Bands).
local function SaveGoals(t, key)
    if not key or key == "" then return end
    if RD.config and RD.config.Set then
        RD.config:Set("itemGoals." .. key, DeepCopy(t))
    end
end

-- ============================================================================
-- Objetivos de equipamiento (por slot)
-- ============================================================================

function ItemGoals:GetSlotGoal(slot)
    local s = tonumber(slot)
    local t = LoadGoals()
    if not t then return nil end
    return t.equip[s]
end

function ItemGoals:SetSlotGoal(slot, item)
    local s = tonumber(slot)
    if not s or not item or not item.name then return false end
    local t, key = LoadGoals()
    if not t then return false end
    local goal = DeepCopy(item)
    -- Nuevo registro: nunca arranca "hecho" (avisa hasta que se equipe o se quite)
    goal.done = false
    t.equip[s] = goal
    SaveGoals(t, key)
    return true
end

function ItemGoals:ClearSlotGoal(slot)
    local s = tonumber(slot)
    local t, key = LoadGoals()
    if not t or not t.equip[s] then return end
    t.equip[s] = nil
    SaveGoals(t, key)
end

-- Devuelve { [slot] = goal, ... } (solo slots con objetivo)
function ItemGoals:SlotGoals()
    local t = LoadGoals()
    if not t then return {} end
    return DeepCopy(t.equip)
end

-- Marca el objetivo del slot como "done" (p.ej. porque el ítem ya está
-- equipado): deja de avisar cuando caiga en el botín, pero el registro se
-- conserva hasta que el usuario lo quite.
function ItemGoals:MarkSlotDone(slot)
    local s = tonumber(slot)
    local t, key = LoadGoals()
    if not t or not t.equip[s] or t.equip[s].done then return end
    t.equip[s].done = true
    SaveGoals(t, key)
end

-- ============================================================================
-- Coincidencia contra links de botín
-- ============================================================================

-- Coincidencia de un link contra un objetivo registrado: por itemID cuando
-- ambos lo tienen (autoritativo), si no por nombre normalizado.
local function LinkMatches(link, goal)
    if not goal or not link then return false end
    if goal.itemID and goal.itemID > 0 then
        local id = string.match(link, "|Hitem:(%d+):")
        if id and tonumber(id) == goal.itemID then return true end
    end
    local linkName = string.match(link, "%[([^%]]+)%]") or link
    if goal.name and goal.name ~= "" then
        return CleanName(goal.name) == CleanName(linkName)
    end
    return false
end

-- Busca el objetivo (slot) que coincide con un link de botín. Ignora los ya
-- "done" (equipados): no hay que avisar de algo que ya se tiene.
function ItemGoals:MatchLink(link)
    local t = LoadGoals()
    if not t then return nil end
    for slot, goal in pairs(t.equip) do
        if goal and not goal.done and LinkMatches(link, goal) then
            return { slot = tonumber(slot), goal = goal }
        end
    end
    return nil
end

-- Dedup por sesión de botín: un objetivo solo avisa UNA vez por ventana abierta.
-- Se limpia en LOOT_CLOSED (ResetLootSession).
local lootSeen = {}

-- Recorre los links del botín y devuelve los hits NO avisados aún, marcándolos
-- como vistos. `links` es una lista de strings (links de ítem). El resultado es
-- una lista de { slot, goal, link }.
function ItemGoals:ScanLoot(links)
    if type(links) ~= "table" then return {} end
    local hits = {}
    for i = 1, #links do
        local link = links[i]
        if link and not lootSeen[link] then
            local match = self:MatchLink(link)
            if match then
                lootSeen[link] = true
                hits[#hits + 1] = { slot = match.slot, goal = match.goal, link = link }
            end
        end
    end
    return hits
end

-- Limpia el dedup de botín (ventana cerrada).
function ItemGoals:ResetLootSession()
    lootSeen = {}
end

-- ============================================================================
-- Metas de monedas (cantidad objetivo por moneda)
-- ============================================================================

function ItemGoals:GetCurrencyGoal(name)
    local t = LoadGoals()
    if not t or not name then return nil end
    return t.currency[name]
end

function ItemGoals:SetCurrencyGoal(name, target)
    if not name or name == "" then return false end
    local t, key = LoadGoals()
    if not t then return false end
    target = tonumber(target)
    if not target or target <= 0 then
        -- Objetivo no válido = quitar
        t.currency[name] = nil
    else
        local prev = t.currency[name]
        t.currency[name] = { target = target, reached = (prev and prev.reached) or false }
        -- Subir el objetivo resetea el "alcanzado" para poder avisar de nuevo
        if prev and prev.reached and target > (prev.target or 0) then
            t.currency[name].reached = false
        end
    end
    SaveGoals(t, key)
    return true
end

function ItemGoals:ClearCurrencyGoal(name)
    if not name then return end
    local t, key = LoadGoals()
    if not t or not t.currency[name] then return end
    t.currency[name] = nil
    SaveGoals(t, key)
end

-- Devuelve { [nombre] = { target, reached }, ... }
function ItemGoals:CurrencyGoals()
    local t = LoadGoals()
    if not t then return {} end
    return DeepCopy(t.currency)
end

-- ============================================================================
-- Seguimiento de monedas (tooltip del botón "Jugador" de la barra inferior)
-- ============================================================================

-- Activa/desactiva el seguimiento de una moneda. Independiente de la meta: una
-- moneda se puede seguir sin meta (la línea del tooltip muestra solo cantidad).
function ItemGoals:SetCurrencyTracked(name, tracked)
    if not name or name == "" then return false end
    local t, key = LoadGoals()
    if not t then return false end
    if tracked then
        t.currencyTracked[name] = true
    else
        t.currencyTracked[name] = nil
    end
    SaveGoals(t, key)
    return true
end

function ItemGoals:IsCurrencyTracked(name)
    if not name or name == "" then return false end
    local t = LoadGoals()
    return (t and t.currencyTracked and t.currencyTracked[name]) == true
end

-- Devuelve la lista de monedas en seguimiento (orden alfabético, determinista;
-- el tooltip la compone luego en el orden EN VIVO del cliente).
function ItemGoals:TrackedCurrencies()
    local t = LoadGoals()
    local out = {}
    if not t then return out end
    for name, on in pairs(t.currencyTracked or {}) do
        if on and name ~= "" then out[#out + 1] = name end
    end
    table.sort(out)
    return out
end

-- Líneas del tooltip del botón "Jugador": una por moneda seguida, en el orden
-- en vivo del cliente (dinero primero y luego sus categorías). Formato:
--   Nombre: cantidad / meta (faltan X)   · meta pendiente
--   Nombre: cantidad / meta ✓            · meta alcanzada
--   Nombre: cantidad                     · sin meta fijada
-- Una moneda seguida que ya no exista en la lista en vivo se omite (el flag se
-- conserva por si la moneda vuelve). Requiere RD.utils.currencies (resuelto en
-- tiempo de llamada: los RD_Utils_* cargan después de la UI en el .toc).
function ItemGoals:TrackedCurrencyLines()
    local tracked = self:TrackedCurrencies()
    if #tracked == 0 then return {} end
    local cur = RD.utils and RD.utils.currencies
    if not cur or not cur.Collect or not cur.Flatten or not cur.Amount then return {} end
    local goals = self:CurrencyGoals()
    local want, placed = {}, {}
    for _, name in ipairs(tracked) do want[name] = true end
    local lines = {}
    for _, c in ipairs(cur:Flatten(cur:Collect())) do
        if want[c.name] and not placed[c.name] then
            placed[c.name] = true
            local goal = goals[c.name]
            local qty = cur:Amount(c, c.quantity)
            if goal and goal.target then
                local target = cur:Amount(c, goal.target)
                -- "✓" si la cantidad ya llega a la meta (aunque CheckCurrencies aún
                -- no haya marcado reached: el flag gobierna el aviso UNA vez; el
                -- tooltip es solo presentación).
                if goal.reached or (c.quantity or 0) >= (goal.target or 0) then
                    lines[#lines + 1] = c.name .. ": " .. qty .. " / " .. target .. " ✓"
                else
                    local diff = cur:Amount(c, math.max(0, (goal.target or 0) - (c.quantity or 0)))
                    lines[#lines + 1] = c.name .. ": " .. qty .. " / " .. target .. " (faltan " .. diff .. ")"
                end
            else
                lines[#lines + 1] = c.name .. ": " .. qty
            end
        end
    end
    return lines
end

-- ============================================================================
-- Seguimiento de OBJETOS (tooltip del botón "Jugador" de la barra inferior)
-- Se sigue por itemID (los objetivos SIEMPRE guardan itemID: ItemFromLink lo
-- extrae del enlace). El check de seguimiento vive en el panel del ítem
-- seleccionado de la sección Equipamiento (RD_UI_BandsPlayerEditor_Sections_Grids).
-- ============================================================================

-- Activa/desactiva el seguimiento de un ítem por su ID. Independiente de la
-- meta y del slot: solo marca que el ítem se muestre en el tooltip de Jugador.
function ItemGoals:SetItemTracked(itemID, tracked)
    local id = tonumber(itemID)
    if not id or id <= 0 then return false end
    local t, key = LoadGoals()
    if not t then return false end
    if tracked then
        t.itemTracked[id] = true
    else
        t.itemTracked[id] = nil
    end
    SaveGoals(t, key)
    return true
end

function ItemGoals:IsItemTracked(itemID)
    local id = tonumber(itemID)
    if not id or id <= 0 then return false end
    local t = LoadGoals()
    return (t and t.itemTracked and t.itemTracked[id]) == true
end

-- iLvL de un ítem para el ORDEN y la etiqueta del tooltip. Prefiere el valor del
-- objetivo registrado (ya persistido); si no, GetItemInfo(itemID) bajo pcall
-- (3.3.5a acepta el ID numérico; el mismo patrón de ResolveGoalIlvl de Grids).
local function ItemIlvl(id, goalsByItem)
    local g = goalsByItem and goalsByItem[id]
    local ilvl = tonumber(g and g.ilvl) or 0
    if ilvl > 0 then return ilvl end
    if GetItemInfo then
        local ok, _, _, _, lvl = pcall(GetItemInfo, id)
        if ok and lvl then return tonumber(lvl) or 0 end
    end
    return 0
end

-- Devuelve la lista de IDs en seguimiento (orden por iLvL DESCENDENTE, desempate
-- por nombre; los que no se pueden resolver van al final). Determinista para el
-- tooltip.
function ItemGoals:TrackedItems()
    local t = LoadGoals()
    local out = {}
    if not t then return out end
    for id, on in pairs(t.itemTracked or {}) do
        if on and tonumber(id) then out[#out + 1] = tonumber(id) end
    end
    -- Mapa id -> objetivo para el iLvL/nombre y el ✓ de "cumplido".
    local goalsByItem = {}
    for _, g in pairs(t.equip or {}) do
        if g and g.itemID then goalsByItem[tonumber(g.itemID)] = g end
    end
    table.sort(out, function(a, b)
        local ia, ib = ItemIlvl(a, goalsByItem), ItemIlvl(b, goalsByItem)
        if ia ~= ib then return ia > ib end
        local na, nb = (goalsByItem[a] and goalsByItem[a].name) or "", (goalsByItem[b] and goalsByItem[b].name) or ""
        if na ~= nb then return tostring(na) < tostring(nb) end
        return a < b
    end)
    return out
end

-- Líneas del tooltip del botón "Jugador": una por ítem seguido. Formato:
--   Nombre  (iLvL N)        · objetivo vigente
--   Nombre  (iLvL N) ✓      · objetivo cumplido (goal.done)
--   Ítem <id>               · sin resolver (ni objetivo ni caché del cliente)
-- Nombre/iLvL: el objetivo registrado gana (ya persistido); si no, GetItemInfo.
function ItemGoals:TrackedItemLines()
    local tracked = self:TrackedItems()
    if #tracked == 0 then return {} end
    local t = LoadGoals()
    if not t then return {} end
    local goalsByItem = {}
    for _, g in pairs(t.equip or {}) do
        if g and g.itemID then goalsByItem[tonumber(g.itemID)] = g end
    end
    local lines = {}
    for _, id in ipairs(tracked) do
        local g = goalsByItem[id]
        local name = (g and g.name) or nil
        local ilvl = ItemIlvl(id, goalsByItem)
        if (not name or name == "") and GetItemInfo then
            local ok, n = pcall(GetItemInfo, id)
            if ok and n and n ~= "" then name = n end
        end
        if name and name ~= "" then
            local line = name
            if ilvl > 0 then line = line .. "  (iLvL " .. ilvl .. ")" end
            if g and g.done then line = line .. " ✓" end
            lines[#lines + 1] = line
        else
            lines[#lines + 1] = "Ítem " .. id
        end
    end
    return lines
end

-- ============================================================================
-- Seguimiento de INSTANCIAS (check GENERAL de la sección Jugador → Instancias)
-- Un booleano por personaje: controla que el bloque de instancias guardadas
-- (RD_UI_BandsPlayerEditor_Sections_Instances) aparezca en el tooltip del botón
-- "Jugador" y en el del botón de minimapa.
-- ============================================================================

function ItemGoals:SetInstancesTracked(on)
    local t, key = LoadGoals()
    if not t then return false end
    t.instancesTracked = (on == true)
    SaveGoals(t, key)
    return true
end

function ItemGoals:IsInstancesTracked()
    local t = LoadGoals()
    return (t and t.instancesTracked) == true
end

-- Comprueba las cantidades actuales contra las metas: devuelve la lista de
-- metas RECIÉN alcanzadas ({ { name, quantity, target } }) y las marca reached
-- para que el aviso salga UNA sola vez. `list` es una lista de
-- { name = ..., quantity = ... } con las cantidades en vivo.
function ItemGoals:CheckCurrencies(list)
    if type(list) ~= "table" then return {} end
    local t, key = LoadGoals()
    if not t then return {} end
    local hits = {}
    for i = 1, #list do
        local entry = list[i]
        if entry and entry.name and not entry.isHeader then
            local goal = t.currency[entry.name]
            if goal and not goal.reached and goal.target then
                local quantity = tonumber(entry.quantity) or 0
                if quantity >= goal.target then
                    goal.reached = true
                    hits[#hits + 1] = { name = entry.name, quantity = quantity, target = goal.target }
                end
            end
        end
    end
    if #hits > 0 then
        SaveGoals(t, key)
    end
    return hits
end

RD.utils.itemGoals = ItemGoals
return ItemGoals