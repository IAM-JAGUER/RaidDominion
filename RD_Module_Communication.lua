--[[
    RD_Module_Communication.lua
    PROPÓSITO: Comunicación addon-a-addon (SendAddonMessage) para emular del
              addon base la obtención de datos del líder de la banda:
              asignaciones (roles/abilities/buffs/auras) y listas configurables
              (rules / mechanics / bands).
    API PÚBLICA:
        - RD.comm:RequestAssignments()
        - RD.comm:RequestList(listKey)
        - RD.comm:BroadcastAssignments(channel, onlyKeys, target)
        - RD.comm:BroadcastList(listKey, channel, target)
    DEPENDENCIA: la serialización del protocolo (codec) vive en
                 RD_Module_Communication_Codec.lua (RD.commCodec), que debe
                 cargarse antes que este archivo (orden en RaidDominion.toc).
    EVENTOS: CHAT_MSG_ADDON ("RD_COMM").
    PROTOCOLO:
        REQ_ASSIGN                    -> el líder responde las categorías permitidas
        REQ_LIST:<key>                ->   según la privacidad de cada lista
                                          (`privacy.<lista>`):
                                            open    -> respuesta automática
                                            ask     -> diálogo al líder mostrando
                                                       quién pide; acepta/rechaza
                                            private -> silencio (solo feedback)
        FEED_OK:<key>     (whisper)   -> el líder aprobó la solicitud (datos en camino)
        FEED_REJ:<key>    (whisper)   -> el líder rechazó la solicitud
        FEED_PRIV:<key>   (whisper)   -> la lista es privada: no se comparte
        DATA_START / DATA_CHUNK:<cat>:<idx>:<total>:<contenido> / DATA_END
    AUTORIDAD Y TOPES (endurecimiento):
        - Las peticiones (REQ_*) y la retroalimentación (FEED_*, por whisper)
          SOLO se aceptan de jugadores que están en el grupo (banda/party):
          un externo no puede spamear al líder por whisper.
        - Los datos (DATA_*) SOLO se aceptan del LÍDER del grupo: son los únicos
          que se escriben en las SavedVariables, y un miembro (o externo) no
          puede inyectarlos.
        - Anti-DoS: los datos requieren DATA_START previo (máquina de estados),
          el índice y el `total` declarados no pueden superar
          MAX_CHUNKS_PER_CATEGORY y el número total de trozos acumulados está
          limitado. Sin esto, un DATA_CHUNK con índice gigante + DATA_END
          forzaba un bucle de concatenación en ProcessIncoming (abuso de CPU).
    RETROALIMENTACIÓN:
        - El líder SIEMPRE ve quién solicita qué (notificación local), con
          independencia de la privacidad: "X solicitó la lista «Y»".
        - El solicitante SIEMPRE recibe un whisper de resultado: aprobado /
          rechazado / privada.
]]

local addonName, private = ...
local RD = _G.RaidDominion or {}
_G.RaidDominion = RD

local Comm = {}

-- Codec de serialización del protocolo (RD_Module_Communication_Codec.lua).
-- Debe cargarse antes que este módulo: orden garantizado por RaidDominion.toc.
local Codec = assert(RD.commCodec, "RD_Module_Communication_Codec.lua debe cargarse antes que RD_Module_Communication.lua")

local PREFIX = "RD_COMM"
local CHUNK_SIZE = 180          -- bytes por trozo (margen sobre el límite del canal)
local MAX_CHUNKS_PER_CATEGORY = 256  -- tope anti-DoS por índice dentro de una categoría
local MAX_TOTAL_CHUNKS = 1024        -- tope anti-DoS del total declarado y de la acumulación
local ASSIGNABLE_LISTS = { "roles", "abilities", "buffs", "auras" }
local VALID_LIST_KEYS = {
    roles = true, abilities = true, buffs = true, auras = true,
    mechanics = true, rules = true, bands = true,
}
local PRIVACY_MODES = { open = true, ask = true, private = true }

local incoming = {}             -- categoria -> { [idx] = trozo }
local dataOpen = false          -- true solo entre DATA_START y DATA_END
local dataOpenLeader = nil      -- token del líder que abrió la sesión (un líder
                                -- distinto no puede escribir ni cerrar la suya)
local dataChunkCount = 0        -- trozos almacenados en la ventana abierta
local dataOpenTime = 0          -- GetTime() de apertura (para expirar sesiones atascadas)
local DATA_SESSION_TIMEOUT = 15 -- segundos sin cierre: se expira y se puede reintentar

-- Diagnóstico opcional (ui.commDebug): imprime lo que se recibe y por qué se
-- rechaza, para depurar en el cliente real la entrega de los DATA_*.
local function CommDebug(...)
    local enabled = RD.config and RD.config.Get and RD.config:Get("ui.commDebug", false)
    if enabled then
        print("[RD-COMM]", ...)
    end
