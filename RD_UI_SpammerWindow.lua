--[[
    RD_UI_SpammerWindow.lua
    PROPÓSITO: Ventana modal del spammer de reclutamiento por banda (estilo KRT).
              Edita bands[i].spammer: prefijo/nombre/sufijo, duración, composición
              por rol, mensaje con placeholders, canales y vista previa (límite 255).
              El nombre se sincroniza desde band.name al abrir (ICC25H → "ICC 25H").
              Las constantes de layout/canales y el envío por canal viven en
              RD_UI_SpammerWindowCore.lua (carga previa); el control
              (Open/Close/Toggle) en RD_UI_SpammerWindow_Control.lua.
    API PÚBLICA:
        - RD.ui.spammerWindow:Open(bandIndex) / Close() / Toggle()
        - RD.ui.spammerWindow:SetRunning(bool) / RefreshBandDropdown()
        - El título de la ventana es un dropdown (CreateOptionsDropdown) que
          lista las bandas y permite cambiar entre ellas (SelectBand).
    EVENTOS: CONFIG_CHANGED("bands") (sync + recarga si la ventana está visible).
]]

local addonName, private = ...
local RD = _G.RaidDominion or {}
_G.RaidDominion = RD

local SpammerWindow = assert(RD.ui and RD.ui.spammerWindow, "RD_UI_SpammerWindowCore.lua debe cargarse antes que RD_UI_SpammerWindow.lua")

-- Constantes de layout/canales expuestas por el core (RD_UI_SpammerWindowCore.lua)
local C = SpammerWindow.constants
local PAD, G = C.PAD, C.G
local WIN_W, WIN_H, INNER = C.WIN_W, C.WIN_H, C.INNER
local CHANNEL_LABELS, OUTPUT_LABELS, Y = C.CHANNEL_LABELS, C.OUTPUT_LABELS, C.Y

local GOLD_R, GOLD_G, GOLD_B = unpack((RD.constants and RD.constants.COLORS and RD.constants.COLORS.GOLD) or { 1, 0.82, 0 })

local UniqueName = RD.UIUtils and RD.UIUtils.UniqueName
local Log = (RD.UIUtils and RD.UIUtils.Log) or function(msg) print(msg) end
-- Texto "presentable" para UN FontString de 3.3.5a: un FontString normal NO
-- renderiza el marcado de enlace |H...|h como enlace interactivo (no existe el
-- hipervínculo activo fuera de las plantillas de chat). Se conserva el mensaje
-- crudo (con el enlace) en self.lastPreviewRaw para enviar/copiar tal cual, y la
-- preview muestra el texto visible con su color: con LinkLabel el FontString
-- parsea |c/|r (color de la rareza) y solo se retira el envoltorio |H/|K
-- (que se vería crudo). Resultado: la preview se ve como el mensaje en el chat.
local StripMarkup = (RD.UIUtils and RD.UIUtils.StripMarkup) or function(t) return tostring(t or "") end
local LinkLabel = (RD.UIUtils and RD.UIUtils.LinkLabel) or StripMarkup
local CreateScrollFrame = (RD.ui and RD.ui.widgets and RD.ui.widgets.CreateScrollFrame) or nil

local function GetCurrent()
    local bands = RD.utils and RD.utils.bands
    if not bands or not SpammerWindow.bandIndex then return nil end
    return bands:GetSpammer(SpammerWindow.bandIndex)
end

local function Commit(key, value)
    local bands = RD.utils and RD.utils.bands
    if not bands or not SpammerWindow.bandIndex then return end
    -- Flush del borrador antes de escribir: un write a bands[i].spammer dispara
    -- CONFIG_CHANGED -> SyncToBands -> RefreshFields, que re-pinta los campos
    -- desde la config; si el texto en vivo no está commiteado, se pierde al
    -- togglear un check de canal o un ojo de rol. Mismo patrón que CommitSeparator.
    if SpammerWindow._commitTexts then SpammerWindow:_commitTexts() end
    local partial = {}
    partial[key] = value
    bands:UpdateSpammer(SpammerWindow.bandIndex, partial)
    if SpammerWindow.RebuildPreview then SpammerWindow:RebuildPreview() end
