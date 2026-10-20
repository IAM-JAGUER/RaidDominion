--[[
    RD_Utils_Registry.lua
    PROPÓSITO: Genera y guarda en las SavedVariables (RaidDominionDB vía
              RD.config) un registro detallado POR PERSONAJE, equivalente v3
              de la opción "Lista" de la v2. La DB es account-wide, así que
              cada personaje guarda SU árbol bajo la clave "Nombre-Reino"
              (la misma de RD.utils.characters): registrar N personajes
              convive en una sola DB sin borrarse entre sí, incluida la info
              de hermandad propia de cada uno (cuenta con varias guilds).
              Árbol por personaje:
                player       -> nombre, reino, nivel, raza, clase, talento,
                                equipamiento completo (slots 0..19) y las
                                proyecciones al portal: `note` (nota global del
                                personaje; vacía si no tiene) e `instances`
                                (snapshot de instancias guardadas)
                objectives   -> objetivos personales de equipamiento y metas
                                de moneda (solo metas; rama compartida con el
                                portal web, sin iconos ni flags de seguimiento)
                assignments  -> ítems (roles/abilities/buffs/auras) asignados
                                a este jugador
                bands        -> bandas donde figura (compartidas), con rol/
                                dual/líder/asistencia/sanción de este jugador
                spammer      -> estado del spammer de banda y del de reglas
                guild        -> SOLO si hay hermandad: nombre, rango propio y
                                la jerarquía COMPLETA de los N rangos (índice
                                y nombre, ordenada de GM/0 a inferior); si el
                                jugador es GM incluye además la lista completa
                                de miembros SIN nota pública ni de oficial;
                                sin hermandad la sección se omite.
              COMPARTIDO (fuera del registro): configuración general, roles,
              abilities, auras, buffs, mechanics, rules y bands viven UNA sola
              vez en la DB para toda la cuenta (sin redundancia entre personajes).
    API PÚBLICA:
        - RD.utils.registry:Capture(silent)  -- registra AL PERSONAJE ACTUAL
        - RD.utils.registry:Get(key)         -- árbol propio o de otro personaje
        - RD.utils.registry:GetAll()         -- contenedor completo {clave=árbol}
        - RD.utils.registry:Count()          -- personajes registrados
        - RD.utils.registry:GetCurrentKey()  -- clave "Nombre-Reino" actual
        - RD.utils.registry:HasKey(key)      -- ¿existe ese registro?
              CONTRATO CON EL PORTAL:
                - registry["Nombre-Reino"].objectives comparte objetivos
                  personales de equipo y metas de moneda; no expone la raíz
                  local itemGoals ni sus datos de seguimiento.
                - player.note / player.instances: la nota global del personaje
                  (store local playerNotes) y el snapshot de las instancias
                  guardadas (lectura en vivo RD_Utils_Instances) se proyectan
                  al portal SOLO al pulsar "Registrar"; sin esos módulos las
                  claves se omiten y la web conserva lo ya publicado.
              EVENTOS: GUILD_ROSTER_UPDATE (descarga diferida del roster para GM).
                       Dispara CONFIG_CHANGED("registry.<Nombre-Reino>") vía RD.config:Set.
]]

local addonName, private = ...
local RD = _G.RaidDominion or {}
_G.RaidDominion = RD

local Registry = {}

local Log = (RD.UIUtils and RD.UIUtils.Log) or function(msg) print(msg) end

-- Espera activa de GUILD_ROSTER_UPDATE (una sola a la vez; sin C_Timer)
local rosterWaiter = nil

-- ============================================================================
-- Helpers
-- ============================================================================

-- Clave del personaje actual ("Nombre-Reino"), misma convención que
-- RD.utils.characters. Fallback local por robustez en tests/orden de carga.
function Registry:GetCurrentKey()
    local chars = RD.utils and RD.utils.characters
    if chars and chars.GetCurrentKey and chars:GetCurrentKey() then
        return chars:GetCurrentKey()
    end
    local name = UnitName("player") or "?"
    return tostring(name) .. "-" .. tostring(GetRealmName() or "?")
