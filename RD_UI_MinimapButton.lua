--[[
    RD_UI_MinimapButton.lua
PROPÓSITO: Botón de minimapa (versión mejorada, similar al addon base v2).
               Clic izquierdo: alterna el menú flotante. Clic derecho: menú
               contextual (Nombre propio / Jugador / Configuración / Gestor de
               botín / Recoger ítems / Spamear reglas / Spamear banda /
               Recargar UI). "Nombre propio" abre el editor del personaje actual
               en modo "mismo" (con las secciones solo-uno-mismo); "Jugador"
               abre el buscador de jugadores. Los ítems de botín y spam solo
               aparecen cuando están disponibles. Se arrastra alrededor del
               minimapa manteniendo Alt; la posición angular se guarda en config
               (ui.minimap.position). El tooltip (OnEnter) muestra los bloques
               de SEGUIMIENTO (objetos, monedas e instancias) solo cuando hay
               datos — el de instancias respeta el check general de la sección
               Instancias. Sin OnUpdate continuo: solo se activa un OnUpdate
               mientras se arrastra.
    API PÚBLICA:
        - RD.ui.minimapButton:Initialize()
        - RD.ui.minimapButton:Show() / Hide() / Toggle()
    EVENTOS: Se inicializa desde RD_Init en PLAYER_LOGIN.
]]

local addonName, private = ...
local RD = _G.RaidDominion or {}
_G.RaidDominion = RD

local MINIMAP_ICON = "Interface\\Icons\\INV_Misc_SummerFest_BrazierOrange"
local BUTTON_SIZE = 26
local RADIUS = 80
local DEFAULT_POS = (RD.constants and RD.constants.DEFAULT_CONFIG
    and RD.constants.DEFAULT_CONFIG.ui and RD.constants.DEFAULT_CONFIG.ui.minimap
    and RD.constants.DEFAULT_CONFIG.ui.minimap.position) or 0.75

local MinimapButton = {
    button = nil,
    menuFrame = nil,
    isMoving = false,
    isInitialized = false,
}

local function GetPos()
    return (RD.config and RD.config.Get and RD.config:Get("ui.minimap.position", DEFAULT_POS)) or DEFAULT_POS
end

local function SetPos(pos)
    if RD.config and RD.config.Set then
        RD.config:Set("ui.minimap.position", pos)
    end
end

local function UpdatePosition()
    local btn = MinimapButton.button
    if not btn or not Minimap then return end
    local angle = GetPos() * 2 * math.pi
    -- Offsets ENTEROS (sin subpíxeles borrosos/brincando durante el arrastre).
    -- El ancla no cambia (siempre CENTER), así que SetPoint re-posiciona solo.
    btn:SetPoint("CENTER", Minimap, "CENTER",
        math.floor(math.cos(angle) * RADIUS + 0.5),
        math.floor(math.sin(angle) * RADIUS + 0.5))
end

local function ToggleFloatingMenu()
    local mf = RD.ui and RD.ui.menuFrame
    if mf and mf.Toggle then mf:Toggle() end
end

-- "Configuración" del menú contextual: abre SIEMPRE la ventana de configuración
-- en la pestaña General.
local function OpenConfigGeneral()
    local cw = RD.ui and RD.ui.configWindow
    if not cw or not cw.Show then return end
    cw:Show()
    if cw.SelectTabById then
        cw:SelectTabById("general")
    end
end

-- "Nombre propio": abre el editor de jugador sobre el personaje actual. Se pasa
-- playerName para que el editor resuelva la banda donde figure (o abra en modo
-- "sin banda") y calcule isSelf=true, habilitando las secciones solo-uno-mismo
-- (Equipamiento, Instancias, Monedas).
local function OpenSelfPlayer()
    local pe = RD.ui and RD.ui.playerEditor
    if not pe or not pe.OpenPlayerEditor then return end
    local name
    if UnitName then name = UnitName("player") end
    if name and name ~= "" then
        pcall(pe.OpenPlayerEditor, pe, { playerName = name })
    end
end

-- "Jugador": abre (o cierra) la ventana buscador de jugadores, igual que el
-- clic derecho del botón "Jugador" de la barra inferior (HandlePlayerFinder ->
-- playerWindow:Toggle).
local function OpenPlayerFinder()
    local pw = RD.ui and RD.ui.playerWindow
    if pw and pw.Toggle then
        pcall(pw.Toggle, pw)
    end
end

