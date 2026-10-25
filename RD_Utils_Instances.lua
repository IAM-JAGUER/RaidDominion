--[[
    RD_Utils_Instances.lua
    PROPÓSITO: Lectura de las instancias guardadas del personaje
              (GetSavedInstanceInfo) con lógica PURA y COMPARTIDA: la consumen
              la sección "Instancias" del editor de jugador, los tooltips del
              botón "Jugador" y del minimapa, el snapshot pasivo de
              characters y, como fallback, la proyección al portal web
              (RD_Utils_Registry). Sin frames, sin mensajes y sin eventos del
              juego, por lo que es testeable con mocks del harness.
              ROBUSTO a la semántica del campo `expires`: en el API estándar
              3.3.5a es una ÉPOCA absoluta; en este servidor (UltimoWoW, como
              lee SavedInstances) es un OFFSET relativo de segundos restantes —
              se detecta y normaliza. La cuenta atrás usa GetServerTime()
              (fallback time()), inmune a la zona horaria del SO. La
              enumeración es por GetSavedInstanceInfo hasta nil (tope de
              seguridad), NO por GetNumSavedInstances: el contador coincide
              siempre con la lista visible.
    API PÚBLICA:
        - RD.utils.instances:Now()                              -> época de referencia
        - RD.utils.instances:ResolveReset(expires, now)         -> segundos restantes | nil
        - RD.utils.instances:DifficultyTag(diff, raid, diffname)-> "25H" / "10" / "N" | nil
        - RD.utils.instances:FormatRemaining(seg)               -> "2d 4h"
        - RD.utils.instances:Collect(now)  -> { { name, rem?, resetAt?, extended, tag, locked } }
        - RD.utils.instances:Split(entries)  -> con reloj, sin reloj
        - RD.utils.instances:Export(now)   -> { { name, difficulty?, resetAt?, extended? } }
                                              (contrato SV del portal, §14)
    EVENTOS: Ninguno.
]]

local addonName, private = ...
local RD = _G.RaidDominion or {}
_G.RaidDominion = RD

RD.utils = RD.utils or {}
local Instances = {}

-- Momento de referencia "ahora": hora del SERVIDOR (época absoluta; inmune a la
-- zona horaria del SO, que era la fuente del día equivocado con date() local).
function Instances:Now()
    if GetServerTime then
        local t = GetServerTime()
        if type(t) == "number" and t > 0 then return t end
    end
    return time()
end

-- El campo `expires` de GetSavedInstanceInfo varía según el cliente/servidor:
-- en el API estándar 3.3.5a es una ÉPOCA absoluta (segundos Unix); en este
-- servidor (UltimoWoW) es un OFFSET relativo de segundos restantes (SavedInstances
-- hace `expires + time()`). Se DETECTA el formato y se devuelven los segundos
-- restantes hasta el reinicio, o nil si no hay reloj válido (expires 0,
-- negativo o ya pasado) — elimina el bug de la "época 0" y las fechas sin
-- sentido.
function Instances:ResolveReset(expires, now)
    if type(expires) ~= "number" or expires <= 0 then return nil end
    local remaining
    if expires > 1e8 then
        -- Época absoluta real (>= ~1973): el reinicio menos el ahora.
        remaining = expires - now
    else
        -- Offset relativo: el reinicio está a `expires` segundos.
        remaining = expires
    end
    if remaining <= 0 then return nil end
    return remaining
end

-- Etiqueta corta de dificultad: "25H" / "10" / "5H" / "40" / "N". PRIORIZA el
-- diffname localizado del API (este servidor lo devuelve), derivando el tamaño
-- (5/10/25/40) y el sufijo heroico; si no hay diffname, usa un mapa
-- CONSERVADOR de diff+raid solo con valores inequívocos (no pintar un tamaño
-- de banda erróneo). nil => sin etiqueta.
local RAID_DIFF_FALLBACK = { [3] = "25", [5] = "25H", [6] = "40", [9] = "40" }
local DUNGEON_DIFF_FALLBACK = { [1] = "5" }
function Instances:DifficultyTag(diff, raid, diffname)
    if diffname and diffname ~= "" then
        local n = diffname:match("(%d+)")
        local hero = (diffname:lower():find("hero", 1, true) ~= nil)
        if n then
            return n .. (hero and "H" or "")
        end
        if hero then return "H" end
        if diffname:find("Normal", 1, true) or diffname:find("Normale", 1, true) then
            return "N"
        end
    end
    if type(diff) == "number" then
        if raid then
            local t = RAID_DIFF_FALLBACK[diff]
            if t then return t end
        end
        local t = DUNGEON_DIFF_FALLBACK[diff]
        if t then return t end
    end
    return nil
