--[[
    RD_UI_BandsPlayerEditor_Sections_Grids.lua
    PROPÓSITO: Sección de DATOS "Equipamiento" del editor de jugador, presentada
              como REJILLA de iconos ordenada por iLvL DESCENDENTE (el iLvL es
              el rótulo visible bajo cada icono) con tooltips propios por ítem y
              una franja de OBJETIVOS ("meta") por slot. El usuario
              registra el objetivo pegando el ENLACE del ítem (Mayús+clic o
              copia/pega) en un campo linkOnly (RD.ui.widgets:CreateItemSearch);
              el addon avisa por chat local cuando ese ítem cae en SU botín
              (RD_Module_ItemGoalsWatch). Solo uno mismo. Cada objetivo se
              muestra con la silueta gris del SLOT que ocupa (EQUIP_SLOT_ICONS),
              igual que el hueco del equipamiento en la ventana del personaje.
              MAYÚS+CLIC sobre cualquier celda (objetivo o equipado) INSERTA el
              enlace del ítem en el cuadro de chat que el usuario tenga activo
              (comportamiento nativo de WoW: ChatEdit_InsertLink), sin depender
              del canal configurado del addon; el panel inferior muestra el ítem
              seleccionado con texto compacto y un CHECK de seguimiento del
              objetivo para el tooltip de "Jugador".
              También hospeda los HELPERS COMPARTIDOS de ambas secciones de
              rejilla (equip y monedas) y el despachador: la sección "monedas"
              vive en RD_UI_BandsPlayerEditor_Sections_Currencies.lua y se
              invoca desde SectionsGrids:Build.
    API PÚBLICA:
        - RD.ui.playerEditorSectionsGrids:Build(key, container, ed, width, height)
              key ∈ { "equip", "monedas" }  (width/height ya reducidos por el editor)
        - RD.ui.playerEditorSectionsGrids:Keys() -> { "equip", "monedas" }
        - RD.ui.playerEditorSectionsGrids.Helpers   -> helpers compartidos (currencies)
    EVENTOS consumidos: CURRENCY_REFRESHED (refresca la sección abierta).
]]

local addonName, private = ...
local RD = _G.RaidDominion or {}
_G.RaidDominion = RD

RD.ui = RD.ui or {}
local SectionsGrids = {}

-- ===== Constantes (grid 4px) =====

local EQUIP_SLOTS = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19 }

-- Contrato de métricas compartido (RD_UI_Utils.Metrics, grid 4px de AGENTS §6).
-- Un único lugar para gutters, altos de control y geometría del panel inferior.
local Metrics = (RD.UIUtils and RD.UIUtils.Metrics) or {
    GRID = 4, PAD = 4, ACTION_X = 14, INPUT_H = 24, ACTION_H = 24, CHIP_H = 24,
    PANEL_H = 116, PANEL_TITLE_Y = -8, PANEL_LINE1_Y = -28, PANEL_LINE_PITCH = 20,
    TRACK_S = 20, TRACK_GAP = 4, ROW_PITCH = 28, LIST_LINE_H = 16,
}
local PAD = Metrics.PAD or 4
-- Panel inferior fijo (sin saltos de layout). 116 px = título + 3 líneas de
-- info (pitch 20) + fila de acción (24 px) + 4 px de inset. El alto sale de
-- Metrics, nunca de un literal suelto (evita solapes con el scroll: en Monedas
-- había un PANEL_H local distinto y las últimas filas quedaban tapadas).
local PANEL_H = Metrics.PANEL_H or 116
local HEADER_H = 20        -- cabecera de la sección (iLvL medio)

-- Nombre único para frames con template (UICheckButtonTemplate requiere un
-- nombre propio para generar sus texturas $parent...; igual que en Monedas).
local UniqueName = (RD.UIUtils and RD.UIUtils.UniqueName)
    or function(prefix) return "RD" .. tostring(prefix) end

local function QualityColor(q)
    return (RD.constants and RD.constants.ITEM_QUALITY_COLORS and RD.constants.ITEM_QUALITY_COLORS[q])
        or { 1, 1, 1 }
end

