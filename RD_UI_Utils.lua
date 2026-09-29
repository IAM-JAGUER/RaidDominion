--[[
    RD_UI_Utils.lua
    PROPÓSITO: Utilidades generales de UI (frames, pooling, escala, estilo).
              Los helpers de texto/enlaces y tooltips viven en
              RD_UI_Utils_Helpers.lua (misma tabla RD.UIUtils, carga previa).
    API PÚBLICA:
        - RD.UIUtils:Log(msg) / SortByOrder(list) / DeepCopy(orig)
        - RD.UIUtils:EstimateWrappedLines(str, width, fontSize) / MakeAutoResizeMultiline(editBox, scrollFrame, measureW)
        - RD.UIUtils:UniqueName(prefix) / ApplyScale(frame) / TrackScale(frame)
        - RD.UIUtils:MakeClickToTop(frame) / SetupWindow(frame, opts) / ActivateWindow(frame)
        - RD.UIUtils:ClampModalToScreen(modal, flexBox, margin)
        - RD.UIUtils:AcquireFrame(poolName, frameType, parent, template) / ReleaseFrame(poolName, frame)
        - RD.UIUtils:CreateLabel(parent, text, template) / CreateEmptyMessage(parent, text, y) / CreateEmptyList(parent, width, text, y)
        - RD.UIUtils:StyleInput(editBox) / MakeChipButton(parent, name, w, h) / PaintTabButton(btn, active)
        - RD.UIUtils:EnableTabNavigation(boxes) / CreateToggleCheck(parent, text, onClick, opts) / StyleTitleDropdown(dropdown)
    EVENTOS: Suscribe CONFIG_CHANGED("general.scale") para re-escalar en vivo
             todas las ventanas registradas con TrackScale.
]]

local addonName, private = ...
local RD = _G.RaidDominion or {}
_G.RaidDominion = RD

local UIUtils = assert(RD.UIUtils, "RD_UI_Utils_Helpers.lua debe cargarse antes que RD_UI_Utils.lua")

-- =============================================
-- HELPERS GENERALES (compartidos por módulos/UI)
-- =============================================

-- Mensaje de sistema con fallback a print (si messageManager no está cargado).
-- Centraliza el patrón Log que se repetía en varios archivos.
function UIUtils.Log(msg)
    if RD.messageManager and RD.messageManager.SendSystemMessage then
        RD.messageManager:SendSystemMessage(msg)
    else
        print(msg)
    end
end

-- Orden estable por `order` (los ítems sin order conservan su posición relativa).
-- Centraliza el insertion-sort que se duplicaba en MenuFactory y ConfigWindow.
function UIUtils.SortByOrder(list)
    local sorted = {}
    for _, v in ipairs(list or {}) do table.insert(sorted, v) end
    for i = 2, #sorted do
        local key = sorted[i]
        local keyOrder = key.order or 0
        local j = i - 1
        while j >= 1 and (sorted[j].order or 0) > keyOrder do
            sorted[j + 1] = sorted[j]
            j = j - 1
        end
        sorted[j + 1] = key
    end
    return sorted
end

-- Copia profunda de una tabla (para sembrar listas sin compartir referencias).
function UIUtils.DeepCopy(orig)
    local origType = type(orig)
    if origType ~= "table" then return orig end
    local copy = {}
    for k, v in next, orig, nil do
        copy[UIUtils.DeepCopy(k)] = UIUtils.DeepCopy(v)
    end
    return setmetatable(copy, UIUtils.DeepCopy(getmetatable(orig)))
end

