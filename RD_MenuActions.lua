--[[
    RD_MenuActions.lua
    PROPÓSITO: Registro y ejecución de acciones invocadas por los ítems de menú.
              Cada `action` presente en RD.constants.MENU_DEFINITIONS se registra
              automáticamente barriendo las definiciones (no hay lista hardcodeada).
    API PÚBLICA:
        - RD.MenuActions:Register(actionId, handler)
        - RD.MenuActions:RegisterDefaultActions()
        - RD.MenuActions:Execute(actionId, context)
    EVENTOS: Ninguno directo. Las acciones de UI disparan UI_SHOW/UI_HIDE
             y CONFIG_RESET a través de los módulos que invocan.
    NOTA: Los módulos de dominio no portados (habilidades, roles, buffs, auras,
          mecánicas, hermandad, gearscore) muestran "módulo en desarrollo".
]]

local addonName, private = ...
local RD = _G.RaidDominion or {}
_G.RaidDominion = RD

local MenuActions = {
    handlers = {},
}

-- Mensaje de sistema (fallback a print si messageManager no está cargado)
-- Mensaje de sistema (helper central en RD.UIUtils.Log)
local Log = (RD.UIUtils and RD.UIUtils.Log) or function(msg) print(msg) end

-- Registra un handler para una acción
function MenuActions:Register(actionId, handler)
    if not actionId or type(handler) ~= "function" then return end
    self.handlers[actionId] = handler
end

-- Ejecuta una acción con contexto (button, item, frame, ...)
function MenuActions:Execute(actionId, context)
    local handler = self.handlers[actionId]
    if handler then
        local ok, err = pcall(handler, context or {})
        if not ok then
            Log("|cffff0000[RaidDominion]|r Error en acción '" .. tostring(actionId) .. "': " .. tostring(err))
        end
    else
        Log("|cffff0000[RaidDominion]|r Acción no registrada: " .. tostring(actionId))
    end
end

-- ============================================================================
-- Handlers de acciones desarrolladas
-- ============================================================================

-- Módulos de dominio aún no portados: aviso y vuelta al menú principal
local function PlaceholderHandler(context)
    local item = context and context.item
    local name = (item and item.name) or "Acción"
    Log(string.format(
        "|cffff8000[RaidDominion]|r %s: módulo en desarrollo (disponible en una próxima versión).",
        name))
    if item and RD.ui and RD.ui.menuFrame and RD.ui.menuFrame.ShowMainMenu then
        RD.ui.menuFrame:ShowMainMenu()
    end
end

-- Abre la ventana de configuración en una pestaña concreta (por id del esquema)
local function OpenConfigTab(tabId)
    return function()
        if RD.ui and RD.ui.configWindow and RD.ui.configWindow.Show then
            RD.ui.configWindow:Show()
            if RD.ui.configWindow.SelectTabById then
                RD.ui.configWindow:SelectTabById(tabId)
            end
        end
    end
end

local function HandleToggleConfig()
    local cw = RD.ui and RD.ui.configWindow
    if not cw or not cw.Show then return end
    cw:Show()
    if cw.SelectTabById then
        cw:SelectTabById("general")
    end
end

local function HandleShowHelp()
    if RD.ui and RD.ui.configWindow and RD.ui.configWindow.Show then
        RD.ui.configWindow:Show()
        -- SelectTabById lo implementa config-system; guard por robustez
        if RD.ui.configWindow.SelectTabById then
            RD.ui.configWindow:SelectTabById("help")
        end
    else
        Log("|cffff8000[RaidDominion]|r Abre la configuración con /rdc.")
    end
end

local function HandleReloadUI()
    ReloadUI()
end

local function HandleHideMainFrame()
    if RD.ui and RD.ui.menuFrame and RD.ui.menuFrame.Hide then
        RD.ui.menuFrame:Hide()
    end
end

-- Abre la ventana de configuración en la pestaña "Bandas" (CRUD de bandas)
local function HandleOpenConfigBands()
    if RD.ui and RD.ui.configWindow and RD.ui.configWindow.Show then
        RD.ui.configWindow:Show()
        if RD.ui.configWindow.SelectTabById then
            RD.ui.configWindow:SelectTabById("bands")
        end
    else
        Log("|cffff0000[RaidDominion]|r La ventana de configuración no está disponible.")
    end
end

local function HandleResetConfig()
    if RD.config and RD.config.ResetToDefaults then
        RD.config:ResetToDefaults()
        Log("|cff33ff99[RaidDominion]|r Configuración restablecida a valores por defecto.")
    end
end

-- Abre el spammer de reglas (rotación del mensaje de una regla por canal).
local function HandleOpenRulesSpammer()
    local win = RD.ui and RD.ui.rulesSpammerWindow
    if win and win.Open then
        win:Open()
    else
        Log("|cffff0000[RaidDominion]|r El spammer de reglas no está disponible.")
    end
end

-- Abre el gestor de botín.
local function HandleOpenLoot()
    local win = RD.ui and RD.ui.lootWindow
    if not win then
        Log("|cffff0000[RaidDominion]|r El gestor de botín no está cargado (falta RD_UI_LootWindow.lua).")
        return
    end
    if not win.Open then
        Log("|cffff0000[RaidDominion]|r El gestor de botín no tiene método Open.")
        return
    end
    local ok, err = pcall(win.Open, win)
    if not ok then
        Log("|cffff0000[RaidDominion]|r Error al abrir el gestor de botín: " .. tostring(err))
    end
