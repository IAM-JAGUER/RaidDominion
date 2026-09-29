--[[
    RD_Module_ReadyCheck.lua
    PROPÓSITO: Ready check con cuenta regresiva: el líder indica los segundos
              (como el pull), se lanza DoReadyCheck y el conteo va por CHAT
              (título "= ... =" + ticks 9s..., 5s... ¡RESPONDAN AHORA!,
              ceñidos al contador). Al terminar (temporizador o
              READY_CHECK_FINISHED), se anuncia quién respondió, quién rechazó,
              quién no respondió y quién está AFK/desconectado.
    API PÚBLICA:
        - RD.modules.readyCheck:Start(seconds)
        - RD.modules.readyCheck:Finish()
        - RD.modules.readyCheck:Cancel()
    EVENTOS: READY_CHECK_CONFIRM (trackeo de confirmados), READY_CHECK_FINISHED
             y READY_CHECK_CANCELED (fin/cancelación anticipada).
]]

local addonName, private = ...
local RD = _G.RaidDominion or {}
_G.RaidDominion = RD

local ReadyCheck = {}

local function Log(msg)
    if RD.messageManager and RD.messageManager.SendSystemMessage then
        RD.messageManager:SendSystemMessage(msg)
    elseif RD.UIUtils and RD.UIUtils.Log then
        RD.UIUtils.Log(msg)
    end
end

local function InRaid() return GetNumRaidMembers() ~= 0 end
local function InParty() return GetNumPartyMembers() > 0 end

