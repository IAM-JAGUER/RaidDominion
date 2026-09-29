--[[
    RD_Module_LootCore.lua
    PROPÓSITO: Núcleo lógico del gestor de botín (RD.modules.lootCore): estado
              compartido, constantes, parseo de dados localizado
              (RANDOM_ROLL_RESULT), resolución de nombres de jugador, rareza de
              ítems, historial de la banda (registro por día y agrupación por
              ítem) y lógica de empates/ordenación de dados. Sin frames ni
              dependencias de UI: el countdown, el loop OnUpdate, el spameo de
              botín y las ventanas viven en RD_Module_Loot.lua.
    API PÚBLICA:
        - RD.modules.lootCore.state                -- tabla de estado compartida
        - RD.modules.lootCore:HasTie() / GetTiedPlayers() / SortRolls() / DidRoll(name)
        - RD.modules.lootCore:LogItem(...) / LogRoll(...) / GetHistory()
        - RD.modules.lootCore:GetDailyHistory() / GroupByItem(records)
        - RD.modules.lootCore:GetRollPattern() / ResolveRollName(player)
        - RD.modules.lootCore:GetItemRarity(itemLink) / RollTypeLabel(rollType)
        - RD.modules.lootCore:InvalidateCountdown() / Publish(event, ...)
        - RD.modules.lootCore.DEFAULT_COUNTDOWN / MAX_COUNTDOWN
    EVENTOS: Publica LOOT_HISTORY_ADDED (LogItem/LogRoll).
]]

local addonName, private = ...
local RD = _G.RaidDominion or {}
_G.RaidDominion = RD

local LootCore = {}

-- Tipos de roll (main / dual / enchant)
local ROLL_MAIN = 1
local ROLL_DUAL = 2
local ROLL_ENCHANT = 3

-- Duración por defecto de la ventana de dados (segundos)
LootCore.DEFAULT_COUNTDOWN = 20

-- Límite máximo permitido de la ventana de dados (segundos). En banda de 40
-- nadie tira en 10 s; se alinea con el tope del ready check (60 s).
LootCore.MAX_COUNTDOWN = 60

-- Estado interno (compartido con RD_Module_Loot.lua vía LootCore.state)
local state = {
    itemName = "",
    itemLink = nil,
    itemTexture = nil,
    itemCount = 1,
    itemRarity = 0,
    rollType = ROLL_MAIN,
    rolls = {},          -- { { name = "X", roll = 87 }, ... }
    rolled = false,      -- si el jugador local ya tiró
    canRoll = true,      -- si se aceptan más dados
    recording = false,   -- si se están registrando dados
    countdown = 0,       -- tiempo restante (0 = sin countdown activo)
    countdownActive = false,
    token = 0,           -- contador anti-stale para avisos programados del conteo
    winner = nil,
    winnerRoll = nil,    -- dado final del ganador (incluye tiros de desempate)
    history = {},        -- registro persistente de ítems asignados
    announced = false,
    -- Estado del desempate por empate en el dado más alto
    duel = false,        -- si hay una ronda de desempate activa
    duelPlayers = {},    -- nombres de los jugadores que deben desempatar
    duelRolls = {},      -- tiros de la ronda de desempate { { name, roll } }
}
LootCore.state = state

-- Publica un evento en el bus (RD.events) si está disponible.
local function Publish(event, ...)
    if RD.events and RD.events.Publish then
        RD.events:Publish(event, ...)
    end
end
LootCore.Publish = Publish

