--[[
    RD_UI_RulesSpammerWindow.lua
    PROPÓSITO: Modal de spam de reglas (config → Reglas → Spamear).
              Selector exclusivo (una regla), duración, canales (Posada + 1-9),
              vista previa con indicador de caracteres e inicio/parada del bucle.
    API PÚBLICA:
        - RD.ui.rulesSpammerWindow:Open() / Close() / Toggle()
        - RD.ui.rulesSpammerWindow:SetRunning(bool) / OnTick(...)
    EVENTOS: CONFIG_CHANGED("rules"|ui.rulesSpammer.*) recarga si está visible.
]]

local addonName, private = ...
local RD = _G.RaidDominion or {}
_G.RaidDominion = RD

local Win = {
    frame = nil,
    isShown = false,
    running = false,
}

local GOLD_R, GOLD_G, GOLD_B = unpack((RD.constants and RD.constants.COLORS and RD.constants.COLORS.GOLD) or { 1, 0.82, 0 })
local UniqueName = RD.UIUtils and RD.UIUtils.UniqueName
local Log = (RD.UIUtils and RD.UIUtils.Log) or function(msg) print(msg) end
local CreateScrollFrame = (RD.ui and RD.ui.widgets and RD.ui.widgets.CreateScrollFrame) or nil

local PAD, G = 12, 8
local WIN_W, WIN_H = 500, 350
local INNER = WIN_W - PAD * 2
local MAX_LEN = 255

-- Filas Y (desde el borde superior): título → duración → pestañas → contenido → preview.
local Y = {
    title = -10,
    durLbl = -36,
    durBox = -32,
    tabs = -60,
    tabContent = -88,
    prevLbl = -193,
    prev = -215,
}

-- Orden: chat estándar → Posada → Sistema → canales 1..9
local CHANNEL_LABELS = {
    { key = "RAID", label = "Banda" },
    { key = "RAID_WARNING", label = "Aviso" },
    { key = "GUILD", label = "Hermandad" },
    { key = "YELL", label = "Gritar" },
    { key = "SAY", label = "Decir" },
    { key = "PARTY", label = "Grupo" },
    { key = "INN", label = "Posada" },
    { key = "SYSTEM", label = "Sistema" },
    { key = "1", label = "1" },
    { key = "2", label = "2" },
    { key = "3", label = "3" },
    { key = "4", label = "4" },
    { key = "5", label = "5" },
    { key = "6", label = "6" },
    { key = "7", label = "7" },
    { key = "8", label = "8" },
    { key = "9", label = "9" },
}

-- Canales de salida puntual (originales + Grupo y Sistema, se mantiene Posada)
local OUTPUT_LABELS = {
    { key = "RAID", label = "Banda" },
    { key = "RAID_WARNING", label = "Aviso" },
    { key = "GUILD", label = "Hermandad" },
    { key = "YELL", label = "Gritar" },
    { key = "SAY", label = "Decir" },
    { key = "PARTY", label = "Grupo" },
    { key = "INN", label = "Posada" },
    { key = "SYSTEM", label = "Sistema" },
}

local function Mod()
    return RD.modules and RD.modules.rulesSpammer
end

local function MakeLabel(parent, text, x, y)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetText(text)
    fs:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    fs:SetTextColor(0.8, 0.8, 0.8)
    return fs
end

local function CollectChannels()
    local out = {}
    for i, c in ipairs(CHANNEL_LABELS) do
        local check = Win.channelChecks and Win.channelChecks[i]
        local checked = check and check:GetChecked()
        out[c.key] = (checked == true or checked == 1)
    end
    return out
end

local function CommitSettings()
    local m = Mod()
    if not m then return end
    local duration = tonumber(Win.durationBox and Win.durationBox:GetText()) or 45
    m:UpdateSettings({
        duration = duration,
        channels = CollectChannels(),
        selectedTitle = Win.selectedTitle or "",
    })
    Win:RebuildPreview()
end

local function SelectRule(title)
    Win.selectedTitle = title or ""
    if Win.ruleDropdown then
        Win.ruleDropdown:SetValue(Win.selectedTitle)
    end
    CommitSettings()
end