-- Copia viva del roster al iniciar (unidades + nombres). En banda se usan las
-- unidades de raid (en banda GetNumPartyMembers devuelve el subgrupo y partyN
-- coincide con raidN, así que solo se usa un origen para no duplicar).
local function SnapshotRoster()
    local units, names = {}, {}
    local function Add(unit, name)
        if unit and name and name ~= "" then
            units[#units + 1] = unit
            names[#names + 1] = name
        end
    end
    local nRaid = GetNumRaidMembers()
    if nRaid > 0 then
        for i = 1, nRaid do Add("raid" .. i, GetRaidRosterInfo(i)) end
    else
        local nParty = GetNumPartyMembers()
        if nParty > 0 then
            for i = 1, nParty do Add("party" .. i, UnitName("party" .. i)) end
        else
            Add("player", UnitName("player"))
        end
    end
    return units, names
end

-- Clasifica a los miembros al finalizar según el estado del check. Los
-- DESCONECTADOS (o que salieron de la banda) se apartan: no pueden responder y
-- su status puede quedar stale ("ready" fantasma). El iniciador ya viene
-- confirmado (el juego auto-confirma al líder).
local function Classify(active)
    local yes, no, pending, afk, offline = {}, {}, {}, {}, {}
    for idx, unit in ipairs(active.units) do
        local name = active.names[idx]
        if name then
            if not UnitExists(unit) or not UnitIsConnected(unit) then
                offline[#offline + 1] = name
            elseif UnitIsAFK(unit) then
                -- Categorías EXCLUSIVAS: un AFK no puede responder, así que solo
                -- va a la línea AFK (no se duplica en Sin responder/Rechazaron).
                afk[#afk + 1] = name
            else
                -- Se PREFIERE el status actual; si ya no está disponible (el
                -- check terminó y los status se resetearon), se cae al trackeo
                -- de CONFIRM, que guardó la respuesta en vivo ("yes"/"no").
                local status = GetReadyCheckStatus and GetReadyCheckStatus(unit) or nil
                if status == "ready" then
                    yes[#yes + 1] = name
                elseif status == "notready" then
                    no[#no + 1] = name
                else
                    local resp = active.confirmed[name]
                    if resp == "no" then
                        no[#no + 1] = name
                    elseif resp == "yes" then
                        yes[#yes + 1] = name
                    else
                        pending[#pending + 1] = name
                    end
                end
            end
        end
    end
    return yes, no, pending, afk, offline
end

-- Anuncia el resumen por el canal configurado. El título va envuelto en
-- "= ... =" (como reglas/mecánicas) y las líneas de detalle van sueltas.
local function SendSummary(active)
    local mm = RD.modules and RD.modules.messageManager
    if not mm then return end
    local yes, no, pending, afk, offline = Classify(active)
    local total = #active.units
    local responded = #yes + #no
    local parts = {
        string.format("= Finalizado: %d/%d respondieron =", responded, total),
    }
    local function AddLine(label, list)
        if #list > 0 then
            parts[#parts + 1] = label .. " (" .. #list .. "): " .. table.concat(list, ", ")
        end
    end
    AddLine("Respondieron", yes)
    AddLine("Rechazaron", no)
    AddLine("Sin responder", pending)
    AddLine("AFK", afk)
    AddLine("Desconectados", offline)
    mm:SendSequence(parts, 0.1, mm:GetChannel())
end

-- Inicia el check. `seconds` > 0 lanza el check con cuenta regresiva de chat
-- y resumen programado; `seconds` == 0 lo lanza INMEDIATO (comportamiento
-- nativo del juego): solo DoReadyCheck, sin ticks ni resumen programado — el
-- cierre y el resumen se delegan a READY_CHECK_FINISHED/CANCELED del juego.
function ReadyCheck:Start(seconds)
    if not InRaid() and not InParty() then
        Log("|cffff0000[RaidDominion]|r Debes estar en grupo para hacer un check.")
        return
    end
    if not (IsRaidLeader() or IsPartyLeader()) then
        Log("|cffff0000[RaidDominion]|r Solo el líder puede iniciar un check.")
        return
    end
    local immediate = (tonumber(seconds) == 0)
    local n = immediate and 0 or (tonumber(seconds) or 30)
    if not immediate then
        if n < 5 then n = 5 end
        if n > 60 then n = 60 end
    end

    if self.active then self:Cancel() end
    DoReadyCheck()
    local mm = RD.modules and RD.modules.messageManager
    local playerName = UnitName("player") or ""

    self.active = { units = {}, names = {}, confirmed = {} }
    self.active.units, self.active.names = SnapshotRoster()
    -- El iniciador ya está listo: el juego auto-confirma al líder del check.
    if playerName ~= "" then self.active.confirmed[playerName] = "yes" end

    if mm then
        -- Primer anuncio en t=0 (restaurado) + conteo ceñido al contador:
        -- 9s..., 5s... → ¡RESPONDAN AHORA!, 3s..., 2s..., 1s... El "¡RESPONDAN
        -- AHORA!" va justo tras el tick de 5s cuando existe; si no, cierra el
        -- conteo en t=N. Al final queda solo el resumen. En el modo inmediato
        -- (0s, nativo) no hay ticks: el juego cierra con sus propios eventos.
        mm:SendMessage(string.format((immediate and "= Ready check lanzado por %s (inmediato) =") or "= Ready check lanzado por %s (%ds) =",
            (playerName ~= "" and strupper(playerName)) or "?", n))
        local plan = {}
        local function At(second, text)
            plan[#plan + 1] = { second = second, text = text }
        end
        if not immediate then
            local hasFive = (n - 1) >= 5
            -- Con n=6 el primer tick es "5s..." y caería en el mismo segundo que el
            -- "5s... ¡RESPONDAN AHORA!" combinado (n-5=1): se omite el suelto.
            if n > 1 and not (hasFive and n - 5 == 1) then
                At(1, tostring(n - 1) .. "s...")
            end
            if hasFive then
                -- "¡RESPONDAN AHORA!" ACOMPAÑA al tick de 5s (mismo segundo); el 4s
                -- queda libre (sin tick propio).
                At(n - 5, "5s... ¡RESPONDAN AHORA!")
            end
            for _, s in ipairs({ 3, 2, 1 }) do
                if s < n - 1 then
                    At(n - s, tostring(s) .. "s...")
                end
            end
            if not hasFive then
                At(n, "¡RESPONDAN AHORA!")
            end
        end
        -- Los ticks y el fin se programan capturando la tabla `active` CONCRETA:
        -- si el check se cancela, termina antes o se inicia otro, `ReadyCheck.active`
        -- ya no coincide y los pendientes no se emiten ni cierran un check nuevo.
        local active = self.active
        for _, p in ipairs(plan) do
            mm:Schedule(p.second, function()
                if ReadyCheck.active == active then
                    mm:SendMessage(p.text, mm:GetChannel())
                end
            end)
        end
        -- Fin del check (resumen) justo después del último tick. En el modo
        -- inmediato (0s) NO se programa: el juego cierra con READY_CHECK_FINISHED
        -- (y el resumen lo envía ese manejador)
        if not immediate then
            mm:Schedule(n + 0.15, function()
                if ReadyCheck.active == active then
                    self:Finish()
                end
            end)
        end
    end
end

-- Finaliza el check y anuncia el resumen (idempotente).
function ReadyCheck:Finish()
    if not self.active then return end
    local active = self.active
    self.active = nil
    SendSummary(active)
end

-- Cancela el check (sin resumen).
function ReadyCheck:Cancel()
    if not self.active then return end
    self.active = nil
    if RD.messageManager then
        RD.messageManager:SendMessage("= Check cancelado =")
    end
end

-- Escucha los eventos del check SOLO cuando hay un check activo de este addon.
local f = CreateFrame("Frame")
f:RegisterEvent("READY_CHECK_CONFIRM")
f:RegisterEvent("READY_CHECK_FINISHED")
f:RegisterEvent("READY_CHECK_CANCELED")
f:SetScript("OnEvent", function(self, event, arg1)
    if not ReadyCheck.active then return end
    if event == "READY_CHECK_CONFIRM" then
        -- Capturar la respuesta EN VIVO: al confirmar, GetReadyCheckStatus(unit)
        -- distingue "ready"/"notready". Si el check ya terminó (READY_CHECK_
        -- FINISHED), los status se resetean y sin esto un "No" caería en
        -- "Respondieron". Si no hay status (nunca disponible), se cuenta como
        -- respondió ("yes").
        local name
        if arg1 then name = UnitName(arg1) end
        if name then
            local status = GetReadyCheckStatus and GetReadyCheckStatus(arg1) or nil
            ReadyCheck.active.confirmed[name] = (status == "notready") and "no" or "yes"
        end
    elseif event == "READY_CHECK_FINISHED" then
        ReadyCheck:Finish()
    elseif event == "READY_CHECK_CANCELED" then
        ReadyCheck:Cancel()
    end
end)

RD.modules = RD.modules or {}
RD.modules.readyCheck = ReadyCheck
return ReadyCheck
