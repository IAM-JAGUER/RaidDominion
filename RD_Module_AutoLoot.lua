--[[
    RD_Module_AutoLoot.lua
    PROPÓSITO: Motor del "Modo Auto" de botín (RD.modules.autoLoot): procesa los
              cadáveres que el jugador saquea con el ratón repartiendo el
              equipamiento verde o mejor entre el grupo/banda (excluyendo al
              maestro despojador) y dirigiendo recetas, materiales, dinero y
              basura al maestro, con confirmación POR EVENTO
              (LOOT_SLOT_CHANGED/LOOT_SLOT_CLEARED) y rotación de destinatarios
              cuando el servidor rechaza la entrega (bolsas llenas / ya lo tiene
              / fuera de rango). Salta los ítems que inician misiones. Sin
              C_Timer: los retardos se programan con MessageManager:Schedule y
              el avance se guía por eventos LOOT_* con token anti-eventos viejos.
              MODO PERMANENTE: la sesión NO termina sola; sigue en modo
              recolector hasta que el usuario la desactiva con el clic izquierdo
              en el botón "Auto" de la barra inferior (el ÚNICO control de
              on/off). Publica AUTO_LOOT_STATE_CHANGED(busy) para que el botón
              de la barra se resalte mientras la sesión está activa.
              El comportamiento de reparto es FIJO (RD_Module_AutoLootCore):
              recetas/materiales/basura/dinero -> maestro despojador; verde o
              mejor -> banda; ítems de misión -> se dejan. Sin opciones.
              ÍNDICES 3.3.5a: en GRUPO el candidato 1 es el maestro (FrameXML
              itera 1..MAX_PARTY_MEMBERS+1); el mapa de índices se deriva
              DETERMINISTA del roster (maestro=1, partyN=N+1) y NUNCA se reparte
              al índice del maestro. LootFrame.selectedSlot es Lua sin efecto en
              el lado C: no se usa para sondear.
              LIMITACIÓN 3.3.5a: el saqueo del mundo es SOLO con el ratón; NO se
              usan funciones protegidas (CastSpellByName/TargetUnit/
              RunMacroText/InteractUnit) porque ensucian la UI
              (ADDON_ACTION_FORBIDDEN). El Auto opera en MODO RECOLECTOR: el
              jugador saquea con el ratón y el addon procesa al instante.
    API PÚBLICA:
        - RD.modules.autoLoot:Run()        -- inicia la sesión Auto (acción del botón)
        - RD.modules.autoLoot:Stop()       -- aborta la sesión en curso
        - RD.modules.autoLoot:IsActive()   -- ¿sesión en curso? (estado del botón)
        - RD.modules.autoLoot:Initialize() -- registra eventos (PLAYER_LOGIN)
    EVENTOS: Registra LOOT_OPENED, LOOT_CLOSED, LOOT_SLOT_CHANGED, LOOT_SLOT_CLEARED.
             Publica AUTO_LOOT_STATE_CHANGED(busy) al iniciar/parar la sesión.
    DEPENDENCIA: la lógica pura vive en RD_Module_AutoLootCore.lua y la máquina
                 de reparto en RD_Module_AutoLootMaster.lua (orden en el .toc);
                 si faltan, el addon no revienta: Run() avisa de recargar la UI.
]]

local addonName, private = ...
local RD = _G.RaidDominion or {}
_G.RaidDominion = RD

-- Dependencias TOLERANTES: si un módulo hermano falta (instalación desincronizada
-- o .toc desactualizado), el addon no revienta en carga: Run() avisa.
local AutoLootCore = RD.modules and RD.modules.autoLootCore
local AutoLootMaster = RD.modules and RD.modules.autoLootMaster

-- Ajustes internos del modo Auto (ver AutoLootCore.TUNING; respaldo si el core no cargó).
local TUNING = (AutoLootCore and AutoLootCore.TUNING) or {
    MIN_GREEN = 2,
    ITEM_DELAY = 0.15,
    VERIFY_DELAY = 0.5,
    SCAN_LIMIT = 8,
    DEBUG = false,
}

