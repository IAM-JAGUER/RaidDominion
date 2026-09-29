--[[
    RD_UI_BandsPlayerEditor.lua
    PROPÓSITO: Ventana modal "Jugador". Organizada en secciones accesibles
              desde una tira de ICONOS alineada sobre el borde derecho de la
              ventana (estilo pestañas de un folder, RD.ui.widgets
              CreateIconTabStrip): una sola sección abierta a la vez, como antes
              con el acordeón, pero liberando todo el alto del cuerpo:
                - Información  : identidad del jugador (nombre, clase y notas)
                  + Guardar/Cancelar.
                - Equipamiento : equipamiento en vivo, SOLO para uno mismo.
                - Bandas       : pertenencias del jugador como enlaces al gestor
                  de jugadores de cada banda + control para añadirlo a otra
                  banda (RD.ui.playerEditorSections).
                - Instancias   : mazmorras/bandas guardadas, SOLO para uno mismo.
                - Monedas      : monedas/emblemas, SOLO para uno mismo.
              El frame se crea UNA vez y se reutiliza. Registra RD.ui.playerEditor.
    API PÚBLICA:
        - RD.ui.playerEditor:OpenPlayerEditor(opts)
              opts = { bandIndex, player (nil si es nuevo), onSaved, prefill }
        - RD.ui.playerEditor:GetFrame()        -- frame del editor (o nil si no se creó)
        - RD.ui.playerEditor:SwitchTo(key)     -- cambia de sección (la usa la UI)
    EVENTOS: Ninguno. Escribe vía RD.utils.bands (dispara CONFIG_CHANGED).
]]

local addonName, private = ...
local RD = _G.RaidDominion or {}
_G.RaidDominion = RD

local PlayerEditor = {}

local editor = nil

local GOLD_R, GOLD_G, GOLD_B = unpack((RD.constants and RD.constants.COLORS and RD.constants.COLORS.GOLD) or { 1, 0.82, 0 })

-- Nombre único para frames con template (los templates crean hijos con $parent).
-- Se delega en el contador ÚNICO de RD.UIUtils para evitar colisiones entre archivos.
local UniqueName = RD.UIUtils and RD.UIUtils.UniqueName

local CLASS_LIST = { "", "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DEATHKNIGHT", "DRUID" }

-- Ancho del dropdown de clase: igual al del input de nombre (160) para que los
-- bordes derechos de los campos queden alineados en el formulario.
local CLASS_DD_W = 160

-- Constantes de la tira de iconos y del cuerpo (grid 4px). La tira y el cuerpo
-- arrancan a la misma altura (BODY_TOP/TAB_Y) para que la pestaña y el contenido
-- queden a la par; sin la pila de pills el cuerpo usa todo el alto disponible.
local BODY_TOP = -40          -- inicio del cuerpo (bajo el título)
local TAB_Y = -40             -- ancla TOPRIGHT de la tira (bajo el botón X)
-- Espacio reservado para Guardar/Cancelar: 52 px para dejar aire entre el panel
-- de datos de la sección activa y la fila de botones, con la línea divisoria
-- (DIVIDER_Y) a medio camino (8 px sobre el tope de los botones y 8 bajo el cuerpo).
local BOTTOM_H = 52
local DIVIDER_Y = 44
-- La tira mide 36 px (icono 28 + 2*pad 4). overhang = 32 < 36 hace que el frame
-- de la tira SOLAPE 4 px al borde derecho de la ventana: su fondo (inset 2) cae
-- en x=418 y el borde visible de la ventana (inset 4) en x=416, con lo que los
-- dos backdrops se tocan (hueco visual 6px -> 2px; "tira pegada", pedido UX).
-- Los botones van a pad=4 del frame -> su borde izquierdo queda en x=420, NO
-- entran en la ventana; la barra de scroll termina en x=404 -> 12 px de margen.
-- El frame de la tira es EnableMouse(true): absorbe el clic y NO lo deja pasar
-- a lo que haya debajo (pedido UX); la tira es un contenedor "ciego" (sin OnClick
-- propio), y el borde de la ventana (x < 416) sigue siendo arrastrable.
local TAB_OVERHANG = 32
-- Margen de 24 px reservado a la derecha del contenido para la barra de scroll
-- (16 px de barra + 8 px de aire). Sin él, la barra (anclada fuera del scroll,
-- a +4 de su borde derecho) llegaría hasta el borde de la ventana y chocaría con
-- la tira de pestañas; y con la barra DENTRO del scroll taparía texto y los
-- chips clicables de las listas.
local SCROLL_GUTTER = 24

