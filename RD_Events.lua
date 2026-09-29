--[[
    RD_Events.lua
    PROPÓSITO: Bus de eventos pub/sub minimalista. Sin dependencias externas.
    API PÚBLICA:
        - RD.events:Subscribe(event, fn)
        - RD.events:Unsubscribe(event, fn)
        - RD.events:Publish(event, ...)
    EVENTOS RESERVADOS:
        CONFIG_LOADED, CONFIG_CHANGED(key, value), CONFIG_RESET,
        ADDON_INITIALIZED, UI_SHOW, UI_HIDE,
        CONFIG_WINDOW_SHOWN, CONFIG_WINDOW_HIDDEN
]]

local addonName, private = ...
local RD = _G.RaidDominion or {}
_G.RaidDominion = RD

local Events = {
    registry = {},
    snapshot = {},
}

-- Suscribe una función a un evento
function Events:Subscribe(event, fn)
    if not event or type(fn) ~= "function" then return end
    if not self.registry[event] then
        self.registry[event] = {}
    end
    table.insert(self.registry[event], fn)
    -- Invalida el snapshot: el próximo Publish lo reconstruye (una sola vez)
    self.snapshot[event] = nil
end

-- Elimina la suscripción de una función a un evento
function Events:Unsubscribe(event, fn)
    local list = self.registry[event]
    if not list then return end
    for i = #list, 1, -1 do
        if list[i] == fn then
            table.remove(list, i)
        end
    end
    -- Libera el registro (y su snapshot) si quedó vacío: no acumular tablas
    -- muertas de eventos ya sin suscriptores.
    if #list == 0 then
        self.registry[event] = nil
    end
    -- Invalida el snapshot: el próximo Publish lo reconstruye.
    self.snapshot[event] = nil
end

-- Publica un evento a todos los suscriptores. El snapshot se cachea y solo se
-- reconstruye cuando Subscribe/Unsubscribe lo invalidan: una lista de
-- suscriptores estable no asigna nada por publish (antes se copiaba en cada
-- publish). La semántica es idéntica a copiar cada vez: los handlers dados de
-- alta durante el publish no corren en ese publish, los dados de baja sí (están
-- en el snapshot).
function Events:Publish(event, ...)
    local list = self.registry[event]
    if not list then return end
    local handlers = self.snapshot[event]
    if not handlers then
        handlers = {}
        for i = 1, #list do
            handlers[i] = list[i]
        end
        self.snapshot[event] = handlers
    end
    for i = 1, #handlers do
        local fn = handlers[i]
        if fn then
            local ok, err = pcall(fn, ...)
            if not ok and RD.messageManager and RD.messageManager.SendSystemMessage then
                RD.messageManager:SendSystemMessage(
                    "|cffff0000[RaidDominion]|r Error en evento " .. tostring(event) .. ": " .. tostring(err))
            end
        end
    end
end

RD.events = Events
return Events