end

local function IsLeader()
    return IsRaidLeader() or (GetNumRaidMembers() == 0 and IsPartyLeader())
end

-- ¿El remitente está en el grupo (banda o party)? Devuelve (token, esLíder) o
-- nil si no está. Resuelve el nombre del remitente ("Nombre-Reino") contra el
-- roster REAL del grupo (GetRaidRosterInfo / UnitName) en lugar de suponer: así
-- un externo que ora por whisper (CHAT_MSG_ADDON con canal WHISPER) no entra.
-- CleanName ya retira el "Reino" y normaliza mayúsculas/espacios.
local function GroupSlot(sender)
    if not sender or sender == "" then return nil end
    local base = Codec:CleanName(sender)
    local raidCount = GetNumRaidMembers()
    if raidCount > 0 then
        for i = 1, raidCount do
            local name, rank = GetRaidRosterInfo(i)
            if name and Codec:CleanName(name) == base then
                -- RANK en 3.3.5a: 2 = líder, 1 = asistente, 0 = miembro.
                -- (OJO: NO es 0=leader; ese error invertido rechazaba SIEMPRE los
                -- DATA_* del líder real, por eso "Obtener" nunca recibía datos.)
                return "raid" .. i, (tonumber(rank) == 2)
            end
        end
    end
    local partyCount = GetNumPartyMembers()
    if partyCount > 0 then
        -- En 3.3.5a NO existe UnitIsGroupLeader (llegó en Cataclysm). El líder
        -- de party SIEMPRE está en el slot 1 ("party1"): el juego reordena la
        -- party para que el líder sea el primero.
        local name = UnitName("party1")
        if name and Codec:CleanName(name) == base then
            return "party1", true
        end
        for i = 1, partyCount do
            local name2 = UnitName("party" .. i)
            if name2 and Codec:CleanName(name2) == base then
                return "party" .. i, false
            end
        end
    end
    return nil
end

local function IsSenderInGroup(sender)
    return GroupSlot(sender) ~= nil
end

-- Solo el LÍDER del grupo puede entregar datos: los DATA_* se escriben en las
-- SavedVariables, así que un miembro (o un externo por whisper) no debe poder
-- inyectarlos. El propio jugador nunca llega aquí (filtrado en OnEvent).
local function IsSenderLeader(sender)
    local token, isLeader = GroupSlot(sender)
    if token == nil or not isLeader then return false end
    return true
end

local function DefaultChannel()
    return (GetNumRaidMembers() > 0) and "RAID" or "PARTY"
end

-- Modo de privacidad de una lista ante "Obtener": privado / preguntar primero /
-- compartir sin restricción. Default "open" para conservar el comportamiento de
-- v2 (compartir automáticamente) y que el líder decida restringir si lo desea.
local function GetPrivacy(key)
    local mode = RD.config and RD.config.Get and RD.config:Get("privacy." .. key, "open")
    if not PRIVACY_MODES[mode] then return "open" end
    return mode
end

local function SafeSend(msg, channel)
    local ch = channel or DefaultChannel()
    CommDebug("send:", (msg:sub(1, 24)), "a", tostring(ch))
    SendAddonMessage(PREFIX, msg, ch)
end

-- Whisper dirigido al solicitante (únicos en recibirlo; el resto de la banda no
-- ve la retroalimentación).
local function SafeWhisper(msg, target)
    if not target or target == "" then return end
    CommDebug("whisper:", (msg:sub(1, 24)), "a", tostring(target))
    SendAddonMessage(PREFIX, msg, "WHISPER", target)
end

-- Notifica al LÍDER (chat local, nunca al canal) de cada petición entrante:
-- siempre sabe quién pidió qué, sea cual sea la privacidad.
local function NotifyLeader(text)
    local msg = "|cFF33CCFF[RaidDominion]|r " .. text
    if RD.messageManager and RD.messageManager.SendSystemMessage then
        RD.messageManager:SendSystemMessage(msg)
    else
        print(msg)
    end
end

-- Muestra al SOLICITANTE el resultado de su petición (feedback local dirigido).
local function Feedback(text)
    local msg = "|cFF88C0FF[RaidDominion]|r " .. text
    if RD.messageManager and RD.messageManager.SendSystemMessage then
        RD.messageManager:SendSystemMessage(msg)
    else
        print(msg)
    end
end