local AutoLoot = {}

-- Estado interno de la sesión Auto
local state = {
    busy = false,
    token = 0,             -- contador anti-eventos obsoletos (Run/Stop/Finish lo invalidan)
    phase = "idle",        -- idle | opening | processing | close | collecting
    procToken = 0,         -- token del cadáver en proceso (invalida callbacks viejos si se cambia de ventana rápido)
    slotQueue = {},        -- slots del cadáver abierto
    slotPos = 1,
    stats = nil,
    masterName = nil,      -- nombre limpio del maestro despojador
    recipients = {},       -- lista barajada de destinatarios (sin el maestro)
}
AutoLoot.state = state

-- Cache persistente de unidades vistas (cadáveres cuya placa se recicló al morir).
local plateCache = {}

-- Mensaje de sistema
function AutoLoot:Msg(text)
    local mm = RD.modules and RD.modules.messageManager
    if mm and mm.SendSystemMessage then
        mm:SendSystemMessage(text)
    end
end

-- Depuración: solo cuando AutoLootCore.TUNING.DEBUG está activo
function AutoLoot:Debug(text)
    if TUNING.DEBUG then
        self:Msg("|cff888888[Auto]|r " .. tostring(text))
    end
end

-- Publica el estado de la sesión para que el botón "Auto" se resalte en vivo.
function AutoLoot:NotifyActive(active)
    if RD.events and RD.events.Publish then
        RD.events:Publish("AUTO_LOOT_STATE_CHANGED", active and true or false)
    end
end

-- Anuncia el ganador SIEMPRE por el canal de salida configurado en la pestaña
-- GENERAL (chat.channel): SendMessage sin canal usa MessageManager:GetChannel.
-- No hay opción de canal propia.
function AutoLoot:AnnounceWinner(playerName, itemLink)
    if not playerName or not itemLink then return end
    local msg = string.format("|cff00c8ff[RaidDominion]|r %s recibió: %s", playerName, itemLink)
    local mm = RD.modules and RD.modules.messageManager
    if not (mm and mm.SendMessage) then
        self:Msg(msg)
        return
    end
    local ok, err = pcall(mm.SendMessage, mm, msg)
    if ok then
        local ch = (mm.GetChannel and pcall(mm.GetChannel, mm)) or nil
        self:Debug(string.format("anuncio de ganador enviado (canal %s): %s recibió %s",
            tostring(select(2, ch) or "?"), playerName, itemLink))
    else
        self:Debug(string.format("anuncio de ganador: fallo al enviar (%s); se usa sistema como respaldo", tostring(err)))
        self:Msg(msg)
    end
end

-- Programa una función tras un retraso (sin C_Timer; fallback síncrono en tests).
function AutoLoot:Delay(seconds, fn)
    local mm = RD.modules and RD.modules.messageManager
    if mm and mm.Schedule then
        mm:Schedule(seconds or 0, fn)
    else
        fn()
    end
end

-- ¿El frame es una placa de nombre de 3.3.5a? (hijo de WorldFrame identificado
-- por la textura de flash del targeting, patrón de TidyPlates).
local function IsFrameNameplate(frame)
    if not frame or not frame.GetRegions then return false end
    local region = frame:GetRegions()
    if not region then return false end
    if region.GetObjectType and region:GetObjectType() == "Texture" then
        local t = region.GetTexture and region:GetTexture()
        if t == "Interface\\TargetingFrame\\UI-TargetingFrame-Flash" then
            return true
        end
    end
    return false
end

-- ¿Es un cadáver loteable? (existe, no es aliado y su vida llegó a 0)
local function IsDeadUnit(u)
    if not UnitExists(u) then return false end
    if UnitIsFriend and UnitIsFriend(u, "player") then return false end
    local health = UnitHealth(u)
    return (health ~= nil and health == 0)
end

