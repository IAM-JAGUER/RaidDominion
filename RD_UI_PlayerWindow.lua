--[[
    RD_UI_PlayerWindow.lua
    PROPÓSITO: Ventana "Jugador" del addon (buscador). Se abre con el clic
              DERECHO del botón "Jugador" de la barra inferior (menú flotante y
              barra de la configuración; ActionBarPlayerFinder) y desde el menú
              contextual del botón de minimapa.
              Ventana de búsqueda: un campo "Nombre del jugador" con
              autocompletado sobre el pool de RD.utils.players (jugadores de las
              listas asignables, miembros de bandas y uno mismo). Al dar un
              nombre (Enter) se ABRE la ventana de edición de jugador
              (RD.ui.playerEditor, acordeón Información/Equipamiento/Bandas/
              Instancias/Monedas), que además permite añadirlo a otras bandas.
              El botón inferior con el nombre del personaje propio abre el
              editor con ese jugador.
              El frame se crea UNA vez (singleton lazy) y se reutiliza.
              Registra RD.ui.playerWindow.
    API PÚBLICA:
        - RD.ui.playerWindow:Toggle()   -- abrir (vista buscar) o cerrar
        - RD.ui.playerWindow:Open()     -- abrir en vista buscar
        - RD.ui.playerWindow:Close()    -- cerrar
    EVENTOS: Ninguno (solo lectura de RD.utils.* y RD.config).
]]

local addonName, private = ...
local RD = _G.RaidDominion or {}
_G.RaidDominion = RD

local PlayerWindow = {}

local window = nil

local UniqueName = (RD.UIUtils and RD.UIUtils.UniqueName) or function() return nil end
local Log = (RD.UIUtils and RD.UIUtils.Log) or function(msg) print(msg) end

-- Mensaje de sistema (helper central del addon)
local function Msg(text)
    if RD.messageManager and RD.messageManager.SendSystemMessage then
        RD.messageManager:SendSystemMessage(text)
    else
        Log(text)
    end
end

-- ============================================================================
-- Construcción (una sola vez)
-- ============================================================================

local function BuildWindow()
    window = CreateFrame("Frame", "RaidDominionPlayerWindow", UIParent)
    if RD.UIUtils and RD.UIUtils.SetupWindow then
        RD.UIUtils.SetupWindow(window)
    else
        window:SetFrameStrata("MEDIUM")
        window:SetToplevel(true)
        window:SetClampedToScreen(true)
    end
    window:SetSize(360, 190)
    window:EnableMouse(true)
    window:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    window:SetBackdropColor(0, 0, 0, 0.95)
    window:SetBackdropBorderColor(1, 1, 1, 0.5)
    table.insert(UISpecialFrames, "RaidDominionPlayerWindow")
    if RD.UIUtils and RD.UIUtils.TrackScale then RD.UIUtils.TrackScale(window) end

    window:SetMovable(true)
    window:RegisterForDrag("LeftButton")
    window:SetScript("OnDragStart", function() window:StartMoving() end)
    window:SetScript("OnDragStop", function() window:StopMovingOrSizing() end)

    local title = window:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOP", window, "TOP", 0, -10)
    title:SetText("Jugador")
    RD.UIUtils.ScaleFont(title, 1.5)
    window.title = title

    local closeBtn = CreateFrame("Button", UniqueName("PwCl"), window, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", window, "TOPRIGHT", -4, -4)
    closeBtn:SetScript("OnClick", function() window:Hide() end)

    local innerW = (window:GetWidth() or 360) - 32

    local nameLabel = window:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    nameLabel:SetText("Nombre del jugador:")
    nameLabel:SetJustifyH("LEFT")
    nameLabel:SetPoint("TOPLEFT", window, "TOPLEFT", 16, -40)
    RD.UIUtils.ScaleFont(nameLabel, 1.25)

    local nameBox = CreateFrame("EditBox", UniqueName("PwNm"), window, "InputBoxTemplate")
    nameBox:SetSize(innerW, 24)
    nameBox:SetPoint("TOPLEFT", window, "TOPLEFT", 16, -58)
    nameBox:SetAutoFocus(false)
    RD.UIUtils.StyleInput(nameBox)
    window.nameBox = nameBox

    -- Autocompletado (patrón de la v2): al teclear con el cursor al final se
    -- busca en el pool de jugadores (listas asignables + bandas + uno mismo) un
    -- nombre que empiece por lo escrito y se completa con el resto resaltado.
    nameBox:SetScript("OnChar", function(self, char)
        local text = self:GetText()
        local textLen = text and text:len() or 0
        local cursor = self:GetCursorPosition()
        if cursor ~= textLen then return end
        local pool = RD.utils and RD.utils.players and RD.utils.players:GetSearchPool()
        if not pool then return end
        local searchText = text:lower()
        for _, entry in ipairs(pool) do
            local candidate = entry.name
            local candLower = candidate:lower()
            if candLower:find("^" .. searchText, 1) and candidate:len() > textLen then
                self:Insert(candidate:sub(textLen + 1))
                self:HighlightText(textLen, candidate:len())
                self:SetCursorPosition(textLen)
                break
            end
        end
    end)
    nameBox:SetScript("OnEnterPressed", function() PlayerWindow:OpenEditorFromBox() end)
    nameBox:SetScript("OnEscapePressed", function() window:Hide() end)

    local hint = window:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hint:SetText("Autocompleta con los jugadores de tus listas (asignaciones y bandas) y tú mismo. Enter abre la edición del jugador.")
    hint:SetJustifyH("LEFT")
    hint:SetTextColor(0.7, 0.7, 0.7)
    hint:SetWidth(innerW)
    hint:SetPoint("TOPLEFT", window, "TOPLEFT", 16, -90)
    window.hint = hint

    local selfBtn = RD.UIUtils.MakeChipButton(window, UniqueName("PwYo"), 120, 24)
    selfBtn:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -16, 12)
    local selfBtnName
    if UnitName then selfBtnName = UnitName("player") end
    selfBtn:SetText(selfBtnName or "Personaje")
    selfBtn:SetScript("OnClick", function()
        local name
        if UnitName then name = UnitName("player") end
        if name then
            PlayerWindow:OpenEditor(name)
        end
    end)
    window.selfBtn = selfBtn

    return window
