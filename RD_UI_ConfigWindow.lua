--[[
    RD_UI_ConfigWindow.lua
    PROPÓSITO: Ventana de configuración vinculada al menú flotante. Se renderiza
              dinámicamente a partir de RD.constants.CONFIG_SCHEMA y del valor
              seteado actual en RD.config. No hay UI hardcodeada por pestaña.
              Layout (v3, reubicado a petición del usuario):
                  título / cerrar
                  TABS SUPERIORES  (chips dorados, diseño previo a la tira de
                                    iconos; ancho proporcional al texto)
                  ZONA DE CONTENIDO DINÁMICO  (pestaña activa O panel del icono)
                  BARRA INFERIOR   (11 iconos de ACTION_BAR en folder acoplado,
                                    centrados, con grip de reorden en cada uno)
              Las 7 pestañas con contraparte en el menú flotante llevan un grip
              lateral que REORDENA la propia fila superior y su ítem del menú
              (ui.menu.itemOrder: el menú flotante refleja ese orden). Los
              iconos de la barra reordenan ui.actionBar.order (compartido con la
              barra del menú flotante).
    API PÚBLICA:
        - RD.ui.configWindow:Create()
        - RD.ui.configWindow:Show() / Hide() / Toggle()
        - RD.ui.configWindow:Render()
        - RD.ui.configWindow:SelectTab(index) / SelectTabById(id)
        - RD.ui.configWindow:SyncTitle()          -- título dinámico (vista activa)
        - RD.ui.configWindow:FrameHeight(viewH)   -- alto del frame (puro)
        - RD.ui.configWindow:SortByOrder(list)    -- orden estable por `order`
    EVENTOS: Publica CONFIG_WINDOW_SHOWN, CONFIG_WINDOW_HIDDEN;
             reacciona a CONFIG_RESET (re-render) y a CONFIG_CHANGED de las
             listas (re-aplica alto), del orden de la barra (RefreshBar) y del
             orden de las pestañas (ReorderTopBar).
]]

local addonName, private = ...
local RD = _G.RaidDominion or {}
_G.RaidDominion = RD

local ConfigWindow = {
    frame = nil,
    content = nil,
    tabs = {},
    currentTab = 1,
    viewBar = nil,
    isShown = false,
    positioned = false,
}

-- Constantes de geometría (enteros, múltiplos del grid 4px)
-- CONTENT_WIDTH: ancho del panel de contenido (la ventana ≈ 808 px).
local CONTENT_WIDTH = 776        -- ancho del panel de contenido (ventana ≈ 808)
local PANEL_PAD = 12           -- padding interior del panel de contenido
local SIDE_PADDING = 8           -- padding lateral del frame (8 + 8)
local BOTTOM_PADDING = 12        -- padding inferior del frame
-- CONTENT_TOP: offset Y del contenedor de contenido. La fila de chips (32px)
-- vive bajo la barra de título (28px), así que el contenido arranca en -72.
local CONTENT_TOP = -72
local MAX_BODY_HEIGHT = 520      -- alto máximo del cuerpo de la config (si lo supera, scrollea)
local MIN_BODY_HEIGHT = 200      -- alto mínimo del cuerpo (sin la tira de iconos)
-- Bloque de la barra inferior: folder (icono 27 + padding-top 6 + bottom 4) + hueco.
local BAR_GAP = 8                -- espacio entre el contenido y la barra
local BAR_FOLDER_HEIGHT = 37     -- 27 + 6 + 4, espejo de RD_UI_ConfigWindow_Bar.lua
local GOLD_R, GOLD_G, GOLD_B = unpack((RD.constants and RD.constants.COLORS and RD.constants.COLORS.GOLD) or { 1, 0.82, 0 })

