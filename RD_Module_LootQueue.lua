--[[
    RD_Module_LootQueue.lua
    PROPÓSITO: Cola de ítems pendientes del cadáver abierto para el gestor de
              botín (RD_Module_Loot). Reconstruye la lista de ítems gestionables
              (sin materiales de encantar y con rareza >= umbral de botín),
              conserva el ítem actual por LINK al reabrir el mismo cadáver o al
              repartirse un slot, avanza al siguiente pendiente al declarar
              ganador o limpiar, y decide si la ventana debe abrirse sola al
              inspeccionar un cadáver (líder + maestro despojador, con toggle de
              config y sin el modo Auto activo).
    API PÚBLICA:
        - RD.modules.loot:ScanCorpse(preserveCurrent, loadIfEmpty, loadIfMissing)
        - RD.modules.loot:Advance() -> bool (¿cargó otro ítem?)
        - RD.modules.loot:ShouldAutoOpen() -> bool
        - RD.modules.loot:LOOT_CLOSED()  -- vacía la cola al cerrar el cadáver
    EVENTOS: Ninguno propio; escucha LOOT_OPENED/LOOT_SLOT_CLEARED/LOOT_CLOSED
             (registrados en RD_Module_Loot.Initialize) y publica LOOT_ITEM_ADDED
             vía SetItem (RD_Module_Loot.lua).
    DEPENDENCIA: RD_Module_LootCore.lua (estado compartido) y RD_Module_Loot.lua
                 (SetItem/ClearRolls/ReadLootSlot); debe cargarse DESPUÉS de
                 ambos (orden en RaidDominion.toc).
]]

local addonName, private = ...
local RD = _G.RaidDominion or {}
_G.RaidDominion = RD

local Loot = assert(RD.modules.loot, "RD_Module_Loot.lua debe cargarse antes que RD_Module_LootQueue.lua")
local LootCore = assert(RD.modules.lootCore, "RD_Module_LootCore.lua debe cargarse antes que RD_Module_LootQueue.lua")
local state = LootCore.state
local Publish = LootCore.Publish

local function System(msg)
    if RD.messageManager and RD.messageManager.SendSystemMessage then
        RD.messageManager:SendSystemMessage(msg)
    end
end

-- Reconstruye la cola de pendientes del cadáver abierto (mismo filtro que
-- GetBossLootLinks). Con `preserveCurrent` (mismo cadáver reabierto o
-- LOOT_SLOT_CLEARED) conserva el ítem actual por LINK, como FetchLoot de KRT.
-- `loadIfEmpty` (solo al inspeccionar) recarga el primer pendiente cuando la
-- casilla está vacía; `loadIfMissing` (solo al inspeccionar) carga el primero
-- cuando el ítem actual ya no está (cadáver nuevo o ítem repartido mientras
-- tanto): sin esto, un Target con GUID ajeno podía conservar el ítem viejo.
-- En LOOT_SLOT_CLEARED no se recarga nada: el avance lo decide el usuario.
function Loot:ScanCorpse(preserveCurrent, loadIfEmpty, loadIfMissing)
    local pending = {}
    local n = GetNumLootItems()
    if n and n > 0 then
        for i = 1, n do
            local itemLink, count = self:ReadLootSlot(i)
            if itemLink then
                pending[#pending + 1] = { link = itemLink, count = count }
            end
        end
    end
    state.pending = pending

    if preserveCurrent then
        local pos
        local current = state.itemLink
        if current then
            -- La posición recordada manda si sigue apuntando al mismo link:
            -- así los links DUPLICADOS en el cadáver no atascan la cola.
            local atPos = pending[state.pendingPos or 0]
            if atPos and atPos.link == current then
                pos = state.pendingPos
            else
                for idx, entry in ipairs(pending) do
                    if entry.link == current then pos = idx break end
                end
            end
        end
        state.pendingPos = pos or 0
        local reload = (not current and loadIfEmpty)
            or (current and state.currentFromCorpse and not pos and loadIfMissing)
        if reload and pending[1] then
            self:SetItem(pending[1].link, pending[1].count)
            state.currentFromCorpse = true
            state.pendingPos = 1
        end
        return
    end

    if pending[1] then
        self:SetItem(pending[1].link, pending[1].count)
        state.currentFromCorpse = true
        state.pendingPos = 1
    else
        state.pendingPos = 0
    end
end

-- Carga el siguiente ítem pendiente del cadáver. Se invoca al declarar ganador
-- (ítem hecho) y al limpiar (ítem descartado). Si el ítem actual no está en la
-- cola (vino de la bolsa) empieza por el primero; si no quedan pendientes deja
-- la casilla vacía y avisa (solo si había un ítem cargado).
function Loot:Advance()
    local pending = state.pending or {}
    local pos = state.pendingPos or 0
    local current = state.itemLink
    if current then
        -- La posición recordada manda si sigue apuntando al mismo link (links
        -- duplicados): buscar siempre desde el índice 1 reencontraba la primera
        -- copia y nunca alcanzaba los ítems posteriores.
        local atPos = pending[pos]
        if not (atPos and atPos.link == current) then
            for idx, entry in ipairs(pending) do
                if entry.link == current then pos = idx break end
            end
        end
    end
    local nextEntry = pending[pos + 1]
    if nextEntry then
        self:SetItem(nextEntry.link, nextEntry.count)
        state.currentFromCorpse = true
        state.pendingPos = pos + 1
        return true
    end

    local hadItem = current ~= nil
    state.itemName = ""
    state.itemLink = nil
    state.itemTexture = nil
    state.itemCount = 1
    state.itemRarity = 0
    state.pendingPos = pos
    state.currentFromCorpse = false
    self:ClearRolls()
    Publish("LOOT_STATE_CHANGED", state)
    if hadItem then
        System("|cffffd700[RaidDominion]|r No quedan ítems pendientes en el cadáver.")
    end
    return false
end

-- LOOT_CLOSED: la ventana de botín se cerró, así que la cola deja de ser
-- válida (solo se gestiona con el cadáver abierto). Se vacía para que Limpiar/
-- Declarar no carguen "fantasmas" al trabajar luego con un ítem de la bolsa.
-- El ítem actual y los dados se conservan: una ronda puede seguir en curso.
-- Si en ese momento ya hay otra ventana de botín abierta, no se toca nada.
function Loot:LOOT_CLOSED()
    local n = GetNumLootItems()
    if n and n > 0 then return end
    state.pending = {}
    state.pendingPos = 0
end

-- ¿Debe abrirse la ventana del gestor al inspeccionar un cadáver? Requiere el
-- toggle de config (loot.autoOpen), ser LÍDER (banda o grupo), ser maestro
-- despojador y que el cadáver tenga ítems que lotear. Se omite mientras el modo
-- Auto está activo: ese modo reparte solo y abrir la ventana sería ruido.
function Loot:ShouldAutoOpen()
    if not self:IsMasterLooter() then return false end
    local enabled = true
    if RD.config and RD.config.Get then
        enabled = RD.config:Get("loot.autoOpen", true)
    end
    if enabled == false then return false end
    if not (IsRaidLeader() or (GetNumRaidMembers() == 0 and IsPartyLeader())) then
        return false
    end
    local auto = RD.modules and RD.modules.autoLoot
    if auto and auto.IsActive and auto:IsActive() then return false end
    return #(state.pending or {}) > 0
end

return Loot
