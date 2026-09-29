--[[
    RD_Module_RulesSpammer.lua
    PROPÓSITO: Motor de spam de UNA regla de banda (selección única). Reenvía la
              regla en DOS renglones (= Título = y contenido por separado,
              con el splitter por palabras) cada `duration` segundos por los
              canales marcados (incl. índices 1-9). Los canales de línea única
              admiten solo un mensaje cada ~10 s y exigen ≤255 caracteres, por
              lo que reciben un ÚNICO renglón con título+contenido unidos: la
              Posada (INN) y los índices de chat numéricos 1-9. Sin C_Timer.
    API PÚBLICA:
        - RD.modules.rulesSpammer:GetRules() / GetSelectedItem()
        - RD.modules.rulesSpammer:GetSettings() / UpdateSettings(partial)
        - RD.modules.rulesSpammer:BuildPreview(item) / BuildLine(item) / GetLength(item)
        - RD.modules.rulesSpammer:CanStart() / IsActive() / TimeLeft()
        - RD.modules.rulesSpammer:Start() / Stop() / Toggle()
        - RD.modules.rulesSpammer:SendItem(item) / SendItemToChannel(item, ch) / SendNext()
    EVENTOS: Ninguno directo.
]]

local addonName, private = ...
local RD = _G.RaidDominion or {}
_G.RaidDominion = RD

local RulesSpammer = {}

local MAX_LEN = 255
local active = false
local nextSendAt = 0
local loopFrame

local Log = (RD.UIUtils and RD.UIUtils.Log) or function(msg) print(msg) end

-- Canales de línea única: admiten solo UN mensaje cada ~10 s (antiflood de la
-- Posada y de los índices de chat 1-9). El mensaje debe caber entero en 255
-- caracteres y enviarse en un único SendChatMessage (sin trocear).
local function IsSingleLineChannel(ch)
    local num = tonumber(ch)
    return ch == "INN" or (num ~= nil and num >= 1 and num <= 9)
end

-- Estilo del wrapper del título de la regla según la config de anuncios
-- (announce.rules.wrapper, editable en la pestaña de configuración de Reglas):
-- "equals" (= Título =, por defecto), "brackets" ([Título]) o "none" (título
-- plano). El default "equals" garantiza que el spammer de regla siempre
-- muestre un título distinguible salvo que el usuario elija "Ninguno".
local function GetTitleWrapper()
    local w = (RD.config and RD.config.Get and RD.config:Get("announce.rules.wrapper", nil)) or "equals"
    if w ~= "brackets" and w ~= "none" then w = "equals" end
    return w
end

-- Aplica el estilo del título configurado. Delega en RD.constants.WrapTitle
-- (única fuente del wrapper del título en el addon); fallback local por
-- robustez en tests/orden de carga.
local function WrapTitle(title)
    local w = GetTitleWrapper()
    if RD.constants and RD.constants.WrapTitle then
        return RD.constants.WrapTitle(title, w)
    end
    if w == "brackets" then return "[" .. title .. "]" end
    if w == "none" then return title end
    return "= " .. title .. " ="
end

-- true si el mensaje puede enviarse a algún canal marcado: cualquier canal
-- admite mensajes largos (SendMessage trocea por palabras con un retraso),
-- salvo los de línea única (INN y 1-9), que limitan a UN mensaje cada ~10 s y
-- por tanto exigen que la línea única quepa en 255 caracteres.
local function CanSend(channels, len)
    local any = false
    local onlySingleLine = true
    for ch, checked in pairs(channels or {}) do
        if checked then
            any = true
            if not IsSingleLineChannel(ch) then onlySingleLine = false end
        end
    end
    if not any then return false end
    if onlySingleLine and len > MAX_LEN then return false end
    return true
end

local function Defaults()
    return (RD.constants and RD.constants.RULES_SPAMMER_DEFAULTS) or {
        duration = 45,
        channels = { RAID = true },
        selectedTitle = "",
    }
end

local function CharCount(text)
    local mm = RD.modules and RD.modules.messageManager
    if mm and mm.CountChars then return mm:CountChars(text) end
    local count = 0
    local byte = 1
    text = text or ""
    while byte <= #text do
        local b = string.byte(text, byte)
        local len = 1
        if b >= 0xF0 then len = 4
        elseif b >= 0xE0 then len = 3
        elseif b >= 0xC0 then len = 2
        end
        byte = byte + len
        count = count + 1
    end
    return count
end

function RulesSpammer:GetRules()
    local list = (RD.config and RD.config.Get and RD.config:Get("rules", {})) or {}
    if type(list) ~= "table" then return {} end
    return list
end

