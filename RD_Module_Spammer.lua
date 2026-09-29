--[[
    RD_Module_Spammer.lua
    PROPÓSITO: Motor de "spameo" de reclutamiento por banda (estilo KRT). Compone
              un mensaje de reclutamiento a partir de la config de spam de una
              banda (bands[i].spammer): nombre sin corchetes envolventes, conteos y clases
              por rol, mensaje libre con placeholders, cola (X/Y) de miembros y
              límite de 255 caracteres. Lo envía en bucle cada `duration` segundos
              a los canales marcados (reusa MessageManager:SendRaw).
              Sin C_Timer: frame OnUpdate persistente que se auto-oculta cuando no
              hay spam activo (cero coste en idle).
    API PÚBLICA:
        - RD.modules.spammer:BuildMessage(bandIndex) -> string
        - RD.modules.spammer:GetLength(bandIndex) -> number (caracteres)
        - RD.modules.spammer:IsActive() / ActiveIndex() -> bool / number|nil
        - RD.modules.spammer:TimeLeft() -> number (segundos hasta el próximo envío)
        - RD.modules.spammer:Start(bandIndex) -> boolean
        - RD.modules.spammer:Stop() / Toggle(bandIndex)
    EVENTOS: Ninguno directo (envía por SendChatMessage vía MessageManager).
]]

local addonName, private = ...
local RD = _G.RaidDominion or {}
_G.RaidDominion = RD

local Spammer = {}

-- Límite de SendChatMessage en 3.3.5a (caracteres; se cuenta UTF-8, no bytes)
local MAX_LEN = 255

-- Mensaje de sistema (avisa del porqué de una parada; fallback a print)
local function System(msg)
    local mm = RD.modules and RD.modules.messageManager
    if mm and mm.SendSystemMessage then
        mm:SendSystemMessage(msg)
    else
        print(msg)
    end
end

-- Si el mensaje compuesto se pasa de largo, se avisa (antes el bucle se paraba
-- en silencio y el usuario creía que seguía activo). Devuelve true si avisó.
local function WarnTooLong(msg)
    if msg ~= "" and CharCount(msg) > MAX_LEN then
        System("|cffff8000[RaidDominion]|r El mensaje supera los " .. MAX_LEN
            .. " caracteres; el spam de banda se ha detenido. Reduce la composición o los placeholders.")
        return true
    end
    return false
end

-- Longitud en bytes de un carácter UTF-8 (fuente única: RD.UIUtils.UTF8Len),
-- con fallback idéntico si este módulo se executa aislado en el harness.
local UTF8Len = (RD.UIUtils and RD.UIUtils.UTF8Len)
    or function(byte)
        if byte >= 0xF0 then return 4
        elseif byte >= 0xE0 then return 3
        elseif byte >= 0xC0 then return 2 end
        return 1
    end

-- Cuenta CARACTERES de un string sin romper multibyte. Fuente única:
-- MessageManager:CountChars (carga previa); fallback idéntico si este módulo se
-- ejecuta aislado en el harness.
local function CharCount(text)
    local mm = RD.modules and RD.modules.messageManager
    if mm and mm.CountChars then return mm:CountChars(text) end
    local count = 0
    local byte = 1
    while byte <= #text do
        local b = string.byte(text, byte)
        byte = byte + UTF8Len(b)
        count = count + 1
    end
    return count
end

-- Nombre "presentable" (sin marcado de enlace) para análisis de tamaño/dificultad
-- y extracción de números (cola X/Y). Se delega en RD.UIUtils.StripMarkup (carga
-- antes en el .toc); fallback idéntico por si el módulo se ejecuta aislado en el
-- harness. El marcado NUNCA se retira del mensaje final, solo del análisis.
local StripMarkup = (RD.UIUtils and RD.UIUtils.StripMarkup)
    or function(text)
        if type(text) ~= "string" then return tostring(text or "") end
        text = text:gsub("%|H[^|]*%|h(.-)%|h", "%1")
        text = text:gsub("%|K[^|]*%|k(.-)%|k", "%1")
        text = text:gsub("%|c%x%x%x%x%x%x%x%x", "")
        text = text:gsub("%|r", "")
        text = text:gsub("%|k", "")
        text = text:gsub("%|h", "")
        return text
    end

