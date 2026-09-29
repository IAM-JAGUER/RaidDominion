--[[
    RD_UI_LootWindow.lua
    PROPÓSITO: Ventana modal del gestor de botín (estilo KRT). Muestra el ítem
              actual (del botín del boss o arrastrado de la bolsa), botones de
              dados por main/dual/enchant, la lista de dados de la banda con el
              ganador destacado (contenida en un área con scroll y clicable:
              Clic = elegir ganador, Ctrl-Clic = anunciar el dado), countdown
              del tiempo límite, y acciones: declarar ganador y limpiar. El
              spameo de botín y la recogida de ítems hacia el maestro viven en
              el submenú Reglas del menú flotante. Se abre desde la barra de
              botones de la ventana de banda. Registra RD.ui.lootWindow.
    API PÚBLICA:
        - RD.ui.lootWindow:Open() / Close() / Toggle()
        - RD.ui.lootWindow:Refresh()
    EVENTOS: LOOT_ITEM_ADDED, LOOT_ROLL_ADDED, LOOT_ROLL_CLEARED, LOOT_WINNER_SET,
             LOOT_STATE_CHANGED (refrescan la ventana si está visible).
]]

local addonName, private = ...
local RD = _G.RaidDominion or {}
_G.RaidDominion = RD

local Win = {
    frame = nil,
    isShown = false,
}

local GOLD = (RD.constants and RD.constants.COLORS and RD.constants.COLORS.GOLD) or { 1, 0.82, 0 }
local GOLD_R, GOLD_G, GOLD_B = GOLD[1], GOLD[2], GOLD[3]
local UniqueName = RD.UIUtils and RD.UIUtils.UniqueName
local Log = (RD.UIUtils and RD.UIUtils.Log) or function(msg) print(msg) end

local PAD, G = 12, 8
-- WIN_H acotado al contenido real (352 = 44 * 8): el último elemento (la fila
-- de acciones "Declarar ganador" / "Limpiar") termina en y=-340 y el padding
-- inferior queda en PAD=12. El spameo de botín y la recogida de ítems viven en
-- el submenú Reglas del menú flotante, no en esta ventana.
local WIN_W, WIN_H = 420, 352
local INNER = WIN_W - PAD * 2

-- Tipos de roll
local ROLL_MAIN = 1
local ROLL_DUAL = 2
local ROLL_ENCHANT = 3

local function MakeLabel(parent, text, x, y)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetText(text)
    fs:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    fs:SetTextColor(0.8, 0.8, 0.8)
    return fs
end

