--[[
    RD_Module_ItemGoalsWatch.lua
    PROPÓSITO: Vigilancia de objetivos ("meta") de ítems y monedas por personaje.
              Escucha los eventos del juego y dispara los avisos locales cuando:
                - Un objetivo de equipamiento cae en la ventana de botín PROPIA
                  (LOOT_OPENED, recorriendo TODOS los slots, para cualquier
                  miembro de la banda — a diferencia de RD_Module_Loot, que solo
                  pre-carga el primer ítem para el master looter).
                - Una meta de moneda alcanza su cantidad (CURRENCY_DISPLAY_UPDATE;
                  avisa UNA sola vez por meta, vía ItemGoals:CheckCurrencies).
              La lectura en vivo de monedas y el formato de dinero viven en
              RD_Utils_Currencies (fuente única; aquí se deduplicó el lector
              privado que había).
              No toca la lógica de dados del gestor de botín (RD_Module_Loot).
              Los mensajes son LOCALES (SendSystemMessage), no van al canal.
    API PÚBLICA:
        - RD.modules.itemGoalsWatch:Initialize()      -- registra los eventos (RD_Init, PLAYER_LOGIN)
        - RD.modules.itemGoalsWatch:GetRegisterCandidate() -> link a registrar desde el editor
        - RD.modules.itemGoalsWatch:LOOT_OPENED() / LOOT_CLOSED() / CURRENCY_DISPLAY_UPDATE()
    EVENTOS registrados: LOOT_OPENED, LOOT_CLOSED, CURRENCY_DISPLAY_UPDATE.
    EVENTOS publicados:
        - ITEM_GOALS_LOOT_SCAN(hits)   tras escanear el botín (hits = { {slot, goal, link} })
        - ITEM_GOALS_LOOT_CLOSED()     al cerrar la ventana de botín
        - CURRENCY_GOAL_REACHED(hits)  al alcanzar una meta de moneda
        - CURRENCY_REFRESHED()         tras actualizar monedas (refresco de UI)
]]

local addonName, private = ...
local RD = _G.RaidDominion or {}
_G.RaidDominion = RD

RD.modules = RD.modules or {}
local Watch = {}

local function Publish(event, ...)
    if RD.events and RD.events.Publish then
        RD.events:Publish(event, ...)
    end
end

local function SendSystem(msg)
    local mm = RD.modules and RD.modules.messageManager
    if mm and mm.SendSystemMessage then
        mm:SendSystemMessage(msg)
    end
end

-- Aviso local de objetivo de equipamiento en el botín. El link se envía tal cual
-- (trae su propio color de calidad y es clicable); no introducimos pipes.
local function AnnounceLootHit(hit)
    if not hit or not hit.link then return end
    local slotLabel = ""
    if RD.utils and RD.utils.itemGoals and RD.utils.itemGoals.SlotLabel then
        slotLabel = " (" .. RD.utils.itemGoals:SlotLabel(hit.slot) .. ")"
    end
    SendSystem("|cff00c800[RaidDominion]|r ¡Objetivo en el botín! " .. hit.link .. slotLabel)
end

-- Aviso local de meta de moneda alcanzada (una sola vez por meta). El oro se
-- avisa desglosado (la meta y la cantidad se guardan en cobre).
local function AnnounceCurrencyHit(hit)
    if not hit then return end
    local cur = RD.utils and RD.utils.currencies
    local qty = tostring(hit.quantity)
    local target = tostring(hit.target)
    if cur and hit.name == (cur.MONEY_KEY or "Oro") then
        qty = cur:FormatMoney(hit.quantity)
        target = cur:FormatMoney(hit.target)
    end
    SendSystem("|cff00c800[RaidDominion]|r ¡Meta alcanzada! " .. tostring(hit.name)
        .. ": " .. qty .. "/" .. target)
end

-- ============================================================================
-- Lectura del listado de monedas en vivo (fuente única: RD_Utils_Currencies).
-- ============================================================================
local function CollectCurrencies()
    local cur = RD.utils and RD.utils.currencies
    if cur and cur.Collect and cur.Flatten then
        return cur:Flatten(cur:Collect())
    end
    return {}
