--[[
    RD_UI_BandsWindow.lua
    PROPÓSITO: Gestor de jugadores de una banda (arrastrable). La lista (pestañas
              Core/Tanque/Healer/Rango/Melee/Sancionados, tabla ordenable, puntos
              de asistencia) la renderiza RD_UI_BandsList; el editor de jugador,
              RD_UI_BandsPlayerEditor. CRUD de bandas en la config. Ventanas del
              addon en DIALOG con click-to-top (la activa siempre arriba).
    API PÚBLICA:
        - RD.ui.bandsWindow:Show() / Hide() / Toggle()
        - RD.ui.bandsWindow:ShowBand(index) / Refresh() / RefreshBandDropdown()
        - El título de la ventana es un dropdown (CreateOptionsDropdown) que
          lista las bandas y permite cambiar entre ellas.
    EVENTOS: CONFIG_CHANGED("bands"), GUILD_ROSTER_UPDATE.
]]

local addonName, private = ...
local RD = _G.RaidDominion or {}
_G.RaidDominion = RD

local BandsWindow = {
    frame = nil,
    isShown = false,
    positioned = false,
    bandIndex = 1,
    category = "core",         -- filtro de jugadores: "core"|"tank"|"healer"|"rango"|"melee"|"sanctioned"
    sortKey = "name",          -- "name" | "role" | "dual" | "attendance" | "sanction"
    sortDir = 1,               -- 1 asc, -1 desc
    page = 1,                  -- página actual de la lista (máx. 25 por página)
    pageLabel = nil,
    pagePrevBtn = nil,
    pageNextBtn = nil,
    playersScroll = nil,
    playersChild = nil,
    rows = {},
    headerButtons = {},
    tabButtons = {},
    bandLabel = nil,
    bandDropdown = nil,
    _bandDropdownKey = nil,
    bandInfo = nil,
}

-- Nombre único para frames con template (los templates crean hijos con
-- $parent). Se delega en el contador ÚNICO de RD.UIUtils para evitar
-- colisiones entre archivos.
local UniqueName = RD.UIUtils and RD.UIUtils.UniqueName

-- Mensaje de sistema (helper central en RD.UIUtils.Log)
local Log = (RD.UIUtils and RD.UIUtils.Log) or function(msg) print(msg) end

-- Selector de banda (dropdown del título): el label NO debe llevar el envoltorio
-- |H/|K de un enlace (un FontString normal lo mostraría crudo), pero sí conserva
-- el color |c/|r del enlace (que el FontString sí parsea).
local LinkLabel = (RD.UIUtils and RD.UIUtils.LinkLabel)
    or function(t) return tostring(t or "") end

local function Bands()
    return RD.utils and RD.utils.bands
end

-- Solicita el roster de la hermandad si aún no está cargado (al abrir el gestor)
local function EnsureRosterLoaded()
    local bs = RD.ui and RD.ui.bandsStatus
    if bs and bs.EnsureLoaded then
        bs:EnsureLoaded()
    end
end