function RulesSpammer:GetSettings()
    local d = Defaults()
    local out = {
        duration = d.duration,
        channels = {},
        selectedTitle = d.selectedTitle or "",
    }
    for k, v in pairs(d.channels or {}) do out.channels[k] = v end
    if RD.config and RD.config.Get then
        local duration = RD.config:Get("ui.rulesSpammer.duration", d.duration)
        out.duration = tonumber(duration) or d.duration
        local channels = RD.config:Get("ui.rulesSpammer.channels", nil)
        if type(channels) == "table" then
            out.channels = {}
            for k, v in pairs(channels) do out.channels[k] = (v == true or v == 1) end
        end
        local title = RD.config:Get("ui.rulesSpammer.selectedTitle", nil)
        if type(title) == "string" then
            out.selectedTitle = title
        elseif title == nil then
            local legacy = RD.config:Get("ui.rulesSpammer.selected", nil)
            if type(legacy) == "table" then
                for k, v in pairs(legacy) do
                    if v == true or v == 1 then
                        out.selectedTitle = tostring(k)
                        break
                    end
                end
            end
        end
    end
    if out.duration < 1 then out.duration = 1 end
    return out
end

function RulesSpammer:UpdateSettings(partial)
    if type(partial) ~= "table" or not RD.config or not RD.config.Set then return false end
    if partial.duration ~= nil then
        RD.config:Set("ui.rulesSpammer.duration", tonumber(partial.duration) or 45)
    end
    if type(partial.channels) == "table" then
        local cur = self:GetSettings().channels
        for ck, cv in pairs(partial.channels) do cur[ck] = cv end
        RD.config:Set("ui.rulesSpammer.channels", cur)
    end
    if partial.selectedTitle ~= nil then
        RD.config:Set("ui.rulesSpammer.selectedTitle", tostring(partial.selectedTitle or ""))
    end
    return true
end

function RulesSpammer:GetSelectedItem()
    local title = self:GetSettings().selectedTitle or ""
    if title == "" then return nil end
    for _, item in ipairs(self:GetRules()) do
        if tostring(item.title or item.name or "") == title then
            local content = tostring(item.content or "")
            if content == "" then content = title end
            return { title = title, content = content, icon = item.icon }
        end
    end
    return nil
end

function RulesSpammer:GetQueue()
    local item = self:GetSelectedItem()
    if not item then return {} end
    return { item }
end