-- Trunca un string contando CARACTERES UTF-8 (no bytes: los nombres son esMX).
local function Truncate(text, max)
    local s = tostring(text or "")
    if max <= 0 then return "" end
    local n = #s
    local count = 0
    local i = 1
    while i <= n and count < max do
        local b = s:byte(i)
        local len
        if b < 0x80 then len = 1
        elseif b < 0xE0 then len = 2
        elseif b < 0xF0 then len = 3
        elseif b < 0xF8 then len = 4
        else len = 1 end
        i = i + len
        count = count + 1
    end
    if i <= n then return s:sub(1, i - 1) .. "…" end
    return s
end

-- Trunca `text` para que quepa en `width` con una fuente de `fontSize` px. Usa
-- el helper central de UIUtils cuando existe (medición heurística UTF-8); en su
-- ausencia cae al conteo de caracteres local (mismo resultado, fallback harness).
local TruncateToWidth = (RD.UIUtils and RD.UIUtils.TruncateToWidth)
    or function(text, width, fontSize)
        local size = tonumber(fontSize) or 12
        return Truncate(text, math.max(1, math.floor((tonumber(width) or 0) / (size * 0.55))))
    end

-- ===== Limpieza y helpers de render =====

-- Oculta (y reparenta a nil) los frames del render anterior; los FontString
-- solo se ocultan (no aceptan SetParent(nil)).
local function CleanExtras(container)
    for _, extra in ipairs(container.rdGridExtras or {}) do
        if extra.Hide then extra:Hide() end
        -- La barra del ScrollFrame se crea como hija del CONTENEDOR (no del
        -- scroll: CreateScrollFrame la ancla a scroll:TOPRIGHT con parent);
        -- sin limpiarla, cada rebuild acumulaba una barra visible duplicada.
        if extra.scrollBar and extra.scrollBar.Hide then extra.scrollBar:Hide() end
        if extra.GetObjectType and extra:GetObjectType() ~= "FontString" then
            extra:SetParent(nil)
        end
        if extra.scrollBar and extra.scrollBar.SetParent then extra.scrollBar:SetParent(nil) end
    end
    container.rdGridExtras = {}
end

local function Track(container, frame)
    container.rdGridExtras[#container.rdGridExtras + 1] = frame
end

-- FontString de línea dentro de un panel inferior (justificado a la izquierda).
-- Margen lateral 6 px para no rozar el borde del recuadro del panel.
local function PanelText(panel, y, size)
    local fs = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetJustifyH("LEFT")
    fs:SetTextHeight(size)
    fs:SetPoint("TOPLEFT", panel, "TOPLEFT", 6, y)
    return fs
end

-- Panel inferior fijo (alto reservado: el layout no salta; se ancla abajo).
-- Lleva un RECUADRO (borde) para agrupar la info del ítem/moneda seleccionado
-- y la fila de "agregar objetivo"; el contenido queda con aire por los lados.
-- `panelH` se pasa explícito para que el scroll de cada sección calcule su alto
-- contra el MISMO valor que usa el panel (regresión del solape en Monedas).
local function MakePanel(container, width, height, panelH)
    panelH = panelH or PANEL_H
    local panel = CreateFrame("Frame", nil, container)
    panel:SetSize(width, panelH)
    panel:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -(height - panelH))
    panel:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    panel:SetBackdropColor(0, 0, 0, 0.55)
    panel:SetBackdropBorderColor(1, 1, 1, 0.35)
    Track(container, panel)
    return panel
end

-- Mensaje de una línea (selfOnly, sin datos, etc.)
local function ShowMessage(container, width, text, color)
    local fs = container:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetJustifyH("LEFT")
    fs:SetTextHeight(12)
    fs:SetText(text)
    fs:SetTextColor(color[1], color[2], color[3])
    fs:SetPoint("TOPLEFT", container, "TOPLEFT", 4, 0)
    fs:SetWidth(width - 8)
    fs:SetWordWrap(true)
    Track(container, fs)
end

-- ScrollFrame + contenido (la barra queda en el gutter que ya reservó el editor).
-- `inset` es el margen vertical del tope de la barra respecto del scroll: en las
-- secciones con panel se pasa 0 para que la barra no se meta por debajo del
-- recuadro (que se dibuja encima y la recortaría asimétricamente).
local function MakeScroll(container, width, height, top, inset)
    local widgets = RD.ui and RD.ui.widgets
    local createScroll = widgets and widgets.CreateScrollFrame
    local scroll, content
    if createScroll then
        -- SIN dos puntos: CreateScrollFrame es función plana (no método); `:` le
        -- inyectaría la tabla de widgets como parent (bug de secciones vacías).
        scroll, content = createScroll(container, width, height, 0, -top, inset)
    else
        scroll = CreateFrame("ScrollFrame", nil, container)
        scroll:SetSize(width, height)
        scroll:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -top)
        content = CreateFrame("Frame", nil, scroll)
        content:SetWidth(width)
        scroll:SetScrollChild(content)
    end
    Track(container, scroll)
    return scroll, content
