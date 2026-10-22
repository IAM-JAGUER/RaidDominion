--[[
    RD_Module_LootQueue.lua
    PROPÓSITO: Cola de ítems pendientes del cadáver abierto para el gestor de
              botín (RD_Module_Loot). Reconstruye la lista de ítems gestionables
              (sin materiales de encantar y con rareza >= umbral de botín),
              conserva el ítem actual por LINK al reabrir el mismo cadáver o al
              repartirse un slot, avanza al siguiente pendiente al declarar
              ganador, y permite NAVEGAR por la cola (Siguiente/Anterior) cuando
              nadie ha tirado dados: el ítem saltado no se marca como entregado
              y un ítem de BOLSA apartado se recupera sin perderlo. También decide
              si la ventana debe abrirse sola al inspeccionar un cadáver (líder +
              maestro despojador, con toggle de config y sin el modo Auto activo).
    API PÚBLICA:
        - RD.modules.loot:ScanCorpse(preserveCurrent, loadIfEmpty, loadIfMissing)
        - RD.modules.loot:Advance(reason) -> bool (¿cargó otro ítem?)
        - RD.modules.loot:SkipItem() -> bool  -- salta al siguiente pendiente
        - RD.modules.loot:PreviousItem() -> bool  -- vuelve al anterior
        - RD.modules.loot:GetQueueInfo() -> tabla (pos, total, canNext, canPrev)
        - RD.modules.loot:SetManualItem(itemLink, count)  -- ítem de bolsa (apartado)
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

-- ==================== Utilidades de la cola ====================

-- Conserva las marcas de "entregado" (awarded) al reescanear el MISMO cadáver:
-- los links se emparejan por ORDEN de aparición, así los duplicados se
-- emparejan 1:1 (entregar una copia NO marca a la otra). Sin esto, un ítem ya
-- declarado volvería a ofrecerse como pendiente tras un LOOT_SLOT_CLEARED.
-- Solo se aplica si el ÍTEM ACTUAL sigue en el cadáver: si ya no está, es un
-- cadáver distinto (mismo GUID, otro botín) y las marcas no se heredan.
local function CarryAwarded(oldList, newList)
    local byLink = {}
    for _, entry in ipairs(oldList or {}) do
        byLink[entry.link] = byLink[entry.link] or {}
        table.insert(byLink[entry.link], entry)
    end
    local taken = {}
    for _, entry in ipairs(newList or {}) do
        local list = byLink[entry.link]
        if list then
            for _, old in ipairs(list) do
                if old.awarded and not taken[old] then
                    taken[old] = true
                    entry.awarded = true
                    break
                end
            end
        end
    end
end

-- ¿El link dado sigue estando en la lista? (el cadáver conserva el ítem actual)
local function ContainsLink(list, link)
    if not link then return false end
    for _, entry in ipairs(list or {}) do
        if entry.link == link then return true end
    end
    return false
end

-- Posición del ítem ACTUAL dentro de la cola (0 si el ítem actual no viene del
-- cadáver o la casilla está vacía). La posición recordada manda si sigue
-- apuntando al mismo link: los links DUPLICADOS en el cadáver no deben
-- reencontrar la primera copia.
local function CurrentPos()
    local pending = state.pending or {}
    local current = state.itemLink
    if not current then return 0 end
    local pos = state.pendingPos or 0
    local atPos = pending[pos]
    if atPos and atPos.link == current then return pos end
    for idx, entry in ipairs(pending) do
        if entry.link == current then return idx end
    end
    return 0
end

-- Cursor de la cola: la posición conocida aunque la casilla esté vacía (por
-- ejemplo tras entregar el último pendiente).
local function Cursor()
    local pos = CurrentPos()
    if pos > 0 then return pos end
    return state.pendingPos or 0
end

-- Índice de la siguiente entrada NO entregada a partir de `from` (excluido).
local function NextFree(from)
    local pending = state.pending or {}
    for i = (from or 0) + 1, #pending do
        if not pending[i].awarded then return i end
    end
    return nil
end

-- Índice de la entrada NO entregada anterior a `from` (excluido).
local function PrevFree(from)
    local pending = state.pending or {}
    for i = (from or 1) - 1, 1, -1 do
        if not pending[i].awarded then return i end
    end
    return nil
end

-- Carga en la casilla el ítem de la cola en la posición `idx`.
local function LoadEntry(self, idx)
    local entry = (state.pending or {})[idx]
    if not entry then return false end
    self:SetItem(entry.link, entry.count)
    state.currentFromCorpse = true
    state.pendingPos = idx
    return true
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
    -- Solo se heredan las marcas "entregado" cuando es el MISMO cadáver: el
    -- ítem actual debe seguir en él o la casilla estar vacía (si ya no está, es
    -- otro botín con el mismo GUID y las marcas NO se heredan).
    if preserveCurrent and (ContainsLink(pending, state.itemLink) or not state.itemLink) then
        CarryAwarded(state.pending, pending)
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
        if reload then
            -- Se salta los pendientes ya entregados (si los hay).
            LoadEntry(self, NextFree(0))
        end
        return
    end

    if not LoadEntry(self, NextFree(0)) then
        state.pendingPos = 0
    end
end

-- Carga el siguiente ítem pendiente del cadáver. Se invoca al declarar ganador
-- (reason = "awarded": el ítem queda entregado y no vuelve a ofrecerse). Si el
-- ítem actual no está en la cola (vino de la bolsa) empieza por el primero
-- pendiente; si no quedan pendientes deja la casilla vacía y avisa (solo si
-- había un ítem cargado).
function Loot:Advance(reason)
    local pending = state.pending or {}
    local pos = Cursor()
    -- El ítem recién entregado se marca: deja de ofrecerse como pendiente ni
    -- tras reescanear el cadáver.
    if reason == "awarded" and pending[pos] then
        pending[pos].awarded = true
    end
    local nextIdx = NextFree(pos)
    if nextIdx and LoadEntry(self, nextIdx) then
        return true
    end

    local hadItem = state.itemLink ~= nil
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

-- ==================== Navegación por la cola ====================

-- Salta el ítem actual (caso "nadie ha tirado dados") y carga el siguiente
-- pendiente NO entregado. El ítem saltado NO se marca como entregado: se puede
-- volver a él con PreviousItem. Si el ítem actual es de la BOLSA se aparta a
-- state.manualItem para poder recuperarlo con "Anterior": al saltar, ningún
-- ítem se pierde. Si no hay ningún pendiente al que ir, la casilla se QUEDA
-- como está (navegar nunca descarta el ítem actual).
function Loot:SkipItem()
    local current = state.itemLink
    local pos = CurrentPos()
    local cursor = Cursor()
    -- Ítem de bolsa: se aparta (no se descarta) para poder volver a él.
    if current and pos == 0 and not state.manualItem then
        state.manualItem = { link = current, count = state.itemCount or 1 }
    end
    local nextIdx = NextFree(cursor)
    if nextIdx and LoadEntry(self, nextIdx) then
        return true
    end
    -- No queda ningún pendiente: si había un ítem de bolsa apartado se recupera
    -- (la casilla queda como estaba) y no se toca nada más.
    if state.manualItem and pos == 0 and current then
        local m = state.manualItem
        state.manualItem = nil
        self:SetItem(m.link, m.count)
        state.currentFromCorpse = false
        state.pendingPos = 0
        return false
    end
    return false
end

-- Vuelve al ítem ANTERIOR de la cola (el anterior no entregado). Los dados se
-- reinician: el ítem vuelve con la ronda limpia (nadie ha tirado aún). Si no
-- hay anterior en la cola y hay un ítem de bolsa apartado, se recupera ese
-- (también con la casilla vacía). Si no hay nada a lo que ir, la casilla se
-- queda como está.
function Loot:PreviousItem()
    local cursor = Cursor()
    local prevIdx = PrevFree(cursor)
    if prevIdx and LoadEntry(self, prevIdx) then
        return true
    end
    -- Sin anterior en la cola: se recupera el ítem de bolsa apartado (si lo hay).
    if state.manualItem then
        local m = state.manualItem
        state.manualItem = nil
        self:SetItem(m.link, m.count)
        state.currentFromCorpse = false
        state.pendingPos = 0
        return true
    end
    return false
end

-- Información de la cola para la UI (sin efectos secundarios): posición del
-- ítem actual, total de ÍTEMS en la cola del cadáver (incluye los ya
-- entregados) y si se puede avanzar o retroceder.
function Loot:GetQueueInfo()
    local pending = state.pending or {}
    local pos = CurrentPos()
    local cursor = Cursor()
    return {
        pos = pos,
        cursor = cursor,
        total = #pending,
        canNext = NextFree(cursor) ~= nil,
        canPrev = (PrevFree(cursor) ~= nil) or (state.manualItem ~= nil),
    }
end

-- Carga un ítem de la BOLSA en la casilla (arrastrado o clic con el cursor) y
-- lo APARTA como "ítem de recuerdo": al saltar a la cola del cadáver se puede
-- volver a él con "Anterior" (navegar nunca pierde un ítem). Sustituye al
-- ítem apartado anterior (que sigue en la bolsa del jugador).
function Loot:SetManualItem(itemLink, count)
    if not itemLink or itemLink == "" then return false end
    state.manualItem = { link = itemLink, count = tonumber(count) or 1 }
    return self:SetItem(itemLink, count)
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
    -- El ítem de bolsa apartado pertenece a la cola: sin cola ya no hay a qué
    -- volver, así que se descarta (el ítem sigue en la bolsa del jugador).
    state.manualItem = nil
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
