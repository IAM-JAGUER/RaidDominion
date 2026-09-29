--[[
    RD_Module_AutoLootMaster.lua
    PROPÓSITO: Máquina de reparto del "Modo Auto" de botín
              (RD.modules.autoLootMaster). Sostiene el mapa de candidatos del
              cadáver abierto (en GRUPO el mapa determinista maestro=1/partyN=N+1
              derivado del roster; en banda, sondeo de 1 arg con respaldo por
              posición) y el estado de la entrega en curso (slot pendiente,
              destinatarios probados, confirmación por
              LOOT_SLOT_CHANGED/LOOT_SLOT_CLEARED). Es lógica pura: sin frames,
              sin eventos y sin retardos; el orquestador RD_Module_AutoLoot.lua
              la conduce con sus propios Delay/Debug/estadísticas.
              La confirmación es POR EVENTO (no por sondeo de heurísticas): un
              slot solo se da por repartido cuando el servidor cambió el slot
              (LOOT_SLOT_CHANGED) o lo retiró (LOOT_SLOT_CLEARED).
    API PÚBLICA:
        - RD.modules.autoLootMaster:Reset()
        - RD.modules.autoLootMaster:BuildCandidateMap(slot) -> mapa (delega en autoLootCore)
        - RD.modules.autoLootMaster:IndexFor(name)          -> índice GiveMasterLoot
        - RD.modules.autoLootMaster:BeginGive(slot, itemLink)
        - RD.modules.autoLootMaster:NextRecipient(list)     -> siguiente destinatario sin probar
        - RD.modules.autoLootMaster:MarkTried(name)
        - RD.modules.autoLootMaster:OnSlotChanged(slot) / OnSlotCleared(slot)
        - RD.modules.autoLootMaster:IsConfirmed(slot)       -> ¿la entrega del slot se confirmó?
    DEPENDENCIA: RD.modules.autoLootCore (RD_Module_AutoLootCore.lua) debe
                 cargarse antes (orden en RaidDominion.toc).
]]

local addonName, private = ...
local RD = _G.RaidDominion or {}
_G.RaidDominion = RD

-- Dependencia tolerante: si autoLootCore no está registrado, la máquina se
-- construye igual y BuildCandidateMap devuelve un mapa vacío (Run() avisa y
-- aborta antes de repartir). Nunca rompe la carga del addon.
local AutoLootCore = RD.modules and RD.modules.autoLootCore

local AutoLootMaster = {}

local state = {
    candMap = nil,  -- { orden = { {name,index}, .. }, byName = { [limpio]=index } }
    pending = nil,  -- { slot, itemLink, recipient, tried = { [limpio]=true } }
    changed = {},   -- [slot] = true (LOOT_SLOT_CHANGED recibido)
    cleared = {},   -- [slot] = true (LOOT_SLOT_CLEARED recibido)
}
AutoLootMaster.state = state

-- Reinicia todo el estado (nuevo cadáver / nueva sesión)
function AutoLootMaster:Reset()
    state.candMap = nil
    state.pending = nil
    state.changed = {}
    state.cleared = {}
end

-- Construye/almacena el mapa de candidatos del cadáver abierto (una vez por
-- cadáver). Delega en autoLootCore (forma de 1 arg). Devuelve el mapa.
function AutoLootMaster:BuildCandidateMap(slot)
    if not AutoLootCore then
        state.candMap = { orden = {}, byName = {} }
        return state.candMap
    end
    local map = AutoLootCore:BuildCandidateMap(slot)
    state.candMap = map
    return map
end

-- Índice para GiveMasterLoot de un nombre en el mapa actual (nil si no figura)
function AutoLootMaster:IndexFor(name)
    if not AutoLootCore or not AutoLootCore.IndexFor then return nil end
    return AutoLootCore:IndexFor(state.candMap, name)
end

-- Inicia una entrega para el slot: limpia marcas del slot y prepara el estado.
function AutoLootMaster:BeginGive(slot, itemLink)
    state.pending = { slot = slot, itemLink = itemLink, recipient = nil, tried = {} }
    state.changed[slot] = nil
    state.cleared[slot] = nil
end

-- Devuelve el siguiente destinatario de la lista que aún no se ha probado para
-- el slot pendiente y lo marca como probado; nil si se agotaron. NUNCA repite.
function AutoLootMaster:NextRecipient(recipients)
    local pending = state.pending
    if not pending then return nil end
    for _, name in ipairs(recipients or {}) do
        local key = AutoLootCore:CleanName(name)
        if not pending.tried[key] then
            pending.tried[key] = true
            pending.recipient = name
            return name
        end
    end
    return nil
end

-- Marca un nombre como probado (usado cuando un candidato no está en el mapa o
-- su entrega fue rechazada)
function AutoLootMaster:MarkTried(name)
    local pending = state.pending
    if pending and name then
        pending.tried[AutoLootCore:CleanName(name)] = true
    end
end

-- El servidor cambió el contenido/estado del slot (LOOT_SLOT_CHANGED)
function AutoLootMaster:OnSlotChanged(slot)
    if slot then state.changed[slot] = true end
end

-- El servidor retiró el ítem del slot (LOOT_SLOT_CLEARED)
function AutoLootMaster:OnSlotCleared(slot)
    if slot then state.cleared[slot] = true end
end

-- ¿La entrega pendiente del slot se confirmó por evento del servidor
-- (LOOT_SLOT_CHANGED / LOOT_SLOT_CLEARED) o por refuerzo explícito (Confirm)?
function AutoLootMaster:IsConfirmed(slot)
    local pending = state.pending
    if not pending or pending.slot ~= slot then return false end
    return state.changed[slot] == true
        or state.cleared[slot] == true
        or pending.confirmed == true
end

-- Confirmación explícita (refuerzo por el flag "locked" de GetLootSlotInfo)
function AutoLootMaster:Confirm()
    local pending = state.pending
    if pending then pending.confirmed = true end
end

-- Confirma la entrega pendiente actual (usado en LOOT_CLOSED: si la ventana de
-- botín se cierra mientras hay una entrega en curso, el/los ítem(s) se dieron).
function AutoLootMaster:ConfirmPending()
    local pending = state.pending
    if pending then pending.confirmed = true end
end

RD.modules = RD.modules or {}
RD.modules.autoLootMaster = AutoLootMaster
return AutoLootMaster