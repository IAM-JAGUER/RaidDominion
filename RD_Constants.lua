--[[
    RD_Constants.lua
    PROPÓSITO: Constantes, definiciones de menú, configuración por defecto y esquema de configuración.
    API PÚBLICA: RaidDominion.constants
    EVENTOS: Ninguno
]]

local addonName, private = ...
local RD = _G.RaidDominion or {}
_G.RaidDominion = RD

-- Helper para ítems de menú cuya visibilidad depende de un flag de config
-- (p.ej. ui.showMechanicsMenu): devuelve una función `enabled` compatible con
-- el filtro de MenuFactory. Semántica `~= false` = visible salvo que se desactive.
local function MenuEnabledByConfig(key, defaultValue)
    return function()
        return (RD.config and RD.config.Get and RD.config:Get(key, defaultValue)) ~= false
    end
end

-- Líneas de seguimiento de monedas para el tooltip del botón "Jugador" de la
-- barra inferior (RD_Utils_ItemGoals:TrackedCurrencyLines). Se resuelve en
-- tiempo de hover (los RD_Utils_* cargan después de RD_Constants en el .toc).
-- Devuelve una lista de strings o nil si el módulo no está disponible.
local function PlayerTrackedLines()
    local goals = RD.utils and RD.utils.itemGoals
    if goals and goals.TrackedCurrencyLines then
        return goals:TrackedCurrencyLines()
    end
    return nil
end

-- Líneas de seguimiento de OBJETOS para el tooltip del botón "Jugador"
-- (RD_Utils_ItemGoals:TrackedItemLines). Lazy igual que PlayerTrackedLines.
local function PlayerTrackedItems()
    local goals = RD.utils and RD.utils.itemGoals
    if goals and goals.TrackedItemLines then
        return goals:TrackedItemLines()
    end
    return nil
end

-- Líneas de seguimiento de INSTANCIAS para el tooltip del botón "Jugador"
-- (RD_UI_BandsPlayerEditor_Sections_Instances:TrackedLines). Lazy igual que las
-- anteriores. Sin `empty` declarado en tooltipExtra: la sección se OMITE cuando
-- el check está apagado o no hay instancias (no hay aviso de descubrimiento).
local function PlayerTrackedInstances()
    local inst = RD.ui and RD.ui.playerEditorSectionsInstances
    if inst and inst.TrackedLines then
        return inst:TrackedLines()
    end
    return {}
end