end

local function CleanName(name)
    if RD.UIUtils and RD.UIUtils.CleanName then
        return RD.UIUtils.CleanName(name)
    end
    local clean = string.gsub(tostring(name or ""), "%-.*", "")
    clean = string.gsub(clean, "%s+", "")
    return string.lower(clean)
end

-- Servidor (host del realmlist, p.ej. "logon.warmane.com"), distinto del
-- reino del mundo (GetRealmName). Se lee del CVar "realmList" (el cliente lo
-- persiste en Config.wtf); si el cliente no lo expone, fallback al reino.
local function GetServerName()
    local server = GetCVar and GetCVar("realmList")
    if type(server) ~= "string" or server == "" then
        return GetRealmName() or ""
    end
    server = string.gsub(server, ":%d+$", "")
    return string.lower(server)
end

-- Copia profunda (fallback local si UIUtils aún no cargó)
local function DeepCopy(orig)
    if RD.UIUtils and RD.UIUtils.DeepCopy then
        return RD.UIUtils.DeepCopy(orig)
    end
    if type(orig) ~= "table" then return orig end
    local copy = {}
    for k, v in pairs(orig) do
        copy[k] = DeepCopy(v)
    end
    return copy
end

-- Copia solo los canales marcados (true) de una tabla {CANAL=bool}
local function CopyChannels(channels)
    local out = {}
    if type(channels) == "table" then
        for ch, on in pairs(channels) do
            if on then out[ch] = true end
        end
    end
    return out
end

-- ============================================================================
-- Sección: jugador (clase, nivel, equipamiento)
-- ============================================================================

-- Slots de inventario con equipo: 0 munición .. 19 tabardo
local EQUIP_SLOTS = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19 }

local function BuildEquipment()
    local items = {}
    local ilvlSum, ilvlCount = 0, 0
    for _, slot in ipairs(EQUIP_SLOTS) do
        local link = GetInventoryItemLink("player", slot)
        if link then
            local name, _, quality, iLevel = GetItemInfo(link)
            -- Ítem no cacheado: al menos rescata el nombre visible del link
            name = name or string.match(link, "%[([^%]]+)%]") or ("Slot " .. tostring(slot))
            items[#items + 1] = {
                slot = slot,
                name = name,
                quality = tonumber(quality),
                ilvl = tonumber(iLevel),
            }
            if iLevel then
                ilvlSum = ilvlSum + iLevel
                ilvlCount = ilvlCount + 1
            end
        end
    end
    table.sort(items, function(a, b) return a.slot < b.slot end)
    return items, #items, (ilvlCount > 0 and math.floor(ilvlSum / ilvlCount + 0.5) or 0)
end

local function BuildPlayer()
    local className, classFile = UnitClass("player")
    local raceName, raceFile = UnitRace("player")
    local player = {
        name = UnitName("player") or "",
        realm = GetRealmName() or "",
        server = GetServerName(),
        level = UnitLevel("player"),
        race = raceName or "",
        raceFile = raceFile or "",
        class = className or "",
        classFile = classFile or "",
        talentTree = 0,
        talentSpec = "",
    }
    -- Talento principal (índice 1..3 y su nombre localizado), si existe la API
    if GetPrimaryTalentTree and GetTalentTabInfo then
        local tree = GetPrimaryTalentTree()
        tree = tonumber(tree) or 0
        if tree > 0 then
            player.talentTree = tree
            player.talentSpec = GetTalentTabInfo(tree) or ""
        end
    end
    local equipment, equipped, avgIlvl = BuildEquipment()
    player.equipment = equipment
    player.equipmentCount = equipped
    player.avgIlvl = avgIlvl
    return player
end

-- ============================================================================
-- Sección: proyecciones locales al portal (nota global + instancias guardadas)
-- ============================================================================

