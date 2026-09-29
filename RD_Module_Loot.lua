--[[
    RD_Module_Loot.lua
    PROPÓSITO: Motor de gestión de botín (estilo KRT). Lleva registro de los ítems
              obtenidos en el transcurso de la banda, permite seleccionar un ítem
              (desde el botín abierto del boss o arrastrado de la bolsa), abrir
              dados por main/dual/enchant dentro de un tiempo límite, llevar el
              registro de los dados de la banda, declarar al ganador, spamear el
              botín del boss caído y limpiar el estado. Sin C_Timer: frame
              OnUpdate persistente para el countdown de los dados.
    API PÚBLICA:
        - RD.modules.loot:SetItem(itemLink, count)
        - RD.modules.loot:StartRoll(rollType) / Roll() / RecordRolls(bool)
        - RD.modules.loot:GetRolls() / HighestRoll() / GetWinner() / SetWinner(name)
        - RD.modules.loot:GetTiedPlayers() / HasTie() / StartDuel() / ResolveDuel()
        - RD.modules.loot:AnnounceWinner() / SpamLoot() / AnnounceRoll(name) / Clear()
        - RD.modules.loot:SetRollType(main|dual|enchant)
        - RD.modules.loot:IsMasterLooter()
        - RD.modules.loot:GetBossLootLinks() / MasterCandidateIndex(slot) / CollectItems()
        - RD.modules.loot:GetHistory() / GetDailyHistory() / GroupByItem(records)
        - RD.modules.loot:GetState()  -- para la UI
    EVENTOS: Publica LOOT_ITEM_ADDED, LOOT_ROLL_ADDED, LOOT_ROLL_CLEARED,
             LOOT_WINNER_SET, LOOT_STATE_CHANGED (para refrescar la UI).
    DEPENDENCIA: el núcleo lógico (estado, historial, parseo de dados) vive en
                 RD_Module_LootCore.lua (RD.modules.lootCore), que debe cargarse
                 antes que este archivo (orden en RaidDominion.toc).
]]

local addonName, private = ...
local RD = _G.RaidDominion or {}
_G.RaidDominion = RD

local LootCore = assert(RD.modules.lootCore, "RD_Module_LootCore.lua debe cargarse antes que RD_Module_Loot.lua")

local Loot = {}

-- Estado compartido con el núcleo (RD_Module_LootCore.lua)
local state = LootCore.state

-- Constantes del núcleo (duración/límite de la ventana de dados)
local DEFAULT_COUNTDOWN = LootCore.DEFAULT_COUNTDOWN
local MAX_COUNTDOWN = LootCore.MAX_COUNTDOWN

-- Helpers del núcleo reutilizados aquí. Solo se aliasan los que LootCore
-- exporta como FUNCIÓN PLANA (definidas con `.`, sin `self`): Publish y
-- SortRolls. Los métodos con dos puntos (GetRollPattern, ResolveRollName,
-- RollTypeLabel, InvalidateCountdown, HasTie, DidRoll, GetItemRarity) se
-- invocan SIEMPRE como `LootCore:Metodo(...)` — aliasarlos como función simple
-- hacía que el argumento real entrara como `self` y el parámetro llegara nil
-- (p.ej. ResolveRollName devolvía nil y ningún dado se registraba).
local Publish = LootCore.Publish
local SortRolls = LootCore.SortRolls

local function System(msg)
    if RD.messageManager and RD.messageManager.SendSystemMessage then
        RD.messageManager:SendSystemMessage(msg)
    end
end

-- Anuncia por la SALIDA POR DEFECTO (chat.channel, vía MessageManager) con
-- troceado automático para mensajes largos. Los modos de dados, el ganador y
-- el spameo de botín salen por aquí, como el addon base (KRT).
local function AnnounceDefault(msg)
    local mm = RD.modules and RD.modules.messageManager
    if mm and mm.SendMessage then
        mm:SendMessage(tostring(msg or ""), mm:GetChannel())
    end
