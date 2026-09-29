--[[
    RD_Module_MessageManager.lua
    PROPÓSITO: Envío de mensajes por el canal configurado (chat.channel) con
              troceado automático para mensajes largos (>250 bytes), enviando
              las partes en secuencia (stackeadas), como el addon base.
              Registra RD.messageManager y RD.modules.messageManager.
    API PÚBLICA:
        - RD.messageManager:SendMessage(text, channel)
        - RD.messageManager:SendSequence(parts, delay, channel)
        - RD.messageManager:SendWhisper(text, target)  -- troceado + pacing por target
        - RD.messageManager:GetChannel()
        - RD.messageManager:Schedule(delay, callback)
        - RD.messageManager:SendSystemMessage(text)
        - RD.messageManager:SendRaw(text, channel)     -- paceado por clase de canal
    EVENTOS: Ninguno.
    LÍMITES PROPIOS: salida única con suelo por clase de canal (ver FLOOR) para
              evitar mutes/desconexiones por ráfagas; presupuesto de ráfaga 1
              (primer envío inmediato); SYSTEM local nunca se encola.
]]

local addonName, private = ...
local RD = _G.RaidDominion or {}
_G.RaidDominion = RD

local MessageManager = {}

-- Límite de SendChatMessage en 3.3.5a: 255 caracteres. Usamos 250 caracteres
-- (margen de seguridad). La base troceaba a 255 bytes (partía acentos UTF-8 a
-- la mitad); aquí el troceo es por CARACTERES y no rompe multibyte.
local MAX_CHARS = 250

-- =============================================
-- Cola de tareas programadas (sin C_Timer): frame OnUpdate que procesa por GetTime
-- =============================================

local taskFrame = nil
local tasks = {}

