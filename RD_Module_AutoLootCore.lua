--[[
    RD_Module_AutoLootCore.lua
    PROPÓSITO: Núcleo lógico puro del "Modo Auto" de botín (RD.modules.autoLootCore):
              filtro de ítems por tipo/rareza, clasificación de slots del botín
              (dinero, misión, bloqueado, al maestro, repartir), roster de
              destinatarios excluyendo al maestro despojador, barajado aleatorio
              con rng inyectable y formateo del informe final. Sin frames, sin
              eventos y sin dependencias de UI: testeable desde el harness.
              El comportamiento del modo Auto es FIJO (sin opciones en config):
                - Recetas (clase ítem 9) y materiales (clase ítem 7, Bienes de
                  comercio) -> al maestro despojador.
                - Equipamiento verde o mejor (rareza >= TUNING.MIN_GREEN, incluye
                  azul, morado y naranja) -> se reparte entre todos menos el maestro.
                - Ítems que inician misiones -> se saltan (quedan en el cadáver).
                - El resto (basura blanca/gris) y el dinero -> al maestro.
              Los únicos "ajustes" son retardos y tope de barrido en TUNING.
    API PÚBLICA:
        - RD.modules.autoLootCore.TUNING                   -> { MIN_GREEN, ITEM_DELAY, VERIFY_DELAY, SCAN_LIMIT, DEBUG, ... }
        - RD.modules.autoLootCore:GetRoster()              -> nombres del grupo/banda
        - RD.modules.autoLootCore:BuildCandidates(roster, masterName)
        - RD.modules.autoLootCore:Shuffle(list, rng)
        - RD.modules.autoLootCore:ItemQuality(itemLink)    -> rareza 0..6 | nil (desconocida)
        - RD.modules.autoLootCore:ItemClass(itemLink)      -> clase ítem de GetItemInfo | nil
        - RD.modules.autoLootCore:IsRecipe(itemLink)       -> clase ítem 9
        - RD.modules.autoLootCore:IsMaterial(itemLink)     -> clase ítem 7 (o 5 legacy)
        - RD.modules.autoLootCore:ShouldDistribute(itemLink) -> ¿verde o mejor / desconocida?
        - RD.modules.autoLootCore:ClassifySlot(slot)       -> "money"|"quest"|"locked"|"master"|"give"|"skip"
        - RD.modules.autoLootCore:IsQuestSlot(slot)        -> si el slot es ítem de misión
        - RD.modules.autoLootCore:IsMasterLooter()
        - RD.modules.autoLootCore:CleanName(name)          -> nombre limpio (sin reino/minúsculas)
        - RD.modules.autoLootCore:BuildIndexMap()          -> mapa DETERMINISTA del roster
        - RD.modules.autoLootCore:ProbeMasterLootCandidates() -> sondeo C SOLO diagnóstico
        - RD.modules.autoLootCore:BuildCandidateMap(slot)  -> SIEMPRE determinista { orden, byName, source }
        - RD.modules.autoLootCore:IndexFor(map, name)      -> índice para GiveMasterLoot
        - RD.modules.autoLootCore:NewStats() / FormatReport(stats)
        - RD.modules.autoLootCore:LogDistribution(playerName, itemLink)
    EVENTOS: Publica LOOT_HISTORY_ADDED vía LootCore:LogItem (solo ítems repartidos).
    ÍNDICES (3.3.5a, FrameXML LootFrame.lua):
        - En GRUPO GetMasterLootCandidate(i) itera 1..MAX_PARTY_MEMBERS+1 => el
          índice 1 es SIEMPRE el maestro despojador y partyN ocupa el índice N+1.
          El mapa determinista es exacto y vale para cualquier slot (no depende
          del estado del lado C).
        - En BANDA el índice == posición del roster (GetRaidRosterInfo(i) -> i).
        - El sondeo (GetMasterLootCandidate) NO se usa para indexar: una lista
          desfasada resuelve a índices erróneos que pueden darte el ítem al
          maestro. Solo se usa como cross-check de diagnóstico.
]]