-- Patrón de dados localizado: convierte RANDOM_ROLL_RESULT (formato printf del
-- cliente, p.ej. "%s rolls %d (%d-%d)" o la variante esMX) a un patrón Lua.
-- Replica la conversión de LibDeformat que usa KRT pero sin librerías externas:
-- escapa los caracteres mágicos y sustituye %s → (.-) y %d → (%d+). Sin esto,
-- el parseo hardcodeado en inglés fallaba en clientes no enUS (esMX) y no se
-- registraban los dados.
local rollPattern
function LootCore:GetRollPattern()
    if rollPattern then return rollPattern end
    local fmt = _G.RANDOM_ROLL_RESULT or "%s rolls %d (%d-%d)"
    local p = fmt:gsub("([%(%)%.%+%-%[%]%?%^%$%%%*])", "%%%1")
    p = p:gsub("%%%%s", "(.-)"):gsub("%%%%d", "(%%d+)")
    rollPattern = "^" .. p .. "$"
    return rollPattern
end

-- Resuelve el nombre del jugador del mensaje de dado: quita el hipervínculo de
-- jugador (si el cliente lo incluye) y mapea el pronombre de primera persona
-- del propio jugador ("You"/"Tú" según el cliente) al nombre real, para no
-- registrar un dado bajo el pronombre.
function LootCore:ResolveRollName(player)
    if not player then return nil end
    local me = UnitName("player") or ""
    if player == me then return me end
    player = player:gsub("|Hplayer:[^|]+|h([^|]+)|h", "%1")
    if player == me then return me end
    local selfRefs = {
        ["You"] = true, ["you"] = true,
        ["Tú"] = true, ["tú"] = true, ["Tu"] = true, ["tu"] = true,
        ["Du"] = true, ["du"] = true, ["Vous"] = true, ["vous"] = true,
    }
    if selfRefs[player] then return me end
    return player
end

-- Etiqueta de tipo de dados para anuncios. Mismo rótulo que la ventana de
-- botín (Main/Dual/Enchant): antes el chat decía MainSpec/DualSpec y la UI Main/
-- Dual, dos nombres para lo mismo.
local ROLL_TYPE_LABEL = { [1] = "Main", [2] = "Dual", [3] = "Enchant" }
function LootCore:RollTypeLabel(rollType)
    return ROLL_TYPE_LABEL[rollType] or "Main"
end

-- Invalida los avisos programados del conteo en curso (cualquier reinicio de
-- dados, cierre o declaración cancela los ticks pendientes de la cuenta vieja).
function LootCore:InvalidateCountdown()
    state.token = state.token + 1
end

-- ¿Hay empate en el dado más alto de la ronda principal? Si lo hay no se
-- auto-declara ganador: queda pendiente un desempate o una elección manual.
local function HasTie()
    if #state.rolls < 2 then return false end
    return state.rolls[1].roll == state.rolls[2].roll
end

function LootCore:HasTie()
    return HasTie()
end

-- Ordena los dados de mayor a menor (desempate por nombre) y, si no hay
-- empate en el dado más alto, fija al ganador automáticamente. Si HAY empate
-- se limpia el ganador (venía auto-asignado del dado anterior cuando aún no
-- había empate): si no, la UI mostraba un ★ y "Declarar ganador" quedaba
-- habilitado, y AnnounceWinner declaraba al empatado sin desempate.
local function SortRolls()
    if #state.rolls > 0 then
        table.sort(state.rolls, function(a, b)
            if a.roll == b.roll then
                return a.name < b.name
            end
            return a.roll > b.roll
        end)
        if not HasTie() then
            state.winner = state.rolls[1].name
            state.winnerRoll = nil
        else
            state.winner = nil
            state.winnerRoll = nil
        end
    end
end
LootCore.SortRolls = SortRolls