RD.constants = {
    VERSION = "3.0.0",
    AUTHOR = "Andres Muñoz",
    WEBSITE = "https://colmillo.netlify.app/",

    -- Grid base para el sistema de alineación (ver sección 6 de AGENTS.md)
    GRID = {
        GUTTER = 4,          -- unidad base de espaciado
        MENU_ITEM_HEIGHT = 22,
        MENU_ITEM_GAP = 2,
        MAX_ITEMS_PER_COLUMN = 9,
        MAX_COLUMNS = 5,
        COLUMN_SPACING = 16,
        LABEL_WIDTH = 184,
        BUTTON_SIZE = 20,
    },

    -- Paleta de acento compartida (única fuente de verdad para los colores
    -- del addon: dorado, rojo de error, verde de éxito).
    COLORS = {
        GOLD = { 1, 0.82, 0 },
        RED = { 1, 0, 0 },
        GREEN = { 0, 1, 0 },
    },

    -- Calidad de ítem (rarity): etiquetas y colores esMX, fuente única para la
    -- rejilla de equipamiento del editor (bordes por calidad, cabeceras de
    -- grupo "Épico"/"Legendario"/...) y para los tooltips de ítem.
    ITEM_QUALITY_COLORS = {
        [0] = { 0.6, 0.6, 0.6 },    -- pobre
        [1] = { 1, 1, 1 },          -- normal
        [2] = { 0.2, 1, 0.2 },      -- superior
        [3] = { 0.3, 0.6, 1 },      -- raro
        [4] = { 0.8, 0.5, 1 },      -- épico
        [5] = { 1, 0.5, 0 },        -- legendario
        [6] = { 0.8, 0.8, 0.8 },    -- relic
        [7] = { 1, 0.82, 0 },       -- mejora/heredado (genérico)
    },
    ITEM_QUALITY_LABELS = {
        [0] = "Pobre", [1] = "Normal", [2] = "Superior", [3] = "Raro",
        [4] = "Épico", [5] = "Legendario", [6] = "Relic", [7] = "Mejora",
    },
    -- Orden de las cabeceras al agrupar el equipamiento por calidad (de mayor
    -- a menor; solo se muestran los grupos no vacíos).
    ITEM_QUALITY_GROUP_ORDER = { 5, 4, 3, 2, 1, 0, 6, 7 },

    -- Nombres de los slots de equipamiento (0..19) en esMX. Se usan como
    -- fallback de GetInventorySlotName (que devuelve el nombre del cliente) y
    -- para los tests del harness (que no tienen API de WoW). El 0 (munición)
    -- no lo devuelve el cliente.
    EQUIP_SLOT_NAMES = {
        [0] = "Munición", [1] = "Cabeza", [2] = "Cuello", [3] = "Hombros",
        [4] = "Camisa", [5] = "Pecho", [6] = "Cintura", [7] = "Piernas",
        [8] = "Pies", [9] = "Muñecas", [10] = "Manos", [11] = "Anillo 1",
        [12] = "Anillo 2", [13] = "Abalorio 1", [14] = "Abalorio 2",
        [15] = "Espalda", [16] = "Mano principal", [17] = "Mano secundaria",
        [18] = "A distancia", [19] = "Tabardo",
    },

    -- Iconos de los slots (0..19): la silueta GRIS del paperdoll de 3.3.5a.
    -- FALLBACK (harness/tests): en el cliente real se prefiere la textura que
    -- devuelve GetInventorySlotInfo("HeadSlot") -> (id, texture, checkRelic),
    -- la misma que usa el paperdoll nativo (nunca "?"). Los nombres de esta
    -- tabla son los de 3.3.5a: muñecas es "Wrists" (PLURAL, no "Wrist").
    EQUIP_SLOT_ICONS = {
        [0] = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Ranged",
        [1] = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Head",
        [2] = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Neck",
        [3] = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Shoulder",
        [4] = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Shirt",
        [5] = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Chest",
        [6] = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Waist",
        [7] = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Legs",
        [8] = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Feet",
        [9] = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Wrists",
        [10] = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Hands",
        [11] = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Finger",
        [12] = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Finger",
        [13] = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Trinket",
        [14] = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Trinket",
        -- Espalda/capa: el cliente NO tiene UI-PaperDoll-Slot-Back (reutiliza la
        -- del pecho); se usa la capa INV_Misc_Cape_10 (la que usa Carbonite 3.3.5a).
        [15] = "Interface\\Icons\\INV_Misc_Cape_10",
        [16] = "Interface\\PaperDoll\\UI-PaperDoll-Slot-MainHand",
        [17] = "Interface\\PaperDoll\\UI-PaperDoll-Slot-SecondaryHand",
        [18] = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Ranged",
        [19] = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Tabard",
    },

    -- Envuelve el título de un elemento con el estilo de título elegido
    -- ("equals" → "= Nombre =", "brackets" → "[Nombre]", "none" → plano).
    -- Es el ÚNICO punto que produce el wrapper del título en todo el addon;
    -- anuncios de menú, spammer de regla y demás lo usan. El estilo "equals"
    -- es el default (un único "=" a cada lado, no "===").
    WrapTitle = function(name, wrapper)
        if type(name) ~= "string" then name = tostring(name or "") end
        if wrapper == "brackets" then
            return "[" .. name .. "]"
        end
        if wrapper == "none" then
            return name
        end
        return "= " .. name .. " ="
    end,

    -- Lista curada de iconos para el selector (SOLO texturas válidas de 3.3.5a).
    -- El usuario elige de esta cuadrícula en vez de escribir nombres de textura.
    -- OJO: no incluir iconos de expansiones posteriores (Cata/Legion/etc.) ni
    -- paths inciertos: una textura inexistente se muestra como casilla vacía y
    -- no hay API en 3.3.5a para validar texturas en tiempo de ejecución.
    ICON_PICKER_LIST = {
        "Interface\\Icons\\Ability_Warrior_DefensiveStance",
        "Interface\\Icons\\Ability_Warrior_OffensiveStance",
        "Interface\\Icons\\Spell_Holy_HolyBolt",
        "Interface\\Icons\\Spell_Holy_FlashHeal",
        "Interface\\Icons\\Spell_Holy_GreaterHeal",
        "Interface\\Icons\\Ability_Warrior_Riposte",
        "Interface\\Icons\\Spell_Shadow_AbominationExplosion",
        "Interface\\Icons\\ability_shaman_heroism",
        "Interface\\Icons\\Ability_Hunter_Misdirection",
        "Interface\\Icons\\Spell_Frost_ChainsOfIce",
        "Interface\\Icons\\Spell_Holy_PrayerOfHealing02",
        "Interface\\Icons\\Spell_Holy_Penance",
        "Interface\\Icons\\spell_shadow_dispersion",
        "Interface\\Icons\\Ability_Druid_Cyclone",
        "Interface\\Icons\\Spell_Nature_StrangleVines",
        "Interface\\Icons\\Spell_Nature_Rejuvenation",
        "Interface\\Icons\\Spell_Holy_DivineShield",
        "Interface\\Icons\\Spell_DeathKnight_DeathAndDecay",
        "Interface\\Icons\\Spell_Shadow_SoulGem",
        "Interface\\Icons\\Ability_Warrior_BattleShout",
        "Interface\\Icons\\Spell_Magic_MageArmor",
        "Interface\\Icons\\Spell_Holy_FistOfJustice",
        "Interface\\Icons\\Spell_Holy_SealOfWisdom",
        "Interface\\Icons\\spell_holy_greaterblessingofsanctuary",
        "Interface\\Icons\\Spell_Nature_Regeneration",
        "Interface\\Icons\\Spell_Shadow_AnimateDead",
        "Interface\\Icons\\Spell_Holy_AuraMastery",
        "Interface\\Icons\\Spell_Holy_SealOfSacrifice",
        "Interface\\Icons\\Spell_Holy_SealOfValor",
        "Interface\\Icons\\Spell_Holy_LayOnHands",
        "Interface\\Icons\\Spell_Shadow_DetectLesserInvisibility",
        "Interface\\Icons\\Spell_Shadow_Twilight",
        "Interface\\Icons\\spell_arcane_massdispel",
        "Interface\\Icons\\Spell_DeathKnight_PlagueStrike",
        "Interface\\Icons\\Spell_DeathKnight_BloodBoil",
        "Interface\\Icons\\Spell_DeathKnight_IcyTouch",
        "Interface\\Icons\\spell_deathknight_strangulate",
        "Interface\\Icons\\Ability_Rogue_TricksOftheTrade",
        "Interface\\Icons\\Spell_Nature_HealingTouch",
        "Interface\\Icons\\Spell_Holy_Excorcism",
        "Interface\\Icons\\Spell_Holy_TurnUndead",
        "Interface\\Icons\\Ability_Paladin_BeaconOfLight",
        "Interface\\Icons\\Ability_Shaman_Hex",
        "Interface\\Icons\\Spell_Nature_BloodLust",
        "Interface\\Icons\\Spell_Shadow_Metamorphosis",
        "Interface\\Icons\\Spell_Fire_Fireball",
        "Interface\\Icons\\Spell_Frost_FrostBolt02",
        "Interface\\Icons\\Spell_Arcane_Blink",
        "Interface\\Icons\\Spell_Shadow_LifeDrain",
        "Interface\\Icons\\Spell_Shadow_DeathCoil",
        "Interface\\Icons\\Ability_Hunter_Quickshot",
        "Interface\\Icons\\Ability_Rogue_SinisterStrike",
        "Interface\\Icons\\INV_Misc_QuestionMark",
        "Interface\\Icons\\INV_Misc_Coin_01",
        "Interface\\Icons\\INV_Box_01",
        "Interface\\Icons\\INV_Gizmo_01",
        "Interface\\Icons\\INV_Misc_Map_01",
        "Interface\\Icons\\INV_Letter_01",
    },

    -- Datos de roles para el menú y la configuración
    ROLE_DATA = {
        { name = "MAIN TANK",      icon = "Interface\\Icons\\Ability_Warrior_DefensiveStance" },
        { name = "OFF TANK",       icon = "Interface\\Icons\\Ability_Warrior_OffensiveStance" },
        { name = "HEALER 1",       icon = "Interface\\Icons\\Spell_Holy_HolyBolt" },
        { name = "HEALER 2",       icon = "Interface\\Icons\\Spell_Holy_FlashHeal" },
        { name = "HEALER 3",       icon = "Interface\\Icons\\Spell_Holy_GreaterHeal" },
    },

    -- Roles de jugador dentro de una banda (para el gestor de jugadores).
    -- Cada rol tiene clave estable (minúscula) guardada en `player.role`.
    BAND_ROLE_DATA = {
        { key = "tank",   short = "T", label = "Tanque",  color = { 0.2, 0.6, 1 } },
        { key = "healer", short = "H", label = "Healer",  color = { 0.1, 1, 0.1 } },
        { key = "rango",  short = "R", label = "Rango",   color = { 1, 0.5, 0 } },
        { key = "melee",  short = "M", label = "Melee",   color = { 1, 0.2, 0.2 } },
    },

    -- Causales de sanción de un jugador (columna de sanciones, similar a rol/dual).
    -- "" significa sin sanción. La pestaña "Sancionados" filtra por causal no vacía.
    -- `short` se muestra en la columna; `label` (si existe) es el nombre completo
    -- que se muestra en el tooltip (p.ej. "Engemado/Encantado").
    BAND_SANCTION_DATA = {
        { key = "lag",          short = "Lag",          color = { 1, 0.8, 0 } },
        { key = "abandono",     short = "Abandono",     color = { 1, 0.5, 0 } },
        { key = "rendimiento",  short = "Rendimiento",  color = { 1, 0.3, 0 } },
        { key = "baneo",        short = "Baneo",        color = { 1, 0.1, 0.1 } },
        { key = "equipamiento", short = "Equip.",       label = "Equipamiento",        color = { 0.3, 0.6, 1 } },
        { key = "engemado",     short = "Eng/Enc",      label = "Engemado/Encantado",  color = { 0.7, 0.4, 1 } },
    },
    BAND_SANCTION_KEYS = { "", "lag", "abandono", "rendimiento", "baneo", "equipamiento", "engemado" },

    -- Estado de líder de raid de un jugador (columna "Líder", similar a rol).
    -- "" = No; "si" = Sí; "ayudante" = Ayudante.
    BAND_LEADER_DATA = {
        { key = "si",       label = "Sí",       color = { 1, 0.82, 0 } },
        { key = "ayudante", label = "Ayudante", color = { 0.3, 0.6, 1 } },
    },
    BAND_LEADER_KEYS = { "", "si", "ayudante" },

    -- Barra de botones inferior del menú flotante (estilo base v2).
    -- Las acciones se implementan en iteraciones posteriores.
    ACTION_BAR = {
        HEIGHT = 30,
        BUTTON_SIZE = 27,
        BUTTON_PADDING = 2,
        ITEMS = {
            { name = "Modo de raid", icon = "Interface\\Icons\\inv_misc_coin_09", tooltip = "Clic izq.: Configurar la dificultad de raid\nClic der.: Solicitar asignaciones del líder", action = "ActionBarRaidMode", actionRight = "ActionBarRaidModeRight",
              panelHelp = "Configura la dificultad de la raid (convierte el grupo a banda si hace falta, solo el líder; pregunta heroico y tamaño).\nEl clic derecho solicita las asignaciones del líder." },
            { name = "Indicar discord", icon = "Interface\\Icons\\inv_letter_17", tooltip = "Clic izq.: Enviar enlace de Discord\nClic der.: Editar enlace de Discord", action = "ActionBarDiscord", actionRight = "ActionBarDiscordEdit",
              panelHelp = "Envía el enlace de Discord del addon por el canal configurado.\nEl clic derecho del icono también lo edita en el momento.",
              panelFields = {
                  { key = "chat.discordLink", type = "textCompact", label = "Enlace de Discord", default = "", help = "Enlace que se envía al pulsar 'Indicar discord'." },
              } },
            { name = "Nombrar objetivo", icon = "Interface\\Icons\\ability_hunter_beastcall", tooltip = "Clic izq.: Nombrar objetivo\nClic der.: Ver info de objetivo", action = "ActionBarNameTarget", actionRight = "ActionBarTargetInfo",
              panelHelp = "Anuncia el nombre del objetivo actual de la banda por el canal configurado.\nEl clic derecho muestra su información." },
            { name = "Marcar principales", icon = "Interface\\Icons\\ability_hunter_markedfordeath", tooltip = "Clic izq.: Marcar principales y alertar\nClic der.: Limpiar marcas de banda", action = "ActionBarMarkMains", actionRight = "ActionBarClearMarks",
              panelHelp = "Marca a los principales de la banda (tanques y curadores) y lo anuncia.\nEl clic derecho limpia las marcas de banda." },
            { name = "Susurrar asignaciones", icon = "Interface\\Icons\\ability_paladin_beaconoflight", tooltip = "Clic izq.: Susurrar asignaciones a la banda", action = "ActionBarWhisperAssignments",
              panelHelp = "Susurra a cada jugador de la banda sus asignaciones actuales (roles, habilidades, buffs y auras)." },
            { name = "Iniciar Check", icon = "Interface\\Icons\\ability_paladin_swiftretribution", tooltip = "Clic izq.: Realizar Ready Check\nClic der.: Reportar jugadores ausentes", action = "ActionBarReadyCheck", actionRight = "ActionBarReportAbsent",
              panelHelp = "Realiza un Ready Check a la banda.\nEl clic derecho reporta los jugadores ausentes." },
            { name = "Iniciar Pull", icon = "Interface\\Icons\\ability_hunter_readiness", tooltip = "Clic izq./der.: Iniciar cuenta regresiva de Pull", action = "ActionBarPull", actionRight = "ActionBarPull",
              panelHelp = "Inicia la cuenta atrás de Pull con una barra de temporizador visible para toda la banda." },
            { name = "Cambiar Botín", icon = "Interface\\Icons\\inv_box_02", tooltip = "Clic izq.: Cambiar método de botín\nClic der.: Asignar maestro despojador al objetivo", action = "ActionBarLootMode", actionRight = "ActionBarMasterLooter",
              panelHelp = "Cambia el método de botín (maestro/grupo).\nEl clic derecho asigna al objetivo como maestro despojador.\nEl tiempo de dados se ajusta en el gestor de botín (/rdloot)." },
            { name = "Auto", icon = "Interface\\Icons\\INV_Misc_Gear_02", tooltip = "Clic izq.: Activar/desactivar el modo Auto (permanente)\nClic der.: Configurar el modo Auto", action = "ActionBarAutoLoot", actionRight = "ActionBarAutoLootConfig", enabled = MenuEnabledByConfig("ui.showAutoLootButton", true), activeEvent = "AUTO_LOOT_STATE_CHANGED",
              panelHelp = "Modo Auto: reparte los cadáveres que saquees mientras seas el maestro despojador.\nRecetas y materiales al maestro; equipamiento verde o mejor al grupo (excluyendo al maestro); dinero y basura al maestro; los ítems de misión se dejan.\nEl on/off lo controla SOLO el clic izquierdo del botón 'Auto' del menú flotante (sesión permanente).",
              panelFields = {
                  { key = "ui.showAutoLootButton", type = "checkbox", label = "Mostrar en la barra inferior", help = "Muestra u oculta el botón 'Auto' de la barra inferior del menú flotante." },
              } },
            { name = "Jugador", icon = "Interface\\Icons\\INV_Misc_GroupNeedMore", tooltip = "Clic izq.: Abrir mi ficha de jugador\nClic der.: Buscar un jugador de tus listas", action = "ActionBarPlayer", actionRight = "ActionBarPlayerFinder",
              panelHelp = "Abre tu ficha de jugador (información, equipamiento, bandas, instancias y monedas) con el clic izquierdo.\nEl clic derecho abre el buscador: autocompleta con los jugadores de tus listas y tú mismo; Enter abre su edición.\nMayús+clic en un ítem de Equipamiento inserta su enlace en el chat activo.",
              tooltipExtra = {
                  { title = "Seguimiento de monedas:", lines = PlayerTrackedLines },
                  { title = "Seguimiento de objetos:", lines = PlayerTrackedItems },
                  { title = "Seguimiento de instancias:", lines = PlayerTrackedInstances },
              } },
            { name = "Configuración", icon = "Interface\\Icons\\INV_Gizmo_02", tooltip = "Clic izq.: Abrir panel de configuración", action = "ActionBarConfig",
              panelHelp = "Abre la ventana de configuración (o usa /rdc).\nLa ventana se centra la primera vez; después respeta la posición en la que la arrastres." },
        },
    },

    -- Temporizadores DBM de la barra de acciones (broadcast timer de la v2).
    -- Cada acción de la barra inferior del menú flotante puede acompañarse de
    -- una barra de cuenta atrás de DBM (barra visual para toda la banda) cuando
    -- dbm.enabled está activo. El MESSAGE de cada acción es personalizable en
    -- el panel de su icono en la barra inferior de la configuración
    -- (dbm.messages); la duración por defecto vive aquí (dato, no código).
    DBM_TIMERS = {
        { action = "ActionBarDiscord",             label = "Indicar discord",            message = "CONECTAR DC",            seconds = 30 },
        { action = "ActionBarMarkMains",           label = "Marcar principales",         message = "MARCAR PRINCIPALES",     seconds = 15 },
        { action = "ActionBarWhisperAssignments",  label = "Susurrar asignaciones",      message = "APLICAR BUFFS",           seconds = 20 },
        { action = "ActionBarReadyCheck",          label = "Iniciar check",              message = "AFK = REEMPLAZO/KICK",    seconds = 30 },
        { action = "ActionBarReportAbsent",        label = "Reportar ausentes",          message = "REPORTAR AUSENTES",      seconds = 15 },
        { action = "ActionBarPull",                label = "Iniciar pull",               message = "¿TODOS LISTOS?",          seconds = 20 },
        { action = "ActionBarLootMode",            label = "Cambiar botín",              message = "CAMBIO DE MÉTODO DE BOTÍN", seconds = 10 },
        { action = "ActionBarMasterLooter",        label = "Asignar maestro despojador", message = "MAESTRO DESPOJADOR",      seconds = 10 },
    },

    -- Datos por defecto de las categorías configurables (se editan desde la
    -- ventana de configuración; cada ítem es { name = ..., icon = ... })
    DEFAULT_LISTS = {
        -- Listas configuradas por el usuario. Se arrancan VACÍAS (decisión de
        -- "versión limpia": el contenido por defecto de la v2 se desactivó).
        -- "Reiniciar" en cada pestaña las restaura a este estado (vacío).
        roles = {}, abilities = {}, buffs = {}, auras = {}, mechanics = {}, rules = {},
    },

    -- Configuración por defecto del spammer de reclutamiento (estilo KRT). Vive
    -- dentro de cada banda (bands[i].spammer); estos defaults se aplican "lazy"
    -- al primer acceso (RD.utils.bands:GetSpammer) sin ensuciar la DB con bandas
    -- que nunca spamean. channels es un mapa canal -> bool (solo los true envían).
    SPAMMER_DEFAULTS = {
        name = "",
        -- Prefijo/sufijo por defecto al restablecer el spammer: "Armo" y "Need".
        prefix = "Armo",
        suffix = "Need",
        -- Último band.name / tamaño desde el que se sincronizó el campo nombre
        -- (al renombrar la banda, AutoComposition propaga al abrir el spammer).
        syncedBandName = "",
        syncedSize = 0,
        duration = 60,
        tank = 0, tankClass = "",
        healer = 0, healerClass = "",
        melee = 0, meleeClass = "",
        ranged = 0, rangedClass = "",
        message = "",
        -- Separador de partes: "" = sin separador (por defecto al restablecer).
        separator = "",
        channels = { RAID = true },
        -- El ojo de cada fila de composición incluye/omite el texto de CLASES en
        -- el mensaje (el número y el rol siempre se incluyen).
        tankClassShow = true, healerClassShow = true,
        meleeClassShow = true, rangedClassShow = true,
    },

    -- Opciones del separador de partes del mensaje del spammer de banda. El
    -- valor se guarda en band.spammer.separator; "" significa "sin separador".
    -- REGLA: cada separador es UN SOLO símbolo y se comporta como una coma:
    -- va pegado a la parte anterior seguido de un espacio ("test/ siguiente"),
    -- sin espacios a su alrededor. El separador elegido reemplaza las comas del
    -- campo Mensaje al componer.
    -- NOTA: el pipe "|" NO es una opción: un "|" suelto en un mensaje de chat
    -- se interpreta como marca de formato de color/enlace del cliente y no se
    -- renderiza bien dentro de los wrappers de título (= x = / [x]).
    SPAMMER_SEPARATORS = {
        { key = ",",   label = ",  (coma)" },
        { key = "/",   label = "/  (barra)" },
        { key = ";",   label = ";  (punto y coma)" },
        { key = "",    label = "Sin separador" },
    },

    -- Texto inicial del campo Mensaje al restablecer el spammer de banda. La
    -- cola (X/Y) se añade sola al final del mensaje (BuildMessageFrom), por eso
    -- no lleva {players}.
    SPAMMER_INITIAL_MESSAGE = "De0,ConDC,CupoFrag,GS {gs}+,Wisp Func+GS",

    -- Defaults del spammer de reglas (ui.rulesSpammer; también en DEFAULT_CONFIG).
    RULES_SPAMMER_DEFAULTS = {
        duration = 45,
        channels = { RAID = true },
        selectedTitle = "",
    },

    -- Definiciones de menú (escalables: agregar datos, no código).
    -- Los ítems con `dynamic` renderizan un submenú con los elementos de la
    -- lista de configuración correspondiente (clave de RD.config).
    MENU_DEFINITIONS = {
        MainFrameOptions = {
            { id = "abilities", name = "Habilidades", action = "ShowSkills", dynamic = "abilities", icon = "Interface\\Icons\\ability_shaman_heroism", tooltip = "Gestionar habilidades del grupo", enabled = MenuEnabledByConfig("ui.showAbilitiesMenu", true) },
            { id = "roles",     name = "Roles",       action = "ShowRoles",  dynamic = "roles",      icon = "Interface\\Icons\\Ability_Warrior_DefensiveStance", tooltip = "Gestionar roles del grupo", enabled = MenuEnabledByConfig("ui.showRolesMenu", true) },
            { id = "buffs",     name = "Buffs",       action = "ShowBuffs",  dynamic = "buffs",      icon = "Interface\\Icons\\Spell_Magic_MageArmor", tooltip = "Gestionar buffs del grupo", enabled = MenuEnabledByConfig("ui.showBuffsMenu", true) },
            { id = "auras",     name = "Auras",       action = "ShowAuras",  dynamic = "auras",      icon = "Interface\\Icons\\Spell_Holy_AuraMastery", tooltip = "Gestionar auras del grupo", enabled = MenuEnabledByConfig("ui.showAurasMenu", true) },
            { id = "mechanics", name = "Mecánicas",   action = "ShowMechanics", dynamic = "mechanics", icon = "Interface\\Icons\\Spell_Shadow_Metamorphosis", tooltip = "Mecánicas de los jefes", enabled = MenuEnabledByConfig("ui.showMechanicsMenu", true) },
            { id = "rules",     name = "Reglas",       action = "ShowRaidRules", dynamic = "rules",     icon = "Interface\\Icons\\INV_Scroll_03", tooltip = "Reglas de la banda", enabled = MenuEnabledByConfig("ui.showRulesMenu", true) },
            { id = "bands",     name = "Bandas",      dynamic = "bands",    tooltip = "Abrir una de tus bandas", icon = "Interface\\Icons\\INV_Banner_02", enabled = MenuEnabledByConfig("ui.showBandsMenu", true) },
            { id = "addonOptions", name = "RaidDominion", tooltip = "Configuración del addon", submenu = "addonOptions" },
        },
        addonOptions = {
            { name = "Registrar", action = "RegisterPlayer", icon = "Interface\\Icons\\INV_Misc_Book_09", tooltip = "Guardar un registro completo del jugador (clase, equipamiento, bandas, hermandad)" },
            { name = "Configuración", action = "ToggleConfig", tooltip = "Abrir la ventana de configuración" },
            { name = "Ayuda",         action = "ShowHelp",     tooltip = "Mostrar ayuda del addon" },
            { name = "Recargar",      action = "ReloadUI",     tooltip = "Recargar la interfaz" },
            { name = "Ocultar",       action = "HideMainFrame", tooltip = "Ocultar el menú principal" },
        },
    },

    -- Configuración por defecto (merge profundo con la DB al cargar)
    DEFAULT_CONFIG = {
        general = {
            debug = false,
            scale = 1.0,
        },
        ui = {
            menu = {
                showOnStart = true,
                lockPosition = false,
                itemsPerColumn = 9,   -- elementos por columna (las columnas se derivan: clamp(ceil(ítems/esto), 2, MAX_COLUMNS))
                position = { point = "CENTER", relativeTo = "UIParent", relativePoint = "CENTER", x = 0, y = 0 },
                -- Orden de los ítems del menú flotante (MainFrameOptions) que se
                -- pueden reordenar (los que tienen pestaña propia en la config:
                -- abilities/roles/buffs/auras/mechanics/rules/bands). Vacío =
                -- orden de declaración. Se reordena arrastrando el grip de una
                -- pestaña superior de la ventana de configuración.
                itemOrder = {},
            },
            actionBar = {
                -- Orden de los iconos de la barra inferior (ACTION_BAR.ITEMS,
                -- por `action`). Vacío = orden de declaración. Se reordena
                -- arrastrando el grip de un icono en la barra de la ventana de
                -- configuración y se comparte con la barra del menú flotante.
                order = {},
            },
            minimap = {
                position = 0.75,       -- ángulo normalizado (0..1) del botón de minimapa
            },
            spammer = {
                -- Posición de la ventana del spammer (como ui.menu.position)
                position = { point = "CENTER", relativeTo = "UIParent", relativePoint = "CENTER", x = 0, y = 0 },
            },
            rulesSpammer = {
                duration = 45,
                channels = { RAID = true },
                selectedTitle = "",
                position = { point = "CENTER", relativeTo = "UIParent", relativePoint = "CENTER", x = 0, y = 0 },
            },
            showTooltips = true,
            -- Visibilidad en vivo de cada submenú de lista en el menú flotante.
            showAbilitiesMenu = true,
            showRolesMenu = true,
            showBuffsMenu = true,
            showAurasMenu = true,
            showMechanicsMenu = true,
            showRulesMenu = true,
            showBandsMenu = true,
            -- Mostrar el botón "Auto" de la barra inferior (el modo Auto en sí
            -- no tiene opciones; su on/off lo controla el clic izquierdo).
            showAutoLootButton = true,
            -- Diagnóstico del protocolo RD_COMM (imprime lo que se recibe y por
            -- qué se rechaza). Solo para depurar entregas en el cliente real.
            commDebug = false,
        },
        chat = {
            channel = "DEFAULT",
            discordLink = "",
        },
        dbm = {
            -- Broadcast timer de DBM: si está activo, cada acción de la barra
            -- inferior del menú flotante lanza una barra de cuenta atrás de DBM
            -- con el mensaje configurable correspondiente (dbm.messages.<acción>).
            enabled = true,
            messages = {},
        },
        loot = {
            rollTimeLimit = 20,   -- segundos de cuenta atrás para los dados de un ítem (máx. 60)
            -- El modo Auto (botón "Auto" de la barra inferior) NO tiene opciones
            -- de configuración: su comportamiento es fijo (recetas/materiales/
            -- dinero/basura al maestro; verde o mejor a la banda; misiones se
            -- dejan) y su on/off lo controla SOLO el clic izquierdo del botón.
            -- La única preferencia relacionada es ui.showAutoLootButton
            -- (mostrar/ocultar el botón en la barra inferior).
        },
        roles = {},
        buffs = {},
        auras = {},
        abilities = {},
        mechanics = {},
        rules = {},
        assignments = {
            roles = {},
            abilities = {},
            buffs = {},
            auras = {},
        },
        -- Presentación de los anuncios por tipo de elemento (pestaña de
        -- configuración correspondiente a cada lista):
        --   wrapper    : estilo del wrapper del título al anunciar ("= x =",
        --                "[x]" o "none" con el nombre tal cual). POR DEFECTO "none"
        --                (Ninguno) en casi todas las listas; las REGLAS usan
        --                "equals" (= x =) para que el spammer de regla muestre
        --                siempre un título distinguible por defecto.
        --   word       : palabra que va antes del elemento al anunciarlo con el clic
        --                en el texto (solo ASIGNABLES; "NEED" por defecto)
        --   assignWord : palabra que va antes del elemento al usar el clic derecho
        --                del botón de asignación (solo ASIGNABLES; ninguna)
        -- Bandas, mecánicas y reglas NO son asignables: solo usan el wrapper.
        announce = {
            bands     = { wrapper = "none" },
            roles     = { wrapper = "none", word = "NEED", assignWord = "" },
            abilities = { wrapper = "none", word = "NEED", assignWord = "" },
            buffs     = { wrapper = "none", word = "NEED", assignWord = "" },
            auras     = { wrapper = "none", word = "NEED", assignWord = "" },
            mechanics = { wrapper = "none" },
            rules     = { wrapper = "equals" },
        },
        -- Privacidad de cada lista ante las peticiones de "Obtener" (el líder
        -- responde según el modo que tenga configurado para esa lista):
        --   open    : compartir sin restricción (responde automáticamente)
        --   ask     : preguntar primero (diálogo al líder mostrando quién pide)
        --   private : privado (no se responde)
        -- Default "open" para no cambiar el comportamiento de compartir de v2.
        privacy = {
            roles     = "open",
            abilities = "open",
            buffs     = "open",
            auras     = "open",
            mechanics = "open",
            rules     = "open",
            bands     = "open",
        },
        -- Bandas registradas: nombre, icono, horario, gearscore mínimo y jugadores.
        bands = {},
        -- Registro detallado POR PERSONAJE generado por "Registrar": contenedor
        -- con clave "Nombre-Reino" por personaje; lo demás queda compartido.
        registry = {},
        -- Personajes detectados de esta cuenta (comparten esta misma DB por ser
        -- una SavedVariables account-wide): clave "Nombre-Reino".
        characters = {},
        -- Objetivos ("meta") de equipamiento y monedas POR PERSONAJE. Contenedor
        -- con clave "Nombre-Reino"; cada personaje guarda:
        --   equip    = { [slot] = { name, itemID, quality, ilvl, icon, done } }
        --   currency = { [nombreMoneda] = { target, reached } }
        -- Data personal del jugador: NO entra en el contrato con el portal (§14).
        itemGoals = {},
    },

    -- Esquema de configuración: la ventana se renderiza a partir de esto
    -- y según el valor seteado actual en RD.config.
    CONFIG_SCHEMA = {
        { id = "general", title = "General", order = 1, icon = "Interface\\Icons\\INV_Gizmo_02", sections = {
            { id = "menu", title = "Menú", help = "Opciones de apariencia y comportamiento del menú flotante.", fields = {
                { key = "ui.menu.showOnStart",   type = "checkbox", label = "Mostrar menú al iniciar", help = "Muestra u oculta el menú flotante al iniciar sesión." },
                { key = "ui.showTooltips",       type = "checkbox", label = "Mostrar información de ayuda", help = "Activa o desactiva las ventanas de ayuda al pasar el cursor sobre los elementos de la interfaz de RaidDominion." },
                { key = "ui.menu.itemsPerColumn", type = "slider",  label = "Elementos por columna", min = 2, max = 9, step = 1, help = "Máximo de elementos por columna. Las columnas se calculan solas: cuantos más elementos por columna, menos columnas (y más alto el menú)." },
                { key = "general.scale",         type = "slider",   label = "Escala de la interfaz", min = 0.7, max = 1.5, step = 0.05, help = "Escala global de la interfaz de RaidDominion." },
            }},
            { id = "chat", title = "Chat", help = "Canal usado para anunciar mensajes.", fields = {
                { key = "chat.channel", type = "dropdown", label = "Salida por defecto", help = "Canal por defecto para los mensajes de la raid. 'Por defecto' elige automáticamente según el contexto (banda, grupo, hermandad, etc.).", options = {
                    ["DEFAULT"]      = "POR DEFECTO",
                    ["SYSTEM"]       = "SISTEMA",
                    ["GUILD"]        = "HERMANDAD",
                    ["SAY"]          = "DECIR",
                    ["YELL"]         = "GRITAR",
                    ["PARTY"]        = "GRUPO",
                    ["RAID"]         = "BANDA",
                    ["RAID_WARNING"] = "AVISO DE BANDA",
                    ["BATTLEGROUND"] = "CAMPO DE BATALLA",
                }},
            }},
            { id = "reset", title = "", fields = {
                { key = "actions", type = "buttons", buttons = {
                    { key = "reload", label = "Recargar UI", action = "ReloadUI", help = "Recarga la interfaz para aplicar cambios que requieren reinicio." },
                    { key = "reset", label = "Restablecer valores por defecto", action = "ResetConfig", help = "Borra toda la configuración de RaidDominion y la vuelve a los valores por defecto.", confirmText = "¿Restablecer TODA la configuración de RaidDominion? Se perderán tus opciones, bandas, registro (portal), personajes y metas de ítems y monedas.", confirmAccept = "Restablecer" },
                }},
            }},
        }},
        { id = "bands", title = "Bandas", order = 2, icon = "Interface\\Icons\\INV_Banner_02", sections = {
            { id = "main", title = "Bandas registradas", help = "Gestiona las bandas: nombre, gearscore mínimo y horario.",
                headerCheckbox = { key = "ui.showBandsMenu", label = "Mostrar en el menú flotante", help = "Muestra u oculta el submenú de bandas del menú flotante." },
                fields = {
                { key = "bands", type = "bands", label = "Bandas", height = 300, help = "Crea, edita o elimina bandas. Cada banda agrupa jugadores con rol, gearscore, sanción y asistencia." },
            }},
            { id = "announce", title = "Anuncios de banda", help = "Cómo se presenta una banda al anunciarla desde los submenús del menú flotante.", fields = {
                { key = "announce.bands.wrapper", type = "dropdown", label = "Estilo del título", help = "Wrapper que envuelve el nombre al anunciar la banda. 'Ninguno' deja el nombre tal cual.", options = { ["equals"] = "= Nombre =", ["brackets"] = "[Nombre]", ["none"] = "Ninguno" } },
            }},
        }},
        { id = "roles", title = "Roles", order = 4, icon = "Interface\\Icons\\Ability_Warrior_DefensiveStance", sections = {
            { id = "main", title = "Roles del grupo", help = "Ítems de rol asignables desde el menú flotante.",
                headerCheckbox = { key = "ui.showRolesMenu", label = "Mostrar en el menú flotante", help = "Muestra u oculta el submenú de roles del menú flotante." },
                fields = {
                { key = "roles", type = "list", label = "Roles", height = 220, help = "Edita el nombre en línea y elige el icono con el botón de la derecha (abre el selector)." },
            }},
            { id = "announce", title = "Anuncios de roles", layout = "row", help = "Cómo se presenta un rol al anunciarlo desde el menú flotante.", fields = {
                { key = "announce.roles.wrapper", type = "dropdown", label = "Estilo del título", help = "Wrapper que envuelve el nombre del rol al anunciarlo. 'Ninguno' deja el nombre tal cual.", options = { ["brackets"] = "[Nombre]", ["equals"] = "= Nombre =", ["none"] = "Ninguno" } },
                { key = "announce.roles.word", type = "text", label = "Palabra antes del elemento", help = "Palabra antes del rol al anunciarlo sin objetivo (hoy: 'NEED')." },
                { key = "announce.roles.assignWord", type = "text", label = "Palabra al clic derecho en Asignar", help = "Palabra antes del elemento al usar el clic derecho en el botón de asignación (vacía = ninguna)." },
            }},
        }},
        { id = "abilities", title = "Habilidades", order = 3, icon = "Interface\\Icons\\ability_shaman_heroism", sections = {
            { id = "main", title = "Habilidades del grupo", help = "Habilidades asignables desde el menú flotante.",
                headerCheckbox = { key = "ui.showAbilitiesMenu", label = "Mostrar en el menú flotante", help = "Muestra u oculta el submenú de habilidades del menú flotante." },
                fields = {
                { key = "abilities", type = "list", label = "Habilidades", height = 220, help = "Edita el nombre en línea y elige el icono con el botón de la derecha (abre el selector)." },
            }},
            { id = "announce", title = "Anuncios de habilidades", layout = "row", help = "Cómo se presenta una habilidad al anunciarla desde el menú flotante.", fields = {
                { key = "announce.abilities.wrapper", type = "dropdown", label = "Estilo del título", help = "Wrapper que envuelve el nombre de la habilidad al anunciarla. 'Ninguno' deja el nombre tal cual.", options = { ["brackets"] = "[Nombre]", ["equals"] = "= Nombre =", ["none"] = "Ninguno" } },
                { key = "announce.abilities.word", type = "text", label = "Palabra antes del elemento", help = "Palabra antes de la habilidad al anunciarla sin objetivo (hoy: 'NEED')." },
                { key = "announce.abilities.assignWord", type = "text", label = "Palabra al clic derecho en Asignar", help = "Palabra antes del elemento al usar el clic derecho en el botón de asignación (vacía = ninguna)." },
            }},
        }},
        { id = "buffs", title = "Buffs", order = 5, icon = "Interface\\Icons\\Spell_Magic_MageArmor", sections = {
            { id = "main", title = "Buffs del grupo", help = "Buffs asignables desde el menú flotante.",
                headerCheckbox = { key = "ui.showBuffsMenu", label = "Mostrar en el menú flotante", help = "Muestra u oculta el submenú de buffs del menú flotante." },
                fields = {
                { key = "buffs", type = "list", label = "Buffs", height = 220, help = "Edita el nombre en línea y elige el icono con el botón de la derecha (abre el selector)." },
            }},
            { id = "announce", title = "Anuncios de buffs", layout = "row", help = "Cómo se presenta un buff al anunciarlo desde el menú flotante.", fields = {
                { key = "announce.buffs.wrapper", type = "dropdown", label = "Estilo del título", help = "Wrapper que envuelve el nombre del buff al anunciarlo. 'Ninguno' deja el nombre tal cual.", options = { ["brackets"] = "[Nombre]", ["equals"] = "= Nombre =", ["none"] = "Ninguno" } },
                { key = "announce.buffs.word", type = "text", label = "Palabra antes del elemento", help = "Palabra antes del buff al anunciarlo sin objetivo (hoy: 'NEED')." },
                { key = "announce.buffs.assignWord", type = "text", label = "Palabra al clic derecho en Asignar", help = "Palabra antes del elemento al usar el clic derecho en el botón de asignación (vacía = ninguna)." },
            }},
        }},
        { id = "auras", title = "Auras", order = 6, icon = "Interface\\Icons\\Spell_Holy_AuraMastery", sections = {
            { id = "main", title = "Auras del grupo", help = "Auras asignables desde el menú flotante.",
                headerCheckbox = { key = "ui.showAurasMenu", label = "Mostrar en el menú flotante", help = "Muestra u oculta el submenú de auras del menú flotante." },
                fields = {
                { key = "auras", type = "list", label = "Auras", height = 220, help = "Edita el nombre en línea y elige el icono con el botón de la derecha (abre el selector)." },
            }},
            { id = "announce", title = "Anuncios de auras", layout = "row", help = "Cómo se presenta un aura al anunciarla desde el menú flotante.", fields = {
                { key = "announce.auras.wrapper", type = "dropdown", label = "Estilo del título", help = "Wrapper que envuelve el nombre del aura al anunciarla. 'Ninguno' deja el nombre tal cual.", options = { ["brackets"] = "[Nombre]", ["equals"] = "= Nombre =", ["none"] = "Ninguno" } },
                { key = "announce.auras.word", type = "text", label = "Palabra antes del elemento", help = "Palabra antes del aura al anunciarla sin objetivo (hoy: 'NEED')." },
                { key = "announce.auras.assignWord", type = "text", label = "Palabra al clic derecho en Asignar", help = "Palabra antes del elemento al usar el clic derecho en el botón de asignación (vacía = ninguna)." },
            }},
        }},
        { id = "mechanics", title = "Mecánicas", order = 7, icon = "Interface\\Icons\\Spell_Shadow_Metamorphosis", sections = {
            { id = "main", title = "Mecánicas de jefes", help = "Mecánicas de los jefes de la banda.",
                headerCheckbox = { key = "ui.showMechanicsMenu", label = "Mostrar en el menú flotante", help = "Muestra u oculta el submenú de mecánicas del menú flotante." },
                fields = {
                { key = "mechanics", type = "contentList", label = "Mecánicas", height = 220, help = "Título, icono y contenido. El clic en el título o la fila abre el editor." },
            }},
            { id = "announce", title = "Anuncios de mecánicas", help = "Cómo se presenta una mecánica al anunciarla desde el menú flotante.", fields = {
                { key = "announce.mechanics.wrapper", type = "dropdown", label = "Estilo del título", help = "Wrapper que envuelve el título de la mecánica al anunciarla. 'Ninguno' deja el título tal cual.", options = { ["equals"] = "= Nombre =", ["brackets"] = "[Nombre]", ["none"] = "Ninguno" } },
            }},
        }},
        { id = "rules", title = "Reglas", order = 8, icon = "Interface\\Icons\\INV_Scroll_03", sections = {
            { id = "main", title = "Reglas de la banda", help = "Reglas de comportamiento de la banda.",
                headerCheckbox = { key = "ui.showRulesMenu", label = "Mostrar en el menú flotante", help = "Muestra u oculta el submenú de reglas del menú flotante." },
                fields = {
                { key = "rules", type = "contentList", label = "Reglas", height = 220, help = "Título, icono y contenido. El clic en el título o la fila abre el editor." },
            }},
            { id = "announce", title = "Anuncios de reglas", help = "Cómo se presenta una regla al anunciarla desde el menú flotante.", fields = {
                { key = "announce.rules.wrapper", type = "dropdown", label = "Estilo del título", help = "Wrapper que envuelve el título de la regla al anunciarla. 'Ninguno' deja el título tal cual.", options = { ["equals"] = "= Nombre =", ["brackets"] = "[Nombre]", ["none"] = "Ninguno" } },
            }},
        }},
        { id = "help", title = "Ayuda", order = 100, icon = "Interface\\Icons\\INV_Misc_Book_09", compact = true, sections = {
            { id = "general", title = "Guía de RaidDominion", fields = {
                { key = "helpAccordion", type = "helpAccordion", entries = {
                    { title = "Acerca de", content = "RaidDominion v3.0.0 es un gestor de banda para World of Warcraft 3.3.5a (WotLK, esMX).\nOrganiza roles, habilidades, buffs, auras, mecánicas y reglas, y gestiona bandas, jugadores y asistencia. Incluye menú flotante, gestor de botín, spammers, temporizador DBM y una barra de acciones de raid." },
                    { title = "Primeros pasos y comandos", content = "Al entrar verás el menú flotante (si 'Mostrar menú al iniciar' está activo). Clic izquierdo navega o ejecuta; clic derecho vuelve al menú anterior; arrastra el menú para moverlo.\nComandos:\n/rd - muestra/oculta el menú flotante\n/rdc - abre/cierra la configuración\n/rdh - muestra el resumen de comandos\n/rdloot - abre el gestor de botín\n/rdminimap - muestra/oculta el botón del minimapa\nSubcomandos de /rd: c (config), loot (o botin), help (o h o ?)" },
                    { title = "Menú flotante", content = "El menú agrupa: Roles, Habilidades, Buffs, Auras, Mecánicas, Reglas, Bandas y RaidDominion.\nLos ítems asignables: selecciona un objetivo y pulsa el icono del ítem para asignárselo (o desasignarlo); el clic en el texto lo anuncia por el canal configurado.\nLa barra inferior reúne las acciones de raid (ver 'Barra de acciones y temporizador DBM')." },
                    { title = "Configuración", content = "Ábrela con /rdc o desde el menú flotante / la barra de acciones.\nPestañas: General, Bandas, Habilidades, Roles, Buffs, Auras, Mecánicas, Reglas y Ayuda.\nLa barra inferior replica las acciones de raid: pulsa un icono para ver los AJUSTES de ese botón (no ejecuta la acción; para ejecutarla usa la barra del menú flotante). Arrastra el agarre para reordenarla (afecta también al menú flotante).\nEl botón 'Restablecer valores por defecto' (tab General) borra toda la configuración Y tus datos: bandas, registro, personajes y metas." },
                    { title = "Listas asignables y de contenido", content = "Roles, habilidades, buffs y auras son listas asignables; mecánicas y reglas, listas de contenido (título, icono y texto).\nSe editan en su pestaña: añade o quita ítems, elige icono y usa el botón-ojo para decidir si aparecen en el menú.\n'Obtener' pide la lista al líder; 'Reiniciar' la vacía.\nAl pulsar un ítem de contenido en el menú, su texto se envía al canal configurado (se trocea solo si es largo)." },
                    { title = "Bandas y jugadores", content = "Crea, edita o elimina bandas en Configuración > Bandas (nombre, gearscore mínimo y horario).\nDesde el menú > Bandas, el clic en el texto anuncia la banda y el clic en el icono abre su gestor de jugadores: rol (Tanque, Healer, Rango o Melee), dual, líder (No/Sí/Ayudante), asistencia (+/-) y sanción.\nCada jugador tiene botones para invitarlo y susurrarle una plantilla de invitación con los datos de la banda." },
                    { title = "Gestor de botín y modo Auto", content = "Gestor de botín (/rdloot o menú > Bandas > Gestor de botín): arrastra un ítem de la bolsa o haz clic con uno en el cursor. Tira dados (Main/Dual/Enchant) con límite de tiempo (campo 'Límite (s)' de la ventana), elige ganador, declara ganador y desempata los empates. El historial se agrupa por día y, dentro del día, por ítem.\nModo Auto (botón 'Auto' de la barra inferior): reparte cada cadáver que saquees (maestro despojador). Recetas y materiales al maestro; verde o mejor en rotación entre el grupo (excluyendo al maestro); dinero y basura al maestro; ítems de misión se saltan. Es PERMANENTE: se apaga solo con el clic izquierdo del botón 'Auto'." },
                    { title = "Spammers", content = "Compón y rota mensajes por canal (máx. 255 caracteres; si lo superas, el bucle se detiene y avisa).\n- De banda: prefijo, nombre, sufijo, duración, composición por rol y vista previa. Desde menú > Bandas > Spamear banda (requiere una banda registrada).\n- De reglas: elige la regla, duración y canales. Desde menú > Reglas > Spamear reglas o el minimapa." },
                    { title = "Barra de acciones y temporizador DBM", content = "Cada botón de la barra inferior del menú flotante explica su acción en el tooltip (pasa el cursor por encima); el clic derecho suele hacer una acción secundaria.\nEl panel de cada icono en la configuración muestra sus ajustes, incluido el texto de su temporizador DBM.\nTemporizador DBM: si el addon DBM está instalado, acompaña 8 de estas acciones con una barra de cuenta atrás. Se activa en Configuración > General ('Acompañar las acciones con temporizador DBM')." },
                    { title = "Comunicación y privacidad", content = "En grupo o banda puedes pedir al líder las asignaciones, reglas, mecánicas o bandas (botón 'Obtener' o clic derecho en 'Modo de raid').\nCada lista tiene una privacidad ante 'Obtener': Privado (no responde), Preguntar primero (pide confirmación) o Compartir (responde al instante).\nEl líder puede compartir asignaciones y listas con el resto de jugadores que usen el addon." },
                    { title = "Minimapa", content = "El botón del minimapa: clic izquierdo abre/cierra el menú flotante; clic derecho abre un menú contextual (Configuración, Gestor de botín, Recoger ítems, Spamear reglas/banda y Recargar UI; el nombre de tu personaje y 'Jugador' se añaden si están disponibles).\nMantén Alt y arrastra para moverlo alrededor del minimapa. Se muestra/oculta con /rdminimap." },
                    { title = "Registrar y fichas de jugador", content = "'Registrar' (menú > RaidDominion > Registrar) guarda un registro completo de tu jugador (clase, equipamiento, bandas, hermandad) para el portal web del proyecto.\nEl botón 'Jugador' de la barra abre tu ficha: información, equipamiento, bandas, instancias y monedas; el clic derecho abre el buscador de jugadores de tus listas.\nLos checks de seguimiento (Monedas, Equipamiento e Instancias) añaden lo que vigilas al tooltip del botón Jugador." },
                }},
            }},
        }},
    },
}