end

local function GetGoals()
    return RD.utils and RD.utils.itemGoals
end

-- Icono del slot (silueta gris del paperdoll). Se prefiere la API del cliente
-- GetInventorySlotInfo("HeadSlot") que devuelve (id, texture, checkRelic): la
-- textura ES la del paperdoll de 3.3.5a (nunca "?"). EXCEPCIÓN: el slot de
-- espalda/capa (15) no tiene textura propia en el cliente — reutiliza la del
-- pecho (GetInventorySlotInfo("BackSlot") == "UI-PaperDoll-Slot-Chest"), lo que
-- se ve DUPLICADO. Se le asigna la capa INV_Misc_Cape_10 (la que usa Carbonite
-- 3.3.5a para Back) para distinguirla. Fallback a EQUIP_SLOT_ICONS (harness).
local EQUIP_SLOT_TOKENS = {
    [0] = "AmmoSlot", [1] = "HeadSlot", [2] = "NeckSlot", [3] = "ShoulderSlot",
    [4] = "ShirtSlot", [5] = "ChestSlot", [6] = "WaistSlot", [7] = "LegsSlot",
    [8] = "FeetSlot", [9] = "WristSlot", [10] = "HandsSlot", [11] = "Finger0Slot",
    [12] = "Finger1Slot", [13] = "Trinket0Slot", [14] = "Trinket1Slot",
    [15] = "BackSlot", [16] = "MainHandSlot", [17] = "SecondaryHandSlot",
    [18] = "RangedSlot", [19] = "TabardSlot",
}
local BACK_SLOT_ICON = "Interface\\Icons\\INV_Misc_Cape_10"
local function SlotIcon(slot)
    if slot == 15 then
        return BACK_SLOT_ICON
    end
    if GetInventorySlotInfo then
        local token = EQUIP_SLOT_TOKENS[slot]
        if token then
            local ok, id, tex = pcall(GetInventorySlotInfo, token)
            if ok and tex and tex ~= "" then return tex end
        end
    end
    local icons = (RD.constants and RD.constants.EQUIP_SLOT_ICONS) or {}
    return icons[slot] or "Interface\\PaperDoll\\UI-Backpack-EmptySlot"
end

-- ===== Equipamiento EN VIVO (con iconos, id y link) =====

local function CollectLiveEquipment()
    local items = {}
    local ilvlSum, ilvlCount = 0, 0
    for _, slot in ipairs(EQUIP_SLOTS) do
        local link = (GetInventoryItemLink and GetInventoryItemLink("player", slot)) or nil
        if link then
            local itemID = string.match(link, "|Hitem:(%d+):")
            local name, _, quality, ilvl, _, _, _, _, _, icon
            if GetItemInfo then
                name, _, quality, ilvl, _, _, _, _, _, icon = GetItemInfo(link)
            end
            name = name or string.match(link, "%[([^%]]+)%]") or ("Slot " .. tostring(slot))
            if not icon and itemID and GetItemIcon then
                local ok, tex = pcall(GetItemIcon, tonumber(itemID))
                if ok and tex then icon = tex end
            end
            items[#items + 1] = {
                slot = slot, name = name,
                itemID = itemID and tonumber(itemID) or nil,
                quality = tonumber(quality), ilvl = tonumber(ilvl),
                icon = icon or "Interface\\PaperDoll\\UI-Backpack-EmptySlot",
                link = link,
            }
            if ilvl then
                ilvlSum = ilvlSum + ilvl
                ilvlCount = ilvlCount + 1
            end
        end
    end
    table.sort(items, function(a, b) return a.slot < b.slot end)
    return items, (ilvlCount > 0 and math.floor(ilvlSum / ilvlCount + 0.5) or 0)
end