function Win:Create()
    if self.frame then return self.frame end

    local frame = CreateFrame("Frame", "RaidDominionLoot", UIParent)
    -- Strata MEDIUM (paridad con los paneles de personaje de WoW): la ventana
    -- se cubre/descubre con la UI del juego y pasa al frente al activarla.
    if RD.UIUtils and RD.UIUtils.SetupWindow then
        RD.UIUtils.SetupWindow(frame)
    else
        frame:SetFrameStrata("MEDIUM")
        frame:SetToplevel(true)
        frame:SetClampedToScreen(true)
    end
    frame:SetSize(WIN_W, WIN_H)
    -- Posición inicial centrada en la pantalla (los modales del addon se anclan
    -- a UIParent; sin SetPoint el frame podría quedar en una posición no visible).
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function() frame:StartMoving() end)
    frame:SetScript("OnDragStop", function() frame:StopMovingOrSizing() end)
    frame:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    frame:SetBackdropColor(0, 0, 0, 0.95)
    frame:SetBackdropBorderColor(1, 1, 1, 0.5)
    table.insert(UISpecialFrames, "RaidDominionLoot")
    if RD.UIUtils and RD.UIUtils.TrackScale then RD.UIUtils.TrackScale(frame) end

    -- Título fijo "Gestor de botín" en ambas vistas; la variación entre pestañas
    -- se expresa con las pestañas "Dados" y "Historial" a la derecha del título.
    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetText("Gestor de botín")
    title:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -12)
    title:SetTextColor(GOLD_R, GOLD_G, GOLD_B)
    RD.UIUtils.ScaleFont(title, 1.25)
    self.title = title

    -- Pestañas de vista "Dados" / "Historial" (estilo chip del addon, como las
    -- pestañas de canales de los spammers). La activa se resalta en dorado.
    local MakeChipButton = (RD.UIUtils and RD.UIUtils.MakeChipButton) or function() return nil end
    local TAB_H = 20
    local viewTabs = {
        { key = "loot", label = "Dados" },
        { key = "history", label = "Historial" },
    }
    self.viewTabButtons = {}
    local prev = title
    for _, t in ipairs(viewTabs) do
        local btn = MakeChipButton(frame, UniqueName("Lt"), 80, TAB_H)
        btn:SetPoint("LEFT", prev, "RIGHT", G, 0)
        btn.rdText:SetText(t.label)
        btn.rdView = t.key
        btn:SetScript("OnClick", function() self:SetView(t.key) end)
        self.viewTabButtons[t.key] = btn
        prev = btn
    end

    local closeBtn = CreateFrame("Button", UniqueName("Lc"), frame, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4)
    closeBtn:SetScript("OnClick", function() self:Close() end)

    -- Contenedores de las dos vistas (ambos cubren todo el frame).
    local mainView = CreateFrame("Frame", UniqueName("LMain"), frame)
    mainView:SetAllPoints()
    self.mainView = mainView
    local historyView = CreateFrame("Frame", UniqueName("LHist"), frame)
    historyView:SetAllPoints()
    historyView:Hide()
    self.historyView = historyView
    self.view = "loot"

    -- ==================== Vista: Gestor de botín ====================
    -- Ítem actual: icono + nombre + contador
    local itemBtn = CreateFrame("Button", UniqueName("LIt"), mainView)
    itemBtn:SetSize(44, 44)
    itemBtn:SetPoint("TOPLEFT", mainView, "TOPLEFT", PAD, -36)
    itemBtn:SetNormalTexture("Interface\\PaperDoll\\UI-Backpack-EmptySlot")
    itemBtn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    self.itemBtn = itemBtn

    -- Acepta el arrastre de un ítem de la bolsa. GetCursorInfo() en 3.3.5a
    -- devuelve type, id, info (para ítems: "item", itemID, itemLink), así que el
    -- link es el 3er valor.
    itemBtn:RegisterForClicks("AnyUp")
    itemBtn:SetScript("OnReceiveDrag", function()
        local cursorType, _, itemLink = GetCursorInfo()
        if cursorType == "item" and itemLink then
            local loot = RD.modules and RD.modules.loot
            if loot and loot.SetItem then
                loot:SetItem(itemLink)
                ClearCursor()
                self:Refresh()
            end
        end
    end)
    -- Además del drag & drop, soporta tomar/soltar por CLIC:
    --  - Clic con un ítem en el cursor → toma ese ítem como el actual del gestor.
    --  - Clic con el cursor vacío y un ítem en el gestor → lo pone en el cursor
    --    (PickupItem) para arrastrarlo de vuelta a la bolsa o a otro sitio.
    itemBtn:SetScript("OnClick", function()
        local cursorType = GetCursorInfo()
        local loot = RD.modules and RD.modules.loot
        if not loot then return end
        if cursorType == "item" then
            local _, _, itemLink = GetCursorInfo()
            if itemLink and loot.SetItem then
                loot:SetItem(itemLink)
                ClearCursor()
                self:Refresh()
            end
        elseif loot.GetState and loot.GetState().itemLink then
            PickupItem(loot.GetState().itemLink)
        end
    end)
    if RD.UIUtils and RD.UIUtils.AddButtonTooltip then
        RD.UIUtils.AddButtonTooltip(itemBtn, function()
            return "Arrastra un ítem de la bolsa aquí, o haz clic con uno en el cursor para tomarlo.\nClic con el cursor vacío: lo sueltas al cursor."
        end)
    end
    self.itemNameText = mainView:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    self.itemNameText:SetPoint("LEFT", itemBtn, "RIGHT", 8, 0)
    self.itemNameText:SetPoint("RIGHT", mainView, "RIGHT", -PAD, 0)
    self.itemNameText:SetJustifyH("LEFT")
    self.itemNameText:SetText("Arrastra un ítem de la bolsa aquí")
    self.itemNameText:SetTextColor(0.8, 0.8, 0.8)

    self.countText = mainView:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    self.countText:SetPoint("BOTTOMRIGHT", itemBtn, "BOTTOMRIGHT", -4, 4)
    self.countText:SetText("")

    -- Botones de dados por tipo
    MakeLabel(mainView, "Dados:", PAD, -92)
    -- Ancho de botón redondeado a múltiplo de 4 (grid AGENTS §6): mayor múltiplo
    -- de 4 ≤ (INNER - 2G)/3. 3*124 + 2*8 = 388 ≤ INNER 396.
    local btnW = math.floor((INNER - G * 2) / 12) * 4
    local rollDefs = {
        { type = ROLL_MAIN, label = "Main" },
        { type = ROLL_DUAL, label = "Dual" },
        { type = ROLL_ENCHANT, label = "Enchant" },
    }
    self.rollBtns = {}
    for i, r in ipairs(rollDefs) do
        local btn = RD.UIUtils.MakeChipButton(mainView, UniqueName("LR"), btnW, 24)
        btn:SetPoint("TOPLEFT", mainView, "TOPLEFT", PAD + (i - 1) * (btnW + G), -108)
        btn:SetText(r.label)
        btn:SetScript("OnClick", function()
            local loot = RD.modules and RD.modules.loot
            if loot and loot.StartRoll then
                self:ApplyTimeLimit()
                loot:StartRoll(r.type)
                self:Refresh()
            end
        end)
        self.rollBtns[i] = btn
    end

    -- Estado de los dados: muestra de forma clara si hay una cuenta atrás
    -- abierta (con tipo de dados y tiempo restante), si se cerró tras abrir
    -- dados, o si simplemente no hay dados abiertos. Se actualiza en cada tick
    -- para que la cuenta atrás sea visible en todo momento.
    self.statusText = mainView:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    self.statusText:SetPoint("TOPRIGHT", mainView, "TOPRIGHT", -PAD, -92)
    self.statusText:SetText("Dados cerrados")
    self.statusText:SetTextColor(0.8, 0.8, 0.8)
    self.statusText:SetWordWrap(false)

    -- Campo para fijar el límite de tiempo (segundos) de los dados. Se guarda
    -- en la config compartida loot.rollTimeLimit y se usa al iniciar los dados.
    -- ANCLA CORRECTA: el campo y su etiqueta van en la fila y=-140, alineados a
    -- la derecha junto a "Tirar dados". Antes se anclaban a `frame, "RIGHT"`
    -- (el punto "RIGHT" es el CENTRO vertical del frame), así que con -140
    -- caían ~332px abajo y quedaban tapados por la fila de acciones.
    self.timeLabel = mainView:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    self.timeLabel:SetText("Límite (s):")
    self.timeLabel:SetTextColor(0.8, 0.8, 0.8)

    self.timeEdit = CreateFrame("EditBox", UniqueName("LTm"), mainView, "InputBoxTemplate")
    self.timeEdit:SetSize(48, 20)
    self.timeEdit:SetPoint("TOPRIGHT", mainView, "TOPRIGHT", -PAD, -140)
    self.timeEdit:SetAutoFocus(false)
    self.timeEdit:SetNumeric(true)
    self.timeEdit:SetMaxLetters(2)
    if RD.UIUtils and RD.UIUtils.DisableLinkInsertion then
        RD.UIUtils.DisableLinkInsertion(self.timeEdit)
    end
    -- Enter/Escape liberan el foco (estilo KRT): commitean el límite y sueltan
    -- el foco para poder usar los atajos del teclado. El Escape cierra la
    -- ventana en un segundo toque vía UISpecialFrames (ya en RaidDominionLoot).
    self.timeEdit:SetScript("OnEnterPressed", function() self:ApplyTimeLimit() end)
    self.timeEdit:SetScript("OnEscapePressed", function() self:ApplyTimeLimit() end)
    -- Etiqueta a la izquierda del campo, centrada verticalmente contra él
    -- (anclas "RIGHT"/"LEFT" entre ambos, no contra el frame).
    self.timeLabel:SetPoint("RIGHT", self.timeEdit, "LEFT", -G, 0)

    -- Botón para que el jugador tire sus propios dados
    self.rollBtn = RD.UIUtils.MakeChipButton(mainView, UniqueName("LMy"), 120, 24)
    self.rollBtn:SetPoint("TOPLEFT", mainView, "TOPLEFT", PAD, -140)
    self.rollBtn:SetText("Tirar dados")
    self.rollBtn:SetScript("OnClick", function()
        local loot = RD.modules and RD.modules.loot
        if loot and loot.Roll then loot:Roll() end
        self:Refresh()
    end)

    -- Lista de dados de la banda (con ganador destacado), contenida en un área
    -- con scroll reutilizando el helper del repo (CreateScrollFrame): el texto
    -- crece hacia abajo sin límite y el ScrollFrame lo recorta. La barra queda
    -- a la derecha del contenido, dentro del INNER (ancho INNER - 26, patrón de
    -- los demás listados del repo), y solo aparece si el contenido no cabe.
    MakeLabel(mainView, "Dados de la banda:", PAD, -176)
    -- Ancho del scroll a múltiplo de 4 (368 = INNER - 28): la barra del helper
    -- queda a la derecha del contenido, dentro del INNER.
    local scrollW = INNER - 28
    local scrollH = 96
    self.rollsScroll, self.rollsChild = RD.ui.widgets.CreateScrollFrame(mainView, scrollW, scrollH, PAD, -196)
    -- Lista de dados clicable (estilo KRT): cada dado es una fila-botón.
    -- Clic = elegir ese jugador como ganador; Ctrl-Clic = anunciar su dado por
    -- la salida por defecto. El ganador se resalta en dorado con ★.
    self.rollsEmptyText = self.rollsChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    self.rollsEmptyText:SetPoint("TOPLEFT", self.rollsChild, "TOPLEFT", 0, 0)
    self.rollsEmptyText:SetText("(sin dados todavía)")
    self.rollsEmptyText:SetTextColor(0.7, 0.7, 0.7)
    self.rollRows = {}
    self.rollsChild:SetHeight(scrollH)
    if self.rollsScroll.SetVerticalScroll then
        self.rollsScroll:SetVerticalScroll(0)
    end

    -- Acciones: "Declarar ganador" (anuncia ganador + ítem por la salida por
    -- defecto), "Desempatar" (ronda de desempate si hay empate en el máximo) y
    -- "Limpiar". El spameo de botín y la recogida de ítems hacia el maestro
    -- viven en el submenú Reglas del menú flotante (acciones SpamLoot y
    -- CollectLoot), no en esta ventana.
    MakeLabel(mainView, "Acciones:", PAD, -300)
    -- Tres botones por fila: 3*w + 2*G <= INNER (124*3 + 8*2 = 388 <= 396).
    local actBtnW = math.floor((INNER - G * 2) / 12) * 4

    self.winnerBtn = RD.UIUtils.MakeChipButton(mainView, UniqueName("LW"), actBtnW, 24)
    self.winnerBtn:SetPoint("TOPLEFT", mainView, "TOPLEFT", PAD, -316)
    self.winnerBtn:SetText("Declarar ganador")
    self.winnerBtn:SetScript("OnClick", function()
        local loot = RD.modules and RD.modules.loot
        if loot and loot.AnnounceWinner then
            if loot:AnnounceWinner() then
                Log("|cff33ff99[RaidDominion]|r Ganador declarado.")
            else
                Log("|cffff0000[RaidDominion]|r No hay ítem o ganador para declarar.")
            end
        end
        self:Refresh()
    end)

    self.duelBtn = RD.UIUtils.MakeChipButton(mainView, UniqueName("LD"), actBtnW, 24)
    self.duelBtn:SetPoint("TOPLEFT", mainView, "TOPLEFT", PAD + (actBtnW + G), -316)
    self.duelBtn:SetText("Desempatar")
    self.duelBtn:SetScript("OnClick", function()
        local loot = RD.modules and RD.modules.loot
        if loot and loot.StartDuel then
            if loot:StartDuel() then
                Log("|cff33ff99[RaidDominion]|r Desempate iniciado: solo tiran los empatados.")
            else
                Log("|cffff0000[RaidDominion]|r No hay empate que desempatar.")
            end
        end
        self:Refresh()
    end)

    self.clearBtn = RD.UIUtils.MakeChipButton(mainView, UniqueName("LCl"), actBtnW, 24)
    self.clearBtn:SetPoint("TOPLEFT", mainView, "TOPLEFT", PAD + 2 * (actBtnW + G), -316)
    self.clearBtn:SetText("Limpiar")
    self.clearBtn:SetScript("OnClick", function()
        local loot = RD.modules and RD.modules.loot
        if loot and loot.Clear then loot:Clear() end
        self:Refresh()
    end)

    -- ==================== Vista: Historial ====================
    -- Registro por día de dados e ítems entregados (y a quién). La construcción
    -- y los métodos viven en RD_UI_LootWindow_History.lua.
    self:BuildHistoryView(historyView)

    -- Suscripción a cambios del loot
    if RD.events and RD.events.Subscribe then
        local function OnChange()
            if self.isShown and self.frame then
                self:Refresh()
            end
        end
        RD.events:Subscribe("LOOT_ITEM_ADDED", OnChange)
        RD.events:Subscribe("LOOT_ROLL_ADDED", OnChange)
        RD.events:Subscribe("LOOT_ROLL_CLEARED", OnChange)
        RD.events:Subscribe("LOOT_WINNER_SET", OnChange)
        RD.events:Subscribe("LOOT_STATE_CHANGED", OnChange)
        RD.events:Subscribe("LOOT_HISTORY_ADDED", OnChange)
        self._handlers = { OnChange }
    end

    -- Frame OnUpdate para el countdown. Solo se muestra mientras el countdown
    -- está activo (evita OnUpdate continuo sin trabajo, AGENTS §6.3): la
    -- actualización se refresca vía eventos cuando hay un roll nuevo.
    local updateFrame = CreateFrame("Frame")
    updateFrame:SetScript("OnUpdate", function()
        if not Win.isShown or not Win.frame then updateFrame:Hide() return end
        local loot = RD.modules and RD.modules.loot
        local st = loot and loot.GetState and loot:GetState()
        if not st or not st.countdownActive then
            updateFrame:Hide()
            Win:RefreshCountdown()
            return
        end
        Win:RefreshCountdown()
    end)
    updateFrame:Hide()
    self.updateFrame = updateFrame

    -- Se asigna al final: si cualquier paso anterior falla (pcall en Open/RD_Init),
    -- self.frame queda en nil y el siguiente intento reconstruye el frame limpio
    -- en lugar de quedarse con un frame parcial e invisible.
    self.frame = frame

    return frame