end

-- Texto de cuenta atrás: "2d 4h" / "5h 20m" / "12m" / "ahora".
function Instances:FormatRemaining(secs)
    secs = math.floor(tonumber(secs) or 0)
    if secs <= 0 then return "ahora" end
    local days = math.floor(secs / 86400)
    local hours = math.floor((secs % 86400) / 3600)
    local mins = math.floor((secs % 3600) / 60)
    if days > 0 then
        if hours > 0 then return string.format("%dd %dh", days, hours) end
        return string.format("%dd", days)
    end
    if hours > 0 then
        if mins > 0 then return string.format("%dh %dm", hours, mins) end
        return string.format("%dh", hours)
    end
    return string.format("%dm", math.max(1, mins))
end

-- Tope de seguridad para la enumeración (el API termina con nil; el cap evita
-- bucear sin límite en clientes raros).
local MAX_INSTANCES = 60

-- Enumeración de TODAS las instancias guardadas (con y sin reloj): se lee
-- GetSavedInstanceInfo hasta que devuelva nil, NO GetNumSavedInstances (el
-- contador coincide siempre con la lista). Leemos los 10 retornos de este
-- cliente (diffname y raid incluidos); un cliente estándar de 5 retornos deja
-- los extras en nil y el código los tolera. Compartido por la sección, los
-- tooltips y el export del registro.
--   rem     = segundos restantes hasta el reinicio (nil sin reloj)
--   resetAt = época ABSOLUTA del reinicio (nil sin reloj): la firma que viaja
--             al portal, donde la cuenta atrás se recalcula contra savedAt.
function Instances:Collect(now)
    now = now or self:Now()
    local entries = {}
    for i = 1, MAX_INSTANCES do
        local name, id, expires, diff, locked, extended, mostsig, raid, players, diffname =
            GetSavedInstanceInfo(i)
        if not name or name == "" then break end
        local rem
        if locked then
            rem = self:ResolveReset(expires, now)
        end
        entries[#entries + 1] = {
            name = name,
            id = id,
            rem = rem,
            resetAt = rem and (now + rem) or nil,
            extended = extended and true or false,
            tag = self:DifficultyTag(diff, raid, diffname),
            locked = locked and true or false,
        }
    end
    return entries
end

-- Separa instancias con reloj pendiente del resto y las ordena: con reloj
-- primero por el más próximo (desempate por nombre; table.sort en Lua 5.1 NO
-- es estable), el resto después por nombre.
function Instances:Split(entries)
    local pending, free = {}, {}
    for _, e in ipairs(entries or {}) do
        if e.rem then pending[#pending + 1] = e else free[#free + 1] = e end
    end
    table.sort(pending, function(a, b)
        if a.rem ~= b.rem then return a.rem < b.rem end
        return a.name < b.name
    end)
    table.sort(free, function(a, b) return a.name < b.name end)
    return pending, free
end

-- Proyección ACOTADA para el contrato SV del portal (AGENTS.md §14): solo
-- nombre, dificultad, reinicio absoluto y el flag de reinicio suspendido; sin
-- ids internos, sin estado de bloqueo y sin datos locales. Los campos nil se
-- omiten (el portal los trata como ausentes). Devuelve SIEMPRE una lista (posiblemente
-- vacía) para que un re-registro sin instancias limpie lo publicado.
function Instances:Export(now)
    local entries = self:Collect(now or self:Now())
    local out = {}
    for _, e in ipairs(entries) do
        local item = { name = e.name }
        if e.tag then item.difficulty = e.tag end
        if e.resetAt then item.resetAt = e.resetAt end
        if e.extended then item.extended = true end
        out[#out + 1] = item
    end
    return out
end

RD.utils.instances = Instances
return Instances