-- Enlace de ítem de una celda para INSERTAR en el chat (Mayús+clic). Prioridad:
--   1) el enlace EN VIVO (el equipado lo guarda CollectLiveEquipment, con sus
--      sufijos aleatorios/enjoyos);
--   2) GetItemInfo(itemID) (2.º retorno), bajo pcall: los OBJETIVOS se guardan
--      sin link (solo itemID) y 3.3.5a acepta el ID numérico;
--   3) fallback construido con el nombre conocido (objetivo legacy sin caché).
-- Devuelve nil solo si no hay ni ID ni nombre con qué construir el enlace.
local function CellLink(cell)
    if not cell then return nil end
    if cell.link and cell.link ~= "" then return cell.link end
    local id = tonumber(cell.itemID)
    if id and GetItemInfo then
        local ok, name, link = pcall(GetItemInfo, id)
        if ok and link and link ~= "" then return link end
        if ok and name and name ~= "" and (not cell.name or cell.name == "") then
            cell.name = name
        end
    end
    local name = cell.name or (id and ("Ítem " .. id)) or nil
    if id and name then
        return "|Hitem:" .. id .. ":0:0:0:0:0:0:0|h[" .. name .. "]|h"
    end
    return nil
end

-- ===== Sección EQUIPAMIENTO: rejilla por iLvL + franja de objetivos + panel =====

-- iLvL del objetivo. Los registrados antes de persistir `ilvl` guardan itemID
-- pero no iLvL: se resuelve en LECTURA con GetItemInfo(itemID) (3.3.5a acepta el
-- ID numérico) bajo pcall, para no romper el build si el cliente no lo conoce.
-- Devuelve 0 si no se sabe (badge oculto y al final del orden).
local function ResolveGoalIlvl(g)
    local ilvl = tonumber(g and g.ilvl) or 0
    if ilvl > 0 then return ilvl end
    if g and g.itemID and GetItemInfo then
        local ok, _, _, _, lvl = pcall(GetItemInfo, tonumber(g.itemID))
        if ok and lvl then return tonumber(lvl) or 0 end
    end
    return 0
end