-- Alto total del frame para un viewport dado (puro, lo usan Render,
-- ReapplyHeight y el tamaño inicial de Create). La ventana abraza el contenido:
-- título+chips (CONTENT_TOP) + viewport + hueco + folder de la barra + el
-- padding inferior estándar (BOTTOM_PADDING). Así la barra queda DENTRO del
-- cuerpo (ancla BOTTOM positiva) sin dejar banda vacía bajo ella.
local function FrameHeight(viewH)
    return -CONTENT_TOP + (viewH or 0) + BAR_GAP + BAR_FOLDER_HEIGHT + BOTTOM_PADDING
end
ConfigWindow.FrameHeight = FrameHeight

-- Nombre único para frames con template (los templates crean hijos con $parent).
-- Se delega en el contador ÚNICO de RD.UIUtils para evitar colisiones entre archivos.
local UniqueName = RD.UIUtils and RD.UIUtils.UniqueName

-- Render/ReapplyHeight viven en RD_UI_ConfigWindow_Render.lua (adjuntos a la
-- tabla RD.ui.configWindow al cargar, antes de PLAYER_LOGIN). Se invocan con
-- guarda defensiva: si ese archivo no llegó a cargarse (p.ej. .toc viejo), el
-- arranque no debe abortar por un método ausente.
local function CallRender(cw)
    if cw and cw.Render then cw:Render() end
end
local function CallReapply(cw)
    if cw and cw.ReapplyHeight then cw:ReapplyHeight() end
end

-- Orden estable por `order` (helper central en RD.UIUtils.SortByOrder)
local SortByOrder = (RD.UIUtils and RD.UIUtils.SortByOrder) or function(list)
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
-- Compartido con RD_UI_ConfigWindow_Render.lua y RD_UI_ConfigWindow_Tabs.lua
ConfigWindow.SortByOrder = SortByOrder

-- Repinta el estado visual de las pestañas chip (activa resaltada en dorado,
-- resto tenue). Mientras se muestra el panel de un icono de la barra (viewBar)
-- ninguna pestaña está activa. Es MÉTODO (lo llama también la barra inferior).
function ConfigWindow:PaintTabs()
    local showTabs = not self.viewBar
    for i, tab in ipairs(self.tabs) do
        local active = showTabs and (i == self.currentTab)
        if tab and tab.button and RD.UIUtils and RD.UIUtils.PaintTabButton then
            RD.UIUtils.PaintTabButton(tab.button, active)
        end
        local text = tab and tab.button and (tab.button.rdText or tab.button.GetFontString and tab.button:GetFontString())
        if text and text.SetTextColor then
            if active then
                text:SetTextColor(GOLD_R, GOLD_G, GOLD_B)
            else
                text:SetTextColor(0.8, 0.8, 0.8)
            end
        end
    end
end

-- Título dinámico de la ventana: compone el nombre de la VISTA activa en la
-- zona de contenido dinámico (la pestaña del esquema o el panel de un icono de
-- la barra inferior), igual que hace el editor del jugador con sus secciones
-- (RD_UI_BandsPlayerEditor). Es el ÚNICO punto que escribe self.title, de modo
-- que cualquier cambio de vista (Render) refresca el texto. Fallback defensivo:
-- si el panel de barra no resuelve ítem (p.ej. tras un reorden), título base.
function ConfigWindow:SyncTitle()
    if not self.title or not self.baseTitle then return end
    local name = nil
    if self.viewBar then
        for _, item in ipairs(self.barItems or {}) do
            if item.action == self.viewBar then name = item.name break end
        end
    else
        local tab = self.tabs and self.tabs[self.currentTab] and self.tabs[self.currentTab].schema
        name = tab and tab.title
    end
    self.title:SetText((name and name ~= "") and (self.baseTitle .. " · " .. name) or self.baseTitle)
end

