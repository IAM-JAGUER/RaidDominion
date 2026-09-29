--[[
    RD_UI_Widgets_IconPicker.lua
    PROPÓSITO: Scroll frame con barra personalizada (CreateScrollFrame) y
              selector de iconos en cuadrícula estilo WoW con recogida de
              iconos del juego (OpenIconPicker / CollectIcons). Extraído de
              RD_UI_Widgets_List.lua para mantenerlo dentro del límite de
              ~700 líneas; CreateScrollFrame lo comparten además ContentList,
              Bands, Loot, Spammer, RulesSpammer, ConfigWindow y BandsWindow.
    API PÚBLICA:
        - RD.ui.widgets.CreateScrollFrame(parent, width, height, x, y)
            -> scroll, child (barra anclada a la derecha del contenido)
        - RD.ui.widgets.OpenIconPicker(anchor, callback, current)
            -> abre el selector; callback(iconPath) recibe la textura elegida
        - RD.ui.widgets.CollectIcons() -> lista completa de iconos (caché)
    EVENTOS: Ninguno. La recolección se precarga en PLAYER_LOGIN vía
             RD.ui.widgets.CollectIcons (RD_Init.lua).
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

-- Nombre único para frames con templates: se delega en el contador ÚNICO de
-- RD.UIUtils (o en el exportado por RD_UI_Widgets.lua si ya cargó antes).
local UniqueName = (Widgets.UniqueName) or (RD.UIUtils and RD.UIUtils.UniqueName)

local DEFAULT_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

-- =============================================
-- SCROLL FRAME CON BARRA PERSONALIZADA
-- La barra se ancla a la DERECHA del scroll, junto al contenido (no en el
-- borde de un área vacía), con margen controlado y rueda del ratón.
-- =============================================

-- Scroll frame con barra personalizada. `inset` es el margen vertical de la
-- barra respecto del scroll (por defecto 8): las secciones con un panel fijo
-- debajo pasan 0 para que la barra no se meta por debajo del recuadro (que se
-- dibuja encima y la recortaría de forma asimétrica).
local function CreateScrollFrame(parent, width, height, x, y, inset)
    local scroll = CreateFrame("ScrollFrame", UniqueName("Scr"), parent)
    scroll:SetSize(width, height)
    scroll:SetPoint("TOPLEFT", parent, "TOPLEFT", x or 0, y or 0)
    scroll:EnableMouseWheel(true)

    local child = CreateFrame("Frame", nil, scroll)
    child:SetWidth(width)
    scroll:SetScrollChild(child)

    local ins = inset or 8
    local bar = CreateFrame("Slider", UniqueName("Bar"), parent, "UIPanelScrollBarTemplate")
    bar:SetPoint("TOPLEFT", scroll, "TOPRIGHT", 4, -ins)
    bar:SetPoint("BOTTOMLEFT", scroll, "BOTTOMRIGHT", 4, ins)

    -- `syncing` evita retroalimentación y errores durante la inicialización:
    -- Slider:SetValue dispara OnValueChanged aunque se llame al crear la barra.
    local syncing = true
    bar:SetScript("OnValueChanged", function(self, value)
        if not syncing and scroll and scroll.SetVerticalScroll then
            scroll:SetVerticalScroll(value)
        end
    end)
    scroll:SetScript("OnVerticalScroll", function(self, offset)
        syncing = true
        self.scrollBar:SetValue(offset)
        syncing = false
        -- Inactiva el ratón de las filas que el nuevo desplazamiento saca del
        -- viewport (el clip del ScrollFrame no recorta los clics; ver
        -- Widgets:ApplyScrollVisibility). Las filas no se ocultan: en 3.3.5a
        -- Hide congelaría su layout y no reaparecerían al volver a scrollear.
        -- La geometría resuelve con un frame de retraso, así que se re-evalúa
        -- también en el siguiente OnUpdate (one-shot) para reactivar la fila
        -- que queda totalmente dentro al llegar al fondo del scroll.
        if self.RDRefreshVisibility then self:RDRefreshVisibility() end
        if Widgets.ScheduleVisibilityRefresh then Widgets:ScheduleVisibilityRefresh(self) end
    end)
    scroll:SetScript("OnScrollRangeChanged", function(self, xrange, yrange)
        local b = self.scrollBar
        if yrange <= 0 then
            b:Hide()
        else
            b:Show()
            b:SetMinMaxValues(0, yrange)
            b:SetValueStep(math.max(1, yrange / 16))
        end
        if self.RDRefreshVisibility then self:RDRefreshVisibility() end
        if Widgets.ScheduleVisibilityRefresh then Widgets:ScheduleVisibilityRefresh(self) end
    end)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local b = self.scrollBar
        local _, max = b:GetMinMaxValues()
        local val = self:GetVerticalScroll() - delta * 16
        if val < 0 then val = 0 end
        if val > max then val = max end
        if self.SetVerticalScroll then
            self:SetVerticalScroll(val)
        end
    end)

    scroll.scrollBar = bar
    bar:SetMinMaxValues(0, 0)
    bar:SetValueStep(1)
    bar:SetValue(0)
    bar:Hide()
    syncing = false

    return scroll, child
end

-- =============================================
-- SELECTOR DE ICONOS (cuadrícula estilo WoW)
-- Recoge los iconos del juego (GetSpellInfo sobre los IDs de hechizo) y los
-- muestra junto a la lista curada, sin que el usuario necesite conocer nombres
-- de texturas.
-- =============================================

local pickerFrame = nil

local ICON_LIST = nil          -- lista completa una vez recogida
local ICON_SEEN = {}           -- dedupe de texturas

-- Paginación del selector: solo se construyen los botones de la página pedida
-- (lazy load a petición). Con ~2000 iconos, crear todos en cada apertura era un
-- golpe de rendimiento; por página se crean ~PAGE_SIZE botones.
local PAGE_SIZE = 100          -- iconos por página
local pickerPage = 1           -- página activa
local totalPages = 1           -- total de páginas

local function CuratedIcons()
    local list = {}
    local curated = (RD.constants and RD.constants.ICON_PICKER_LIST) or {}
    for _, icon in ipairs(curated) do
        if not ICON_SEEN[icon] then
            ICON_SEEN[icon] = true
            list[#list + 1] = icon
        end
    end
    return list
end

-- Recoge los iconos de los hechizos del juego en una sola pasada (sin C_Timer).
-- Se ejecuta una única vez en PLAYER_LOGIN (vía Widgets.CollectIcons) para no
-- congelar la apertura del selector. Usa GetSpellInfo (API 3.3.5a) cuyo tercer
-- valor de retorno es la textura del icono. Se acota el número de iconos únicos
-- para mantener la carga razonable. El icono por defecto (elementos sin imagen)
-- SIEMPRE está primero, para poder re-seleccionar el estado "sin icono".
local function BuildFullIconList()
    if ICON_LIST then return ICON_LIST end
    local list = {}
    if not ICON_SEEN[DEFAULT_ICON] then
        ICON_SEEN[DEFAULT_ICON] = true
        list[#list + 1] = DEFAULT_ICON
    end
    for _, icon in ipairs(CuratedIcons()) do
        list[#list + 1] = icon
    end
    local MAX_ID = 70000
    local MAX_UNIQUE = 2000
    -- Heurística anti-hitche: si ya hay suficientes iconos y se barren muchos IDs
    -- consecutivos sin encontrar uno nuevo (rangos dispersos hacia 70k), se corta.
    local MAX_GAP = 20000
    local MIN_ICONS = 200
    local sinceNew = 0
    for i = 1, MAX_ID do
        local icon = select(3, GetSpellInfo(i))
        if icon and icon ~= "" and not ICON_SEEN[icon] then
            ICON_SEEN[icon] = true
            list[#list + 1] = icon
            sinceNew = 0
            if #list >= MAX_UNIQUE then break end
        else
            sinceNew = sinceNew + 1
            if sinceNew >= MAX_GAP and #list >= MIN_ICONS then break end
        end
    end
    ICON_LIST = list
    return list
end

-- Construye la cuadrícula de botones de la PÁGINA ACTIVA (lazy load por página).
-- Solo se crean los botones de la página actual; al cambiar de página se
-- reconstruye esa página. La lista completa ya está en caché.
local function BuildPickerGrid()
    for _, btn in ipairs(pickerFrame.buttons) do
        btn:Hide()
        btn:SetParent(nil)
    end
    pickerFrame.buttons = {}

    local list = BuildFullIconList()
    totalPages = math.max(1, math.ceil(#list / PAGE_SIZE))
    if pickerPage < 1 then pickerPage = 1 end
    if pickerPage > totalPages then pickerPage = totalPages end

    local cell = 36
    local cols = math.max(4, math.floor((pickerFrame.child:GetWidth() or 412) / cell))
    local currentIcon = pickerFrame.current

    local first = (pickerPage - 1) * PAGE_SIZE + 1
    local last = math.min(#list, first + PAGE_SIZE - 1)
    local n = 0
    for i = first, last do
        local icon = list[i]
        n = n + 1
        local col = (n - 1) % cols
        local row = math.floor((n - 1) / cols)
        local btn = CreateFrame("Button", nil, pickerFrame.child)
        btn:SetSize(32, 32)
        btn:SetPoint("TOPLEFT", pickerFrame.child, "TOPLEFT", col * cell, -row * cell)

        local tex = btn:CreateTexture(nil, "ARTWORK")
        tex:SetAllPoints()
        tex:SetTexture(icon)

        local hl = btn:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
        hl:SetBlendMode("ADD")

        if icon == currentIcon then
            local ring = btn:CreateTexture(nil, "OVERLAY")
            ring:SetAllPoints()
            ring:SetTexture("Interface\\Buttons\\UI-EmptySlot")
            ring:SetVertexColor(1, 0.82, 0, 1)
        end

        btn:SetScript("OnClick", function()
            local cb = pickerFrame and pickerFrame.callback
            pickerFrame:Hide()
            if cb then cb(icon) end
        end)

        pickerFrame.buttons[#pickerFrame.buttons + 1] = btn
    end
    pickerFrame.child:SetHeight(math.ceil(n / cols) * cell)

    -- Navegación de páginas (SetEnabled no existe en 3.3.5a: se usa
    -- SetButtonState, visual; los OnClick ya guardan los límites de página)
    if pickerFrame.pageLabel then
        pickerFrame.pageLabel:SetText(string.format("Página %d / %d", pickerPage, totalPages))
        if pickerFrame.prevBtn.SetButtonState then
            pickerFrame.prevBtn:SetButtonState(pickerPage > 1 and "NORMAL" or "DISABLED")
        end
        if pickerFrame.nextBtn.SetButtonState then
            pickerFrame.nextBtn:SetButtonState(pickerPage < totalPages and "NORMAL" or "DISABLED")
        end
    end
end

-- Abre el selector de iconos junto al frame ancla. callback(iconPath) recibe
-- el path de textura elegido.
local function OpenIconPicker(anchor, callback, current)
    if not anchor or type(callback) ~= "function" then return end

    if not pickerFrame then
        pickerFrame = CreateFrame("Frame", "RDIconPicker", UIParent)
        -- Strata MEDIUM (paridad con los paneles de personaje de WoW): el picker
        -- se cubre/descubre con la UI del juego y pasa al frente al activarlo.
        if RD.UIUtils and RD.UIUtils.SetupWindow then
            RD.UIUtils.SetupWindow(pickerFrame)
        else
            pickerFrame:SetFrameStrata("MEDIUM")
            pickerFrame:SetToplevel(true)
            pickerFrame:SetClampedToScreen(true)
        end
        pickerFrame:SetSize(460, 420)
        pickerFrame:EnableMouse(true)

        -- Arrastrable desde cualquier zona no interactiva (título/fondo/espacio
        -- vacío); los botones de la cuadrícula capturan su propio clic.
        pickerFrame:SetMovable(true)
        pickerFrame:RegisterForDrag("LeftButton")
        pickerFrame:SetScript("OnDragStart", function()
            pickerFrame:StartMoving()
        end)
        pickerFrame:SetScript("OnDragStop", function()
            pickerFrame:StopMovingOrSizing()
        end)

        pickerFrame:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 12,
            insets = { left = 4, right = 4, top = 4, bottom = 4 },
        })
        pickerFrame:SetBackdropColor(0, 0, 0, 0.95)
        pickerFrame:SetBackdropBorderColor(1, 1, 1, 0.5)
        pickerFrame.buttons = {}
        if RD.UIUtils and RD.UIUtils.TrackScale then RD.UIUtils.TrackScale(pickerFrame) end

        -- Fondo modal: clic fuera cierra el selector
        local catcher = CreateFrame("Frame", nil, UIParent)
        if RD.UIUtils and RD.UIUtils.SetupWindow then
            RD.UIUtils.SetupWindow(catcher)
        else
            catcher:SetFrameStrata("MEDIUM")
            catcher:SetToplevel(true)
        end
        catcher:SetAllPoints(UIParent)
        catcher:EnableMouse(true)
        catcher:SetScript("OnMouseUp", function()
            if pickerFrame then pickerFrame:Hide() end
        end)
        pickerFrame.catcher = catcher
        pickerFrame:SetScript("OnHide", function()
            if pickerFrame and pickerFrame.catcher then pickerFrame.catcher:Hide() end
            if pickerFrame then pickerFrame.callback = nil end
        end)

        local title = pickerFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        title:SetPoint("TOP", pickerFrame, "TOP", 0, -8)
        title:SetText("Selecciona un icono")

        local closeBtn = CreateFrame("Button", UniqueName("Cl"), pickerFrame, "UIPanelCloseButton")
        closeBtn:SetPoint("TOPRIGHT", pickerFrame, "TOPRIGHT", -4, -4)
        closeBtn:SetScript("OnClick", function()
            pickerFrame:Hide()
        end)

        -- Scroll con barra personalizada a la derecha del contenido (más espacio);
        -- se deja sitio abajo para la navegación de páginas.
        local scroll, child = CreateScrollFrame(pickerFrame, 412, 320, 8, -30)
        pickerFrame.scroll = scroll
        pickerFrame.child = child

        -- Navegación de páginas (lazy load por página). Etiquetas de texto:
        -- los glifos ◀/▶ no existen en la fuente de 3.3.5a (renderizan "?").
        local prevBtn = RD.UIUtils.MakeChipButton(pickerFrame, UniqueName("Np"), 84, 24)
        prevBtn:SetText("Anterior")
        prevBtn:SetPoint("BOTTOMLEFT", pickerFrame, "BOTTOMLEFT", 12, 12)
        prevBtn:SetScript("OnClick", function()
            if pickerPage > 1 then
                pickerPage = pickerPage - 1
                BuildPickerGrid()
            end
        end)
        pickerFrame.prevBtn = prevBtn

        local pageLabel = pickerFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        pageLabel:SetText("Página 1 / 1")
        pageLabel:SetPoint("BOTTOM", pickerFrame, "BOTTOM", 0, 16)
        RD.UIUtils.ScaleFont(pageLabel, 1.25)
        pickerFrame.pageLabel = pageLabel

        local nextBtn = RD.UIUtils.MakeChipButton(pickerFrame, UniqueName("Nx"), 84, 24)
        nextBtn:SetText("Siguiente")
        nextBtn:SetPoint("BOTTOMRIGHT", pickerFrame, "BOTTOMRIGHT", -12, 12)
        nextBtn:SetScript("OnClick", function()
            if pickerPage < totalPages then
                pickerPage = pickerPage + 1
                BuildPickerGrid()
            end
        end)
        pickerFrame.nextBtn = nextBtn
    end

    pickerFrame.callback = callback
    pickerFrame.current = current

    -- Un elemento sin imagen (icono vacío) se muestra con el icono por defecto;
    -- así el estado "sin icono" queda representado y re-seleccionable.
    if pickerFrame.current == "" or pickerFrame.current == nil then
        pickerFrame.current = DEFAULT_ICON
    end

    -- Salta a la página donde está el icono actual (si existe); si no, página 1
    local list = BuildFullIconList()
    local idx = nil
    for i, icon in ipairs(list) do
        if icon == pickerFrame.current then idx = i break end
    end
    if idx then
        pickerPage = math.max(1, math.ceil(idx / PAGE_SIZE))
    else
        pickerPage = 1
    end

    -- La lista ya está precargada en PLAYER_LOGIN (Widgets.CollectIcons);
    -- BuildPickerGrid usa BuildFullIconList (caché) directamente.
    BuildPickerGrid()

    pickerFrame:ClearAllPoints()
    pickerFrame:SetPoint("BOTTOMLEFT", anchor, "TOPLEFT", 0, 8)
    if RD.UIUtils and RD.UIUtils.ClampModalToScreen then
        RD.UIUtils.ClampModalToScreen(pickerFrame, pickerFrame.scroll, 20)
    end
    pickerFrame.catcher:Show()
    if RD.UIUtils and RD.UIUtils.ActivateWindow then
        RD.UIUtils.ActivateWindow(pickerFrame)
    else
        pickerFrame:Show()
        pickerFrame:Raise()
    end

    local layout = RD.ui and RD.ui.layout
    if layout and layout.EnsureVisible then
        layout:EnsureVisible(pickerFrame, 8)
    end
end

-- Helpers compartidos con otros archivos de listas (CreateList, ContentList,
-- Bands, Loot, Spammer, RulesSpammer, ConfigWindow, BandsWindow)
Widgets.CreateScrollFrame = CreateScrollFrame
Widgets.OpenIconPicker = OpenIconPicker

-- Hook público para precargar la lista de iconos en PLAYER_LOGIN (sin C_Timer)
Widgets.CollectIcons = function()
    return BuildFullIconList()
end

return Widgets