end

-- Preview en vivo desde los campos del UI (sin commitear)
function SpammerWindow:RebuildPreview()
    if not self.frame or not self.previewBox or not self.lengthText then return end
    local spammer = RD.modules and RD.modules.spammer
    local msg = ""
    local len = 0
    if spammer and self.bandIndex and spammer.BuildMessage then
        local current = GetCurrent()
        if current and self.messageBox and self.nameBox then
            local previewData = {}
            for k, v in pairs(current) do
                if type(v) == "table" then
                    previewData[k] = {}
                    for kk, vv in pairs(v) do previewData[k][kk] = vv end
                else
                    previewData[k] = v
                end
            end
            previewData.prefix = (self.prefixBox and self.prefixBox:GetText()) or ""
            previewData.name = self.nameBox:GetText() or ""
            previewData.suffix = (self.suffixBox and self.suffixBox:GetText()) or ""
            previewData.duration = tonumber(self.durationBox and self.durationBox:GetText()) or previewData.duration
            previewData.tank = tonumber(self.tankBox and self.tankBox:GetText()) or 0
            previewData.tankClass = (self.tankClassBox and self.tankClassBox:GetText()) or ""
            previewData.healer = tonumber(self.healerBox and self.healerBox:GetText()) or 0
            previewData.healerClass = (self.healerClassBox and self.healerClassBox:GetText()) or ""
            previewData.melee = tonumber(self.meleeBox and self.meleeBox:GetText()) or 0
            previewData.meleeClass = (self.meleeClassBox and self.meleeClassBox:GetText()) or ""
            previewData.ranged = tonumber(self.rangedBox and self.rangedBox:GetText()) or 0
            previewData.rangedClass = (self.rangedClassBox and self.rangedClassBox:GetText()) or ""
            previewData.message = self.messageBox:GetText() or ""
            if spammer.BuildMessageFrom then
                msg = spammer:BuildMessageFrom(previewData, self.bandIndex)
            else
                msg = spammer:BuildMessage(self.bandIndex)
            end
        else
            msg = spammer:BuildMessage(self.bandIndex)
        end
    end
    self.lastPreviewRaw = msg or ""
    -- La preview muestra el texto VISIBLE con su color (los receptores ven el
    -- nombre del enlace en el chat, coloreado: "[Espina de Saronita]" en morado
    -- si es un ítem, etc.), no el marcado crudo |H...|h.
    self.previewBox:SetText(LinkLabel(self.lastPreviewRaw))
    -- Redimensiona el hijo del scroll al alto real del texto.
    if self.previewChild then
        local h = (self.previewBox.GetStringHeight and self.previewBox:GetStringHeight() + 8) or 24
        if h < 24 then h = 24 end
        self.previewChild:SetHeight(h)
    end
    len = (spammer and spammer.CharCount and spammer:CharCount(msg)) or #msg
    self.lengthText:SetText(tostring(len) .. "/255")
    if len <= 255 then
        self.lengthText:SetTextColor(0.0, 1.0, 0.0)
    else
        self.lengthText:SetTextColor(1.0, 0.0, 0.0)
    end
    local canStart = (len > 0 and len <= 255)
    if self.startBtn then
        if canStart then self.startBtn:Enable() else self.startBtn:Disable() end
    end
end