function ConfigWindow:Create()
    if self.frame then return self.frame end

    if not (RD.ui and RD.ui.layout) then return nil end

    local frame = CreateFrame("Frame", "RaidDominionConfig", UIParent)
    -- Strata MEDIUM (paridad con los paneles de personaje de WoW): la ventana
    -- se cubre/descubre con la UI del juego y pasa al frente al activarla.
    if RD.UIUtils and RD.UIUtils.SetupWindow then
        RD.UIUtils.SetupWindow(frame)
    else
        frame:SetFrameStrata("MEDIUM")
        frame:SetToplevel(true)
        frame:SetClampedToScreen(true)
    end
    frame:EnableMouse(true)
    frame:SetMovable(true)

    -- Arrastre de toda la ventana (como la v2): se arrastra desde cualquier
    -- zona no interactiva (barra de título, fondo, padding). Los widgets hijos
    -- (pestañas, checkboxes, sliders, botones, grips) capturan su propio clic.
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function()
        frame:StartMoving()
    end)
    frame:SetScript("OnDragStop", function()
        frame:StopMovingOrSizing()
        local layout = RD.ui and RD.ui.layout
        if layout and layout.EnsureVisible then
            layout:EnsureVisible(frame, 8)
        end
    end)

    -- Escala de la interfaz (general.scale) aplicada al frame raíz
    if RD.UIUtils and RD.UIUtils.TrackScale then
        RD.UIUtils.TrackScale(frame)
    else
        local scaleValue = RD.config and RD.config.Get and RD.config:Get("general.scale", 1.0) or 1.0
        if type(scaleValue) == "number" and scaleValue > 0 then
            frame:SetScale(scaleValue)
        end
    end

    -- Backdrop estilo dialog coherente con el menú flotante
    frame:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    frame:SetBackdropColor(0, 0, 0, 0.9)
    frame:SetBackdropBorderColor(1, 1, 1, 0.5)

    -- Franja del título: banda oscura casi a todo lo ancho con línea dorada de
    -- acento inferior. Se reduce 2px por lado y 2px desde el borde superior
    -- para que no asomen los "picos" de las esquinas redondeadas del frame.
    local titleBg = CreateFrame("Frame", nil, frame)
    titleBg:SetPoint("TOPLEFT", frame, "TOPLEFT", 2, -2)
    titleBg:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -2, -2)
    titleBg:SetHeight(28)
    titleBg:SetFrameLevel(frame:GetFrameLevel())
    titleBg:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        tile = true, tileSize = 16,
    })
    titleBg:SetBackdropColor(0.06, 0.06, 0.06, 0.9)
    local titleLine = titleBg:CreateTexture(nil, "ARTWORK")
    titleLine:SetPoint("BOTTOMLEFT", titleBg, "BOTTOMLEFT", 0, 0)
    titleLine:SetPoint("BOTTOMRIGHT", titleBg, "BOTTOMRIGHT", 0, 0)
    titleLine:SetHeight(2)
    titleLine:SetTexture(GOLD_R, GOLD_G, GOLD_B, 0.6)

    -- Título (jerarquía: título de ventana, el más prominente). La pestaña
    -- activa se compone a la derecha del título base.
    self.baseTitle = "RaidDominion"
    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetText(self.baseTitle)
    title:SetTextColor(GOLD_R, GOLD_G, GOLD_B)
    title:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -5)
    RD.UIUtils.ScaleFont(title, 1.25)
    self.title = title

    -- Botón de cerrar (ESC también cierra vía UISpecialFrames)
    local closeButton = CreateFrame("Button", UniqueName("Cl"), frame, "UIPanelCloseButton")
    closeButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, 1)
    closeButton:SetFrameLevel(frame:GetFrameLevel() + 10)
    closeButton:SetScript("OnClick", function()
        self:Hide()
    end)
    table.insert(UISpecialFrames, "RaidDominionConfig")

    -- TABS SUPERIORES (chips + grips): vive en RD_UI_ConfigWindow_Tabs.lua.
    -- Construye self.tabs, self.tabRowFrame, self.reorderChips y self.dropZones.
    if self.BuildTabRow then
        self:BuildTabRow(frame)
    end

    -- Zonas de soltado del arrastre cross-list: si Tabs no cargó, se garantiza
    -- una tabla vacía (GetDropZones nunca devuelve nil).
    self.dropZones = self.dropZones or {}

    -- Contenedor del cuerpo: ScrollFrame con panel oscuro y alto máximo.
    -- Si el contenido supera MAX_BODY_HEIGHT, el viewport scrollea (barra + rueda).
    local contentWidth = CONTENT_WIDTH + 2 * PANEL_PAD
    self.contentWidth = contentWidth
    self.minBodyHeight = MIN_BODY_HEIGHT
    local createScroll = RD.ui and RD.ui.widgets and RD.ui.widgets.CreateScrollFrame
    local scroll, content
    if createScroll then
        scroll, content = createScroll(frame, contentWidth, 200, SIDE_PADDING, CONTENT_TOP)
        content:SetWidth(contentWidth)
        -- La barra de scroll queda DENTRO del panel (borde derecho), con un
        -- pequeño inset para que no se salga del marco; se estira al alto del
        -- viewport (el padding simétrico de las filas le deja sitio).
        if scroll and scroll.scrollBar then
            local bar = scroll.scrollBar
            bar:ClearAllPoints()
            bar:SetPoint("TOPRIGHT", scroll, "TOPRIGHT", -4, -12)
            bar:SetPoint("BOTTOMRIGHT", scroll, "BOTTOMRIGHT", -4, 12)
        end
        scroll:SetBackdrop({
            bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 },
        })
        scroll:SetBackdropColor(0.09, 0.09, 0.09, 0.72)
        scroll:SetBackdropBorderColor(0.55, 0.55, 0.55, 0.6)
    else
        content = CreateFrame("Frame", nil, frame)
        content:SetPoint("TOPLEFT", frame, "TOPLEFT", SIDE_PADDING, CONTENT_TOP)
        content:SetSize(contentWidth, 200)
    end
    content.rows = {}
    self.content = content
    self.scroll = scroll
    self.frame = frame

    -- BARRA INFERIOR (folder de iconos + grips de reorden): vive en
    -- RD_UI_ConfigWindow_Bar.lua. Construye self.barRow, self.barCells.
    if self.BuildBar then
        self:BuildBar(frame)
    end

    -- Frame de debounce para re-ajustar la altura cuando cambia el contenido de
    -- un editor de lista/bandas (p.ej. "Añadir banda"): el editor crece tras
    -- BuildRows, así que se re-aplica la altura un instante después (sin recrear
    -- widgets, sin perder el foco).
    local reapplyFrame = CreateFrame("Frame")
    reapplyFrame:Hide()
    reapplyFrame:SetScript("OnUpdate", function(f, elapsed)
        f.rdElapsed = (f.rdElapsed or 0) + elapsed
        if f.rdElapsed >= (f.rdDelay or 0.1) then
            f:Hide()
            f.rdElapsed = 0
            CallReapply(self)
        end
    end)
    self.reapplyFrame = reapplyFrame
    local function QueueReapply()
        if self.isShown and self.reapplyFrame then
            self.reapplyFrame.rdElapsed = 0
            self.reapplyFrame:Show()
        end
    end

    -- Re-render al restablecer la configuración por defecto; re-ajuste de altura
    -- cuando cambia una lista/bandas del tab activo; reorden de la barra (los
    -- iconos de la barra inferior y el menú flotante comparten ui.actionBar.order).
    if RD.events and RD.events.Subscribe then
        RD.events:Subscribe("CONFIG_RESET", function()
            CallRender(self)
        end)
        RD.events:Subscribe("CONFIG_CHANGED", function(key)
            if not key then return end
            if key == "ui.actionBar.order" then
                if self.RefreshBar then self:RefreshBar() end
                return
            end
            if key == "ui.menu.itemOrder" then
                -- El orden de las pestañas superiores con contraparte cambió:
                -- reposicionar la fila (el menú flotante se refresca él solo).
                if self.ReorderTopBar then self:ReorderTopBar() end
                return
            end
            local listKeys = { roles = true, abilities = true, buffs = true,
                auras = true, mechanics = true, rules = true, bands = true }
            if not listKeys[key] then return end
            -- Solo se re-aplica si el TAB ACTIVO contiene un campo con esa clave
            -- (evita encoger p.ej. el tab Ayuda si cambia una lista estando en él).
            local tab = self.tabs and self.tabs[self.currentTab] and self.tabs[self.currentTab].schema
            if tab and tab.sections then
                for _, section in ipairs(tab.sections) do
                    for _, field in ipairs(section.fields or {}) do
                        if field.key == key then
                            QueueReapply()
                            return
                        end
                    end
                end
            end
        end)
    end

    -- Tamaño inicial y primer render del tab activo (nunca por debajo del alto
    -- mínimo del cuerpo; Render lo recalcula después).
    local initialView = math.max(self.minBodyHeight or MIN_BODY_HEIGHT, math.min(MAX_BODY_HEIGHT, 260))
    frame:SetSize(contentWidth + 2 * SIDE_PADDING, FrameHeight(initialView))
    self:PaintTabs()
    CallRender(self)

    return frame