local addonName, private = ...
local RD = _G.RaidDominion or {}
_G.RaidDominion = RD

local AutoLootCore = {}

-- Ajustes internos del modo Auto (NO configurables por el usuario; el único
-- control del modo Auto en Configuración es mostrar/ocultar su botón en la
-- barra inferior). El comportamiento de reparto es fijo por diseño:
--   recetas/materiales/dinero/basura -> maestro despojador
--   verde o mejor (MIN_GREEN)        -> repartir a la banda (sin el maestro)
--   ítems de misión                  -> saltar
AutoLootCore.TUNING = {
    MIN_GREEN = 2,           -- rareza mínima para repartir (2 = verde o mejor)
    ITEM_DELAY = 0.15,       -- pausa entre ítems (s)
    VERIFY_DELAY = 0.5,      -- pausa antes de verificar una asignación (s; tolera la latencia)
    SCAN_LIMIT = 8,          -- tope de cadáveres detectados por re-barrido
    DEBUG = false,           -- imprime detalles del barrido en el chat
    ITEM_CLASS_RECIPE = 9,   -- clase ítem de las recetas (GetItemInfo select 6)
    ITEM_CLASS_TRADE = 7,    -- Bienes de comercio (materiales de oficio)
    ITEM_CLASS_REAGENT = 5,  -- legacy (material de alquimia, sin uso real en 3.3.5a)
}

-- Nombre limpio para comparaciones (sin sufijo de reino, minúsculas, sin espacios)
local function Clean(name)
    if RD.UIUtils and RD.UIUtils.CleanName then
        return RD.UIUtils.CleanName(name)
    end
    local clean = string.gsub(tostring(name or ""), "%-.*", "")
    clean = string.gsub(clean, "%s+", "")
    return string.lower(clean)
end

