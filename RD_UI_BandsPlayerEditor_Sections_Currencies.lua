--[[
    RD_UI_BandsPlayerEditor_Sections_Currencies.lua
    PROPÓSITO: Sección de DATOS "Monedas" del editor de jugador. Muestra SIEMPRE
              el DINERO del personaje (grupo "Dinero": oro/plata/cobre desglosado,
              con meta SOLO de oro) y las FILAS de monedas/emblemas agrupadas por
              las CATEGORÍAS del cliente: icono a la izquierda y, a su derecha,
              DOS LÍNEAS de información (nombre completo sin truncar + "Cantidad
              · Meta") y un CHECK de seguimiento al extremo derecho de cada fila.
              La lectura en vivo y el formato de dinero viven en
              RD_Utils_Currencies (acceso LAZY: los RD_Utils_* cargan después de
              la UI en el .toc); se deduplicó el lector privado que había aquí.
              Clic izq. en la fila → panel con EditBox para la meta; clic der. →
              quitar la meta. El check de seguimiento consume su propio clic y
              guarda el flag (RD_Utils_ItemGoals) que alimenta el tooltip del
              botón "Jugador" de la barra inferior (RD_Utils_ItemGoals:
              TrackedCurrencyLines). El oro se edita en ORO (entero) y se guarda
              en COBRE (CheckCurrencies compara con GetMoney()). Al alcanzarla,
              el addon avisa UNA vez (RD_Module_ItemGoalsWatch) y la fila queda
              dorada. Solo uno mismo.
              Usa los helpers compartidos de RD_UI_BandsPlayerEditor_Sections_Grids
              (que DEBE cargarse antes en el .toc) vía RD.ui.playerEditorSectionsGrids.Helpers.
    API PÚBLICA:
        - RD.ui.playerEditorSectionsCurrencies:Build(container, ed, width, height)
    EVENTOS consumidos: CURRENCY_REFRESHED (publicado por el watcher; refresca
                        la sección si está abierta y el EditBox no tiene foco).
]]

local addonName, private = ...
local RD = _G.RaidDominion or {}
_G.RaidDominion = RD

RD.ui = RD.ui or {}
local Currencies = {}

-- Helpers compartidos (cargados antes: RD_UI_BandsPlayerEditor_Sections_Grids).
local H = (RD.ui and RD.ui.playerEditorSectionsGrids and RD.ui.playerEditorSectionsGrids.Helpers) or {}
local CleanExtras = H.CleanExtras or function() end
local Track = H.Track or function() end
local PanelText = H.PanelText or function(panel, y, size)
    local fs = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetJustifyH("LEFT")
    fs:SetPoint("TOPLEFT", panel, "TOPLEFT", 4, y)
    return fs
end
local MakePanel = H.MakePanel or function(container, width, height, panelH)
    return CreateFrame("Frame", nil, container)
end
local MakeScroll = H.MakeScroll or function(container, width, height, top, inset)
    local scroll = CreateFrame("ScrollFrame", nil, container)
    local content = CreateFrame("Frame", nil, scroll)
    scroll:SetSize(width, height)
    scroll:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -top)
    content:SetWidth(width)
    scroll:SetScrollChild(content)
    return scroll, content
end
local ShowMessage = H.ShowMessage or function() end
local GetGoals = H.GetGoals or function() return RD.utils and RD.utils.itemGoals end
-- Métricas compartidas (grid 4px): el MISMO contrato que usa la sección de
-- equipamiento. PANEL_H no puede divergir (regresión: un PANEL_H local distinto
-- hacía que el scroll tapara 12 px de las últimas filas de moneda).
local Metrics = H.Metrics or {
    GRID = 4, PAD = 4, ACTION_X = 14, ACTION_H = 24, CHIP_H = 24,
    PANEL_H = 116, PANEL_TITLE_Y = -8, PANEL_LINE1_Y = -28, PANEL_LINE_PITCH = 20,
    TRACK_S = 20, TRACK_GAP = 4,
}
local PAD = H.PAD or Metrics.PAD or 4
local PANEL_H = H.PANEL_H or Metrics.PANEL_H or 116
local TruncateToWidth = H.TruncateToWidth
    or function(text, width, fontSize)
        local size = tonumber(fontSize) or 12
        return tostring(text or "")
    end