function BandsWindow:Refresh()
    if not self.frame then return end
    local bands = Bands()
    if not bands then return end

    -- Una sola lectura de la tabla de bandas (GetBands/GetBand recorren config
    -- por separado; antes este refresh la leía dos veces por llamada).
    local all = bands:GetBands()

    -- Clampear el índice si la banda seleccionada ya no existe
    local count = #all
    if count == 0 then
        self.bandIndex = 1
    elseif self.bandIndex > count then
        self.bandIndex = count
    end

    local band = all[self.bandIndex]
    -- Dropdown de selección de banda (título de la ventana): lista todas las
    -- bandas y permite cambiar entre ellas. Se reconstruye solo si cambia la
    -- lista o la selección.
    self:RefreshBandDropdown()
    if self.bandInfo then
        if band then
            self.bandInfo:SetText(string.format("Gearscore mínimo: %d  ·  Horario: %s  ·  Jugadores: %d",
                tonumber(band.minGS) or 0,
                (band.schedule and band.schedule ~= "") and band.schedule or "Sin horario",
                #(band.players or {})))
        else
            self.bandInfo:SetText("No hay bandas registradas. Créalas en Configuración > Bandas.")
        end
    end

    -- Los filtros (Core/Roles/Sancionados) solo aplican a la vista de jugadores
    if self.tabContainer then
        self.tabContainer:Show()
    end

    local list = RD.ui and RD.ui.bandsList
    if list and list.Render then
        list:Render(self)
    end
end

function BandsWindow:Create()
    if self.frame then return self.frame end

    local frame = CreateFrame("Frame", "RaidDominionBands", UIParent)
    -- Strata MEDIUM (paridad con los paneles de personaje de WoW): la ventana
    -- se cubre/descubre con la UI del juego y pasa al frente al activarla.
    if RD.UIUtils and RD.UIUtils.SetupWindow then
        RD.UIUtils.SetupWindow(frame)
    else
        frame:SetFrameStrata("MEDIUM")
        frame:SetToplevel(true)
        frame:SetClampedToScreen(true)
    end
    frame:SetSize(760, 500)
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function() frame:StartMoving() end)
    frame:SetScript("OnDragStop", function() frame:StopMovingOrSizing() end)

    frame:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    frame:SetBackdropColor(0, 0, 0, 0.92)
    frame:SetBackdropBorderColor(1, 1, 1, 0.5)
    table.insert(UISpecialFrames, "RaidDominionBands")
    self.frame = frame
    if RD.UIUtils and RD.UIUtils.TrackScale then RD.UIUtils.TrackScale(frame) end

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    title:SetText("Banda:")
    title:SetTextColor(0.8, 0.8, 0.8)
    title:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -8)
    self.bandLabel = title
    RD.UIUtils.ScaleFont(title, 1.25)

    local closeBtn = CreateFrame("Button", UniqueName("Cl"), frame, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4)
    closeBtn:SetScript("OnClick", function() self:Hide() end)

    local info = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    info:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -36)
    info:SetTextColor(0.8, 0.8, 0.8)
    self.bandInfo = info
    RD.UIUtils.ScaleFont(info, 1.5)

    -- Barra de acciones
    local function MakeButton(label, width, onClik)
        local btn = RD.UIUtils.MakeChipButton(frame, UniqueName("Tb"), width, 22)
        btn:SetText(label)
        btn:SetScript("OnClick", onClik)
        return btn
    end

    local toolbar = {
        { label = "Añadir jugador", w = 110, fn = function()
            local pe = RD.ui and RD.ui.playerEditor
            if pe and pe.OpenPlayerEditor then
                -- Si hay un objetivo seleccionado, se precargan los datos que se
                -- puedan recuperar (nombre y clase) para el nuevo jugador.
                local prefill = nil
                if UnitExists("target") then
                    local name = UnitName("target")
                    local classFile = select(2, UnitClass("target"))
                    if name and name ~= "" then
                        prefill = { name = name, class = classFile }
                    end
                end
                pe:OpenPlayerEditor({
                    bandIndex = self.bandIndex,
                    player = nil,
                    prefill = prefill,
                    onSaved = function()
                        self:Refresh()
                    end,
                })
            end
        end },
        { label = "Escanear grupo", w = 110, fn = function()
            local bands = Bands()
            if bands then
                local added = bands:ScanGroupIntoBand(self.bandIndex)
                self:Refresh()
                Log(string.format("|cff00ff00[RaidDominion]|r %d jugadores añadidos a la banda.", added))
            end
        end },
        { label = "Editar en config", w = 120, fn = function()
            if RD.MenuActions and RD.MenuActions.Execute then
                RD.MenuActions:Execute("OpenConfigBands")
            end
        end },
        { label = "Spamear", w = 80, fn = function()
            local sw = RD.ui and RD.ui.spammerWindow
            if sw and sw.Open then
                sw:Open(self.bandIndex)
            else
                Log("|cffff0000[RaidDominion]|r El spammer no está disponible.")
            end
        end },
    }

    local x = 12
    for _, t in ipairs(toolbar) do
        local btn = MakeButton(t.label, t.w, t.fn)
        btn:SetPoint("TOPLEFT", frame, "TOPLEFT", x, -56)
        x = x + t.w + 6
    end

    local panel = CreateFrame("Frame", nil, frame)
    panel:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, -86)
    -- El panel se estira con el marco: si el alto se recorta (ClampModalToScreen)
    -- el panel y el scroll absorben el recorte sin desbordarse.
    panel:SetPoint("BOTTOM", frame, "BOTTOM", 0, 0)
    panel:SetSize(744, 400)
    panel:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    panel:SetBackdropColor(0.09, 0.09, 0.09, 0.72)
    panel:SetBackdropBorderColor(0.55, 0.55, 0.55, 0.6)

    -- Pestañas de la lista: Core / Tanque / Healer / Rango / Melee / Sancionados.
    -- El ancho y la posición finales los fija BuildTabs (autodimensionado); aquí
    -- se crean con un ancho mínimo inicial.
    local tabContainer = CreateFrame("Frame", nil, panel)
    tabContainer:SetPoint("TOPLEFT", panel, "TOPLEFT", 4, -2)
    tabContainer:SetSize(440, 20)
    self.tabContainer = tabContainer
    local tabDefs = (RD.ui and RD.ui.bandsList and RD.ui.bandsList.TAB_KEYS)
        or { { key = "core", label = "Core" }, { key = "tank", label = "Tanque" }, { key = "healer", label = "Healer" }, { key = "rango", label = "Rango" }, { key = "melee", label = "Melee" }, { key = "sanctioned", label = "Sancionados" } }
    local tx = 0
    for _, t in ipairs(tabDefs) do
        local btn = RD.UIUtils.MakeChipButton(tabContainer, nil, 56, 20)
        btn:SetPoint("TOPLEFT", tabContainer, "TOPLEFT", tx, 0)
        btn:SetScript("OnClick", function()
            self.category = t.key
            self.page = 1
            self:Refresh()
        end)
        self.tabButtons[#self.tabButtons + 1] = { key = t.key, label = t.label, btn = btn }
        tx = tx + 62
    end

    -- Cabeceras de columna (debajo de las pestañas)
    local headerContainer = CreateFrame("Frame", nil, panel)
    headerContainer:SetPoint("TOPLEFT", panel, "TOPLEFT", 4, -26)
    headerContainer:SetSize(716, 18)
    self.headerContainer = headerContainer

    -- Scroll de jugadores (se estira con el panel; deja sitio abajo para la paginación).
    -- El offset de BOTTOM es POSITIVO: el scroll termina 28px ARRIBA del borde inferior
    -- del panel (no por debajo, lo que desbordaba el contenido fuera del marco).
    local playersScroll, playersChild = RD.ui.widgets.CreateScrollFrame(panel, 716, 322, 4, -48)
    playersScroll:SetPoint("BOTTOM", panel, "BOTTOM", 0, 28)
    self.playersScroll = playersScroll
    self.playersChild = playersChild

    -- Paginación de la lista (máximo 25 jugadores por página)
    local pageBar = CreateFrame("Frame", nil, panel)
    pageBar:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 4, 4)
    pageBar:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -4, 4)
    pageBar:SetHeight(20)
    local prevBtn = RD.UIUtils.MakeChipButton(pageBar, UniqueName("Pg"), 84, 20)
    prevBtn:SetText("Anterior")
    prevBtn:SetPoint("BOTTOMLEFT", pageBar, "BOTTOMLEFT", 0, 0)
    prevBtn:SetScript("OnClick", function()
        if self.page > 1 then
            self.page = self.page - 1
            self:Refresh()
        end
    end)
    self.pagePrevBtn = prevBtn
    local pageLabel = pageBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pageLabel:SetPoint("CENTER", pageBar, "CENTER", 0, 0)
    pageLabel:SetText("Página 1 / 1")
    RD.UIUtils.ScaleFont(pageLabel, 1.25)
    self.pageLabel = pageLabel
    local nextBtn = RD.UIUtils.MakeChipButton(pageBar, UniqueName("PgN"), 84, 20)
    nextBtn:SetText("Siguiente")
    nextBtn:SetPoint("BOTTOMRIGHT", pageBar, "BOTTOMRIGHT", 0, 0)
    nextBtn:SetScript("OnClick", function()
        self.page = self.page + 1
        self:Refresh()
    end)
    self.pageNextBtn = nextBtn

    -- Re-render automático si las bandas cambian en la configuración.
    -- Debounceado: editar un campo de banda dispara varios CONFIG_CHANGED
    -- encadenados (uno por tecla); antes cada uno reconstruía la tabla de filas
    -- al instante (churn de frames). El refresh final es idéntico.
    local bandsDebouncer = RD.UIUtils and RD.UIUtils.NewDebouncer
        and RD.UIUtils.NewDebouncer(0.15, function()
            if self.isShown then self:Refresh() end
        end)
    if RD.events and RD.events.Subscribe then
        RD.events:Subscribe("CONFIG_CHANGED", function(key)
            if key == "bands" and self.isShown and bandsDebouncer then
                bandsDebouncer:Fire()
            elseif key == "bands" and self.isShown then
                self:Refresh()
            end
        end)
    end

    -- Estado de conexión: GUILD_ROSTER_UPDATE invalida caché y repinta la tabla
    local rosterEvent = CreateFrame("Frame")
    rosterEvent:RegisterEvent("GUILD_ROSTER_UPDATE")
    rosterEvent:SetScript("OnEvent", function()
        local bs = RD.ui and RD.ui.bandsStatus
        if bs and bs.Invalidate then
            bs:Invalidate()
        end
        if self.isShown then
            self:Refresh()
        end
    end)
    self.rosterEvent = rosterEvent

    self:Refresh()
    return frame