end

function ConfigWindow:Show()
    if not self.frame then
        self:Create()
    end
    if not self.frame then return end

    -- Re-aplica la escala de la interfaz por si cambió mientras estaba cerrada
    if RD.UIUtils and RD.UIUtils.ApplyScale then
        RD.UIUtils.ApplyScale(self.frame)
    end

    -- Posición: se centra la primera vez y luego conserva la posición
    -- (arrastrable) en la que el usuario la deje.
    if not self.positioned then
        self.frame:ClearAllPoints()
        self.frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        self.positioned = true
    end

    local layout = RD.ui and RD.ui.layout
    if layout and layout.EnsureVisible then
        layout:EnsureVisible(self.frame, 8)
    end

    if RD.UIUtils and RD.UIUtils.ActivateWindow then
        RD.UIUtils.ActivateWindow(self.frame)
    else
        self.frame:Raise()
        self.frame:Show()
    end
    self.isShown = true
    if RD.events and RD.events.Publish then
        RD.events:Publish("CONFIG_WINDOW_SHOWN")
    end
end

function ConfigWindow:Hide()
    if not self.frame then return end
    self.frame:Hide()
    self.isShown = false
    if RD.events and RD.events.Publish then
        RD.events:Publish("CONFIG_WINDOW_HIDDEN")
    end