-- Copia viva del roster (nombres): banda > grupo > uno mismo. Mismo patrón que
-- RD_Module_ReadyCheck (en banda GetNumPartyMembers devuelve el subgrupo, así
-- que solo se usa un origen para no duplicar).
function AutoLootCore:GetRoster()
    local names = {}
    local function Add(name)
        if name and name ~= "" then names[#names + 1] = name end
    end
    local nRaid = 0
    if GetNumRaidMembers then nRaid = GetNumRaidMembers() end
    if nRaid > 0 then
        for i = 1, nRaid do Add(GetRaidRosterInfo(i)) end
    else
        local nParty = 0
        if GetNumPartyMembers then nParty = GetNumPartyMembers() end
        if nParty > 0 then
            for i = 1, nParty do Add(UnitName("party" .. i)) end
        else
            Add(UnitName("player"))
        end
    end
    return names
end

-- Destinatarios válidos: el roster SIN el maestro despojador (nunca se le
-- reparte a sí mismo). El jugador local ya queda excluido si es el maestro,
-- que es el único caso en que el reparto es posible.
function AutoLootCore:BuildCandidates(roster, masterName)
    local out = {}
    local masterClean = Clean(masterName)
    for _, name in ipairs(roster or {}) do
        if Clean(name) ~= masterClean then
            out[#out + 1] = name
        end
    end
    return out
end

-- Barajado Fisher-Yates con rng inyectable (por defecto math.random). No
-- modifica la lista original: devuelve una copia mezclada.
function AutoLootCore:Shuffle(list, rng)
    local copy = {}
    for i = 1, #list do copy[i] = list[i] end
    local rand = rng or math.random
    for i = #copy, 2, -1 do
        local j = math.floor(rand() * i) + 1
        copy[i], copy[j] = copy[j], copy[i]
    end
    return copy
end

-- Rareza (0..6) de un itemLink. Fuente AUTORITATIVA: el COLOR del link, que el
-- cliente pone según la rareza REAL del ítem (los links de botín siempre lo
-- traen). Se consulta PRIMERO porque GetItemInfo (select 3) puede devolver un
-- valor erróneo/bajo en algunos clientes (p.ej. ítem no en caché o DB distinta)
-- y eso hacía que verdes/azules se clasificaran como basura y se vaciaran al
-- maestro. Respaldo: calidad numérica de GetItemInfo. Devuelve nil SOLO si no
-- hay forma de determinarla (sin color y sin dato): en ese caso el llamador
-- debe REPARTIR y NUNCA quedárselo.
function AutoLootCore:ItemQuality(itemLink)
    if not itemLink or itemLink == "" then return nil end
    local r = itemLink:match("|cff(%x%x%x%x%x%x)")
    if r then
        local map = {
            ["9d9d9d"] = 0, ["ffffff"] = 1, ["1eff00"] = 2, ["0070dd"] = 3,
            ["a335ee"] = 4, ["ff8000"] = 5, ["e6cc80"] = 6,
        }
        local q = map[r:lower()]
        if q ~= nil then return q end
    end
    local ok, quality = pcall(function()
        local info = { GetItemInfo(itemLink) }
        return info[3]
    end)
    if ok and type(quality) == "number" and quality >= 0 and quality <= 7 then
        return quality
    end
    return nil
end

-- Clase ítem de un itemLink (select 6 de GetItemInfo en 3.3.5a). Devuelve nil
-- si NO se puede determinar (item no en caché): en ese caso el filtro de tipo
-- NUNCA clasifica el ítem como receta/material (no va al maestro por su clase),
-- y cae al reparto por rareza (verde o mejor / desconocida -> se reparte).
function AutoLootCore:ItemClass(itemLink)
    if not itemLink then return nil end
    local ok, itemClass = pcall(function()
        local info = { GetItemInfo(itemLink) }
        return info[6]
    end)
    if ok and type(itemClass) == "number" then return itemClass end
    return nil
end

-- ¿El ítem es una RECETA (clase ítem 9 en 3.3.5a)? Las recetas SIEMPRE van al
-- maestro despojador, sean de la rareza que sean.
function AutoLootCore:IsRecipe(itemLink)
    return self:ItemClass(itemLink) == AutoLootCore.TUNING.ITEM_CLASS_RECIPE
end

-- ¿El ítem es un MATERIAL de oficio (clase ítem 7 = Bienes de comercio: hierbas,
-- mineral, cuero, tela, piezas de ingeniería...)? También la clase 5 legacy
-- (reagent). Los materiales SIEMPRE van al maestro despojador.
function AutoLootCore:IsMaterial(itemLink)
    local c = self:ItemClass(itemLink)
    if c == nil then return false end
    return c == AutoLootCore.TUNING.ITEM_CLASS_TRADE
        or c == AutoLootCore.TUNING.ITEM_CLASS_REAGENT
end

-- ¿Este ítem debe REPARTIRSE a la banda? rareza >= MIN_GREEN (verde o mejor,
-- incluye azul, morado y naranja). Rareza DESCONOCIDA (ItemQuality == nil) =>
-- se reparte: NUNCA se queda el ítem el maestro por no poder clasificarlo
-- (evita el bug de "todo a mí").
function AutoLootCore:ShouldDistribute(itemLink)
    if not itemLink then return false end
    local quality = self:ItemQuality(itemLink)
    if quality == nil then return true end
    return quality >= AutoLootCore.TUNING.MIN_GREEN
end

-- ¿El slot del botín abierto es un ítem que inicia/forma parte de una misión?
-- LootSlotGetQuestInfo(slot) devuelve la info de misión; cualquier valor no-nil
-- (excepto false) se trata como ítem de misión. El modo debug imprime los
-- valores crudos para poder afinar la interpretación en el cliente.
function AutoLootCore:IsQuestSlot(slot)
    if not LootSlotGetQuestInfo then return false end
    local ok, q1, q2 = pcall(LootSlotGetQuestInfo, slot)
    if not ok then return false end
    return (q1 ~= nil and q1 ~= false) or (q2 ~= nil)
end

-- Clasifica un slot del botín abierto para decidir la acción (comportamiento
-- FIJO del modo Auto, sin opciones):
--   money   -> dinero (va al maestro: no se puede regalar)
--   quest   -> ítem de misión (se salta y queda en el cadáver)
--   locked  -> alguien ya lo tiene / está en roll (se salta)
--   master  -> receta, material o basura blanca/gris (va al maestro despojador)
--   give    -> ítem verde o mejor (se reparte a la banda, sin el maestro)
--   skip    -> slot sin ítem / no loteable
function AutoLootCore:ClassifySlot(slot)
    if not LootSlotIsItem then return "skip" end
    if LootSlotIsMoney and LootSlotIsMoney(slot) then
        return "money"
    end
    if self:IsQuestSlot(slot) then
        return "quest"
    end
    if not LootSlotIsItem(slot) then return "skip" end
    -- 5º valor de GetLootSlotInfo = booleano "locked" (slot ya en roll/asignado)
    local ok, _, _, _, _, locked = pcall(GetLootSlotInfo, slot)
    if ok and locked then return "locked" end
    local itemLink = GetLootSlotLink(slot)
    if not itemLink then return "skip" end
    -- Recetas y materiales van SIEMPRE al maestro (aunque su rareza sea alta).
    if self:IsRecipe(itemLink) or self:IsMaterial(itemLink) then
        return "master"
    end
    if self:ShouldDistribute(itemLink) then
        return "give"
    end
    -- Basura blanca/gris: se recoge para el maestro.
    return "master"
end

-- ¿El jugador local es el maestro despojador? (GetLootMethod: método + partyID;
-- partyID == 0 => el maestro es el jugador local, igual que Loot:IsMasterLooter).
function AutoLootCore:IsMasterLooter()
    local method, partyID = GetLootMethod()
    if not method or method ~= "master" then return false end
    return (partyID and partyID == 0)
end

-- Nombre limpio (API pública: reutilizada por AutoLootMaster y el módulo Loot)
function AutoLootCore:CleanName(name)
    return Clean(name)
end

-- Mapa DETERMINISTA de índices de candidatos derivado del roster, sin depender
-- del estado del lado C del cliente:
--   - BANDA:  índice i == posición del roster (GetRaidRosterInfo(i) -> i).
--   - GRUPO:  índice 1 = maestro despojador y partyN -> N+1 (FrameXML itera
--             1..MAX_PARTY_MEMBERS+1).
-- Devuelve { source = "deterministic", orden = { {name,index}, .. },
--           byName = { [limpio]=idx }, byIndex = { [idx]=name } }.
-- Este mapa es VÁLIDO PARA CUALQUIER SLOT del cadáver en grupo (el FrameXML
-- no cambia la lista por slot en grupo) y es la fuente fiable del reparto.
function AutoLootCore:BuildIndexMap()
    local orden, byName, byIndex = {}, {}, {}
    local function Add(idx, name)
        if not name or name == "" then return end
        local key = Clean(name)
        orden[#orden + 1] = { name = name, index = idx }
        if not byName[key] then
            byName[key] = idx
        end
        if not byIndex[idx] then
            byIndex[idx] = name
        end
    end
    local nRaid = 0
    if GetNumRaidMembers then nRaid = GetNumRaidMembers() end
    if nRaid > 0 then
        for i = 1, nRaid do Add(i, GetRaidRosterInfo(i)) end
    else
        Add(1, UnitName("player"))
        local nParty = 0
        if GetNumPartyMembers then nParty = GetNumPartyMembers() end
        for i = 1, nParty do Add(i + 1, UnitName("party" .. i)) end
    end
    return { source = "deterministic", orden = orden, byName = byName, byIndex = byIndex }
end

-- Sondeo del lado C: GetMasterLootCandidate(i) con la forma REAL de 1 argumento.
-- Solo es fiable si el jugador seleccionó el slot con clic izquierdo
-- (LootFrame_OnClick -> LootSlot(slot)); en otro caso la lista llega vacía o
-- desfasada. Devuelve { source = "probe", orden, byName } (orden vacío si nada).
function AutoLootCore:ProbeMasterLootCandidates()
    local orden, byName = {}, {}
    for i = 1, 40 do
        local ok, name = pcall(GetMasterLootCandidate, i)
        if not ok or not name or name == "" then break end
        local key = Clean(name)
        orden[#orden + 1] = { name = name, index = i }
        if not byName[key] then
            byName[key] = i
        end
    end
    return { source = "probe", orden = orden, byName = byName }
end

-- Mapa de candidatos del cadáver para repartir. SIEMPRE determinista:
--   - GRUPO: maestro = 1, partyN = N+1 (FrameXML itera 1..MAX_PARTY_MEMBERS+1).
--   - BANDA: índice == posición del roster (GetRaidRosterInfo(i) -> i; el
--     dropdown de Blizzard usa exactamente esos índices para GiveMasterLoot).
-- El sondeo del lado C (GetMasterLootCandidate) NO se usa para indexar: solo es
-- fiable si el jugador seleccionó el slot con clic izquierdo, y una lista
-- desfasada (de otro slot o vacía) resuelve a índices erróneos que pueden darte
-- el ítem al maestro. El sondeo queda SOLO como cross-check de diagnóstico
-- (ProbeMasterLootCandidates).
function AutoLootCore:BuildCandidateMap(slot)
    return self:BuildIndexMap()
end

-- Índice para GiveMasterLoot de un nombre en el mapa de candidatos (nil si no
-- figura). NUNCA adivina un índice: si el jugador no está en el mapa, no se
-- entrega (un índice erróneo daría el ítem a otra persona).
function AutoLootCore:IndexFor(map, name)
    if not map or not name then return nil end
    return map.byName[Clean(name)]
end

-- Índice REAL de un jugador para GiveMasterLoot, buscando su NOMBRE en el
-- sondeo del lado C en el MISMO momento de la entrega. Es la forma que usan
-- los addons de master loot correctos (y la documentada): GetMasterLootCandidate
-- NO garantiza un orden estable entre invocaciones, así que un mapa cacheado o
-- determinista puede entregar a la persona equivocada (o al maestro). Al buscar
-- por nombre aquí y ahora, el índice devuelto ES el del jugador. nil si no se
-- encuentra (no es candidato o la lista aún no se construyó): NO se adivina.
function AutoLootCore:IndexOfRecipient(name)
    if not name or name == "" then return nil end
    local cleanTarget = Clean(name)
    for i = 1, 40 do
        local ok, candidate = pcall(GetMasterLootCandidate, i)
        if not ok or not candidate or candidate == "" then break end
        if Clean(candidate) == cleanTarget then
            return i
        end
    end
    return nil
end

-- Estadísticas del barrido
function AutoLootCore:NewStats()
    return {
        opened = 0, given = 0, taken = 0, money = 0,
        unassigned = 0, skipped = 0,
    }
end

-- Mensaje resumen del barrido (local; el canal de banda es decisión del llamador)
function AutoLootCore:FormatReport(stats)
    stats = stats or {}
    local parts = {
        "|cff00c8ff[RaidDominion]|r Auto:",
        string.format("cadáveres %d", stats.opened or 0),
        string.format("repartidos %d", stats.given or 0),
        string.format("para ti %d (recetas/materiales/basura)", stats.taken or 0),
    }
    if stats.money and stats.money > 0 then
        parts[#parts + 1] = string.format("dinero %d", stats.money)
    end
    if stats.unassigned and stats.unassigned > 0 then
        parts[#parts + 1] = string.format("|cffff0000%d sin asignar|r (bolsas llenas o ya lo tienen)", stats.unassigned)
    end
    if stats.skipped and stats.skipped > 0 then
        parts[#parts + 1] = string.format("%d de misión/bloqueados saltados", stats.skipped)
    end
    return table.concat(parts, " · ")
end

-- Registra en el historial de botín un ítem repartido a un jugador (paridad con
-- el gestor manual: el evento "item" se agrupa por itemLink en GroupByItem).
function AutoLootCore:LogDistribution(playerName, itemLink)
    if not playerName or not itemLink then return end
    local lc = RD.modules and RD.modules.lootCore
    if lc and lc.LogItem then
        lc:LogItem(playerName, itemLink, 1, 0)
    end
end

RD.modules = RD.modules or {}
RD.modules.autoLootCore = AutoLootCore
return AutoLootCore