-- Nombres de los jugadores que comparten el dado más alto (los que deben
-- desempatar). Vacío si no hay empate.
function LootCore:GetTiedPlayers()
    local tied = {}
    if #state.rolls < 2 then return tied end
    local top = state.rolls[1].roll
    for _, r in ipairs(state.rolls) do
        if r.roll == top then
            tied[#tied + 1] = r.name
        end
    end
    return tied
end

-- ¿El jugador ya tiró en la ronda principal?
function LootCore:DidRoll(name)
    for _, r in ipairs(state.rolls) do
        if r.name == name then
            return true
        end
    end
    return false
end

-- Parse del rarity desde el color del itemLink (|cffffffff → 1, |cff0070dd → 4, ...)
function LootCore:GetItemRarity(itemLink)
    -- Guardia defensiva: algunos flujos de la UI (p.ej. GetCursorInfo item sin
    -- link completo o arrastres parciales) pueden llegar con itemLink nil.
    if not itemLink or itemLink == "" then return 0 end
    local r = itemLink:match("|cff(%x%x%x%x%x%x)")
    if not r then return 0 end
    local map = {
        ["9d9d9d"] = 0, ["ffffff"] = 1, ["1eff00"] = 2, ["0070dd"] = 3,
        ["a335ee"] = 4, ["ff8000"] = 5, ["e6cc80"] = 6,
    }
    return map[r:lower()] or 0
end

-- ==================== Historial de la banda ====================

-- Clave de día local (YYYY-MM-DD) para agrupar el historial por jornada.
local function TodayKey()
    return date("%Y-%m-%d")
end

-- Registra un ítem en el historial de la banda (lo obtiene un jugador)
function LootCore:LogItem(playerName, itemLink, rollType, rollValue)
    table.insert(state.history, {
        day = TodayKey(),
        event = "item",
        player = playerName,
        itemLink = itemLink,
        rollType = rollType,
        rollValue = rollValue,
        time = GetTime(),
    })
    Publish("LOOT_HISTORY_ADDED", state)
end

-- Registra un dado lanzado en el historial de la banda (por día). Se llama desde
-- CHAT_MSG_SYSTEM cuando se captura un dado del jugador local o de la banda.
function LootCore:LogRoll(playerName, roll)
    if not playerName or not roll then return end
    table.insert(state.history, {
        day = TodayKey(),
        event = "roll",
        player = playerName,
        roll = tonumber(roll),
        itemLink = state.itemLink,
        time = GetTime(),
    })
    Publish("LOOT_HISTORY_ADDED", state)
end

-- Devuelve el historial de botín de la banda
function LootCore:GetHistory()
    return state.history
end

-- Devuelve el historial agrupado por día (tabla { [dia] = { registros } }).
-- Los días se ordenan de más reciente a más antiguo.
function LootCore:GetDailyHistory()
    local groups = {}
    local order = {}
    for _, e in ipairs(state.history) do
        local day = e.day or TodayKey()
        if not groups[day] then
            groups[day] = {}
            order[#order + 1] = day
        end
        groups[day][#groups[day] + 1] = e
    end
    -- Días de más reciente a más antiguo (el formato YYYY-MM-DD ordena como string)
    table.sort(order, function(a, b) return a > b end)
    return groups, order
end

-- Agrupa una lista de registros (p.ej. los de un día) POR ÍTEM: cada ítem
-- agrupa sus dados (rolls) y al ganador (la entrega del ítem). Devuelve una
-- lista de { itemLink, rolls = { {player, roll}, ... }, winner, winnerRoll,
-- rollType }. Los registros comparten itemLink (los dados se registran con el
-- ítem actual y la entrega con el ítem ganado), lo que permite juntarlos.
function LootCore:GroupByItem(records)
    local items = {}
    local order = {}
    for _, e in ipairs(records or {}) do
        local link = e.itemLink or ""
        if link ~= "" then
            if not items[link] then
                items[link] = { itemLink = link, rolls = {}, winner = nil, winnerRoll = nil, rollType = nil }
                order[#order + 1] = link
            end
            local it = items[link]
            if e.event == "roll" then
                it.rolls[#it.rolls + 1] = { player = e.player, roll = e.roll }
            elseif e.event == "item" then
                it.winner = e.player
                it.winnerRoll = e.rollValue
                it.rollType = e.rollType
            end
        end
    end
    local result = {}
    for _, link in ipairs(order) do
        result[#result + 1] = items[link]
    end
    return result
end

RD.modules = RD.modules or {}
RD.modules.lootCore = LootCore
return LootCore