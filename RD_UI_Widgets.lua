--[[
    RD_UI_Widgets.lua
    PROPÓSITO: Widgets reutilizables (Checkbox, Slider, Dropdown, Textbox, Button, Color).
              La ventana de configuración los usa para renderizar por esquema.
              Cada widget lee su valor con RD.config:Get(field.key, field.default)
              y escribe con RD.config:Set (que dispara CONFIG_CHANGED).
    API PÚBLICA:
        - RD.ui.widgets:CreateCheckbox(parent, field, onChange)
        - RD.ui.widgets:CreateSlider(parent, field, onChange)
        - RD.ui.widgets:CreateDropdown(parent, field, onChange)
        - RD.ui.widgets:CreateTextbox(parent, field, onChange)
        - RD.ui.widgets:CreateButton(parent, field, onClick)
        - RD.ui.widgets:CreateList(parent, field, onChange)
        - RD.ui.widgets:CreateColor(parent, field, onChange)
    NOTA: La API completa de widgets se reparte en varios archivos que cuelgan
          métodos del MISMO RD.ui.widgets:
          - RD_UI_Widgets_Scroll.lua: ApplyScrollVisibility, ScheduleVisibilityRefresh,
            SetRowMouseEnabled (visibilidad de filas en editores con scroll).
          - RD_UI_Widgets_Dropdown.lua: DataOptions, CreateOptionsDropdown,
            CreatePrivacyDropdown (dropdowns de opciones y privacidad de listas).
          - RD_UI_Widgets_List.lua / _ContentList / _Bands / _Drag / _Color / _Help.
    EVENTOS: Ninguno (indirectamente dispara CONFIG_CHANGED vía RD.config:Set)
]]

local addonName, private = ...
local RD = _G.RaidDominion or {}
_G.RaidDominion = RD

-- La tabla de widgets se reutiliza si ya existe: así ningún widget de otro
-- archivo (RD_UI_Widgets_*) se pierde aunque el orden de carga varíe.
RD.ui = RD.ui or {}
local Widgets = RD.ui.widgets
if not Widgets then
    Widgets = {}
    RD.ui.widgets = Widgets
end

-- Grid base (misma fuente que RD.constants.GRID)
local GUTTER = (RD.constants and RD.constants.GRID and RD.constants.GRID.GUTTER) or 4
local LABEL_WIDTH = (RD.constants and RD.constants.GRID and RD.constants.GRID.LABEL_WIDTH) or 184

-- Nombre único para frames con templates (los templates crean hijos con $parent).
-- Se delega en el contador ÚNICO de RD.UIUtils para evitar colisiones entre archivos.
local UniqueName = RD.UIUtils and RD.UIUtils.UniqueName

-- Lee un valor de config con guarda
local function GetValue(field)
    if RD.config and RD.config.Get then
        return RD.config:Get(field.key, field.default)
    end
    return field.default
end

-- Escribe un valor de config y dispara el callback con guarda
local function SetValue(field, value, onChange)
    if RD.config and RD.config.Set then
        RD.config:Set(field.key, value)
    end
    if onChange then
        onChange(field, value)
    end
end

-- Redondea un número al paso del campo (con limpieza de artefactos de coma flotante)
local function RoundToStep(value, step)
    if not step or step <= 0 then return value end
    local rounded = math.floor((value / step) + 0.5) * step
    if step < 1 then
        rounded = math.floor(rounded * 100 + 0.5) / 100
    end
    return rounded
end

-- Formatea el valor según el paso (enteros si step >= 1, dos decimales si no)
local function FormatValue(value, step)
    if step and step >= 1 then
        return string.format("%d", math.floor(value + 0.5))
    end
    return string.format("%.2f", value)
end

-- =============================================
-- CHECKBOX
-- =============================================

