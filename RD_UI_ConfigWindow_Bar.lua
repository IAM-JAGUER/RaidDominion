--[[
    RD_UI_ConfigWindow_Bar.lua
    PROPÓSITO: Barra inferior de la ventana de configuración: los 11 iconos de
              ACTION_BAR (replica del menú flotante) en un reborde "folder"
              acoplado, CENTRADOS bajo la zona de contenido dinámico. Cada icono
              tiene un agarre (grip) lateral que reordena ui.actionBar.order
              (compartido con la barra del menú flotante, que se actualiza en
              vivo vía UpdateBar). TODOS los iconos son reordenables.
              Los iconos NO ejecutan la acción del botón: cualquier clic (izq o
              der) muestra en la zona de contenido dinámico el PANEL de ajustes
              de ese ítem (definidos por dato en cada ACTION_BAR.ITEMS.panel*).
              El tooltip de cada icono es SOLO el nombre del botón (sin
              indicaciones de sus funciones). La acción real vive únicamente en
              la barra del menú flotante. El título dinámico de la ventana sigue
              al icono activo (SyncTitle, definido en el archivo principal).
    API PÚBLICA (adjunta a RD.ui.configWindow):
        - ConfigWindow:BuildBar(frame)
        - ConfigWindow:RefreshBar()
        - ConfigWindow:SelectBarItem(actionId)
        - ConfigWindow:RenderBarPanel()   -- invocado por Render; devuelve la col
        - ConfigWindow:BarItems()         -- defs de la barra en orden efectivo
        - ConfigWindow:BarCells()         -- celdas en orden visual
    EVENTOS: CONFIG_CHANGED("ui.actionBar.order") -> RefreshBar;
             AUTO_LOOT_STATE_CHANGED -> brillo del icono Auto (ApplyBarButtonActive).
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
-- principal RD_UI_ConfigWindow.lua, cuyo FrameHeight reserva este bloque).
-- La barra queda DENTRO del cuerpo de la ventana: se ancla al BOTTOM con un
-- offset POSITIVO igual al padding inferior estándar (BOTTOM_PADDING), de modo
-- que no sobresale del borde ni deja banda vacía (la ventana abraza el contenido).
-- Estos paddings/márgenes aplican SOLO al folder de la barra de la VENTANA DE
-- CONFIGURACIÓN (la barra del menú flotante mantiene su propia geometría).
local BOTTOM_PADDING = 12
local BAR_HEIGHT = 27            -- alto del icono (ACTION_BAR.BUTTON_SIZE)
local BAR_GAP = 8                -- margin-x entre celdas (grid 8px)
local BAR_PAD_X = 8              -- padding-x del folder
local BAR_PAD_TOP = 6            -- padding superior del folder
local BAR_PAD_BOTTOM = 4         -- padding inferior del folder
local BAR_FOLDER_HEIGHT = BAR_HEIGHT + BAR_PAD_TOP + BAR_PAD_BOTTOM
local GRIP_SIZE = 12             -- agarre lateral compacto
local GRIP_GAP = 4               -- separación grip-icono dentro de la celda
local ROW_HEIGHT = 24
local ROW_SPACING = 8
local COMPACT_CELL_HEIGHT = 48   -- alto de celda del widget compacto (label+editbox)
local CONTENT_WIDTH = 776        -- fallback (en runtime: self.contentWidth)
local PANEL_PAD = 12
local GOLD_R, GOLD_G, GOLD_B = unpack((RD.constants and RD.constants.COLORS and RD.constants.COLORS.GOLD) or { 1, 0.82, 0 })
local DEFAULT_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

-- Alto de fila de un campo del PANEL de un botón según su widget: los campos
-- compactos (label ARRIBA / editbox abajo, p.ej. los temporizadores DBM y el
-- enlace de Discord) necesitan COMPACT_CELL_HEIGHT; el resto (checkbox, slider,
-- dropdown, textbox, botones) cabe en una fila estándar de 28px.
local function PanelFieldHeight(field)
    local t = field.type or "text"
    if t == "textCompact" then return COMPACT_CELL_HEIGHT end
    if t == "slider" or t == "dropdown" or t == "text" or t == "textbox"
        or t == "button" or t == "buttons" then return 28 end
    return ROW_HEIGHT
end

-- Reborde del folder (mismo estilo que la tira de iconos del editor Jugador).
local REBORDE = {
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 8,
    insets = { left = 2, right = 2, top = 2, bottom = 2 },
}

-- Orden de DECLARACIÓN de la barra (los action de ACTION_BAR.ITEMS): base
-- coherente con lo que se ve en pantalla cuando el usuario aún no reordenó.
function ConfigWindow:BarDeclaredOrder()
    local AB = RD.constants and RD.constants.ACTION_BAR
    local order = {}
    for _, it in ipairs((AB and AB.ITEMS) or {}) do
        order[#order + 1] = it.action
    end
    return order
end

-- Defs de la barra en el orden efectivo (ui.actionBar.order, o declaración).
function ConfigWindow:BarItems()
    return self.barItems or {}
end

-- Celdas (grip+icono) en el orden visual actual.
function ConfigWindow:BarCells()
    return self.barCells or {}
end

-- Barra inferior del folder. Se construye una sola vez en Create; RefreshBar
-- reordena las celdas en sitio al cambiar ui.actionBar.order (sin reconstruir).
function ConfigWindow:BuildBar(frame)
    local widgets = RD.ui and RD.ui.widgets
    local menuFactory = RD.ui and RD.ui.menuFactory
    if not widgets or not menuFactory then return end

    local AB = (RD.constants and RD.constants.ACTION_BAR) or {}
    local items = (menuFactory.OrderBarItems and menuFactory:OrderBarItems(AB.ITEMS)) or AB.ITEMS or {}
    self.barItems = items

    local buttonSize = AB.BUTTON_SIZE or 27
    local iconSize = math.max(1, buttonSize - 3)
    local cellW = GRIP_SIZE + GRIP_GAP + buttonSize
    local n = #items
    local width = math.max(1, n * cellW + (n - 1) * BAR_GAP + 2 * BAR_PAD_X)

    local bar = CreateFrame("Frame", nil, frame)
    bar:SetSize(width, BAR_FOLDER_HEIGHT)
    -- Offset POSITIVO en el ancla BOTTOM: la barra queda BOTTOM_PADDING px por
    -- ENCIMA del borde inferior del frame (dentro del cuerpo, sin banda vacía).
    bar:SetPoint("BOTTOM", frame, "BOTTOM", 0, BOTTOM_PADDING)
    bar:SetBackdrop(REBORDE)
    bar:SetBackdropColor(0, 0, 0, 0.85)
    bar:SetBackdropBorderColor(1, 1, 1, 0.5)
    self.barRow = bar

    local cells = {}
    for i, item in ipairs(items) do
        local cell = CreateFrame("Frame", nil, bar)
        cell:SetSize(cellW, BAR_HEIGHT)
        cell:SetPoint("TOPLEFT", bar, "TOPLEFT", BAR_PAD_X + (i - 1) * (cellW + BAR_GAP), -BAR_PAD_TOP)

        -- Icono (botón plano, mismo aspecto que la barra del menú flotante)
        local btn = CreateFrame("Button", nil, cell)
        btn:SetSize(iconSize, iconSize)
        btn:SetPoint("RIGHT", cell, "RIGHT", 0, 0)
        btn:RegisterForClicks("AnyUp")
        btn:SetHighlightTexture("Interface\\Buttons\\UI-Panel-Button-Highlight", "ADD")
        if item.icon then
            local tex = btn:CreateTexture(nil, "ARTWORK")
            tex:SetAllPoints()
            tex:SetTexture(item.icon)
            btn.icon = tex
        end
        -- El icono se re-texturiza al reordenar (cell.rdItem cambia en vivo)
        btn:SetScript("OnClick", function()
            local cw = self -- ConfigWindow (BuildBar es método de la ventana)
            cw:OnBarIconClick(cell.rdItem)
        end)
        if item.activeEvent and menuFactory.ApplyBarButtonActive then
            menuFactory:ApplyBarButtonActive(btn, item.activeEvent)
        end

        -- Énfasis de SELECCIÓN: marco dorado sobre el icono mientras su panel
        -- esté abierto (self.viewBar == action). Es un frame sin mouse (no
        -- captura clics ni bloquea el hover del tooltip) que se pinta en vivo
        -- con PaintBar (sin reconstruir botones).
        local sel = CreateFrame("Frame", nil, cell)
        sel:SetAllPoints(btn)
        sel:SetFrameLevel((cell.GetFrameLevel and cell:GetFrameLevel() or 1) + 5)
        sel:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 8,
            insets = { left = 2, right = 2, top = 2, bottom = 2 },
        })
        sel:SetBackdropColor(0, 0, 0, 0)
        sel:SetBackdropBorderColor(GOLD_R, GOLD_G, GOLD_B, 0.9)
        sel:Hide()
        cell.rdSelected = sel

        -- Agarre lateral del reorden (TODOS los iconos son reordenables)
        local grip = widgets:CreateGrip(cell, GRIP_SIZE, function()
            local it = cell.rdItem
            return "Arrastra para reordenar '" .. tostring((it or item).name or (it or item).action) .. "' en la barra inferior (menú y configuración)."
        end)
        grip:SetPoint("LEFT", cell, "LEFT", 0, 0)

        widgets:EnableRowDrag(grip, {
            mode = "row",
            scroll = bar,
            row = bar,
            child = bar,
            rowH = BAR_HEIGHT,
            source = i,
            itemCount = function() return #cells end,
            items = function() return cells end,
            label = item.name or item.action,
            commitTarget = function(target)
                self:CommitBarReorder(cell.rdItem or item, target)
            end,
        })

        cell.rdItem = item
        cell.rdButton = btn
        -- Tooltip del icono: SOLO el nombre del botón (la ventana de
        -- configuración no ejecuta la acción; la pista de clic izq/der vive en
        -- la barra del menú flotante). Relee cell.rdItem para seguir el orden.
        if RD.UIUtils and RD.UIUtils.AddButtonTooltip then
            RD.UIUtils.AddButtonTooltip(btn, function()
                local it = cell.rdItem
                return (it and it.name) or item.name or item.action or ""
            end)
        end

        cells[#cells + 1] = cell
    end
    self.barCells = cells
    self:PaintBar()

    -- El estado del modo Auto se re-renderiza en vivo si su panel está abierto
    -- (el icono se resalta vía ApplyBarButtonActive; el texto del panel también).
    if RD.events and RD.events.Subscribe then
        RD.events:Subscribe("AUTO_LOOT_STATE_CHANGED", function()
            if self.viewBar == "ActionBarAutoLoot" and self.Render then
                self:Render()
            end
        end)
    end
end

-- Mueve el action de `item` a la posición `target` del orden de la barra
-- (ui.actionBar.order) y publica CONFIG_CHANGED (menú + barra se refrescan).
function ConfigWindow:CommitBarReorder(item, target)
    if not item or not item.action then return end
    local menuFactory = RD.ui and RD.ui.menuFactory
    if not menuFactory or not menuFactory.MoveOrderedId then return end
    local saved = RD.config.Get and RD.config:Get("ui.actionBar.order")
    local base = (type(saved) == "table" and #saved > 0) and saved or self:BarDeclaredOrder()
    local srcIdx = nil
    for j = 1, #base do
        if base[j] == item.action then srcIdx = j break end
    end
    if not srcIdx then return end
    if RD.config.Set then
        RD.config:Set("ui.actionBar.order", menuFactory:MoveOrderedId(base, srcIdx, target))
    end
end

-- Reorden en VIVO de la barra (ui.actionBar.order): reordena las celdas y las
-- reposiciona SIN reconstruir botones ni grips (evita fugas de suscriptores de
-- ApplyBarButtonActive). cell.rdItem se actualiza en cada celda para que el
-- icono, el tooltip y el clic sigan al nuevo ítem.
function ConfigWindow:RefreshBar()
    local menuFactory = RD.ui and RD.ui.menuFactory
    local AB = RD.constants and RD.constants.ACTION_BAR
    if not menuFactory or not AB or not self.barRow then return end
    local ordered = menuFactory:OrderBarItems(AB.ITEMS)
    self.barItems = ordered
    local cells = self.barCells or {}
    local byAction = {}
    for _, cell in ipairs(cells) do
        if cell.rdItem and cell.rdItem.action then byAction[cell.rdItem.action] = cell end
    end
    local buttonSize = AB.BUTTON_SIZE or 27
    local cellW = GRIP_SIZE + GRIP_GAP + buttonSize
    local n = 0
    for _, item in ipairs(ordered) do
        local cell = byAction[item.action]
        if cell then
            n = n + 1
            cell.rdItem = item
            cell:ClearAllPoints()
            cell:SetPoint("TOPLEFT", self.barRow, "TOPLEFT", BAR_PAD_X + (n - 1) * (cellW + BAR_GAP), -BAR_PAD_TOP)
            cell:Show()
            -- Re-texturizar el icono (el orden visual cambió de ítem)
            local btn = cell.rdButton
            if btn and btn.icon and btn.icon.SetTexture then
                btn.icon:SetTexture(item.icon or DEFAULT_ICON)
            end
        end
    end
    self:PaintBar()
end

-- Énfasis de SELECCIÓN de la barra inferior de la config: marco dorado en el
-- icono cuyo panel está abierto (self.viewBar); el resto queda sin marco. Es
-- idempotente y lo llaman BuildBar, SelectBarItem, SelectTab, ClearBarPanel y
-- RefreshBar (tras un reorden, el marco sigue al action, no a la celda).
function ConfigWindow:PaintBar()
    for _, cell in ipairs(self.barCells or {}) do
        local sel = cell and cell.rdSelected
        if sel then
            local action = cell.rdItem and cell.rdItem.action
            if action and action == self.viewBar then
                sel:Show()
            else
                sel:Hide()
            end
        end
    end
end

-- Clic sobre un icono de la barra de la config: NUNCA ejecuta la acción real
-- del botón (eso es responsabilidad del menú flotante). Cualquier clic muestra
-- el panel de ajustes de ese ítem en la zona de contenido dinámico.
function ConfigWindow:OnBarIconClick(item)
    if not item or not item.action then return end
    self:SelectBarItem(item.action)
end

-- Muestra el panel informativo de un icono de la barra en la zona dinámica.
function ConfigWindow:SelectBarItem(actionId)
    if not actionId then return end
    local found = false
    for _, item in ipairs(self.barItems or {}) do
        if item.action == actionId then found = true break end
    end
    if not found then return end
    self.viewBar = actionId
    self:Render()
    self:PaintTabs()
    self:PaintBar()
end

-- Limpia el panel de barra (vuelve al esquema por pestañas). Restaura el
-- título dinámico a la pestaña activa (sin llamadas en el repo hoy, pero la API
-- queda consistente si se usa).
function ConfigWindow:ClearBarPanel()
    self.viewBar = nil
    if self.SyncTitle then self:SyncTitle() end
    self:PaintBar()
end

-- Render del PANEL INFORMATIVO de la barra dentro de la zona dinámica.
-- Devuelve el cursor de columna usado para que Render calcule las dimensiones.
function ConfigWindow:RenderBarPanel()
    local content = self.content
    local layout = RD.ui and RD.ui.layout
    if not layout then return nil end

    local item = nil
    for _, it in ipairs(self.barItems or {}) do
        if it.action == self.viewBar then item = it break end
    end
    if not item then return nil end

    local contentWidth = (type(self.contentWidth) == "number" and self.contentWidth > 0)
        and self.contentWidth or (CONTENT_WIDTH + 2 * PANEL_PAD)
    local availW = math.max(340, contentWidth - 2 * PANEL_PAD)
    local fieldW = math.floor(availW * 0.95)
    local fieldX = math.max(PANEL_PAD, math.floor((contentWidth - fieldW) / 2))
    local col = layout:Column(content, PANEL_PAD, -PANEL_PAD, fieldW, ROW_SPACING)

    -- Cabecera: icono + nombre (sin pista de clic: la ventana no ejecuta)
    local header = CreateFrame("Frame", nil, content)
    header:SetSize(fieldW, 40)
    local icon = header:CreateTexture(nil, "ARTWORK")
    icon:SetSize(36, 36)
    icon:SetPoint("LEFT", header, "LEFT", 0, 0)
    icon:SetTexture(item.icon or DEFAULT_ICON)
    local name = header:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    name:SetText(item.name or "")
    name:SetTextColor(GOLD_R, GOLD_G, GOLD_B)
    name:SetPoint("LEFT", header, "LEFT", 44, 0)
    RD.UIUtils.ScaleFont(name, 1.15)
    local usedY = col:Place(header, 40)
    header:ClearAllPoints()
    header:SetPoint("TOPLEFT", content, "TOPLEFT", fieldX, usedY)
    table.insert(content.rows, header)

    -- Descripción (readonly, alto medido para no desbordar al hacer scroll)
    if item.panelHelp and item.panelHelp ~= "" then
        local row = CreateFrame("Frame", nil, content)
        row:SetSize(fieldW, ROW_HEIGHT)
        local help = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        help:SetText(item.panelHelp)
        help:SetTextColor(0.85, 0.85, 0.85)
        help:SetWordWrap(true)
        help:SetJustifyH("LEFT")
        help:SetWidth(fieldW - 4)
        local h = ConfigWindow.MeasureReadonlyText and ConfigWindow.MeasureReadonlyText(help, fieldW - 4) or ROW_HEIGHT
        row:SetHeight(h)
        help:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
        local usedY = col:Place(row, h)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", content, "TOPLEFT", fieldX, usedY)
        table.insert(content.rows, row)
    end

    -- Ajustes relacionados (panelFields; reutilizan el despacho de widgets).
    -- Cada campo ocupa el alto que necesita su widget: los compactos (label
    -- arriba / editbox abajo) 48px, el resto 28px (checkbox/slider/dropdown/
    -- textbox), de modo que los inputs del panel quedan distribuidos y legibles.
    for _, field in ipairs(item.panelFields or {}) do
        local rowH = PanelFieldHeight(field)
        local row = CreateFrame("Frame", nil, content)
        row:SetSize(fieldW, rowH)
        local ok = pcall(function()
            local widget = ConfigWindow.CreateFieldWidget and ConfigWindow.CreateFieldWidget(row, field)
            if widget and widget.SetFocus then row.rdFocusable = widget end
            if field.type ~= "buttons" and RD.UIUtils and RD.UIUtils.AddRowHover then
                local targets = widget and widget.rdHoverTargets
                RD.UIUtils.AddRowHover(row, function() return field.help end, targets)
            end
        end)
        if not ok then
            row:Hide()
            row:SetParent(nil)
        else
            local usedY = col:Place(row, rowH)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", content, "TOPLEFT", fieldX, usedY)
            table.insert(content.rows, row)
        end
    end

    -- Estado en vivo del modo Auto (solo en su panel)
    if item.action == "ActionBarAutoLoot" then
        local mod = RD.modules and RD.modules.autoLoot
        local active = mod and mod.IsActive and mod:IsActive()
        local status = CreateFrame("Frame", nil, content)
        status:SetSize(fieldW, ROW_HEIGHT)
        local st = status:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        st:SetJustifyH("LEFT")
        st:SetText(active and "|cff1dbf00Estado: SESIÓN AUTO ACTIVA"
            or "|cffff8000Estado: sesión detenida (actívala con el clic izquierdo del botón 'Auto' del menú flotante)")
        st:SetPoint("LEFT", status, "LEFT", 0, 0)
        local usedY = col:Place(status, ROW_HEIGHT)
        status:ClearAllPoints()
        status:SetPoint("TOPLEFT", content, "TOPLEFT", fieldX, usedY)
        table.insert(content.rows, status)
    end

    return col
end

-- Suscripción al reorden de la barra (se registra en BuildBar si la barra ya
-- existe; BuildBar se llama desde Create).
return ConfigWindow