end

-- Refresca el texto de estado de los dados (cuenta atrás abierta/cerrada).
-- La cuenta atrás activa es el único caso que necesita actualización continua;
-- el resto de estados se refrescan por eventos.
function Win:RefreshCountdown()
    local loot = RD.modules and RD.modules.loot
    local st = loot and loot.GetState and loot:GetState()
    if not st then return end
    if not self.statusText then return end
    if st.countdownActive and st.countdown > 0 then
        local secs = math.ceil(st.countdown)
        if st.duel then
            self.statusText:SetText(string.format("|cff33ff99Desempate (%s)|r — %ds", table.concat(st.duelPlayers or {}, ", "), secs))
        else
            local typeText = ({ [1] = "Main", [2] = "Dual", [3] = "Enchant" })[st.rollType] or "Main"
            self.statusText:SetText(string.format("|cff33ff99Dados abiertos (%s)|r — %ds", typeText, secs))
        end
        if secs <= 3 then
            self.statusText:SetTextColor(1, 0.3, 0.3)
        else
            self.statusText:SetTextColor(GOLD_R, GOLD_G, GOLD_B)
        end
        if self.updateFrame and not self.updateFrame:IsShown() then
            self.updateFrame:Show()
        end
    else
        if st.duel then
            self.statusText:SetText("|cffffd700Desempate abierto|r — esperando tiros de los empatados")
            self.statusText:SetTextColor(GOLD_R, GOLD_G, GOLD_B)
        elseif #st.rolls > 0 then
            self.statusText:SetText("|cffffd700Dados cerrados|r — tiempo agotado")
            self.statusText:SetTextColor(0.9, 0.7, 0.2)
        else
            self.statusText:SetText("Dados cerrados")
            self.statusText:SetTextColor(0.8, 0.8, 0.8)
        end
    end