-- Arrastre: sigue el cursor alrededor del minimapa. Solo activo durante el
-- arrastre (se limpia el OnUpdate al soltar o si se suelta Alt).
local function DragUpdate(self)
    if not MinimapButton.isMoving then
        self:SetScript("OnUpdate", nil)
        return
    end
    if not IsAltKeyDown() then
        MinimapButton.isMoving = false
        self:SetScript("OnUpdate", nil)
        return
    end
    local mx, my = Minimap:GetCenter()
    local px, py = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    local angle = math.atan2(py / scale - my, px / scale - mx)
    local pos = (angle % (2 * math.pi)) / (2 * math.pi)
    SetPos(pos)
    UpdatePosition()
end

local function StartDrag(self)
    MinimapButton.isMoving = true
    self:SetScript("OnUpdate", DragUpdate)
end

local function StopDrag(self)
    MinimapButton.isMoving = false
    self:SetScript("OnUpdate", nil)
end

-- Menú contextual derecho (clic derecho). El frame se reutiliza (sin acumular
-- huérfanos) pero EasyMenu debe llamarse en CADA clic para re-mostrar el menú:
-- devolver el frame sin llamarlo era la causa de que solo apareciera una vez.
local function OpenContextMenu()
    if not MinimapButton.menuFrame then
        MinimapButton.menuFrame = CreateFrame("Frame", "RaidDominionMinimapMenu", UIParent, "UIDropDownMenuTemplate")
    end
    local items = {}

    -- Nombre del personaje propio: abre el editor en modo "mismo". Se lee en
    -- cada apertura del menú (así sigue correcto al cambiar de personaje) y se
    -- omite si no hay nombre o el editor no está cargado.
    local selfName
    if UnitName then selfName = UnitName("player") end
    local pe = RD.ui and RD.ui.playerEditor
    if selfName and selfName ~= "" and pe and pe.OpenPlayerEditor then
        items[#items + 1] = { text = selfName, func = function()
            OpenSelfPlayer()
        end }
    end
    -- "Jugador": buscador de jugadores de las listas/bandas.
    local pw = RD.ui and RD.ui.playerWindow
    if pw and pw.Toggle then
        items[#items + 1] = { text = "Jugador", func = function()
            OpenPlayerFinder()
        end }
    end
    items[#items + 1] = { text = "Configuración", func = function()
        OpenConfigGeneral()
    end }

    -- Acciones de botín y spammers: se añaden solo cuando están disponibles
    -- (cada una guarda por la existencia de su módulo/ventana; "Spamear banda"
    -- además exige al menos una banda registrada). Así el menú nunca muestra
    -- ítems inutilizables y conserva al menos un elemento de acción.
    local lootWin = RD.ui and RD.ui.lootWindow
    if lootWin and lootWin.Open then
        items[#items + 1] = { text = "Gestor de botín", func = function()
            pcall(lootWin.Open, lootWin)
        end }
    end
    local loot = RD.modules and RD.modules.loot
    if loot and loot.CollectItems then
        items[#items + 1] = { text = "Recoger ítems", func = function()
            loot:CollectItems()
        end }
    end
    local rulesWin = RD.ui and RD.ui.rulesSpammerWindow
    if rulesWin and rulesWin.Open then
        items[#items + 1] = { text = "Spamear reglas", func = function()
            rulesWin:Open()
        end }
    end
    local hasBand = false
    local bands = RD.utils and RD.utils.bands
    if bands and bands.GetBands then
        for _, b in ipairs(bands:GetBands() or {}) do
            hasBand = true
            break
        end
    end
    local spammerWin = RD.ui and RD.ui.spammerWindow
    if hasBand and spammerWin and spammerWin.OpenEmpty then
        items[#items + 1] = { text = "Spamear banda", func = function()
            spammerWin:OpenEmpty()
        end }
    end

    -- "Recargar UI" es la última opción accionable; el gesto de mover el botón
    -- ya se documenta en el tooltip (Alt+arrastrar), no como ítem de menú.
    items[#items + 1] = { text = "Recargar UI", func = function()
        ReloadUI()
    end }
    EasyMenu(items, MinimapButton.menuFrame, "cursor", 0, 0, "MENU", 1)
end

local function OnMouseDown(self, button)
    if button == "LeftButton" then
        if IsAltKeyDown() then
            StartDrag(self)
        else
            ToggleFloatingMenu()
        end
    elseif button == "RightButton" then
            OpenContextMenu()
    end
end

