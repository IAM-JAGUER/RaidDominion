--[[
    RD_Module_Communication_Codec.lua
    PROPÓSITO: Codificación/decodificación pura del protocolo RD_COMM usado por
              RD_Module_Communication.lua. Funciones sin estado ni efectos
              laterales: sanean, particionan y serializan los payloads que viajan
              por SendAddonMessage (asignaciones, listas configurables y bandas).
    API PÚBLICA:
        - RD.commCodec:CleanName(name)
        - RD.commCodec:SplitFields(str, sep)
        - RD.commCodec:Sanitize(text)
        - RD.commCodec:EncodeItem(it)
        - RD.commCodec:EncodeBand(band)
        - RD.commCodec:EncodeAssignments(tbl)
        - RD.commCodec:DecodePlayers(raw)
        - RD.commCodec:BandKey(name, minGS, schedule)
        - RD.commCodec:ListLabel(key)
        - RD.commCodec:FeedbackLabel(key)
    EVENTOS: ninguno (módulo puro: sin frames, sin registros, sin estado).
]]

local addonName, private = ...
local RD = _G.RaidDominion or {}
_G.RaidDominion = RD

local Codec = {}

-- Normaliza un nombre de jugador (minúsculas, sin Reino) para comparar contra el
-- roster real del grupo. Delega en RD.UIUtils.CleanName si está disponible.
function Codec:CleanName(name)
    if RD.UIUtils and RD.UIUtils.CleanName then
        return RD.UIUtils.CleanName(name)
    end
    return string.lower(tostring(name or ""))
end

local ListNames = {
    roles = "Roles", abilities = "Habilidades", buffs = "Buffs", auras = "Auras",
    mechanics = "Mecánicas", rules = "Reglas", bands = "Bandas",
}

-- Etiqueta legible de una lista configurable (roles/rules/bands/...)
function Codec:ListLabel(key)
    return ListNames[key] or key
end

-- Etiqueta legible en el feedback: las asignaciones usan la clave "assign".
function Codec:FeedbackLabel(key)
    if key == "assign" then return "las asignaciones de raid" end
    local label = Codec:ListLabel(key)
    return "la lista «" .. (label == key and key or label) .. "»"
end