function Widgets:CreateCheckbox(parent, field, onChange)
    if not parent or not field then return nil end

    -- CheckButton con template y nombre único (el template crea "$parentText").
    -- Estilo WoW: checkbox a la izquierda y label a su derecha (compacto).
    local check = CreateFrame("CheckButton", UniqueName("Ck"), parent, "UICheckButtonTemplate")
    check:SetSize(20, 20)
    check:SetPoint("LEFT", parent, "LEFT", 0, 0)

    -- Vaciar el texto del template (el label propio va a la derecha del check)
    local templateText = getglobal(check:GetName() .. "Text")
    if templateText then
        templateText:SetText("")
    end

    -- Label a la derecha del checkbox
    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetText(field.label or "")
    RD.UIUtils.ScaleFont(label, 1.25)
    label:SetJustifyH("LEFT")
    label:SetPoint("LEFT", check, "RIGHT", 6, 0)

    -- Botón transparente sobre el label para hacer toggle (los FontStrings no tienen OnClick)
    local labelButton = CreateFrame("Button", nil, parent)
    labelButton:SetPoint("LEFT", check, "RIGHT", 6, 0)
    labelButton:SetPoint("RIGHT", parent, "RIGHT", 0, 0)
    labelButton:SetHeight(24)
    labelButton:SetScript("OnClick", function()
        check:SetChecked(not check:GetChecked())
        -- 3.3.5a: GetChecked devuelve 1/nil (WoW Flag Boolean), se normaliza a nativo
        local checked = check:GetChecked()
        local value = (checked == true) or (checked == 1)
        SetValue(field, value, onChange)
    end)

    -- Valor inicial
    check:SetChecked(GetValue(field))

    check:SetScript("OnClick", function(self)
        -- 3.3.5a: GetChecked devuelve 1/nil, se normaliza a booleano nativo para
        -- que Config:Set guarde true/false (no borre la clave con nil).
        local checked = self:GetChecked()
        local value = (checked == true) or (checked == 1)
        SetValue(field, value, onChange)
    end)

    -- Controles interactivos para hover/tooltip de fila (cubren todo el elemento)
    check.rdHoverTargets = { check, labelButton }
    return check
end

-- =============================================
-- SLIDER
-- =============================================

function Widgets:CreateSlider(parent, field, onChange)
    if not parent or not field then return nil end

    local min = field.min or 0
    local max = field.max or 1
    local step = field.step or 0.05

    local slider = CreateFrame("Slider", UniqueName("Sld"), parent, "OptionsSliderTemplate")
    slider:SetSize(100, 32)
    slider:SetMinMaxValues(min, max)
    slider:SetValueStep(step)

    -- Vaciar el texto del template (mostramos el valor con FontString propio)
    -- y retirar las etiquetas "Bajo"/"Alto" (Low/High) del template.
    local sliderName = slider:GetName()
    for _, suffix in ipairs({ "Text", "Low", "High" }) do
        local lbl = getglobal(sliderName .. suffix)
        if lbl then
            lbl:SetText("")
        end
    end

    -- Label a la izquierda con ancho fijo para alinear todos los sliders
    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetText(field.label or "")
    RD.UIUtils.ScaleFont(label, 1.25)
    label:SetJustifyH("LEFT")
    label:SetPoint("LEFT", parent, "LEFT", 0, 0)
    label:SetWidth(LABEL_WIDTH)

    -- Valor (solo lectura): FontString a la derecha, siempre visible y NO
    -- editable. El valor solo cambia arrastrando la barra.
    local valueText = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    valueText:SetJustifyH("RIGHT")
    valueText:SetPoint("RIGHT", parent, "RIGHT", 0, 0)

    -- El slider se estira entre el label y el valor; y=+4 centra los 32px del
    -- widget en la fila de 24px de la ventana de config (P4: sin asomar abajo).
    slider:SetPoint("LEFT", label, "RIGHT", 8, 4)
    slider:SetPoint("RIGHT", valueText, "LEFT", -8, 4)

    -- Estado interno y flag de carga (protege contra OnValueChanged durante init)
    local currentValue = min
    local loading = true

    local function UpdateDisplays(value)
        currentValue = value
        valueText:SetText(FormatValue(value, step))
    end

    -- En 3.3.5a OnValueChanged recibe (self, value) sin flag userChanged
    -- (ese tercer argumento llegó en Cataclysm). El flag `loading` protege
    -- contra SetValue programáticos durante init/edición manual.
    slider:SetScript("OnValueChanged", function(self, value)
        if loading then return end
        local rounded = RoundToStep(value, step)
        UpdateDisplays(rounded)
        SetValue(field, rounded, onChange)
    end)
    slider.rdHoverTargets = { slider }

    -- Carga del valor inicial
    local initial = GetValue(field)
    if type(initial) ~= "number" then
        initial = min
    end
    loading = true
    slider:SetValue(initial)
    loading = false
    UpdateDisplays(initial)

    return slider