function Win:RebuildPreview()
    if not self.previewBox then return end
    local m = Mod()
    if not m then
        self.previewBox:SetText("")
        if self.lengthText then self.lengthText:SetText("0/" .. MAX_LEN) end
        if self.previewChild then self.previewChild:SetHeight(24) end
        return
    end
    local item = m.GetSelectedItem and m:GetSelectedItem()
    local text = item and m:BuildPreview(item) or "(ninguna regla seleccionada)"
    self.previewBox:SetText(text)

    -- Redimensionar el hijo del scroll al alto real del texto (la vista previa
    -- queda acotada al alto fijo del scroll y se desplaza si es más larga).
    if self.previewChild then
        local h = (self.previewBox.GetStringHeight and self.previewBox:GetStringHeight() + 8) or 24
        if h < 24 then h = 24 end
        self.previewChild:SetHeight(h)
    end

    local len = (m.GetLength and m:GetLength(item)) or 0
    local canStart = m.CanStart and m:CanStart() or false
    if self.lengthText then
        self.lengthText:SetText(tostring(len) .. "/" .. MAX_LEN)
        -- Verde si es enviable (splitter en canales normales; los canales de
        -- línea única —Posada e índices 1-9— exigen ≤255), rojo si no hay forma
        -- de enviarlo.
        if canStart then
            self.lengthText:SetTextColor(0, 1, 0)
        else
            self.lengthText:SetTextColor(1, 0, 0)
        end
    end
    if self.startBtn then
        if item and canStart then
            self.startBtn:Enable()
        else
            if not (m.IsActive and m:IsActive()) then
                self.startBtn:Disable()
            end
        end
    end
end

function Win:OnTick()
    self:RebuildPreview()
end

-- Muestra una sola pestaña de canales (bucle o salida puntual) a la vez.
function Win:SetChannelTab(tab)
    self.channelTab = tab
    local isLoop = (tab == "loop")
    for _, ctrl in ipairs(self.loopControls or {}) do
        for k = 1, 3 do
            if isLoop then ctrl[k]:Show() else ctrl[k]:Hide() end
        end
    end
    for _, btn in ipairs(self.outputControls or {}) do
        if isLoop then btn:Hide() else btn:Show() end
    end
    for key, btn in pairs(self.channelTabButtons or {}) do
        if RD.UIUtils and RD.UIUtils.PaintTabButton then
            RD.UIUtils.PaintTabButton(btn, key == tab)
        end
    end
end

-- Envía la regla seleccionada una sola vez al canal dado (salida puntual).
-- Dos renglones (título y contenido) en canales normales; la Posada (INN) y los
-- índices 1-9 reciben un único renglón ≤255 caracteres (permiten un mensaje
-- cada 10 s). Paridad con el spammer de banda (RD_UI_SpammerWindow:SendToChannel).
function Win:SendToChannel(channelKey)
    if not channelKey then return end
    CommitSettings()
    local m = Mod()
    local item = m and m.GetSelectedItem and m:GetSelectedItem()
    if not item then
        Log("|cffff0000[RaidDominion]|r No hay una regla seleccionada para enviar.")
        return
    end
    local skipped = m.SendItemToChannel and m:SendItemToChannel(item, channelKey)
    if skipped then
        Log("|cffff8000[RaidDominion]|r La regla supera 255 caracteres: la Posada y los índices 1-9 solo permiten un mensaje cada 10 s.")
    end
end

-- Abre el editor de la regla seleccionada con un contexto autónomo (el editor
-- de listas de contenido lee/escribe la config directamente, sin depender de
-- Configuración → Reglas). Sin selección avisa por Log.
function Win:EditSelectedRule()
    local m = Mod()
    local title = m and m.GetSettings and (m:GetSettings().selectedTitle or "") or ""
    local item = nil
    if title ~= "" and m and m.GetRules then
        for _, it in ipairs(m:GetRules()) do
            if tostring(it.title or it.name or "") == title then
                item = it
                break
            end
        end
    end
    if not item then
        Log("|cffff8000[RaidDominion]|r Selecciona una regla para editarla.")
        return
    end
    local widgets = RD.ui and RD.ui.widgets
    if widgets and widgets.OpenContentListEditor then
        widgets:OpenContentListEditor("rules", item)
    end