-- Aplana los trozos de varias categorías en la lista de mensajes del protocolo
-- (DATA_START + DATA_CHUNK* + DATA_END).
local function BuildChunkMessages(chunks)
    local msgs = { "DATA_START" }
    for _, ch in ipairs(chunks) do
        local total = math.ceil(#ch.content / CHUNK_SIZE)
        for i = 1, total do
            local sub = ch.content:sub((i - 1) * CHUNK_SIZE + 1, i * CHUNK_SIZE)
            msgs[#msgs + 1] = string.format("DATA_CHUNK:%s:%d:%d:%s", ch.category, i, total, sub)
        end
    end
    msgs[#msgs + 1] = "DATA_END"
    return msgs
end

-- Serializador del protocolo: los trozos se envían con un pequeño retraso entre
-- sí (CHUNK_DELAY) para que el canal de banda/grupo no descarte el exceso de
-- paquetes en una ráfaga (causa típica de transferencias grandes INTERMITENTES
-- y de huecos). Una sola cola FIFO impide que dos envíos se intercalen.
-- TRANSPORTE: los datos se envían por WHISPER al solicitante (job.target),
-- no por el canal de grupo. Es el transporte que el FEED_* ya usa y que
-- DEMOSTRADAMENTE llega en el cliente real (varios clientes/servidores 3.3.5a
-- no entregan los addon messages de banda/grupo, pero sí los whispers).
local CHUNK_DELAY = 0.25
local commQueue = {}            -- { msgs, channel, target }
local commBusy = false

local function PumpComm()
    if commBusy or #commQueue == 0 then return end
    local job = table.remove(commQueue, 1)
    commBusy = true
    local i = 0
    local mm = RD.modules and RD.modules.messageManager
    local function Next()
        i = i + 1
        if i > #job.msgs then
            commBusy = false
            PumpComm()
            return
        end
        if job.target then
            SendAddonMessage(PREFIX, job.msgs[i], "WHISPER", job.target)
            CommDebug("send(whisper):", job.msgs[i]:sub(1, 24), "a", tostring(job.target))
        else
            SafeSend(job.msgs[i], job.channel)
            CommDebug("send:", job.msgs[i]:sub(1, 24), "a", tostring(job.channel))
        end
        if mm and mm.Schedule then
            mm:Schedule(CHUNK_DELAY, Next)
        else
            Next()   -- sin cola (harness): síncrono, para que los tests no esperen
        end
    end
    Next()
end

-- Envía DATA_START + trozos + DATA_END para una o varias categorías. Encola en
-- el serializador (pacing entre trozos) y devuelve de inmediato. `target`
-- (opcional) envía la secuencia por whisper a ese jugador en vez del canal.
function Comm:SendChunks(chunks, channel, target)
    commQueue[#commQueue + 1] = {
        msgs = BuildChunkMessages(chunks),
        channel = channel or DefaultChannel(),
        target = target,
    }
    PumpComm()
end

-- El líder envía las asignaciones de roles/abilities/buffs/auras permitidas.
-- `onlyKeys` (opcional) limita las categorías a las indicadas (filtro de
-- privacidad): las listas en modo "privado" nunca se comparten. Devuelve true
-- si se enviaron trozos; false si no había nada que compartir (asignaciones
-- vacías) para que el caller pueda mandar FEED_EMPTY en vez de FEED_OK.
function Comm:BroadcastAssignments(channel, onlyKeys, target)
    local chunks = {}
    for _, key in ipairs(ASSIGNABLE_LISTS) do
        if not (onlyKeys and not onlyKeys[key]) then
            local assign = RD.config:Get("assignments." .. key, {})
            if type(assign) == "table" and next(assign) then
                chunks[#chunks + 1] = { category = "assign." .. key, content = Codec:EncodeAssignments(assign) }
            end
        end
    end
    if #chunks == 0 then return false end
    self:SendChunks(chunks, channel, target)
    return true
end

-- El líder envía una lista configurable (rules / mechanics / bands). Devuelve
-- true si se enviaron trozos; false si la lista está vacía (o no existe) para
-- que el caller pueda mandar FEED_EMPTY en vez de un FEED_OK que promete datos
-- que nunca llegan (causa raíz del bug "Obtener no funciona" con listas vacías).
-- `target` (opcional) envía la respuesta por WHISPER a ese jugador (transporte
-- fiable en el cliente real); sin él, por el canal de grupo.
function Comm:BroadcastList(listKey, channel, target)
    if not listKey then return false end
    local list = RD.config:Get(listKey, {})
    if type(list) ~= "table" or #list == 0 then return false end
    local items = {}
    if listKey == "bands" then
        for _, b in ipairs(list) do
            items[#items + 1] = Codec:EncodeBand(b)
        end
    else
        for _, it in ipairs(list) do
            items[#items + 1] = Codec:EncodeItem(it)
        end
    end
    self:SendChunks({ { category = listKey, content = table.concat(items, "\2") } }, channel, target)
    return true
end

-- ============ Solicitudes (seguidor) ============

local function InGroup()
    return GetNumRaidMembers() > 0 or GetNumPartyMembers() > 0
end

-- Devuelve el nombre del líder del grupo: en banda el miembro con rank 2
-- (0=miembro, 1=asistente, 2=líder), en grupo el party leader (siempre el slot
-- "party1" en 3.3.5a; UnitIsGroupLeader no existe aquí). nil si no se puede
-- determinar. Permite dirigir las peticiones por whisper (transporte fiable)
-- en vez de depender de los addon messages de banda/grupo.
local function GroupLeaderName()
    local raidCount = GetNumRaidMembers()
    if raidCount > 0 then
        for i = 1, raidCount do
            local name, rank = GetRaidRosterInfo(i)
            if name and tonumber(rank) == 2 then return name end
        end
    end
    local partyCount = GetNumPartyMembers()
    if partyCount > 0 then
        return UnitName("party1")
    end
    return nil
end

-- Solicita al líder las asignaciones (roles/abilities/buffs/auras). La petición
-- va por WHISPER directo al líder (si se le detecta por rango/slot); si no, por
-- el canal de grupo. Devuelve true si se envió.
function Comm:RequestAssignments()
    if not InGroup() then return false end
    if IsLeader() then return false end   -- el líder ya tiene sus datos
    local ok, name = pcall(GroupLeaderName)
    if ok and name and name ~= "" then
        SafeWhisper("REQ_ASSIGN", name)
    else
        SafeSend("REQ_ASSIGN")
    end
    return true
end

-- Solicita al líder una lista configurable (rules / mechanics / bands / listas
-- asignables). Solo se piden claves conocidas (el líder ignora el resto).
-- Devuelve (true) si se envió la petición, o (false, motivo) si no se puede:
-- "nofollow" (sin grupo), "leader" (eres el líder) o "invalid" (clave).
function Comm:RequestList(listKey)
    local why = self:CanRequestList(listKey)
    if why then return false, why end
    local ok, name = pcall(GroupLeaderName)
    if ok and name and name ~= "" then
        SafeWhisper("REQ_LIST:" .. listKey, name)
    else
        SafeSend("REQ_LIST:" .. listKey)
    end
    return true
end

-- Prechequeo ANTES de abrir el diálogo de confirmación del botón "Obtener":
-- si no se puede pedir esta lista, devuelve el motivo (string) y la UI avisa
-- sin molestar con un diálogo imposible. Devuelve nil si se puede pedir.
function Comm:CanRequestList(listKey)
    if not listKey or not VALID_LIST_KEYS[listKey] then return "invalid" end
    if not InGroup() then return "nofollow" end
    if IsLeader() then return "leader" end
    return nil
end

-- ============ Solicitudes con privacidad (lado líder) ============

-- Petición en curso pendiente de aprobación manual ("preguntar primero"). Solo la
-- petición MÁS RECIENTE se puede aceptar: si llega otra, la anterior queda
-- invalidada (el diálogo abierto mostró la última y es la única que responde).
local pendingRequest = nil

-- Muestra el diálogo al líder indicando QUIÉN pide y QUÉ; aceptar dispara
-- `onAccept` (compartir), rechazar no envía nada. Sin UI (harness) la petición
-- queda guardada en pendingRequest sin disparar nada.
local function PromptRequest(text, onAccept, onCancel)
    local current = { text = text, onAccept = onAccept, onCancel = onCancel }
    pendingRequest = current
    local dialogs = RD.ui and RD.ui.dialogs
    if dialogs and dialogs.ShowConfirmDialog then
        dialogs:ShowConfirmDialog({
            text = text,
            acceptText = "Compartir",
            cancelText = "Rechazar",
            onAccept = function()
                if pendingRequest ~= current then return end
                pendingRequest = nil
                if onAccept then onAccept() end
            end,
            onCancel = function()
                if pendingRequest ~= current then return end
                pendingRequest = nil
                if onCancel then onCancel() end
            end,
        })
    end
    return current
end

-- Petición de UNA lista (botón "Obtener" del seguidor). El líder responde según
-- la privacidad configurada para esa lista, pero SIEMPRE ve quién pidió qué y
-- el solicitante recibe feedback del resultado (aprobado / rechazado / privada).
function Comm:HandleListRequest(key, requester, channel)
    if not IsLeader() then return end
    local who = tostring(requester or "?")
    local what = Codec:FeedbackLabel(key)
    local mode = GetPrivacy(key)
    if mode == "private" then
        NotifyLeader(string.format("|cFFFFFFFF%s|r solicitó %s — lista PRIVADA: no se comparte.", who, what))
        SafeWhisper("FEED_PRIV:" .. key, requester)
    elseif mode == "ask" then
        PromptRequest(string.format("«%s» solicita %s de RaidDominion.\n¿Compartir tus datos?",
            who, what), function()
            -- Solo se prometen datos si realmente hay algo que enviar: con la
            -- lista vacía se responde FEED_EMPTY (nada que añadir) en lugar de
            -- un FEED_OK que nunca se cumple. La respuesta va por el MISMO canal
            -- del que vino la petición (no DefaultChannel del líder).
            if self:BroadcastList(key, channel, requester) then
                SafeWhisper("FEED_OK:" .. key, requester)
            else
                SafeWhisper("FEED_EMPTY:" .. key, requester)
            end
        end, function()
            SafeWhisper("FEED_REJ:" .. key, requester)
        end)
    else
        NotifyLeader(string.format("|cFFFFFFFF%s|r solicitó %s — respondido automáticamente.", who, what))
        if self:BroadcastList(key, channel, requester) then
            SafeWhisper("FEED_OK:" .. key, requester)
        else
            SafeWhisper("FEED_EMPTY:" .. key, requester)
        end
    end
end

-- Petición de las asignaciones de raid (clic derecho en "Modo de raid"). La
-- respuesta se filtra por la privacidad de CADA lista asignable: las privadas
-- nunca se comparten; si hay alguna en "preguntar primero" se pide el visto
-- bueno del líder (que aprueba las abiertas y las que pidieron preguntar), y si
-- todas son "open" se responde automáticamente. Como en las listas, el líder
-- SIEMPRE ve quién pidió y el solicitante recibe feedback dirigido.
function Comm:HandleAssignRequest(requester, channel)
    if not IsLeader() then return end
    local who = tostring(requester or "?")
    local openKeys, askKeys = {}, {}
    local parts = {}
    for _, key in ipairs(ASSIGNABLE_LISTS) do
        local mode = GetPrivacy(key)
        if mode == "ask" then
            askKeys[key] = true
            parts[#parts + 1] = Codec:ListLabel(key)
        elseif mode ~= "private" then
            openKeys[key] = true
            parts[#parts + 1] = Codec:ListLabel(key)
        end
    end
    if not next(parts) then
        NotifyLeader(string.format("|cFFFFFFFF%s|r solicitó las asignaciones de raid — todas las listas son PRIVADAS: no se comparte.", who))
        SafeWhisper("FEED_PRIV:assign", requester)
        return
    end
    if next(askKeys) then
        local all = {}
        for k in pairs(openKeys) do all[k] = true end
        for k in pairs(askKeys) do all[k] = true end
        PromptRequest(string.format("«%s» solicita las asignaciones de raid de RaidDominion (%s).\n¿Compartirlas?",
            who, table.concat(parts, ", ")), function()
            if self:BroadcastAssignments(channel, all, requester) then
                SafeWhisper("FEED_OK:assign", requester)
            else
                SafeWhisper("FEED_EMPTY:assign", requester)
            end
        end, function()
            SafeWhisper("FEED_REJ:assign", requester)
        end)
    else
        NotifyLeader(string.format("|cFFFFFFFF%s|r solicitó las asignaciones de raid — respondido automáticamente.", who))
        if self:BroadcastAssignments(channel, openKeys, requester) then
            SafeWhisper("FEED_OK:assign", requester)
        else
            SafeWhisper("FEED_EMPTY:assign", requester)
        end
    end
end

-- ============ Recepción ============

function Comm:HandleIncoming(message, sender, channel)
    if not message or message == "" then return end
    CommDebug("recv:", (message:sub(1, 24)), "de", tostring(sender), "canal", tostring(channel))

    -- Peticiones: SOLO de jugadores que están en el grupo. Un externo (whisper)
    -- no puede spamear al líder con diálogos ni forzar notificaciones.
    if message == "REQ_ASSIGN" then
        if IsSenderInGroup(sender) then
            self:HandleAssignRequest(sender, channel)
        end
        return
    elseif message:match("^REQ_LIST:") then
        if not IsSenderInGroup(sender) then return end
        local key = message:match("^REQ_LIST:(.+)$")
        if not key or not VALID_LIST_KEYS[key] then return end
        self:HandleListRequest(key, sender, channel)
        return
    end

    -- Retroalimentación del líder (whisper dirigido): solo de miembros del grupo.
    if message:match("^FEED_") then
        if not IsSenderInGroup(sender) then return end
        local kind, key = message:match("^(FEED_[A-Z]+):(.+)$")
        if kind and key then
            local what = Codec:FeedbackLabel(key)
            if kind == "FEED_OK" then
                Feedback("El líder aprobó tu solicitud de " .. what .. ": datos en camino.")
            elseif kind == "FEED_REJ" then
                Feedback("El líder rechazó tu solicitud de " .. what .. ".")
            elseif kind == "FEED_EMPTY" then
                Feedback("El líder no tiene elementos en " .. what .. ": tu lista queda como estaba.")
            else
                Feedback(what .. " es PRIVADA: el líder no la comparte.")
            end
        end
        return
    end

    -- Datos: SOLO del líder del grupo y con máquina de estados estricta (nada de
    -- trozos/cierre sin DATA_START previo, para no alimentar ProcessIncoming).
    -- `dataOpenLeader` recuerda QUÉ líder abrió la sesión (por nombre
    -- normalizado, estable ante reorden del roster): si el liderazgo cambia a
    -- mitad de la transferencia, el nuevo líder no puede escribir ni cerrar la
    -- sesión del anterior.
    if message == "DATA_START" then
        if IsSenderLeader(sender) then
            incoming = {}
            dataOpen = true
            dataOpenLeader = Codec:CleanName(sender)
            dataChunkCount = 0
            dataOpenTime = (GetTime and GetTime()) or 0
            CommDebug("DATA_START de", sender)
        else
            CommDebug("DATA_START RECHAZADO de", tostring(sender), "(no líder en roster)")
        end
        return
    end
    if message == "DATA_END" then
        if dataOpen and dataOpenLeader and IsSenderLeader(sender)
            and Codec:CleanName(sender) == dataOpenLeader then
            dataOpen = false
            dataOpenLeader = nil
            -- Si ProcessIncoming lanza un error (datos malformados) el lote debe
            -- cerrarse igualmente: BeginBatch/EndBatch para a la siguiente tanda.
            local ok, err = pcall(function()
                self:ProcessIncoming()
            end)
            if type(RD.config.EndBatch) == "function" then RD.config:EndBatch() end
            if not ok then
                if RD.messageManager and RD.messageManager.SendSystemMessage then
                    RD.messageManager:SendSystemMessage(
                        "|cffff0000[RaidDominion]|r Error al aplicar datos del líder: " .. tostring(err))
                end
            end
        else
            CommDebug("DATA_END RECHAZADO de", tostring(sender), "open=", tostring(dataOpen))
        end
        return
    end
    if message:match("^DATA_CHUNK:") then
        -- Sesión atascada (DATA_START sin cierre): se expira para poder reintentar.
        local nowT = (GetTime and GetTime()) or 0
        if dataOpen and nowT - dataOpenTime > DATA_SESSION_TIMEOUT then
            CommDebug("sesión expirada por timeout")
            dataOpen = false
            dataOpenLeader = nil
            incoming = {}
            dataChunkCount = 0
        end
        if not (dataOpen and dataOpenLeader and IsSenderLeader(sender)
            and Codec:CleanName(sender) == dataOpenLeader) then
            CommDebug("DATA_CHUNK RECHAZADO de", tostring(sender), "open=", tostring(dataOpen))
            return
        end
        if dataChunkCount >= MAX_TOTAL_CHUNKS then return end
        local category, idx, total, content = message:match("^DATA_CHUNK:([^:]+):(%d+):(%d+):(.+)$")
        if category and idx and content and content ~= "" then
            local ci = tonumber(idx)
            local ct = tonumber(total)
            -- Topes anti-DoS: índice dentro de la categoría y total declarado
            -- plausibles (el índice no puede superar su propio total), y un
            -- trozo no puede exceder el tamaño fijo de particionado.
            if ci and ci >= 1 and ci <= MAX_CHUNKS_PER_CATEGORY
                and ct and ct >= 1 and ct <= MAX_TOTAL_CHUNKS
                and ci <= ct
                and #content <= CHUNK_SIZE then
                if not incoming[category] then incoming[category] = {} end
                incoming[category][ci] = content
                dataChunkCount = dataChunkCount + 1
            end
        end
        return
    end
end

-- Aplica los datos recibidos a la configuración local. Las listas se FUSIONAN de
-- forma NO destructiva: se conservan los elementos locales y se añaden solo los
-- recibidos que no existan (sin duplicados). Nunca se borra nada local.
function Comm:ProcessIncoming()
    local applied = false
    local totalAdded = 0
    local updatedPlayers = 0
    local gapCategory = nil        -- si un trozo se perdió, se aborta el lote entero
    -- Los Sets de cada categoría se agrupan en un lote: al final se publica
    -- CONFIG_CHANGED una sola vez por clave distinta (evita N re-renders en
    -- cadena al sincronizar config del líder).
    if type(RD.config.BeginBatch) == "function" then RD.config:BeginBatch() end
    for category, chunks in pairs(incoming) do
        local maxIdx = 0
        for i in pairs(chunks) do
            if i > maxIdx then maxIdx = i end
        end
        -- Unión de trozos. Fast-path: si todos los índices 1..maxIdx tienen
        -- trozo (caso normal, entrega completa) se usa table.concat (una sola
        -- copia); el tamaño queda acotado por los topes anti-DoS
        -- (MAX_CHUNKS_PER_CATEGORY x CHUNK_SIZE).
        local content = ""
        local gap = false
        for i = 1, maxIdx do
            if chunks[i] == nil then gap = true break end
        end
        if not gap then
            content = table.concat(chunks, "", 1, maxIdx)
        else
            -- Hueco (trozo perdido): NO se reconstruye con "vacíos" (eso
            -- corrompía la lista fusionando nombres truncados en silencio). Se
            -- aborta el lote, se descartan los datos incompletos y se avisa para
            -- que el usuario repita "Obtener"; su configuración queda intacta.
            gapCategory = category
            break
        end

        local assignKey = category:match("^assign%.(.+)$")
        if assignKey then
            -- Asignaciones (item -> jugador): se REEMPLAZAN por las del líder, que
            -- es la fuente de verdad (datos de raid transitorios, no configuración
            -- local del seguidor). Solo las LISTAS (roles/rules/etc.) se fusionan
            -- de forma no destructiva.
            local tbl = {}
            for _, pair in ipairs(Codec:SplitFields(content, "\2")) do
                local fields = Codec:SplitFields(pair, "\1")
                if fields[1] ~= "" then tbl[fields[1]] = fields[2] or "" end
            end
            RD.config:Set("assignments." .. assignKey, tbl)
            -- Marcamos que SÍ se aplicó algo (para el feedback) aunque las
            -- asignaciones se reemplacen y no "sumen" elementos nuevos.
            for _ in pairs(tbl) do totalAdded = totalAdded + 1 end
        elseif category == "roles" or category == "abilities" or category == "buffs" or category == "auras" then
            -- Fusión NO destructiva de listas simples { name, icon }: conserva la
            -- lista local y añade solo los recibidos cuyo nombre no exista.
            local current = RD.config:Get(category, {})
            local list = {}
            local existing = {}
            if type(current) == "table" then
                for _, v in ipairs(current) do
                    local n = v.name or ""
                    if n ~= "" then
                        existing[Codec:CleanName(n)] = true
                        list[#list + 1] = v
                    end
                end
            end
            local added = 0
            for _, item in ipairs(Codec:SplitFields(content, "\2")) do
                local fields = Codec:SplitFields(item, "\1")
                local name = fields[1] or ""
                if name ~= "" and not existing[Codec:CleanName(name)] then
                    existing[Codec:CleanName(name)] = true
                    list[#list + 1] = { name = name, icon = fields[2] or "" }
                    added = added + 1
                end
            end
            RD.config:Set(category, list)
            totalAdded = totalAdded + added
        elseif category == "rules" or category == "mechanics" then
            -- Fusión NO destructiva por título (conserva los locales, sin duplicados)
            local current = RD.config:Get(category, {})
            local list = {}
            local seen = {}
            if type(current) == "table" then
                for _, v in ipairs(current) do
                    local t = v.title or v.name or ""
                    if t ~= "" then
                        seen[Codec:CleanName(t)] = true
                        list[#list + 1] = v
                    end
                end
            end
            local added = 0
            for _, item in ipairs(Codec:SplitFields(content, "\2")) do
                local fields = Codec:SplitFields(item, "\1")
                local title = fields[1] or ""
                if title ~= "" and not seen[Codec:CleanName(title)] then
                    seen[Codec:CleanName(title)] = true
                    list[#list + 1] = { title = title, icon = fields[2] or "", content = fields[3] or "" }
                    added = added + 1
                end
            end
            RD.config:Set(category, list)
            totalAdded = totalAdded + added
        elseif category == "bands" then
            local bands = RD.utils and RD.utils.bands
            if bands then
                local localBands = bands:GetBands()
                -- Mapa identity -> índice local. El icono NO forma parte de la
                -- identidad: coincidir en nombre+GS+horario = misma banda.
                local byKey = {}
                for i, b in ipairs(localBands) do
                    local key = (b.name ~= "") and Codec:BandKey(b.name, b.minGS, b.schedule) or nil
                    if key then byKey[key] = i end
                end
                local addedBands = 0
                local addedPlayers = 0
                for _, item in ipairs(Codec:SplitFields(content, "\2")) do
                    local fields = Codec:SplitFields(item, "\1")
                    local bname = fields[1] or ""
                    if bname ~= "" then
                        local key = Codec:BandKey(fields[1], fields[2], fields[3])
                        local idx = byKey[key]
                        local players = Codec:DecodePlayers(fields[5])
                        if idx then
                            -- Banda coincidente: fusiona jugadores sin duplicados.
                            -- El líder es la fuente de verdad: su versión de un
                            -- jugador ya existente REEMPLAZA la del solicitante;
                            -- los no existentes se añaden. Nunca se borran los
                            -- jugadores locales ausentes del payload.
                            for _, p in ipairs(players) do
                                if bands:GetPlayer(idx, p.name) then
                                    bands:UpdatePlayer(idx, p.name, p)
                                    updatedPlayers = updatedPlayers + 1
                                else
                                    bands:AddPlayer(idx, p)
                                    addedPlayers = addedPlayers + 1
                                end
                            end
                        else
                            -- Banda nueva: se crea con sus jugadores. El índice se
                            -- deriva del array que solo crece por el final (SaveBands
                            -- conserva orden), para que duplicados exactos dentro del
                            -- mismo payload colapsen en la banda recién creada.
                            local newIdx = #localBands + addedBands + 1
                            byKey[key] = newIdx
                            bands:CreateBand({
                                name = bname,
                                minGS = tonumber(fields[2]) or 0,
                                schedule = fields[3] or "",
                                icon = fields[4] or "Interface\\Icons\\INV_Banner_02",
                                players = players,
                            })
                            addedBands = addedBands + 1
                        end
                    end
                end
                totalAdded = totalAdded + addedBands + addedPlayers
            end
        end
        applied = true
    end
    incoming = {}
    dataOpen = false
    dataChunkCount = 0
    -- Cierra el lote: publica CONFIG_CHANGED una vez por clave distinta tocada.
    if type(RD.config.EndBatch) == "function" then RD.config:EndBatch() end

    -- Hueco detectado: se abortó antes de aplicar nada (la configuración local
    -- quedó intacta). Se avisa para que el usuario repita "Obtener".
    if gapCategory then
        CommDebug("ProcessIncoming: hueco en", tostring(gapCategory), "- lote abortado")
        if RD.messageManager and RD.messageManager.SendSystemMessage then
            RD.messageManager:SendSystemMessage(string.format(
                "|cffff8000[RaidDominion]|r La transferencia de %s llegó incompleta (se perdieron trozos) y NO se aplicó; tu configuración sigue intacta. Pulsa 'Obtener' de nuevo.",
                tostring(Codec:FeedbackLabel(gapCategory))))
        end
        return
    end

    -- Re-render en vivo de la ventana de config si está visible: sin esto, el
    -- editor del tab activo no mostraría los datos recién obtenidos (ReapplyHeight
    -- solo reajusta alturas). Render() es responsivo en combate.
    if applied then
        local cw = RD.ui and RD.ui.configWindow
        if cw and cw.Render and cw.isShown then
            cw:Render()
        end
        -- Feedback no amenazante: cuántos elementos nuevos se añadieron (nunca se
        -- borran los locales) y cuántos jugadores se sincronizaron con el líder.
        if RD.messageManager and RD.messageManager.SendSystemMessage then
            local msg = "|cff33ff99[RaidDominion]|r Obtener: "
            if totalAdded > 0 then
                msg = msg .. string.format("se añadieron %d elemento(s) nuevo(s), sin duplicados ni pérdidas", totalAdded)
                if updatedPlayers > 0 then
                    msg = msg .. string.format(" y se actualizaron %d jugador(es) con los datos del líder", updatedPlayers)
                end
            elseif updatedPlayers > 0 then
                msg = msg .. string.format("sin elementos nuevos; se actualizaron %d jugador(es) con los datos del líder", updatedPlayers)
            else
                msg = msg .. "tu lista ya estaba al día (no había elementos nuevos)."
            end
            RD.messageManager:SendSystemMessage(msg .. ".")
        end
    end
end

-- ============ Evento CHAT_MSG_ADDON ============
-- El cliente SOLO entrega los addon messages cuyo prefijo está REGISTRADO con
-- RegisterAddonMessagePrefix (API que SÍ existe en 3.3.5a, contraria a lo que
-- creía una versión anterior): sin el registro, CHAT_MSG_ADDON nunca dispara
-- para "RD_COMM" y el addon no recibe ni peticiones ni datos. Se registra con
-- pcall por si un cliente antiguo no lo expone; el filtro por prefijo del
-- handler se conserva igualmente (defensa en profundidad).

local commEvent = CreateFrame("Frame")
commEvent:RegisterEvent("CHAT_MSG_ADDON")
if type(RegisterAddonMessagePrefix) == "function" then
    pcall(RegisterAddonMessagePrefix, PREFIX)
end
commEvent:SetScript("OnEvent", function(self, event, prefix, message, channel, sender)
    if prefix ~= PREFIX then return end
    if sender == UnitName("player") then return end
    pcall(function()
        Comm:HandleIncoming(message, sender, channel)
    end)
end)

RD.comm = Comm
RD.modules = RD.modules or {}
RD.modules.communication = Comm

return Comm