-- Orden, etiquetas, icono y tooltip de las secciones (fuente única de datos de
-- la tira; los iconos son rutas Interface\Icons de 3.3.5a).
local SECTIONS = {
    { key = "info",      label = "Información",  selfOnly = false,
      icon = "Interface\\Icons\\INV_Misc_Note_02",       tip = "Nombre, clase y notas del jugador." },
    { key = "equip",     label = "Equipamiento", selfOnly = true,
      icon = "Interface\\Icons\\INV_Sword_04",           tip = "Equipamiento en vivo de tu personaje.\nMayús+clic: insertar el enlace en el chat activo.\nEl check del panel añade el objetivo al tooltip del botón Jugador." },
    { key = "bands",     label = "Bandas",       selfOnly = false,
      icon = "Interface\\Icons\\INV_Misc_Book_09",       tip = "Bandas donde está registrado y alta en otra banda." },
    { key = "instances", label = "Instancias",   selfOnly = true,
      icon = "Interface\\Icons\\INV_Misc_Map_01",        tip = "Mazmorras y bandas guardadas." },
    { key = "monedas",   label = "Monedas",      selfOnly = true,
      icon = "Interface\\Icons\\INV_Misc_Coin_01",       tip = "Monedas y emblemas de tu personaje." },
}

local sectionByKey = {}
for _, sec in ipairs(SECTIONS) do sectionByKey[sec.key] = sec end

-- Nombre localizado de una clase (classFile)
local function ClassLabel(classFile)
    if classFile and classFile ~= "" and _G.LOCALIZED_CLASS_NAMES and _G.LOCALIZED_CLASS_NAMES[classFile] then
        return _G.LOCALIZED_CLASS_NAMES[classFile]
    end
    return classFile and classFile ~= "" and classFile or "Sin clase"
end

-- Limpia un nombre (sin reino, minúsculas)
local function CleanName(name)
    if RD.UIUtils and RD.UIUtils.CleanName then
        return RD.UIUtils.CleanName(name)
    end
    local clean = string.gsub(tostring(name or ""), "%-.*", "")
    clean = string.gsub(clean, "%s+", "")
    return string.lower(clean)
end

-- Si el jugador a editar es uno mismo (habilita Instancias/Monedas/Equipamiento)
local function IsSelf(name)
    local selfName
    if UnitName then selfName = UnitName("player") end
    return selfName ~= nil and CleanName(selfName) == CleanName(name)
end

-- ============================================================================
-- Construcción de la ventana (una sola vez)
-- ============================================================================

-- Crea el frame del cuerpo de una sección. Se posiciona bajo el título (bodyY
-- negativo) y se estira hasta el borde superior de la fila de botones; el alto
-- solo depende de la ventana (lo reajusta LayoutBodies, no las pestañas).
local function MakeSectionBody(parent, width, height, bodyY)
    local body = CreateFrame("Frame", nil, parent)
    body:SetSize(width, height)
    body:SetPoint("TOPLEFT", parent, "TOPLEFT", 12, bodyY)
    body:Hide()
    return body
end