-- Semilla de las listas configurables: se rellenan tras construir el literal
-- porque dentro de la tabla RD.constants aún no existe la referencia.
local listSeeds = RD.constants.DEFAULT_LISTS
RD.constants.DEFAULT_CONFIG.roles = listSeeds.roles
RD.constants.DEFAULT_CONFIG.buffs = listSeeds.buffs
RD.constants.DEFAULT_CONFIG.auras = listSeeds.auras
RD.constants.DEFAULT_CONFIG.abilities = listSeeds.abilities
RD.constants.DEFAULT_CONFIG.mechanics = listSeeds.mechanics
RD.constants.DEFAULT_CONFIG.rules = listSeeds.rules

-- Mensajes del temporizador DBM por acción: se generan desde DBM_TIMERS (una
-- sola fuente de datos) como CAMPOS del panel de configuración de cada icono
-- de la barra inferior (panelFields del ítem cuyo action o actionRight
-- coincide). Así cada botón edita su propio mensaje (dbm.messages.<acción>)
-- EN SU SECCIÓN, liberando la pestaña General de estos inputs.
local function FindBarItem(actionId)
    for _, it in ipairs(RD.constants.ACTION_BAR.ITEMS) do
        if it.action == actionId or it.actionRight == actionId then
            return it
        end
    end