-- Estima el número de líneas envueltas de un texto a un ancho y fuente dados
-- (salto de línea + excedente por wrap). Se usa como fallback cuando la medición
-- de un FontString oculto devuelve 0 en 3.3.5a (layout diferido). Centraliza la
-- heurística que se duplicaba en ConfigWindow_Render y BandsPlayerEditor.
function UIUtils.EstimateWrappedLines(str, width, fontSize)
    local text = tostring(str or "")
    local fs = fontSize or 14
    local newlines = select(2, text:gsub("\n", "\n"))
    local cpl = math.max(30, math.floor((width or 400) * 2 / fs))
    return newlines + 1 + math.max(0, math.ceil(#text / cpl))
end

--[[
    Convención de EditBox multilínea dentro de un ScrollFrame (paridad entre el
    campo Notas del modal de editar jugador y el campo Mensaje del spammer):
    el EditBox de 3.3.5a no recorta su texto, así que se crea un FontString de
    medida oculto con el mismo ancho/fuente y se crece la caja a su contenido
    dentro del ScrollFrame (que lo recorta y scrollea). Si GetStringHeight()
    devuelve 0 (layout diferido en 3.3.5a) se usa EstimateWrappedLines como
    fallback. El alto mínimo es el alto actual del ScrollFrame.
    Devuelve la función resize() para asignar a OnTextChanged/OnTextSet.
]]
function UIUtils.MakeAutoResizeMultiline(editBox, scrollFrame, measureW)
    local measureFS = scrollFrame:CreateFontString(nil, "ARTWORK")
    local font, size = editBox:GetFont()
    if font and size then
        measureFS:SetFont(font, size)
    end
    measureFS:SetWordWrap(true)
    measureFS:SetJustifyH("LEFT")
    measureFS:Hide()

    return function()
        if not editBox or not scrollFrame then return end
        local _, fontSize = editBox:GetFont()
        local lineHeight = (fontSize or 15) * 1.2
        measureFS:SetWidth(measureW)
        measureFS:SetText(editBox:GetText() or "")
        local h = measureFS:GetStringHeight() or 0
        if h < lineHeight then
            local str = measureFS:GetText() or ""
            local estLines = UIUtils.EstimateWrappedLines(str, measureW, fontSize or 15)
            h = estLines * lineHeight
        end
        local minH = (scrollFrame.GetHeight and scrollFrame:GetHeight()) or 80
        editBox:SetHeight(math.max(minH, h + 8))
        if scrollFrame.UpdateScrollChildRect then
            scrollFrame:UpdateScrollChildRect()
        end
    end
end

-- =============================================
-- FRAMES: nombres únicos globales
-- =============================================

-- Contador ÚNICO del addon para nombres de frames. Centralizarlo aquí evita
-- colisiones entre archivos: en WoW 3.3.5a, CreateFrame con un nombre ya usado
-- devuelve el frame previo (no crea uno nuevo), lo que corrompía los botones de
-- cerrar (5 archivos generaban "RDCl1" cada uno con su contador local).
local nameCounter = 0
function UIUtils.UniqueName(prefix)
    nameCounter = nameCounter + 1
    return string.format("RD%s%d", prefix or "Ux", nameCounter)
end

-- Escala la fuente de un FontString (pct = 1.25 => +25%). Válido en 3.3.5a.
function UIUtils.ScaleFont(fs, pct)
    if not fs or not fs.GetFont then return end
    local font, size = fs:GetFont()
    if font and size then
        fs:SetFont(font, math.max(8, math.floor(size * (pct or 1))))
    end
end

-- =============================================
-- ESCALA GLOBAL (general.scale)
-- =============================================

-- Registro central de ventanas raíz que siguen la escala global. Cada ventana
-- llama a TrackScale al crear su frame; un único suscriptor de CONFIG_CHANGED
-- re-aplica la escala en vivo a todas (incluso las ocultas).
local scaledFrames = {}

-- Aplica la escala global (general.scale) a un frame raíz. Es el ÚNICO lugar
-- permitido para SetScale (AGENTS.md §6.3: solo en el frame raíz, nunca en hijos).
function UIUtils.ApplyScale(frame)
    if not frame or not frame.SetScale then return end
    local scale = 1.0
    if RD.config and RD.config.Get then
        local value = RD.config:Get("general.scale", 1.0)
        if type(value) == "number" and value > 0 then
            scale = value
        end
    end
    pcall(function()
        frame:SetScale(scale)
    end)
end

-- Registra una ventana raíz para que siga la escala global (la aplica al
-- instante y la mantiene actualizada ante cambios de general.scale).
function UIUtils.TrackScale(frame)
    if not frame then return end
    scaledFrames[frame] = true
    UIUtils.ApplyScale(frame)
end

-- Re-aplica la escala a todas las ventanas registradas.
local function ApplyAllScales()
    for frame in pairs(scaledFrames) do
        UIUtils.ApplyScale(frame)
    end
end

-- Suscripción central (única): cualquier cambio de general.scale re-escala en
-- vivo todas las ventanas del addon registradas.
if RD.events and RD.events.Subscribe then
    RD.events:Subscribe("CONFIG_CHANGED", function(key)
        if key == "general.scale" then
            ApplyAllScales()
        end
    end)
end

-- Limita el alto de un modal a la pantalla disponible (alto máximo). Si el alto
-- natural del modal supera el máximo, se reduce el `flexBox` (área que scrollea
-- internamente: EditBox multilínea o scroll frame) para que el modal quepa
-- completo. Los widgets que no caben siguen accesibles vía el scroll del flexBox.
function UIUtils.ClampModalToScreen(modal, flexBox, margin)
    if not modal or not modal.SetHeight then return end
    margin = margin or 20
    local scale = (UIParent and UIParent.GetScale and UIParent:GetScale()) or 1
    if not scale or scale <= 0 then scale = 1 end
    local screenH = (GetScreenHeight and GetScreenHeight() / scale) or 800
    local maxH = math.max(180, screenH - margin * 2)
    local naturalH = modal:GetHeight() or 0
    if naturalH <= maxH then return end
    local shrink = naturalH - maxH
    if flexBox and flexBox.SetHeight then
        flexBox:SetHeight(math.max(60, (flexBox:GetHeight() or 0) - shrink))
    end
    modal:SetHeight(maxH)
end

-- =============================================
-- COMPORTAMIENTO DE VENTANAS (paridad con paneles del juego)
-- =============================================

-- Strata compartida de las ventanas del addon. Los paneles de personaje de
-- WoW (CharacterFrame y cía.) viven en MEDIUM (estrato por defecto de
-- UIParent); las ventanas RD usan la misma capa para cubrirse/descubrirse
-- entre sí y con la UI del juego como lo haría un panel nativo. StaticPopups
-- (DIALOG) y GameTooltip (TOOLTIP) quedan SIEMPRE por encima.
UIUtils.WIN_STRATA = "MEDIUM"

-- Garantiza el clic → al frente de forma explícita y determinista. Un frame
-- con SetToplevel(true) ya se sube solo al mostrarse y al recibir clic en
-- 3.3.5a; además se registra Raise() en OnMouseDown si no existe un script
-- previo (los frames raíz del addon no lo usan, así que no hay conflicto).
function UIUtils.MakeClickToTop(frame)
    if not frame then return end
    frame:SetToplevel(true)
    if not frame:GetScript("OnMouseDown") then
        frame:SetScript("OnMouseDown", function(self)
            self:Raise()
        end)
    end
end

-- Configura una ventana raíz del addon con el comportamiento estándar de panel
-- de WoW: strata WIN_STRATA (o la indicada en opts.strata), toplevel
-- (activación sube al frente), clamp a pantalla y clic → al frente. Fuente
-- única de verdad para el setup de ventanas (AGENTS.md §6).
function UIUtils.SetupWindow(frame, opts)
    if not frame then return end
    opts = opts or {}
    frame:SetFrameStrata(opts.strata or UIUtils.WIN_STRATA)
    frame:SetToplevel(true)
    if frame.SetClampedToScreen then
        frame:SetClampedToScreen(true)
    end
    UIUtils.MakeClickToTop(frame)
end

-- Activa una ventana: la muestra y la sube al frente de sus hermanas del mismo
-- estrato (las demás quedan detrás sin tocarlas). Comportamiento de panel de
-- WoW: el elemento activo pasa al frente y los inactivos quedan detrás.
function UIUtils.ActivateWindow(frame)
    if not frame then return end
    frame:Show()
    frame:Raise()
end

-- =============================================
-- POOLING DE FRAMES
-- =============================================

local framePools = {}

-- Adquiere un frame de un pool o lo crea
function UIUtils.AcquireFrame(poolName, frameType, parent, template)
    local key = poolName .. (frameType or "Frame")
    if not framePools[key] then framePools[key] = {} end
    local pool = framePools[key]

    local frame = table.remove(pool)
    if not frame then
        frame = CreateFrame(frameType, nil, parent, template)
    else
        frame:SetParent(parent)
        frame:ClearAllPoints()
    end
    frame:Show()
    return frame
end

-- Libera un frame de vuelta al pool
function UIUtils.ReleaseFrame(poolName, frame)
    local frameType = frame:GetObjectType()
    local key = poolName .. frameType
    if not framePools[key] then framePools[key] = {} end

    frame:Hide()
    frame:SetParent(nil)
    frame:ClearAllPoints()
    table.insert(framePools[key], frame)
end

-- Debouncer compartido (coalesce llamadas encadenadas): p.ej. editar un campo
-- dispara un Set por tecla -> CONFIG_CHANGED -> refresh; con el debouncer el
-- refresh corre una sola vez transcurrido el delay tras la última llamada.
-- Devuelve { Fire = function, Cancel = function }. Fire reinicia el temporizador
-- y Show() el frame; onFire SE EJECUTA aunque la ventana se haya ocultado entre
-- medias, así que el propio onFire debe guardar con su isShown.
function UIUtils.NewDebouncer(delay, onFire)
    local f = CreateFrame("Frame")
    f:Hide()
    f.rdDelay = delay or 0.15
    f:SetScript("OnUpdate", function(self, elapsed)
        self.rdElapsed = (self.rdElapsed or 0) + elapsed
        if self.rdElapsed >= self.rdDelay then
            self:Hide()
            self.rdElapsed = 0
            onFire()
        end
    end)
    local debouncer = {
        Fire = function()
            f.rdElapsed = 0
            f:Show()
        end,
        Cancel = function()
            f:Hide()
            f.rdElapsed = 0
        end,
    }
    return debouncer
end

-- Crea un label (FontString)
function UIUtils.CreateLabel(parent, text, template)
    local label = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlight")
    label:SetText(text or "")
    return label
end

-- Mensaje vacío dentro de un scroll/panel (frame: se limpia con SetParent(nil))
function UIUtils.CreateEmptyMessage(parent, text, y)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(300, 20)
    f:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, y or 0)
    local fs = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetText(text)
    fs:SetTextColor(0.7, 0.7, 0.7)
    fs:SetJustifyH("LEFT")
    fs:SetPoint("LEFT", f, "LEFT", 0, 0)
    return f
end

-- Convención de lista vacía (editores de lista y CRUD de bandas): frame con la
-- indicación para crear el primer elemento, alineado a la izquierda con padding.
-- Devuelve el frame (se limpia con SetParent(nil)).
function UIUtils.CreateEmptyList(parent, width, text, y)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(width, 20)
    f:SetPoint("TOPLEFT", parent, "TOPLEFT", 6, y or 0)
    local fs = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetText(text)
    fs:SetTextColor(0.7, 0.7, 0.7)
    fs:SetJustifyH("LEFT")
    fs:SetPoint("LEFT", f, "LEFT", 0, 0)
    return f
end

-- ============================================================
-- CONVENCIONES DE ESTILO (jerarquía y consistencia)
-- Fuentes base de 3.3.5a: NormalLarge=15, Normal=12, NormalSmall=10.
-- Escala sobre esas fuentes base; usar vía UI_STYLE para que todo
-- el addon quede consistente (botones, inputs y jerarquía de títulos).
-- ============================================================
local UI_STYLE = {
    -- Inputs de texto (EditBox con InputBoxTemplate): 15px legible + insets
    input = { height = 24, textSize = 15, inset = 4 },
    -- Jerarquía de títulos (de mayor a menor)
    fonts = {
        windowTitle  = { template = "GameFontNormalLarge", scale = 1.25 },  -- ~19px  · título de ventana
        tab          = { template = "GameFontNormalSmall", scale = 1.25 },  -- ~13px  · pestañas
        sectionTitle = { template = "GameFontNormalSmall", scale = 1.5 },   -- ~15px  · sección (dorado)
        fieldLabel   = { template = "GameFontNormal",      scale = 1.25 },  -- ~15px  · etiqueta de campo
        contentText  = { template = "GameFontNormalSmall", scale = 1.25 },  -- ~12px  · cuerpo/texto
        hint         = { template = "GameFontNormalSmall", scale = 1.0 },   -- ~10px  · pistas/ayuda (gris)
    },
}

UIUtils.STYLE = UI_STYLE

-- Contrato de métricas compartido por las ventanas/módulos (grid 4px, AGENTS §6):
-- un único lugar para gutters, altos de control y geometría del panel inferior
-- de las secciones de rejilla. Casi todos los valores son múltiplos de GRID;
-- la ÚNICA excepción es ACTION_X (14px, ver su comentario).
UIUtils.Metrics = {
    GRID = 4,              -- cuadrícula base
    PAD = 4,               -- gutter lateral del contenido de una sección
    ACTION_X = 14,         -- ancla X de la fila de acción (PAD + 10px de ajuste
                           -- óptico pedido explícitamente por el usuario). ÚNICO
                           -- valor fuera del grid de 4px (excepción documentada
                           -- en harness/tests/test_ui_metrics.lua).
    INPUT_H = 24,          -- alto de EditBox (StyleInput)
    ACTION_H = 24,         -- alto de la fila de acción (input + botones)
    CHIP_H = 24,           -- alto de botones chip de acción (Registrar/Quitar)
    PANEL_H = 116,         -- alto del panel inferior fijo (equip/monedas)
    PANEL_TITLE_Y = -8,    -- ancla del título del panel (13/15px)
    PANEL_LINE1_Y = -28,   -- ancla de la 1ª línea de info del panel
    PANEL_LINE_PITCH = 20, -- separación vertical entre líneas del panel
    TRACK_S = 20,          -- lado del check de seguimiento (check por moneda/objetivo)
    TRACK_GAP = 4,         -- hueco entre el check y el texto/otro control (grid 4px)
    ROW_PITCH = 28,        -- pitch vertical de una fila de formulario (24 + 4)
    LIST_LINE_H = 16,      -- alto de línea de las listas con scroll (13px + aire)
}

-- Aplica la convención tipográfica de UI_STYLE a un FontString. `kind` es una
-- clave de UI_STYLE.fonts; escala la fuente base del template (mismo mecanismo
-- que ScaleFont, respetando el template que fija la fuente real en 3.3.5a).
function UIUtils.ApplyFontStyle(fs, kind)
    if not fs or not fs.GetFont then return end
    local spec = UI_STYLE.fonts[kind] or UI_STYLE.fonts.contentText
    if spec then UIUtils.ScaleFont(fs, spec.scale) end
end

-- Trunca `text` para que quepa en `width` con una fuente de `fontSize` px,
-- contando CARACTERES UTF-8 (los nombres son esMX) y añadiendo "…" si corta.
-- Heurístico (sin medir): en 3.3.5a el layout diferido puede dar 0; el ancho
-- medio de un glifo ronda ~0.55 * fontSize.
function UIUtils.TruncateToWidth(text, width, fontSize)
    local s = tostring(text or "")
    width = tonumber(width) or 0
    if width <= 0 then return s end
    local size = tonumber(fontSize) or 12
    local max = math.max(1, math.floor(width / (size * 0.55)))
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

-- Aplica la convención de input: alto estándar, insets interiores y fuente 15px.
function UIUtils.StyleInput(editBox)
    if not editBox or not editBox.SetTextInsets then return end
    editBox:SetHeight(UI_STYLE.input.height)
    editBox:SetTextInsets(UI_STYLE.input.inset, UI_STYLE.input.inset, UI_STYLE.input.inset, UI_STYLE.input.inset)
    if editBox.SetFont then
        local font = editBox:GetFont()
        editBox:SetFont(font, UI_STYLE.input.textSize)
    end
end

-- Crea un botón "chip": fondo oscuro translúcido, borde dorado suave, texto
-- dorado centrado y un highlight en hover (estética de los spammers). Usado
-- para pestañas, botones de salida puntual y, de forma general, todos los
-- botones con label de las ventanas/modales. El texto queda en `btn.rdText`
-- y se registra como el FontString del botón para que SetText()/GetText()/
-- GetFontString() funcionen igual que en un UIPanelButtonTemplate. El estado
-- deshabilitado (Enable/Disable) atenúa el texto, ya que un Button plano sin
-- template no lo atenúa solo.
function UIUtils.MakeChipButton(parent, name, w, h)
    local btn = CreateFrame("Button", name, parent)
    btn:SetSize(w, h)
    btn:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 12, insets = { left = 2, right = 2, top = 2, bottom = 2 } })
    btn:SetBackdropColor(0.1, 0.1, 0.1, 0.75)
    btn:SetBackdropBorderColor(1, 0.82, 0, 0.4)
    local text = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    text:SetPoint("LEFT", btn, "LEFT", 0, 0)
    text:SetPoint("RIGHT", btn, "RIGHT", 0, 0)
    text:SetJustifyH("CENTER")
    text:SetTextColor(1, 0.82, 0)
    UIUtils.ScaleFont(text, 1.25)
    btn:SetFontString(text)
    btn.rdText = text
    btn:SetScript("OnDisable", function() text:SetTextColor(0.55, 0.55, 0.55) end)
    btn:SetScript("OnEnable", function() text:SetTextColor(1, 0.82, 0) end)
    local hl = btn:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetTexture("Interface\\Buttons\\UI-Listbox-Highlight2")
    hl:SetBlendMode("ADD")
    hl:SetAlpha(0.35)
    hl:Hide()
    btn.rdHl = hl
    btn:SetScript("OnEnter", function() hl:Show() end)
    btn:SetScript("OnLeave", function() hl:Hide() end)
    return btn