-- Nota GLOBAL del personaje actual (RD_Utils_PlayerNotes, store local del
-- addon). Se exporta SIEMPRE que el módulo esté disponible (incluso vacía):
-- así la web distingue "sin nota" de "nota borrada" y un SV sin la clave
-- (addon < 3.1.0) conserva lo ya publicado. Nunca se exportan las notas de
-- otros personajes del store.
local function BuildNote()
    local notes = RD.utils and RD.utils.playerNotes
    if not (notes and notes.GetText) then return nil end
    local name = UnitName("player")
    if not name or name == "" then return "" end
    return tostring(notes:GetText(name) or "")
end

-- Snapshot de instancias guardadas para el portal (nombre, dificultad y
-- reinicio ABSOLUTO): lo proyecta RD_Utils_Instances.Export. Sin el módulo la
-- clave se omite (no pisa lo ya publicado); con el módulo se exporta SIEMPRE
-- una lista (posiblemente vacía) para que un re-registro sin instancias limpie
-- las expiradas.
local function BuildInstances()
    local util = RD.utils and RD.utils.instances
    if not (util and util.Export) then return nil end
    return util:Export()
end

-- ============================================================================
-- Sección: objetivos personales compartidos con el portal
-- ============================================================================

-- Acepta solo números finitos; strings numéricos también se consideran datos
-- malformados para el contrato y se tratan como nil.
local function ToFiniteNumber(value)
    if type(value) ~= "number" then
        return nil
    end
    local number = value
    if not number or number ~= number or number == math.huge or number == -math.huge then
        return nil
    end
    return number
end

local function HasUsableName(name)
    return type(name) == "string" and string.find(name, "%S") ~= nil
end

-- Lee cada API por separado: el registro sigue siendo válido si falta el
-- módulo, uno de sus métodos o si una API devuelve una subtabla no disponible.
local function ReadGoalList(itemGoals, methodName)
    local method = itemGoals[methodName]
    if type(method) ~= "function" then
        return {}
    end
    local ok, goals = pcall(method, itemGoals)
    if not ok or type(goals) ~= "table" then
        return {}
    end
    return goals
end

-- Proyecta únicamente los campos públicos acordados. No serializa la raíz
-- itemGoals: itemTracked/currencyTracked/instancesTracked e iconos son locales.
local function BuildObjectives()
    local objectives = { equipment = {}, currencies = {} }
    local utils = RD.utils
    local itemGoals = type(utils) == "table" and utils.itemGoals or nil
    if type(itemGoals) ~= "table" then
        return objectives
    end

    local slotGoals = ReadGoalList(itemGoals, "SlotGoals")
    for slot, goal in pairs(slotGoals) do
        local numericSlot = type(slot) == "number" and ToFiniteNumber(slot) or nil
        local validSlot = numericSlot and numericSlot >= 0 and numericSlot <= 19
            and numericSlot == math.floor(numericSlot)
        if validSlot and type(goal) == "table" and HasUsableName(goal.name) then
            objectives.equipment[#objectives.equipment + 1] = {
                slot = numericSlot,
                name = goal.name,
                itemID = ToFiniteNumber(goal.itemID),
                ilvl = ToFiniteNumber(goal.ilvl),
                quality = ToFiniteNumber(goal.quality),
                done = goal.done == true or goal.done == 1,
            }
        end
    end
    table.sort(objectives.equipment, function(a, b)
        return a.slot < b.slot
    end)

    local currencyGoals = ReadGoalList(itemGoals, "CurrencyGoals")
    for name, goal in pairs(currencyGoals) do
        local target = type(goal) == "table" and ToFiniteNumber(goal.target) or nil
        if HasUsableName(name) and target and target > 0 then
            objectives.currencies[#objectives.currencies + 1] = {
                name = name,
                target = target,
                reached = goal.reached == true or goal.reached == 1,
            }
        end
    end
    table.sort(objectives.currencies, function(a, b)
        return a.name < b.name
    end)

    return objectives
end

-- ============================================================================
-- Sección: asignaciones vigentes para ESTE jugador
-- ============================================================================

local ASSIGNABLE_LISTS = { "roles", "abilities", "buffs", "auras" }

