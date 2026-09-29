--[[
    RD_UI_ConfigWindow_Tabs.lua
    PROPÓSITO: Fila de pestañas SUPERIORES de la ventana de configuración
              (diseño previo a la tira de iconos, commit 2a3218a^): chips dorados
              con ancho PROPORCIONAL al texto (mín. TAB_MIN_WIDTH) y gap de 1px.
              El orden VISUAL de la fila es: General, las 7 pestañas con
              contraparte en el menú flotante (Bandas, Habilidades, Roles, Buffs,
              Auras, Mecánicas, Reglas) en el orden EFECTIVO de ui.menu.itemOrder,
              y Ayuda. Cada pestaña reordenable lleva un agarre LATERAL (grip):
              arrastrándolo se REORDENA la propia fila superior Y se refleja en el
              menú flotante (misma clave ui.menu.itemOrder). Las pestañas se
              reposicionan en sitio (sin reconstruir frames ni suscriptores).
              También registra las zonas de soltado del arrastre cross-list
              (roles/abilities/buffs/auras) sobre los chips.
    API PÚBLICA (adjunta a RD.ui.configWindow):
        - ConfigWindow:BuildTabRow(frame)
        - ConfigWindow:ReorderableMenuIds()  -- ids reordenables (orden por defecto)
        - ConfigWindow:EffectiveMenuOrder()  -- orden efectivo (guardado o default)
        - ConfigWindow:EffectiveVisualTabOrder() -- ids de la fila en orden visual
        - ConfigWindow:ReorderTopBar()       -- reposiciona los chips al orden efectivo
        - ConfigWindow:CommitTabReorder(draggedId, target)
    EVENTOS: El commit publica CONFIG_CHANGED("ui.menu.itemOrder") (re-ordena la
             fila y refresca el menú flotante).
]]

local addonName, private = ...
local RD = _G.RaidDominion or {}
_G.RaidDominion = RD

local ConfigWindow = RD.ui and RD.ui.configWindow
if not ConfigWindow then
    ConfigWindow = {}
    RD.ui = RD.ui or {}
    RD.ui.configWindow = ConfigWindow
end

-- Constantes de geometría (enteros, múltiplos del grid 4px; espejo del archivo
-- principal RD_UI_ConfigWindow.lua, cuyo CONTENT_TOP (-72) deja sitio a esta
-- fila de 32px bajo la barra de título de 28px).
local TAB_HEIGHT = 32            -- alto de pestaña estilo personaje (v2)
local TAB_GAP = 4                -- margin-x entre pestañas (grid 4px)
local TAB_TEXT_PAD = 8           -- padding-x del texto dentro del chip (aire al borde)
local TAB_MIN_WIDTH = 52         -- ancho mínimo de pestaña
local TAB_ROW_Y = -34            -- offset Y de la fila de pestañas (bajo el título)
local GRIP_SIZE = 12             -- agarre lateral compacto (arrastre de reorden)
local GRIP_GAP = 4               -- separación grip-chip (grid 4px)
-- Presupuesto de ancho: la fila se ancla a la izquierda del frame (offset 8) y
-- debe caber en el contenido (800px). Con los valores actuales la fila ocupa
-- ≈ 640-700px en runtime (los grips de las 7 pestañas reordenables suman 14px
-- cada uno), así que entra holgada sin recortar ni hacer scroll lateral.
local GOLD_R, GOLD_G, GOLD_B = unpack((RD.constants and RD.constants.COLORS and RD.constants.COLORS.GOLD) or { 1, 0.82, 0 })