end
for _, timer in ipairs(RD.constants.DBM_TIMERS) do
    local item = FindBarItem(timer.action)
    if item then
        item.panelFields = item.panelFields or {}
        item.panelFields[#item.panelFields + 1] = {
            key = "dbm.messages." .. timer.action,
            type = "textCompact",
            label = (timer.action == item.action) and "Temporizador DBM"
                or ("Temporizador DBM · " .. timer.label),
            default = timer.message,
            help = "Mensaje de la cuenta atrás de DBM al ejecutar '" .. timer.label .. "' en el menú flotante. Vacío = sin temporizador para esta acción."
        }
    end
    RD.constants.DEFAULT_CONFIG.dbm.messages[timer.action] = timer.message
end
-- El interruptor MAESTRO del temporizador DBM queda en la pestaña General
-- (una sola casilla global; los mensajes por acción viven en cada panel).
local dbmCheckboxFields = {
    { key = "dbm.enabled", type = "checkbox", label = "Acompañar las acciones con temporizador DBM", help = "Muestra una barra de cuenta atrás de DBM (si está instalado) al ejecutar cada acción de la barra inferior del menú flotante. El texto de cada acción se personaliza en el panel de su icono (barra inferior de esta ventana)." },
}
local dbmCheckboxSection = {
    id = "dbm",
    title = "Temporizador DBM",
    help = "Ayuda visual de cuenta atrás al usar la barra de acciones.",
    fields = dbmCheckboxFields,
}
for _, tab in ipairs(RD.constants.CONFIG_SCHEMA) do
    if tab.id == "general" then
        for i, sec in ipairs(tab.sections) do
            if sec.id == "reset" then
                -- insertar entre "Chat" y los botones de reset (Recargar /
                -- Restablecer): solo el interruptor maestro del temporizador.
                table.insert(tab.sections, i, dbmCheckboxSection)
                break
            end
        end
        break
    end
end

return RD.constants
