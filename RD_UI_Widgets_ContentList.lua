--[[
    RD_UI_Widgets_ContentList.lua
    PROPÓSITO: Editor de listas de contenido (título + icono + contenido de texto)
              para Mecánicas y Reglas. Al hacer clic en un elemento se abre una
              ventana para editar título, icono y contenido (área de texto).
              Vive en un archivo aparte para mantener RD_UI_Widgets_List.lua
              dentro del límite de ~700 líneas. Registra RD.ui.widgets:CreateContentList.
    API PÚBLICA:
        - RD.ui.widgets:CreateContentList(parent, field, onChange)
    EVENTOS: Ninguno. Escribe vía RD.config:Set (dispara CONFIG_CHANGED).
]]

local addonName, private = ...
local RD = _G.RaidDominion or {}
_G.RaidDominion = RD

RD.ui = RD.ui or {}
local Widgets = RD.ui.widgets
if not Widgets then
    Widgets = {}
    RD.ui.widgets = Widgets
end

local UniqueName = Widgets.UniqueName
local GetValue = Widgets.GetValue
local SetValue = Widgets.SetValue
local CreateScrollFrame = Widgets.CreateScrollFrame
local OpenIconPicker = Widgets.OpenIconPicker
local EnableTabNavigation = RD.UIUtils and RD.UIUtils.EnableTabNavigation
local Log = (RD.UIUtils and RD.UIUtils.Log) or function(msg) print(msg) end
local DEFAULT_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

-- =============================================
-- LIST EDITOR DE CONTENIDO (título + icono + contenido de texto)
-- Para Mecánicas y Reglas: se listan los elementos y al hacer clic se abre una
-- ventana para editar título, icono y contenido (área de texto multilínea).
-- =============================================

local contentEditor = nil