end

-- =============================================
-- DROPDOWN
-- =============================================

function Widgets:CreateDropdown(parent, field, onChange)
    if not parent or not field then return nil end

    local options = field.options or {}
    local dropDown = CreateFrame("Frame", UniqueName("DD"), parent, "UIDropDownMenuTemplate")
    -- y=+4 centra el alto del template (~32px) en la fila de 24px de la config
    -- (P4: sin asomar bajo la fila). El label queda arriba a la izquierda.
    dropDown:SetPoint("RIGHT", parent, "RIGHT", 0, 4)

    -- Label a la izquierda
    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetText(field.label or "")
    RD.UIUtils.ScaleFont(label, 1.25)
    label:SetJustifyH("LEFT")
    label:SetPoint("LEFT", parent, "LEFT", 0, 0)

    UIDropDownMenu_SetWidth(dropDown, 160)
    UIDropDownMenu_SetAnchor(dropDown, 0, 0)

    -- Valor actual; si no existe en options, usar el primer valor como fallback
    local actual = GetValue(field)
    if not options[actual] then
        for k in pairs(options) do
            actual = k
            break
        end
    end

    local function InitFunc()
        local info = UIDropDownMenu_CreateInfo()
        for value, text in pairs(options) do
            info.text = text
            info.value = value
            info.checked = (value == actual)
            info.func = function()
                UIDropDownMenu_SetSelectedValue(dropDown, value)
                UIDropDownMenu_SetText(dropDown, text)
                actual = value
                SetValue(field, value, onChange)
            end
            UIDropDownMenu_AddButton(info)
        end
    end

    UIDropDownMenu_Initialize(dropDown, InitFunc)
    UIDropDownMenu_SetSelectedValue(dropDown, actual)
    UIDropDownMenu_SetText(dropDown, options[actual] or "")

    dropDown.rdHoverTargets = { dropDown, getglobal(dropDown:GetName() .. "Button") }
    return dropDown
end

-- =============================================
-- TEXTBOX
-- =============================================