-- Divide un string conservando campos vacíos (strsplit de WoW los descarta)
function Codec:SplitFields(str, sep)
    local out = {}
    local pos = 1
    while true do
        local s, e = string.find(str, sep, pos, true)
        if not s then
            out[#out + 1] = str:sub(pos)
            break
        end
        out[#out + 1] = str:sub(pos, s - 1)
        pos = e + 1
    end
    return out
end

-- Codifica un ítem { title, icon, content } / { name, minGS, schedule, icon }.
-- Se sanean los caracteres de control (incluidos \1/\2 del framing y \n) para no
-- corromper el formato del mensaje, igual que EncodeBand con las notas.
-- Fast-path: si el texto no contiene control chars (el caso común en los envíos)
-- se devuelve tal cual, sin reasignar (gsub crea un string nuevo igual al
-- original).
function Codec:Sanitize(text)
    text = tostring(text or "")
    if not text:find("[%c]") then return text end
    return string.gsub(text, "[%c]", " ")
end

-- Sanea un campo de texto (control chars) y lo ACOTA en longitud. El recorte no
-- parte un carácter UTF-8 multibyte (descarta los bytes de continuación
-- sobrantes). Evita que un payload hostil rompa el framing con \1-\4/\n o infle
-- el buffer de ProcessIncoming con campos larguísimos.
local FIELD_MAX = 120
local FIELD_MAX_CONTENT = 2000
local function SanitizeField(text, maxLen)
    local s = Codec:Sanitize(text)
    local limit = maxLen or FIELD_MAX
    if #s > limit then
        s = s:sub(1, limit)
        -- Quita bytes de continuación sobrantes del último carácter UTF-8.
        s = s:gsub("[\128-\191]*$", "")
        -- Si quedó un byte LEAD huérfano al final (sin su continuación), se
        -- descarta también (no puede completarse).
        local lb = string.byte(s, #s)
        if lb and lb >= 0xC0 then
            s = s:sub(1, #s - 1)
        end
    end
    return s
end

function Codec:EncodeItem(it)
    return SanitizeField(it.title or it.name, FIELD_MAX) .. "\1" ..
           SanitizeField(it.icon, 160) .. "\1" ..
           SanitizeField(it.content or it.schedule, FIELD_MAX_CONTENT)
end

-- Codifica una banda INCLUYENDO su lista de jugadores (para compartir bandas
-- completas vía "Obtener"). Separadores: \1 = campo de banda, \2 = ítem,
-- \3 = campo de jugador, \4 = jugador. TODOS los campos se sanean de caracteres
-- de control (antes solo las notas: un nombre con \1/\4 inyectaba campos) y se
-- acotan en longitud.
-- PRIVACIDAD: las NOTAS de jugador NO viajan (campo enviado vacío). Son datos
-- personales del líder (roster GM); el portal web tampoco las expone
-- (AGENTS.md §14.3). El receptor conserva sus notas locales (ver UpdatePlayer).
function Codec:EncodeBand(band)
    local parts = {
        SanitizeField(band.name or "", FIELD_MAX),
        tostring(tonumber(band.minGS) or 0),
        SanitizeField(band.schedule or "", FIELD_MAX),
        SanitizeField(band.icon or "", 160),
    }
    local players = {}
    for _, p in ipairs(band.players or {}) do
        players[#players + 1] = table.concat({
            SanitizeField(p.name or "", 64),
            SanitizeField(p.class or "", 32),
            SanitizeField(p.role or "", 32),
            SanitizeField(p.dual or "", 32),
            SanitizeField(p.sanction or "", 32),
            tostring(tonumber(p.points) or 0),
            "",   -- notes: nunca viajan (privacidad, AGENTS.md §14.3)
            SanitizeField(p.leader or "", 16),
        }, "\3")
    end
    parts[#parts + 1] = table.concat(players, "\4")
    return table.concat(parts, "\1")
end

-- Codifica una tabla de asignaciones { itemName = player }: saneado y acotado
-- de ambos lados (antes no saneaba nada: un nombre con \1/\2 inyectaba campos).
function Codec:EncodeAssignments(tbl)
    local out = {}
    for k, v in pairs(tbl) do
        out[#out + 1] = SanitizeField(k, FIELD_MAX) .. "\1" .. SanitizeField(v, 64)
    end
    return table.concat(out, "\2")
end

-- Clave de identidad de una banda para el dedup/merge de "Obtener". Las bandas
-- NO son únicas por nombre: dos bandas pueden llamarse igual y distinguirse por
-- GS y horario (p.ej. "Núcleo 25" 5400 Día / "Núcleo 25" 5200 Sábado). Si se
-- deduplica solo por nombre, al obtener se perderían todas menos la primera del
-- mismo nombre. La clave compone nombre+GS+horario (el icono NO forma parte de
-- la identidad: coincidir en estos tres campos = misma banda, y sus jugadores se
-- fusionan). Los jugadores tampoco forman parte de la identidad.
function Codec:BandKey(name, minGS, schedule)
    return Codec:CleanName(name or "") .. "\1" ..
           tostring(tonumber(minGS) or 0) .. "\1" ..
           tostring(schedule or "")
end

-- Decodifica la lista de jugadores compartida (campo 5 de una banda, separadores
-- \4 jugador / \3 campo). Devuelve un array de { name, class, role, dual,
-- sanction, banned, points, notes, leader }.
function Codec:DecodePlayers(raw)
    local players = {}
    if raw and raw ~= "" then
        -- Fast-path: un solo jugador (sin \4) evita el SplitFields doble y el
        -- bucle. Es el caso más común en bandas pequeñas.
        local function DecodeOne(pstr)
            local pf = Codec:SplitFields(pstr, "\3")
            if pf[1] and pf[1] ~= "" then
                local sanction = pf[5] or ""
                players[#players + 1] = {
                    name = pf[1],
                    class = pf[2] or "",
                    role = pf[3] or "",
                    dual = pf[4] or "",
                    sanction = sanction,
                    banned = sanction ~= "",
                    points = tonumber(pf[6]) or 0,
                    notes = pf[7] or "",
                    leader = pf[8] or "",
                }
            end
        end
        if not string.find(raw, "\4", 1, true) then
            DecodeOne(raw)
        else
            for _, pstr in ipairs(Codec:SplitFields(raw, "\4")) do
                DecodeOne(pstr)
            end
        end
    end
    return players
end

RD.commCodec = Codec
return Codec