function SpammerWindow:RefreshFields()
    if not self.frame then return end
    local s = GetCurrent()
    if not s then return end
    if self.prefixBox then self.prefixBox:SetText(s.prefix or "") end
    if self.nameBox then self.nameBox:SetText(s.name or "") end
    if self.suffixBox then self.suffixBox:SetText(s.suffix or "") end
    if self.durationBox then self.durationBox:SetText(tostring(s.duration or 60)) end
    if self.tankBox then self.tankBox:SetText(tostring(s.tank or 0)) end
    if self.tankClassBox then self.tankClassBox:SetText(s.tankClass or "") end
    if self.healerBox then self.healerBox:SetText(tostring(s.healer or 0)) end
    if self.healerClassBox then self.healerClassBox:SetText(s.healerClass or "") end
    if self.meleeBox then self.meleeBox:SetText(tostring(s.melee or 0)) end
    if self.meleeClassBox then self.meleeClassBox:SetText(s.meleeClass or "") end
    if self.rangedBox then self.rangedBox:SetText(tostring(s.ranged or 0)) end
    if self.rangedClassBox then self.rangedClassBox:SetText(s.rangedClass or "") end
    -- Estado de los ojos de clase (incluir/omitir el texto de clases por rol)
    if self.roleEyes then
        for _, eye in ipairs(self.roleEyes) do
            if eye.SetShow then eye:SetShow(s[eye.showKey] ~= false) end
        end
    end
    if self.messageBox then self.messageBox:SetText(s.message or "") end
    if self.separatorDropdown and self.separatorDropdown.SetValue then
        self.separatorDropdown:SetValue(s.separator or "")
    end
    if self.ResizeMessageBox then self:ResizeMessageBox() end
    local channels = s.channels or {}
    for i, c in ipairs(CHANNEL_LABELS) do
        local check = self.channelChecks and self.channelChecks[i]
        if check then
            local v = channels[c.key]
            check:SetChecked(v == true or v == 1)
        end
    end
    if self.RebuildPreview then self:RebuildPreview() end
end

local function MakeEditBox(parent, x, y, w)
    local box = CreateFrame("EditBox", UniqueName("SpE"), parent, "InputBoxTemplate")
    box:SetWidth(w)
    box:SetAutoFocus(false)
    RD.UIUtils.StyleInput(box)
    box:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    return box
end

local function MakeLabel(parent, text, x, y)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetText(text)
    fs:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    fs:SetTextColor(0.8, 0.8, 0.8)
    return fs
end

-- Botón "chip" para pestañas/salida: fondo oscuro translúcido, borde dorado
-- suave, texto dorado y un highlight en hover (estética consistente del addon).
local MakeChipButton = (RD.UIUtils and RD.UIUtils.MakeChipButton) or function() return nil end