end

-- Spamea el botín del boss (o el ítem actual del gestor) por la salida por
-- defecto. Acción del submenú Reglas del menú flotante (no requiere la ventana
-- de botín abierta).
local function HandleSpamLoot()
    local loot = RD.modules and RD.modules.loot
    if not loot or not loot.SpamLoot then
        Log("|cffff0000[RaidDominion]|r El gestor de botín no está cargado.")
        return
    end
    if not loot:SpamLoot() then
        Log("|cffff8000[RaidDominion]|r No hay botín abierto ni ítem seleccionado para spamear.")
    end
end

-- Recoge los ítems del botín abierto y los dirige al maestro despojador.
-- Acción del submenú Bandas del menú flotante.
local function HandleCollectLoot()
    local loot = RD.modules and RD.modules.loot
    if not loot or not loot.CollectItems then
        Log("|cffff0000[RaidDominion]|r El gestor de botín no está cargado.")
        return
    end
    loot:CollectItems()
end

-- Genera y guarda el registro detallado del PERSONAJE ACTUAL en las
-- SavedVariables (clave "registry.Nombre-Reino", una entrada por personaje de
-- la cuenta): clase, equipo, asignaciones, bandas, spammers y hermandad
-- (roster completo solo si el jugador es GM). Los registros de los demás
-- personajes se preservan.
local function HandleRegisterPlayer()
    local reg = RD.utils and RD.utils.registry
    if reg and reg.Capture then
        reg:Capture()
    else
        Log("|cffff0000[RaidDominion]|r El registro no está disponible (falta RD_Utils_Registry.lua).")
    end
end

-- Abre el spammer de banda en blanco (sin banda seleccionada ni campos
-- precargados). Acción del submenú Bandas del menú flotante.
local function HandleOpenSpammerEmpty()
    local sw = RD.ui and RD.ui.spammerWindow
    if not sw or not sw.OpenEmpty then
        Log("|cffff0000[RaidDominion]|r El spammer no está disponible.")
        return
    end
    sw:OpenEmpty()
end

-- Abre (o cierra) la ventana "Jugador": busca entre los jugadores de las
-- listas del usuario (asignaciones y bandas) y él mismo, y permite añadir un
-- jugador por nombre a una banda. Acción del submenú RaidDominion.
local function HandleShowPlayer()
    local pw = RD.ui and RD.ui.playerWindow
    if not pw or not pw.Toggle then
        Log("|cffff0000[RaidDominion]|r La ventana de jugador no está disponible.")
        return
    end
    pw:Toggle()
end

-- ============================================================================
-- Registro por barrido de datos (no hardcodear la lista de acciones)
-- ============================================================================

function MenuActions:RegisterDefaultActions()
    -- Mapa de acciones desarrolladas: la acción resuelve a su handler específico
    local developed = {
        ToggleConfig    = HandleToggleConfig,
        ShowHelp        = HandleShowHelp,
        ReloadUI        = HandleReloadUI,
        HideMainFrame   = HandleHideMainFrame,
        ResetConfig     = HandleResetConfig,
        -- Las categorías configurables abren su pestaña en la ventana de config
        ShowSkills      = OpenConfigTab("abilities"),
        ShowRoles       = OpenConfigTab("roles"),
        ShowBuffs       = OpenConfigTab("buffs"),
        ShowAuras       = OpenConfigTab("auras"),
        ShowMechanics   = OpenConfigTab("mechanics"),
        ShowRaidRules   = OpenConfigTab("rules"),
        OpenConfigBands = HandleOpenConfigBands,
        OpenRulesSpammer = HandleOpenRulesSpammer,
        OpenLoot = HandleOpenLoot,
        SpamLoot = HandleSpamLoot,
        CollectLoot = HandleCollectLoot,
        OpenSpammerEmpty = HandleOpenSpammerEmpty,
        RegisterPlayer = HandleRegisterPlayer,
        ShowPlayer = HandleShowPlayer,
    }

    local registered = {}

    -- 1) Las acciones desarrolladas se registran SIEMPRE, incluso las que solo
    --    se referencian desde listas dinámicas o desde botones de UI no estáticos.
    for actionId, handler in pairs(developed) do
        self:Register(actionId, handler)
        registered[actionId] = true
    end

    -- 2) Barrido de definiciones: las acciones referenciadas en MENU_DEFINITIONS
    --    que no están desarrolladas se registran como placeholder.
    local definitions = RD.constants and RD.constants.MENU_DEFINITIONS
    if type(definitions) == "table" then
        for _, items in pairs(definitions) do
            if type(items) == "table" then
                for _, item in ipairs(items) do
                    local actionId = item and item.action
                    if actionId and not registered[actionId] then
                        self:Register(actionId, PlaceholderHandler)
                        registered[actionId] = true
                    end
                end
            end
        end
    end
end

-- Registro automático al cargar: el .toc carga este archivo tras la UI,
-- por lo que no hay dependencias pendientes (menuFrame/configWindow ya existen).
MenuActions:RegisterDefaultActions()

RD.MenuActions = MenuActions
return MenuActions