-- Descubre los cadáveres detectables: objetivo y ratón primero, luego las
-- placas de WorldFrame, luego la cache persistente. Devuelve hasta el tope.
function AutoLoot:ScanCorpses(limit)
    local maxCorpses = tonumber(limit) or TUNING.SCAN_LIMIT
    local found = {}
    local seen = {}

    -- Registra una unidad en la cache (viva o muerta) para poder lotearla
    -- cuando muera aunque su placa se recicle.
    local function Record(u)
        if not u or not UnitExists(u) then return end
        local guid
        if UnitGUID then guid = UnitGUID(u) end
        if not guid then return end
        if not plateCache[u] then
            plateCache[u] = { guid = guid, firstSeen = (GetTime and GetTime()) or 0 }
        else
            plateCache[u].guid = guid
        end
    end

    local function Add(u)
        if not u or seen[u] then return end
        if not IsDeadUnit(u) then
            Record(u)
            return
        end
        Record(u)
        seen[u] = true
        local unitName
        if UnitName then unitName = UnitName(u) end
        found[#found + 1] = {
            unitId = u,
            guid = plateCache[u] and plateCache[u].guid,
            name = unitName or "",
        }
    end

    Add("target")
    Add("mouseover")

    local wf = WorldFrame
    if wf and wf.GetChildren then
        for i = 1, wf:GetNumChildren() do
            local child = select(i, wf:GetChildren())
            if child and child.GetName and IsFrameNameplate(child) and child.nameUnitId then
                Add(child.nameUnitId)
            end
        end
    end

    -- Cache: unidades vistas antes que siguen existiendo muertas
    for u, cached in pairs(plateCache) do
        if not seen[u] and UnitExists and UnitExists(u) then
            local guid
            if UnitGUID then guid = UnitGUID(u) end
            if guid and guid == cached.guid and IsDeadUnit(u) then
                Add(u)
            end
        end
    end

    -- Podar la cache (unidades que ya no existen en el mundo)
    for u in pairs(plateCache) do
        if not (UnitExists and UnitExists(u)) then
            plateCache[u] = nil
        end
    end

    if #found > maxCorpses then
        local trimmed = {}
        for i = 1, maxCorpses do trimmed[i] = found[i] end
        found = trimmed
    end
    return found
end

-- Apertura de cadáveres. En 3.3.5a el Auto opera SIEMPRE en MODO RECOLECTOR:
-- el jugador saquea con el ratón (clic derecho estándar) y RaidDominion procesa
-- el botín al instante (LOOT_OPENED), sin funciones protegidas (CastSpellByName/
-- TargetUnit/RunMacroText/InteractUnit ensucian la UI). Las llamadas de reparto
-- (GiveMasterLoot, LootSlot, CloseLoot) no ensucian la UI.
function AutoLoot:TryOpen(nearby)
    self:ArmCollector()
end

-- Activa el modo recolector: procesa cada cadáver que el jugador saquee con el
-- ratón (LOOT_OPENED). El modo es SIEMPRE permanente: solo el clic izquierdo
-- en el botón "Auto" (Run/Stop) lo detiene.
function AutoLoot:ArmCollector()
    state.phase = "collecting"
    self:Msg("|cff00c8ff[RaidDominion]|r Auto: sigue activo (permanente). Saquea el cadáver con el ratón y RaidDominion repartirá/recogerá solo. Clic en 'Auto' para desactivarlo.")
end