-- Nombre único para frames con template: InputBoxTemplate crea texturas
-- $parentLeft/Middle/Right que requieren un nombre UNICO en el frame (si se
-- pasa nil, las texturas del template no se generan y el input no renderiza).
local UniqueName = (RD.UIUtils and RD.UIUtils.UniqueName)
    or function(prefix) return "RD" .. tostring(prefix) end

-- Lectura en vivo y formato de dinero: fuente ÚNICA RD_Utils_Currencies.
-- Acceso LAZY (los RD_Utils_* cargan después de la UI en el .toc; resuelto en
-- tiempo de llamada, no en load, igual que el contrato de los helpers de Grids).
local function Cur()
    return RD.utils and RD.utils.currencies
end

-- Clave del dinero del personaje como meta (solo oro): "Oro" (RD_Utils_Currencies).
local function MoneyKey()
    local c = Cur()
    return (c and c.MONEY_KEY) or "Oro"
end

-- Texto de una cantidad según el tipo de fila (dinero → desglose; resto, entero).
-- `isMoney` fuerza el desglose cuando no se tiene el entry (p.ej. el panel).
local function AmountText(entry, value, isMoney)
    local c = Cur()
    if c and c.Amount then
        if entry then return c:Amount(entry, value) end
        if isMoney and c.FormatMoney then return c:FormatMoney(value) end
    end
    return tostring(value)
end

-- Cobre por oro (constante compartida: la meta del oro se guarda en cobre).
local function CopperPerGold()
    local c = Cur()
    return (c and c.COPPER_PER_GOLD) or 10000
end

local currencyRefresh = nil  -- upvalue: refresco del panel (usado por las filas)

-- ============================================================================
-- Filas de moneda: icono a la izquierda + DOS LÍNEAS de info a la derecha
-- (nombre completo en la 1ª; "Cantidad · Meta" en la 2ª). Sin truncar el nombre.
-- ============================================================================

-- Geometría de la fila (grid 4px): icono 32x32 pegado a la izquierda (PAD), texto
-- a la derecha aprovechando el alto del icono para las dos líneas.
local ROW_H = 40
local ICON_S = 32
local ROW_GAP = 4
-- Columna de texto: PAD + icono + PAD → 40 (múltiplo de 4). Cabecera de categoría,
-- icono y texto comparten el gutter PAD para que no se desalineen.
local TXT_X = PAD + ICON_S + PAD
-- Check de seguimiento al extremo derecho de cada fila: 20x20 + gutter PAD = 24
-- (múltiplo de 4). Las constantes salen del contrato compartido Metrics
-- (mismas que usa el check del panel de Equipamiento). La columna de texto
-- reserva TRACK_GUTTER para no solaparse.
local TRACK_S = Metrics.TRACK_S or 20
local TRACK_GUTTER = TRACK_S + PAD
local HINT_H = 16
-- Ancho útil de la columna de texto (derecha reservada para el check).
local function TextW(width)
    return width - TXT_X - TRACK_GUTTER - 8
end