function SpammerWindow:BuildChannelControls(frame)
    if not frame then return end
    self.channelChecks = {}
    self.loopControls = {}
    self.outputControls = {}
    self.channelTabButtons = {}

    local function CommitChannels()
        Commit("channels", self:CollectChannels())
    end

    -- Pestañas compactas: "Canales" (bucle) y "Salida" (puntual por canal).
    local TAB_W = 88
    local tabs = { { key = "loop", label = "Canales" }, { key = "output", label = "Salida" } }
    for i, t in ipairs(tabs) do
        local btn = MakeChipButton(frame, UniqueName("SpTab"), TAB_W, 24)
        btn:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD + (i - 1) * (TAB_W + G), Y.tabs)
        btn.rdText:SetText(t.label)
        btn.rdTab = t.key
        btn:SetScript("OnClick", function() self:SetChannelTab(t.key) end)
        self.channelTabButtons[t.key] = btn
    end

    -- Canales del bucle (5 columnas).
    local cols = 5
    local colW = math.floor((INNER - G * (cols - 1)) / cols)
    for i, c in ipairs(CHANNEL_LABELS) do
        local col = (i - 1) % cols
        local row = math.floor((i - 1) / cols)
        local check, labelButton, label = RD.UIUtils.CreateToggleCheck(frame, c.label, function()
            CommitChannels()
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

    -- Salida puntual por canal (4 columnas).
    local outCols = 4
    local outColW = math.floor((INNER - G * (outCols - 1)) / outCols)
    for i, c in ipairs(OUTPUT_LABELS) do
        local col = (i - 1) % outCols
        local row = math.floor((i - 1) / outCols)
        local btn = MakeChipButton(frame, UniqueName("SpCh"), outColW, 24)
        btn:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD + col * (outColW + G), Y.tabContent - row * 28)
        btn.rdText:SetText(c.label)
        btn.rdChannel = c.key
        btn:SetScript("OnClick", function() self:SendToChannel(c.key) end)
        self.outputControls[#self.outputControls + 1] = btn
    end

    self:SetChannelTab(self.channelTab or "loop")
end

function SpammerWindow:BuildMessageField(frame)
    if not frame then return end
    -- Campo 20px más angosto que el ancho interior de la ventana.
    local msgW = INNER - 20

    -- Alto fijo: desde Y.msg hasta justo antes de las pestañas de canales (Y.tabs).
    local msgH = Y.msg - (Y.tabs + 6)
    MakeLabel(frame, "Mensaje", PAD, Y.msgLbl)

    local msgScroll = CreateScrollFrame(frame, msgW, msgH, PAD, Y.msg)
    msgScroll:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, Y.msg)
    msgScroll:SetPoint("RIGHT", frame, "RIGHT", -(PAD + 20), 0)
    msgScroll:SetHeight(msgH)

    -- EditBox multilínea SIN template (paridad con el campo Notas): el dibujado lo aporta el SetBackdrop.
    self.messageBox = CreateFrame("EditBox", UniqueName("SpM"), msgScroll)
    self.messageBox:SetWidth(msgW)
    self.messageBox:SetHeight(msgH)
    self.messageBox:SetPoint("TOPLEFT", msgScroll, "TOPLEFT", 0, 0)
    self.messageBox:SetMultiLine(true)
    self.messageBox:SetAutoFocus(false)
    self.messageBox:EnableMouse(true)
    self.messageBox:SetFontObject(GameFontNormalSmall)
    RD.UIUtils.ScaleFont(self.messageBox, 1.5)
    self.messageBox:SetTextInsets(4, 4, 4, 4)
    self.messageBox:SetBackdrop({ bgFile = "Interface\\ChatFrame\\ChatFrameBackground", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 12, insets = { left = 2, right = 2, top = 2, bottom = 2 } })
    self.messageBox:SetBackdropColor(0, 0, 0, 0.7)
    self.messageBox:SetBackdropBorderColor(0.5, 0.5, 0.5, 0.7)
    msgScroll:SetScrollChild(self.messageBox)
    self.messageScroll = msgScroll

    self.ResizeMessageBox = RD.UIUtils.MakeAutoResizeMultiline(self.messageBox, msgScroll, msgW - 8)

    frame:SetScript("OnShow", function()
        if self.messageBox and self.messageBox.SetText then
            self.messageBox:SetText(self.messageBox:GetText() or "")
        end
        if self.ResizeMessageBox then self:ResizeMessageBox() end
        if self.RebuildPreview then self:RebuildPreview() end
    end)

    self.messageBox:SetScript("OnTextSet", function()
        if self.ResizeMessageBox then self:ResizeMessageBox() end
    end)
end