end

-- Pintado de estado de un botón "chip" con borde dorado (ver MakeChipButton):
-- la pestaña activa se resalta con borde y fondo dorados, la inactiva queda tenue.
function UIUtils.PaintTabButton(btn, active)
    if not btn or not btn.SetBackdropBorderColor then return end
    if active then
        btn:SetBackdropBorderColor(1, 0.82, 0, 0.9)
        btn:SetBackdropColor(0.18, 0.14, 0.05, 0.85)
    else
        btn:SetBackdropBorderColor(1, 0.82, 0, 0.3)
        btn:SetBackdropColor(0.1, 0.1, 0.1, 0.6)
    end
end

--[[
    Habilita la navegación con Tab/Shift+Tab entre EditBoxes (convención de los
    spammer). 3.3.5a solo expone OnTabPressed (no hay OnShiftTabPressed ni
    SetTabInserting), así que Shift se detecta con IsShiftKeyDown() y OnTabPressed
    reemplaza el comportamiento por defecto del EditBox. `boxes` es una lista
    ORDENADA de EditBoxes: Tab avanza, Shift+Tab retrocede, con salto circular
    (el último vuelve al primero y viceversa).
]]
function UIUtils.EnableTabNavigation(boxes)
    if type(boxes) ~= "table" then return end
    -- Filtra entradas nil (ipairs corta en el primer hueco): el recorrido queda
    -- contiguo, en el orden dado.
    local list = {}
    for i = 1, #boxes do
        if boxes[i] and boxes[i].SetScript then
            list[#list + 1] = boxes[i]
        end
    end
    for i, box in ipairs(list) do
        box:SetScript("OnTabPressed", function()
            local target
            if IsShiftKeyDown() then
                target = list[i - 1] or list[#list]
            else
                target = list[i + 1] or list[1]
            end
            if target and target.SetFocus then target:SetFocus() end
        end)
    end
end


--[[
    CheckButton con label clicable (los FontString no reciben OnClick en 3.3.5a).
    Convención de los spammer y del widget central (RD_UI_Widgets:CreateCheckbox):
    el cuadrado del check + un botón transparente que cubre el texto alternan el
    estado y disparan el mismo handler que el check. Se limpia el texto del
    template "$parentText" para que no quede un label fantasma.
    Devuelve { check, labelButton }.
]]
function UIUtils.CreateToggleCheck(parent, text, onClick, opts)
    opts = opts or {}
    local check = CreateFrame("CheckButton", UIUtils.UniqueName("Ck"), parent, "UICheckButtonTemplate")
    local size = opts.size or 20
    check:SetSize(size, size)

    local templateText = getglobal(check:GetName() .. "Text")
    if templateText then
        templateText:SetText("")
    end

    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetText(text or "")
    label:SetJustifyH("LEFT")
    label:SetTextColor(0.8, 0.8, 0.8)

    -- Botón transparente sobre el label para alternar (mismo handler que el check)
    local labelButton = CreateFrame("Button", nil, parent)
    labelButton:SetHeight(math.max(20, size))
    labelButton:SetScript("OnClick", function(self)
        check:SetChecked(not check:GetChecked())
        if onClick then onClick(check) end
    end)

    -- El check dispara el mismo handler (normaliza 1/nil legacy de 3.3.5a)
    check:SetScript("OnClick", function(self)
        if onClick then onClick(self) end
    end)

    return check, labelButton, label
end

-- Aplica un estilo de mayor legibilidad al dropdown usado como TÍTULO de una
-- ventana (selector de banda/regla en los spammers): alto mayor, texto más
-- grande y con más aire. Recibe el dropdown de CreateOptionsDropdown.
function UIUtils.StyleTitleDropdown(dropdown)
    if not dropdown or not dropdown.button then return end
    local btn = dropdown.button
    btn:SetHeight(24)
    local text = dropdown.text
    if text then
        text:SetJustifyH("LEFT")
        text:SetPoint("LEFT", btn, "LEFT", 6, 0)
        text:SetPoint("RIGHT", btn, "RIGHT", -18, 0)
        if text.GetFont then
            local font, size = text:GetFont()
            if font and size then
                text:SetFont(font, math.max(8, math.floor(size * 1.4)))
            end
        end
    end
end

RD.UIUtils = UIUtils
RD.ui = RD.ui or {}
RD.ui.style = UI_STYLE
return UIUtils