-- Sustituye los placeholders {band} {players} {gs} {tank} {healer} {melee} {ranged}
-- sobre el mensaje libre del spammer.
local function SubstitutePlaceholders(msg, spammer, band)
    if not msg or msg == "" then return "" end
    local playersText = "0"
    local inRaid = GetNumRaidMembers() > 0
    local inParty = GetNumPartyMembers() > 0
    local count = (inRaid and GetNumRaidMembers()) or (inParty and (GetNumPartyMembers() + 1)) or 0
    -- El cupo se detecta sobre el nombre SIN marcado de enlace: los dígitos
    -- internos de un enlace (IDs de logro/ítem, GUIDs) no falsean el cupo.
    local maxNum = tonumber(StripMarkup(spammer.name or ""):match("%d+"))
    playersText = "(" .. tostring(count) .. "/" .. tostring(maxNum or 0) .. ")"
    local map = {
        band = tostring(band and band.name or ""),
        players = playersText,
        gs = tostring(tonumber(band and band.minGS) or 0),
        tank = tostring(tonumber(spammer.tank) or 0),
        healer = tostring(tonumber(spammer.healer) or 0),
        melee = tostring(tonumber(spammer.melee) or 0),
        ranged = tostring(tonumber(spammer.ranged) or 0),
    }
    return (msg:gsub("{(%a+)}", function(token)
        return map[token] or ("{" .. token .. "}")
    end))
end

