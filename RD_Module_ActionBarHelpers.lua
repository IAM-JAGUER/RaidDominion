--[[
    RD_Module_ActionBarHelpers.lua
    PROPÓSITO: Helpers internos puros del módulo de barra de acciones
              (RD_Module_ActionBar.lua), extraídos en la ronda 8 de refactor:
              temporizador DBM (FireBarTimer/FireDbmNotice), estado de grupo
              (InRaid/InParty), limpieza de nombres (CleanName), marcadores de
              raid (ClearAllRaidIcons), enlace de Discord (GetDiscordLink) y la
              cuenta regresiva del pull (StartPullCountdown). Sin frames ni
              handlers: la lógica de cada acción vive en el padre.
    API PÚBLICA:
        - RD.modules.actionBarHelpers.FireBarTimer(actionId, seconds)
        - RD.modules.actionBarHelpers.FireDbmNotice(message, seconds)
        - RD.modules.actionBarHelpers.InRaid() / InParty()
        - RD.modules.actionBarHelpers.CleanName(name)
        - RD.modules.actionBarHelpers.ClearAllRaidIcons()
        - RD.modules.actionBarHelpers.GetDiscordLink()
        - RD.modules.actionBarHelpers.StartPullCountdown(seconds)
    ORDEN: cargar ANTES de RD_Module_ActionBar.lua (ver RaidDominion.toc); el
           padre los alía como upvalues locales al cargar.
    EVENTOS: Ninguno.
]]

local addonName, private = ...
local RD = _G.RaidDominion or {}
_G.RaidDominion = RD

local Helpers = {}

-- Temporizador DBM de la barra: dispara la cuenta atrás correspondiente a la
-- acción SOLO cuando esta realmente se ejecuta (tras guardas y tras confirmar
-- los popups Sí/No/Cancelar). Cada handler invoca con su propio actionId; las
-- acciones de clic derecho tienen entrada propia en DBM_TIMERS. `seconds`
-- (opcional) fuerza el tiempo fijado por el usuario en el diálogo (check/pull).
function Helpers.FireBarTimer(actionId, seconds)
    local t = RD.modules and RD.modules.dbmTimer
    if t and t.FireForAction then
        t:FireForAction(actionId, seconds)
    end
end

-- Aviso puntual de gestión (clic/interacción con popup) como barra DBM fija, en
-- lugar del broadcast por el canal de líder (RW). Solo cambios de estado útiles
-- para gestionar la banda; los conteos y la información (enlaces, listas de
-- nombres) siguen por el canal configurado.
function Helpers.FireDbmNotice(message, seconds)
    local t = RD.modules and RD.modules.dbmTimer
    if t and t.Notice then
        t:Notice(message, seconds)
    end
end

function Helpers.InRaid() return GetNumRaidMembers() ~= 0 end
function Helpers.InParty() return GetNumPartyMembers() > 0 end

function Helpers.CleanName(name)
    if RD.UIUtils and RD.UIUtils.CleanName then
        return RD.UIUtils.CleanName(name)
    end
    return string.lower(tostring(name or ""))
end

-- Limpia TODOS los iconos de marcado de la banda. En 3.3.5a NO existe
-- ClearAllRaidIcons (llegó en Cataclysm) ni se garantiza ClearRaidTargetIcon;
-- la forma fiable de retirar un marcador es SetRaidTarget(unit, 0) (índice 0 =
-- sin icono), el mismo API con el que se colocan.
function Helpers.ClearAllRaidIcons()
    for i = 1, GetNumRaidMembers() do
        if SetRaidTarget then
            SetRaidTarget("raid" .. i, 0)
        end
    end
end

function Helpers.GetDiscordLink()
    return (RD.config and RD.config.Get and RD.config:Get("chat.discordLink", "")) or ""
end

-- Abrevia cifras grandes para el chat (p.ej. vida/maná de un boss): un decimal y
-- sufijo k/M, sin el ".0" sobrante. < 1000 se deja tal cual.
--   16300 -> "16.3k"   5000 -> "5k"   163000 -> "163k"
--   2200000 -> "2.2M"  999 -> "999"   nil/0 -> "0"
function Helpers.AbbreviateNumber(value)
    local n = tonumber(value) or 0
    local suffix, scaled = nil, n
    if n >= 1000000 then
        suffix, scaled = "M", n / 1000000
    elseif n >= 1000 then
        suffix, scaled = "k", n / 1000
    end
    if suffix then
        local text = string.format("%.1f", scaled):gsub("%.0$", "")
        return text .. suffix
    end
    return string.format("%d", n)
end

-- Lanza el conteo por chat y devuelve el número de segundos EFECTIVO usado
-- (clamp 1..30); el DBM acompaña con ese mismo tiempo fijado.
function Helpers.StartPullCountdown(seconds)
    local mm = RD.modules and RD.modules.messageManager
    if not mm then return end
    local n = tonumber(seconds) or 10
    if n < 1 then n = 1 end
    if n > 30 then n = 30 end
    -- Canal por defecto (GetChannel): config DEFAULT + líder de banda => RAID_WARNING.
    local ch = mm:GetChannel()
    -- Primer mensaje: "= PULL DE Ns INICIADO POR <JUGADOR> =" (nombre en
    -- mayúsculas). Cada mensaje se programa a su SEGUNDO EXACTO respecto al
    -- inicio del pull (contador interno): el anuncio en t=0, el primer tick en
    -- t=1, y los puntos clave 5/3/2/1 cuando faltan 5/3/2/1 segundos (t=N-s);
    -- cierra con "¡PULL AHORA!" en t=N. Así no se llena el warning con alertas.
    local pName = UnitName("player") or ""
    local playerName = (pName ~= "" and strupper(pName)) or "?"
    local plan = {}
    local function At(second, text)
        plan[#plan + 1] = { second = second, text = text }
    end
    At(0, string.format("= PULL DE %ds INICIADO POR %s =", n, playerName))
    if n > 1 then
        At(1, tostring(n - 1) .. "...")
    end
    for _, s in ipairs({ 5, 3, 2, 1 }) do
        if s < n - 1 then
            At(n - s, tostring(s) .. "...")
        end
    end
    At(n, "¡PULL AHORA!")

    for _, p in ipairs(plan) do
        mm:Schedule(p.second, function()
            mm:SendMessage(p.text, ch)
        end)
    end
    return n
end

RD.modules = RD.modules or {}
RD.modules.actionBarHelpers = Helpers
return Helpers