--[[
    RD_UI_ConfigWindow_Render.lua
    PROPÓSITO: Parte del render de la ventana de configuración (RD_UI_ConfigWindow)
              separada en archivo propio para cumplir el límite de ~700 líneas.
              Contiene el despacho de campos a widgets (CreateFieldWidget), los
              helpers de layout del render (AnchorButton, ClearContent,
              MeasureReadonlyText) y los métodos ReapplyHeight / Render sobre la
              tabla RD.ui.configWindow (definida en RD_UI_ConfigWindow.lua).
              Render despacha a dos vistas: la pestaña del esquema (CONFIG_SCHEMA)
              o el panel informativo de un icono de la barra inferior
              (RD_UI_ConfigWindow_Bar.lua, vista viewBar).
    API PÚBLICA:
        - RD.ui.configWindow:ReapplyHeight()
        - RD.ui.configWindow:Render()
        - RD.ui.configWindow:ApplyTabOrder()
        - RD.ui.configWindow:CreateFieldWidget(row, field)
        - RD.ui.configWindow:MeasureReadonlyText(text, width)
    EVENTOS: Lo invoca la ventana (Create / CONFIG_RESET / CONFIG_CHANGED).
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

-- Constantes de geometría (mismos valores que RD_UI_ConfigWindow.lua; el ancho
-- en runtime lo aporta self.contentWidth calculado en Create — el literal de
-- aquí es solo el fallback defensivo y espejo del CONTENT_WIDTH del archivo
-- principal, para conservar el ancho actual de la ventana ~808 px).
local CONTENT_WIDTH = 776
local PANEL_PAD = 12
local SIDE_PADDING = 8
local BOTTOM_PADDING = 12
local CONTENT_TOP = -72
local ROW_HEIGHT = 24
local ROW_SPACING = 8
local SECTION_TITLE_HEIGHT = 20
local MAX_BODY_HEIGHT = 520
local MIN_BODY_HEIGHT = 200
-- Bloque de la barra inferior (folder): el alto del frame reserva este hueco
-- (espejo de BAR_GAP, BAR_FOLDER_HEIGHT y BOTTOM_PADDING de
-- RD_UI_ConfigWindow.lua).
local BAR_GAP = 8
local BAR_FOLDER_HEIGHT = 37
-- Alto de las celdas del layout en columnas (widget compacto: label + editbox)
local COMPACT_CELL_HEIGHT = 48
-- Alto de la pill de una sección colapsable (acordeón de Ayuda)
local COLLAPSIBLE_HEADER_H = 24
local GOLD_R, GOLD_G, GOLD_B = unpack((RD.constants and RD.constants.COLORS and RD.constants.COLORS.GOLD) or { 1, 0.82, 0 })

-- Alto del viewport: nunca por debajo del alto mínimo del cuerpo (la barra de
-- la config ya no necesita alojar una tira vertical de iconos). Se aplica
-- también en el bloque final que re-afirma el scroll cuando el contenido cabe.
local function ViewHeight(self, bodyH)
    local minBody = (self and self.minBodyHeight) or MIN_BODY_HEIGHT
    return math.max(minBody, math.min(MAX_BODY_HEIGHT, bodyH))
end

-- Ancho del panel de contenido. En runtime lo fija Create (self.contentWidth,
-- que conserva el ancho actual de la ventana); el literal es el fallback.
local function ContentWidth(self)
    local w = self and self.contentWidth
    if type(w) == "number" and w > 0 then return w end
    return CONTENT_WIDTH + 2 * PANEL_PAD
end

local function CreateFieldWidget(row, field)
    local widgets = RD.ui and RD.ui.widgets
    if not widgets then return nil end

    local fieldType = field.type or "text"
    if fieldType == "checkbox" then
        return widgets:CreateCheckbox(row, field, nil)
    elseif fieldType == "slider" then
        return widgets:CreateSlider(row, field, nil)
    elseif fieldType == "dropdown" then
        return widgets:CreateDropdown(row, field, nil)
    elseif fieldType == "text" or fieldType == "textbox" then
        return widgets:CreateTextbox(row, field, nil)
    elseif fieldType == "textCompact" then
        return widgets:CreateTextboxCompact(row, field, nil)
    elseif fieldType == "button" then
        return widgets:CreateButton(row, field, nil)
    elseif fieldType == "buttons" then
        return widgets:CreateButtons(row, field, nil)
    elseif fieldType == "list" then
        return widgets:CreateList(row, field, nil)
    elseif fieldType == "contentList" then
        return widgets:CreateContentList(row, field, nil)
    elseif fieldType == "bands" then
        return widgets:CreateBands(row, field, nil)
    elseif fieldType == "color" then
        return widgets:CreateColor(row, field, nil)
    elseif fieldType == "helpAccordion" then
        return widgets:CreateHelpAccordion(row, field)
    end

    -- Tipo de campo sin widget: reportar en lugar de improvisar.
    if RD.messageManager and RD.messageManager.SendSystemMessage then
        RD.messageManager:SendSystemMessage(
            "|cffff0000[RaidDominion]|r Campo de configuración sin widget: " .. tostring(field.key or fieldType))
    end
    return nil
end

-- Expuesto como método para que el panel de la barra (RD_UI_ConfigWindow_Bar)
-- reutilice el mismo despacho de campos a widgets.
ConfigWindow.CreateFieldWidget = CreateFieldWidget

-- CreateButton no ancla el botón: se ancla a la derecha de la fila y se
-- autodimensiona al ancho del texto (regla 6.4 de AGENTS.md).
local function AnchorButton(button, row)
    if not button or not row then return end
    local layout = RD.ui and RD.ui.layout
    local textW = 0
    local fs = button:GetFontString()
    if fs and fs.GetStringWidth then
        textW = fs:GetStringWidth() or 0
    end
    local width = math.max(140, (layout and layout.Snap(textW + 24)) or (textW + 24))
    button:SetWidth(width)
    button:SetPoint("RIGHT", row, "RIGHT", 0, 0)
end

-- Checkbox compacto para la CABECERA de sección (section.headerCheckbox): se
-- ancla a la derecha del título dorado (check + label + botón transparente) y
-- lee/escribe RD.config vía Widgets.GetValue/SetValue sobre un campo sintético.
-- Ahorra una fila entera frente a renderizarlo como campo suelto y refuerza la
-- jerarquía (la visibilidad del submenú vive en el encabezado de su sección).
local function BuildHeaderCheckbox(header, hc)
    if not header or not hc then return nil end
    local widgets = RD.ui and RD.ui.widgets
    local field = { key = hc.key, default = true }

    local check = CreateFrame("CheckButton", RD.UIUtils and RD.UIUtils.UniqueName("Hc"), header, "UICheckButtonTemplate")
    check:SetSize(20, 20)
    local templateText = check.GetName and getglobal(check:GetName() .. "Text")
    if templateText then
        templateText:SetText("")
    end
    check:SetPoint("RIGHT", header, "RIGHT", 0, 0)
    if widgets and widgets.GetValue then
        check:SetChecked(widgets.GetValue(field))
    end

    local label = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetText(hc.label or "")
    RD.UIUtils.ScaleFont(label, 1.25)
    label:SetJustifyH("LEFT")
    label:SetPoint("RIGHT", check, "LEFT", -6, 0)

    local labelButton = CreateFrame("Button", nil, header)
    labelButton:SetPoint("LEFT", label, "LEFT", 0, 0)
    labelButton:SetPoint("RIGHT", header, "RIGHT", 0, 0)
    labelButton:SetHeight(20)

    local function Apply()
        local checked = check:GetChecked()
        local value = (checked == true) or (checked == 1)
        if widgets and widgets.SetValue then
            widgets.SetValue(field, value)
        end
    end
    check:SetScript("OnClick", function() Apply() end)
    labelButton:SetScript("OnClick", function()
        check:SetChecked(not check:GetChecked())
        Apply()
    end)

    if RD.UIUtils and RD.UIUtils.AddRowHover then
        RD.UIUtils.AddRowHover(header, function() return hc.help or "" end, { check, labelButton })
    end
    return check
end

-- Limpia el contenido previo. content.rows solo contiene FRAMES (filas y
-- cabeceras de sección); sobre FontStrings NO se puede SetParent(nil) en 3.3.5a.
local function ClearContent(content)
    if not content then return end
    if GameTooltip and GameTooltip.Hide then GameTooltip:Hide() end
    local rows = content.rows or {}
    for _, child in ipairs(rows) do
        child:Hide()
        child:SetParent(nil)
    end
    content.rows = {}
end

-- FontString de medida oculto: el alto envuelto del texto readonly se mide de
-- forma fiable (GetStringHeight del widget puede subestimar antes del layout),
-- evitando que el texto se desborde de su fila al hacer scroll. `width` es el
-- ancho real del campo (fieldW - 4), determinista. La fila queda con un margen
-- mínimo (2px) por debajo del texto para no inflar el contenido de la ayuda.
local measureTextFS = nil
local function MeasureReadonlyText(text, width)
    if not text or not text.GetText then return ROW_HEIGHT end
    if not measureTextFS then
        local holder = CreateFrame("Frame", nil, UIParent)
        holder:Hide()
        measureTextFS = holder:CreateFontString(nil, "ARTWORK")
    end
    local font, size = text:GetFont()
    if font and size then measureTextFS:SetFont(font, size) end
    measureTextFS:SetWordWrap(true)
    measureTextFS:SetJustifyH("LEFT")
    measureTextFS:SetWidth(math.max(120, width or 400))
    measureTextFS:SetText(text:GetText() or "")
    local h = measureTextFS:GetStringHeight() or 0
    -- Validación: si la medición es 0 o menor que una línea (FS no layoutado),
    -- se estima por número de líneas (helper central en RD.UIUtils).
    local lineHeight = (size or 14) * 1.2
    if h < lineHeight then
        local str = measureTextFS:GetText() or ""
        local estLines = RD.UIUtils.EstimateWrappedLines(str, width or 400, size or 14)
        h = estLines * lineHeight
    end
    return math.max(ROW_HEIGHT, math.floor(h) + 2)
end

-- Expuesto como método para que el panel de la barra (RD_UI_ConfigWindow_Bar)
-- mida el alto de su texto de descripción de la misma forma fiable.
ConfigWindow.MeasureReadonlyText = MeasureReadonlyText

-- Cola compartida del render (pestaña o panel de barra): dimensiones finales
-- del frame/scroll, alto máximo global y estado final del scroll. El frame
-- reserva el bloque de la barra inferior (FrameHeight incluye BAR_GAP y
-- BAR_FOLDER_HEIGHT).
local function FinalizeSizing(self, content, col, contentWidth)
    if not col then return end
    local layout = RD.ui and RD.ui.layout
    local innerHeight = -col.y - PANEL_PAD
    local bodyH = innerHeight + 2 * PANEL_PAD
    content:SetSize(contentWidth, bodyH)
    local viewH = ViewHeight(self, bodyH)
    if self.scroll then
        self.scroll:SetHeight(viewH)
        if self.scroll.UpdateScrollChildRect then
            self.scroll:UpdateScrollChildRect()
        end
    end
    if ConfigWindow.FrameHeight then
        self.frame:SetSize(contentWidth + 2 * SIDE_PADDING, ConfigWindow.FrameHeight(viewH))
    else
        self.frame:SetSize(contentWidth + 2 * SIDE_PADDING,
            -CONTENT_TOP + viewH + BAR_GAP + BAR_FOLDER_HEIGHT + BOTTOM_PADDING)
    end

    -- Alto máximo global: si la ventana no cabe en pantalla, se recorta el
    -- viewport (que sigue scrolleando) en lugar de salirse de la pantalla.
    if self.scroll and RD.UIUtils and RD.UIUtils.ClampModalToScreen then
        RD.UIUtils.ClampModalToScreen(self.frame, self.scroll, 16)
    elseif layout and layout.EnsureVisible then
        layout:EnsureVisible(self.frame, 8)
    end

    -- Estado final del scroll tras reconstruir y redimensionar. Tras pasar de un
    -- tab largo (Ayuda) a uno corto (General), la barra o el rango del tab
    -- anterior podían quedar visibles/activos si OnScrollRangeChanged no se
    -- disparaba o si ClampModalToScreen (del tab largo) dejó el viewport recortado:
    -- cuando el contenido cabe (bodyH <= MAX_BODY_HEIGHT) se re-afirma el viewport,
    -- se fuerza la barra a rango 0 (la rueda no scrollea), se resetea el offset y
    -- se oculta la barra.
    if self.scroll and bodyH <= MAX_BODY_HEIGHT then
        self.scroll:SetHeight(ViewHeight(self, bodyH))
        if self.scroll.UpdateScrollChildRect then
            self.scroll:UpdateScrollChildRect()
        end
        if self.scroll.SetVerticalScroll then
            self.scroll:SetVerticalScroll(0)
        end
        if self.scroll.scrollBar then
            self.scroll.scrollBar:SetMinMaxValues(0, 0)
            self.scroll.scrollBar:SetValue(0)
            self.scroll.scrollBar:Hide()
        end
    end
end

-- Enlaza la navegación con TAB entre los EditBoxes del contenido actual: cada
-- campo de texto apunta a su siguiente/anterior (rdTabNext/rdTabPrev) según el
-- orden visual de las filas. La tecla la maneja el propio widget (OnKeyDown).
function ConfigWindow:ApplyTabOrder()
    if not self.content then return end
    local editBoxes = {}
    for _, row in ipairs(self.content.rows or {}) do
        if row.rdFocusables then
            -- Filas de varias celdas (layout en columnas): cada celda aporta su
            -- EditBox, en el orden visual de izquierda a derecha.
            for _, eb in ipairs(row.rdFocusables) do
                if eb and eb.SetFocus then
                    editBoxes[#editBoxes + 1] = eb
                end
            end
        else
            local eb = row.rdFocusable
            if eb then editBoxes[#editBoxes + 1] = eb end
        end
    end
    local n = #editBoxes
    for i, eb in ipairs(editBoxes) do
        eb.rdTabNext = editBoxes[(i % n) + 1]
        eb.rdTabPrev = editBoxes[((i - 2 + n) % n) + 1]
    end
end

function ConfigWindow:ReapplyHeight()
    if not self.frame or not self.content or not self.scroll then return end
    local layout = RD.ui and RD.ui.layout
    local contentWidth = ContentWidth(self)
    local colY = -PANEL_PAD
    for _, row in ipairs(self.content.rows or {}) do
        local h = (row.GetHeight and row:GetHeight()) or ROW_HEIGHT
        if h < 1 then h = ROW_HEIGHT end
        if layout and layout.Snap then
            colY = layout.Snap(colY - math.floor(h) - ROW_SPACING)
        else
            colY = colY - math.floor(h) - ROW_SPACING
        end
    end
    local innerHeight = -colY - PANEL_PAD
    local bodyH = innerHeight + 2 * PANEL_PAD
    self.content:SetSize(contentWidth, bodyH)
    local viewH = ViewHeight(self, bodyH)
    self.scroll:SetHeight(viewH)
    if self.scroll.UpdateScrollChildRect then
        self.scroll:UpdateScrollChildRect()
    end
    if ConfigWindow.FrameHeight then
        self.frame:SetSize(contentWidth + 2 * SIDE_PADDING, ConfigWindow.FrameHeight(viewH))
    else
        self.frame:SetSize(contentWidth + 2 * SIDE_PADDING,
            -CONTENT_TOP + viewH + BAR_GAP + BAR_FOLDER_HEIGHT + BOTTOM_PADDING)
    end
    if RD.UIUtils and RD.UIUtils.ClampModalToScreen then
        RD.UIUtils.ClampModalToScreen(self.frame, self.scroll, 16)
    end
    -- Mismo estado final que Render: si el contenido cabe, re-afirma el viewport,
    -- fuerza la barra a rango 0, resetea el scroll y oculta la barra.
    if self.scroll and bodyH <= MAX_BODY_HEIGHT then
        self.scroll:SetHeight(ViewHeight(self, bodyH))
        if self.scroll.UpdateScrollChildRect then
            self.scroll:UpdateScrollChildRect()
        end
        if self.scroll.SetVerticalScroll then
            self.scroll:SetVerticalScroll(0)
        end
        if self.scroll.scrollBar then
            self.scroll.scrollBar:SetMinMaxValues(0, 0)
            self.scroll.scrollBar:SetValue(0)
            self.scroll.scrollBar:Hide()
        end
    end
end

function ConfigWindow:Render()
    if not self.frame or not self.content then return end

    -- Título dinámico: compone la vista activa (pestaña o panel de la barra).
    -- Con guarda defensiva como CallRender: si el método no llegó a adjuntarse
    -- (p.ej. .toc viejo), el render no debe abortar.
    if self.SyncTitle then self:SyncTitle() end

    local layout = RD.ui and RD.ui.layout
    if not layout then return end
    local content = self.content
    ClearContent(content)
    local contentWidth = ContentWidth(self)
    content:SetSize(contentWidth, 2 * PANEL_PAD)

    -- Vista de un icono de la barra inferior: el PANEL INFORMATIVO se renderiza
    -- en la misma zona de contenido dinámico (RD_UI_ConfigWindow_Bar.lua).
    if self.viewBar then
        local col = self:RenderBarPanel()
        if not col then return end
        FinalizeSizing(self, content, col, contentWidth)
        self:ApplyTabOrder()
        return
    end

    local schema = (RD.constants and RD.constants.CONFIG_SCHEMA) or {}
    -- El tab activo se resuelve desde self.tabs (que respeta el orden por `order`),
    -- no indexando el esquema original, para no desincronizarse si el orden cambia.
    local tab = self.tabs[self.currentTab] and self.tabs[self.currentTab].schema
    if not tab then
        self.currentTab = 1
        tab = schema[1]
    end
    if not tab or not tab.sections then
        return
    end

    -- El contenido aprovecha el ancho disponible del marco. TODOS los campos
    -- (normales y editores de lista) se centran en un bloque que ocupa el 80%
    -- del ancho usable del panel (márgenes simétricos ~10% a cada lado), de
    -- modo que queden bien ubicados y sin pegarse a los bordes ni a la barra.
    local availW = math.max(340, contentWidth - 2 * PANEL_PAD)
    -- El contenido aprovecha el 95% del ancho usable del panel en todas las
    -- pestañas (antes 80%), centrado con márgenes simétricos.
    local fieldW = math.floor(availW * 0.95)
    local fieldX = math.max(PANEL_PAD, math.floor((contentWidth - fieldW) / 2))

    -- Tabs compactos (p.ej. Ayuda): se reduce el espaciado entre filas y el alto
    -- de las cabeceras de sección para acortar el contenido/scroll (~80px).
    local isCompact = tab.compact or tab.id == "help"
    local spacing = isCompact and 4 or ROW_SPACING
    local sectionH = isCompact and 16 or SECTION_TITLE_HEIGHT
    local col = layout:Column(content, PANEL_PAD, -PANEL_PAD, fieldW, spacing)
    local sections = (ConfigWindow.SortByOrder and ConfigWindow.SortByOrder(tab.sections)) or {}

    for _, section in ipairs(sections) do
        -- Estado de las secciones colapsables (estilo acordeón de Ayuda): por
        -- defecto PLEGADAS; el estado vive en section._expanded y sobrevive al
        -- re-render (se resetea al reiniciar el cliente, igual que el de Ayuda).
        local isOpen = not section.collapsible or section._expanded == true

        -- Cabecera de sección. Las colapsables se renderizan como una pill
        -- clicable (acordeón de Ayuda): al pulsarla se despliega/pliega el
        -- bloque de campos y se re-renderiza la ventana.
        if section.collapsible then
            local header = RD.UIUtils.MakeChipButton(content, nil, fieldW, COLLAPSIBLE_HEADER_H)
            header:SetText(section.title or "")
            if RD.UIUtils and RD.UIUtils.PaintTabButton then
                RD.UIUtils.PaintTabButton(header, isOpen)
            end
            header:SetScript("OnClick", function()
                if section._expanded == true then
                    section._expanded = nil
                else
                    section._expanded = true
                end
                self:Render()
            end)
            local usedY = col:Place(header, COLLAPSIBLE_HEADER_H)
            header:ClearAllPoints()
            header:SetPoint("TOPLEFT", content, "TOPLEFT", fieldX, usedY)
            table.insert(content.rows, header)
        elseif section.title and section.title ~= "" then
            -- Cabecera de sección normal (se omite si el título está vacío; en
            -- 3.3.5a no se puede SetParent(nil) sobre un FontString, por eso se
            -- envuelve).
            local header = CreateFrame("Frame", nil, content)
            header:SetSize(fieldW, sectionH)
            local sectionTitle = header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            sectionTitle:SetText(section.title or "")
            sectionTitle:SetTextColor(GOLD_R, GOLD_G, GOLD_B)
            sectionTitle:SetJustifyH("LEFT")
            sectionTitle:SetPoint("TOPLEFT", header, "TOPLEFT", 0, 0)
            RD.UIUtils.ScaleFont(sectionTitle, 1.5)
            -- Con headerCheckbox el título reserva espacio a la derecha para no
            -- chocar con el checkbox+label (p.ej. "Mostrar en el menú flotante").
            if section.headerCheckbox then
                sectionTitle:SetWidth(math.max(120, fieldW - 210))
            end
            -- Línea separadora sutil bajo el título de sección
            local titleLine = header:CreateTexture(nil, "ARTWORK")
            titleLine:SetPoint("TOPLEFT", header, "TOPLEFT", 0, -sectionH + 2)
            titleLine:SetPoint("TOPRIGHT", header, "TOPRIGHT", 0, -sectionH + 2)
            titleLine:SetHeight(1)
            titleLine:SetTexture(1, 1, 1, 0.1)
            -- Checkbox de visibilidad del submenú, anclado a la derecha del título
            if section.headerCheckbox then
                BuildHeaderCheckbox(header, section.headerCheckbox)
            end
            local usedY = col:Place(header, sectionH)
            header:ClearAllPoints()
            header:SetPoint("TOPLEFT", content, "TOPLEFT", fieldX, usedY)
            table.insert(content.rows, header)
        end

        -- Campos de la sección. Las secciones colapsables PLEGADAS no crean
        -- filas (no quedan huecos en el layout, igual que el render omite los
        -- ítems deshabilitados del menú). Cada campo se construye de forma
        -- resiliente: si un widget falla, el render continúa y el sizing final
        -- se calcula igual (evita que un fallo a mitad deje el frame/scroll con
        -- tamaños de otro tab). Secciones con `columns > 1` (p.ej. los mensajes
        -- DBM) disponen sus campos en filas de N celdas para aprovechar el
        -- ancho del panel.
        if isOpen then
        if section.layout == "row" then
            -- Secciones `layout = "row"` (p.ej. los anuncios de las listas
            -- asignables): los campos se disponen en FILAS horizontales de 24px,
            -- hasta 2 por fila, para aprovechar el ancho del panel y ahorrar
            -- alto vertical frente a una fila por campo. Cada campo vive en su
            -- propia celda y los widgets (dropdown/textbox) ya se auto-posicionan
            -- label-izquierda / control-derecha dentro de ella.
            local fields = section.fields or {}
            local gap = 8
            local perRow = 2
            local row = nil
            local rowCellW = 0
            local rowPlaced = 0
            for i, field in ipairs(fields) do
                if rowPlaced == 0 then
                    local remaining = #fields - i + 1
                    local thisRow = math.min(perRow, remaining)
                    row = CreateFrame("Frame", nil, content)
                    row:SetSize(fieldW, ROW_HEIGHT)
                    local usedY = col:Place(row, ROW_HEIGHT)
                    row:ClearAllPoints()
                    row:SetPoint("TOPLEFT", content, "TOPLEFT", fieldX, usedY)
                    table.insert(content.rows, row)
                    rowCellW = math.floor((fieldW - (thisRow - 1) * gap) / thisRow)
                end
                local cell = CreateFrame("Frame", nil, row)
                cell:SetSize(rowCellW, ROW_HEIGHT)
                cell:SetPoint("TOPLEFT", row, "TOPLEFT", rowPlaced * (rowCellW + gap), 0)
                local okCell = pcall(function()
                    local widget = CreateFieldWidget(cell, field)
                    if widget and widget.SetFocus then
                        row.rdFocusable = widget
                    end
                    if RD.UIUtils and RD.UIUtils.AddRowHover then
                        local targets = widget and widget.rdHoverTargets
                        RD.UIUtils.AddRowHover(cell, function() return field.help end, targets)
                    end
                end)
                if not okCell then
                    cell:Hide()
                    cell:SetParent(nil)
                    if RD.messageManager and RD.messageManager.SendSystemMessage then
                        RD.messageManager:SendSystemMessage(
                            "|cffff8000[RaidDominion]|r No se pudo mostrar el campo '" .. tostring(field.key or field.label or field.type) .. "'.")
                    end
                end
                rowPlaced = rowPlaced + 1
                if rowPlaced >= perRow then rowPlaced = 0 end
            end
        else
        local columns = math.max(1, math.floor(section.columns or 1))
        if columns > 1 then
            -- Cuadrícula: los campos se agrupan de a `columns` por fila; cada
            -- celda usa el widget compacto (label arriba / editbox abajo).
            local fields = section.fields or {}
            local gap = 8
            local cellW = math.floor((fieldW - (columns - 1) * gap) / columns)
            local idx = 1
            while idx <= #fields do
                local row = CreateFrame("Frame", nil, content)
                row:SetSize(fieldW, COMPACT_CELL_HEIGHT)
                row.rdFocusables = {}
                local okCell = pcall(function()
                    for c = 1, columns do
                        local field = fields[idx]
                        if not field then return end
                        idx = idx + 1
                        local cell = CreateFrame("Frame", nil, row)
                        cell:SetSize(cellW, COMPACT_CELL_HEIGHT)
                        cell:SetPoint("TOPLEFT", row, "TOPLEFT", (c - 1) * (cellW + gap), 0)
                        local widget = CreateFieldWidget(cell, field)
                        if widget and widget.SetFocus then
                            row.rdFocusables[#row.rdFocusables + 1] = widget
                        end
                        if field.type ~= "buttons" and RD.UIUtils and RD.UIUtils.AddRowHover then
                            local targets = widget and widget.rdHoverTargets
                            RD.UIUtils.AddRowHover(cell, function() return field.help end, targets)
                        end
                    end
                end)
                if not okCell then
                    row:Hide()
                    row:SetParent(nil)
                    if RD.messageManager and RD.messageManager.SendSystemMessage then
                        RD.messageManager:SendSystemMessage(
                            "|cffff8000[RaidDominion]|r No se pudo mostrar una celda de la sección '" .. tostring(section.id or section.title or "") .. "'.")
                    end
                else
                    -- Fila de celdas compactas: alto fijo (la celda ya cuadricula 48px)
                    local usedY = col:Place(row, COMPACT_CELL_HEIGHT)
                    row:ClearAllPoints()
                    row:SetPoint("TOPLEFT", content, "TOPLEFT", fieldX, usedY)
                    table.insert(content.rows, row)
                end
            end
        else
        for _, field in ipairs(section.fields or {}) do
            -- La row se crea FUERA del pcall para poder limpiarla si el widget
            -- falla (evita frames huérfanos) y para reportar el error sin abortar.
            local row = CreateFrame("Frame", nil, content)
            row:SetSize(fieldW, ROW_HEIGHT)
            local okField = pcall(function()
            local isList = (field.type == "list") or (field.type == "contentList") or (field.type == "bands") or (field.type == "helpAccordion")

            -- La navegación entre el cursor y las pestañas es más natural que
            -- copiar/pegar: los campos de las 4 listas asignables
            -- (roles/habilidades/buffs/auras) exponen las zonas de soltado de los
            -- tabs para arrastrar un ítem de una lista a otra. Se copia el campo
            -- (shallow) para no mutar el esquema y se añade dropZones.
            local renderField = field
            if field.type == "list" and field.key and self.GetDropZones then
                renderField = {}
                for fk, fv in pairs(field) do renderField[fk] = fv end
                renderField.dropZones = function()
                    return self:GetDropZones()
                end
            end

            local widget = CreateFieldWidget(row, renderField)

            -- Los campos de texto (EditBox) son los únicos widgets con SetFocus:
            -- se recogen por fila para enlazar la navegación con TAB al final del
            -- render, en el orden visual de las filas.
            if widget and widget.SetFocus then
                row.rdFocusable = widget
            end

            -- Hover sutil + tooltip de ayuda en filas de campos normales. El
            -- hover/tooltip se propaga a los controles del widget (checkbox,
            -- slider, botón...) para cubrir todo el elemento. Los editores de
            -- lista no muestran tooltip en la fila (solo sus botones principales)
            -- y las filas de varios botones ("buttons") usan tooltips propios por
            -- botón (no se pisan con el de la fila).
            if not isList and field.type ~= "buttons" and RD.UIUtils and RD.UIUtils.AddRowHover then
                local targets = widget and widget.rdHoverTargets
                RD.UIUtils.AddRowHover(row, function() return field.help end, targets)
            end

            -- El widget de botón no ancla su control: se ancla a la derecha
            if field.type == "button" then
                AnchorButton(widget, row)
            end

            -- Texto informativo readonly: alto ajustado al contenido (medición
            -- fiable para que el texto no se desborde al hacer scroll) y clip
            -- por fila como red de seguridad.
            local rowH = ROW_HEIGHT
            if (field.type == "text" or field.type == "textbox") and field.readonly and widget then
                if row.EnableClipsChildren then
                    row:EnableClipsChildren(true)
                end
                rowH = MeasureReadonlyText(widget, fieldW - 4)
            elseif field.type == "list" or field.type == "contentList" or field.type == "bands" or field.type == "helpAccordion" then
                -- Los editores de lista y el acordeón de ayuda fijan su propio
                -- alto según el contenido (el widget hace parent:SetHeight).
                rowH = row:GetHeight() or field.height or 200
            end

            local usedY = col:Place(row, rowH)
            -- Re-anclar: todo el contenido centrado en el bloque (padding simétrico)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", content, "TOPLEFT", fieldX, usedY)
            table.insert(content.rows, row)
            end)
            if not okField then
                -- Limpia la row huérfana y reporta el fallo (sin abortar el render)
                row:Hide()
                row:SetParent(nil)
                if RD.messageManager and RD.messageManager.SendSystemMessage then
                    RD.messageManager:SendSystemMessage(
                        "|cffff8000[RaidDominion]|r No se pudo mostrar el campo '" .. tostring(field.key or field.label or field.type) .. "'.")
                end
            end
        end
        end -- else (columnas: render vertical tradicional)
        end -- else (layout row: render horizontal por filas)
        end -- if isOpen (secciones colapsables plegadas no crean filas)
    end -- for section

    -- Dimensiones finales (enteros, múltiplos del grid); el cursor empezó en
    -- -PANEL_PAD y baja, así que el alto interior es -col.y - PANEL_PAD.
    FinalizeSizing(self, content, col, contentWidth)

    -- Navegación con TAB: enlazar los campos de texto ya construidos.
    self:ApplyTabOrder()
end

-- Registro explícito e idempotente: la tabla debe ser SIEMPRE la misma que la
-- del archivo principal (RD_UI_ConfigWindow.lua), por si este archivo se cargó
-- antes de que aquél registrara su tabla (fallback de identidad).
RD.ui = RD.ui or {}
RD.ui.configWindow = ConfigWindow

return ConfigWindow