-- El botín está abierto (evento o botín previo): procesar los slots del cadáver.
-- Cada apertura incrementa procToken: si el jugador abre otro cadáver mientras
-- se procesa el anterior, los callbacks pendientes del anterior se invalidan.
function AutoLoot:StartProcessing()
    state.phase = "processing"
    state.procToken = state.procToken + 1
    state.stats.opened = state.stats.opened + 1
    state.slotPos = 1
    state.slotQueue = {}
    AutoLootMaster:Reset()
    local n = GetNumLootItems() or 0
    for i = 1, n do state.slotQueue[#state.slotQueue + 1] = i end
    self:Debug(string.format("botín abierto: %d slot(s) (procToken %d)", #state.slotQueue, state.procToken))
    -- Diagnóstico: cuántos candidatos de master loot expone el sondeo del lado C
    if TUNING.DEBUG and AutoLootCore and AutoLootCore.ProbeMasterLootCandidates then
        local probe = AutoLootCore:ProbeMasterLootCandidates()
        self:Debug(string.format("sondeo candidatos master: %d encontrado(s)", #(probe.orden or {})))
    end
    self:ProcessNextSlot()
end

-- Procesa el siguiente slot del cadáver abierto (clasifica y actúa).
function AutoLoot:ProcessNextSlot()
    if not state.busy then return end
    local ptoken = state.procToken
    local slot = state.slotQueue[state.slotPos]
    if not slot then
        self:CloseAndAdvance(ptoken)
        return
    end
    -- Diagnóstico honesto del slot (motivo del skip y rareza real del ítem)
    local link = (GetLootSlotLink and GetLootSlotLink(slot)) or nil
    local itemName = link and link:match("|h%[(.-)%]|h") or nil
    local quality = link and AutoLootCore:ItemQuality(link) or nil
    local isMoney = (LootSlotIsMoney and LootSlotIsMoney(slot)) or false
    local isItem = (LootSlotIsItem and LootSlotIsItem(slot)) or false
    local kind = AutoLootCore:ClassifySlot(slot)
    self:Debug(string.format(
        "slot %d -> %s | item=%s calidad=%s money=%s item=%s link=%s",
        slot, kind, itemName or "?", tostring(quality ~= nil and quality or "?"),
        tostring(isMoney), tostring(isItem), link and "sí" or "no"))
    local function Next()
        self:Delay(TUNING.ITEM_DELAY, function()
            if not state.busy or state.phase ~= "processing" or state.procToken ~= ptoken then return end
            state.slotPos = state.slotPos + 1
            self:ProcessNextSlot()
        end)
    end
    if kind == "money" then
        if LootSlot then LootSlot(slot) end
        state.stats.money = state.stats.money + 1
        Next()
    elseif kind == "quest" or kind == "locked" or kind == "skip" then
        if kind == "quest" and TUNING.DEBUG and LootSlotGetQuestInfo then
            -- Firma de LootSlotGetQuestInfo a confirmar en el cliente (modo debug)
            local q1, q2, q3 = LootSlotGetQuestInfo(slot)
            self:Debug(string.format("ítem de misión slot %d: q1=%s q2=%s q3=%s",
                slot, tostring(q1), tostring(q2), tostring(q3)))
        end
        state.stats.skipped = state.stats.skipped + 1
        Next()
    elseif kind == "master" then
        -- Recetas, materiales y basura: van al maestro despojador.
        self:GiveToMaster(slot)
    elseif kind == "give" then
        self:GiveSlot(slot)
    end
end

-- Da un ítem al maestro despojador (recetas, materiales de oficio, dinero no
-- aplica aquí — el dinero se lotea con LootSlot — y basura blanca/gris) usando
-- el índice REAL de su candidatura (en GRUPO siempre el índice 1; en banda su
-- posición en el roster). NUNCA usa LootSlot a ciegas: sin índice del maestro
-- el ítem se queda (no se arriesga saquear a tu bolsa si el método cambiara).
function AutoLoot:GiveToMaster(slot)
    local ptoken = state.procToken
    local masterName = state.masterName or (UnitName("player") or "")
    -- Índice REAL del maestro en este momento (sondeo por nombre; el orden de
    -- GetMasterLootCandidate no es estable). Si no se encuentra, se deja.
    local idx = AutoLootCore:IndexOfRecipient(masterName)
    if idx and GiveMasterLoot then
        pcall(GiveMasterLoot, slot, idx)
        state.stats.taken = state.stats.taken + 1
        self:Debug(string.format("slot %d -> %s (al maestro, índice %d)", slot, masterName, idx))
    else
        -- Sin índice del maestro: se deja el ítem. No se arriesga LootSlot
        -- (si el método dejara de ser "master", saquearía el ítem a tu bolsa).
        state.stats.unassigned = state.stats.unassigned + 1
        self:Debug(string.format("slot %d -> sin índice del maestro: se queda sin recoger", slot))
    end
    self:Delay(TUNING.ITEM_DELAY, function()
        if not state.busy or state.phase ~= "processing" or state.procToken ~= ptoken then return end
        state.slotPos = state.slotPos + 1
        self:ProcessNextSlot()
    end)
end

-- Reparte un ítem de valor a un destinatario aleatorio del grupo. CADA
-- (slot, índice) SE ENTREGA UNA SOLA VEZ: AutoLootMaster registra los probados,
-- así que ningún candidato recibe el mismo slot dos veces (evita duplicados).
-- NUNCA se reparte al índice del maestro (guarda contra mapas desfasados: un
-- índice erróneo no puede darte el ítem a ti). La confirmación es POR EVENTO
-- (LOOT_SLOT_CHANGED/LOOT_SLOT_CLEARED) con refuerzo del flag "locked" de
-- GetLootSlotInfo; si el servidor rechaza la entrega dentro del timeout
-- (verifyDelay * 2), se rota al siguiente destinatario real. Agotados todos,
-- el ítem queda SIN REPARTIR y la ventana se deja abierta (lo decide
-- CloseAndAdvance).
function AutoLoot:GiveSlot(slot)
    local ptoken = state.procToken
    local itemLink = GetLootSlotLink(slot)
    local done = false
    local recipient = nil

    local function NextSlot()
        self:Delay(TUNING.ITEM_DELAY, function()
            if not state.busy or state.phase ~= "processing" or state.procToken ~= ptoken then return end
            state.slotPos = state.slotPos + 1
            self:ProcessNextSlot()
        end)
    end

    local function FinishGive(given)
        if done then return end
        done = true
        if given and recipient then
            state.stats.given = state.stats.given + 1
            AutoLootCore:LogDistribution(recipient, itemLink)
            self:AnnounceWinner(recipient, itemLink)
            self:Debug(string.format("slot %d -> %s (confirmado)", slot, recipient))
        else
            state.stats.unassigned = state.stats.unassigned + 1
            self:Debug(string.format("slot %d NO confirmado: se queda sin repartir", slot))
        end
        NextSlot()
    end

    local function TryGive()
        if done or not state.busy or state.procToken ~= ptoken then return end
        local masterName = state.masterName or (UnitName("player") or "")
        local masterClean = AutoLootCore:CleanName(masterName)
        local pl = AutoLootMaster:NextRecipient(state.recipients)
        if not pl then
            -- Todos los destinatarios probados: sin repartir.
            state.stats.unassigned = state.stats.unassigned + 1
            NextSlot()
            return
        end
        -- Anti-maestro defensivo: si el destinatario fuera el maestro (fallo de
        -- BuildCandidates), se descarta.
        if AutoLootCore:CleanName(pl) == masterClean then
            self:Debug(string.format("destinatario '%s' es el maestro: descartado", pl))
            TryGive()
            return
        end
        -- Índice REAL del destinatario en ESTE momento: GetMasterLootCandidate NO
        -- tiene un orden estable (documentado), así que se busca por NOMBRE aquí y
        -- ahora (patrón de los addons de master loot correctos). Si no se
        -- encuentra, NO se adivina: el ítem se deja (nunca a una persona errónea).
        local idx = AutoLootCore:IndexOfRecipient(pl)
        if not idx then
            self:Debug(string.format("no se pudo resolver el índice real de '%s' (slot %d): descartado, sin adivinar", pl, slot))
            TryGive()
            return
        end
        recipient = pl
        if GiveMasterLoot then pcall(GiveMasterLoot, slot, idx) end
        self:Debug(string.format("GiveMasterLoot(slot %d -> %s, idx %d)", slot, pl, idx))
        -- Confirmación por evento con timeout (verifyDelay * 2) y refuerzo locked
        local checksLeft = 2
        local function CheckOnce()
            if done or not state.busy or state.procToken ~= ptoken then return end
            if AutoLootMaster:IsConfirmed(slot) then
                self:Debug(string.format("asignación confirmada: %s recibió el slot %d (LOOT_SLOT_CHANGED)", pl, slot))
                FinishGive(true)
                return
            end
            -- Confirmación VISUAL (más fiable que el evento en algunos clientes):
            -- si el slot ya no tiene ítem, la entrega se dio (el ítem salió del
            -- cadáver). Si el servidor rechazara la entrega, el ítem seguiría.
            local okSlot, isItem = pcall(function()
                return (LootSlotIsItem and LootSlotIsItem(slot)) == true
            end)
            if okSlot and not isItem then
                AutoLootMaster:Confirm()
                self:Debug(string.format("asignación confirmada: %s recibió el slot %d (slot vacío)", pl, slot))
                FinishGive(true)
                return
            end
            -- Refuerzo: el servidor marcó el slot como bloqueado (locked) sin
            -- disparar el evento en algunos clientes.
            local okLocked, _, _, _, _, locked = pcall(GetLootSlotInfo, slot)
            if okLocked and locked then
                AutoLootMaster:Confirm()
                self:Debug(string.format("asignación confirmada: %s recibió el slot %d (locked)", pl, slot))
                FinishGive(true)
                return
            end
            if checksLeft > 0 then
                checksLeft = checksLeft - 1
                self:Delay(TUNING.VERIFY_DELAY, CheckOnce)
            else
                -- Rechazada: rotar al siguiente destinatario real (nunca re-da
                -- el mismo slot+índice). La ventana queda abierta si se agotan.
                self:Debug(string.format("entrega a '%s' rechazada para el slot %d: probar otro", pl, slot))
                TryGive()
            end
        end
        self:Delay(TUNING.VERIFY_DELAY, CheckOnce)
    end

    AutoLootMaster:BeginGive(slot, itemLink)
    TryGive()
end

-- Cierra el cadáver abierto tras dejarlo asentar. Si quedaron ítems SIN
-- REPARTIR, la ventana NO se cierra (se deja abierta para gestionarlos a mano:
-- evita el "se cerró y no sé si se recogió"). El avance lo decide
-- LOOT_CLOSED/AfterCorpseClosed.
function AutoLoot:CloseAndAdvance(ptoken)
    if not state.busy then return end
    local stats = state.stats
    if stats and stats.unassigned and stats.unassigned > 0 then
        state.phase = "collecting"
        self:Msg(string.format(
            "|cffff8000[RaidDominion]|r Auto: %d ítem(s) no pudieron repartirse; la ventana de botín queda ABIERTA para gestionarlos.",
            stats.unassigned))
        return
    end
    state.phase = "close"
    -- Dejar asentar las entregas antes de cerrar (el servidor procesa los gives)
    self:Delay(0.5, function()
        if not state.busy or state.procToken ~= (ptoken or state.procToken) then return end
        if CloseLoot then pcall(CloseLoot) end
        -- Respaldo por si LOOT_CLOSED no llega (cierre silencioso del servidor)
        self:Delay(1.5, function()
            if state.busy and state.phase == "close" and state.procToken == (ptoken or state.procToken) then
                self:AfterCorpseClosed()
            end
        end)
    end)
end

-- Tras cerrar un cadáver: feedback inmediato por cadáver y seguir siempre con
-- el recolector (modo permanente; solo el clic en "Auto" detiene la sesión).
function AutoLoot:AfterCorpseClosed()
    local s = state.stats
    local parts = {
        string.format("Cadáver procesado: repartidos %d · para ti %d (recetas/materiales/basura)", s.given, s.taken),
    }
    if s.money and s.money > 0 then
        parts[#parts + 1] = string.format("dinero %d", s.money)
    end
    if s.unassigned and s.unassigned > 0 then
        parts[#parts + 1] = string.format("|cffff0000%d sin asignar|r", s.unassigned)
    end
    local line = "|cff00c8ff[RaidDominion]|r " .. table.concat(parts, " · ")
    self:Msg(line .. " · |cff00c8ffAuto sigue activo|r")
    self:ContinueSweep()
end

-- Re-barrido permanente: vuelve a detectar cadáveres cercanos y sigue
-- repartiendo mientras la sesión siga activa. Sin cadáveres, espera en modo
-- recolector a que el jugador saquee el siguiente (LOOT_OPENED lo procesará).
-- Si se pierde el rol de maestro o el grupo, la sesión se detiene sola.
function AutoLoot:ContinueSweep()
    if not state.busy then return end
    if not AutoLootCore:IsMasterLooter() or #AutoLootCore:GetRoster() < 2 then
        self:Msg("|cffff8000[RaidDominion]|r Auto: ya no eres el maestro despojador o no hay grupo; sesión detenida.")
        self:Finish()
        return
    end
    state.phase = "collecting"
    self:Debug("barrido permanente: re-detectando cadáveres...")
    local nearby = self:ScanCorpses(TUNING.SCAN_LIMIT)
    if #nearby > 0 then
        if GetNumLootItems and GetNumLootItems() > 0 then
            self:StartProcessing()
        else
            self:TryOpen(nearby)
        end
        return
    end
    self:ArmCollector()
end

-- Termina la sesión: informe final SIEMPRE por el canal de salida configurado
-- por el usuario en la pestaña GENERAL (chat.channel) e invalidación del token.
function AutoLoot:Finish()
    local stats = state.stats
    state.phase = "idle"
    state.busy = false
    AutoLootMaster:Reset()
    local report = stats and AutoLootCore:FormatReport(stats) or nil
    state.token = state.token + 1
    state.stats = nil
    state.masterName = nil
    self:NotifyActive(false)
    if report and report ~= "" then
        local mm = RD.modules and RD.modules.messageManager
        if mm and mm.SendMessage then
            mm:SendMessage(report)
        else
            self:Msg(report)
        end
    end
end

-- Aborta la sesión en curso (clic izquierdo en "Auto" mientras está activa).
-- Emite el informe acumulado y avisa de la parada.
function AutoLoot:Stop()
    if state.busy then
        self:Finish()
    end
    self:Msg("|cffff8000[RaidDominion]|r Auto: barrido detenido.")
end

-- ¿Hay una sesión Auto en curso? (estado del botón de la barra inferior)
function AutoLoot:IsActive()
    return state.busy == true
end

-- ==================== Punto de entrada (clic izquierdo) ====================

function AutoLoot:Run()
    if state.busy then
        self:Msg("|cffff8000[RaidDominion]|r Auto: ya hay una sesión en curso.")
        return false
    end
    if not AutoLootCore or not AutoLootMaster then
        self:Msg("|cffff8000[RaidDominion]|r Auto: faltan módulos (AutoLootCore/AutoLootMaster). Recarga la UI (/reload) para cargarlos.")
        return false
    end
    local roster = AutoLootCore:GetRoster()
    if #roster < 2 then
        self:Msg("|cffff8000[RaidDominion]|r Auto: necesitas estar en grupo o banda.")
        return false
    end
    if not AutoLootCore:IsMasterLooter() then
        self:Msg("|cffff0000[RaidDominion]|r Auto: solo el maestro despojador puede repartir el botín.")
        return false
    end
    if GetLootMethod then
        local method, partyID = GetLootMethod()
        self:Debug(string.format("método de botín: %s (partyID %s)", tostring(method), tostring(partyID)))
    end

    state.busy = true
    state.token = state.token + 1
    state.stats = AutoLootCore:NewStats()
    AutoLootMaster:Reset()
    local masterName = UnitName("player") or ""
    if masterName == "" then
        state.busy = false
        self:Msg("|cffff0000[RaidDominion]|r Auto: no se pudo identificar al maestro despojador.")
        return false
    end
    state.masterName = masterName
    -- Doble exclusión del maestro: BuildCandidates ya lo excluye por nombre
    -- limpio; este segundo filtro es a prueba de fallos (nunca es destinatario).
    state.recipients = AutoLootCore:Shuffle(AutoLootCore:BuildCandidates(roster, masterName))
    local masterClean = AutoLootCore:CleanName(masterName)
    local filtered = {}
    for _, name in ipairs(state.recipients) do
        if AutoLootCore:CleanName(name) ~= masterClean then
            filtered[#filtered + 1] = name
        end
    end
    state.recipients = filtered

    self:NotifyActive(true)
    local nearby = self:ScanCorpses(TUNING.SCAN_LIMIT)
    self:Msg(string.format("|cff00c8ff[RaidDominion]|r Auto activo (permanente): %d cadáver(es) detectado(s) cerca; repartiendo a %d jugador(es). Clic en 'Auto' para desactivarlo.",
        #nearby, #state.recipients))

    -- Botín ya abierto: procesarlo de inmediato (lo más fiable).
    if GetNumLootItems and GetNumLootItems() > 0 then
        self:StartProcessing()
    else
        self:TryOpen(nearby)
    end
    return true
end

-- ==================== Eventos del juego ====================

function AutoLoot:LOOT_OPENED()
    if not state.busy then return end
    -- Se procesa CUALQUIER ventana que se abra durante la sesión, aunque ya se
    -- esté procesando otro cadáver: procToken invalida los callbacks del anterior.
    self:StartProcessing()
end

function AutoLoot:LOOT_CLOSED()
    if not state.busy then return end
    -- Confirmar la entrega pendiente: si la ventana se cerró, el ítem en curso
    -- se dio (o la ventana se gestionó manualmente). El CheckOnce lo detecta.
    AutoLootMaster:ConfirmPending()
    if state.phase == "processing" or state.phase == "close" or state.phase == "collecting" then
        -- Si ya hay OTRA ventana abierta (el jugador cambió de cadáver antes de
        -- que el anterior cerrara), no cortar: su LOOT_OPENED la procesará.
        if GetNumLootItems and GetNumLootItems() > 0 then
            return
        end
        self:AfterCorpseClosed()
    end
end

-- El servidor cambió el contenido/estado de un slot: es la CONFIRMACIÓN de que
-- la entrega del slot pendiente fue aceptada (LOOT_SLOT_CHANGED).
function AutoLoot:LOOT_SLOT_CHANGED(slot)
    if not state.busy then return end
    AutoLootMaster:OnSlotChanged(slot)
end

-- El servidor retiró el ítem del slot (LOOT_SLOT_CLEARED): también confirma
-- que la entrega del slot pendiente surtió efecto.
function AutoLoot:LOOT_SLOT_CLEARED(slot)
    if not state.busy then return end
    AutoLootMaster:OnSlotCleared(slot)
end

-- Registra los eventos del juego. Se llama desde RD_Init en PLAYER_LOGIN.
function AutoLoot:Initialize()
    if self._initialized then return end
    self._initialized = true
    local f = CreateFrame("Frame", "RDAutoLootEvents", UIParent)
    f:RegisterEvent("LOOT_OPENED")
    f:RegisterEvent("LOOT_CLOSED")
    f:RegisterEvent("LOOT_SLOT_CHANGED")
    f:RegisterEvent("LOOT_SLOT_CLEARED")
    f:SetScript("OnEvent", function(_, event, arg1)
        if event == "LOOT_OPENED" then
            AutoLoot:LOOT_OPENED()
        elseif event == "LOOT_CLOSED" then
            AutoLoot:LOOT_CLOSED()
        elseif event == "LOOT_SLOT_CHANGED" then
            AutoLoot:LOOT_SLOT_CHANGED(arg1)
        elseif event == "LOOT_SLOT_CLEARED" then
            AutoLoot:LOOT_SLOT_CLEARED(arg1)
        end
    end)
    self._eventFrame = f
end

RD.modules = RD.modules or {}
RD.modules.autoLoot = AutoLoot
return AutoLoot