local function EnsureTaskFrame()
    if taskFrame then return taskFrame end
    taskFrame = CreateFrame("Frame")
    taskFrame:SetScript("OnUpdate", function(self, elapsed)
        local now = GetTime()
        -- Escaneo sin asignaciones: si ninguna tarea venció, este frame no crea
        -- ninguna tabla (antes se particionaban due/pending en cada frame, lo que
        -- asignaba 2 tablas por frame durante los envíos en ráfaga).
        local due = nil
        for i, task in ipairs(tasks) do
            if task.time <= now then
                due = {}
                break
            end
        end
        if not due then
            return
        end
        -- Las tareas debidas se marcan a nil (no se modifican con table.remove
        -- mientras otras tareas debidas pueden programar nuevas, y table.remove
        -- al medio es O(n)). Orden de ejecución idéntico al original (por lista).
        for i, task in ipairs(tasks) do
            if task.time <= now then
                due[#due + 1] = task
                tasks[i] = nil
            end
        end
        for _, task in ipairs(due) do
            pcall(task.callback)
        end
        -- Compactar en el mismo array: las nuevas tareas (programadas por las
        -- debidas durante su ejecución) se conservan y se ejecutan en el
        -- siguiente frame, igual que antes.
        local write = 1
        for i = 1, #tasks do
            if tasks[i] then
                tasks[write] = tasks[i]
                write = write + 1
            end
        end
        for i = write, #tasks do
            tasks[i] = nil
        end
        if #tasks == 0 then self:Hide() end
    end)
    return taskFrame
end

local function Schedule(delay, callback)
    table.insert(tasks, { time = GetTime() + (delay or 0), callback = callback })
    EnsureTaskFrame():Show()
end

-- =============================================
-- Limitador de salida (anti-mute / anti-desconexión)
-- =============================================
-- WoW 3.3.5a throttlea el chat y los addon messages: una ráfaga de N mensajes
-- en el mismo frame se descarta o silencia (mute temporal). Una sola cola de
-- salida con un suelo mínimo por CLASE de canal y un presupuesto de ráfaga de 1
-- (el primer envío es inmediato, lo que preserva la respuesta instantánea tipo
-- KRT y mantiene el fast-path de SendMessage síncrono). `SYSTEM` (local) nunca
-- se encola. La cola reutiliza el scheduler de tareas (sin C_Timer).
local FLOOR = {
    WHISPER = 0.5,        -- por DESTINATARIO (clave "whis:<target>")
    PARTY = 0.4, RAID = 0.4, RAID_WARNING = 0.4, BATTLEGROUND = 0.4,
    GUILD = 0.8, SAY = 0.8, YELL = 0.8,
    -- Canales de chat personalizado (índices 1-9) y Posada: el juego permite ~1
    -- mensaje cada 10 s (regla documentada; ver RD_Module_RulesSpammer.lua).
    CHANNEL = 10.0, INN = 10.0,
}
local lastSend = {}      -- clave -> GetTime() del último envío
local sendQueue = {}     -- FIFO: { text, channel, target } (target solo whisper)
local pumpScheduled = false

-- Forward-declarada: SendNow/PumpSend (arriba) la usan, y se asigna abajo en la
-- sección de envío (su cuerpo depende de VALID_CHANNELS/GetChannel).
local SendImmediate
-- Forward-declarada igualmente: SendWhisper (abajo) la usa; se asigna más abajo.
local SplitAt

local function ChannelClass(ch)
    local chNum = tonumber(ch)
    if chNum and chNum >= 1 and chNum <= 9 then return "CHANNEL" end
    if ch == "INN" then return "INN" end
    return ch
end

-- Llama al envío real (whisper directo o a través de SendImmediate).
local function SendNow(text, channel, target)
    if target then
        SendChatMessage(text, "WHISPER", nil, target)
    else
        SendImmediate(text, channel)
    end
end

-- Drena la cola FIFO. Los mensajes cuyo suelo aún no venció se conservan en
-- orden; los de otras clases (o destinatarios) independientes pueden salir sin
-- esperar a la cabeza. Se re-programa mientras quede cola.
local function PumpSend()
    if pumpScheduled then return end
    pumpScheduled = true
    Schedule(0.05, function()
        pumpScheduled = false
        local now = GetTime()
        local write = 1
        for i = 1, #sendQueue do
            local item = sendQueue[i]
            local cls = item.target and "WHISPER" or ChannelClass(item.channel)
            local floor = FLOOR[cls] or 0.8
            local key = item.target and ("whis:" .. item.target) or (cls .. ":" .. tostring(item.channel))
            if now >= (lastSend[key] or -1e9) + floor then
                SendNow(item.text, item.channel, item.target)
                lastSend[key] = now
            else
                sendQueue[write] = item
                write = write + 1
            end
        end
        for i = write, #sendQueue do sendQueue[i] = nil end
        if #sendQueue > 0 then
            PumpSend()
        end
    end)
end

-- =============================================
-- Envío
-- =============================================

-- Resuelve el canal de envío igual que la base (GetDefaultChannel):
-- usa el canal guardado si no es "DEFAULT"; si es "DEFAULT", auto-resuelve
-- según el contexto (campo de batalla / banda / grupo / hermandad / say).
function MessageManager:GetChannel()
    local saved = (RD.config and RD.config.Get and RD.config:Get("chat.channel", "DEFAULT")) or "DEFAULT"
    saved = strtrim(tostring(saved))
    saved = strupper(saved)
    if saved ~= "DEFAULT" and saved ~= "" then
        return saved
    end
    if UnitInBattleground("player") then
        return "BATTLEGROUND"
    elseif GetNumRaidMembers() ~= 0 then
        return (IsRaidLeader() or IsRaidOfficer()) and "RAID_WARNING" or "RAID"
    elseif GetNumPartyMembers() > 0 then
        return "PARTY"
    elseif IsInGuild() then
        return "GUILD"
    end
    return "SAY"
end

-- Canales reconocidos (igual que la base)
local VALID_CHANNELS = {
    DEFAULT = true, SYSTEM = true, GUILD = true, SAY = true, YELL = true,
    PARTY = true, RAID = true, RAID_WARNING = true, BATTLEGROUND = true,
    CHANNEL = true, INN = true,
}

-- Envío inmediato real (sin pacing): INN por número de canal, SYSTEM por
-- mensaje de sistema y el resto por SendChatMessage. Si el canal no es
-- reconocido, se re-resuelve por contexto (nunca cae a sistema salvo que el
-- contexto diga SYSTEM). Es la salida BRUTA: solo la usan SendRaw (paceado) y
-- SendWhisper (paceado por destinatario).
SendImmediate = function(text, channel)
    local ch = channel
    -- Canales numéricos 1-9 (índice de chat personalizado / general)
    local chNum = tonumber(ch)
    if chNum and chNum >= 1 and chNum <= 9 then
        SendChatMessage(text, "CHANNEL", nil, chNum)
        return
    end
    if not VALID_CHANNELS[ch] then
        ch = MessageManager:GetChannel()
    end
    if ch == "INN" then
        -- GetChannelName devuelve (nombre, índice); SendChatMessage con "CHANNEL"
        -- espera el ÍNDICE numérico (select(2)). Si el canal de la Posada no está
        -- activo (id nil) se cae a SAY para no enviar con argumento inválido.
        local id = select(2, GetChannelName("Posada"))
        if id then
            SendChatMessage(text, "CHANNEL", nil, id)
        else
            SendChatMessage(text, "SAY")
        end
    elseif ch == "SYSTEM" then
        SendSystemMessage(text)
    else
        SendChatMessage(text, ch)
    end
end

-- Envío directo con limitador: pasa por la cola de salida si el suelo de su
-- clase de canal no ha vencido. Es método público para que el spammer (y
-- cualquier módulo) envíe a un canal concreto sin duplicar la lógica de
-- canales. `SYSTEM` (local) nunca se encola.
function MessageManager:SendRaw(text, channel)
    local ch = channel
    local chNum = tonumber(ch)
    if not (VALID_CHANNELS[ch] or (chNum and chNum >= 1 and chNum <= 9)) then
        ch = MessageManager:GetChannel()
    end
    local cls = ChannelClass(ch)
    if cls == "SYSTEM" then
        SendImmediate(text, ch)
        return
    end
    local floor = FLOOR[cls] or 0.8
    local key = cls .. ":" .. tostring(ch)
    local now = GetTime()
    if now >= (lastSend[key] or -1e9) + floor then
        SendNow(text, ch, nil)
        lastSend[key] = now
        return
    end
    sendQueue[#sendQueue + 1] = { text = text, channel = ch }
    PumpSend()
end

-- Susurro a un jugador con pacing POR DESTINATARIO (WoW throttlea los whispers
-- seguidos al mismo target). Trocea igual que SendMessage para no exceder 255.
function MessageManager:SendWhisper(text, target)
    if not target or target == "" then return end
    local msg = tostring(text or "")
    if msg == "" then return end
    local part, rest = SplitAt(msg, MAX_CHARS)
    if rest == "" then
        local now = GetTime()
        local key = "whis:" .. target
        if now >= (lastSend[key] or -1e9) + (FLOOR.WHISPER or 0.5) then
            SendChatMessage(part, "WHISPER", nil, target)
            lastSend[key] = now
            return
        end
        sendQueue[#sendQueue + 1] = { text = part, channel = "WHISPER", target = target }
        PumpSend()
        return
    end
    -- Largo: se trocea igual que SendMessage (SplitAt ya no rompe UTF-8).
    local parts = { part }
    msg = rest
    while #msg > 0 do
        part, rest = SplitAt(msg, MAX_CHARS)
        parts[#parts + 1] = part
        msg = rest
    end
    for _, p in ipairs(parts) do
        self:SendWhisper(p, target)
    end
end

-- Alias interno (SendSequence/SendMessage lo usan) — siempre con self correcto
local function SendRaw(text, channel)
    return MessageManager:SendRaw(text, channel)
end

-- Longitud en bytes de un carácter UTF-8 (fuente única: RD.UIUtils.UTF8Len),
-- con fallback idéntico si el módulo se ejecuta aislado en el harness.
local UTF8Len = (RD.UIUtils and RD.UIUtils.UTF8Len)
    or function(byte)
        if byte >= 0xF0 then return 4
        elseif byte >= 0xE0 then return 3
        elseif byte >= 0xC0 then return 2 end
        return 1
    end

-- Corta en un límite de CARACTERES sin partir una palabra ni un carácter
-- UTF-8 multibyte: si hay un espacio dentro de los `limit` primeros caracteres,
-- corta justo después del último espacio (descarta ese espacio de separación);
-- si no hay ningún espacio (una única palabra más larga que el límite), corta
-- en el límite como último recurso. Devuelve (parte, resto). Si todo el texto
-- cabe en el límite de caracteres (aunque sus bytes superen el límite por
-- multibyte), no corta y devuelve el texto completo.
SplitAt = function(text, limit)
    local chars = 0
    local byte = 1
    local lastSpace = 0   -- byte de inicio del último espacio visto (0 = ninguno)
    while byte <= #text do
        if chars == limit then break end
        local b = string.byte(text, byte)
        local len = UTF8Len(b)
        if b == 32 then lastSpace = byte end
        byte = byte + len
        chars = chars + 1
    end
    -- Todo el texto cabe en el límite de caracteres (no parte)
    if byte > #text then return text, "" end
    -- Cortar en el último espacio (>=2 para no devolver una parte vacía)
    if lastSpace > 1 then
        return text:sub(1, lastSpace - 1), text:sub(lastSpace + 1)
    end
    -- Sin espacios en el bloque: partir por el límite (palabra gigante)
    return text:sub(1, byte - 1), text:sub(byte)
end

-- Envía una secuencia de mensajes por un canal (por defecto el configurado),
-- con el retraso indicado entre cada parte.
function MessageManager:SendSequence(parts, delay, channel)
    if not parts or #parts == 0 then return end
    local target = channel or self:GetChannel()
    local i = 1
    local function SendNext()
        if i > #parts then return end
        SendRaw(parts[i], target)
        i = i + 1
        if i <= #parts then
            Schedule(delay or 0.1, SendNext)
        end
    end
    SendNext()
end

-- Envía un mensaje por el canal configurado (o el indicado), troceándolo en
-- partes de MAX_CHARS caracteres si es largo y enviándolas en secuencia con un
-- pequeño retraso (como el addon base, pero sin partir caracteres UTF-8).
function MessageManager:SendMessage(text, channel)
    local msg = tostring(text or "")
    if msg == "" then return end
    local part, rest = SplitAt(msg, MAX_CHARS)
    if rest == "" then
        -- Fast-path (el caso común): el mensaje entero cabe en una sola parte.
        -- Se envía directo y síncrono, sin construir la tabla de partes ni
        -- programar tareas de cola (cero asignaciones extra).
        SendRaw(part, channel or self:GetChannel())
        return
    end
    local parts = { part }
    msg = rest
    while #msg > 0 do
        part, rest = SplitAt(msg, MAX_CHARS)
        parts[#parts + 1] = part
        msg = rest
    end
    self:SendSequence(parts, 0.1, channel)
end

-- Programa una función para ejecutarse tras un retraso (sin C_Timer)
function MessageManager:Schedule(delay, callback)
    Schedule(delay or 0, callback)
end

-- Mensaje de sistema (usado por otros módulos como fallback)
function MessageManager:SendSystemMessage(msg)
    SendSystemMessage(tostring(msg or ""))
end

-- Prefijo canónico que identifica al addon en los mensajes de chat
-- (|cff33ff99[RaidDominion]|r). Fuente única para anuncios a canales, susurros
-- y mensajes del sistema; antes cada módulo repetía el literal con colores
-- distintos (ff0000/00ff00/ff8000/33ff99) y mayúsculas mezcladas.
function MessageManager:Prefix()
    return "|cff33ff99[RaidDominion]|r "
end

-- Cuenta CARACTERES UTF-8 de un string sin romper multibyte. Fuente única del
-- límite de 255: antes cada módulo (spammer, rules spammer, salida puntual)
-- duplicaba CharCount con su propio UTF8Len.
function MessageManager:CountChars(text)
    local s = tostring(text or "")
    local count = 0
    local byte = 1
    while byte <= #s do
        byte = byte + UTF8Len(string.byte(s, byte))
        count = count + 1
    end
    return count
end

-- Suelo de envío (segundos) de un canal: mínimo tiempo entre dos envíos al
-- mismo canal que impone el limitador. `SYSTEM` (local) no se pacea (0). Lo
-- usan los spammers para avisar de que un `duration` menor al suelo quedará
-- espaciado por el suelo del canal (p.ej. la Posada exige ~10 s).
function MessageManager:ChannelFloor(channel)
    local cls = ChannelClass(channel)
    if cls == "SYSTEM" then return 0 end
    return FLOOR[cls] or 0.8
end

RD.messageManager = MessageManager
RD.modules = RD.modules or {}
RD.modules.messageManager = MessageManager

return MessageManager