function SpammerWindow:Create()
    if self.frame then return self.frame end

    local frame = CreateFrame("Frame", "RaidDominionSpammer", UIParent)
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
            RD.config:Set("ui.spammer.position", {
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
    table.insert(UISpecialFrames, "RaidDominionSpammer")
    self.frame = frame
    if RD.UIUtils and RD.UIUtils.TrackScale then RD.UIUtils.TrackScale(frame) end

    -- Título de la ventana: etiqueta + dropdown de bandas.
    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    title:SetText("Banda:")
    title:SetTextColor(0.8, 0.8, 0.8)
    title:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, Y.title)
    self.bandLabel = title
    RD.UIUtils.ScaleFont(title, 1.25)

    local closeBtn = CreateFrame("Button", UniqueName("SpC"), frame, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4)
    closeBtn:SetScript("OnClick", function() self:Close() end)
    -- Fila nombre: Prefijo/Nombre/Sufijo mismo ancho; separador antes de Dur.
    local NUM_W = 36
    local fW = 140               -- ancho común de Prefijo, Nombre y Sufijo (extienden al espacio libre)
    local durW = NUM_W
    local sepW = 88              -- ancho del dropdown de separador
    local xPrefix = PAD
    local xName = xPrefix + fW + G
    local xSuffix = xName + fW + G
    local xSep = xSuffix + fW + G
    local xDur = xSep + sepW + G

    MakeLabel(frame, "Prefijo", xPrefix, Y.nameLbl)
    self.prefixBox = MakeEditBox(frame, xPrefix, Y.nameBox, fW)
    MakeLabel(frame, "Nombre", xName, Y.nameLbl)
    self.nameBox = MakeEditBox(frame, xName, Y.nameBox, fW)
    MakeLabel(frame, "Sufijo", xSuffix, Y.nameLbl)
    self.suffixBox = MakeEditBox(frame, xSuffix, Y.nameBox, fW)
    MakeLabel(frame, "Separador", xSep, Y.nameLbl)
    self.sepX = xSep
    self.separatorBox = nil
    MakeLabel(frame, "Dur.(s)", xDur, Y.nameLbl)
    self.durationBox = MakeEditBox(frame, xDur, Y.nameBox, durW)
    self.durationBox:SetNumeric(true)
    if RD.UIUtils and RD.UIUtils.DisableLinkInsertion then
        RD.UIUtils.DisableLinkInsertion(self.durationBox)
    end

    local sepDefs = (RD.constants and RD.constants.SPAMMER_SEPARATORS) or {}
    local sepOpts = {}
    for _, s in ipairs(sepDefs) do
        sepOpts[#sepOpts + 1] = { key = s.key, label = s.label }
    end
    self.separatorDropdown = RD.ui.widgets.CreateOptionsDropdown
        and RD.ui.widgets:CreateOptionsDropdown(frame, sepW, {
            emptyLabel = "Sin separador",
            current = "",
            options = sepOpts,
            onSelect = function(key) self:CommitSeparator(key) end,
        })
    if self.separatorDropdown and self.separatorDropdown.button then
        self.separatorDropdown.button:SetPoint("TOPLEFT", frame, "TOPLEFT", xSep, Y.nameBox)
        self.separatorDropdown.button:SetHeight(24)
    end

    -- Composición 2×2: labels anclados al centro del conteo (input h=24).
    -- El ancho de los campos de CLASES se reduce lo justo para reservar al final
    -- de cada fila el botón-ojo (incluir/omitir el texto de clases).
    MakeLabel(frame, "Composición", PAD, Y.compLbl)
    local half = math.floor((INNER - G) / 2)
    local roleLabelW = 48
    local EYE_W = 22
    local roleClassX = roleLabelW + NUM_W + G
    local roleClassW = half - roleClassX - EYE_W - G
    local roleDefs = {
        { y = Y.role1, role = "Tank",   countKey = "tank",   classKey = "tankClass",   showKey = "tankClassShow",   x = PAD },
        { y = Y.role2, role = "Healer", countKey = "healer", classKey = "healerClass", showKey = "healerClassShow", x = PAD },
        { y = Y.role1, role = "Melee",  countKey = "melee",  classKey = "meleeClass",  showKey = "meleeClassShow",  x = PAD + half + G },
        { y = Y.role2, role = "Rango",  countKey = "ranged", classKey = "rangedClass", showKey = "rangedClassShow", x = PAD + half + G },
    }
    self.roleEyes = {}
    for _, rc in ipairs(roleDefs) do
        local countBox = MakeEditBox(frame, rc.x + roleLabelW, rc.y, NUM_W)
        countBox:SetNumeric(true)
        if RD.UIUtils and RD.UIUtils.DisableLinkInsertion then
            RD.UIUtils.DisableLinkInsertion(countBox)
        end
        local classBox = MakeEditBox(frame, rc.x + roleClassX, rc.y, roleClassW)
        local lbl = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        lbl:SetText(rc.role)
        lbl:SetTextColor(0.8, 0.8, 0.8)
        -- Alineación vertical con el EditBox (TOPLEFT del label no coincide con el centro del input)
        lbl:SetPoint("RIGHT", countBox, "LEFT", -4, 0)

        -- Botón-ojo: incluye o NO el texto de CLASES de este rol en el mensaje
        -- (el número y el rol siempre van). Estado: bands[i].spammer.<showKey>.
        local eye = CreateFrame("Button", UniqueName("SpEye"), frame)
        eye:SetSize(EYE_W, EYE_W)
        eye:SetPoint("LEFT", classBox, "RIGHT", G, 0)
        eye.showKey = rc.showKey -- clave de config que alterna este ojo
        local eyeTex = eye:CreateTexture(nil, "ARTWORK")
        eyeTex:SetAllPoints()
        eyeTex:SetTexture("Interface\\Icons\\INV_Misc_Eye_01")
        eye:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
        local on = true
        eye.SetShow = function(self, show)
            on = (show ~= false)
            eyeTex:SetVertexColor(on and 1 or 0.35, on and 1 or 0.35, on and 1 or 0.35)
        end
        eye:SetScript("OnEnter", function(self)
            if not (RD.UIUtils and RD.UIUtils.TooltipsEnabled and RD.UIUtils.TooltipsEnabled()) then
                GameTooltip:Hide()
                return
            end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(on and "Incluir el texto de clases en el mensaje"
                or "Omitir el texto de clases del mensaje", 1, 0.82, 0, 1, true)
            GameTooltip:AddLine("El número y el rol siempre se incluyen.", 1, 1, 1, true)
            GameTooltip:Show()
        end)
        eye:SetScript("OnLeave", function() GameTooltip:Hide() end)
        eye:SetScript("OnClick", function(self)
            local cur = GetCurrent()
            local show = not (cur and cur[self.showKey] ~= false)
            Commit(self.showKey, show)
        end)
        self.roleEyes[#self.roleEyes + 1] = eye

        if rc.countKey == "tank" then self.tankBox = countBox; self.tankClassBox = classBox
        elseif rc.countKey == "healer" then self.healerBox = countBox; self.healerClassBox = classBox
        elseif rc.countKey == "melee" then self.meleeBox = countBox; self.meleeClassBox = classBox
        else self.rangedBox = countBox; self.rangedClassBox = classBox end
    end

    self:BuildMessageField(frame)
    self:BuildChannelControls(frame)

    MakeLabel(frame, "Vista previa:", PAD, Y.prevLbl)
    self.lengthText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    self.lengthText:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PAD, Y.prevLbl)
    self.lengthText:SetText("0/255")

    -- Vista previa ACOTADA con scroll: hijo al alto del texto.
    local PREV_H = 61
    local prevScroll, prevChild = CreateScrollFrame(frame, INNER - 16, PREV_H, PAD, Y.prev)
    prevScroll:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 12, insets = { left = 2, right = 2, top = 2, bottom = 2 } })
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
    -- +2 px sobre GameFontNormalSmall (~10 → 12)
    do
        local fontPath, fontSize, fontFlags = self.previewBox:GetFont()
        if fontPath and fontSize then self.previewBox:SetFont(fontPath, fontSize + 2, fontFlags) end
    end

    local statusFrame = CreateFrame("Frame")
    statusFrame:SetScript("OnUpdate", function(self)
        if not self.rdShowUntil then statusFrame:Hide() return end
        if GetTime() >= self.rdShowUntil then
            self.rdShowUntil = nil
            SpammerWindow.statusText:SetText("")
            SpammerWindow.statusText:Hide()
            statusFrame:Hide()
        end
    end)
    statusFrame:Hide()
    self.statusFrame = statusFrame
    local function ShowStatus(text, r, g, b)
        local st = SpammerWindow.statusText
        st:SetText(text)
        st:SetTextColor(r or 1, g or 0.82, b or 0)
        st:Show()
        statusFrame.rdShowUntil = GetTime() + 3
        statusFrame:Show()
    end
    self.copyBtn = MakeChipButton(frame, UniqueName("SpCp"), 90, 24)
    self.copyBtn:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", PAD, PAD)
    self.copyBtn:SetText("Copiar")
    local copyEdit
    self.copyBtn:SetScript("OnClick", function()
        if self._commitTexts then self:_commitTexts() end
        -- Copia el mensaje CRUDO (con el enlace dinámico intacto), no el texto
        -- presentable de la preview (que ya no incluye el marcado).
        local msg = self.lastPreviewRaw or (self.previewBox and self.previewBox:GetText() or "")
        if msg == "" then
            Log("|cffff0000[RaidDominion]|r La preview está vacía: no hay nada que copiar.")
            return
        end
        if _G.SetClipboardText then
            _G.SetClipboardText(msg)
            Log("|cff33ff99[RaidDominion]|r Preview copiada al portapapeles.")
            ShowStatus("Copiado al portapapeles", 0.3, 1, 0.3)
            return
        end
        if not copyEdit then
            copyEdit = CreateFrame("EditBox", UniqueName("SpCb"), frame)
            copyEdit:SetAutoFocus(false)
            copyEdit:SetMultiLine(true)
            copyEdit:SetSize(1, 1)
            copyEdit:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
        end
        copyEdit:SetText(msg)
        copyEdit:HighlightText()
        copyEdit:SetFocus()
        ShowStatus("Pulsa Ctrl+C para copiar", 1, 0.82, 0)
    end)
    self.resetBtn = MakeChipButton(frame, UniqueName("SpR"), 100, 24)
    self.resetBtn:SetPoint("LEFT", self.copyBtn, "RIGHT", G, 0)
    self.resetBtn:SetText("Restablecer")
    self.resetBtn:SetScript("OnClick", function()
        if self.ResetToBandDefaults then self:ResetToBandDefaults() end
    end)
    -- Vacía todos los campos del spammer (mensaje en blanco, sin composición).
    self.clearBtn = MakeChipButton(frame, UniqueName("SpClr"), 80, 24)
    self.clearBtn:SetPoint("LEFT", self.resetBtn, "RIGHT", G, 0)
    self.clearBtn:SetText("Vaciar")
    self.clearBtn:SetScript("OnClick", function()
        if self.ClearAll then self:ClearAll() end
    end)

    self.startBtn = MakeChipButton(frame, UniqueName("SpS"), 140, 24)
    self.startBtn:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PAD, PAD)
    self.startBtn:SetText("Iniciar")
    self.startBtn:SetScript("OnClick", function() self:ToggleSpam() end)

    self.statusText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    self.statusText:SetPoint("BOTTOMRIGHT", self.startBtn, "BOTTOMLEFT", -G, 0)
    self.statusText:SetText("")
    self.statusText:SetTextColor(0.3, 1, 0.3)
    self.statusText:Hide()
    self.timeLeftText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    self.timeLeftText:SetPoint("RIGHT", self.startBtn, "LEFT", -G, 0)
    self.timeLeftText:SetText("")
    self.timeLeftText:SetTextColor(GOLD_R, GOLD_G, GOLD_B)
    local timeFrame = CreateFrame("Frame")
    timeFrame:SetScript("OnUpdate", function()
        local win = SpammerWindow
        local spammer = RD.modules and RD.modules.spammer
        if not win.frame or not win.isShown or not spammer then timeFrame:Hide() return end
        if spammer.IsActive and spammer.IsActive() then
            local left = spammer.TimeLeft and spammer.TimeLeft()
            win.timeLeftText:SetText("Próximo envío: " .. math.ceil(left or 0) .. "s")
            win.timeLeftText:Show()
        else
            win.timeLeftText:SetText("")
            win.timeLeftText:Hide()
        end
    end)
    timeFrame:Hide()
    self.timeFrame = timeFrame

    self._commitTexts = function()
        local bands = RD.utils and RD.utils.bands
        if not bands or not self.bandIndex then return end
        local partial = {}
        if self.prefixBox then partial.prefix = self.prefixBox:GetText() end
        if self.nameBox then partial.name = self.nameBox:GetText() end
        if self.suffixBox then partial.suffix = self.suffixBox:GetText() end
        if self.durationBox then partial.duration = tonumber(self.durationBox:GetText()) or 60 end
        if self.tankBox then partial.tank = tonumber(self.tankBox:GetText()) or 0 end
        if self.tankClassBox then partial.tankClass = self.tankClassBox:GetText() end
        if self.healerBox then partial.healer = tonumber(self.healerBox:GetText()) or 0 end
        if self.healerClassBox then partial.healerClass = self.healerClassBox:GetText() end
        if self.meleeBox then partial.melee = tonumber(self.meleeBox:GetText()) or 0 end
        if self.meleeClassBox then partial.meleeClass = self.meleeClassBox:GetText() end
        if self.rangedBox then partial.ranged = tonumber(self.rangedBox:GetText()) or 0 end
        if self.rangedClassBox then partial.rangedClass = self.rangedClassBox:GetText() end
        if self.messageBox then partial.message = self.messageBox:GetText() end
        partial.channels = self:CollectChannels()
        bands:UpdateSpammer(self.bandIndex, partial)
        if self.RebuildPreview then self:RebuildPreview() end
    end

    local boxes = {
        self.prefixBox, self.nameBox, self.suffixBox, self.durationBox,
        self.tankBox, self.tankClassBox, self.healerBox, self.healerClassBox,
        self.meleeBox, self.meleeClassBox, self.rangedBox, self.rangedClassBox,
        self.messageBox,
    }
    for _, box in ipairs(boxes) do
        if box then
            -- Enter/Escape liberan el foco del control (estilo KRT): tras commitear,
            -- se hace ClearFocus para poder usar los atajos del teclado sin que las
            -- teclas sigan entrando en el editbox. El Escape cierra la ventana en un
            -- segundo toque vía UISpecialFrames (ya incluida en RaidDominionSpammer).
            box:SetScript("OnEnterPressed", function()
                self:_commitTexts()
                box:ClearFocus()
            end)
            box:SetScript("OnEscapePressed", function()
                self:_commitTexts()
                box:ClearFocus()
            end)
            box:SetScript("OnTextChanged", function()
                if box == self.messageBox and self.ResizeMessageBox then
                    self:ResizeMessageBox()
                end
                if self.RebuildPreview then self:RebuildPreview() end
            end)
        end
    end

    if RD.UIUtils and RD.UIUtils.EnableTabNavigation then RD.UIUtils.EnableTabNavigation(boxes) end

    if RD.events and RD.events.Subscribe then
        -- Sincronización de banda en vivo, DEBOUNCEADA (editar un campo de banda
        -- dispara un Set por tecla -> CONFIG_CHANGED; antes cada uno ejecutaba
        -- AutoComposition + RefreshFields + RefreshBandDropdown al instante).
        -- La guardia _inBandSync se conserva: los cambios internos (p.ej. dentro
        -- de RefreshFields) pueden re-publicar CONFIG_CHANGED("bands"); mientras
        -- se está sincronizando se descartan, evitando el bucle de re-render.
        local SyncToBands = function()
            if not self.isShown then return end
            if self._inBandSync then return end
            self._inBandSync = true
            local ok, err = pcall(function()
                -- Renombre de banda en vivo: re-sincroniza nombre/cupo/dificultad
                if self.bandIndex and self.AutoComposition then self:AutoComposition(self.bandIndex) end
                self:RefreshFields()
                local bands = RD.utils and RD.utils.bands
                if self.bandIndex and bands and not bands:GetBand(self.bandIndex) then
                    local spammer = RD.modules and RD.modules.spammer
                    if spammer and spammer.Stop then spammer:Stop() end
                    self:Close()
                elseif self.bandIndex and bands and bands:GetBand(self.bandIndex) then
                    -- Renombre de banda: refresca el selector del título
                    self:RefreshBandDropdown()
                end
            end)
            self._inBandSync = false
            if not ok then
                Log("|cffff0000[RaidDominion]|r Error en la sync de banda del spammer: " .. tostring(err))
            end
        end
        local bandSyncDebouncer = RD.UIUtils and RD.UIUtils.NewDebouncer
            and RD.UIUtils.NewDebouncer(0.15, SyncToBands)
        RD.events:Subscribe("CONFIG_CHANGED", function(key)
            if key ~= "bands" or not self.frame or not self.isShown then return end
            if bandSyncDebouncer then
                bandSyncDebouncer:Fire()
            else
                SyncToBands()
            end
        end)
    end

    local pos = RD.config and RD.config.Get and RD.config:Get("ui.spammer.position")
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
function SpammerWindow:AutoComposition(bandIndex)
    -- Implementado en RD_UI_SpammerWindow_Control.lua
    return false
end
RD.ui = RD.ui or {}
RD.ui.spammerWindow = SpammerWindow
return SpammerWindow