-- Crea/rellena las filas dentro de `content` (hijo del scroll). Devuelve la
-- lista de filas creadas (para que el panel de selección pueda marcar la activa).
local function BuildCurrencyRows(content, width, groups, sel, onPick, goals)
    local rows = {}
    local y = 0

    -- Línea de ayuda del check de seguimiento (una sola línea, 10px, al tope del
    -- scroll para que se vaya con él). No colisiona con las cabeceras: las filas
    -- empiezan en y = HINT_H.
    local hint = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hint:SetJustifyH("LEFT")
    hint:SetTextColor(0.6, 0.6, 0.6)
    if RD.UIUtils and RD.UIUtils.ApplyFontStyle then
        RD.UIUtils.ApplyFontStyle(hint, "hint")
    end
    hint:SetText("Check = seguimiento: aparece en el tooltip del botón Jugador.")
    hint:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, -y)
    rows[#rows + 1] = hint
    y = y + HINT_H

    for _, g in ipairs(groups) do
        -- Cabecera de categoría (alineada con el icono de sus filas: x = PAD).
        local h = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        h:SetJustifyH("LEFT")
        h:SetTextColor(1, 0.82, 0)
        if RD.UIUtils and RD.UIUtils.ApplyFontStyle then
            RD.UIUtils.ApplyFontStyle(h, "contentText")
        end
        h:SetText(g.title or "")
        h:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, -y)
        y = y + 20
        rows[#rows + 1] = h

        for _, c in ipairs(g.items) do
            local goal = c.goal
            local reached = goal and goal.reached
            local row = CreateFrame("Button", nil, content)
            row:SetSize(width, ROW_H)
            row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
            row:SetBackdrop({
                bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
                edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                tile = true, tileSize = 16, edgeSize = 12,
                insets = { left = 3, right = 3, top = 3, bottom = 3 },
            })
            row:SetBackdropColor(0, 0, 0, 0.35)
            local bc = reached and { 1, 0.82, 0 } or { 1, 1, 1 }
            row:SetBackdropBorderColor(bc[1], bc[2], bc[3], 0.8)
            row:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")

            -- Icono a la izquierda (32x32, ocupa el alto de la fila).
            local icon = row:CreateTexture(nil, "ARTWORK")
            icon:SetSize(ICON_S, ICON_S)
            icon:SetPoint("LEFT", row, "LEFT", PAD, 0)
            icon:SetTexture(c.icon or "Interface\\Icons\\INV_Misc_Coin_01")
            icon:SetTexCoord(0.06, 0.94, 0.06, 0.94)

            -- Línea 1: nombre completo (truncado solo si no cabe; el nombre real
            -- queda en el tooltip). El ancho reserva el gutter del check.
            local name = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            name:SetJustifyH("LEFT")
            if RD.UIUtils and RD.UIUtils.ApplyFontStyle then
                RD.UIUtils.ApplyFontStyle(name, "contentText")
            end
            name:SetText(TruncateToWidth(c.name or "", TextW(width), 12))
            local ncol = reached and { 1, 0.82, 0 } or { 1, 1, 1 }
            name:SetTextColor(ncol[1], ncol[2], ncol[3])
            name:SetPoint("TOPLEFT", row, "TOPLEFT", TXT_X, -6)

            -- Línea 2: cantidad y meta. El dinero se muestra desglosado.
            local meta = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            meta:SetJustifyH("LEFT")
            meta:SetTextColor(0.7, 0.7, 0.7)
            if RD.UIUtils and RD.UIUtils.ApplyFontStyle then
                RD.UIUtils.ApplyFontStyle(meta, "contentText")
            end
            meta:SetText(TruncateToWidth(
                "Cantidad: " .. AmountText(c, c.quantity)
                    .. (goal and ("  ·  Meta: " .. AmountText(c, goal.target)) or "")
                    .. (reached and "  ·  ✓" or ""),
                TextW(width), 12))
            meta:SetPoint("TOPLEFT", name, "BOTTOMLEFT", 0, -2)
            meta:SetWidth(TextW(width))

            -- Check de seguimiento al extremo derecho de la fila: consume su
            -- propio clic (no abre el panel ni toca la meta) y guarda el flag
            -- por moneda (RD_Utils_ItemGoals:SetCurrencyTracked). El estado lo
            -- muestra el propio check; no reconstruye la lista (respeta scroll
            -- y selección).
            local tracked = goals and goals.IsCurrencyTracked and goals:IsCurrencyTracked(c.key)
            local track = CreateFrame("CheckButton", UniqueName("CurTrk"), row, "UICheckButtonTemplate")
            track:SetSize(TRACK_S, TRACK_S)
            track:SetPoint("RIGHT", row, "RIGHT", -PAD, 0)
            track:SetChecked(tracked == true)
            track:RegisterForClicks("LeftButtonUp")
            track:SetScript("OnClick", function(self)
                local checked = self:GetChecked()
                local value = (checked == true) or (checked == 1)
                if goals and goals.SetCurrencyTracked then
                    goals:SetCurrencyTracked(c.key, value)
                end
            end)
            row.rdTrack = track

            row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            row:SetScript("OnClick", function(self, button)
                if button == "RightButton" then
                    if onPick and onPick.clear then onPick.clear(c) end
                    return
                end
                if onPick then onPick.select(c) end
            end)
            if RD.UIUtils and RD.UIUtils.AddButtonTooltip then
                RD.UIUtils.AddButtonTooltip(row, function()
                    return c.name .. "\nCantidad: " .. AmountText(c, c.quantity)
                        .. (goal and ("\nMeta: " .. AmountText(c, goal.target) .. (reached and " (alcanzada)" or "")) or "")
                        .. "\nClic izq.: editar meta · Clic der.: quitar"
                end)
            end
            row.rdKey = c.name
            row.rdBorder = bc
            rows[#rows + 1] = row
            y = y + ROW_H + ROW_GAP
        end
        y = y + 4
    end
    return rows, y + 4
end

local function BuildCurrencies(container, ed, width, height)
    CleanExtras(container)
    local goals = GetGoals()

    if not ed or not ed.isSelf then
        ShowMessage(container, width, "Solo visible para tu propio personaje.", { 0.7, 0.7, 0.7 })
        return
    end

    local groups = (Cur() and Cur():Collect()) or {}
    if #groups == 0 then
        ShowMessage(container, width, "No tienes monedas o emblemas.", { 0.7, 0.7, 0.7 })
        return
    end

    local curGoals = (goals and goals.CurrencyGoals and goals:CurrencyGoals()) or {}
    local curCount = {}
    for _, g in ipairs(groups) do
        for _, c in ipairs(g.items) do
            curCount[c.name] = c.quantity
        end
    end

    local scrollH = math.max(40, height - PANEL_H)
    local scroll, content = MakeScroll(container, width, scrollH, 0, 0)

    -- Selección persistente entre rebuilds (contenedor.rdSelCurrency).
    local sel = { name = container.rdSelCurrency or nil }

    -- Estructura de datos por grupo (la consumen las filas y los tests).
    local dataGroups = {}
    for _, g in ipairs(groups) do
        local items = {}
        for _, c in ipairs(g.items) do
            local goal = curGoals[c.name]
            items[#items + 1] = {
                key = c.name,
                name = c.name,
                quantity = c.quantity,
                icon = c.icon,
                goal = goal,
                reached = goal and goal.reached,
                money = c.money,
                tracked = (goals and goals.IsCurrencyTracked and goals:IsCurrencyTracked(c.name)) == true,
            }
        end
        dataGroups[#dataGroups + 1] = { title = g.title, items = items }
    end
    -- Datos estructurados por grupo (los consumen las filas y los tests/harness).
    container.rdCurrencyData = dataGroups

    -- Render de filas (icono a la izquierda + 2 líneas de info a la derecha).
    local function SelectCurrency(c)
        sel.name = c.key
        container.rdSelCurrency = c.key
        if currencyRefresh then currencyRefresh(c.key) end
    end
    container.rdCurrencySelect = SelectCurrency
    local rows, rowsH = BuildCurrencyRows(content, width, dataGroups, sel, {
        select = SelectCurrency,
        clear = function(c)
            if goals and goals.ClearCurrencyGoal then
                goals:ClearCurrencyGoal(c.key)
                BuildCurrencies(container, ed, width, height)
            end
        end,
    }, goals)
    for _, r in ipairs(rows) do
        Track(container, r)
    end
    content:SetHeight(math.max(10, rowsH or 10))
    if scroll.UpdateScrollChildRect then scroll:UpdateScrollChildRect() end

    -- ----- Panel inferior fijo: meta de cantidad por moneda -----
    -- (heredó el recuadro de MakePanel; info arriba, fila de acción abajo)
    local panel = MakePanel(container, width, height, PANEL_H)

    -- Geometría del panel desde Metrics (grid 4px): título + 3 líneas de info
    -- (cantidad, meta, estado) con pitch 20 y la fila de acción anclada abajo.
    local PT, L1, LP = Metrics.PANEL_TITLE_Y, Metrics.PANEL_LINE1_Y, Metrics.PANEL_LINE_PITCH
    local lineW = math.max(40, width - 2 * PAD - 2)

    local title = PanelText(panel, PT, 15)
    title:SetTextColor(1, 0.82, 0)
    local line = PanelText(panel, L1, 13)
    line:SetWidth(lineW)
    local status = PanelText(panel, L1 - LP, 13)
    status:SetWidth(lineW)
    local state = PanelText(panel, L1 - 2 * LP, 13)
    state:SetWidth(lineW)

    -- Input de la meta. Ancho 128 (antes 96): el placeholder "Cantidad meta…" a
    -- 15px (UI_STYLE.input.textSize) mide ~105-115px y se cortaba en 88px útiles.
    local edit = CreateFrame("EditBox", UniqueName("Cur"), panel, "InputBoxTemplate")
    edit:SetSize(128, Metrics.ACTION_H)
    edit:SetAutoFocus(false)
    if RD.UIUtils and RD.UIUtils.StyleInput then RD.UIUtils.StyleInput(edit) end
    edit:SetPoint("TOPLEFT", panel, "TOPLEFT", Metrics.ACTION_X, -(PANEL_H - Metrics.ACTION_H - 4))

    -- Placeholder "Cantidad meta…" con el patrón de CreateItemSearch (3.3.5a no
    -- tiene SetPlaceholderText): texto REAL gris dentro del input, sustituido
    -- por lo que teclea el usuario. CRÍTICO: el filtro numérico solo actúa sobre
    -- tecleo real (userInput); si filtrara también el SetText interno, borraría
    -- el placeholder en cuanto se mostrara (OnTextChanged con userInput=nil).
    local PH = "Cantidad meta…"
    local function ShowPlaceholder()
        edit:SetText(PH)
        edit:SetTextColor(0.6, 0.6, 0.6)
    end
    local function ClearPlaceholder(self)
        if self:GetText() == PH then
            self:SetText("")
            self:SetTextColor(1, 1, 1)
        end
    end
    -- Texto "real": el placeholder cuenta como vacío (Registrar no lo registra).
    local function GetRealText()
        local t = edit:GetText() or ""
        if t == PH then return "" end
        return t
    end

    -- Solo números (la meta es una cantidad entera): se filtran los no dígitos
    -- al teclear. El flag evita reentrada cuando SetText dispara OnTextChanged.
    local filtering = false
    edit:SetScript("OnTextChanged", function(self, userInput)
        if filtering or not userInput then return end
        local t = self:GetText() or ""
        local cleaned = t:gsub("%D", "")
        if cleaned ~= t then
            filtering = true
            self:SetText(cleaned)
            filtering = false
        end
    end)
    edit:SetScript("OnEditFocusGained", ClearPlaceholder)
    edit:SetScript("OnEditFocusLost", function(self)
        if self:GetText() == "" then ShowPlaceholder() end
    end)
    edit:SetScript("OnEscapePressed", function()
        if GetRealText() == "" then ShowPlaceholder() end
        edit:ClearFocus()
    end)
    ShowPlaceholder()

    local regBtn = RD.UIUtils.MakeChipButton(panel, nil, 80, Metrics.CHIP_H)
    regBtn:SetText("Registrar")
    regBtn:SetPoint("LEFT", edit, "RIGHT", 6, 0)
    local clearBtn = RD.UIUtils.MakeChipButton(panel, nil, 72, Metrics.CHIP_H)
    clearBtn:SetText("Quitar")
    clearBtn:SetPoint("LEFT", regBtn, "RIGHT", 6, 0)

    -- Referencia para el guard de refresco (RefreshOpenSection en la sección grids)
    if RD.ui and RD.ui.playerEditorSectionsGrids then
        RD.ui.playerEditorSectionsGrids.currencyEditBox = edit
    end

    -- Marca la fila seleccionada (afordancia) SIN reconstruir la lista: la fila
    -- activa se distingue por fondo cálido + borde dorado; el resto conserva su
    -- estado base (borde blanco, o dorado si la meta ya se alcanzó).
    local rowsByKey = {}
    for _, r in ipairs(rows) do
        if r.rdKey then rowsByKey[r.rdKey] = r end
    end
    local function MarkSelected(name)
        for k, r in pairs(rowsByKey) do
            if k == name then
                r:SetBackdropBorderColor(1, 0.82, 0, 1)
                r:SetBackdropColor(0.2, 0.16, 0.06, 0.6)
            else
                local bc = r.rdBorder or { 1, 1, 1 }
                r:SetBackdropBorderColor(bc[1], bc[2], bc[3], 0.8)
                r:SetBackdropColor(0, 0, 0, 0.35)
            end
        end
    end

    local function ParseEdit()
        return tonumber(GetRealText())
    end

    regBtn:SetScript("OnClick", function()
        if not sel.name or not goals or not goals.SetCurrencyGoal then return end
        local v = ParseEdit()
        if not v or v <= 0 then
            if RD.messageManager and RD.messageManager.SendSystemMessage then
                RD.messageManager:SendSystemMessage("|cffff8000[RaidDominion]|r Escribe una cantidad objetivo válida (número mayor que 0).")
            end
            return
        end
        -- El oro se edita en ORO (entero) pero se guarda en COBRE para que
        -- CheckCurrencies compare cobre contra cobre (GetMoney()).
        local target = (sel.name == MoneyKey()) and (math.floor(v) * CopperPerGold()) or v
        goals:SetCurrencyGoal(sel.name, target)
        BuildCurrencies(container, ed, width, height)
    end)

    clearBtn:SetScript("OnClick", function()
        if not sel.name or not goals or not goals.ClearCurrencyGoal then return end
        goals:ClearCurrencyGoal(sel.name)
        BuildCurrencies(container, ed, width, height)
    end)

    -- Resto que falta a una meta (desglosado si es dinero).
    local function RemainingText(name, goal)
        local qty = curCount[name] or 0
        local diff = math.max(0, (goal.target or 0) - qty)
        return "Te faltan " .. AmountText(nil, diff, name == MoneyKey())
    end

    currencyRefresh = function(name)
        sel.name = name
        if not name then
            title:SetText("Selecciona una moneda")
            line:SetText("")
            status:SetText("")
            state:SetTextColor(0.7, 0.7, 0.7)
            state:SetText("Para fijar (o quitar) su objetivo.")
            ShowPlaceholder()
            regBtn:Disable()
            clearBtn:Disable()
            MarkSelected(nil)
            return
        end
        local goal = goals and goals.GetCurrencyGoal and goals:GetCurrencyGoal(name)
        title:SetText(TruncateToWidth(name, lineW, 15))
        -- Línea 1: cantidad actual (desglosada si es dinero).
        line:SetText("Cantidad actual: " .. AmountText(nil, curCount[name] or 0, name == MoneyKey()))
        -- Línea 2: meta.
        if goal then
            status:SetTextColor(1, 0.82, 0)
            status:SetText("Meta: " .. AmountText(nil, goal.target, name == MoneyKey()))
        else
            status:SetTextColor(0.7, 0.7, 0.7)
            status:SetText("Sin meta")
        end
        -- Línea 3: estado (alcanzada / pendiente / pista).
        if goal and goal.reached then
            state:SetTextColor(0, 1, 0)
            state:SetText("Objetivo alcanzado ✓")
        elseif goal then
            state:SetTextColor(1, 0.82, 0)
            state:SetText(RemainingText(name, goal))
        else
            state:SetTextColor(0.7, 0.7, 0.7)
            state:SetText("")
        end
        -- El input del oro muestra la meta en ORO (target/COPPER_PER_GOLD); sin
        -- meta, vuelve al placeholder (gris) en lugar de quedar vacío.
        if goal then
            edit:SetText(tostring((name == MoneyKey()) and math.floor(goal.target / CopperPerGold()) or goal.target))
            if goal.reached then edit:SetTextColor(0, 1, 0) else edit:SetTextColor(1, 1, 1) end
        else
            ShowPlaceholder()
        end
        if goal then clearBtn:Enable() else clearBtn:Disable() end
        if goals and goals.SetCurrencyGoal then regBtn:Enable() else regBtn:Disable() end
        MarkSelected(name)
    end

    currencyRefresh(sel.name)
end

-- Construye la sección de monedas (invocado desde SectionsGrids:Build).
function Currencies:Build(container, ed, width, height)
    width = width or ((container and container:GetWidth()) or 396) - 24
    if width < 8 then width = 372 end
    height = height or ((container and container:GetHeight()) or 300)
    BuildCurrencies(container, ed, width, height)
end

RD.ui.playerEditorSectionsCurrencies = Currencies
return Currencies