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
                player       -> nombre, reino, servidor, nivel, raza, clase,
                                talento, resumen de equipo (count/avgIlvl) y la
                                nota global del personaje (vacía si no tiene).
                                El array `equipment` y las `instances` SOLO se
                                escriben como fallback cuando characters aún
                                no tiene ese snapshot; si existe, se omiten
                                para no duplicar datos pesados.
                objectives   -> objetivos personales de equipamiento y metas
                                de moneda (solo metas; rama compartida con el
                                portal web, sin iconos ni flags de seguimiento)
                guild        -> SOLO si hay hermandad: nombre, rango propio y
                                la jerarquía COMPLETA de los N rangos (índice
                                y nombre, ordenada de GM/0 a inferior); si el
                                jugador es GM incluye además la lista completa
                                de miembros SIN nota pública ni de oficial;
                                sin hermandad la sección se omite. Esta sección
                                se reconcilia en login/PLAYER_GUILD_UPDATE con
                                SyncGuild (alta, baja o cambio de rango).
              COMPARTIDO (fuera del registro): configuración general, roles,
              abilities, auras, buffs, mechanics, rules y bands viven UNA sola
              vez en la DB para toda la cuenta (sin redundancia entre personajes).
              RD_Utils_Characters es la fuente PASIVA de equipo, instancias,
              nivel, monedas y dinero de TODOS los personajes (se refresca en
              login/equipo/nivel/guild/logout). "Registrar" reutiliza ese
              snapshot sin repetir consultas y solo lo escribe en `registry`
              como fallback si aún no existe, para que el portal tenga datos
              frescos sin duplicar arrays. NO se copian datos ajenos a su
              contrato (bands, asignaciones o spammer, que viven en sus
              fuentes compartidas).
    API PÚBLICA:
        - RD.utils.registry:Capture(silent)  -- registra AL PERSONAJE ACTUAL
        - RD.utils.registry:Get(key)         -- árbol propio o de otro personaje
        - RD.utils.registry:GetAll()         -- contenedor completo {clave=árbol}
        - RD.utils.registry:Count()          -- personajes registrados
        - RD.utils.registry:GetCurrentKey()  -- clave "Nombre-Reino" actual
        - RD.utils.registry:HasKey(key)      -- ¿existe ese registro?
        - RD.utils.registry:SyncGuild()      -- reconcilia SOLO registry[clave].guild
                                               con la hermandad viva (login y
                                               PLAYER_GUILD_UPDATE); al abandonar
                                               la elimina para que el portal no
                                               lo siga mostrando como miembro.
              CONTRATO CON EL PORTAL:
                - registry["Nombre-Reino"].objectives comparte objetivos
                  personales de equipo y metas de moneda; no expone la raíz
                  local itemGoals ni sus datos de seguimiento.
                - player.note: la nota global del personaje (store local
                  playerNotes) se proyecta al pulsar "Registrar"; sin el módulo
                  la clave se omite y la web conserva lo ya publicado.
                - player.equipment / player.instances: equipo e instancias son
                  PASIVOS y viven en characters["Nombre-Reino"]; el portal los
                  lee de ahí para los personajes ya registrados. El registro
                  solo los escribe como fallback si characters aún no tiene el
                  snapshot, y conserva count/avgIlvl como resumen.
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

-- IsInGuild de 3.3.5a devuelve 1/nil (NO true/false). Normaliza a booleano;
-- nil solo si la API no existe (no se debe borrar nada a ciegas).
local function QueryPlayerGuild()
    if type(IsInGuild) ~= "function" then return nil end
    local value = IsInGuild()
    return not (value == nil or value == false or value == 0)
end

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

-- Snapshot account-wide del personaje actual. RD_Utils_Characters lo refresca
-- en login, cambios de equipo/dinero/monedas, entrada al mundo y logout. El
-- registro lo reutiliza para no repetir consultas al paperdoll ni a las
-- instancias al pulsar "Registrar".
local function GetCharacterSnapshot()
    local chars = RD.utils and RD.utils.characters
    if not (chars and chars.GetCurrentKey) then return nil end
    local key = chars:GetCurrentKey()
    if not key then return nil end
    if chars.Get then
        local ok, info = pcall(chars.Get, chars, key)
        if ok and type(info) == "table" then return info end
    end
    if type(RaidDominionDB) == "table" and type(RaidDominionDB.characters) == "table" then
        return RaidDominionDB.characters[key]
    end
    return nil
end

-- ============================================================================
-- Sección: jugador (clase, nivel, equipamiento)
-- ============================================================================

-- Equipamiento del personaje: se reutiliza el snapshot vigente de characters.
-- Solo si aún no hay piezas guardadas (paperdoll no listo en el login) se lee
-- el paperdoll en vivo como fallback. Es un dato PASIVO del SV, sin check de
-- seguimiento, y el registro conserva su forma para el portal.
local function BuildEquipment(snapshot)
    if snapshot and type(snapshot.equipment) == "table" and #snapshot.equipment > 0 then
        return snapshot.equipment,
            tonumber(snapshot.equipmentCount) or #snapshot.equipment,
            tonumber(snapshot.avgIlvl) or 0
    end
    local util = RD.utils and RD.utils.equipment
    if not (util and util.Get) then return {}, 0, 0 end
    local ok, items, count, avg = pcall(util.Get, util)
    if not ok or type(items) ~= "table" then return {}, 0, 0 end
    return items, tonumber(count) or #items, tonumber(avg) or 0
end