-- Ítems del menú flotante (MainFrameOptions) con pestaña propia en el
-- CONFIG_SCHEMA, en el orden POR DEFECTO = orden del esquema (la fila superior):
-- bands, abilities, roles, buffs, auras, mechanics, rules. Es la base sobre la
-- que el usuario reordena y el fallback cuando ui.menu.itemOrder está vacío.
function ConfigWindow:ReorderableMenuIds()
    local mf = RD.ui and RD.ui.menuFactory
    if mf and mf.DefaultMenuOrder then return mf:DefaultMenuOrder() end
    local defs = RD.constants and RD.constants.MENU_DEFINITIONS and RD.constants.MENU_DEFINITIONS.MainFrameOptions
    local schema = RD.constants and RD.constants.CONFIG_SCHEMA
    local ids = {}
    for _, tab in ipairs(schema or {}) do
        if tab.id then
            for _, d in ipairs(defs or {}) do
                if d.id == tab.id then
                    ids[#ids + 1] = d.id
                    break
                end
            end
        end
    end
    return ids
end

-- Orden EFECTIVO de las 7 pestañas reordenables: ui.menu.itemOrder guardado si
-- el usuario ya reordenó, o el orden por defecto.
function ConfigWindow:EffectiveMenuOrder()
    local mf = RD.ui and RD.ui.menuFactory
    if mf and mf.MenuOrder then return mf:MenuOrder() end
    return self:ReorderableMenuIds()
end

-- Orden VISUAL de la fila completa: General (sin contraparte, siempre primero),
-- las 7 reordenables en el orden efectivo, Ayuda (sin contraparte, siempre al
-- final).
function ConfigWindow:EffectiveVisualTabOrder()
    local ids = {}
    for _, t in ipairs(self.tabs or {}) do
        if t.id == "general" then ids[#ids + 1] = t.id break end
    end
    for _, id in ipairs(self:EffectiveMenuOrder()) do
        ids[#ids + 1] = id
    end
    for _, t in ipairs(self.tabs or {}) do
        if t.id == "help" then ids[#ids + 1] = t.id break end
    end
    return ids
end

-- Construye una pestaña chip (MakeChipButton) con ancho ajustado al texto.
local function BuildTabChip(parent, title)
    local btn = RD.UIUtils.MakeChipButton(parent, nil, TAB_MIN_WIDTH, TAB_HEIGHT)
    btn:SetText(title or "")
    local text = btn:GetFontString()
    local textW = (text and text.GetStringWidth and (text:GetStringWidth() or 0)) or 0
    local w = math.max(TAB_MIN_WIDTH, math.floor(textW + 2 * TAB_TEXT_PAD))
    btn:SetSize(w, TAB_HEIGHT)
    btn.rdTabWidth = w
    return btn
end

-- Posiciona chips y grips de la fila según el orden visual EFECTIVO. Es
-- idempotente: lo llama BuildTabRow al crear y ReorderTopBar al cambiar
-- ui.menu.itemOrder (reorden en sitio, sin reconstruir frames ni suscriptores).
function ConfigWindow:PlaceTabs()
    local rowFrame = self.tabRowFrame
    if not rowFrame then return end
    local x = 0
    for _, id in ipairs(self:EffectiveVisualTabOrder()) do
        local cell = self.tabCells and self.tabCells[id]
        if cell and cell.chip then
            if cell.grip then
                cell.grip:ClearAllPoints()
                cell.grip:SetPoint("LEFT", rowFrame, "LEFT", x, 0)
                cell.chip:ClearAllPoints()
                cell.chip:SetPoint("LEFT", rowFrame, "LEFT", x + GRIP_SIZE + GRIP_GAP, 0)
                x = x + GRIP_SIZE + GRIP_GAP
            else
                cell.chip:ClearAllPoints()
                cell.chip:SetPoint("LEFT", rowFrame, "LEFT", x, 0)
            end
            x = x + cell.width + TAB_GAP
        end
    end
    rowFrame:SetWidth(math.max(1, x))
end

-- Reposiciona la fila al orden efectivo (llamado desde CONFIG_CHANGED).
function ConfigWindow:ReorderTopBar()
    self:PlaceTabs()
end

-- Mueve el ítem del menú a la posición `target` en ui.menu.itemOrder (misma
-- clave que usa OrderMainDefs) y publica CONFIG_CHANGED: la fila superior se
-- reposiciona (ReorderTopBar) y el menú flotante se refresca.
function ConfigWindow:CommitTabReorder(draggedId, target)
    local mf = RD.ui and RD.ui.menuFactory
    if not draggedId or not target or not mf or not mf.MoveOrderedId then return end
    local base = self:EffectiveMenuOrder()
    local srcIdx = nil
    for j = 1, #base do
        if base[j] == draggedId then srcIdx = j break end
    end
    if not srcIdx then return end
    if RD.config.Set then
        RD.config:Set("ui.menu.itemOrder", mf:MoveOrderedId(base, srcIdx, target))
    end
end

-- Chips reordenables en el orden VISUAL actual (geometría del drag; el orden
-- cambia en cada reorden, por eso se resuelve en el momento).
function ConfigWindow:ReorderChips()
    local arr = {}
    for _, id in ipairs(self:EffectiveVisualTabOrder()) do
        local cell = self.tabCells and self.tabCells[id]
        if cell and cell.reorderable and cell.chip then
            arr[#arr + 1] = cell.chip
        end
    end
    return arr
end

-- Fila de chips + grips. Se construye una sola vez en Create.
function ConfigWindow:BuildTabRow(frame)
    local widgets = RD.ui and RD.ui.widgets
    if not widgets then return end

    -- Contenedor de la fila: define la geometría del arrastre (GetLeft/GetTop
    -- en el mismo espacio que los chips) y agrupa chips + grips en un solo host.
    local rowFrame = CreateFrame("Frame", nil, frame)
    rowFrame:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, TAB_ROW_Y)
    rowFrame:SetHeight(TAB_HEIGHT)
    self.tabRowFrame = rowFrame

    local schema = (RD.constants and RD.constants.CONFIG_SCHEMA) or {}
    local sortedTabs = (ConfigWindow.SortByOrder and ConfigWindow.SortByOrder(schema)) or schema
    local reorderSet = {}
    for _, id in ipairs(self:ReorderableMenuIds()) do reorderSet[id] = true end

    self.tabs = {}
    self.tabCells = {}

    for i, tab in ipairs(sortedTabs) do
        local chip = BuildTabChip(rowFrame, tab.title)
        local cell = {
            chip = chip,
            grip = nil,
            width = chip.rdTabWidth or TAB_MIN_WIDTH,
            reorderable = reorderSet[tab.id] == true,
        }
        local tabData = { id = tab.id, schema = tab, button = chip }
        self.tabs[i] = tabData
        self.tabCells[tab.id] = cell

        chip:SetScript("OnClick", function()
            self:SelectTab(i)
        end)

        if cell.reorderable then
            local grip = widgets:CreateGrip(rowFrame, GRIP_SIZE, function()
                return "Arrastra para mover '" .. tostring(tab.title or tab.id) .. "' (reordena la fila y el menú flotante)."
            end)
            cell.grip = grip
            tabData.grip = grip

            widgets:EnableRowDrag(grip, {
                mode = "row",
                scroll = rowFrame,
                row = rowFrame,
                child = rowFrame,
                rowH = TAB_HEIGHT,
                source = self:VisualIndex(tab.id),
                itemCount = function() return #self:ReorderChips() end,
                items = function() return self:ReorderChips() end,
                label = tab.title or tab.id,
                commitTarget = function(target)
                    self:CommitTabReorder(tab.id, target)
                end,
            })
        end
    end

    self:PlaceTabs()

    -- Zonas de soltado para el arrastre INTER-LIST (roles/abilities/buffs/auras):
    -- soltar un ítem sobre el chip de otro tab lo TRASLADA a esa lista.
    self.dropZones = {}
    local ASIGNABLES = { roles = true, abilities = true, buffs = true, auras = true }
    for i, tabData in ipairs(self.tabs) do
        if ASIGNABLES[tabData.id] then
            local btn = tabData.button
            local idx = i
            local zones = self.dropZones
            zones[#zones + 1] = {
                key = tabData.id,
                frame = btn,
                hilite = function()
                    if btn.SetBackdropBorderColor then
                        btn:SetBackdropBorderColor(GOLD_R, GOLD_G, GOLD_B, 1)
                        btn:SetBackdropColor(0.18, 0.14, 0.05, 0.85)
                    end
                end,
                unhilite = function()
                    if RD.UIUtils and RD.UIUtils.PaintTabButton then
                        RD.UIUtils.PaintTabButton(btn, (idx == self.currentTab and not self.viewBar))
                    end
                end,
            }
        end
    end
end

-- Índice de un id en el orden visual de los chips reordenables (para el
-- `source` del arrastre; la geometría del modo fila no lo necesita, es fallback).
function ConfigWindow:VisualIndex(id)
    local cell = self.tabCells and self.tabCells[id]
    local chips = self:ReorderChips()
    for j, c in ipairs(chips) do
        if cell and c == cell.chip then return j end
    end
    return 1
end

return ConfigWindow