end

-- Plan de avisos del conteo de dados por la salida por defecto, con el mismo
-- ritmo que el conteo de pull/ready check: primer tick (N-1s...), "5s...
-- ¡TIREN AHORA!", luego 3s..., 2s..., 1s... Los avisos se programan con
-- mm:Schedule (sin C_Timer) y se guardan con el token de la cuenta atrás para
-- que un reinicio/cancelación los invalide.
local function ScheduleCountdownAnnouncements(limit)
    local mm = RD.modules and RD.modules.messageManager
    if not mm then return end
    local token = state.token
    local plan = {}
    local function At(second, text)
        plan[#plan + 1] = { second = second, text = text }
    end
    local hasFive = (limit - 1) >= 5
    -- Con n=6 el primer tick sería "5s..." y chocaría con el "5s... ¡TIREN
    -- AHORA!" combinado (n-5=1): se omite el suelto.
    if limit > 1 and not (hasFive and limit - 5 == 1) then
        At(1, tostring(limit - 1) .. "s...")
    end
    if hasFive then
        At(limit - 5, "5s... ¡TIREN AHORA!")
    end
    for _, s in ipairs({ 3, 2, 1 }) do
        if s < limit - 1 then
            At(limit - s, tostring(s) .. "s...")
        end
    end
    if not hasFive then
        At(limit, "¡TIREN AHORA!")
    end
    for _, p in ipairs(plan) do
        mm:Schedule(p.second, function()
            -- Solo se emite si sigue activo EL MISMO conteo (token) y la cuenta
            -- no se cerró antes (un StartRoll nuevo o ClearRolls invalidan).
            if state.token == token and state.countdownActive and state.countdown > 0 then
                AnnounceDefault(p.text)
            end
        end)
    end
end

-- Comprueba si el jugador local es el maestro despojador (para auto-capturar el
-- botín del boss). Compatible 3.3.5a: GetLootMethod() devuelve método, índice
-- de party y de raid; el jugador local es el maestro cuando partyID == 0.
function Loot:IsMasterLooter()
    local method, partyID = GetLootMethod()
    if not method or method ~= "master" then return false end
    return (partyID and partyID == 0)
end

-- ==================== API delegada al núcleo ====================
-- La lógica de empates, historial y agrupación vive en RD_Module_LootCore.lua;
-- estos wrappers preservan la API pública de RD.modules.loot.

-- ¿Hay empate en el dado más alto de la ronda principal?
function Loot:HasTie()
    return LootCore:HasTie()
end

-- Nombres de los jugadores que comparten el dado más alto (los que deben
-- desempatar). Vacío si no hay empate.
function Loot:GetTiedPlayers()
    return LootCore:GetTiedPlayers()
end

-- Registra un ítem en el historial de la banda (lo obtiene un jugador)
function Loot:LogItem(playerName, itemLink, rollType, rollValue)
    return LootCore:LogItem(playerName, itemLink, rollType, rollValue)
end

-- Registra un dado lanzado en el historial de la banda (por día)
function Loot:LogRoll(playerName, roll)
    return LootCore:LogRoll(playerName, roll)
end

-- Devuelve el historial de botín de la banda
function Loot:GetHistory()
    return LootCore:GetHistory()
end

-- Devuelve el historial agrupado por día (tabla { [dia] = { registros } }).
-- Los días se ordenan de más reciente a más antiguo.
function Loot:GetDailyHistory()
    return LootCore:GetDailyHistory()
end

-- Agrupa una lista de registros (p.ej. los de un día) POR ÍTEM
function Loot:GroupByItem(records)
    return LootCore:GroupByItem(records)
end

-- ==================== Gestión de ítem ====================

-- Fija el ítem actual (desde el botín del boss o arrastrado de la bolsa)
function Loot:SetItem(itemLink, count)
    if not itemLink or itemLink == "" then return false end
    local itemName = GetItemInfo(itemLink) or itemLink:match("%[([^%]]+)%]") or itemLink
    local itemTexture = select(10, GetItemInfo(itemLink)) or "Interface\\PaperDoll\\UI-Backpack-EmptySlot"
    state.itemName = itemName
    state.itemLink = itemLink
    state.itemTexture = itemTexture
    state.itemCount = tonumber(count) or 1
    state.itemRarity = LootCore:GetItemRarity(itemLink)
    -- Nuevo ítem: reinicia los dados
    self:ClearRolls()
    Publish("LOOT_ITEM_ADDED", state)
    return true
end

-- Devuelve una copia del estado (para la UI)
function Loot:GetState()
    return state
end

-- Devuelve el ítem actual
function Loot:GetItem()
    if not state.itemLink then return nil end
    return state
end

-- ==================== Dados (rolls) ====================

-- Inicia una ventana de dados para el ítem actual con un tipo dado. Anuncia el
-- modo por la salida por defecto (estilo KRT: "Dados Main por: <ítem>") y
-- programa los avisos del conteo con el mismo ritmo que el conteo de pull.
function Loot:StartRoll(rollType)
    if not state.itemLink then return false end
    state.rollType = rollType
    self:ClearRolls()
    state.recording = true
    state.canRoll = true
    state.announced = false
    local limit = DEFAULT_COUNTDOWN
    if RD.config and RD.config.Get then
        limit = RD.config:Get("loot.rollTimeLimit", DEFAULT_COUNTDOWN)
    end
    limit = tonumber(limit) or DEFAULT_COUNTDOWN
    -- El límite no puede superar MAX_COUNTDOWN (60 s): saneo de configs
    -- heredadas que guardaron valores mayores (la pestaña de config ya no
    -- permite ese campo; el gestor de botín lo controla al escribir).
    if limit > MAX_COUNTDOWN then limit = MAX_COUNTDOWN end
    LootCore:InvalidateCountdown()
    state.countdown = limit
    state.countdownActive = true
    -- Asegura que el loop del countdown corra: el frame se auto-oculta al
    -- terminar una cuenta atrás y hay que volver a mostrarlo en cada una nueva;
    -- sin esto el countdown quedaba congelado y los dados nunca se cerraban.
    self:ShowLoop()
    -- Anuncio del modo por la salida por defecto (KRT: ChatRollMS/OS/Free).
    local modeMsg = string.format("Dados %s por: %s", LootCore:RollTypeLabel(rollType), state.itemLink)
    if state.itemCount and state.itemCount > 1 then
        modeMsg = modeMsg .. string.format(" x%d", state.itemCount)
    end
    AnnounceDefault(modeMsg)
    ScheduleCountdownAnnouncements(limit)
    Publish("LOOT_STATE_CHANGED", state)
    return true
end

-- Establece el tipo de roll (main/dual/enchant) sin abrir ventana
function Loot:SetRollType(rollType)
    state.rollType = rollType
end

-- El jugador local tira sus propios dados (RandomRoll 1-100)
function Loot:Roll()
    if not state.recording or state.rolled then return end
    RandomRoll(1, 100)
    state.rolled = true
    Publish("LOOT_STATE_CHANGED", state)
end

-- Activa/desactiva el registro de dados
function Loot:RecordRolls(bool)
    state.canRoll = (bool == true)
    state.recording = (bool == true)
end

-- CHAT_MSG_SYSTEM: captura los dados (RANDOM_ROLL_RESULT localizado)
function Loot:CHAT_MSG_SYSTEM(msg)
    if not msg or not state.recording then return end
    local player, roll, min, max = msg:match(LootCore:GetRollPattern())
    if player and roll and tonumber(min) == 1 and tonumber(max) == 100 then
        if state.canRoll == false then
            return
        end
        player = LootCore:ResolveRollName(player)
        if not player then return end
        -- Ronda de desempate: solo se aceptan tiros de los jugadores en duelo,
        -- y cada uno tira una sola vez. Al completar todos los tiros se resuelve.
        if state.duel then
            local allowed = false
            for _, name in ipairs(state.duelPlayers) do
                if name == player then allowed = true break end
            end
            if not allowed then return end
            for _, d in ipairs(state.duelRolls) do
                if d.name == player then return end
            end
            table.insert(state.duelRolls, { name = player, roll = tonumber(roll) })
            LootCore:LogRoll(player, tonumber(roll))
            Publish("LOOT_ROLL_ADDED", state)
            self:ResolveDuel()
            return
        end
        if not LootCore:DidRoll(player) then
            table.insert(state.rolls, { name = player, roll = tonumber(roll) })
            SortRolls()
            LootCore:LogRoll(player, tonumber(roll))
            Publish("LOOT_ROLL_ADDED", state)
        end
    end
end

-- Devuelve la tabla de dados (ordenada de mayor a menor)
function Loot:GetRolls()
    return state.rolls
end

-- Devuelve el dado más alto del ganador (tiene en cuenta los tiros del
-- desempate si el ganador salió de una ronda de desempate)
function Loot:HighestRoll()
    if state.winnerRoll then return state.winnerRoll end
    if state.winner then
        for _, r in ipairs(state.rolls) do
            if r.name == state.winner then
                return r.roll
            end
        end
    end
    return 0
end

-- Devuelve el ganador actual (el de mayor dado)
function Loot:GetWinner()
    return state.winner
end

-- Declara manualmente un ganador (elección por clic en un dado). Al elegir
-- manualmente se cancela cualquier ronda de desempate en curso.
function Loot:SetWinner(name)
    state.winner = name
    state.winnerRoll = nil
    state.duel = false
    state.duelRolls = {}
    state.duelPlayers = {}
    state.announced = false
    Publish("LOOT_WINNER_SET", state)
end

-- Inicia una ronda de desempate entre los jugadores que empataron en el dado
-- más alto. Solo esos jugadores pueden tirar durante el desempate (el filtro
-- vive en CHAT_MSG_SYSTEM). Devuelve false si no hay empate que desempatar.
function Loot:StartDuel()
    if not LootCore:HasTie() then return false end
    state.duelPlayers = LootCore:GetTiedPlayers()
    state.duelRolls = {}
    state.duel = true
    state.recording = true
    state.canRoll = true
    state.rolled = false
    -- Sin ganador hasta que el desempate se resuelva (o se elija a mano).
    state.winner = nil
    state.winnerRoll = nil
    local limit = DEFAULT_COUNTDOWN
    if RD.config and RD.config.Get then
        limit = RD.config:Get("loot.rollTimeLimit", DEFAULT_COUNTDOWN)
    end
    limit = tonumber(limit) or DEFAULT_COUNTDOWN
    if limit > MAX_COUNTDOWN then limit = MAX_COUNTDOWN end
    LootCore:InvalidateCountdown()
    state.countdown = limit
    state.countdownActive = true
    self:ShowLoop()
    AnnounceDefault("¡Desempate! Tiran solo: " .. table.concat(state.duelPlayers, ", "))
    ScheduleCountdownAnnouncements(limit)
    Publish("LOOT_STATE_CHANGED", state)
    return true
end

-- Resuelve la ronda de desempate cuando todos los jugadores en duelo han tirado.
-- Si vuelve a haber empate entre los tiros del duelo, abre otra ronda con los
-- empatados de esa ronda; si no, fija al ganador (y su dado final).
function Loot:ResolveDuel()
    if not state.duel then return end
    -- Todos los jugadores del duelo deben haber tirado una vez.
    local pending = 0
    for _, name in ipairs(state.duelPlayers) do
        local has = false
        for _, d in ipairs(state.duelRolls) do
            if d.name == name then has = true break end
        end
        if not has then pending = pending + 1 end
    end
    if pending > 0 then return end

    table.sort(state.duelRolls, function(a, b)
        if a.roll == b.roll then return a.name < b.name end
        return a.roll > b.roll
    end)
    -- Empate en el duelo: nueva ronda con los empatados de esta ronda.
    if #state.duelRolls >= 2 and state.duelRolls[1].roll == state.duelRolls[2].roll then
        state.duelPlayers = {}
        local top = state.duelRolls[1].roll
        for _, d in ipairs(state.duelRolls) do
            if d.roll == top then state.duelPlayers[#state.duelPlayers + 1] = d.name end
        end
        state.duelRolls = {}
        AnnounceDefault("Nuevo desempate entre: " .. table.concat(state.duelPlayers, ", "))
        Publish("LOOT_STATE_CHANGED", state)
        return
    end
    state.winner = state.duelRolls[1].name
    state.winnerRoll = state.duelRolls[1].roll
    state.duel = false
    state.duelRolls = {}
    state.duelPlayers = {}
    state.announced = false
    AnnounceDefault(string.format("Desempate resuelto: %s gana con %d.", state.winner, state.winnerRoll))
    Publish("LOOT_STATE_CHANGED", state)
end

-- Anuncia el dado de un jugador concreto por la salida por defecto (Ctrl-clic
-- sobre un dado en la ventana), como el ChatPlayerRolled de KRT.
function Loot:AnnounceRoll(playerName)
    if not playerName then return false end
    for _, r in ipairs(state.rolls) do
        if r.name == playerName then
            AnnounceDefault(string.format("%s obtuvo %d en dados.", playerName, r.roll))
            return true
        end
    end
    return false
end

-- Declara al ganador por la salida por defecto (anuncia el nombre y el ítem)
function Loot:AnnounceWinner()
    if not state.itemLink or not state.winner then return false end
    if state.announced then return true end
    local rollTypeText = ({ [1] = "main", [2] = "dual", [3] = "enchant" })[state.rollType] or "main"
    local rollValue = self:HighestRoll()
    AnnounceDefault(string.format("%s ganó %s (dado %d, %s)", state.winner, state.itemLink, rollValue, rollTypeText))
    -- Lleva registro del ítem ganador en el historial (esté o no haya bandas).
    LootCore:LogItem(state.winner, state.itemLink, state.rollType, rollValue)
    state.announced = true
    state.recording = false
    state.countdownActive = false
    LootCore:InvalidateCountdown()
    Publish("LOOT_STATE_CHANGED", state)
    return true
end

-- ==================== Spamear botín ====================

-- Lista los ítems del botín del boss recién caído (ventana de botín abierta),
-- sin monedas ni materiales de encantar (familia 64), igual que KRT.
function Loot:GetBossLootLinks()
    local list = {}
    local n = GetNumLootItems()
    if not n or n <= 0 then return list end
    local threshold = GetLootThreshold() or 2
    for i = 1, n do
        if LootSlotIsItem(i) then
            local itemLink = GetLootSlotLink(i)
            if itemLink and GetItemFamily(itemLink) ~= 64 then
                local _, _, rarity = GetItemInfo(itemLink)
                if (rarity or 0) >= threshold then
                    list[#list + 1] = itemLink
                end
            end
        end
    end
    return list
end

-- Spamea el botín del boss caído por la salida por defecto, como el addon base
-- (KRT): cabecera "Ítems obtenidos:" + un mensaje por ítem numerado. Si no hay
-- ventana de botín abierta, cae al ítem actual del gestor. TOPE de ítems
-- anunciados (MAX_LOOT_LINES) para no soltar una ráfaga enorme: el resto se
-- resume con "… y N más"; el pacing del limitador global espacia el resto.
function Loot:SpamLoot()
    local MAX_LOOT_LINES = 30
    local list = self:GetBossLootLinks()
    if #list == 0 then
        if not state.itemLink then return false end
        AnnounceDefault("Ítems obtenidos:")
        if state.itemCount > 1 then
            AnnounceDefault("1. " .. state.itemLink .. " x" .. state.itemCount)
        else
            AnnounceDefault("1. " .. state.itemLink)
        end
        return true
    end
    AnnounceDefault("Ítems obtenidos:")
    for i, link in ipairs(list) do
        if i > MAX_LOOT_LINES then
            AnnounceDefault(string.format("… y %d más", #list - MAX_LOOT_LINES))
            break
        end
        AnnounceDefault(string.format("%d. %s", i, link))
    end
    return true
end

-- Índice del candidato del maestro despojador para recoger un slot de botín
-- (el índice de jugador que acepta GiveMasterLoot en 3.3.5a). GetMasterLootCandidate
-- NO tiene un orden estable entre invocaciones, así que se busca el índice por
-- NOMBRE en el momento (patrón de los addons de master loot correctos).
function Loot:MasterCandidateIndex(lootSlot)
    local myName = UnitName("player") or ""
    if myName == "" then return nil end
    local core = RD.modules and RD.modules.autoLootCore
    if core and core.IndexOfRecipient then
        return core:IndexOfRecipient(myName)
    end
    -- Respaldo: sondeo directo por nombre
    local cleanMy = core and core.CleanName and core:CleanName(myName) or myName
    for p = 1, 40 do
        local name = GetMasterLootCandidate(p)
        if not name then break end
        local cleanName = core and core.CleanName and core:CleanName(name) or name
        if cleanName == cleanMy then return p end
    end
    return nil
end

-- Recoge los ítems del botín abierto y los dirige al maestro despojador
-- (botón pensado para el maestro). Cada slot se asigna al propio maestro con
-- GiveMasterLoot, como hace KRT al asignar a un ganador.
function Loot:CollectItems()
    if not self:IsMasterLooter() then
        System("|cffff0000[RaidDominion]|r Solo el maestro despojador puede recoger los ítems.")
        return false
    end
    local n = GetNumLootItems()
    if not n or n <= 0 then
        System("|cffffd700[RaidDominion]|r No hay ventana de botín abierta para recoger ítems.")
        return false
    end
    local collected = 0
    for i = 1, n do
        if LootSlotIsItem(i) then
            local itemLink = GetLootSlotLink(i)
            if itemLink and GetItemFamily(itemLink) ~= 64 then
                local idx = self:MasterCandidateIndex(i)
                if idx then
                    GiveMasterLoot(i, idx)
                    collected = collected + 1
                end
            end
        end
    end
    if collected > 0 then
        AnnounceDefault(string.format("%s recogió %d ítems del botín.", UnitName("player") or "El maestro", collected))
        return true
    end
    return false
end

-- ==================== Limpiar ====================

-- Limpia los dados y el estado del roll actual (mantiene el historial)
function Loot:ClearRolls()
    LootCore:InvalidateCountdown()
    state.rolls = {}
    state.rolled = false
    state.canRoll = true
    state.recording = false
    state.countdown = 0
    state.countdownActive = false
    state.winner = nil
    state.winnerRoll = nil
    state.announced = false
    state.duel = false
    state.duelPlayers = {}
    state.duelRolls = {}
    Publish("LOOT_ROLL_CLEARED", state)
end

-- Limpia todo el gestor de botín (ítem + dados + historial)
function Loot:Clear()
    state.itemName = ""
    state.itemLink = nil
    state.itemTexture = nil
    state.itemCount = 1
    state.itemRarity = 0
    state.history = {}
    self:ClearRolls()
    Publish("LOOT_STATE_CHANGED", state)
end

-- ==================== Eventos del juego ====================

-- Inicializa el registro de eventos del juego (LOOT_OPENED, CHAT_MSG_SYSTEM).
-- Se llama desde RD_Init en PLAYER_LOGIN.
function Loot:Initialize()
    if self._initialized then return end
    self._initialized = true
    local f = CreateFrame("Frame", "RDLootEvents", UIParent)
    f:RegisterEvent("LOOT_OPENED")
    f:RegisterEvent("CHAT_MSG_SYSTEM")
    f:SetScript("OnEvent", function(self, event, arg1)
        if event == "LOOT_OPENED" then
            Loot:LOOT_OPENED()
        elseif event == "CHAT_MSG_SYSTEM" then
            Loot:CHAT_MSG_SYSTEM(arg1)
        end
    end)
    self._eventFrame = f
end

-- LOOT_OPENED: si hay un botín abierto (boss caído), carga el primer ítem
-- automáticamente. Replica el comportamiento de KRT (master looter).
function Loot:LOOT_OPENED()
    if not self:IsMasterLooter() then return end
    for i = 1, GetNumLootItems() do
        if LootSlotIsItem(i) then
            local itemLink = GetLootSlotLink(i)
            if itemLink and GetItemFamily(itemLink) ~= 64 then
                -- Carga el primer ítem del botín del boss para gestionarlo.
                -- El contador es la cantidad del stack del ítem. GetLootSlotInfo
                -- devuelve los valores en orden distinto según el cliente (aquí
                -- es "textura, nombre, cantidad, ..."; en otros "nombre, cantidad,
                -- rareza, ..."), así que se localiza la cantidad por su TIPO
                -- (primer valor numérico o string numérico) en lugar de asumir
                -- una posición fija. Sin esto, el 2º valor podía ser el NOMBRE
                -- (string) y `count > 1` reventaba con "attempt to compare number
                -- with string".
                local function ToCount(v)
                    if type(v) == "number" then return v end
                    if type(v) == "string" then return tonumber(v) end
                    return nil
                end
                local a, b, c = GetLootSlotInfo(i)
                local count = ToCount(a) or ToCount(b) or ToCount(c)
                self:SetItem(itemLink, count and count > 1 and count or 1)
                Publish("LOOT_ITEM_ADDED", self:GetState())
                return
            end
        end
    end
end

-- ==================== Countdown OnUpdate ====================

local countdownFrame

function Loot:Tick(elapsed)
    if not state.countdownActive then return end
    -- Decremento por tiempo real (elapsed del OnUpdate): antes se restaba un
    -- 0.1 fijo por frame, con lo que a 60fps el countdown corría 6x.
    state.countdown = state.countdown - (elapsed or 0.1)
    if state.countdown <= 0 then
        state.countdown = 0
        state.countdownActive = false
        state.recording = false
        state.canRoll = false
        LootCore:InvalidateCountdown()
        -- Fin del conteo por la salida por defecto (estilo conteo de pull) y
        -- aviso local de que los dados fuera de tiempo se ignoran.
        AnnounceDefault("¡Dados cerrados! Fuera de tiempo se ignoran.")
        System("|cffffd700[RaidDominion]|r Dados cerrados: tiempo agotado. Se ignoran dados fuera de tiempo.")
        Publish("LOOT_STATE_CHANGED", state)
    end
end

-- ==================== Loop ====================

-- Frame OnUpdate persistente: gestiona el countdown de los dados. Se crea de
-- forma perezosa en Initialize (PLAYER_LOGIN) para no depender de UIParent en
-- el load del .toc.
function Loot:EnsureLoop()
    if countdownFrame then return end
    countdownFrame = CreateFrame("Frame", "RDLootLoop", UIParent)
    countdownFrame:Hide()
    countdownFrame:SetScript("OnUpdate", function(self, elapsed)
        if not state.countdownActive then
            self:Hide()
            return
        end
        Loot:Tick(elapsed)
    end)
end

function Loot:ShowLoop()
    self:EnsureLoop()
    if state.countdownActive then
        countdownFrame:Show()
    else
        countdownFrame:Hide()
    end
end

RD.modules = RD.modules or {}
RD.modules.loot = Loot
return Loot