-- Vista previa en DOS renglones: título (con el estilo configurado) y contenido
-- aparte.
function RulesSpammer:BuildPreview(item)
    if not item then return "" end
    local title = tostring(item.title or "")
    local content = tostring(item.content or "")
    local lines = {}
    if title ~= "" then lines[#lines + 1] = WrapTitle(title) end
    if content ~= "" and content ~= title then lines[#lines + 1] = content end
    return table.concat(lines, "\n")
end

-- Mensaje de UNA línea con título y contenido unidos (para los canales de línea
-- única —la Posada, INN, y los índices 1-9—, que permiten solo un mensaje cada
-- ~10 s y por tanto no admiten dos renglones).
function RulesSpammer:BuildLine(item)
    if not item then return "" end
    local title = tostring(item.title or "")
    local content = tostring(item.content or "")
    if content == "" then content = title end
    local parts = {}
    if title ~= "" then parts[#parts + 1] = WrapTitle(title) end
    if content ~= "" and content ~= title then parts[#parts + 1] = content end
    return table.concat(parts, " ")
end

function RulesSpammer:GetLength(item)
    item = item or self:GetSelectedItem()
    if not item then return 0 end
    -- Longitud del mensaje de una línea (el que exigen los canales de línea
    -- única —Posada e índices 1-9—: ≤255).
    return CharCount(self:BuildLine(item))
end

function RulesSpammer:CharCount(text)
    return CharCount(text or "")
end

function RulesSpammer:IsActive()
    return active == true
end

function RulesSpammer:TimeLeft()
    if not active then return 0 end
    local left = nextSendAt - GetTime()
    if left < 0 then left = 0 end
    return left
end

function RulesSpammer:Cursor()
    return 1
end

-- Envía una regla a UN canal: DOS renglones (título y contenido por separado,
-- cada uno con el splitter por palabras) salvo en los canales de línea única
-- (la Posada, INN, y los índices 1-9) que admiten un único mensaje cada ~10 s:
-- allí se envía un solo renglón (BuildLine) con un único SendChatMessage
-- (SendRaw, sin trocear) siempre que quepa en 255 caracteres. Devuelve true si
-- el canal de línea única se omitió por longitud (no se pudo enviar nada ahí).
function RulesSpammer:SendItemToChannel(item, ch)
    local mm = RD.modules and RD.modules.messageManager
    if not mm or not mm.SendRaw then return false end
    if IsSingleLineChannel(ch) then
        local line = self:BuildLine(item)
        if line == "" then return false end
        if CharCount(line) > MAX_LEN then return true end
        pcall(function() mm:SendRaw(line, ch) end)
        return false
    end
    if not mm.SendMessage then return false end
    local title = tostring(item.title or "")
    local content = tostring(item.content or "")
    if content == "" then content = title end
    if title ~= "" then pcall(function() mm:SendMessage(WrapTitle(title), ch) end) end
    if content ~= "" and content ~= title then pcall(function() mm:SendMessage(content, ch) end) end
    return false
end

function RulesSpammer:SendItem(item)
    if not item then return end
    local settings = self:GetSettings()
    local channels = settings.channels or {}
    local hasChannel = false
    local innSkipped = false
    for ch, checked in pairs(channels) do
        if checked then
            hasChannel = true
            if self:SendItemToChannel(item, ch) then innSkipped = true end
        end
    end
    if not hasChannel then
        self:SendItemToChannel(item, nil)
    end
    if innSkipped then
        Log("|cffff8000[RaidDominion]|r La regla supera 255 caracteres: no se envió a los canales de línea única (Posada e índices 1-9; permiten un mensaje cada 10 s).")
    end
end

function RulesSpammer:SendNext()
    local item = self:GetSelectedItem()
    if not item then
        self:Stop()
        return
    end
    self:SendItem(item)
    local win = RD.ui and RD.ui.rulesSpammerWindow
    if win and win.OnTick then win:OnTick(1, { item }) end
end

-- true si la regla seleccionada puede enviarse: mensaje no vacío y al menos un
-- canal marcado que lo admita (los canales de línea única —Posada e índices
-- 1-9— exigen que la línea quepa en 255 caracteres).
function RulesSpammer:CanStart()
    local item = self:GetSelectedItem()
    if not item then return false end
    if self:BuildPreview(item) == "" then return false end
    return CanSend(self:GetSettings().channels, CharCount(self:BuildLine(item)))
end

function RulesSpammer:Start()
    if not self:CanStart() then return false end
    local settings = self:GetSettings()

    active = true
    self:SendNext()
    if not active then return false end
    local duration = tonumber(settings.duration) or 45
    if duration < 1 then duration = 1 end
    -- Aviso único si algún canal marcado tiene un suelo mayor que `duration`
    -- (Posada e índices 1-9 admiten ~1 envío cada 10 s): el limitador global
    -- espaciará el bucle a ese ritmo.
    local mm = RD.modules and RD.modules.messageManager
    local warnOnce = false
    for ch, checked in pairs(settings.channels or {}) do
        if checked and mm and mm.ChannelFloor and mm:ChannelFloor(ch) > duration then
            warnOnce = true
            break
        end
    end
    if warnOnce and mm and mm.SendSystemMessage then
        mm:SendSystemMessage(string.format(
            "|cffff8000[RaidDominion]|r Los canales de línea única (Posada e índices 1-9) admiten un envío cada %d s; el bucle se espaciará a ese ritmo.",
            math.floor(mm:ChannelFloor("INN") or 10)))
    end
    nextSendAt = GetTime() + duration
    if loopFrame then loopFrame:Show() end
    local win = RD.ui and RD.ui.rulesSpammerWindow
    if win and win.SetRunning then win:SetRunning(true) end
    if RD.events and RD.events.Publish then
        RD.events:Publish("SPAM_STATE_CHANGED", "rules")
    end
    return true
end

function RulesSpammer:Stop()
    if not active then return end
    active = false
    if loopFrame then loopFrame:Hide() end
    local win = RD.ui and RD.ui.rulesSpammerWindow
    if win and win.SetRunning then win:SetRunning(false) end
    if RD.events and RD.events.Publish then
        RD.events:Publish("SPAM_STATE_CHANGED", nil)
    end
end

function RulesSpammer:Toggle()
    if active then
        self:Stop()
        return false
    end
    return self:Start()
end

loopFrame = CreateFrame("Frame", "RDRulesSpammerLoop", UIParent)
loopFrame:Hide()
loopFrame:SetScript("OnUpdate", function(self)
    if not active then self:Hide() return end
    local now = GetTime()
    if now >= nextSendAt then
        if not UnitIsDeadOrGhost("player") then
            RulesSpammer:SendNext()
        end
        local settings = RulesSpammer:GetSettings()
        local duration = tonumber(settings.duration) or 45
        if duration < 1 then duration = 1 end
        nextSendAt = now + duration
    end
end)

RD.modules = RD.modules or {}
RD.modules.rulesSpammer = RulesSpammer
return RulesSpammer