end

function Win:SetRunning(running)
    self.running = (running == true)
    if self.startBtn then
        if self.running then
            self.startBtn:SetText("Detener")
            self.startBtn:Enable()
        else
            self.startBtn:SetText("Iniciar")
        end
    end
end

function Win:RefreshRuleList()
    -- Selección de regla por DROPDOWN (lista seleccionable desplegable), como la
    -- lista de jugadores: un botón que despliega las reglas y marca la activa.
    -- Se reconstruye en cada refresh para reflejar cambios en la lista de reglas.
    local m = Mod()
    local rules = m and m:GetRules() or {}
    local settings = m and m:GetSettings() or {}
    -- Prioridad a la selección EN CURSO (dropdown) sobre la guardada: al cambiar
    -- de regla, UpdateSettings guarda duration/channels ANTES que selectedTitle y
    -- esos CONFIG_CHANGED intermedios disparan RefreshFields con la selección
    -- guardada aún vieja; si se leyera settings primero, el dropdown se
    -- reconstruiría con la regla ANTERIOR (revertía el cambio recién hecho).
    local selectedTitle = self.selectedTitle or settings.selectedTitle or ""

    -- Si no hay selección válida, precargar la primera regla
    local firstTitle = nil
    local found = false
    local options = {}
    for _, item in ipairs(rules) do
        local t = tostring(item.title or item.name or "")
        if t ~= "" then
            if not firstTitle then firstTitle = t end
            if t == selectedTitle then found = true end
            options[#options + 1] = { key = t, label = t }
        end
    end
    if not found then selectedTitle = firstTitle or "" end
    self.selectedTitle = selectedTitle

    -- Reconstruir el dropdown con las opciones actuales; se ancla al TÍTULO de
    -- la ventana (etiqueta "Regla:"), como el selector de banda del spammer.
    if self.ruleDropdown and self.ruleDropdown.button then
        self.ruleDropdown.button:Hide()
        self.ruleDropdown.button:SetParent(nil)
    end
    local widgets = RD.ui and RD.ui.widgets
    local gold = (RD.constants and RD.constants.COLORS and RD.constants.COLORS.GOLD) or { 1, 0.82, 0 }
    self.ruleDropdown = widgets and widgets.CreateOptionsDropdown
        and widgets:CreateOptionsDropdown(self.frame, 340, {
            emptyLabel = "—",
            current = selectedTitle,
            textColor = gold,
            options = options,
            onSelect = function(key)
                SelectRule(key)
            end,
        })
    if self.ruleDropdown and self.ruleDropdown.button then
        self.ruleDropdown.button:SetPoint("LEFT", self.ruleLabel, "RIGHT", 6, 0)
        if RD.UIUtils and RD.UIUtils.StyleTitleDropdown then
            RD.UIUtils.StyleTitleDropdown(self.ruleDropdown)
        end
    end

    -- Persistir si se precargó la primera (cuando no había selección)
    if selectedTitle ~= (settings.selectedTitle or "") then
        CommitSettings()
    end
end

function Win:RefreshFields()
    local m = Mod()
    local settings = m and m:GetSettings() or {}
    if self.durationBox then
        self.durationBox:SetText(tostring(settings.duration or 45))
    end
    local channels = settings.channels or {}
    for i, c in ipairs(CHANNEL_LABELS) do
        local check = self.channelChecks and self.channelChecks[i]
        if check then
            check:SetChecked(channels[c.key] == true or channels[c.key] == 1)
        end
    end
    -- No se resetea self.selectedTitle desde settings aquí: lo gestiona
    -- RefreshRuleList (prioridad a la selección en curso), para que un cambio de
    -- regla en el dropdown no se revierta por los refrescos intermedios.
    self:RefreshRuleList()
    -- Persistir selección por defecto si se precargó la primera
    if self.selectedTitle ~= (settings.selectedTitle or "") then
        CommitSettings()
    else
        self:RebuildPreview()
    end
    self:SetRunning(m and m.IsActive and m:IsActive())
end

function Win:Create()
    if self.frame then return self.frame end

    local frame = CreateFrame("Frame", "RaidDominionRulesSpammer", UIParent)
    -- Strata MEDIUM (paridad con los paneles de personaje de WoW): la ventana
    -- se cubre/descubre con la UI del juego y pasa al frente al activarla.
    if RD.UIUtils and RD.UIUtils.SetupWindow then
        RD.UIUtils.SetupWindow(frame)
    else
        frame:SetFrameStrata("MEDIUM")
        frame:SetToplevel(true)
        frame:SetClampedToScreen(true)
    end
    frame:SetSize(WIN_W, WIN_H)
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function() frame:StartMoving() end)
    frame:SetScript("OnDragStop", function()
        frame:StopMovingOrSizing()
        local point, relativeTo, relativePoint, xOfs, yOfs = frame:GetPoint(1)
        local relativeName = "UIParent"
        if relativeTo and relativeTo.GetName then relativeName = relativeTo:GetName() end
        if RD.config and RD.config.Set then
            RD.config:Set("ui.rulesSpammer.position", {
                point = point, relativeTo = relativeName,
                relativePoint = relativePoint or point, x = xOfs or 0, y = yOfs or 0,
            })
        end
    end)
    frame:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    frame:SetBackdropColor(0, 0, 0, 0.95)
    frame:SetBackdropBorderColor(1, 1, 1, 0.5)
    table.insert(UISpecialFrames, "RaidDominionRulesSpammer")
    self.frame = frame
    if RD.UIUtils and RD.UIUtils.TrackScale then RD.UIUtils.TrackScale(frame) end

    -- Selector de regla (título de la ventana): etiqueta + dropdown que lista
    -- las reglas y permite cambiar entre ellas (widget estándar del addon, mismo
    -- patrón que el título del spammer de banda). El botón se construye en
    -- RefreshRuleList y se ancla a esta etiqueta.
    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    title:SetText("Regla:")
    title:SetTextColor(0.8, 0.8, 0.8)
    title:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -10)
    self.ruleLabel = title
    RD.UIUtils.ScaleFont(title, 1.25)

    local closeBtn = CreateFrame("Button", UniqueName("RsC"), frame, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4)
    closeBtn:SetScript("OnClick", function() self:Close() end)

    MakeLabel(frame, "Duración (s)", PAD, Y.durLbl)
    self.durationBox = CreateFrame("EditBox", UniqueName("RsD"), frame, "InputBoxTemplate")
    self.durationBox:SetWidth(48)
    self.durationBox:SetAutoFocus(false)
    self.durationBox:SetNumeric(true)
    RD.UIUtils.StyleInput(self.durationBox)
    if RD.UIUtils and RD.UIUtils.DisableLinkInsertion then
        RD.UIUtils.DisableLinkInsertion(self.durationBox)
    end
    self.durationBox:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD + 80, Y.durBox)
    -- Enter/Escape liberan el foco del control (estilo KRT, como el spammer de
    -- banda): tras commitear se hace ClearFocus para poder usar los atajos del
    -- teclado sin que las teclas sigan entrando en el editbox. El Escape cierra
    -- la ventana en un segundo toque vía UISpecialFrames.
    self.durationBox:SetScript("OnEnterPressed", function()
        CommitSettings()
        self.durationBox:ClearFocus()
    end)
    self.durationBox:SetScript("OnEscapePressed", function()
        CommitSettings()
        self.durationBox:ClearFocus()
    end)
    self.durationBox:SetScript("OnEditFocusLost", function() CommitSettings() end)

    -- Pestañas compactas: "Canales" (bucle) y "Salida" (puntual por canal).
    self.channelChecks = {}
    self.loopControls = {}
    self.outputControls = {}
    self.channelTabButtons = {}
    local MakeChipButton = (RD.UIUtils and RD.UIUtils.MakeChipButton) or function() return nil end
    local TAB_W = 88
    local tabs = { { key = "loop", label = "Canales" }, { key = "output", label = "Salida" } }
    for i, t in ipairs(tabs) do
        local btn = MakeChipButton(frame, UniqueName("RsTab"), TAB_W, 24)
        btn:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD + (i - 1) * (TAB_W + G), Y.tabs)
        btn.rdText:SetText(t.label)
        btn.rdTab = t.key
        btn:SetScript("OnClick", function() self:SetChannelTab(t.key) end)
        self.channelTabButtons[t.key] = btn
    end

    -- Canales del bucle (5 columnas, estándar + Posada + Sistema + 1..9).
    local cols = 5
    local colW = math.floor((INNER - G * (cols - 1)) / cols)
    for i, c in ipairs(CHANNEL_LABELS) do
        local col = (i - 1) % cols
        local row = math.floor((i - 1) / cols)
        local check, labelButton, label = RD.UIUtils.CreateToggleCheck(frame, c.label, function()
            CommitSettings()
        end)
        check:SetSize(24, 24)
        check:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD + col * (colW + G), Y.tabContent - row * 26)
        label:SetPoint("LEFT", check, "RIGHT", 4, 0)
        -- El área clicable cubre cuadrado + texto (como el widget central)
        labelButton:SetPoint("LEFT", check, "RIGHT", 4, 0)
        labelButton:SetWidth(colW - check:GetWidth() - 4)
        self.channelChecks[i] = check
        self.loopControls[#self.loopControls + 1] = { check, labelButton, label }
    end

    -- Salida puntual por canal (4 columnas): envía la regla seleccionada una vez.
    local outCols = 4
    local outColW = math.floor((INNER - G * (outCols - 1)) / outCols)
    for i, c in ipairs(OUTPUT_LABELS) do
        local col = (i - 1) % outCols
        local row = math.floor((i - 1) / outCols)
        local btn = MakeChipButton(frame, UniqueName("RsOut"), outColW, 24)
        btn:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD + col * (outColW + G), Y.tabContent - row * 28)
        btn.rdText:SetText(c.label)
        btn.rdChannel = c.key
        btn:SetScript("OnClick", function() self:SendToChannel(c.key) end)
        self.outputControls[#self.outputControls + 1] = btn
    end
    self:SetChannelTab(self.channelTab or "loop")

    -- Vista previa (acotada a PREV_H con scroll, como el spammer de banda).
    MakeLabel(frame, "Vista previa:", PAD, Y.prevLbl)
    self.lengthText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    self.lengthText:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PAD, Y.prevLbl)
    self.lengthText:SetText("0/" .. MAX_LEN)
    self.lengthText:SetTextColor(0, 1, 0)

    local PREV_H = 100
    local prevScroll, prevChild = CreateScrollFrame(frame, INNER - 16, PREV_H, PAD, Y.prev)
    prevScroll:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    prevScroll:SetBackdropColor(0, 0, 0, 0.7)
    prevScroll:SetBackdropBorderColor(0.5, 0.5, 0.5, 0.7)
    self.previewScroll = prevScroll
    self.previewChild = prevChild
    self.previewBox = prevChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    self.previewBox:SetPoint("TOPLEFT", prevChild, "TOPLEFT", 4, -4)
    self.previewBox:SetWidth(INNER - 28)
    self.previewBox:SetWordWrap(true)
    self.previewBox:SetJustifyH("LEFT")
    self.previewBox:SetTextColor(1, 1, 1)
    do
        local fontPath, fontSize, fontFlags = self.previewBox:GetFont()
        if fontPath and fontSize then
            self.previewBox:SetFont(fontPath, fontSize + 2, fontFlags)
        end
    end

    self.startBtn = MakeChipButton(frame, UniqueName("RsS"), 140, 24)
    self.startBtn:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PAD, PAD)
    self.startBtn:SetText("Iniciar")
    self.startBtn:SetScript("OnClick", function()
        CommitSettings()
        local m = Mod()
        if not m then return end
        if m:IsActive() then
            m:Stop()
            self:SetRunning(false)
            self:RebuildPreview()
            return
        end
        local ok = m:Start()
        if not ok then
            Log("|cffff0000[RaidDominion]|r No se pudo iniciar: elige una regla no vacía y al menos un canal (los canales de línea única —Posada y 1-9— exigen ≤255 caracteres).")
        end
        self:SetRunning(m:IsActive())
        self:RebuildPreview()
    end)

    -- Editar la regla activa: abre el editor de la lista de reglas (Configuración
    -- → Reglas) con el elemento vivo correspondiente a la selección actual.
    self.editBtn = MakeChipButton(frame, UniqueName("RsE"), 110, 24)
    self.editBtn:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", PAD, PAD)
    self.editBtn:SetText("Editar regla")
    RD.UIUtils.AddButtonTooltip(self.editBtn, function()
        return "Abre el editor de la regla seleccionada en Configuración > Reglas."
    end)
    self.editBtn:SetScript("OnClick", function()
        self:EditSelectedRule()
    end)

    self.timeLeftText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    self.timeLeftText:SetPoint("RIGHT", self.startBtn, "LEFT", -G, 0)
    self.timeLeftText:SetTextColor(GOLD_R, GOLD_G, GOLD_B)
    local timeFrame = CreateFrame("Frame")
    timeFrame:SetScript("OnUpdate", function()
        if not Win.frame or not Win.isShown then timeFrame:Hide() return end
        local m = Mod()
        if m and m.IsActive and m:IsActive() then
            Win.timeLeftText:SetText("Próximo: " .. math.ceil(m:TimeLeft() or 0) .. "s")
            Win.timeLeftText:Show()
        else
            Win.timeLeftText:SetText("")
            Win.timeLeftText:Hide()
        end
    end)
    timeFrame:Hide()
    self.timeFrame = timeFrame

    if RD.events and RD.events.Subscribe then
        -- Debounceado: editar reglas dispara un Set por tecla -> CONFIG_CHANGED;
        -- RefreshFields reconstruiría los campos al instante por cada una. El
        -- caso selectedTitle se mantiene inmediato (solo reconstruye el preview,
        -- sin escribir config, no produce bucle).
        local fieldsDebouncer = RD.UIUtils and RD.UIUtils.NewDebouncer
            and RD.UIUtils.NewDebouncer(0.15, function()
                if Win.isShown then Win:RefreshFields() end
            end)
        RD.events:Subscribe("CONFIG_CHANGED", function(key)
            if not Win.isShown then return end
            if key == "rules" or (type(key) == "string" and key:find("^ui%.rulesSpammer"))
                or (type(key) == "string" and key:find("^announce%.rules")) then
                -- Evita bucle al guardar selectedTitle desde RefreshFields
                if key == "ui.rulesSpammer.selectedTitle" then
                    Win:RebuildPreview()
                    return
                end
                if key and key:find("^announce%.rules") then
                    -- Cambió el estilo del título (announce.rules.wrapper):
                    -- solo hay que refrescar la vista previa.
                    Win:RebuildPreview()
                    return
                end
                if fieldsDebouncer then
                    fieldsDebouncer:Fire()
                else
                    Win:RefreshFields()
                end
            end
        end)
    end

    local pos = RD.config and RD.config.Get and RD.config:Get("ui.rulesSpammer.position")
    if type(pos) == "table" and pos.point then
        local relativeTo = UIParent
        if pos.relativeTo and pos.relativeTo ~= "UIParent" then
            relativeTo = _G[pos.relativeTo] or UIParent
        end
        frame:ClearAllPoints()
        frame:SetPoint(pos.point, relativeTo, pos.relativePoint or pos.point, pos.x or 0, pos.y or 0)
    end
    if RD.ui and RD.ui.layout and RD.ui.layout.EnsureVisible then
        RD.ui.layout:EnsureVisible(frame, 8)
    end

    return frame
end

function Win:Open()
    if not self.frame then
        local ok, err = pcall(function() self:Create() end)
        if not ok then
            self.frame = nil
            Log("|cffff0000[RaidDominion]|r Error al abrir spammer de reglas: " .. tostring(err))
            return
        end
    end
    if not self.frame then return end
    self:RefreshFields()
    if RD.UIUtils and RD.UIUtils.ActivateWindow then
        RD.UIUtils.ActivateWindow(self.frame)
    else
        self.frame:Show()
        self.frame:Raise()
    end
    self.isShown = true
    if self.timeFrame then self.timeFrame:Show() end
end

function Win:Close()
    if not self.frame then return end
    CommitSettings()
    if self.timeFrame then self.timeFrame:Hide() end
    self.frame:Hide()
    self.isShown = false
end

function Win:Toggle()
    if self.isShown then self:Close() else self:Open() end
end

RD.ui = RD.ui or {}
RD.ui.rulesSpammerWindow = Win
return Win