local function BuildAssignments(playerKey)
    local out = { count = 0 }
    for _, listKey in ipairs(ASSIGNABLE_LISTS) do
        local tbl = {}
        if RD.utils and RD.utils.assignments and RD.utils.assignments.Get then
            tbl = RD.utils.assignments:Get(listKey) or {}
        end
        if type(tbl) == "table" then
            local mine = {}
            for itemName, assigned in pairs(tbl) do
                if assigned and assigned ~= "" and CleanName(assigned) == playerKey then
                    mine[#mine + 1] = itemName
                end
            end
            if #mine > 0 then
                table.sort(mine)
                out[listKey] = mine
                out.count = out.count + #mine
            end
        end
    end
    return out
end

-- ============================================================================
-- Sección: bandas donde está registrado este jugador
-- ============================================================================

local function BuildBands(playerKey)
    local out = {}
    local bands = {}
    if RD.utils and RD.utils.bands and RD.utils.bands.GetBands then
        bands = RD.utils.bands:GetBands() or {}
    end
    for _, band in ipairs(bands) do
        local players = type(band.players) == "table" and band.players or {}
        for _, m in ipairs(players) do
            if m.name and CleanName(m.name) == playerKey then
                out[#out + 1] = {
                    band = band.name or "",
                    schedule = band.schedule or "",
                    minGS = tonumber(band.minGS) or 0,
                    role = m.role or "",
                    dual = m.dual or "",
                    leader = m.leader or "",
                    points = tonumber(m.points) or 0,
                    sanction = m.sanction or "",
                }
                break
            end
        end
    end
    return out
end

-- ============================================================================
-- Sección: estado de los spammers (banda y reglas)
-- ============================================================================

local function BuildSpammer()
    local state = {
        band = { active = false, bandIndex = 0, timeLeft = 0 },
        rules = { active = false, duration = 45, channels = {}, selectedTitle = "" },
    }
    local mod = RD.modules and RD.modules.spammer
    if mod then
        state.band.active = (mod.IsActive and mod:IsActive()) or false
        state.band.bandIndex = tonumber(mod.ActiveIndex and mod:ActiveIndex()) or 0
        state.band.timeLeft = math.floor((tonumber(mod.TimeLeft and mod:TimeLeft()) or 0) + 0.5)
    end
    local rmod = RD.modules and RD.modules.rulesSpammer
    if rmod and rmod.IsActive then
        state.rules.active = (rmod:IsActive()) or false
    end
    if RD.config and RD.config.Get then
        state.rules.duration = tonumber(RD.config:Get("ui.rulesSpammer.duration", 45)) or 45
        state.rules.channels = CopyChannels(RD.config:Get("ui.rulesSpammer.channels"))
        state.rules.selectedTitle = tostring(RD.config:Get("ui.rulesSpammer.selectedTitle", "") or "")
    end
    return state
end

-- ============================================================================
-- Sección: hermandad (condicional: GM / miembro / sin hermandad)
-- ============================================================================

-- Jerarquía completa y ordenada de los N rangos de la hermandad: índice 0 (GM,
-- el más alto) hasta N-1. Funciona en TODOS los casos combinando dos fuentes:
--   1) ROSTER (autoritativo sobre los rangos EN USO): GetGuildRosterInfo da el
--      rankIndex 0-based (contiguo 0..max) y el nombre de cada rango. Disponible
--      para cualquier miembro; si aún no cargó (rosterPendiente) no aporta nada.
--   2) GUILDCONTROL (completa rangos sin miembros y nombres faltantes):
--      GuildControlGetRankName es 1-based (1 = GM). Se usa su conteo como techo,
--      pero si quedara corto/impreciso, el máximo del roster evita perder rangos.
-- Se unen por índice y se devuelve 0..maxIndex en orden. Devuelve tabla vacía
-- solo si ambas fuentes no responden.
local MAX_GUILD_RANKS = 10
local function BuildGuildRanks()
    local ranks = {}
    local nameByIndex = {}
    local maxIndex = -1

    -- Fuente 1: roster. rankIndex 0-based, contiguo; cada miembro aporta además
    -- el nombre de su rango (mismo nombre para todos los del mismo rango).
    local numMembers = GetNumGuildMembers and (GetNumGuildMembers(true) or 0) or 0
    for i = 1, numMembers do
        local _, rankName, rankIndex = GetGuildRosterInfo(i)
        rankIndex = tonumber(rankIndex)
        if rankIndex and rankIndex >= 0 then
            if rankIndex > maxIndex then maxIndex = rankIndex end
            if not nameByIndex[rankIndex] or nameByIndex[rankIndex] == "" then
                nameByIndex[rankIndex] = rankName or ""
            end
        end
    end

    -- Fuente 2: GuildControl (1-based, 1 = GM), techo = conteo (o MAX si falta).
    -- Cubre rangos sin miembros y se detiene en el primer hueco (nil o "").
    if GuildControlGetNumRanks and GuildControlGetRankName then
        local numRanks = tonumber(GuildControlGetNumRanks()) or MAX_GUILD_RANKS
        numRanks = math.min(numRanks, MAX_GUILD_RANKS)
        for i = 1, numRanks do
            local name = GuildControlGetRankName(i)
            if name == nil or name == "" then
                break
            end
            local idx = i - 1
            if idx > maxIndex then maxIndex = idx end
            if not nameByIndex[idx] or nameByIndex[idx] == "" then
                nameByIndex[idx] = name
            end
        end
    end

    for idx = 0, maxIndex do
        ranks[#ranks + 1] = {
            index = idx,
            name = nameByIndex[idx] or "",
        }
    end
    return ranks
