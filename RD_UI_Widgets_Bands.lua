--[[
    RD_UI_Widgets_Bands.lua
    PROPÓSITO: Editor CRUD de bandas para la pestaña "Bandas" de la configuración
              (CreateBands). Vive en un archivo propio, igual que los otros
              editores de lista, reutilizando la tabla RD.ui.widgets.
    API PÚBLICA:
        - RD.ui.widgets:CreateBands(parent, field, onChange)
    EVENTOS: Escribe vía RD.utils.bands / RD.config:Set (dispara CONFIG_CHANGED).
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
local CreateScrollFrame = Widgets.CreateScrollFrame
local EnableTabNavigation = RD.UIUtils and RD.UIUtils.EnableTabNavigation
local Log = (RD.UIUtils and RD.UIUtils.Log) or function(msg) print(msg) end


-- Acceso al módulo de bandas (con guarda; puede no estar cargado al renderizar)
local function BandsModule()
    return RD.utils and RD.utils.bands
end

-- Guarda los campos editables de una banda existente (dispara CONFIG_CHANGED)
local function SaveBandField(index, data)
    local bands = BandsModule()
    if bands and bands.UpdateBand then
        bands:UpdateBand(index, data)
    end
end

-- Días seleccionables del horario de banda. `key` es el token que se guarda en
-- la clave schedule ("DIA 20:00"); `label` es el texto corto del dropdown.
local DAY_OPTIONS = {
    { key = "DIA", label = "Día" },
    { key = "LUN", label = "Lun" },
    { key = "MAR", label = "Mar" },
    { key = "MIE", label = "Mié" },
    { key = "JUE", label = "Jue" },
    { key = "VIE", label = "Vie" },
    { key = "SAB", label = "Sáb" },
    { key = "DOM", label = "Dom" },
}

local function DayLabel(key)
    for _, o in ipairs(DAY_OPTIONS) do
        if o.key == key then return o.label end
    end
    return key or "DIA"
end

-- Separa una schedule ("DIA 20:00") en día y hora. Si el valor no tiene el
-- formato día+hora (legacy/libre, p.ej. "Ma y Ju 20:30"), el día se conserva
-- íntegro para que el editor no pierda datos al re-guardar.
local function ParseDayTime(sched)
    sched = sched or ""
    sched = sched:match("^%s*(.-)%s*$") or ""
    if sched == "" then return "DIA", "" end
    local day, time = sched:match("^(%S+)%s+(%d%d:%d%d)$")
    if day and time then return day, time end
    return sched, ""
end

-- Normaliza un texto a formato 24h "HH:MM" (acepta "H:MM" y "HH:MM").
-- Devuelve "" si el texto está vacío y nil si no es una hora válida.
local function NormalizeTime24(t)
    t = tostring(t or "")
    t = t:match("^%s*(.-)%s*$") or ""
    if t == "" then return "" end
    local h, m = t:match("^(%d%d):(%d%d)$")
    if not h or not m then
        h, m = t:match("^(%d):(%d%d)$")
    end
    if h and m then
        local hh = tonumber(h)
        local mm = tonumber(m)
        if hh and mm and hh <= 23 and mm <= 59 then
            return string.format("%02d:%02d", hh, mm)
        end
    end
    return nil
end

-- Compone la schedule a guardar desde el día seleccionado y la hora. Devuelve
-- nil si la hora es inválida y no está vacía (no se escribe basura a la DB).
local function ComposeSchedule(dayKey, timeText)
    local t = NormalizeTime24(timeText)
    if t == nil then return nil end
    if t == "" then return dayKey end
    return dayKey .. " " .. t
end

function Widgets:CreateBands(parent, field, onChange)
    if not parent or not field then return nil end

    local createScroll = Widgets.CreateScrollFrame
    if not createScroll then return nil end

    local height = field.height or 200
    local width = field.width or (parent.GetWidth and (parent:GetWidth() or 0) or 0)
    if width <= 0 then width = 452 end
    local scrollW = width - 26
    local childW = scrollW

    -- Geometría del editor (offsets enteros, grid 4px)
    local ADD_H = 22
    local ROW_H = 24
    local GAP = 6
    local HEADER_H = 14
    -- Fila de privacidad de las bandas ("Obtener"): vive dentro de la franja de
    -- creación (addBar), sobre la cabecera de columnas.
    local PRIV_H = 22

    -- Franja fija de creación (Añadir banda), siempre visible FUERA del scroll.
    -- EnableMouse: la franja captura el clic en su zona vacía para que NO caiga
    -- a través sobre los elementos que quedan debajo del editor.
    local addBar = CreateFrame("Frame", nil, parent)
    addBar:SetSize(childW, ADD_H + GAP + PRIV_H + GAP)
    addBar:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    addBar:EnableMouse(true)
    addBar:SetScript("OnMouseDown", function() end)
    addBar:SetScript("OnMouseUp", function() end)

    -- Franja fija de título de columnas (Nombre/GS mín/Día/Hora), también FUERA
    -- del scroll: no se oculta al desplazar y captura el clic en su zona vacía.
    local headerBar = CreateFrame("Frame", nil, parent)
    headerBar:SetSize(childW, HEADER_H + GAP)
    headerBar:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(ADD_H + GAP + PRIV_H + GAP))
    headerBar:EnableMouse(true)
    headerBar:SetScript("OnMouseDown", function() end)
    headerBar:SetScript("OnMouseUp", function() end)

    local scroll, child = createScroll(parent, scrollW, height, 0, -(ADD_H + GAP + PRIV_H + GAP + HEADER_H + GAP))
    child:SetWidth(childW)
    -- La fila de la ventana de config que aloja el editor consume el clic en su
    -- zona vacía: en 3.3.5a el child del scroll sobresale del viewport por el
    -- borde inferior (cola del contenido que no cabe) y ese área, al quedar
    -- fuera del rect del scroll, dejaría caer el clic a través de él hasta la
    -- sección siguiente de la ventana (p.ej. los anuncios bajo el editor de
    -- bandas). Los controles (addBar, headerBar, filas, viewport) son hijos y
    -- ganan en su propia zona.
    parent:EnableMouse(true)
    parent:SetScript("OnMouseDown", function() end)
    parent:SetScript("OnMouseUp", function() end)

    -- La franja fija queda POR ENCIMA del contenido del scroll para el hit-test
    -- de clic: en 3.3.5a el ScrollFrame no recorta el ratón de su contenido, así
    -- que una fila que asoma por el borde superior al hacer scroll solaparía
    -- físicamente estas franjas (invisible pero capturando el clic). Se eleva su
    -- frame level sobre el scroll y sus filas para que la franja gane siempre el
    -- clic en su propia zona.
    local barLevel = (scroll and scroll.GetFrameLevel and scroll:GetFrameLevel() or 0) + 5
    if addBar.SetFrameLevel then addBar:SetFrameLevel(barLevel) end
    if headerBar.SetFrameLevel then headerBar:SetFrameLevel(barLevel) end

    -- Columnas dimensionadas al CONTENIDO real: se miden los textos de la cabecera
    -- con la misma fuente que se usa para dibujarlos (GameFontNormalSmall escala
    -- 1.5) y cada columna recibe texto + margen. Así "GS mín" nunca envuelve y el
    -- InputBox de la hora conserva su propio espacio.
    local RM_W = 70
    local ACTIONS_GAP = 12
    local LEFT_PAD = 4
    -- El bloque de acciones (grip 20 + ojo 20 + eliminar 20 + juntas) vive a la
    -- derecha, FUERA del área de campos: se reservan RM_W y un respiro ACTIONS_GAP
    -- para que el agarre de arrastre quede siempre visible y clicable.
    local availW = math.max(240, childW - RM_W - ACTIONS_GAP - LEFT_PAD)

    -- Medidor temporal (oculto) con la fuente exacta de las cabeceras
    local measureFS = headerBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    measureFS:SetTextColor(1, 0.82, 0)
    RD.UIUtils.ScaleFont(measureFS, 1.5)
    measureFS:Hide()
    local function MeasureText(txt)
        measureFS:SetText(txt)
        return math.ceil(measureFS:GetStringWidth() or 0)
    end

    -- Anchos por columna: el label más largo + el margen que necesita el control
    -- (el dropdown del día lleva su flecha a la derecha, los InputBox sus insets).
    local GS_W = math.max(62, MeasureText("GS mín") + 12)
    local DIA_W = math.max(82, MeasureText("Sáb") + 30)
    local HORA_W = math.max(54, MeasureText("20:30") + 16)
    local NAME_MIN = 140
    -- Tope del nombre: da espacio de sobra a la banda, pero sin empujar a
    -- Día/Hora contra las acciones (el grip se quedaría tapado).
    local NAME_MAX = 320

    local fixedW = GS_W + DIA_W + HORA_W + 3 * GAP
    local NAME_W = availW - fixedW
    if NAME_W > NAME_MAX then
        NAME_W = NAME_MAX
    elseif NAME_W < NAME_MIN then
        -- Ancho escaso: se recorta Día y Hora (con mínimos que respetan sus
        -- controles) antes que el nombre, y nunca se desborda.
        local deficit = NAME_MIN - NAME_W
        local take = math.min(deficit, DIA_W - 74)
        DIA_W = DIA_W - take
        deficit = deficit - take
        take = math.min(deficit, HORA_W - 50)
        HORA_W = HORA_W - take
        deficit = deficit - take
        NAME_W = NAME_MIN - deficit
    end

    local bandRows = {}

    local function ClearRows()
        -- Mismo guard de 3.3.5a que en CreateList: liberar foco antes de ocultar.
        for _, r in ipairs(bandRows) do
            if r and r.Hide then
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
        bandRows = {}
    end

    -- Cabecera de columna en la franja fija headerBar (no se reconstruye).
    local function MakeHeaderLabel(x, label, w)
        local fs = headerBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetText(label)
        fs:SetTextColor(1, 0.82, 0)
        fs:SetJustifyH("LEFT")
        fs:SetPoint("LEFT", headerBar, "LEFT", x, 0)
        fs:SetWidth(w)
        RD.UIUtils.ScaleFont(fs, 1.5)
        return fs
    end
    -- Etiquetas fijas de columnas (las filas del scroll comparten los mismos x).
    -- Los labels de "Día"/"Hora" se corren sobre el CONTENIDO visible de sus
    -- controles: el template del dropdown dibuja su botón con margen interno a la
    -- izquierda (~20px) y el InputBox de la hora parte tras una columna de día más
    -- ancha que su texto, por lo que su label necesita apoyarse +50px adentro.
    MakeHeaderLabel(LEFT_PAD, "Nombre", NAME_W)
    MakeHeaderLabel(LEFT_PAD + NAME_W + GAP, "GS mín", GS_W)
    MakeHeaderLabel(LEFT_PAD + NAME_W + GAP + GS_W + GAP + 20, "Día", DIA_W)
    MakeHeaderLabel(LEFT_PAD + NAME_W + GAP + GS_W + GAP + DIA_W + GAP + 50, "Hora", HORA_W)

    local BuildRows

    -- Fila superior: botón de añadir banda (en la franja fija OUT del scroll)
    local addBtn = RD.UIUtils.MakeChipButton(addBar, UniqueName("BAdd"), 130, ADD_H)
    addBtn:SetPoint("TOPLEFT", addBar, "TOPLEFT", 0, 0)
    addBtn:SetText("Añadir banda")
    RD.UIUtils.AddButtonTooltip(addBtn, function() return "Crea una nueva banda en la lista." end)
    addBtn:SetScript("OnClick", function()
        local bands = BandsModule()
        if bands and bands.CreateBand then
            local index = bands:CreateBand({ name = "Nueva banda", minGS = 5000, schedule = "DIA 20:00" })
            BuildRows()
            local row = bandRows[index]
            if row and row.nameBox then
                row.nameBox:SetFocus()
                row.nameBox:HighlightText()
            end
        end
    end)

    -- Obtener del líder + Reiniciar (borra TODAS las bandas) vía helper compartido
    local actions = RD.ui.widgets and RD.ui.widgets.CreateListActionButtons
        and RD.ui.widgets:CreateListActionButtons(addBar, addBtn, {
            listKey = "bands",
            label = "bandas",
            obtainWidth = 90,
            resetWidth = 90,
            obtainConfirm = "¿Pedir la lista de bandas al líder? Se añadirán solo las bandas que no tengas (sin duplicados ni pérdidas).",
            resetTooltip = "Borra TODAS las bandas y sus jugadores (no hay valores por defecto de bandas).",
            resetConfirm = "¿Borrar TODAS las bandas? Se perderán sus jugadores, asistencia y sanciones.",
            resetAccept = "Borrar todo",
            onReset = function()
                if RD.config and RD.config.Set then
                    RD.config:Set("bands", {})
                end
                BuildRows()
            end,
        })

    -- La franja de creación (addBar) queda FUERA del scroll: no hay frames de
    -- acciones que ocultar por visibilidad.

    -- Privacidad de las bandas ante "Obtener" (sobre la lista, en la franja fija).
    if RD.ui and RD.ui.widgets and RD.ui.widgets.CreatePrivacyDropdown then
        RD.ui.widgets:CreatePrivacyDropdown(addBar, "bands", { x = 6, y = -(ADD_H + GAP) })
    end

    BuildRows = function()
        ClearRows()

        -- Inválida el closure viejo de visibilidad antes de tocar el scroll
        -- (ver RD_UI_Widgets_List.lua): SetHeight/SetVerticalScroll del scroll
        -- disparan OnScrollRangeChanged/OnVerticalScroll que, con el closure
        -- anterior, podrían re-mostrar filas ya limpiadas como fantasmas.
        scroll.RDRefreshVisibility = nil

        local bands = BandsModule()
        local list = {}
        if bands and bands.GetBands then
            list = bands:GetBands()
        end
        if type(list) ~= "table" then list = {} end

        -- Las filas arrancan en el TOP del scroll: las cabeceras de columna
        -- viven en la franja fija headerBar, fuera del scroll.
        local y = 0

        -- Cada banda: una fila con nombre, gearscore mínimo, día y hora editables.
        -- Las filas capturan el índice de la banda en la lista; tras cualquier
        -- cambio estructural (añadir/eliminar) se reconstruyen los índices.
        for i, band in ipairs(list) do
            local row = CreateFrame("Frame", nil, child)
            row:SetSize(childW, ROW_H)
            row:SetPoint("TOPLEFT", child, "TOPLEFT", 0, y)
            RD.UIUtils.AddRowHover(row)

            -- Nombre (edición en vivo). Un nombre de banda puede ser un enlace de chat
            -- (p.ej. pegar un logro como nombre, que luego se muestra con LinkLabel
            -- en los submenús); se aplica el mismo auto-detect + re-inyección.
            local nameBox = CreateFrame("EditBox", UniqueName("BNm"), row, "InputBoxTemplate")
            nameBox:SetSize(NAME_W, 22)
            nameBox:SetPoint("LEFT", row, "LEFT", LEFT_PAD, 0)
            nameBox:SetAutoFocus(false)
            RD.UIUtils.StyleInput(nameBox)
            local bandLinkAware = RD.UIUtils and RD.UIUtils.MakeLinkAwareEditBox
            if bandLinkAware then
                bandLinkAware(nameBox, band.name or "", {
                    onChange = function(raw)
                        SaveBandField(i, { name = raw })
                    end,
                    -- Enter/Esc liberan el foco (el guardado ya fue en vivo).
                    onCommit = function() end,
                })
            else
                nameBox:SetText(band.name or "")
                nameBox:SetScript("OnTextChanged", function(self)
                    SaveBandField(i, { name = self:GetText() })
                end)
            end
            -- Enter/Escape liberan el foco (estilo KRT) para usar atajos del teclado.
            nameBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
            nameBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
            row.nameBox = nameBox

            -- Gearscore mínimo (numérico; se guarda al confirmar/foco perdido)
            local gsBox = CreateFrame("EditBox", UniqueName("BGS"), row, "InputBoxTemplate")
            gsBox:SetSize(GS_W, 22)
            gsBox:SetNumeric(true)
            gsBox:SetAutoFocus(false)
            if RD.UIUtils and RD.UIUtils.DisableLinkInsertion then
                RD.UIUtils.DisableLinkInsertion(gsBox)
            end
            gsBox:SetPoint("LEFT", nameBox, "RIGHT", GAP, 0)
            gsBox:SetText(tostring(tonumber(band.minGS) or 0))
            RD.UIUtils.StyleInput(gsBox)
            local function SaveGS(self)
                SaveBandField(i, { minGS = tonumber(self:GetText()) or 0 })
                self:ClearFocus()
            end
            gsBox:SetScript("OnEnterPressed", SaveGS)
            gsBox:SetScript("OnEscapePressed", SaveGS)
            gsBox:SetScript("OnEditFocusLost", SaveGS)
            row.gsBox = gsBox

            -- Horario → día (dropdown seleccionable) + hora (formato 24h HH:MM).
            -- El almacenamiento es la misma cadena schedule ("DIA 20:00").
            local dayKey, timeText = ParseDayTime(band.schedule or "")
            local dayActual = dayKey
            -- Declaración adelantada: el init del dropdown referencia la hora;
            -- se asigna justo después, antes de que se toque (solo al hacer clic).
            local hourBox

            local dayBtn = CreateFrame("Frame", UniqueName("BDy"), row, "UIDropDownMenuTemplate")
            dayBtn:SetPoint("LEFT", gsBox, "RIGHT", GAP, 0)
            UIDropDownMenu_SetWidth(dayBtn, DIA_W)
            UIDropDownMenu_SetAnchor(dayBtn, 0, 0)
            -- Días conocidos + el token actual si no coincide con ninguno (los
            -- valores legacy se conservan y vuelven a guardarse tal cual).
            local function DayInitFunc()
                local info = UIDropDownMenu_CreateInfo()
                local known = {}
                for _, o in ipairs(DAY_OPTIONS) do known[o.key] = true end
                local ordered = {}
                for _, o in ipairs(DAY_OPTIONS) do ordered[#ordered + 1] = o end
                if dayActual ~= "" and not known[dayActual] then
                    ordered[#ordered + 1] = { key = dayActual, label = dayActual }
                end
                for _, o in ipairs(ordered) do
                    info.text = o.label
                    info.value = o.key
                    info.checked = (o.key == dayActual)
                    info.func = function()
                        dayActual = o.key
                        UIDropDownMenu_SetSelectedValue(dayBtn, o.key)
                        UIDropDownMenu_SetText(dayBtn, DayLabel(o.key))
                        local composed = ComposeSchedule(o.key, hourBox:GetText())
                        if composed then SaveBandField(i, { schedule = composed }) end
                    end
                    UIDropDownMenu_AddButton(info)
                end
            end
            UIDropDownMenu_Initialize(dayBtn, DayInitFunc)
            UIDropDownMenu_SetSelectedValue(dayBtn, dayActual)
            UIDropDownMenu_SetText(dayBtn, DayLabel(dayActual))
            row.dayBtn = dayBtn

            hourBox = CreateFrame("EditBox", UniqueName("BHr"), row, "InputBoxTemplate")
            hourBox:SetSize(HORA_W, 22)
            hourBox:SetAutoFocus(false)
            if RD.UIUtils and RD.UIUtils.DisableLinkInsertion then
                RD.UIUtils.DisableLinkInsertion(hourBox)
            end
            hourBox:SetPoint("LEFT", dayBtn, "RIGHT", GAP, 0)
            hourBox:SetText(timeText)
            RD.UIUtils.StyleInput(hourBox)
            RD.UIUtils.AddButtonTooltip(hourBox, function() return "Hora en formato 24h (p. ej. 20:30)." end)
            local function SaveHour(self)
                local composed = ComposeSchedule(dayActual, self:GetText())
                if composed then SaveBandField(i, { schedule = composed }) end
                self:ClearFocus()
            end
            hourBox:SetScript("OnEnterPressed", SaveHour)
            hourBox:SetScript("OnEscapePressed", SaveHour)
            hourBox:SetScript("OnEditFocusLost", SaveHour)
            row.hourBox = hourBox

            -- Agarre de arrastre: reordena las bandas con click-drag → click-drop.
            local grip = Widgets.CreateGrip and Widgets:CreateGrip(row)
            if grip and Widgets.EnableRowDrag then
                Widgets:EnableRowDrag(grip, {
                    scroll = scroll,
                    child = child,
                    cols = 1,
                    cellW = childW,
                    colGap = 0,
                    rowH = ROW_H,
                    gap = GAP,
                    -- Las cabeceras de columna viven en su franja fija (fuera
                    -- del scroll): las filas arrancan en el top del scroll.
                    firstTop = 0,
                    gridRows = function()
                        local bm = BandsModule()
                        return (bm and bm.GetBands and #(bm:GetBands() or {})) or 0
                    end,
                    source = i,
                    itemCount = function()
                        local bm = BandsModule()
                        return (bm and bm.GetBands and #(bm:GetBands() or {})) or 0
                    end,
                    label = band.name,
                    commitTarget = function(target)
                        local bm = BandsModule()
                        if not bm or not bm.GetBands then return end
                        local blist = bm:GetBands()
                        if type(blist) ~= "table" then return end
                        local src = i
                        if target < 1 then target = 1 end
                        if target > #blist + 1 then target = #blist + 1 end
                        if target == src or target == src + 1 then return end
                        local temp = blist[src]
                        table.remove(blist, src)
                        local idx = target
                        if idx > src then idx = idx - 1 end
                        table.insert(blist, idx, temp)
                        local copy = {}
                        for idx2, bd in ipairs(blist) do copy[idx2] = bd end
                        if RD.config and RD.config.Set then RD.config:Set("bands", copy) end
                        BuildRows()
                        if onChange then onChange(field, blist) end
                    end,
                })
            end

            -- Botón visibilidad en el menú flotante (ojo), antes del eliminar
            local visBtn = RD.ui.widgets:CreateVisibilityToggle(row, band, function()
                local bands = BandsModule()
                if bands and RD.config and RD.config.Set then
                    local list = bands:GetBands()
                    local copy = {}
                    for idx, bd in ipairs(list) do copy[idx] = bd end
                    RD.config:Set("bands", copy)
                end
                if onChange then onChange(field, bands and bands:GetBands()) end
            end, function() BuildRows() end)

            -- Botón eliminar banda
            local removeBtn = CreateFrame("Button", UniqueName("BRm"), row)
            removeBtn:SetSize(20, 20)
            local rmTex = removeBtn:CreateTexture(nil, "ARTWORK")
            rmTex:SetAllPoints()
            rmTex:SetTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")
            removeBtn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
            -- Bloque de acciones a la derecha: [agarre][ojo][eliminar]
            removeBtn:SetPoint("RIGHT", row, "RIGHT", 0, 0)
            visBtn:SetPoint("RIGHT", removeBtn, "LEFT", -2, 0)
            if grip then grip:SetPoint("RIGHT", visBtn, "LEFT", -2, 0) end
            removeBtn:SetScript("OnClick", function()
                local dialogs = RD.ui and RD.ui.dialogs
                local bands = BandsModule()
                if not bands then return end
                local bandName = (bands.GetBand and (bands:GetBand(i) or {}).name) or "la banda"
                local function DoDelete()
                    if bands.DeleteBand then
                        bands:DeleteBand(i)
                    end
                    BuildRows()
                    if onChange then onChange(field, bands:GetBands()) end
                end
                if dialogs and dialogs.ShowConfirmDialog then
                    dialogs:ShowConfirmDialog({
                        text = string.format("¿Eliminar la banda '%s'? Se borrarán sus jugadores y asistencia.", tostring(bandName)),
                        acceptText = "Eliminar",
                        cancelText = "Cancelar",
                        onAccept = DoDelete,
                    })
                else
                    DoDelete()
                end
            end)

            bandRows[i] = row
            y = y - (ROW_H + GAP)
        end

        if #list == 0 then
            local empty = RD.UIUtils and RD.UIUtils.CreateEmptyList
                and RD.UIUtils.CreateEmptyList(child, childW, "Lista vacía: pulsa 'Añadir banda' para crear la primera banda.", 0)
            if empty then bandRows[1] = empty end
            y = y - 20
        end

        -- Navegación con Tab entre los campos de cada banda: nombre → GS mín →
        -- hora (fila a fila, con salto circular). El dropdown de día no toma
        -- foco por teclado (se abre con el ratón); los días se oscilan con las
        -- flechas mientras el menú está abierto.
        if EnableTabNavigation then
            local boxes = {}
            for _, r in ipairs(bandRows) do
                if r.nameBox then boxes[#boxes + 1] = r.nameBox end
                if r.gsBox then boxes[#boxes + 1] = r.gsBox end
                if r.hourBox then boxes[#boxes + 1] = r.hourBox end
            end
            EnableTabNavigation(boxes)
        end

        child:SetHeight(math.max(1, -y))
        if scroll.SetVerticalScroll then scroll:SetVerticalScroll(0) end
        -- Viewport dinámico: se ajusta al contenido real (compacto si no hay
        -- bandas), con tope en field.height. La altura total incluye las dos
        -- franjas fijas (addBar + headerBar) que viven fuera del scroll.
        local viewH = math.max(1, math.min(height, math.max(1, -y)))
        scroll:SetHeight(viewH)
        if parent.SetHeight then
            parent:SetHeight(ADD_H + GAP + PRIV_H + GAP + HEADER_H + GAP + viewH)
        end

        -- Visibilidad de las filas dentro del viewport: oculta las filas que
        -- quedan fuera de rango para que no reciban clics "a través" de los
        -- campos que haya debajo de la lista (p.ej. los anuncios de banda). La
        -- franja de creación (addBar) queda siempre visible.
        if Widgets.ApplyScrollVisibility then
            Widgets:ApplyScrollVisibility(scroll, bandRows)
        end
    end

    BuildRows()

    return scroll
end

return Widgets