local function BuildEditor()
    editor = CreateFrame("Frame", "RaidDominionPlayerEditor", UIParent)
    -- Strata MEDIUM (paridad con los paneles de personaje de WoW): el editor se
    -- cubre/descubre con la UI del juego y pasa al frente al activarlo.
    if RD.UIUtils and RD.UIUtils.SetupWindow then
        RD.UIUtils.SetupWindow(editor)
    else
        editor:SetFrameStrata("MEDIUM")
        editor:SetToplevel(true)
        editor:SetClampedToScreen(true)
    end
    editor:SetSize(420, 500)
    editor:EnableMouse(true)
    editor:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    editor:SetBackdropColor(0, 0, 0, 0.95)
    editor:SetBackdropBorderColor(1, 1, 1, 0.5)
    table.insert(UISpecialFrames, "RaidDominionPlayerEditor")
    if RD.UIUtils and RD.UIUtils.TrackScale then RD.UIUtils.TrackScale(editor) end

    -- Arrastrable desde cualquier zona no interactiva del editor
    editor:SetMovable(true)
    editor:RegisterForDrag("LeftButton")
    editor:SetScript("OnDragStart", function() editor:StartMoving() end)
    editor:SetScript("OnDragStop", function()
        editor:StopMovingOrSizing()
        -- SetClampedToScreen acota el frame, NO la tira de pestañas que sobresale
        -- a la derecha: sin este re-clam al soltar, arrastrar el editor contra el
        -- borde derecho dejaría las pestañas fuera de pantalla (inalcanzables).
        local layout = RD.ui and RD.ui.layout
        if layout and layout.EnsureVisible then
            layout:EnsureVisible(editor, TAB_OVERHANG + 8)
        end
    end)

    -- Sin "clic fuera cierra": el editor NO se cierra al hacer clic fuera, para
    -- no perder lo escrito (se cierra con Guardar/Cancelar o el botón X). El
    -- Escape libera el foco de los campos (y un segundo Escape, sin campo
    -- enfocado, cierra la ventana vía UISpecialFrames).
    editor:SetScript("OnHide", function()
        editor.onSaved = nil
        editor.player = nil
    end)

    local title = editor:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOP", editor, "TOP", 0, -10)
    title:SetText("Jugador")
    editor.title = title
    -- Jerarquía de UI_STYLE: el título de ventana es la mayor escala del addon
    -- (era del mismo tamaño que las etiquetas de campo; eso aplanaba la jerarquía).
    if RD.UIUtils and RD.UIUtils.ApplyFontStyle then
        RD.UIUtils.ApplyFontStyle(title, "windowTitle")
    else
        RD.UIUtils.ScaleFont(title, 1.5)
    end

    local closeBtn = CreateFrame("Button", UniqueName("Cl"), editor, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", editor, "TOPRIGHT", -4, -4)
    closeBtn:SetScript("OnClick", function() editor:Hide() end)

    -- Contenedor del cuerpo (ancho interior fijo) y alto disponible: la ventana
    -- mide 420x500; sin pills, bodyH = alto - fila de botones - margen superior.
    local innerW = (editor:GetWidth() or 420) - 24
    local bodyBottom = (editor:GetHeight() or 500) - BOTTOM_H
    local bodyH = bodyBottom - math.abs(BODY_TOP)

    editor.bodies = {}
    editor.openSection = "info"

    -- Cuerpos de sección: un frame por sección, creado UNA vez y reutilizado
    -- (se muestra el de la sección activa). El alto solo depende de la ventana,
    -- no de cuántas pestañas sean visibles (lo reajusta LayoutBodies).
    for _, sec in ipairs(SECTIONS) do
        local body = MakeSectionBody(editor, innerW, math.max(60, bodyH), BODY_TOP)
        editor.bodies[sec.key] = body
    end

    -- Tira de iconos "pestañas de folder" sobre el borde derecho. isVisible
    -- aplica selfOnly según ed.isSelf (se setea en OpenPlayerEditor ANTES del
    -- Refresh/SwitchTo). Al pulsar se conmuta de sección (re-render "Bandas"
    -- refleja cambios al añadir).
    local widgets = RD.ui and RD.ui.widgets
    if widgets and widgets.CreateIconTabStrip then
        editor.tabStrip = widgets:CreateIconTabStrip(editor, SECTIONS, {
            y = TAB_Y,
            overhang = TAB_OVERHANG,
            isVisible = function(key)
                local sec = sectionByKey[key]
                return sec and ((not sec.selfOnly) or editor.isSelf)
            end,
            onSelect = function(key)
                PlayerEditor:SwitchTo(key)
            end,
        })
    end

    -- ========================================================================
    -- SECCIÓN "INFORMACIÓN" (controles clásicos del editor)
    -- ========================================================================
    local infoBody = editor.bodies["info"]

    -- Gutter lateral y pitch vertical compartidos (grid 4px, UIUtils.Metrics).
    -- Las etiquetas se centran contra el input de 24px poniendo su tope 4 px por
    -- encima del control (label top = rowTop - 4): 15px en un alto de 24 quedan
    -- centradas dentro de la cuadrícula (desfase ≤ 0.5px, nunca media píxel).
    local InfoMetrics = (RD.UIUtils and RD.UIUtils.Metrics) or { PAD = 4, ROW_PITCH = 28 }
    local PAD = InfoMetrics.PAD or 4
    local ROW_PITCH = InfoMetrics.ROW_PITCH or 28
    local LABEL_X = PAD
    local INPUT_X = 96
    -- Tope del campo de Notas, DERIVADO de la cuadrícula (fila 3 bajo las dos
    -- primeras), no un literal suelto: -8 - 2*28 - 20 = -84.
    local NOTES_TOP = -8 - 2 * ROW_PITCH - 20
    -- Lo comparte LayoutBodies para reajustar el alto tras el clamp de pantalla.
    editor.notesTop = NOTES_TOP

    local function MakeLabel(text, y)
        local lbl = infoBody:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        lbl:SetText(text)
        lbl:SetJustifyH("LEFT")
        lbl:SetPoint("TOPLEFT", infoBody, "TOPLEFT", LABEL_X, y)
        -- fieldLabel de UI_STYLE (15px): jerarquía por debajo del título de ventana.
        if RD.UIUtils and RD.UIUtils.ApplyFontStyle then
            RD.UIUtils.ApplyFontStyle(lbl, "fieldLabel")
        else
            RD.UIUtils.ScaleFont(lbl, 1.25)
        end
        return lbl
    end

    -- Nombre (fila 1)
    MakeLabel("Nombre:", -8 - 4)
    local nameBox = CreateFrame("EditBox", UniqueName("Nm"), infoBody, "InputBoxTemplate")
    nameBox:SetSize(160, 24)
    nameBox:SetPoint("TOPLEFT", infoBody, "TOPLEFT", INPUT_X, -8)
    nameBox:SetAutoFocus(false)
    RD.UIUtils.StyleInput(nameBox)
    -- Enter/Escape liberan el foco (estilo KRT) para poder usar atajos del teclado.
    nameBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    nameBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    editor.nameBox = nameBox

    -- Clase (fila 2; dropdown; requiere nombre único para la API de dropdowns)
    MakeLabel("Clase:", -36 - 4)
    local classDD = CreateFrame("Frame", UniqueName("Cl"), infoBody, "UIDropDownMenuTemplate")
    classDD:SetPoint("TOPLEFT", infoBody, "TOPLEFT", INPUT_X, -36)
    -- Mismo alto explícito que el input de nombre (24px) para el ritmo vertical.
    classDD:SetHeight(24)
    UIDropDownMenu_SetWidth(classDD, CLASS_DD_W)
    UIDropDownMenu_SetAnchor(classDD, 0, 0)
    -- Escala el texto del dropdown a fieldLabel (15px) para respetar la jerarquía
    -- (igual que las etiquetas y los valores/inputs del modal).
    local classDDText = getglobal(classDD:GetName() .. "Button")
    if classDDText and classDDText.GetFontString then
        local fs = classDDText:GetFontString()
        if fs then
            if RD.UIUtils and RD.UIUtils.ApplyFontStyle then
                RD.UIUtils.ApplyFontStyle(fs, "fieldLabel")
            else
                RD.UIUtils.ScaleFont(fs, 1.25)
            end
        end
    end
    UIDropDownMenu_Initialize(classDD, function()
        local info = UIDropDownMenu_CreateInfo()
        for _, cf in ipairs(CLASS_LIST) do
            info.text = ClassLabel(cf)
            info.value = cf
            info.checked = (cf == editor.class)
            info.func = function()
                editor.class = cf
                UIDropDownMenu_SetSelectedValue(classDD, cf)
                UIDropDownMenu_SetText(classDD, ClassLabel(cf))
            end
            UIDropDownMenu_AddButton(info)
        end
    end)
    editor.classDD = classDD

    -- Notas (fila 3): etiqueta propia y campo bajo ella
    MakeLabel("Notas:", -64)

    -- El EditBox multilínea de 3.3.5a no recorta su texto: crece con el contenido
    -- dentro de un ScrollFrame que lo recorta y scrollea (rueda del ratón/barra).
    local createScroll = RD.ui and RD.ui.widgets and RD.ui.widgets.CreateScrollFrame
    -- El ancho descuenta SCROLL_GUTTER: ese margen aloja la barra de scroll, que
    -- cuelga 4 px a la derecha del ScrollFrame, de modo que ni la barra ni la tira
    -- de pestañas (que sobresale del borde derecho) pisan el texto de las notas.
    local notesW = innerW - SCROLL_GUTTER
    -- Alto del campo: desde NOTES_TOP hasta el borde inferior del cuerpo con 8px
    -- de aire (el cuerpo ya termina justo sobre el separador de Guardar/Cancelar).
    local notesH = math.max(40, bodyH - math.abs(NOTES_TOP) - 8)
    -- Un solo ancla (TOPLEFT) + tamaño explícito: anclar también por la derecha
    -- dejaría la posición ambigua y el cálculo de la barra dependent de cuál
    -- prevalenciera.
    local notesScroll = createScroll(infoBody, notesW, notesH, PAD, NOTES_TOP)
    notesScroll:SetHeight(notesH)

    local notesBox = CreateFrame("EditBox", nil, notesScroll)
    notesBox:SetWidth(notesW)
    notesBox:SetHeight(60)
    notesBox:SetPoint("TOPLEFT", notesScroll, "TOPLEFT", 0, 0)
    notesBox:SetMultiLine(true)
    notesBox:SetAutoFocus(false)
    notesBox:EnableMouse(true)
    notesBox:SetFontObject(GameFontNormalSmall)
    RD.UIUtils.ScaleFont(notesBox, 1.5)
    notesBox:SetTextInsets(4, 4, 4, 4)
    notesBox:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    notesBox:SetBackdropColor(0, 0, 0, 0.7)
    notesBox:SetBackdropBorderColor(0.5, 0.5, 0.5, 0.7)
    notesScroll:SetScrollChild(notesBox)

    -- Convención de EditBox multilínea dentro de ScrollFrame (helper central
    -- UIUtils.MakeAutoResizeMultiline): mide con un FontString oculto y crece la
    -- caja al contenido; el ScrollFrame lo recorta y scrollea (3.3.5a no recorta).
    local ResizeNotesBox = RD.UIUtils.MakeAutoResizeMultiline(notesBox, notesScroll, notesW - 8)
    notesBox:SetScript("OnTextChanged", ResizeNotesBox)
    notesBox:SetScript("OnTextSet", ResizeNotesBox)
    -- Escape libera el foco del campo de notas (Enter inserta salto de línea y
    -- mantiene el foco, como es habitual en un área de texto multilínea).
    notesBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    editor:SetScript("OnShow", function()
        ResizeNotesBox()
        -- Fuerza el re-render interno del EditBox multilínea (el texto se seteó
        -- con el modal oculto).
        notesBox:SetText(notesBox:GetText() or "")
    end)
    editor.notesBox = notesBox
    editor.notesScroll = notesScroll

    -- Navegación con Tab entre los campos de texto del modal: Nombre → Notas
    if RD.UIUtils and RD.UIUtils.EnableTabNavigation then
        RD.UIUtils.EnableTabNavigation({ nameBox, notesBox })
    end

    -- Separador: línea sutil entre el cuerpo de la sección y la fila global de
    -- Guardar/Cancelar (que se ve en los 5 tabs). Evita que las dos filas de
    -- acciones (la del panel de datos y la de la ventana) parezcan una sola.
    local divider = editor:CreateTexture(nil, "BACKGROUND")
    divider:SetHeight(1)
    divider:SetTexture(1, 1, 1, 0.15)
    divider:SetPoint("BOTTOMLEFT", editor, "BOTTOMLEFT", 12, DIVIDER_Y)
    divider:SetPoint("BOTTOMRIGHT", editor, "BOTTOMRIGHT", -12, DIVIDER_Y)

    -- ========================================================================
    -- Guardar / Cancelar
    -- ========================================================================
    local saveBtn = RD.UIUtils.MakeChipButton(editor, UniqueName("Sv"), 90, 24)
    saveBtn:SetText("Guardar")
    saveBtn:SetPoint("BOTTOMRIGHT", editor, "BOTTOMRIGHT", -16, 12)
    saveBtn:SetScript("OnClick", function()
        local name = strtrim(editor.nameBox:GetText() or "")
        if name == "" then return end
        local bands = RD.utils and RD.utils.bands
        if not bands then return end
        -- Sin banda (jugador no registrado aún): la sección "Bandas" es la vía
        -- para añadirlo; Guardar solo edita dentro de una banda existente.
        if not editor.bandIndex then
            if RD.messageManager and RD.messageManager.SendSystemMessage then
                RD.messageManager:SendSystemMessage("|cffff8000[RaidDominion]|r El jugador no está en ninguna banda. Añádelo desde la sección 'Bandas'.")
            end
            return
        end
        local data = {
            name = name,
            class = editor.class or "",
            notes = editor.notesBox:GetText() or "",
        }
        if editor.isNew then
            -- Comprobar el duplicado ANTES de AddPlayer (que en otros flujos
            -- fusiona el jugador existente y devuelve true): así no se pisan
            -- en silencio los datos del jugador ya registrado.
            local existing = bands.GetPlayer and bands:GetPlayer(editor.bandIndex, data.name or "")
            if existing then
                if RD.messageManager and RD.messageManager.SendSystemMessage then
                    RD.messageManager:SendSystemMessage("|cffff0000[RaidDominion]|r No se pudo añadir: ya existe un jugador con ese nombre.")
                end
                return
            end
            if not bands:AddPlayer(editor.bandIndex, data) then
                if RD.messageManager and RD.messageManager.SendSystemMessage then
                    RD.messageManager:SendSystemMessage("|cffff0000[RaidDominion]|r No se pudo añadir: nombre inválido.")
                end
                return
            end
        else
            if not bands:UpdatePlayer(editor.bandIndex, editor.player.name, data) then
                if RD.messageManager and RD.messageManager.SendSystemMessage then
                    RD.messageManager:SendSystemMessage("|cffff0000[RaidDominion]|r No se pudo guardar: ya existe un jugador con ese nombre.")
                end
                return
            end
            -- Propagar el renombrado al resto de bandas donde el jugador figura
            -- (UpdatePlayer solo renombra dentro de la banda editada).
            local oldClean = CleanName(editor.player.name)
            local newClean = CleanName(data.name)
            if oldClean ~= "" and oldClean ~= newClean then
                local res = bands.RenamePlayerEverywhere and bands:RenamePlayerEverywhere(editor.player.name, data.name)
                if res and res.conflicts and #res.conflicts > 0 then
                    local names = {}
                    for _, c in ipairs(res.conflicts) do
                        names[#names + 1] = tostring(c.name or ("Banda " .. c.index))
                    end
                    if RD.messageManager and RD.messageManager.SendSystemMessage then
                        RD.messageManager:SendSystemMessage("|cffff8000[RaidDominion]|r El nombre se conservó en: " .. table.concat(names, ", ") .. " (ya había un jugador con ese nombre).")
                    end
                end
            end
        end
        local onSaved = editor.onSaved
        editor:Hide()
        if onSaved then onSaved() end
    end)
    editor.saveBtn = saveBtn

    local cancelBtn = RD.UIUtils.MakeChipButton(editor, UniqueName("Cx"), 90, 24)
    cancelBtn:SetText("Cancelar")
    cancelBtn:SetPoint("RIGHT", saveBtn, "LEFT", -8, 0)
    cancelBtn:SetScript("OnClick", function()
        editor:Hide()
    end)

    return editor
end

-- ============================================================================
-- Cambio de sección (una sola abierta a la vez)
-- ============================================================================

-- Reajusta el alto de TODOS los cuerpos (y del scroll de notas) al alto REAL de
-- la ventana: UIUtils.ClampModalToScreen la encoge de forma irreversible cuando
-- la pantalla es baja, y sin esto los cuerpos —sin clip— se derramarían sobre la
-- fila de Guardar/Cancelar. Se llama en cada apertura, tras el clamp.
local function LayoutBodies()
    if not editor then return end
    local bodyH = math.max(60, ((editor:GetHeight() or 500) - BOTTOM_H) - math.abs(BODY_TOP))
    for _, sec in ipairs(SECTIONS) do
        local body = editor.bodies[sec.key]
        if body then body:SetHeight(bodyH) end
    end
    if editor.notesScroll and editor.notesScroll.SetHeight then
        local nt = math.abs(editor.notesTop or 84)
        editor.notesScroll:SetHeight(math.max(40, bodyH - nt - 8))
    end
end

-- Muestra la sección `key`: repinta la tira de iconos (la activa en dorado) y
-- muestra SOLO el cuerpo de esa sección (los selfOnly se ocultan en la tira vía
-- isVisible). Información se rellena al abrir el editor; las demás se construyen
-- bajo demanda con RD.ui.playerEditorSections.
function PlayerEditor:SwitchTo(key)
    if not editor then return end
    -- Una sección oculta (solo-uno-mismo sin isSelf) no puede quedar abierta:
    -- se vuelve a Información para que el título no anuncie un cuerpo vacío.
    local target = sectionByKey[key]
    if not target or ((target.selfOnly) and not editor.isSelf) then
        key = "info"
        target = sectionByKey[key]
    end
    editor.openSection = key

    -- El título compone el nombre de la sección activa (descubribilidad: la
    -- tira es solo iconos y el tooltip no siempre está activo).
    if editor.title and editor.baseTitle then
        editor.title:SetText(target and (editor.baseTitle .. " · " .. target.label) or editor.baseTitle)
    end

    for _, s in ipairs(SECTIONS) do
        local body = editor.bodies[s.key]
        if body then
            local visible = (not s.selfOnly) or editor.isSelf
            if visible and s.key == key then
                body:Show()
            else
                body:Hide()
            end
        end
    end

    if editor.tabStrip and editor.tabStrip.SetActive then
        editor.tabStrip:SetActive(key)
    end

    -- Rellenar el cuerpo (Información se puebla en OpenPlayerEditor)
    if key == "equip" or key == "bands" or key == "instances" or key == "monedas" then
        local secs = RD.ui and RD.ui.playerEditorSections
        if secs and secs.Build then
            local body = editor.bodies[key]
            if body then
                secs:Build(key, body, editor)
            end
        end
    end
end

-- Puente para que las secciones (RD.ui.playerEditorSections) llamen ed:SwitchTo
-- directamente sobre el frame (sin depender del módulo).
function PlayerEditor:BindFrameSwitch()
    if editor and not editor.SwitchTo then
        editor.SwitchTo = function(self, key)
            PlayerEditor:SwitchTo(key)
        end
    end
end

-- ============================================================================
-- Apertura / cierre
-- ============================================================================

-- Crea el editor una sola vez y lo reutiliza. Si la construcción fallara, se
-- descarta el frame parcial para poder reconstruirlo limpio en el próximo uso.
local function EnsureEditor()
    if editor then return editor end
    local ok, err = pcall(BuildEditor)
    if not ok then
        editor = nil
        if RD.messageManager and RD.messageManager.SendSystemMessage then
            RD.messageManager:SendSystemMessage("|cffff0000[RaidDominion]|r Error al construir el editor de jugador: " .. tostring(err))
        end
        return nil
    end
    return editor
end

-- Abre el editor. Modes:
--   - Con bandIndex + player (nil si es nuevo): edición vinculada a esa banda.
--   - Con playerName (sin bandIndex): el editor localiza la banda donde figura
--     el jugador (para editar allí) o, si no está en ninguna, abre en modo
--     "sin banda" (la sección Bandas permite añadirlo a una).
-- Resuelve bandIndex internamente cuando se abre solo por nombre.
function PlayerEditor:OpenPlayerEditor(opts)
    if not opts then return end
    local ed = EnsureEditor()
    if not ed then return end
    self:BindFrameSwitch()

    -- Resolver banda por nombre (modo búsqueda desde la ventana Jugador)
    local targetBand = opts.bandIndex
    local targetPlayer = opts.player
    local resolvedName = opts.playerName
    if not targetBand and resolvedName then
        local bands = (RD.utils and RD.utils.bands and RD.utils.bands.GetBands and RD.utils.bands:GetBands()) or {}
        local clean = CleanName(resolvedName)
        for i, band in ipairs(bands) do
            if type(band.players) == "table" then
                for _, m in ipairs(band.players) do
                    if m and m.name and CleanName(m.name) == clean then
                        targetBand = i
                        targetPlayer = m
                        resolvedName = m.name
                        break
                    end
                end
            end
            if targetBand then break end
        end
    end

    ed.bandIndex = targetBand
    ed.player = targetPlayer
    ed.isNew = not targetPlayer
    ed.onSaved = opts.onSaved
    ed.playerName = resolvedName or (targetPlayer and targetPlayer.name) or (opts.prefill and opts.prefill.name) or ""
    -- En modo nuevo, la clase puede venir precargada del objetivo seleccionado;
    -- solo se acepta si pertenece a CLASS_LIST (evita "UNKNOW" para no-jugadores).
    ed.class = (targetPlayer and targetPlayer.class) or ""
    if ed.class == "" and opts.prefill and opts.prefill.class then
        for _, cf in ipairs(CLASS_LIST) do
            if cf == opts.prefill.class then
                ed.class = cf
                break
            end
        end
    end
    if ed.isNew then
        -- Al abrir por nombre (buscador "Jugador" o "lo mismo" desde el menú
        -- del minimapa) y el jugador no está en ninguna banda, el título muestra
        -- su nombre en vez de "Nuevo jugador"; el flujo "Añadir jugador" con
        -- prefill del objetivo conserva el rótulo "Nuevo jugador".
        local newName = resolvedName or (opts.prefill and opts.prefill.name)
        ed.baseTitle = (newName and newName ~= "") and newName or "Nuevo jugador"
        ed.nameBox:SetText(newName or "")
        ed.notesBox:SetText("")
    else
        ed.baseTitle = "Jugador"
        ed.nameBox:SetText(targetPlayer.name or "")
        ed.notesBox:SetText(targetPlayer.notes or "")
    end

    -- ¿El jugador a editar es uno mismo? (habilita Instancias/Monedas)
    ed.isSelf = IsSelf(ed.nameBox:GetText() or "")

    -- Aplicar visibilidad de la tira (selfOnly) ANTES de SwitchTo para que la
    -- pestaña activa sea visible y la pila reflowee sin huecos.
    if ed.tabStrip and ed.tabStrip.Refresh then
        ed.tabStrip:Refresh()
    end

    -- Clase: si es el jugador propio se garantiza la clase real en vivo
    -- (UnitClass("player")), ignorando la posible copia desactualizada de una
    -- banda; si no se conoce, se resuelve con el lookup de RD.utils.players.
    -- IMPORTANTE (Lua 5.1): llamar directo a UnitClass("player"); `X and X(...)`
    -- en una asignación múltiple colapsa a un solo valor (liveClass = nil).
    if ed.isSelf and UnitClass then
        local _, liveClass = UnitClass("player")
        if liveClass and liveClass ~= "" then ed.class = liveClass end
    end
    if ed.class == "" then
        local playersUtils = RD.utils and RD.utils.players
        if playersUtils and playersUtils.GetClassLookup then
            ed.class = playersUtils:GetClassLookup(ed.nameBox:GetText() or "") or ""
        end
    end

    UIDropDownMenu_SetSelectedValue(ed.classDD, ed.class)
    UIDropDownMenu_SetText(ed.classDD, ClassLabel(ed.class))

    -- Singleton: se resetea el scroll del área de Notas al abrir
    if ed.notesScroll and ed.notesScroll.SetVerticalScroll then
        ed.notesScroll:SetVerticalScroll(0)
    end
    if ed.notesBox.SetScrollOffset then
        ed.notesBox:SetScrollOffset(0)
    end

    -- Sección inicial: Información (los controles clásicos)
    self:SwitchTo("info")

    ed:ClearAllPoints()
    ed:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    if RD.UIUtils and RD.UIUtils.ClampModalToScreen then
        RD.UIUtils.ClampModalToScreen(ed, ed.notesScroll, 20)
    end
    -- Tras el clamp: los cuerpos y el scroll de notas se ajustan al alto real.
    LayoutBodies()
    if RD.UIUtils and RD.UIUtils.ActivateWindow then
        RD.UIUtils.ActivateWindow(ed)
    else
        ed:Show()
        ed:Raise()
    end

    local layout = RD.ui and RD.ui.layout
    if layout and layout.EnsureVisible then
        -- Margen ampliado (overhang de la tira + 8, grid 4px): una ventana
        -- arrastrada al borde derecho no debe recortar las pestañas que sobresalen.
        layout:EnsureVisible(ed, TAB_OVERHANG + 8)
    end
end

-- Frame del editor (nil si aún no se construyó). Lo usan las secciones para
-- saber si el modal está abierto y en qué sección (p.ej. refrescar la sección
-- de monedas al llegar datos). NOTA: RD.ui.playerEditor es la tabla módulo; el
-- frame real se registra aquí para no confundirlo (bug previo de la sección).
function PlayerEditor:GetFrame()
    return editor
end

RD.ui = RD.ui or {}
RD.ui.playerEditor = PlayerEditor
return PlayerEditor