-- Compone el mensaje final a partir de una config de spam dada y la banda.
-- Replica el orden de KRT: Nombre // N Tank (clases) // ... // mensaje // cola.
-- `s` puede ser la config commiteada (BuildMessage) o un override en edición
-- (BuildMessageFrom, usado por el preview en vivo de la ventana).
function Spammer:BuildMessageFrom(s, bandIndex)
    if not s or type(s) ~= "table" then return "" end
    local bands = RD.utils and RD.utils.bands
    local band = bands and bandIndex and bands:GetBand(bandIndex)
    if not band then return "" end

    local temp = ""
    local prefix = tostring(s.prefix or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local suffix = tostring(s.suffix or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local name = tostring(s.name or ""):gsub("^%s+", ""):gsub("%s+$", "")
    -- Separador de partes configurable ("" = sin separador).
    -- REGLA: el separador es UN SOLO símbolo y actúa como coma: pegado a la
    -- parte anterior + un espacio después ("test/ siguiente"), sin espacios a
    -- su alrededor. El separador reemplaza las comas del campo Mensaje.
    local sep = tostring(s.separator or "")
    local sepGlued = ""
    if sep ~= "" then sepGlued = sep .. " " end
    -- Si el nombre guardado trae corchetes internos (plantillas legacy tipo
    -- "Armo [Icc 25H]"), se extrae el contenido entre corchetes para emitir el
    -- nombre de la banda limpio, sin corchetes que lo rodeen ni prefijos extra.
    -- ATENCIÓN: si el nombre es un ENLACE dinámico (logro/ítem/objetivo), su
    -- texto visible va dentro de "[...]" del propio enlace (|H...|h[Visible]|h)
    -- y este patrón lo extraería, DESTRUYENDO el enlace. Se omite la extracción
    -- cuando el nombre trae marcado de hiperenlace.
    local isLinkName = name:find("|H", 1, true) ~= nil or name:find("|K", 1, true) ~= nil
    local bracketContent = nil
    if not isLinkName then
        bracketContent = name:match("%[([^%]]+)%]")
        if bracketContent then
            name = bracketContent
        end
    end
    -- Nombre SIN corchetes envolventes + prefijo/sufijo editables (preview y
    -- envío). El nombre se emite tal cual (ya viene limpio de la extracción
    -- legacy de arriba; los enlaces dinámicos se emiten TAL CUAL, sin corchetes
    -- extra que duplicarían el texto visible del enlace).
    local namePart = ""
    if name ~= "" then
        namePart = name
    end

    -- Construye el mensaje por PARTES; cada parte se une con el separador
    -- (comportamiento de coma: símbolo + espacio). El separador también
    -- reemplaza las comas del campo Mensaje al componer.
    local parts = {}
    local function AddPart(text)
        text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if text ~= "" then parts[#parts + 1] = text end
    end

    -- Cabeza: prefijo / nombre / sufijo unidos con espacio simple
    local headParts = {}
    if prefix ~= "" then headParts[#headParts + 1] = prefix end
    if namePart ~= "" then headParts[#headParts + 1] = namePart end
    if suffix ~= "" then headParts[#headParts + 1] = suffix end
    if #headParts > 0 then AddPart(table.concat(headParts, " ")) end

    -- Roles con conteo > 0 (como KRT). El texto de CLASES solo se incluye si el
    -- ojo de esa fila está activo (band.spammer.<rol>ClassShow no es false):
    -- número y rol SIEMPRE van, el ojo solo alterna las clases.
    local roleText = ""
    local roles = {
        { n = tonumber(s.tank or 0),   label = "Tank",      cls = s.tankClass,   show = s.tankClassShow   ~= false },
        { n = tonumber(s.healer or 0), label = "Healer",    cls = s.healerClass, show = s.healerClassShow ~= false },
        { n = tonumber(s.melee or 0),  label = "DPS Melee", cls = s.meleeClass,  show = s.meleeClassShow  ~= false },
        { n = tonumber(s.ranged or 0), label = "DPS Rango", cls = s.rangedClass, show = s.rangedClassShow ~= false },
    }
    for _, r in ipairs(roles) do
        if r.n and r.n > 0 then
            if roleText ~= "" then roleText = roleText .. " " end
            roleText = roleText .. r.n .. " " .. r.label
            local cls = tostring(r.cls or ""):gsub("^%s+", ""):gsub("%s+$", "")
            if r.show and cls ~= "" then
                roleText = roleText .. " (" .. cls .. ")"
            end
        end
    end
    AddPart(roleText)

    -- Mensaje libre con placeholders; las comas se reemplazan por el separador
    local message = tostring(s.message or "")
    if message ~= "" then
        local sub = SubstitutePlaceholders(message, s, band)
        if sep ~= "" then
            sub = sub:gsub(",", sepGlued)
            -- Colapsa separadores repetidos del propio mensaje (p.ej. "a,,b")
            local esc = sep:gsub("([^%w])", "%%%1")
            sub = sub:gsub("(" .. esc .. "%s*)+", sepGlued)
        else
            -- Sin separador: se retiran las comas para no dejar fragmentos sueltos
            sub = sub:gsub(",", " ")
        end
        AddPart(sub)
    end

    -- Cola (X/Y) si el nombre contiene un número (como KRT). Se analiza el nombre
    -- SIN marcado de enlace: los dígitos internos de un enlace no falsean el cupo.
    local maxNum = tonumber(StripMarkup(name):match("%d+"))
    if maxNum then
        local inRaid = GetNumRaidMembers() > 0
        local inParty = GetNumPartyMembers() > 0
        local count = (inRaid and GetNumRaidMembers()) or (inParty and (GetNumPartyMembers() + 1)) or 0
        AddPart("(" .. count .. "/" .. maxNum .. ")")
    end

    -- Une las partes con el separador ("" → espacio simple entre partes)
    local glue = " "
    if sep ~= "" then glue = sepGlued end
    temp = table.concat(parts, glue)

    -- Normaliza espacios sobrantes y colapsa separadores consecutivos
    if sep ~= "" then
        local esc = sep:gsub("([^%w])", "%%%1")
        temp = temp:gsub("(" .. esc .. "%s*)+", sepGlued)
    end
    temp = temp:gsub("%s+", " ")
    temp = temp:gsub("^%s+", ""):gsub("%s+$", "")
    return temp
end

-- Compone el mensaje final de la banda (usa la config commiteada)
function Spammer:BuildMessage(bandIndex)
    local bands = RD.utils and RD.utils.bands
    if not bands then return "" end
    local s = bands:GetSpammer(bandIndex)
    if not s then return "" end
    return self:BuildMessageFrom(s, bandIndex)
end

-- Detecta tamaño (jugadores 10/25), dificultad (N/H) y nombre presentable a
-- partir del nombre de la banda. Formatos típicos: "ICC25H", "SR10H",
-- "icc 25 n", "Core 25 Heroico". Devuelve
-- { size, players, difficulty, suggestedName, bandName }.
function Spammer:DetectRaidInfo(bandIndex)
    local bands = RD.utils and RD.utils.bands
    local band = bands and bandIndex and bands:GetBand(bandIndex)
    if not band then
        return { size = nil, players = nil, difficulty = nil, suggestedName = "", bandName = "" }
    end
    local bandName = tostring(band.name or ""):gsub("^%s+", ""):gsub("%s+$", "")
    -- El análisis (tamaño/dificultad) se hace sobre el nombre SIN marcado de
    -- enlace: si el nombre es un enlace dinámico, los números/GUIDs internos del
    -- markup no deben falsear 10/25 ni N/H. suggestedName conserva el nombre
    -- original (con el enlace) para que la composición automática no lo aplane.
    local cleanName = StripMarkup(bandName)
    local text = string.lower(cleanName)
    local compact = text:gsub("%s+", "")

    local size, difficulty, suggestedName

    -- Código compacto: ICC25H / SR10N / toc25hc → base + tamaño + dificultad.
    -- Lua 5.1 no soporta alternancia `|` en patrones, así que se capturan los
    -- dos dígitos (%d%d) y se valida que sean 10 o 25.
    local basePart, sizePart, diffPart = compact:match("^([%a%-%_]+)(%d%d)([hn])c?$")
    if basePart and sizePart and (sizePart == "10" or sizePart == "25") and diffPart then
        size = tonumber(sizePart)
        difficulty = diffPart
        -- Preserva mayúsculas del original sin espacios (ICC25H → base "ICC")
        local raw = cleanName:gsub("%s+", "")
        local rawBase = raw:match("^([%a%-%_]+)(%d%d)([HhNn])c?$")
        local prettyBase = rawBase or basePart
        if #prettyBase <= 4 then
            prettyBase = string.upper(prettyBase)
        else
            prettyBase = prettyBase:sub(1, 1):upper() .. prettyBase:sub(2):lower()
        end
        suggestedName = prettyBase .. " " .. sizePart .. string.upper(diffPart)
    else
        if text:find("25") then size = 25
        elseif text:find("10") then size = 10 end
        if text:find("%d+h") or text:find("hc") or text:find("heroic") or text:find("heroico")
            or text:find(" h%f[%A]") then
            difficulty = "h"
        elseif text:find("%d+n") or text:find("normal") or text:find(" n%f[%A]") then
            difficulty = "n"
        end
        suggestedName = bandName
        if suggestedName ~= "" and size and difficulty then
            -- Inserta espacio antes del tamaño si venía pegado: "Icc25H" → "Icc 25H"
            local clean = suggestedName
            clean = clean:gsub("([%a])(10)([HhNn])", "%1 %2%3")
            clean = clean:gsub("([%a])(25)([HhNn])", "%1 %2%3")
            clean = clean:gsub("25[hH]", "25H"):gsub("25[nN]", "25N")
            clean = clean:gsub("10[hH]", "10H"):gsub("10[nN]", "10N")
            clean = clean:gsub("^%l", string.upper)
            suggestedName = clean
        elseif suggestedName ~= "" then
            suggestedName = suggestedName:gsub("^%l", string.upper)
        end
    end

    return {
        size = size,
        players = size, -- alias: cupo de la banda (10/25)
        difficulty = difficulty,
        suggestedName = suggestedName or "",
        bandName = bandName,
    }
end

-- Longitud en CARACTERES de un string (sin romper multibyte)
function Spammer:CharCount(text)
    return CharCount(text or "")
end

-- Longitud en CARACTERES del mensaje compuesto (para el límite 255)
function Spammer:GetLength(bandIndex)
    return CharCount(self:BuildMessage(bandIndex))
end

-- ============ Bucle de envío ============

local activeIndex = nil
local nextSendAt = 0
-- Declaración adelantada: Start/Stop referencian loopFrame. En Lua 5.1 un
-- `local` solo es visible DESPUÉS de su línea; si CreateFrame va abajo,
-- Start/Stop ven el global nil, nunca hacen Show() y el OnUpdate no corre
-- (solo el primer SendNow de Start, sin reenvíos ni reinicio de countdown).
local loopFrame

function Spammer:IsActive()
    return activeIndex ~= nil
end

function Spammer:ActiveIndex()
    return activeIndex
end

-- Tiempo restante (segundos) hasta el próximo envío del bucle. 0 si no está activo.
function Spammer:TimeLeft()
    if not activeIndex then return 0 end
    local left = nextSendAt - GetTime()
    if left < 0 then left = 0 end
    return left
end

-- Envía el mensaje ahora a los canales marcados (reusa MessageManager:SendRaw
-- para que INN por número / SYSTEM / resolución de canal tengan una sola fuente)
function Spammer:SendNow()
    local bands = RD.utils and RD.utils.bands
    if not bands then return end
    local s = bands:GetSpammer(activeIndex)
    if not s then self:Stop() return end
    local msg = self:BuildMessage(activeIndex)
    if msg == "" or CharCount(msg) > MAX_LEN then
        WarnTooLong(msg)
        self:Stop()
        return
    end
    local channels = s.channels or {}
    local mm = RD.modules and RD.modules.messageManager
    for ch, checked in pairs(channels) do
        if checked and mm and mm.SendRaw then
            pcall(function() mm:SendRaw(msg, ch) end)
        end
    end
end

-- Inicia el bucle de spam de una banda. Envía inmediatamente y luego cada
-- `duration` segundos. Devuelve false si no se puede (mensaje vacío, >255 chars
-- o sin canales marcados).
function Spammer:Start(bandIndex)
    local bands = RD.utils and RD.utils.bands
    if not bands or not bands.GetBand or not bands:GetBand(bandIndex) then return false end
    local s = bands:GetSpammer(bandIndex)
    if not s then return false end
    -- Validaciones (como KRT: Start deshabilitado si no aplica)
    local msg = self:BuildMessage(bandIndex)
    if msg == "" or CharCount(msg) > MAX_LEN then
        WarnTooLong(msg)
        return false
    end
    local hasChannel = false
    for _, checked in pairs(s.channels or {}) do
        if checked then hasChannel = true break end
    end
    if not hasChannel then return false end

    activeIndex = bandIndex
    nextSendAt = GetTime()          -- envío inmediato al arrancar
    local duration = tonumber(s.duration) or 60
    if duration < 1 then duration = 1 end
    -- Aviso único si algún canal tiene un suelo mayor que `duration`: el
    -- limitador global espaciará los envíos a ese canal (p.ej. la Posada y los
    -- índices 1-9 exigen ~10 s) y el usuario debe saber por qué.
    local mm = RD.modules and RD.modules.messageManager
    local warnOnce = false
    for ch, checked in pairs(s.channels or {}) do
        if checked and mm and mm.ChannelFloor and mm:ChannelFloor(ch) > duration then
            warnOnce = true
            break
        end
    end
    if warnOnce and mm and mm.SendSystemMessage then
        mm:SendSystemMessage(string.format(
            "|cffff8000[RaidDominion]|r Algunos canales de este spammer admiten un envío cada %d s (Posada e índices 1-9); el bucle se espaciará a ese ritmo aunque el intervalo configurado sea menor.",
            math.floor(mm:ChannelFloor("INN") or 10)))
    end
    self:SendNow()
    nextSendAt = GetTime() + duration

    if loopFrame then loopFrame:Show() end
    if RD.ui and RD.ui.spammerWindow and RD.ui.spammerWindow.SetRunning then
        RD.ui.spammerWindow:SetRunning(true)
    end
    if RD.events and RD.events.Publish then
        RD.events:Publish("SPAM_STATE_CHANGED", bandIndex)
    end
    return true
end

function Spammer:Stop()
    if activeIndex == nil then return end
    local wasIndex = activeIndex
    activeIndex = nil
    if loopFrame then loopFrame:Hide() end
    if RD.ui and RD.ui.spammerWindow and RD.ui.spammerWindow.SetRunning then
        RD.ui.spammerWindow:SetRunning(false)
    end
    if RD.events and RD.events.Publish then
        RD.events:Publish("SPAM_STATE_CHANGED", nil)
    end
end

function Spammer:Toggle(bandIndex)
    if activeIndex == bandIndex then
        self:Stop()
        return false
    end
    return self:Start(bandIndex)
end

-- Frame OnUpdate persistente: se auto-oculta cuando no hay spam activo.
-- Se crea con UIParent como padre para garantizar que OnUpdate se ejecute
-- en 3.3.5a (un frame oculto sin mostrar no recibe OnUpdate; al Show() corre).
-- Lee la duración de la config en cada tick (los cambios aplican al siguiente
-- intervalo). Si el jugador está muerto se salta el envío de ese tick.
loopFrame = CreateFrame("Frame", "RDSpammerLoop", UIParent)
loopFrame:Hide()
loopFrame:SetScript("OnUpdate", function(self)
    if not activeIndex then self:Hide() return end
    local now = GetTime()
    if now >= nextSendAt then
        if not UnitIsDeadOrGhost("player") then
            Spammer:SendNow()
        end
        local bands = RD.utils and RD.utils.bands
        local s = bands and bands.GetSpammer and bands:GetSpammer(activeIndex)
        -- duration mínimo 1s (evita spam por frame si se escribe 0/negativo)
        local duration = s and (tonumber(s.duration) or 60) or 60
        if duration < 1 then duration = 1 end
        nextSendAt = now + duration
    end
end)

RD.modules = RD.modules or {}
RD.modules.spammer = Spammer
return Spammer