end

-- Reconstruye el dropdown de selección de banda (título de la ventana) con las
-- bandas actuales, usando el widget estándar del addon (CreateOptionsDropdown,
-- como en BandsList/PlayerEditor/RulesSpammerWindow). Patrón de opciones
-- dinámicas: se destruye el botón anterior y se crea uno nuevo; se omite todo si
-- la lista de bandas o la selección no cambiaron desde la última vez.
function BandsWindow:RefreshBandDropdown()
    if not self.frame or not self.bandLabel then return end
    local bands = Bands()
    if not bands then return end
    local list = bands:GetBands() or {}
    local keyParts = { tostring(self.bandIndex or 1) }
    for i, b in ipairs(list) do
        keyParts[#keyParts + 1] = tostring(i) .. "=" .. tostring(b.name or "")
    end
    local key = table.concat(keyParts, ";")
    if key == self._bandDropdownKey then return end
    self._bandDropdownKey = key

    if self.bandDropdown and self.bandDropdown.button then
        self.bandDropdown.button:Hide()
        self.bandDropdown.button:SetParent(nil)
        self.bandDropdown = nil
    end

    local options = {}
    for i, b in ipairs(list) do
        options[#options + 1] = { key = tostring(i), label = LinkLabel(b.name) or ("Banda " .. i) }
    end

    local widgets = RD.ui and RD.ui.widgets
    self.bandDropdown = widgets and widgets.CreateOptionsDropdown
        and widgets:CreateOptionsDropdown(self.frame, 280, {
            emptyLabel = "Sin banda",
            current = tostring(self.bandIndex or 1),
            options = options,
            onSelect = function(key)
                local idx = tonumber(key)
                if idx and idx >= 1 then
                    self:ShowBand(idx)
                end
            end,
        })
    if self.bandDropdown and self.bandDropdown.button then
        self.bandDropdown.button:SetPoint("LEFT", self.bandLabel, "RIGHT", 6, 0)
        self.bandDropdown.button:SetHeight(22)
    end
end

function BandsWindow:ShowBand(index)
    if not self.frame then
        local ok, err = pcall(function() self:Create() end)
        if not ok then
            -- Si Create falló a mitad (frame parcial), se limpia para reintentar
            -- limpiamente en el próximo uso en lugar de mostrar una ventana rota.
            self.frame = nil
            Log("|cffff0000[RaidDominion]|r Error al abrir la ventana de banda: " .. tostring(err))
            return
        end
    end
    if not self.frame then return end
    if type(index) == "number" and index >= 1 then
        self.bandIndex = index
        self.page = 1
    end

    -- Posición inicial centrada (la primera vez); luego conserva la arrastrada
    if not self.positioned then
        self.frame:ClearAllPoints()
        self.frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        self.positioned = true
    end

    -- Solicita el roster de la hermandad si falta (disponible para la UI)
    EnsureRosterLoaded()

    -- Alto máximo: si la ventana no cabe en pantalla, se recorta el alto y el
    -- scroll de la lista absorbe el sobrante (sigue scrolleando).
    if RD.UIUtils and RD.UIUtils.ClampModalToScreen then
        RD.UIUtils.ClampModalToScreen(self.frame, self.playersScroll, 16)
    end

    self:Refresh()
    if RD.UIUtils and RD.UIUtils.ActivateWindow then
        RD.UIUtils.ActivateWindow(self.frame)
    else
        self.frame:Show()
        self.frame:Raise()
    end
    self.isShown = true
end

function BandsWindow:Show()
    self:ShowBand(self.bandIndex or 1)
end

function BandsWindow:Hide()
    if self.frame then self.frame:Hide() end
    self.isShown = false
end

function BandsWindow:Toggle()
    if self.isShown then self:Hide() else self:Show() end
end

RD.ui = RD.ui or {}
RD.ui.bandsWindow = BandsWindow
return BandsWindow