end

-- Construye la sección guild. Devuelve (guild|nil, rosterPendiente).
-- Sin hermandad devuelve nil (la sección se omite por completo). Para GM
-- incluye el roster COMPLETO; jamás se leen las notas pública/oficial del
-- roster (campos 7 y 8 de GetGuildRosterInfo).
local function BuildGuild()
    if not IsInGuild() then
        return nil, false
    end

    local guildName, rankName, rankIndex = GetGuildInfo("player")
    rankIndex = tonumber(rankIndex) or 0
    local isGM = (rankIndex == 0)

    local guild = {
        name = guildName or "",
        rank = rankName or "",
        rankIndex = rankIndex,
        isGM = isGM,
        ranks = BuildGuildRanks(),
    }

    -- El roster completo es exclusivo del GM; requiere descarga previa
    local numTotal = GetNumGuildMembers(true)
    if not isGM then
        guild.numMembers = numTotal
        return guild, false
    end

    if numTotal == 0 then
        -- Roster aún no descargado: se completa al llegar GUILD_ROSTER_UPDATE
        return guild, true
    end

    guild.numMembers = numTotal
    guild.memberList = {}
    for i = 1, numTotal do
        local name, mName, mRankIdx, level, class, _, _, _, isOnline, _, classFile =
            GetGuildRosterInfo(i)
        if name and name ~= "" then
            guild.memberList[#guild.memberList + 1] = {
                name = name,
                rank = mName or "",
                rankIndex = tonumber(mRankIdx) or 0,
                level = tonumber(level) or 0,
                class = class or "",
                classFile = classFile or "",
                online = (tonumber(isOnline) == 1),
            }
        end
    end
    return guild, false
end

-- Espera la descarga del roster y re-captura cuando llegue el evento
local function RequestRosterAndRecapture()
    pcall(GuildRoster)
    if rosterWaiter then return end
    rosterWaiter = CreateFrame("Frame")
    rosterWaiter:RegisterEvent("GUILD_ROSTER_UPDATE")
    rosterWaiter:SetScript("OnEvent", function(self)
        self:UnregisterAllEvents()
        rosterWaiter = nil
        Registry:Capture(true)
    end)
end

-- ============================================================================
-- API pública
-- ============================================================================

-- Árbol del personaje actual (o de otro si se pasa su clave "Nombre-Reino").
-- Devuelve nil si ese personaje aún no tiene registro.
function Registry:Get(key)
    key = key or Registry:GetCurrentKey()
    local container = (RD.config and RD.config.Get and RD.config:Get("registry", nil)) or nil
    if type(container) ~= "table" then return nil end
    return container[key]