end

-- ============================================================================
-- Eventos del juego
-- ============================================================================

-- LOOT_OPENED: escanea TODA la ventana de botín propia (todos los slots) y
-- avisa de los objetivos que coincidan. Vale para cualquier miembro, no solo
-- para el master looter.
function Watch:LOOT_OPENED()
    local links = {}
    local n = (GetNumLootItems and GetNumLootItems()) or 0
    for i = 1, n do
        local link = (GetLootSlotLink and GetLootSlotLink(i)) or nil
        if link and link ~= "" then
            links[#links + 1] = link
        end
    end
    local goals = RD.utils and RD.utils.itemGoals
    local hits = (goals and goals.ScanLoot and goals:ScanLoot(links)) or {}
    for i = 1, #hits do
        AnnounceLootHit(hits[i])
    end
    Publish("ITEM_GOALS_LOOT_SCAN", hits)
end

-- LOOT_CLOSED: se reinicia el dedup de la sesión de botín (el próximo botín
-- vuelve a avisar).
function Watch:LOOT_CLOSED()
    local goals = RD.utils and RD.utils.itemGoals
    if goals and goals.ResetLootSession then
        goals:ResetLootSession()
    end
    Publish("ITEM_GOALS_LOOT_CLOSED")
end

-- CURRENCY_DISPLAY_UPDATE: comprueba las cantidades actuales contra las metas
-- y avisa (una vez) de las recién alcanzadas; además avisa a la UI para que
-- refresque los iconos si la sección de monedas está abierta.
function Watch:CURRENCY_DISPLAY_UPDATE()
    local list = CollectCurrencies()
    local goals = RD.utils and RD.utils.itemGoals
    local hits = (goals and goals.CheckCurrencies and goals:CheckCurrencies(list)) or {}
    for i = 1, #hits do
        AnnounceCurrencyHit(hits[i])
    end
    if #hits > 0 then
        Publish("CURRENCY_GOAL_REACHED", hits)
    end
    Publish("CURRENCY_REFRESHED")
end

-- ============================================================================
-- Candidato a registrar desde el editor de jugador
-- ============================================================================

-- Devuelve el link que se puede registrar como objetivo de equipamiento, en
-- orden de preferencia:
--   1. El ítem cargado en el gestor de botín (/rdloot, Loot:GetItem).
--   2. El primer ítem de la ventana de botín propia abierta.
-- Devuelve nil si no hay ninguno (el botón se deshabilita con una pista).
function Watch:GetRegisterCandidate()
    local loot = RD.modules and RD.modules.loot
    if loot and loot.GetState then
        local state = loot:GetState()
        if state and state.itemLink and state.itemLink ~= "" then
            return state.itemLink
        end
    end
    local n = (GetNumLootItems and GetNumLootItems()) or 0
    for i = 1, n do
        local link = (GetLootSlotLink and GetLootSlotLink(i)) or nil
        if link and link ~= "" then
            return link
        end
    end
    return nil
end

-- ============================================================================
-- Inicialización
-- ============================================================================

-- Registra los eventos del juego. Se llama desde RD_Init en PLAYER_LOGIN
-- (después de RD_Module_Loot y del roster de personajes).
function Watch:Initialize()
    if self._initialized then return end
    self._initialized = true
    local f = CreateFrame("Frame", "RDItemGoalsWatch", UIParent)
    f:RegisterEvent("LOOT_OPENED")
    f:RegisterEvent("LOOT_CLOSED")
    f:RegisterEvent("CURRENCY_DISPLAY_UPDATE")
    f:SetScript("OnEvent", function(self, event)
        if event == "LOOT_OPENED" then
            Watch:LOOT_OPENED()
        elseif event == "LOOT_CLOSED" then
            Watch:LOOT_CLOSED()
        elseif event == "CURRENCY_DISPLAY_UPDATE" then
            Watch:CURRENCY_DISPLAY_UPDATE()
        end
    end)
    self._eventFrame = f
end

RD.modules.itemGoalsWatch = Watch
return Watch