function Widgets:CreateTextbox(parent, field, onChange)
    if not parent or not field then return nil end

    -- Modo readonly: FontString multilinea (se usa para el tab de ayuda)
    if field.readonly then
        local text = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        text:SetText(field.label or field.default or "")
        RD.UIUtils.ScaleFont(text, 1.25)
        text:SetWordWrap(true)
        text:SetJustifyH("LEFT")
        text:SetJustifyV("TOP")
        text:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
        -- Aprovecha el ancho disponible del frame fila
        local avail = parent.GetWidth and parent:GetWidth() or 0
        text:SetWidth((avail and avail > 0) and (avail - 4) or (LABEL_WIDTH + 80))
        return text
    end

    -- Label a la izquierda
    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetText(field.label or "")
    RD.UIUtils.ScaleFont(label, 1.25)
    label:SetJustifyH("LEFT")
    label:SetPoint("LEFT", parent, "LEFT", 0, 0)

    -- EditBox que se estira entre el label y el borde derecho de la fila/celda:
    -- así aprovecha todo el ancho (fila completa o celda del layout "row" de los
    -- anuncios) sin hueco central ni solaparse con el label.
    local editBox = CreateFrame("EditBox", UniqueName("Ed"), parent, "InputBoxTemplate")
    editBox:SetSize(200, 24)
    editBox:SetAutoFocus(false)
    RD.UIUtils.StyleInput(editBox)
    editBox:SetPoint("LEFT", label, "RIGHT", 8, 0)
    editBox:SetPoint("RIGHT", parent, "RIGHT", 0, 0)

    local initial = GetValue(field)
    if initial == nil then initial = "" end
    editBox:SetText(tostring(initial))

    local function SaveValue(self, clearFocus)
        local value = self:GetText()
        SetValue(field, value, onChange)
        if clearFocus then self:ClearFocus() end
    end

    -- Guardado EN VIVO: cada tecla escrita actualiza RD.config (dispara
    -- CONFIG_CHANGED) para que el cambio afecte de inmediato al menú flotante
    -- (p.ej. la palabra de los anuncios) sin necesidad de pulsar Intro.
    editBox:SetScript("OnTextChanged", function(self, userInput)
        if userInput then SaveValue(self, false) end
    end)
    -- Intro y ESC guardan y devuelven el foco (comportamiento clásico)
    editBox:SetScript("OnEnterPressed", function(self) SaveValue(self, true) end)
    editBox:SetScript("OnEscapePressed", function(self) SaveValue(self, true) end)

    -- Navegación con TAB entre los campos de texto de la ventana de config: la
    -- cadena rdTabNext/rdTabPrev la enlaza ConfigWindow:Render (ApplyTabOrder)
    -- tras construir las filas, en el orden visual. SHIFT-TAB retrocede.
    -- (En 3.3.5a los dropdown/checkbox no toman foco por teclado; un dropdown
    -- abierto ya se navega con las flechas.)
    editBox:SetScript("OnKeyDown", function(self, key)
        if key == "TAB" then
            if self.rdTabNext and self.rdTabNext.SetFocus then
                self.rdTabNext:SetFocus()
            end
        elseif key == "SHIFT-TAB" then
            if self.rdTabPrev and self.rdTabPrev.SetFocus then
                self.rdTabPrev:SetFocus()
            end
        end
    end)
    editBox.rdHoverTargets = { editBox }

    return editBox
end

-- =============================================
-- TEXTBOX COMPACTO (diseño en columnas)
-- =============================================

-- Variante de CreateTextbox para secciones con varios campos por fila (layout
-- en columnas): el label va ARRIBA y el EditBox ocupa todo el ancho debajo.
-- Así los mensajes cortos (p.ej. los temporizadores DBM) aprovechan el ancho
-- disponible sin que label+editbox compitan por la misma línea.
function Widgets:CreateTextboxCompact(parent, field, onChange)
    if not parent or not field then return nil end

    local cellW = parent.GetWidth and (parent:GetWidth() or 0) or 0
    local avail = (cellW and cellW > 0) and (cellW - 4) or (LABEL_WIDTH + 60)

    -- Label arriba, fuente reducida para caber en la celda
    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetText(field.label or "")
    RD.UIUtils.ScaleFont(label, 0.9)
    label:SetJustifyH("LEFT")
    label:SetWordWrap(true)
    label:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    label:SetWidth(avail)

    -- EditBox debajo, a todo el ancho de la celda
    local editBox = CreateFrame("EditBox", UniqueName("Ed"), parent, "InputBoxTemplate")
    editBox:SetSize(avail, 22)
    editBox:SetAutoFocus(false)
    RD.UIUtils.StyleInput(editBox)
    editBox:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 0, 0)

    local initial = GetValue(field)
    if initial == nil then initial = "" end
    editBox:SetText(tostring(initial))

    local function SaveValue(self, clearFocus)
        local value = self:GetText()
        SetValue(field, value, onChange)
        if clearFocus then self:ClearFocus() end
    end

    editBox:SetScript("OnTextChanged", function(self, userInput)
        if userInput then SaveValue(self, false) end
    end)
    editBox:SetScript("OnEnterPressed", function(self) SaveValue(self, true) end)
    editBox:SetScript("OnEscapePressed", function(self) SaveValue(self, true) end)
    editBox:SetScript("OnKeyDown", function(self, key)
        if key == "TAB" then
            if self.rdTabNext and self.rdTabNext.SetFocus then
                self.rdTabNext:SetFocus()
            end
        elseif key == "SHIFT-TAB" then
            if self.rdTabPrev and self.rdTabPrev.SetFocus then
                self.rdTabPrev:SetFocus()
            end
        end
    end)
    editBox.rdHoverTargets = { editBox }

    -- Alto de celda fijo: label (arriba) + editbox (abajo) con aire
    parent:SetHeight(48)

    return editBox