end

-- Contenedor completo {["Nombre-Reino"] = árbol, ...} (la DB compartida;
-- NO mutar el resultado: usar Capture para escribir)
function Registry:GetAll()
    if RD.config and RD.config.Get then
        return RD.config:Get("registry", nil) or {}
    end
    return {}
end

-- Número de personajes con registro guardado en esta cuenta
function Registry:Count()
    local n = 0
    for _ in pairs(Registry:GetAll()) do n = n + 1 end
    return n
end

-- ¿Existe ya un registro para esa clave ("Nombre-Reino")?
function Registry:HasKey(key)
    return Registry:Get(key) ~= nil
end

-- Construye el árbol completo, lo guarda bajo la clave del personaje actual y
-- resume por chat. silent=true evita el resumen (usado por la re-captura tras
-- GUILD_ROSTER_UPDATE). Los registros de OTROS personajes se preservan.
function Registry:Capture(silent)
    local playerName = UnitName("player") or ""
    local playerKey = CleanName(playerName)

    local player = BuildPlayer()
    -- Proyecciones locales al portal, dentro del scope del personaje: la nota
    -- global (siempre que el módulo exista) y el snapshot de instancias.
    local note = BuildNote()
    if note ~= nil then
        player.note = note
    end
    local instances = BuildInstances()
    if instances ~= nil then
        player.instances = instances
    end

    local tree = {
        savedAt = date("%Y-%m-%d %H:%M:%S"),
        player = player,
        objectives = BuildObjectives(),
        assignments = BuildAssignments(playerKey),
        bands = BuildBands(playerKey),
        spammer = BuildSpammer(),
    }

    local guild, rosterPending = BuildGuild()
    if guild then
        tree.guild = guild
    end

    -- Guarda SOLO la clave de este personaje ("registry.Nombre-Reino"): los
    -- registros de los demás personajes quedan intactos en el contenedor y no
    -- hay DeepCopy del contenedor completo en cada captura.
    if RD.config and RD.config.Set then
        RD.config:Set("registry." .. Registry:GetCurrentKey(), DeepCopy(tree))
    end

    if not silent then
        local p = tree.player
        Log(string.format(
            "|cff33ff99[RaidDominion]|r Registro guardado en SavedVariables (%s).",
            tostring(tree.savedAt)))
        Log(string.format(
            "|cff33ff99[RaidDominion]|r Jugador: %s · %s nivel %d · %d piezas (iLvl medio %d).",
            tostring(p.name), tostring(p.class), tonumber(p.level) or 0,
            tonumber(p.equipmentCount) or 0, tonumber(p.avgIlvl) or 0))
        Log(string.format(
            "|cff33ff99[RaidDominion]|r Bandas donde figura: %d · Asignaciones activas: %d.",
            #tree.bands, tonumber(tree.assignments.count) or 0))
        if not guild then
            Log("|cffff8000[RaidDominion]|r Sin hermandad: el registro incluye solo los datos del jugador.")
        elseif guild.isGM then
            Log(string.format(
                "|cff33ff99[RaidDominion]|r Hermandad: %s · Rango: %s (GM) · %d rangos.",
                tostring(guild.name), tostring(guild.rank), #(guild.ranks or {})))
        else
            Log(string.format(
                "|cff33ff99[RaidDominion]|r Hermandad: %s · Rango: %s · %d rangos.",
                tostring(guild.name), tostring(guild.rank), #(guild.ranks or {})))
        end
    end

    -- GM con roster pendiente: pedirlo y completar el registro al llegar
    if rosterPending then
        if not silent then
            Log("|cffff8000[RaidDominion]|r Descargando roster de la hermandad; el registro se completará al llegar.")
        end
        RequestRosterAndRecapture()
    elseif guild and guild.isGM and not silent and guild.memberList then
        Log(string.format(
            "|cff33ff99[RaidDominion]|r Roster completo incluido: %d miembros (sin notas).",
            #(guild.memberList or {})))
    end

    return tree
end

RD.utils = RD.utils or {}
RD.utils.registry = Registry
return Registry