local function BuildGoalGroup(groups, slotGoals, goals, selCell)
    local list = {}
    for slot in pairs(slotGoals) do
        local s = tonumber(slot)
        if s then list[#list + 1] = { slot = s, goal = slotGoals[slot] } end
    end
    if #list == 0 then return end

    -- Orden: iLvL DESCENDENTE (mismo criterio que el grupo Equipamiento); los
    -- objetivos sin iLvL (legacy) van al final y entre iguales se desempata por
    -- slot. El badge de cada celda muestra ese iLvL sobre el icono.
    table.sort(list, function(a, b)
        local ia, ib = ResolveGoalIlvl(a.goal), ResolveGoalIlvl(b.goal)
        if ia ~= ib then return ia > ib end
        return a.slot < b.slot
    end)

    local items = {}
    for _, e in ipairs(list) do
        local slot, g = e.slot, e.goal
        local slotName = (goals and goals.SlotLabel and goals:SlotLabel(slot)) or ("Slot " .. tostring(slot))
        local lineColor = g.done and { 0, 1, 0 } or { 1, 1, 1 }
        local key = "goal" .. slot
        local ilvl = ResolveGoalIlvl(g)
        items[#items + 1] = {
            key = key,
            slot = slot,
            itemID = g.itemID,
            name = g.name,
            icon = SlotIcon(slot),
            -- La capa de espalda es un icono de ítem en color; se desatura a gris
            -- para que quede como las siluetas del paperdoll de los demás slots.
            desaturated = (slot == 15),
            borderColor = g.done and { 1, 0.82, 0 } or QualityColor(g.quality),
            selected = (key == selCell),
            -- Badge iLvL sobre el icono (solo si se conoce; legacy → oculto).
            label = (ilvl > 0) and tostring(ilvl) or nil,
            tooltip = {
                { text = "Objetivo: " .. (g.name or "?"), 1, 0.82, 0 },
                { text = slotName .. (ilvl > 0 and (" · iLvL " .. ilvl) or "") .. (g.done and " · HECHO" or ""), lineColor[1], lineColor[2], lineColor[3] },
                { text = "Clic izq.: gestionar · Clic der.: quitar", 0.7, 0.7, 0.7 },
                { text = "Mayús+clic: insertar el enlace en el chat", 0.7, 0.7, 0.7 },
            },
        }
    end
    groups[#groups + 1] = { title = "Objetivos (" .. #items .. ")", color = { 1, 0.82, 0 }, items = items }
end

-- Grupo único de equipamiento ordenado por iLvL DESCENDENTE (de mayor a menor)
-- con el iLvL como BADGE sobre el icono (cell.label). El tooltip conserva el
-- nombre del ítem, su slot y la calidad del borde.
local function BuildQualityGroups(groups, items, goals, selCell)
    if #items == 0 then return end
    local sorted = {}
    for _, item in ipairs(items) do sorted[#sorted + 1] = item end
    table.sort(sorted, function(a, b)
        local ia, ib = tonumber(a.ilvl) or -1, tonumber(b.ilvl) or -1
        if ia ~= ib then return ia > ib end
        return (a.slot or 0) < (b.slot or 0)
    end)

    local cells = {}
    for _, item in ipairs(sorted) do
        local slotName = (goals and goals.SlotLabel and goals:SlotLabel(item.slot)) or ("Slot " .. tostring(item.slot))
        local qc = QualityColor(item.quality)
        local key = "e" .. item.slot
        cells[#cells + 1] = {
            key = key,
            slot = item.slot,
            itemID = item.itemID,
            name = item.name,
            link = item.link,
            icon = item.icon,
            label = tostring(item.ilvl or "?"),
            borderColor = qc,
            selected = (key == selCell),
            tooltip = {
                { text = item.name, qc[1], qc[2], qc[3] },
                { text = slotName .. " · iLvL " .. tostring(item.ilvl or "?"), 1, 1, 1 },
                { text = "Clic: gestionar objetivo", 1, 0.82, 0 },
                { text = "Mayús+clic: insertar el enlace en el chat", 0.7, 0.7, 0.7 },
            },
        }
    end
    groups[#groups + 1] = {
        title = "Equipamiento (" .. #cells .. ")",
        color = { 1, 0.82, 0 },
        items = cells,
    }
end

local equipRefresh = nil  -- asignado dentro de BuildEquip (upvalue para la rejilla)

local function BuildEquip(container, ed, width, height)
    CleanExtras(container)
    local goals = GetGoals()
    local widgets = RD.ui and RD.ui.widgets

    if not ed or not ed.isSelf then
        ShowMessage(container, width, "Solo visible para tu propio personaje.", { 0.7, 0.7, 0.7 })
        return
    end

    local items, avg = CollectLiveEquipment()

    -- Objetivos cumplidos (el ítem ya está equipado): dejan de avisar.
    if goals and goals.MarkSlotDone then
        for _, item in ipairs(items) do
            if item.link then
                local m = goals:MatchLink(item.link)
                if m and m.slot then goals:MarkSlotDone(m.slot) end
            end
        end
    end

    local slotGoals = (goals and goals.SlotGoals and goals:SlotGoals()) or {}

    -- Cabecera: iLvL medio + nº de objetos (sin repetir "Equipamiento": ya está
    -- en el título de la ventana y en el grupo de la rejilla).
    local header = container:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    header:SetJustifyH("LEFT")
    header:SetTextColor(1, 0.82, 0)
    if RD.UIUtils and RD.UIUtils.ApplyFontStyle then
        RD.UIUtils.ApplyFontStyle(header, "sectionTitle")
    end
    header:SetText("iLvL medio " .. tostring(avg or "?") .. " · " .. #items .. " objetos")
    header:SetPoint("TOPLEFT", container, "TOPLEFT", PAD, 0)
    Track(container, header)

    local scrollH = math.max(40, height - HEADER_H - PANEL_H)
    local scroll, content = MakeScroll(container, width, scrollH, HEADER_H, 0)

    if not widgets or not widgets.CreateItemGrid then
        ShowMessage(container, width, "Rejilla no disponible.", { 0.8, 0.4, 0.4 })
        return
    end

    -- Selección persistente entre rebuilds (contenedor.rdSelSlot / rdSelCell).
    local sel = { slot = container.rdSelSlot or nil, cell = container.rdSelCell or nil }

    local grid = widgets:CreateItemGrid(content, {
        width = width,
        onSelect = function(cell)
            sel.slot = cell.slot
            sel.cell = cell.key
            container.rdSelSlot = cell.slot
            container.rdSelCell = cell.key
            if grid and grid.SetSelected then grid:SetSelected(cell.key) end
            if equipRefresh then equipRefresh(cell.slot) end
        end,
        onRightSelect = function(cell)
            if cell.slot and goals then
                goals:ClearSlotGoal(cell.slot)
                BuildEquip(container, ed, width, height)
            end
        end,
        onShareLink = function(cell)
            local link = CellLink(cell)
            if not link then
                local mm = RD.messageManager
                if mm and mm.SendSystemMessage then
                    mm:SendSystemMessage("|cffff8000[RaidDominion]|r No se pudo resolver el enlace de este ítem.")
                end
                return
            end
            -- INSERCIÓN en el chat activo (comportamiento NATIVO de Mayús+clic):
            -- ChatEdit_InsertLink mete el enlace en el cuadro de chat que el
            -- usuario tenga ABIERTO y enfocado (el que activó con Enter), NO en
            -- el canal configurado del addon. El global ya está envuelto por
            -- RD_UI_Utils_LinkInsert: si un EditBox del addon está enfocado lo
            -- usa, y si no, deriva al ChatEdit_InsertLink original (chat real).
            if type(ChatEdit_InsertLink) == "function" then
                ChatEdit_InsertLink(link)
            end
        end,
    })
    if not grid then
        ShowMessage(container, width, "Rejilla no disponible.", { 0.8, 0.4, 0.4 })
        return
    end
    grid:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
    Track(container, grid)

    local groups = {}
    BuildGoalGroup(groups, slotGoals, goals, sel.cell)
    BuildQualityGroups(groups, items, goals, sel.cell)

    grid:SetGroups(groups)
    -- Restaura la celda seleccionada tras el rebuild (afordancia de selección).
    if grid.SetSelected then grid:SetSelected(sel.cell) end
    content:SetHeight(grid:GetContentHeight())
    if scroll.UpdateScrollChildRect then scroll:UpdateScrollChildRect() end

    -- ----- Panel inferior fijo: info del ítem seleccionado + agregar objetivo -----
    local panel = MakePanel(container, width, height, PANEL_H)

    -- Geometría del panel desde Metrics (grid 4px): título + 3 líneas de info
    -- con pitch 20 y la fila de acción anclada abajo.
    local PT, L1, LP = Metrics.PANEL_TITLE_Y, Metrics.PANEL_LINE1_Y, Metrics.PANEL_LINE_PITCH
    local lineW = math.max(40, width - 2 * PAD - 2)

    -- Bloque de INFORMACIÓN del ítem seleccionado (orden: slot, equipado,
    -- objetivo). PanelText fija el tamaño FINAL en px (sin doble escalado con
    -- ApplyFontStyle: ya no se aplica aquí — ese doble scaling dejaba el panel
    -- a 22/16 px en vez de los 13/11 pedidos). Margen sup. para el recuadro.
    local title = PanelText(panel, PT, 13)
    title:SetTextColor(1, 0.82, 0)
    local line = PanelText(panel, L1, 11)
    line:SetWidth(lineW)
    -- La línea del OBJETIVO reserva a la derecha el gutter del check de
    -- seguimiento (TRACK_S + 2*TRACK_GAP = 28, múltiplo de 4) para no solaparse.
    local TRACK_S = Metrics.TRACK_S or 20
    local TRACK_GAP = Metrics.TRACK_GAP or 4
    local statusW = math.max(40, lineW - TRACK_S - 2 * TRACK_GAP)
    local status = PanelText(panel, L1 - LP, 11)
    status:SetWidth(statusW)
    -- Pista de descubrimiento del check (banda vertical libre del panel tras
    -- reducir los textos: -68 a -88 queda a 10px de la fila de acción).
    local hint = PanelText(panel, L1 - 2 * LP, 10)
    hint:SetWidth(lineW)
    hint:SetText((RD.UIUtils and RD.UIUtils.TrackHint and RD.UIUtils.TrackHint()) or "Aparece en el tooltip del botón Jugador de la barra inferior.")
    hint:SetTextColor(0.6, 0.6, 0.6)

    -- Check de seguimiento del OBJETIVO (decisión UX: un solo check, el de la
    -- meta del slot). 20x20, anclado a la derecha de la línea de estado,
    -- centrado verticalmente en el texto. El estado lo muestra el propio check;
    -- el toggle NO reconstruye el panel (respeta scroll y selección).
    local track = CreateFrame("CheckButton", UniqueName("TrackObj"), panel, "UICheckButtonTemplate")
    track:SetSize(TRACK_S, TRACK_S)
    track:SetPoint("LEFT", status, "RIGHT", TRACK_GAP, 0)
    track:SetChecked(false)
    track:SetScript("OnClick", function(self)
        local checked = self:GetChecked()
        local value = (checked == true) or (checked == 1)
        local id = self.rdItemID
        if id and goals and goals.SetItemTracked then
            goals:SetItemTracked(id, value)
        end
    end)
    track:SetScript("OnEnter", function(self)
        if not self.rdName then return end
        if RD.UIUtils and RD.UIUtils.TooltipsEnabled and not RD.UIUtils.TooltipsEnabled() then return end
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("Seguimiento", 1, 0.82, 0, 1)
        GameTooltip:AddLine("Mostrar «" .. tostring(self.rdName) .. "» en el tooltip del botón Jugador.", 1, 1, 1, 1)
        GameTooltip:Show()
    end)
    track:SetScript("OnLeave", function()
        if GameTooltip then GameTooltip:Hide() end
    end)
    track:Hide()
    Track(container, track)

    -- Fila de ACCIÓN "agregar objetivo" (campo de enlace + Registrar/Quitar).
    local search = (widgets and widgets.CreateItemSearch) and widgets:CreateItemSearch(panel, {
        width = 160,
        placeholder = "Enlace objetivo…",
        maxResults = 8,
        linkOnly = true,
        parseLink = function(text)
            return goals and goals.ItemFromLink and goals:ItemFromLink(text) or nil
        end,
        onPick = function(entry)
            if sel.slot and goals and goals.SetSlotGoal and entry and entry.name then
                goals:SetSlotGoal(sel.slot, entry)
                BuildEquip(container, ed, width, height)
            end
        end,
    })
    if search then
        search:SetPoint("TOPLEFT", panel, "TOPLEFT", Metrics.ACTION_X, -(PANEL_H - Metrics.ACTION_H - 4))
        Track(container, search)
    end

    local regBtn = RD.UIUtils.MakeChipButton(panel, nil, 80, Metrics.CHIP_H)
    regBtn:SetText("Registrar")
    regBtn:SetPoint("LEFT", search, "RIGHT", 6, 0)
    local clearBtn = RD.UIUtils.MakeChipButton(panel, nil, 72, Metrics.CHIP_H)
    clearBtn:SetText("Quitar")
    clearBtn:SetPoint("LEFT", regBtn, "RIGHT", 6, 0)

    local equippedByName = {}
    for _, item in ipairs(items) do equippedByName[item.slot] = item end

    -- Registrar: requiere un ENLACE de ítem válido en el campo (linkOnly ya
    -- marca en rojo el texto inválido; aquí solo se protege el flujo).
    regBtn:SetScript("OnClick", function()
        if not sel.slot or not goals or not goals.SetSlotGoal then return end
        local entry = search and search.rdSearchFirstMatch and search:rdSearchFirstMatch() or nil
        if not entry or not entry.name then
            if RD.messageManager and RD.messageManager.SendSystemMessage then
                RD.messageManager:SendSystemMessage("|cffff8000[RaidDominion]|r Pega un enlace de ítem válido (Mayús+clic o copia/pega).")
            end
            return
        end
        goals:SetSlotGoal(sel.slot, entry)
        BuildEquip(container, ed, width, height)
    end)

    clearBtn:SetScript("OnClick", function()
        if not sel.slot or not goals or not goals.ClearSlotGoal then return end
        goals:ClearSlotGoal(sel.slot)
        BuildEquip(container, ed, width, height)
    end)

    equipRefresh = function(slot)
        sel.slot = slot
        if search then search.rdSearchClear() end
        if not slot then
            title:SetText("Selecciona un ícono")
            line:SetTextColor(0.7, 0.7, 0.7)
            line:SetText("Clic en un ítem de la rejilla para gestionar su objetivo.")
            status:SetText("")
            track.rdItemID = nil
            track.rdName = nil
            track:Hide()
            regBtn:Disable()
            clearBtn:Disable()
            return
        end
        local slotName = (goals and goals.SlotLabel and goals:SlotLabel(slot)) or ("Slot " .. tostring(slot))
        local equipped = equippedByName[slot]
        local goal = goals and goals.GetSlotGoal and goals:GetSlotGoal(slot)

        title:SetText(TruncateToWidth(slotName, lineW, 13))
        if equipped then
            local qc = QualityColor(equipped.quality)
            line:SetTextColor(qc[1], qc[2], qc[3])
            line:SetText(TruncateToWidth(equipped.name .. (equipped.ilvl and ("  (iLvL " .. equipped.ilvl .. ")") or ""), lineW, 11))
        else
            line:SetTextColor(0.7, 0.7, 0.7)
            line:SetText("Sin ítem equipado en este slot.")
        end

        if goal then
            -- El objetivo se muestra SIEMPRE con su nombre (el usuario necesita
            -- ver qué ítem fijó al seleccionar el slot). ÚNICA excepción: si ese
            -- objetivo ES el ítem equipado, el nombre ya está en la línea de
            -- arriba (equipped.name) y no se repite aquí → solo estado.
            local goalName = goal.name or "?"
            if equipped and equipped.name == goalName then
                status:SetTextColor(0.7, 0.7, 0.7)
                status:SetText(goal.done and "Objetivo HECHO ✓" or "Objetivo fijado ✓")
            else
                local qc = QualityColor(goal.quality)
                status:SetTextColor(qc[1], qc[2], qc[3])
                status:SetText(TruncateToWidth("Objetivo: " .. goalName .. (goal.done and " · HECHO" or ""), statusW, 11))
            end
            -- Check de seguimiento: visible solo si el objetivo tiene itemID
            -- (los legacy sin ID no se pueden seguir por ID) y sincronizado con
            -- el flag persistido, SIN reconstruir el panel.
            local trackID = tonumber(goal.itemID)
            if trackID then
                track.rdItemID = trackID
                track.rdName = goal.name
                track:SetChecked(goals and goals.IsItemTracked and goals:IsItemTracked(trackID) == true or false)
                track:Show()
            else
                track.rdItemID = nil
                track.rdName = nil
                track:Hide()
            end
        else
            status:SetTextColor(0.7, 0.7, 0.7)
            status:SetText("Sin objetivo.")
            track.rdItemID = nil
            track.rdName = nil
            track:Hide()
        end

        if goal then clearBtn:Enable() else clearBtn:Disable() end
        if goals and goals.SetSlotGoal then regBtn:Enable() else regBtn:Disable() end
    end

    equipRefresh(sel.slot)
end

-- ==== Refresco de la sección abierta ante los eventos del watcher ====

-- Refresca la sección `key` si está abierta; en monedas, no pisa el EditBox
-- mientras el usuario escribe la meta.
local function RefreshOpenSection(key)
    local pe = RD.ui and RD.ui.playerEditor
    if not pe or not pe.GetFrame then return end
    local ed = pe:GetFrame()
    if not ed or not ed.IsShown or not ed:IsShown() or not ed.SwitchTo then return end
    if ed.openSection ~= key then return end
    if key == "monedas" then
        local box = SectionsGrids.currencyEditBox
        if box and box.HasFocus and box:HasFocus() then return end
    end
    ed:SwitchTo(key)
end

if RD.events and RD.events.Subscribe then
    RD.events:Subscribe("CURRENCY_REFRESHED", function()
        RefreshOpenSection("monedas")
    end)
end

-- ==== API pública ====

function SectionsGrids:Keys()
    return { "equip", "monedas" }
end

-- Helpers compartidos con la sección de monedas (RD_UI_BandsPlayerEditor_Sections_Currencies).
SectionsGrids.Helpers = {
    CleanExtras = CleanExtras,
    Track = Track,
    PanelText = PanelText,
    MakePanel = MakePanel,
    MakeScroll = MakeScroll,
    ShowMessage = ShowMessage,
    Truncate = Truncate,
    TruncateToWidth = TruncateToWidth,
    GetGoals = GetGoals,
    -- Métricas compartidas (grid 4px): el contrato que consumen las secciones.
    Metrics = Metrics,
    PANEL_H = PANEL_H,
    PAD = PAD,
}

-- Construye la sección `key` dentro de `container`. Recibe width/height ya
-- reducidos (el editor resta el SCROLL_GUTTER); sin ellos, ancho del cuerpo.
function SectionsGrids:Build(key, container, ed, width, height)
    width = width or ((container and container:GetWidth()) or 396) - 24
    if width < 8 then width = 372 end
    height = height or (container and container:GetHeight()) or 300

    if key == "monedas" then
        local cur = RD.ui and RD.ui.playerEditorSectionsCurrencies
        if cur and cur.Build then
            cur:Build(container, ed, width, height)
        end
        return
    end
    if key == "equip" then
        BuildEquip(container, ed, width, height)
    end
end

RD.ui.playerEditorSectionsGrids = SectionsGrids
return SectionsGrids