end

-- Lee el campo de límite de tiempo (si tiene un valor válido) y lo guarda en la
-- config compartida loot.rollTimeLimit para que StartRoll lo use. El límite no
-- puede superar 60 segundos (máx. permitido por el gestor de botín).
function Win:ApplyTimeLimit()
    if not self.timeEdit then return end
    local raw = self.timeEdit:GetText() or ""
    local value = tonumber(raw)
    if value and value >= 1 then
        if value > 60 then value = 60 end
        if RD.config and RD.config.Set then
            RD.config:Set("loot.rollTimeLimit", math.floor(value))
        end
    end
    -- Libera el foco siempre (al pulsar Enter/Escape), incluso si el valor es
    -- inválido/vacío, para poder usar los atajos del teclado.
    self.timeEdit:ClearFocus()
end

-- Refresca toda la ventana desde el estado del loot
function Win:Refresh()
    if not self.frame then return end
    local loot = RD.modules and RD.modules.loot
    local st = loot and loot.GetState and loot:GetState()
    if not st then return end

    -- Ítem
    if st.itemLink then
        self.itemNameText:SetText(st.itemLink)
        self.itemNameText:SetTextColor(1, 1, 1)
        if st.itemTexture then
            self.itemBtn:SetNormalTexture(st.itemTexture)
        end
        if st.itemCount and st.itemCount > 1 then
            self.countText:SetText(st.itemCount)
        else
            self.countText:SetText("")
        end
    else
        self.itemNameText:SetText("Arrastra un ítem de la bolsa aquí")
        self.itemNameText:SetTextColor(0.8, 0.8, 0.8)
        self.itemBtn:SetNormalTexture("Interface\\PaperDoll\\UI-Backpack-EmptySlot")
        self.countText:SetText("")
    end

    -- Dados (dentro del área con scroll): cada dado es una fila-botón clicable
    -- (Clic = elegir ganador, Ctrl-Clic = anunciar el dado). El ganador se
    -- resalta en dorado para distinguirlo del resto.
    self:BuildRollRows(st.rolls or {}, st.winner)

    -- Estado de los botones. "Declarar ganador" se habilita con ítem y ganador
    -- (esté o no haya bandas: el gestor de botín es independiente de ellas). En
    -- caso de empate en el máximo, el ganador no se auto-asigna y el botón de
    -- desempate queda disponible para que solo tiren los empatados; también se
    -- puede elegir ganador manualmente (clic sobre un dado).
    local hasItem = st.itemLink ~= nil
    local canDeclare = hasItem and st.winner ~= nil
    local hasTie = not st.duel and hasItem and loot and loot.HasTie and loot:HasTie()
    -- Resalta el tipo de dados activo (Main/Dual/Enchant) para que se sepa qué
    -- dados se abrieron; los demás vuelven a su color normal.
    local activeType = st.rollType
    for i, btn in ipairs(self.rollBtns) do
        if hasItem then btn:Enable() else btn:Disable() end
        local fs = btn:GetFontString()
        if fs then
            if not hasItem then
                fs:SetTextColor(0.6, 0.6, 0.6)
            elseif i == activeType then
                fs:SetTextColor(GOLD_R, GOLD_G, GOLD_B)
            else
                fs:SetTextColor(1, 1, 1)
            end
        end
    end
    if self.winnerBtn then
        if canDeclare then self.winnerBtn:Enable() else self.winnerBtn:Disable() end
    end
    if self.duelBtn then
        if hasTie then self.duelBtn:Enable() else self.duelBtn:Disable() end
    end
    if self.rollBtn then
        -- En una ronda de desempate solo puede tirar el jugador local si está
        -- entre los empatados (el filtro de CHAT_MSG_SYSTEM descarta al resto).
        local canRollNow = st.recording and not st.rolled
        if st.duel then
            local me = UnitName("player") or ""
            local inDuel = false
            for _, name in ipairs(st.duelPlayers or {}) do
                if name == me then inDuel = true break end
            end
            canRollNow = canRollNow and inDuel
        end
        if canRollNow then self.rollBtn:Enable() else self.rollBtn:Disable() end
    end

    -- Sincroniza el campo de límite de tiempo con la config (sin pisar el texto
    -- mientras el usuario lo está editando). El límite no supera 60 segundos.
    if self.timeEdit and not self.timeEdit:HasFocus() then
        local limit = 20
        if RD.config and RD.config.Get then
            limit = RD.config:Get("loot.rollTimeLimit", 20)
        end
        limit = tonumber(limit) or 20
        if limit > 60 then limit = 60 end
        self.timeEdit:SetText(tostring(limit))
    end

    self:RefreshCountdown()
    -- Refresca el historial si es la vista activa (nuevos dados/ítems registrados).
    if self.view == "history" then
        self:RefreshHistory()
    end
