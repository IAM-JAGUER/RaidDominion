--[[
    RD_UI_SpammerWindowCore.lua
    PROPÓSITO: Núcleo de datos y canales de la ventana del spammer de banda
              (RD_UI_SpammerWindow.lua), extraído en la ronda 8 de refactor:
              constantes de layout (PAD/G/WIN_W/WIN_H/INNER/Y), catálogos de
              canales (CHANNEL_LABELS/OUTPUT_LABELS), recolección del estado de
              los checks de canal (CollectChannels) y envío puntual por canal
              (SendToChannel). Sin frames: la construcción de la ventana vive en
              el padre, que carga después y reutiliza esta tabla.
    API PÚBLICA:
        - RD.ui.spammerWindow.constants  -- { PAD, G, WIN_W, WIN_H, INNER, CHANNEL_LABELS, OUTPUT_LABELS, Y }
        - RD.ui.spammerWindow:CollectChannels()
        - RD.ui.spammerWindow:SendToChannel(channelKey)
    EVENTOS: Ninguno.
]]

local addonName, private = ...
local RD = _G.RaidDominion or {}
_G.RaidDominion = RD

RD.ui = RD.ui or {}
local SpammerWindow = RD.ui.spammerWindow
if not SpammerWindow then
    SpammerWindow = {
        frame = nil,
        isShown = false,
        bandIndex = nil,
        running = false,
        bandLabel = nil,
        bandDropdown = nil,
        _bandDropdownKey = nil,
    }
    RD.ui.spammerWindow = SpammerWindow
end

local Log = (RD.UIUtils and RD.UIUtils.Log) or function(msg) print(msg) end

-- Grid de layout (GUTTER 8, padding 12; offsets enteros §6 AGENTS)
local PAD = 12
local G = 8
local WIN_W = 600
local WIN_H = 492
local INNER = WIN_W - PAD * 2 -- 576

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

-- Canales de salida puntual
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

-- Filas Y (desde el borde superior): nombre → composición → mensaje → pestañas → preview.
local Y = {
    title = -10,
    nameLbl = -36,
    nameBox = -52,
    compLbl = -84,
    role1 = -104,
    role2 = -132,
    msgLbl = -160,
    msg = -178,
    tabs = -221,
    tabContent = -251,
    prevLbl = -369,
    prev = -387,
}

-- Constantes expuestas al padre (RD_UI_SpammerWindow.lua), que las alía como
-- upvalues locales al cargar (mismo patrón que RD_Module_LootCore.state).
SpammerWindow.constants = {
    PAD = PAD,
    G = G,
    WIN_W = WIN_W,
    WIN_H = WIN_H,
    INNER = INNER,
    CHANNEL_LABELS = CHANNEL_LABELS,
    OUTPUT_LABELS = OUTPUT_LABELS,
    Y = Y,
}

-- Recolecta el estado de los checks de canal del bucle (tabla { [clave] = bool }).
-- Los checks se crean en BuildChannelControls (padre) y se guardan en
-- self.channelChecks en el mismo orden que CHANNEL_LABELS.
function SpammerWindow:CollectChannels()
    local out = {}
    for i, c in ipairs(CHANNEL_LABELS) do
        local check = self.channelChecks and self.channelChecks[i]
        local checked = check and check:GetChecked()
        out[c.key] = (checked == true or checked == 1)
    end
    return out
end

-- Envío puntual del mensaje actual a un canal (botones de la pestaña "Salida").
-- Commitea primero los campos en vivo (_commitTexts, definido en Create) para
-- que el mensaje refleje el estado actual del formulario. Valida el límite de
-- 255 como SendNow (antes usaba SendRaw directo y un mensaje largo se truncaba
-- o fallaba en silencio).
function SpammerWindow:SendToChannel(channelKey)
    if not channelKey or not self.bandIndex then return end
    if self._commitTexts then self:_commitTexts() end
    local spammer = RD.modules and RD.modules.spammer
    local msg = (spammer and spammer.BuildMessage and spammer:BuildMessage(self.bandIndex)) or ""
    if msg == "" then
        Log("|cffff0000[RaidDominion]|r El mensaje está vacío.")
        return
    end
    local maxLen = 255
    local mm = RD.modules and RD.modules.messageManager
    local len = (mm and mm.CountChars and mm:CountChars(msg))
        or (spammer and spammer.CharCount and spammer:CharCount(msg)) or #msg
    if len > maxLen then
        Log(string.format("|cffff8000[RaidDominion]|r El mensaje supera los %d caracteres: reduce la composición o los placeholders.", maxLen))
        return
    end
    if mm and mm.SendRaw then
        pcall(function() mm:SendRaw(msg, channelKey) end)
    end
end

RD.ui.spammerWindow = SpammerWindow
return SpammerWindow