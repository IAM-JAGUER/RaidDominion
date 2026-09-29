--[[
    RD_Module_DBMTimer.lua
    PROPÓSITO: Replica el comando "broadcast timer" de la v2 para mostrar una
              barra de cuenta atrás de DBM (ayuda visual para la banda) al
              ejecutar las acciones de la barra inferior del menú flotante.
              Se controla desde Configuración > General > Temporizador DBM
              (checkbox maestro) y cada mensaje es personalizable por acción
              en el panel de su icono (barra inferior de la configuración,
              dbm.messages.<acción>).
    API PÚBLICA:
        - RD.modules.dbmTimer:SafeDBMCommand(command)
        - RD.modules.dbmTimer:Broadcast(seconds, message)
        - RD.modules.dbmTimer:FireForAction(actionId, secondsOverride)
        - RD.modules.dbmTimer:Notice(message, seconds)
    EVENTOS: Ninguno directo. Se consume en los handlers de RD_Module_ActionBar
             (FireForAction) en el punto exacto donde cada acción se ejecuta, de
             modo que los popups Sí/No/Cancelar y el clic derecho (que tiene su
             propio actionId) acompañan la barra real de la acción.
]]

local addonName, private = ...
local RD = _G.RaidDominion or {}
_G.RaidDominion = RD

local DBMTimer = {}

-- Icono fijo de la barra de cuenta atrás (igual que la v2)
local BAR_ICON = "Interface\\Icons\\Spell_Nature_WispSplode"

-- Devuelve si DBM está "presente" a nivel global (sin tocar _G en pcall).
-- Solo se leen tablas globales: si el addon no está instalado, son nil.
local function HasDBM()
    return (type(DBM) == "table" or type(DBM) == "userdata")
end

-- Escala un mensaje a MAYÚSCULAS limitado a un ancho razonable para la barra.
local function NormalizeMessage(message)
    return tostring(message or ""):upper()
end

-- Ejecuta el comando equivalente a la v2 de forma segura (pcall) y en orden de
-- disponibilidad: DBT:StartBar -> DBM.Bars:CreateBar -> DBM:CreatePizzaTimer.
-- Devuelve true si se llegó a mostrar una barra.
function DBMTimer:SafeDBMCommand(command)
    if not command or command == "" then return false end
    if not HasDBM() then
        return false
    end
    local ok, res = pcall(function()
        if command:match("^broadcast timer") then
            local timeStr, message = command:match("broadcast timer (%d+:%d+) (.+)")
            if timeStr and message then
                local minutes, seconds = timeStr:match("(%d+):(%d+)")
                local totalSeconds = (tonumber(minutes) or 0) * 60 + (tonumber(seconds) or 0)
                if DBT and DBT.StartBar then
                    DBT:StartBar(totalSeconds, message, BAR_ICON)
                    return true
                elseif DBM.Bars and DBM.Bars.CreateBar then
                    DBM.Bars:CreateBar(totalSeconds, message, BAR_ICON)
                    return true
                elseif DBM.CreatePizzaTimer then
                    DBM:CreatePizzaTimer(totalSeconds, message, true)
                    return true
                end
            end
        end
        return false
    end)
    return ok and res
end

-- Lanza una barra de cuenta atrás de DBM con el formato "broadcast timer m:ss"
-- de la v2. seconds se clampa a >= 1; message vacío desactiva la barra.
function DBMTimer:Broadcast(seconds, message)
    local secs = math.max(1, math.floor(tonumber(seconds) or 10))
    local text = NormalizeMessage(message)
    if text == "" then return false end
    local minutes = math.floor(secs / 60)
    local rest = secs % 60
    local timeStr = string.format("%d:%02d", minutes, rest)
    return self:SafeDBMCommand("broadcast timer " .. timeStr .. " " .. text)
end

-- Devuelve la config del temporizador para una acción de la barra, o nil.
local function GetEnv()
    if not RD.config or not RD.config.Get then return nil end
    local enabled = RD.config:Get("dbm.enabled", true)
    if not enabled then return nil end
    return RD.config
end

-- Ejecuta el temporizador correspondiente a una acción de la barra inferior.
-- Se invoca desde cada handler de RD_Module_ActionBar en el punto de ejecución
-- real (tras guardas y tras confirmar los popups), cubriendo también el clic
-- derecho (cada actionRight tiene entrada propia en DBM_TIMERS). Los mensajes
-- default viven en DBM_TIMERS. Si se pasa secondsOverride (> 0), la barra usa
-- ese tiempo (el fijado por el usuario en el diálogo) en vez del default.
function DBMTimer:FireForAction(actionId, secondsOverride)
    local config = GetEnv()
    if not config then return false end
    local timers = (RD.constants and RD.constants.DBM_TIMERS) or {}
    for _, timer in ipairs(timers) do
        if timer.action == actionId then
            local message = config:Get("dbm.messages." .. actionId, timer.message)
            if message == nil or message == "" then return false end
            local seconds = (tonumber(secondsOverride) or 0) > 0 and secondsOverride or timer.seconds
            return self:Broadcast(seconds, message)
        end
    end
    return false
end

-- Aviso puntual de gestión (clic/interacción con popup) con mensaje FIJO y corto:
-- barra DBM que sustituye al broadcast por el canal de líder (RW) en los avisos
-- de estado del flujo (p.ej. "¿QUE FALTA?", "FIJANDO PULL", "PULL CANCELADO").
-- No pasa por la configuración por acción (a diferencia de FireForAction): el
-- mensaje se da al llamar. Solo se emite si DBM está habilitado (dbm.enabled).
-- `seconds` por defecto 10 (como la v2). Devuelve lo de Broadcast.
function DBMTimer:Notice(message, seconds)
    local config = GetEnv()
    if not config then return false end
    return self:Broadcast(seconds or 10, message)
end

RD.modules = RD.modules or {}
RD.modules.dbmTimer = DBMTimer
return DBMTimer