end

-- =============================================
-- BUTTON
-- =============================================

function Widgets:CreateButton(parent, field, onClick)
    if not parent or not field then return nil end

    local button = RD.UIUtils.MakeChipButton(parent, UniqueName("Btn"), 140, 24)
    button:SetText(field.label or "")

    button:SetScript("OnClick", function(self)
        if onClick then
            onClick(field, self)
        end
        if field.action then
            -- La acción puede no estar registrada aún al construir la UI
            pcall(function()
                if RD.MenuActions and RD.MenuActions.Execute then
                    RD.MenuActions:Execute(field.action, { button = self, field = field })
                end
            end)
        end
    end)

    button.rdHoverTargets = { button }
    return button
end

-- Fila de botones (varios botones en una misma línea, alineados a la derecha).
-- Cada botón lleva su propio tooltip (field.buttons[i].help) y puede pedir
-- confirmación antes de ejecutar su acción (field.buttons[i].confirmText), lo
-- que cubre los procesos destructivos (p.ej. "Restablecer valores por defecto").
function Widgets:CreateButtons(parent, field, onClick)
    if not parent or not field then return nil end
    local defs = field.buttons or {}
    if #defs == 0 then return nil end

    local buttons = {}
    local gap = 8
    local x = 0
    for _, bd in ipairs(defs) do
        local btn = RD.UIUtils.MakeChipButton(parent, UniqueName("BtR"), 140, 24)
        btn:SetText(bd.label or "")
        local fs = btn:GetFontString()
        local textW = (fs and fs.GetStringWidth and (fs:GetStringWidth() or 0)) or 0
        local layout = RD.ui and RD.ui.layout
        local width = math.max(140, textW + 24)
        btn:SetWidth(layout and layout.Snap(width) or width)
        btn:SetPoint("RIGHT", parent, "RIGHT", -x, 0)
        x = x + btn:GetWidth() + gap

        local tip = bd.help or field.help
        if tip then
            RD.UIUtils.AddButtonTooltip(btn, function() return tip end)
        end

        local function Run()
            if onClick then onClick(bd, btn) end
            if bd.action and RD.MenuActions and RD.MenuActions.Execute then
                pcall(function()
                    RD.MenuActions:Execute(bd.action, { button = btn, field = field })
                end)
            end
        end

        btn:SetScript("OnClick", function()
            if bd.confirmText then
                local dialogs = RD.ui and RD.ui.dialogs
                if dialogs and dialogs.ShowConfirmDialog then
                    dialogs:ShowConfirmDialog({
                        text = bd.confirmText,
                        acceptText = bd.confirmAccept or "Aceptar",
                        onAccept = Run,
                    })
                    return
                end
            end
            Run()
        end)

        buttons[#buttons + 1] = btn
    end

    return { buttons = buttons, rdHoverTargets = buttons }
end

-- Botones de acciones de LISTA: "Obtener" (pedir al líder) y "Reiniciar"
-- (restaurar estado por defecto), ambos con confirmación. Centraliza el patrón
-- que antes se triplicaba en CreateList / CreateContentList / CreateBands.
-- opts: { listKey, label, showObtain, showReset, obtainWidth, resetWidth,
--         obtainConfirm, obtainAccept, resetConfirm, resetAccept, resetTooltip,
--         onReset (callback del reset específico del editor) }
-- Devuelve { obtBtn, resetBtn, lastBtn } para que el editor posicione lo que siga.
function Widgets:CreateListActionButtons(parent, anchorBtn, opts)
    if not parent then return nil end
    opts = opts or {}
    local gap = 6
    local anchor = anchorBtn
    local result = {}

    local function MakeButton(name, text, w)
        local b = RD.UIUtils.MakeChipButton(parent, UniqueName(name), w or 80, 22)
        b:SetText(text)
        if anchor then
            b:SetPoint("LEFT", anchor, "RIGHT", gap, 0)
        else
            b:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
        end
        anchor = b
        return b
    end

    local function RequestList()
        local comm = RD.comm
        if not (comm and comm.RequestList) then return end
        local ok, why = comm:RequestList(opts.listKey)
        if ok then return end
        if RD.messageManager and RD.messageManager.SendSystemMessage then
            local text = "|cffff8000[RaidDominion]|r "
            if why == "leader" then
                text = text .. "Eres el líder: esta lista ya está en tu configuración."
            elseif why == "nofollow" then
                text = text .. "Debes estar en un grupo o banda para pedir la lista al líder."
            else
                text = text .. "No se puede pedir esta lista."
            end
            RD.messageManager:SendSystemMessage(text)
        end
    end

    if opts.showObtain ~= false then
        local b = MakeButton("LgOb", "Obtener", opts.obtainWidth)
        RD.UIUtils.AddButtonTooltip(b, function() return "Pide esta lista al líder si estás en grupo (añade solo los elementos nuevos, sin duplicados ni pérdidas)." end)
        b:SetScript("OnClick", function()
            -- Prechequeo ANTES del diálogo: si no se puede pedir (solo / líder /
            -- clave inválida), se avisa con el motivo concreto y no se abre un
            -- diálogo de confirmación imposible.
            local comm = RD.comm
            local why = (comm and comm.CanRequestList and comm:CanRequestList(opts.listKey)) or nil
            if why then
                RequestList()
                return
            end
            local dialogs = RD.ui and RD.ui.dialogs
            if dialogs and dialogs.ShowConfirmDialog then
                dialogs:ShowConfirmDialog({
                    text = opts.obtainConfirm or string.format("¿Pedir la lista de %s al líder? Se añadirán solo los elementos que no tengas (sin duplicados ni pérdidas).", opts.label or opts.listKey),
                    acceptText = opts.obtainAccept or "Obtener",
                    onAccept = RequestList,
                })
            else
                RequestList()
            end
        end)
        result.obtBtn = b
    end

    if opts.showReset ~= false and opts.onReset then
        local b = MakeButton("LgRs", "Reiniciar", opts.resetWidth)
        RD.UIUtils.AddButtonTooltip(b, function()
            return opts.resetTooltip or "Restaura esta lista a su estado por defecto (elimina los elementos actuales)."
        end)
        b:SetScript("OnClick", function()
            local dialogs = RD.ui and RD.ui.dialogs
            if not (dialogs and dialogs.ShowConfirmDialog) then return end
            dialogs:ShowConfirmDialog({
                text = opts.resetConfirm or string.format("¿Reiniciar la lista de %s? Se eliminarán todos los elementos y se restaurará el estado por defecto.", opts.label or opts.listKey),
                acceptText = opts.resetAccept or "Reiniciar",
                onAccept = opts.onReset,
            })
        end)
        result.resetBtn = b
    end

    result.lastBtn = anchor
    return result
end

-- =============================================
-- VISIBILIDAD EN EL MENÚ (mostrar/ocultar un elemento del submenú flotante)
-- =============================================

-- Botón-ojo: togglea item.visible (default true). Cuando false, el elemento no
-- aparece en el submenú correspondiente del menú flotante. Guarda (saveFn) y
-- reconstruye (rebuildFn). Colocado ANTES del botón eliminar en los editores.
function Widgets:CreateVisibilityToggle(parent, item, saveFn, rebuildFn)
    if not parent or not item then return nil end
    local btn = CreateFrame("Button", UniqueName("Vy"), parent)
    btn:SetSize(20, 20)
    local tex = btn:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints()
    tex:SetTexture("Interface\\Icons\\INV_Misc_Eye_01")
    btn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    local function Paint()
        tex:SetVertexColor(item.visible == false and 0.35 or 1, item.visible == false and 0.35 or 1, item.visible == false and 0.35 or 1)
    end
    Paint()
    btn:SetScript("OnEnter", function(self)
        if not (RD.UIUtils and RD.UIUtils.TooltipsEnabled and RD.UIUtils.TooltipsEnabled()) then
            GameTooltip:Hide()
            return
        end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(item.visible == false and "Mostrar en el menú flotante" or "Ocultar del menú flotante", 1, 0.82, 0, 1, true)
        GameTooltip:AddLine("El elemento se conserva en la lista; solo cambia su visibilidad en el menú flotante.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    btn:SetScript("OnClick", function()
        if item.visible == false then
            item.visible = true
        else
            item.visible = false
        end
        Paint()
        if saveFn then saveFn() end
        if rebuildFn then rebuildFn() end
    end)
    return btn
end

-- =============================================
-- STEPPERS Y HELPERS DE ROL / SANCIÓN (compartidos por la lista de jugadores y
-- el editor de jugador)
-- =============================================

-- Stepper [-] [label] [+] reutilizable (rol, dual, sanción). Devuelve
-- { frame, minus, plus, label }.
function Widgets:CreateStepper(parent, width)
    if not parent then return nil end
    -- Flechas de página (3.3.5a): izquierda = anterior, derecha = siguiente,
    -- congruentes con el ciclo de opciones de los steppers (rol/dual/sanción).
    local PREV_ICON = "Interface\\Buttons\\UI-SpellbookIcon-PrevPage-Up"
    local NEXT_ICON = "Interface\\Buttons\\UI-SpellbookIcon-NextPage-Up"
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetSize(width, 20)
    local minus = CreateFrame("Button", nil, frame)
    minus:SetSize(16, 20)
    minus:SetPoint("LEFT", frame, "LEFT", 0, 0)
    local minusTex = minus:CreateTexture(nil, "ARTWORK")
    minusTex:SetAllPoints()
    minusTex:SetTexture(PREV_ICON)
    minus:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    local plus = CreateFrame("Button", nil, frame)
    plus:SetSize(16, 20)
    plus:SetPoint("RIGHT", frame, "RIGHT", 0, 0)
    local plusTex = plus:CreateTexture(nil, "ARTWORK")
    plusTex:SetAllPoints()
    plusTex:SetTexture(NEXT_ICON)
    plus:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    local label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetJustifyH("CENTER")
    label:SetPoint("LEFT", minus, "RIGHT", 4, 0)
    label:SetPoint("RIGHT", plus, "LEFT", -4, 0)
    return { frame = frame, minus = minus, plus = plus, label = label }
end

-- Pinta el label de sanción con el short de la causal (o "—" si no hay)
function Widgets:PaintSanctionLabel(label, cause)
    if not label then return end
    local data = (RD.constants and RD.constants.BAND_SANCTION_DATA) or {}
    local meta = nil
    for _, s in ipairs(data) do
        if s.key == cause then meta = s break end
    end
    if meta then
        label:SetText(meta.short)
        label:SetTextColor(meta.color[1], meta.color[2], meta.color[3])
    else
        label:SetText("—")
        label:SetTextColor(0.6, 0.6, 0.6)
    end
end

-- Helpers compartidos con otros archivos de widgets (p.ej. RD_UI_Widgets_Color)
Widgets.UniqueName = UniqueName
Widgets.GetValue = GetValue
Widgets.SetValue = SetValue

return Widgets