end

-- Construye la lista de dados de la banda como filas-botón clicables dentro del
-- área con scroll (estilo KRT). Cada fila muestra el nombre y el dado; el
-- ganador actual va resaltado en dorado con ★ para distinguirlo del resto.
-- Clic normal → `SetWinner(name)` (elige a ese jugador como ganador).
-- Ctrl-Clic → `AnnounceRoll(name)` (anuncia ese dado por la salida por defecto).
function Win:BuildRollRows(rolls, winner)
    if not self.rollsChild then return end
    for _, row in ipairs(self.rollRows) do
        row:Hide()
        row:SetParent(nil)
    end
    self.rollRows = {}

    if not rolls or #rolls == 0 then
        if self.rollsEmptyText then self.rollsEmptyText:Show() end
        self.rollsChild:SetHeight(96)
        if self.rollsScroll and self.rollsScroll.SetVerticalScroll then
            self.rollsScroll:SetVerticalScroll(0)
        end
        return
    end
    if self.rollsEmptyText then self.rollsEmptyText:Hide() end

    local rowH, gap = 20, 2
    local childW = self.rollsChild:GetWidth() or 368
    self.rollsChild:SetHeight(#rolls * (rowH + gap) + gap)
    for i, r in ipairs(rolls) do
        local isWinner = (r.name == winner)
        local row = CreateFrame("Button", nil, self.rollsChild)
        row:SetSize(childW, rowH)
        row:SetPoint("TOPLEFT", self.rollsChild, "TOPLEFT", 0, -((i - 1) * (rowH + gap)))
        row:SetHighlightTexture("Interface\\Buttons\\UI-Listbox-Highlight", "ADD")

        -- Estrella del ganador por TEXTURA (el glifo ★ no existe en la fuente de
        -- 3.3.5a y renderiza "?"). Solo la fila ganadora la muestra, a la
        -- izquierda del nombre, que se corre para dejarle sitio.
        local star = row:CreateTexture(nil, "OVERLAY")
        star:SetSize(12, 12)
        star:SetPoint("LEFT", row, "LEFT", 2, 0)
        star:SetTexture("Interface\\GroupFrame\\UI-Group-LeaderIcon")
        star:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        star:Hide()

        local name = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        name:SetPoint("LEFT", row, "LEFT", isWinner and 18 or 4, 0)
        name:SetPoint("RIGHT", row, "RIGHT", -24, 0)
        name:SetJustifyH("LEFT")
        if isWinner then
            star:Show()
            name:SetText(r.name)
            name:SetTextColor(GOLD_R, GOLD_G, GOLD_B)
        else
            name:SetText(r.name)
            name:SetTextColor(1, 1, 1)
        end

        local rollText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        rollText:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        rollText:SetTextColor(isWinner and GOLD_R or 1, isWinner and GOLD_G or 1, isWinner and GOLD_B or 1)
        rollText:SetText(r.roll)

        if RD.UIUtils and RD.UIUtils.AddButtonTooltip then
            RD.UIUtils.AddButtonTooltip(row, function()
                if isWinner then
                    return "Ganador actual. Clic: mantener ganador · Ctrl-Clic: anunciar su dado."
                end
                return "Clic: elegir como ganador · Ctrl-Clic: anunciar su dado."
            end)
        end

        row:SetScript("OnClick", function()
            local loot = RD.modules and RD.modules.loot
            if not loot then return end
            if IsControlKeyDown() then
                if loot.AnnounceRoll then loot:AnnounceRoll(r.name) end
            else
                if loot.SetWinner then loot:SetWinner(r.name) end
            end
            self:Refresh()
        end)

        self.rollRows[#self.rollRows + 1] = row
    end
    if self.rollsScroll and self.rollsScroll.SetVerticalScroll then
        self.rollsScroll:SetVerticalScroll(0)
    end
end

function Win:Open()
    if not self.frame then
        local ok, err = pcall(function() self:Create() end)
        if not ok then
            self.frame = nil
            Log("|cffff0000[RaidDominion]|r Error al abrir el gestor de botín: " .. tostring(err))
            return
        end
    end
    if not self.frame then return end
    self:SetView(self.view or "loot")
    if RD.UIUtils and RD.UIUtils.ActivateWindow then
        RD.UIUtils.ActivateWindow(self.frame)
    else
        self.frame:Show()
        self.frame:Raise()
    end
    self.isShown = true
    if self.updateFrame then self.updateFrame:Show() end
    -- Activa el loop del countdown del módulo
    local loot = RD.modules and RD.modules.loot
    if loot and loot.ShowLoop then loot:ShowLoop() end
end

function Win:Close()
    if not self.frame then return end
    if self.updateFrame then self.updateFrame:Hide() end
    local loot = RD.modules and RD.modules.loot
    if loot and loot.ShowLoop then loot:ShowLoop() end
    self.frame:Hide()
    self.isShown = false
end

function Win:Toggle()
    if self.isShown then self:Close() else self:Open() end
end

RD.ui = RD.ui or {}
RD.ui.lootWindow = Win
return Win