end

-- ============================================================================
-- Apertura / edición
-- ============================================================================

-- Abre el editor con el nombre escrito (o avisa si está vacío)
function PlayerWindow:OpenEditorFromBox()
    local name = strtrim(window and window.nameBox and window.nameBox:GetText() or "")
    if name == "" then
        Msg("|cffff8000[RaidDominion]|r Escribe el nombre de un jugador.")
        return
    end
    self:OpenEditor(name)
end

-- Abre la ventana de edición de jugador (acordeón Información/Equipamiento/
-- Bandas/Instancias/Monedas). El editor resuelve la banda donde figura el
-- jugador o, si no está en ninguna, se abre en modo "sin banda" para poder
-- añadirlo desde la sección Bandas.
function PlayerWindow:OpenEditor(name)
    local editor = RD.ui and RD.ui.playerEditor
    if not editor or not editor.OpenPlayerEditor then
        Msg("|cffff0000[RaidDominion]|r El editor de jugador no está disponible.")
        return
    end
    editor:OpenPlayerEditor({
        playerName = name,
    })
    if window then window:Hide() end
end

-- ============================================================================
-- Apertura / cierre de la ventana de búsqueda
-- ============================================================================

-- Toggle: si está visible se cierra; si no, abre en vista buscar
function PlayerWindow:Toggle()
    if window and window:IsShown() then
        self:Close()
        return
    end
    self:Open()
end

function PlayerWindow:Open()
    if not window then
        local ok, err = pcall(BuildWindow)
        if not ok then
            window = nil
            Log("|cffff0000[RaidDominion]|r Error al abrir la ventana Jugador: " .. tostring(err))
            return
        end
    end
    if not window then return end
    -- Posición inicial centrada (la primera vez); luego conserva la arrastrada
    if not window.positioned then
        window:ClearAllPoints()
        window:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        window.positioned = true
    end
    if window.nameBox then
        window.nameBox:SetText("")
        window.nameBox:SetFocus()
    end
    if RD.UIUtils and RD.UIUtils.ActivateWindow then
        RD.UIUtils.ActivateWindow(window)
    else
        window:Show()
        window:Raise()
    end
end

function PlayerWindow:Close()
    if window then window:Hide() end
end

RD.ui = RD.ui or {}
RD.ui.playerWindow = PlayerWindow
return PlayerWindow