local function EnsureContentEditor()
    if contentEditor then return contentEditor end

    contentEditor = CreateFrame("Frame", "RDContentEditor", UIParent)
    -- Strata MEDIUM (paridad con los paneles de personaje de WoW): el editor se
    -- cubre/descubre con la UI del juego y pasa al frente al activarlo.
    if RD.UIUtils and RD.UIUtils.SetupWindow then
        RD.UIUtils.SetupWindow(contentEditor)
    else
        contentEditor:SetFrameStrata("MEDIUM")
        contentEditor:SetToplevel(true)
        contentEditor:SetClampedToScreen(true)
    end
    contentEditor:SetSize(440, 360)
    contentEditor:EnableMouse(true)
    contentEditor:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    contentEditor:SetBackdropColor(0, 0, 0, 0.95)
    contentEditor:SetBackdropBorderColor(1, 1, 1, 0.5)
    -- Permite cerrar con Escape (segundo toque, sin campo enfocado) vía
    -- UISpecialFrames; el primer Escape libera el foco del campo activo.
    table.insert(UISpecialFrames, "RDContentEditor")
    if RD.UIUtils and RD.UIUtils.TrackScale then RD.UIUtils.TrackScale(contentEditor) end

    -- Arrastrable desde cualquier zona no interactiva (título/fondo/espacio
    -- vacío); los campos y botones capturan su propio clic.
    contentEditor:SetMovable(true)
    contentEditor:RegisterForDrag("LeftButton")
    contentEditor:SetScript("OnDragStart", function()
        contentEditor:StartMoving()
    end)
    contentEditor:SetScript("OnDragStop", function()
        contentEditor:StopMovingOrSizing()
    end)

    -- Sin "clic fuera cierra": el editor NO se cierra al hacer clic fuera, para
    -- no perder lo escrito (se cierra con Guardar/Cancelar, el botón X o Esc).
    -- El Escape libera el foco del campo activo y, un segundo toque sin campo
    -- enfocado, cierra la ventana vía UISpecialFrames.

    local title = contentEditor:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOP", contentEditor, "TOP", 0, -10)
    title:SetText("Editar elemento")
    RD.UIUtils.ScaleFont(title, 1.5)

    local closeBtn = CreateFrame("Button", UniqueName("Cl"), contentEditor, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", contentEditor, "TOPRIGHT", -4, -4)
    closeBtn:SetScript("OnClick", function()
        contentEditor:Hide()
    end)

    -- Título
    local titleLabel = contentEditor:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    titleLabel:SetPoint("TOPLEFT", contentEditor, "TOPLEFT", 16, -36)
    titleLabel:SetText("Título:")
    RD.UIUtils.ScaleFont(titleLabel, 1.5)
    local titleBox = CreateFrame("EditBox", UniqueName("CEdT"), contentEditor, "InputBoxTemplate")
    titleBox:SetSize(400, 24)
    titleBox:SetPoint("TOPLEFT", titleLabel, "BOTTOMLEFT", 0, -6)
    titleBox:SetAutoFocus(false)
    RD.UIUtils.StyleInput(titleBox)
    -- Enter/Escape liberan el foco (estilo KRT) para poder usar atajos del teclado.
    titleBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    titleBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    contentEditor.titleBox = titleBox

    -- Icono (selector de iconos)
    local iconLabel = contentEditor:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    iconLabel:SetPoint("TOPLEFT", titleBox, "BOTTOMLEFT", 0, -16)
    iconLabel:SetText("Icono:")
    RD.UIUtils.ScaleFont(iconLabel, 1.5)
    local iconBtn = CreateFrame("Button", UniqueName("CEdI"), contentEditor)
    iconBtn:SetSize(24, 24)
    iconBtn:SetPoint("LEFT", iconLabel, "RIGHT", 8, 0)
    local iconTex = iconBtn:CreateTexture(nil, "ARTWORK")
    iconTex:SetAllPoints()
    iconBtn:SetScript("OnClick", function()
        OpenIconPicker(iconBtn, function(icon)
            contentEditor.icon = icon
            iconTex:SetTexture(icon)
        end, contentEditor.icon)
    end)
    contentEditor.iconBtn = iconBtn
    contentEditor.iconTex = iconTex

    -- Contenido (área de texto multilínea)
    local contentLabel = contentEditor:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    contentLabel:SetPoint("TOPLEFT", iconLabel, "BOTTOMLEFT", 0, -20)
    contentLabel:SetText("Contenido:")
    RD.UIUtils.ScaleFont(contentLabel, 1.5)

    -- El EditBox multilínea de 3.3.5a no recorta su texto: crece con el contenido
    -- dentro de un ScrollFrame que lo recorta y scrollea (rueda del ratón/barra).
    local contentW = (contentEditor:GetWidth() or 440) - 52
    local contentScroll = CreateScrollFrame(contentEditor, contentW, 140, 16, -174)
    contentScroll:SetPoint("TOPLEFT", contentLabel, "BOTTOMLEFT", 0, -6)
    contentScroll:SetPoint("RIGHT", contentEditor, "RIGHT", -36, 0)
    contentScroll:SetPoint("BOTTOM", contentEditor, "BOTTOM", 0, 40)

    local contentBox = CreateFrame("EditBox", UniqueName("CEdC"), contentScroll)
    contentBox:SetWidth(contentW)
    contentBox:SetHeight(140)
    contentBox:SetPoint("TOPLEFT", contentScroll, "TOPLEFT", 0, 0)
    contentBox:SetMultiLine(true)
    contentBox:SetAutoFocus(false)
    contentBox:EnableMouse(true)
    contentBox:SetFontObject(GameFontNormalSmall)
    RD.UIUtils.ScaleFont(contentBox, 1.5)
    contentBox:SetTextInsets(4, 4, 4, 4)
    contentBox:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    contentBox:SetBackdropColor(0, 0, 0, 0.7)
    contentBox:SetBackdropBorderColor(0.5, 0.5, 0.5, 0.7)
    contentScroll:SetScrollChild(contentBox)

    -- FontString de medida: el EditBox de 3.3.5a no expone el alto real de su
    -- texto, así que se mide con una copia oculta del mismo ancho y fuente.
    local measureFS = contentEditor:CreateFontString(nil, "ARTWORK")
    measureFS:SetFontObject(GameFontNormalSmall)
    RD.UIUtils.ScaleFont(measureFS, 1.5)
    measureFS:SetWordWrap(true)
    measureFS:SetJustifyH("LEFT")
    measureFS:Hide()
    local measureW = contentW - 8

    local function ResizeContentBox()
        measureFS:SetWidth(measureW)
        measureFS:SetText(contentBox:GetText() or "")
        local h = measureFS:GetStringHeight() or 0
        -- Fallback: en 3.3.5a un FontString oculto sin layout puede devolver 0 en
        -- GetStringHeight (la caja no crecería y el texto largo quedaría recortado
        -- sin scroll). Si la medición es menor que una línea, se estima por líneas.
        local _, fontSize = contentBox:GetFont()
        local lineHeight = (fontSize or 15) * 1.2
        if h < lineHeight then
            local str = measureFS:GetText() or ""
            local newlines = select(2, str:gsub("\n", "\n"))
            local cpl = math.max(30, math.floor(measureW * 2 / (fontSize or 15)))
            local estLines = newlines + 1 + math.max(0, math.ceil(#str / cpl))
            h = estLines * lineHeight
        end
        local minH = (contentScroll.GetHeight and contentScroll:GetHeight()) or 140
        contentBox:SetHeight(math.max(minH, h + 8))
        if contentScroll.UpdateScrollChildRect then
            contentScroll:UpdateScrollChildRect()
        end
    end
    contentBox:SetScript("OnTextChanged", ResizeContentBox)
    contentBox:SetScript("OnTextSet", ResizeContentBox)
    -- Escape libera el foco del contenido multilínea (Enter inserta salto de
    -- línea y mantiene el foco, como es habitual en un área de texto).
    contentBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    contentEditor:SetScript("OnShow", function()
        ResizeContentBox()
        -- El texto se seteó con el modal oculto: se fuerza el re-render interno
        -- del EditBox multilínea (SetText dispara OnTextSet aunque sea idéntico).
        contentBox:SetText(contentBox:GetText() or "")
    end)
    contentEditor.contentBox = contentBox
    contentEditor.contentScroll = contentScroll

    -- Soporte de enlaces del juego (shift-clic de ítems, hechizos/profesiones,
    -- misiones y logros) como el cuadro de chat: el propio EditBox los acepta
    -- sin botones extra (ver UIUtils.EnableLinkInsertion).
    if RD.UIUtils and RD.UIUtils.EnableLinkInsertion then
        RD.UIUtils.EnableLinkInsertion(contentBox)
    end

    -- Navegación con Tab entre los campos del modal: Título → Contenido
    if EnableTabNavigation then
        EnableTabNavigation({ titleBox, contentBox })
    end

    -- Guardar / Cancelar
    local saveBtn = RD.UIUtils.MakeChipButton(contentEditor, UniqueName("CEdS"), 90, 24)
    saveBtn:SetText("Guardar")
    saveBtn:SetPoint("BOTTOMRIGHT", contentEditor, "BOTTOMRIGHT", -16, 12)
    saveBtn:SetScript("OnClick", function()
        local st = contentEditor.state
        local item = contentEditor.item
        contentEditor.saved = true
        if item then
            item.title = strtrim(contentEditor.titleBox:GetText() or "")
            item.icon = contentEditor.icon or ""
            item.content = contentEditor.contentBox:GetText() or ""
        end
        contentEditor:Hide()
        if st then
            if st.saveList then st.saveList() end
            if st.buildRows then st.buildRows() end
        end
    end)
    contentEditor.saveBtn = saveBtn

    local cancelBtn = RD.UIUtils.MakeChipButton(contentEditor, UniqueName("CEdX"), 90, 24)
    cancelBtn:SetText("Cancelar")
    cancelBtn:SetPoint("RIGHT", saveBtn, "LEFT", -8, 0)
    cancelBtn:SetScript("OnClick", function()
        contentEditor:Hide()
    end)

    -- Al cerrar sin guardar y siendo un elemento nuevo, se elimina de la lista
    contentEditor:SetScript("OnHide", function()
        local st = contentEditor.state
        if contentEditor.isNew and not contentEditor.saved and st and st.list then
            local item = contentEditor.item
            for idx, v in ipairs(st.list) do
                if v == item then
                    table.remove(st.list, idx)
                    break
                end
            end
            if st.saveList then st.saveList() end
            if st.buildRows then st.buildRows() end
        end
        contentEditor.state = nil
        contentEditor.item = nil
        contentEditor.isNew = nil
        contentEditor.saved = nil
    end)

    return contentEditor
end

-- Abre el editor de contenido para un elemento con un estado propio
-- { list, saveList, buildRows }. Reutilizable desde el panel de configuración
-- (CreateContentList) y desde fuera (OpenContentListEditor, modo standalone).
local function OpenEditorWithState(item, isNew, state)
    local ed = EnsureContentEditor()
    ed.item = item
    ed.isNew = isNew
    ed.saved = nil
    ed.state = state
    ed.titleBox:SetText(item.title or "")
    ed.icon = item.icon or ""
    ed.iconTex:SetTexture(ed.icon ~= "" and ed.icon or DEFAULT_ICON)
    ed.contentBox:SetText(item.content or "")
    -- El modal se reutiliza (singleton): se resetea el scroll externo y el
    -- interno del EditBox para no mostrar un desplazamiento de una apertura
    -- anterior (contenido cortado o área vacía).
    if ed.contentScroll and ed.contentScroll.SetVerticalScroll then
        ed.contentScroll:SetVerticalScroll(0)
    end
    if ed.contentBox.SetScrollOffset then
        ed.contentBox:SetScrollOffset(0)
    end
    ed:ClearAllPoints()
    ed:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    if RD.UIUtils and RD.UIUtils.ClampModalToScreen then
        RD.UIUtils.ClampModalToScreen(ed, ed.contentScroll, 20)
    end
    if RD.UIUtils and RD.UIUtils.ActivateWindow then
        RD.UIUtils.ActivateWindow(ed)
    else
        ed:Show()
        ed:Raise()
    end
    local layout = RD.ui and RD.ui.layout
    if layout and layout.EnsureVisible then layout:EnsureVisible(ed, 8) end
end

function Widgets:CreateContentList(parent, field, onChange)
    if not parent or not field then return nil end

    local key = field.key
    local value = GetValue(field)
    local list = {}
    if type(value) == "table" then
        for _, v in ipairs(value) do
            list[#list + 1] = { title = v.title or v.name or "", icon = v.icon or "", content = v.content or "", visible = v.visible }
        end
    end

    local width = field.width or (parent.GetWidth and (parent:GetWidth() or 0) or 0)
    if width <= 0 then width = 452 end
    local height = field.height or 200
    local scrollW = width - 26
    local childW = scrollW
    local rowH = 24
    local gap = 2
    -- Franja fija de creación (Añadir), siempre visible FUERA de la zona de scroll
    local ADD_H = 24
    local GAP_H = 2
    -- Fila de privacidad de la lista ("Obtener"): vive dentro de la franja.
    local PRIV_H = 22

    local scroll, child = CreateScrollFrame(parent, scrollW, height, 0, -(ADD_H + GAP_H + PRIV_H + GAP_H))
    child:SetWidth(childW)
    -- La fila de la ventana de config que aloja el editor consume el clic en su
    -- zona vacía: en 3.3.5a el child del scroll sobresale del viewport por el
    -- borde inferior (cola del contenido que no cabe) y ese área, al quedar
    -- fuera del rect del scroll, dejaría caer el clic a través de él hasta la
    -- sección siguiente (p.ej. el título/controles "Anuncios..." que quedan
    -- debajo de la lista). Los controles (addBar, filas, viewport) son hijos y
    -- ganan en su propia zona.
    parent:EnableMouse(true)
    parent:SetScript("OnMouseDown", function() end)
    parent:SetScript("OnMouseUp", function() end)

    -- Franja de creación anclada al TOP del editor: Añadir + Obtener/Reiniciar.
    -- No forma parte del scroll (no se desplaza ni se oculta). EnableMouse:
    -- la franja captura el clic en su zona vacía para que NO caiga a través
    -- sobre los elementos que quedan debajo del editor.
    local addBar = CreateFrame("Frame", nil, parent)
    addBar:SetSize(childW, ADD_H + GAP_H + PRIV_H + GAP_H)
    addBar:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    addBar:EnableMouse(true)
    addBar:SetScript("OnMouseDown", function() end)
    addBar:SetScript("OnMouseUp", function() end)
    -- En 3.3.5a el ScrollFrame no recorta el ratón de su contenido: una fila que
    -- asoma por el borde superior al hacer scroll solaparía esta franja. Elevar
    -- su frame level sobre el scroll hace que la franja gane siempre el clic.
    local scrollLevel = scroll and scroll.GetFrameLevel and scroll:GetFrameLevel() or 0
    if addBar.SetFrameLevel then addBar:SetFrameLevel(scrollLevel + 5) end

    local itemRows = {}
    local BuildRows

    local function SaveList()
        local copy = {}
        for _, v in ipairs(list) do
            copy[#copy + 1] = { title = v.title, icon = v.icon, content = v.content, visible = v.visible }
        end
        if RD.config and RD.config.Set then RD.config:Set(key, copy) end
        if onChange then onChange(field, copy) end
    end

    local function ClearRows()
        -- Mismo guard de 3.3.5a que en CreateList: liberar foco antes de ocultar
        -- para que WoW no congele la fila en pantalla como fantasma.
        for _, r in ipairs(itemRows) do
            if r then
                local ok, err = pcall(function(dead)
                    if dead.nameBox and dead.nameBox.ClearFocus then dead.nameBox:ClearFocus() end
                    if dead.EnableMouse then dead:EnableMouse(false) end
                    dead:Hide()
                    dead:SetParent(nil)
                end, r)
                if not ok then
                    Log("|cffff0000[RaidDominion]|r error limpiando la lista: " .. tostring(err))
                end
            end
        end
        itemRows = {}
    end

    -- Abre la ventana de edición para un elemento (isNew si acaba de crearse)
    local function OpenEditor(item, isNew)
        OpenEditorWithState(item, isNew, { list = list, saveList = SaveList, buildRows = BuildRows })
    end

    -- Botón añadir
    local addBtn = RD.UIUtils.MakeChipButton(addBar, UniqueName("AAd"), 80, 22)
    addBtn:SetText("Añadir")
    RD.UIUtils.AddButtonTooltip(addBtn, function() return "Añade un nuevo elemento con título, icono y contenido." end)
    addBtn:SetPoint("TOPLEFT", addBar, "TOPLEFT", 0, 1)
    addBtn:SetScript("OnClick", function()
        local newItem = { title = "", icon = "", content = "" }
        table.insert(list, newItem)
        OpenEditor(newItem, true)
    end)

    -- Botón obtener del líder + reiniciar (confirmaciones) vía helper compartido
    local actions = RD.ui and RD.ui.widgets and RD.ui.widgets.CreateListActionButtons
        and RD.ui.widgets:CreateListActionButtons(addBar, addBtn, {
            listKey = key,
            label = field.label or key,
            onReset = function()
                local defaults = (RD.constants and RD.constants.DEFAULT_LISTS and RD.constants.DEFAULT_LISTS[key]) or {}
                for i = #list, 1, -1 do table.remove(list, i) end
                for _, item in ipairs(defaults) do
                    local copy = {}
                    for k, v in pairs(item) do copy[k] = v end
                    list[#list + 1] = copy
                end
                SaveList()
                BuildRows()
            end,
        })

    -- Privacidad de la lista ante "Obtener" (sobre la lista, en la franja fija).
    if RD.ui and RD.ui.widgets and RD.ui.widgets.CreatePrivacyDropdown then
        RD.ui.widgets:CreatePrivacyDropdown(addBar, key, { x = 6, y = -(ADD_H + GAP_H) })
    end

    -- (El botón "Spamear" de la pestaña de reglas se retiró: el spammer de reglas
    -- se abre desde el menú flotante (submenú Reglas → Spamear reglas).)

    -- La franja de creación (addBar) queda FUERA del scroll: no hay frames de
    -- cabecera que ocultar por visibilidad ni que reconstruir en cada build.

    BuildRows = function()
        ClearRows()

        -- Inválida el closure viejo de visibilidad antes de tocar el scroll
        -- (ver RD_UI_Widgets_List.lua): SetHeight/SetVerticalScroll del scroll
        -- disparan OnScrollRangeChanged/OnVerticalScroll que, con el closure
        -- anterior, podrían re-mostrar filas ya limpiadas como fantasmas.
        scroll.RDRefreshVisibility = nil

        -- Los ítems se distribuyen en el máximo de columnas que caben según el
        -- ancho disponible (cada celda necesita un ancho mínimo), aprovechando
        -- todo el espacio del panel.
        local MIN_CELL = 190
        local colGap = 8
        local cols = math.max(1, math.floor((childW + colGap) / (MIN_CELL + colGap)))
        local cellW = math.max(120, math.floor((childW - (cols - 1) * colGap) / cols))
        local gridRows = math.ceil(#list / cols)
        -- Las filas arrancan en el TOP del scroll (la franja de creación quedó
        -- fuera, arriba); el motor de drag usa firstTop = 0 (ver más abajo).
        local totalH = gridRows * (rowH + gap)

        for i, item in ipairs(list) do
            local col = (i - 1) % cols
            local r = math.floor((i - 1) / cols)
            local row = CreateFrame("Frame", nil, child)
            row:SetSize(cellW, rowH)
            row:SetPoint("TOPLEFT", child, "TOPLEFT", col * (cellW + colGap), -r * (rowH + gap))
            RD.UIUtils.AddRowHover(row)

            -- Icono del ítem a la izquierda. Sin icono (o "?" por defecto) se
            -- deja el hueco vacío: NO se muestra el signo de pregunta.
            local iconTex = row:CreateTexture(nil, "ARTWORK")
            iconTex:SetSize(20, 20)
            iconTex:SetPoint("LEFT", row, "LEFT", 0, 0)
            if item.icon and item.icon ~= "" and item.icon ~= DEFAULT_ICON then
                iconTex:SetTexture(item.icon)
            else
                iconTex:Hide()
            end

            -- Título: abre el editor al hacer clic (función delegada a la fila;
            -- el botón "✎" que se renderizaba como "?" se retiró).
            local titleText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            titleText:SetText(item.title ~= "" and item.title or "(sin título)")
            titleText:SetJustifyH("LEFT")
            titleText:SetJustifyV("CENTER")
            titleText:SetPoint("LEFT", iconTex, "RIGHT", 6, 0)
            titleText:SetPoint("RIGHT", row, "RIGHT", -70, 0)
            RD.UIUtils.ScaleFont(titleText, 1.25)
            row:SetScript("OnMouseDown", function(_, button)
                if button == "LeftButton" then
                    OpenEditor(item, false)
                end
            end)

            -- Agarre de arrastre: reordena la lista con click-drag → click-drop.
            local grip = Widgets.CreateGrip and Widgets:CreateGrip(row)
            if grip and Widgets.EnableRowDrag then
                Widgets:EnableRowDrag(grip, {
                    scroll = scroll,
                    child = child,
                    cols = cols,
                    cellW = cellW,
                    colGap = colGap,
                    rowH = rowH,
                    gap = gap,
                    -- Las filas arrancan en el top del scroll (la franja de
                    -- creación quedó fuera), así que la primera fila cae a 0.
                    firstTop = 0,
                    gridRows = gridRows,
                    source = i,
                    itemCount = function() return #list end,
                    label = item.title,
                    commitTarget = function(target)
                        local src = i
                        if target < 1 then target = 1 end
                        if target > #list + 1 then target = #list + 1 end
                        if target == src or target == src + 1 then return end
                        local temp = table.remove(list, src)
                        local idx = target
                        if idx > src then idx = idx - 1 end
                        table.insert(list, idx, temp)
                        SaveList()
                        BuildRows()
                    end,
                })
            end

            -- Botón visibilidad en el menú flotante (ojo), antes del eliminar
            local visBtn = RD.ui.widgets:CreateVisibilityToggle(row, item, SaveList, function() BuildRows() end)

            -- Botón quitar
            local removeBtn = CreateFrame("Button", UniqueName("IRm"), row)
            removeBtn:SetSize(20, 20)
            local rmTex = removeBtn:CreateTexture(nil, "ARTWORK")
            rmTex:SetAllPoints()
            rmTex:SetTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")
            removeBtn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
            -- Bloque de acciones a la derecha: [agarre][ojo][quitar]
            removeBtn:SetPoint("RIGHT", row, "RIGHT", 0, 0)
            visBtn:SetPoint("RIGHT", removeBtn, "LEFT", -2, 0)
            if grip then grip:SetPoint("RIGHT", visBtn, "LEFT", -2, 0) end
            removeBtn:SetScript("OnClick", function()
                local dialogs = RD.ui and RD.ui.dialogs
                local function DoRemove()
                    table.remove(list, i)
                    SaveList()
                    BuildRows()
                end
                if dialogs and dialogs.ShowConfirmDialog then
                    dialogs:ShowConfirmDialog({
                        text = string.format("¿Eliminar '%s' de la lista?", tostring(item.title or "")),
                        acceptText = "Eliminar",
                        onAccept = DoRemove,
                    })
                else
                    DoRemove()
                end
            end)

            itemRows[#itemRows + 1] = row
        end

        -- Lista vacía: indicación para empezar a crear elementos (anclada al top
        -- del scroll, igual que las filas; la franja de creación está fuera).
        if #list == 0 then
            local empty = RD.UIUtils and RD.UIUtils.CreateEmptyList
                and RD.UIUtils.CreateEmptyList(child, childW, "Lista vacía: pulsa 'Añadir' para crear el primer elemento.", 0)
            if empty then itemRows[#itemRows + 1] = empty end
            totalH = 20
        end

        child:SetHeight(totalH)
        if scroll.SetVerticalScroll then scroll:SetVerticalScroll(0) end
        -- Viewport dinámico (misma regla que Bandas): compacto si está vacío,
        -- tope en field.height si el contenido crece. La altura total incluye la
        -- franja de creación fija (ADD_H + GAP_H) que vive fuera del scroll.
        local viewH = math.max(1, math.min(height, math.max(1, totalH)))
        scroll:SetHeight(viewH)
        if parent.SetHeight then parent:SetHeight(ADD_H + GAP_H + PRIV_H + GAP_H + viewH) end

        -- Interactividad de las filas dentro del viewport: inactiva el ratón de
        -- solo las filas que quedan fuera de rango para que no reciban clics
        -- "a través" de los campos que haya debajo de la lista (p.ej. los
        -- anuncios). Las filas se mantienen VISIBLES (no se ocultan: en 3.3.5a
        -- Hide congelaría su layout y no reaparecerían al scrollear). La franja
        -- de creación (addBar) queda siempre visible y nunca se inactiva.
        if Widgets.ApplyScrollVisibility then
            Widgets:ApplyScrollVisibility(scroll, itemRows)
        end
    end

    BuildRows()

    return scroll
end

-- Abre el editor de un elemento de una lista de contenido (p.ej. "rules") desde
-- fuera del panel de configuración (botón "Editar regla" del spammer). Construye
-- su propio contexto leyendo la config directamente: así NO depende de que la
-- pestaña de Configuración se haya abierto alguna vez. `item` identifica el
-- elemento a editar (se busca por título dentro de la lista para editar el
-- objeto que se guardará). Devuelve true si pudo abrirlo.
function Widgets:OpenContentListEditor(listKey, item)
    if not listKey or not item then return false end
    local list = {}
    local value = (RD.config and RD.config.Get and RD.config:Get(listKey, {})) or {}
    if type(value) == "table" then
        for _, v in ipairs(value) do
            list[#list + 1] = { title = v.title or v.name or "", icon = v.icon or "", content = v.content or "", visible = v.visible }
        end
    end
    -- Editar el objeto DENTRO de la lista (por título) para que Guardar persista
    local target = item
    local title = tostring(item.title or item.name or "")
    if title ~= "" then
        for _, v in ipairs(list) do
            if tostring(v.title) == title then
                target = v
                break
            end
        end
    end
    local function SaveList()
        local copy = {}
        for _, v in ipairs(list) do
            copy[#copy + 1] = { title = v.title, icon = v.icon, content = v.content, visible = v.visible }
        end
        if RD.config and RD.config.Set then RD.config:Set(listKey, copy) end
    end
    OpenEditorWithState(target, false, {
        list = list,
        saveList = SaveList,
        buildRows = function() end,
    })
    return true
end


return Widgets