end

function ConfigWindow:Toggle()
    if self.isShown then
        self:Hide()
    else
        self:Show()
    end
end

function ConfigWindow:SelectTab(index)
    if not self.tabs or not self.tabs[index] then return end
    -- Seleccionar una pestaña abandona el panel de un icono de la barra
    self.viewBar = nil
    self.currentTab = index
    -- El título dinámico (vista activa) lo compone Render vía SyncTitle, que
    -- sustituyó al bloque inline que vivía aquí (único punto que escribía
    -- self.title).
    CallRender(self)
    self:PaintTabs()
    -- Volver a una pestaña abandona el panel de un icono: sin panel abierto,
    -- ningún botón de la barra inferior queda enfatizado.
    if self.PaintBar then self:PaintBar() end
end

-- Busca un tab por su id en el esquema (lo usa la acción "ShowHelp" del menú)
function ConfigWindow:SelectTabById(id)
    if not id then return end
    for i, tab in ipairs(self.tabs) do
        if tab.id == id then
            self:SelectTab(i)
            return
        end
    end
end

-- Zonas de soltado para el arrastre inter-list (solo los 4 tabs asignables).
-- CreateList las lee vía el campo field.dropZones para permitir mover un ítem
-- arrastrándolo hasta la pestaña de la lista destino.
function ConfigWindow:GetDropZones()
    return self.dropZones or {}
end

RD.ui = RD.ui or {}
-- Simétrico ante reorden del .toc: si RD_UI_ConfigWindow_Render.lua (o Tabs o
-- Bar) cargó primero (tabla con métodos), se fusionan sus métodos en esta tabla.
if RD.ui.configWindow then
    for k, v in pairs(RD.ui.configWindow) do
        if ConfigWindow[k] == nil then ConfigWindow[k] = v end
    end
end
RD.ui.configWindow = ConfigWindow
return ConfigWindow