local function OnEnter(self)
    if not (RD.UIUtils and RD.UIUtils.TooltipsEnabled and RD.UIUtils.TooltipsEnabled()) then
        GameTooltip:Hide()
        return
    end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("|cfff58cbaRaidDominion|r")

    -- Bloques de SEGUIMIENTO (paridad con el tooltip del botón "Jugador" de la
    -- barra inferior, pero SIN avisos de descubrimiento: cada bloque solo
    -- aparece si tiene datos). Orden: objetos → monedas → instancias. El bloque
    -- de instancias lo decide el propio módulo (check general de la sección
    -- Instancias): TooltipLines devuelve nil cuando el check está apagado.
    local first = true
    local function AddBlock(title, lines, maxLines)
        if type(lines) ~= "table" or #lines == 0 then return end
        if not first then
            GameTooltip:AddLine(" ", 1, 1, 1, true)
        end
        first = false
        GameTooltip:AddLine(title, 1, 0.82, 0, true)
        local shown = 0
        for _, line in ipairs(lines) do
            if maxLines and shown >= maxLines then
                local hidden = #lines - shown
                GameTooltip:AddLine("  " .. ((RD.UIUtils and RD.UIUtils.TruncHint and RD.UIUtils.TruncHint(hidden))
                    or ("… y " .. hidden .. " más")), 0.6, 0.6, 0.6, true)
                break
            end
            if type(line) == "table" then
                GameTooltip:AddLine("  " .. tostring(line.text or ""), line.r or 1, line.g or 1, line.b or 1, true)
            else
                GameTooltip:AddLine("  " .. tostring(line), 0.85, 0.85, 0.9, true)
            end
            shown = shown + 1
        end
    end

    local goals = RD.utils and RD.utils.itemGoals
    if goals and goals.TrackedItemLines then
        AddBlock("Seguimiento de objetos:", goals:TrackedItemLines(), 10)
    end
    if goals and goals.TrackedCurrencyLines then
        AddBlock("Seguimiento de monedas:", goals:TrackedCurrencyLines(), 10)
    end
    local instances = RD.ui and RD.ui.playerEditorSectionsInstances
    if instances and instances.TooltipLines then
        AddBlock("Seguimiento de instancias:", instances:TooltipLines(), 12)
    end

    GameTooltip:AddLine("|cff00ff00Clic:|r Abrir/cerrar el menú flotante", 1, 1, 1, true)
    GameTooltip:AddLine("|cff00ff00Clic derecho:|r Menú contextual", 1, 1, 1, true)
    GameTooltip:AddLine("|cff00ff00Alt+arrastrar:|r Mover el botón", 1, 1, 1, true)
    GameTooltip:Show()
end

local function OnLeave()
    GameTooltip:Hide()
end

function MinimapButton:Initialize()
    if self.isInitialized or not Minimap then return end

    local button = CreateFrame("Button", "RaidDominionMinimapButton", Minimap)
    button:SetSize(BUTTON_SIZE, BUTTON_SIZE)
    -- Sin SetClampedToScreen: en un hijo de Minimap el clamp pelea con el
    -- posicionado angular (en cada frame de arrastre) y puede dejar el botón
    -- desplazado/no clicable. El radio 80 mantiene el botón dentro de la
    -- pantalla. Sin SetFrameStrata: un hijo no puede superar la strata de su
    -- padre (Minimap), así que se hereda.
    button:SetFrameLevel(8)
    button:SetMovable(true)
    button:SetDontSavePosition(true)

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    icon:SetTexture(MINIMAP_ICON)
    button:SetNormalTexture(icon)

    local highlight = button:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    highlight:SetBlendMode("ADD")
    highlight:SetAllPoints()
    button:SetHighlightTexture(highlight)

    local pushed = button:CreateTexture(nil, "OVERLAY")
    pushed:SetTexture(MINIMAP_ICON)
    pushed:SetAllPoints()
    pushed:SetAlpha(0.7)
    button:SetPushedTexture(pushed)

    button:SetScript("OnMouseDown", OnMouseDown)
    button:SetScript("OnMouseUp", function(self) StopDrag(self) end)
    button:SetScript("OnEnter", OnEnter)
    button:SetScript("OnLeave", OnLeave)

    self.button = button
    UpdatePosition()
    self.isInitialized = true
end

function MinimapButton:Show()
    if self.button then self.button:Show() end
end

function MinimapButton:Hide()
    if self.button then self.button:Hide() end
end

function MinimapButton:Toggle()
    if not self.button then self:Initialize() end
    if not self.button then return end
    if self.button:IsShown() then
        self:Hide()
    else
        self:Show()
    end
end

RD.ui = RD.ui or {}
RD.ui.minimapButton = MinimapButton

-- Slash command: /rdminimap
SLASH_RDMINIMAP1 = "/rdminimap"
SlashCmdList["RDMINIMAP"] = function()
    MinimapButton:Toggle()
end

return MinimapButton