-- Identidad del jugador: primero el snapshot de characters (misma fuente que
-- el roster de la cuenta) y, si falta algún campo, la API del cliente.
local function BuildPlayer(snapshot)
    local name = snapshot and snapshot.name
    if not name or name == "" then name = UnitName("player") or "" end
    local realm = snapshot and snapshot.realm
    if not realm or realm == "" then realm = GetRealmName() or "" end
    -- El nivel puede cambiar sin relog: se lee en vivo (llamada barata) y solo
    -- se usa el snapshot si el cliente no lo da.
    local level = UnitLevel("player")
    if not level or level <= 0 then level = snapshot and tonumber(snapshot.level) end
    local raceName = snapshot and snapshot.raceName
    local raceFile = snapshot and snapshot.raceFile
    if not raceName or raceName == "" or not raceFile or raceFile == "" then
        local rn, rf = UnitRace("player")
        if not raceName or raceName == "" then raceName = rn end
        if not raceFile or raceFile == "" then raceFile = rf end
    end
    local className = snapshot and snapshot.className
    local classFile = snapshot and snapshot.classFile
    if not className or className == "" or not classFile or classFile == "" then
        local cn, cf = UnitClass("player")
        if not className or className == "" then className = cn end
        if not classFile or classFile == "" then classFile = cf end
    end
    local player = {
        name = name,
        realm = realm,
        server = GetServerName(),
        level = level,
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
    local equipment, equipped, avgIlvl = BuildEquipment(snapshot)
    -- El array de equipo es el bloque pesado y ya vive en characters: si ese
    -- snapshot existe, el registro NO lo duplica. Se conserva el resumen
    -- (count/avg) como fallback barato y solo se escribe el array completo
    -- cuando characters aún no tiene piezas válidas.
    local hasSnapshotEquipment = type(snapshot) == "table"
        and type(snapshot.equipment) == "table" and #snapshot.equipment > 0
    if not hasSnapshotEquipment then
        player.equipment = equipment
    end
    player.equipmentCount = equipped
    player.avgIlvl = avgIlvl
    return player
end

-- ============================================================================
-- Sección: proyecciones locales al portal (nota global + fallback de instancias)
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
-- reinicio ABSOLUTO): ya lo proyecta RD_Utils_Instances.Export en el snapshot
-- de characters, así que el registro NO lo duplica cuando ese snapshot existe
-- (se devuelve nil para omitir la clave). Solo si characters aún no tiene la
-- lista se exporta en vivo como fallback; sin el módulo la clave se omite
-- (no pisa lo ya publicado). Con el módulo el fallback puede ir vacío para que
-- un re-registro sin instancias limpie las expiradas.
local function BuildInstances(snapshot)
    if type(snapshot) == "table" and type(snapshot.instances) == "table" then
        return nil
    end
    local util = RD.utils and RD.utils.instances
    if not (util and util.Export) then return nil end
    local ok, list = pcall(util.Export, util)
    if ok and type(list) == "table" then return list end
    -- Fallo de lectura: omitir la clave para no borrar lo ya publicado.
    return nil
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
-- Sincronización de hermandad (sin volver a pulsar "Registrar")
-- ============================================================================

-- Reconcilia SOLO la sección guild del registro existente del personaje actual
-- con el estado VIVO de hermandad:
--   * sin hermandad -> elimina registry[clave].guild (el portal deja de
--     listarlo como miembro);
--   * con hermandad -> actualiza nombre, rango, jerarquía y, si es GM, roster.
-- No auto-registra personajes sin entrada previa ni toca player, objectives,
-- note, instances o savedAt. Si el cliente aún no expone el nombre de la
-- hermandad (transitorio al cargar), NO borra: conserva lo ya guardado.
function Registry:SyncGuild()
    local key = Registry:GetCurrentKey()
    if not key then return false end

    local tree = Registry:Get(key)
    if type(tree) ~= "table" then return false end

    local inGuild = QueryPlayerGuild()

    if inGuild == false then
        if tree.guild == nil then return true end
        if RD.config and RD.config.Set then
            RD.config:Set("registry." .. key .. ".guild", nil)
        end
        return true
    end
    if not inGuild then return false end

    local guildName = GetGuildInfo("player")
    if type(guildName) ~= "string" or guildName == "" then
        return false
    end

    local previous = tree.guild
    local guild, rosterPending = BuildGuild()
    if not guild then return false end

    -- Misma hermandad con el roster aún sin descargar: conservar los datos
    -- completos ya guardados para no degradar el registro con vacíos.
    if type(previous) == "table" and previous.name == guild.name then
        if rosterPending then
            if type(previous.memberList) == "table" then
                guild.memberList = previous.memberList
                rosterPending = false
            end
            if type(previous.ranks) == "table" and #(guild.ranks or {}) == 0 then
                guild.ranks = previous.ranks
            end
        end
        if (tonumber(guild.numMembers) or 0) == 0 then
            guild.numMembers = tonumber(previous.numMembers) or guild.numMembers
        end
    end

    if RD.config and RD.config.Set then
        RD.config:Set("registry." .. key .. ".guild", guild)
    end
    if rosterPending then
        RequestRosterAndRecapture()
    end
    return true
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
    -- Un solo snapshot de characters alimenta identidad, equipamiento e
    -- instancias: no se repiten consultas ni procesamientos en "Registrar".
    local snapshot = GetCharacterSnapshot()
    local player = BuildPlayer(snapshot)
    -- La nota se proyecta al portal. Las instancias solo se escriben como
    -- fallback si characters aún no las tiene (ver BuildInstances).
    local note = BuildNote()
    if note ~= nil then
        player.note = note
    end
    local instances = BuildInstances(snapshot)
    if instances ~= nil then
        player.instances = instances
    end

    local tree = {
        savedAt = date("%Y-%m-%d %H:%M:%S"),
        player = player,
        objectives = BuildObjectives(),
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
