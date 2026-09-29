--[[
    RD_UI_MenuFactory.lua
    PROPÓSITO: Fábrica de menús. Renderiza submenús a partir de definiciones de datos
              (RD.constants.MENU_DEFINITIONS) con layout escalable por columnas
              (grid 4px, anclas relativas, offsets enteros).
    API PÚBLICA:
        - RD.ui.menuFactory:BuildMenu(definitions, opts)
        - RD.ui.menuFactory:RenderBar(buttonBar, barItems)
        - RD.ui.menuFactory:OrderBySavedOrder(items, savedOrder, getId)
        - RD.ui.menuFactory:MoveOrderedId(order, source, target)
        - RD.ui.menuFactory:OrderBarItems(barItems)
        - RD.ui.menuFactory:DefaultMenuOrder()
        - RD.ui.menuFactory:MenuOrder()
        - RD.ui.menuFactory:OrderMainDefs(defs)
        - RD.ui.menuFactory:ApplyBarButtonActive(button, activeEvent)
    EVENTOS: Ninguno (los botones disparan acciones vía RD.MenuActions)
]]

local addonName, private = ...
local RD = _G.RaidDominion or {}
_G.RaidDominion = RD

local MenuFactory = {}

-- ============================================================================
-- ORDEN DE ÍTEMS (barra inferior y menú principal)
-- Los iconos de la barra inferior y los ítems del menú flotante se pueden
-- reordenar arrastrando el grip correspondiente en la ventana de configuración
-- (claves ui.actionBar.order y ui.menu.itemOrder). Vacío = orden de declaración.
-- Helpers PUROS (los blinda el harness): no leen config ni crean frames.
-- ============================================================================

-- Devuelve una COPIA de `items` ordenada según `savedOrder` (array de ids con
-- la semántica del arrastre del drag-row: 1..n). Los ítems sin id guardado se
-- dejan al final en su orden de declaración (estable, sin table.sort).
function MenuFactory:OrderBySavedOrder(items, savedOrder, getId)
    items = items or {}
    if type(getId) ~= "function" then return items end
    local order = {}
    if type(savedOrder) == "table" then
        for _, v in ipairs(savedOrder) do order[#order + 1] = v end
    end
    local byId = {}
    for _, it in ipairs(items) do
        local id = getId(it)
        if id ~= nil then byId[id] = it end
    end
    local result = {}
    local used = {}
    for _, id in ipairs(order) do
        local it = byId[id]
        if it then
            result[#result + 1] = it
            used[it] = true
        end
    end
    for _, it in ipairs(items) do
        if not used[it] then
            result[#result + 1] = it
            used[it] = true
        end
    end
    return result
end

-- Mueve el id en `order[source]` a la posición `target` (semántica del drag:
-- target en [1, n+1], el hueco donde se insertaría ANTES de quitar el ítem).
-- Devuelve un array NUEVO; no muta `order`.
function MenuFactory:MoveOrderedId(order, source, target)
    local list = {}
    for i = 1, #order do list[i] = order[i] end
    local n = #list
    if n == 0 then return list end
    local id = list[source]
    if id == nil then return list end
    table.remove(list, source)
    local insert = target
    if target > source then insert = target - 1 end
    insert = math.max(1, math.min(#list + 1, insert))
    table.insert(list, insert, id)
    return list
end

-- Orden guardado de la barra inferior (por `action`) o nil si no hay config.
local function SavedOrder(key)
    if RD.config and RD.config.Get then
        local v = RD.config:Get(key)
        if type(v) == "table" then return v end
    end
    return nil
end

-- Ítems de la barra inferior en el orden guardado (para construir/reposicionar).
function MenuFactory:OrderBarItems(barItems)
    return self:OrderBySavedOrder(barItems, SavedOrder("ui.actionBar.order"),
        function(it) return it.action end)
end

-- Orden POR DEFECTO de los ítems del menú flotante con pestaña propia: el orden
-- del ESQUEMA de configuración ordenado por `order` (la fila superior), filtrado
-- a los ids que existen en MainFrameOptions. Así la barra superior y el menú
-- comparten el mismo orden inicial (bands, abilities, roles, buffs, auras,
-- mechanics, rules).
function MenuFactory:DefaultMenuOrder()
    local defs = RD.constants and RD.constants.MENU_DEFINITIONS and RD.constants.MENU_DEFINITIONS.MainFrameOptions
    local schema = RD.constants and RD.constants.CONFIG_SCHEMA
    if not defs or not schema then return {} end
    -- Copia ordenada por `order` (la fila superior respeta este orden; no se
    -- reusa la declaración del archivo, que no coincide).
    local sorted = {}
    for _, tab in ipairs(schema) do sorted[#sorted + 1] = tab end
    for i = 2, #sorted do
        local key = sorted[i]
        local keyOrder = key.order or 0
        local j = i - 1
        while j >= 1 and (sorted[j].order or 0) > keyOrder do
            sorted[j + 1] = sorted[j]
            j = j - 1
        end
        sorted[j + 1] = key
    end
    local ids = {}
    for _, tab in ipairs(sorted) do
        if tab.id then
            for _, d in ipairs(defs) do
                if d.id == tab.id then
                    ids[#ids + 1] = d.id
                    break
                end
            end
        end
    end
    return ids
end

-- Orden EFECTIVO de los ítems reordenables del menú principal: el guardado
-- (ui.menu.itemOrder) si el usuario ya reordenó, o el orden por defecto.
function MenuFactory:MenuOrder()
    local saved = SavedOrder("ui.menu.itemOrder")
    if type(saved) == "table" and #saved > 0 then return saved end
    return self:DefaultMenuOrder()
end

-- Defs del menú principal en el orden efectivo (MenuOrder); el submenú del
-- addon (sin contraparte) queda al final en orden de declaración.
function MenuFactory:OrderMainDefs(defs)
    return self:OrderBySavedOrder(defs, self:MenuOrder(),
        function(it) return it.id end)
end

-- Constantes de grid (deben coincidir con RD.constants.GRID)
local GRID = (RD.constants and RD.constants.GRID) or {}
local MAX_ITEMS_PER_COLUMN = GRID.MAX_ITEMS_PER_COLUMN or 9
local MAX_COLUMNS = GRID.MAX_COLUMNS or 2
local LABEL_WIDTH = GRID.LABEL_WIDTH or 184
local MENU_ITEM_HEIGHT = GRID.MENU_ITEM_HEIGHT or 22
local MENU_ITEM_GAP = GRID.MENU_ITEM_GAP or 2
local COLUMN_SPACING = GRID.COLUMN_SPACING or 16
local BUTTON_SIZE = GRID.BUTTON_SIZE or 20
local GUTTER = GRID.GUTTER or 4

-- Color dorado de acento (1, 0.82, 0)
local GOLD_R, GOLD_G, GOLD_B = unpack((RD.constants and RD.constants.COLORS and RD.constants.COLORS.GOLD) or { 1, 0.82, 0 })

--[[
    Construye un frame de menú a partir de una lista de definiciones.
    opts: parent, yOffset, columns (máximo de columnas), itemsPerColumn
          (elementos por columna), onClick(item, button), onRightClick(item, button),
          onIconClick(item, iconButton), noBackdrop (default true), centerLabels,
          movable, barItems, tooltipEnabled.
    Los ítems con `assignable` muestran "<asignado> [<ítem>]" en el label y un
    botón-icono a la derecha que invoca opts.onIconClick.
    Devuelve menu, width, height (sizes en enteros).
]]
function MenuFactory:BuildMenu(definitions, opts)
    opts = opts or {}
    local parent = opts.parent or UIParent
    local yOffset = opts.yOffset or 0

    local menu = CreateFrame("Frame", nil, parent)
    menu:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -yOffset)

    -- Backdrop solo si el frame flotante no lo aporta (noBackdrop default true)
    if opts.noBackdrop == false then
        menu:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 12,
            insets = { left = 4, right = 4, top = 4, bottom = 4 },
        })
        menu:SetBackdropColor(0, 0, 0, 0.9)
        menu:SetBackdropBorderColor(1, 1, 1, 0.5)
    end

    -- Filtrar ítems deshabilitados (sin huecos) y ordenar por item.order
    local visible = {}
    if definitions then
        for _, item in ipairs(definitions) do
            local enabled = true
            if type(item.enabled) == "function" then
                enabled = item.enabled()
            end
            if enabled then
                table.insert(visible, item)
            end
        end
    end

    -- Orden estable por order (los ítems sin order conservan su posición relativa)
    for i = 2, #visible do
        local key = visible[i]
        local keyOrder = key.order or 0
        local j = i - 1
        while j >= 1 and (visible[j].order or 0) > keyOrder do
            visible[j + 1] = visible[j]
            j = j - 1
        end
        visible[j + 1] = key
    end

    -- Menú vacío: frame con tamaño mínimo
    if #visible == 0 then
        menu:SetSize(LABEL_WIDTH, MENU_ITEM_HEIGHT)
        return menu, LABEL_WIDTH, MENU_ITEM_HEIGHT
    end

    -- Cálculo de columnas DETERMINISTA: solo depende del número de ítems y de
    -- `opts.itemsPerColumn` (elementos por columna). columnas = clamp(ceil(n /
    -- itemsPerColumn), 2, MAX_COLUMNS). Mínimo 2 columnas (como la base v2);
    -- tope duro global MAX_COLUMNS. Así el único control de la config (General)
    -- tiene efecto visible y predecible en vivo.
    local itemsPerColumn = opts.itemsPerColumn and opts.itemsPerColumn > 0 and math.floor(opts.itemsPerColumn) or MAX_ITEMS_PER_COLUMN
    local numColumns = math.max(2, math.min(MAX_COLUMNS, math.ceil(#visible / itemsPerColumn)))
    local rows = math.ceil(#visible / numColumns)

    local barItems = opts.barItems
    for i = 1, #visible do
        local item = visible[i]
        local col = (i - 1) % numColumns
        local row = math.floor((i - 1) / numColumns)
        local x = col * (LABEL_WIDTH + COLUMN_SPACING)
        local y = -row * (MENU_ITEM_HEIGHT + MENU_ITEM_GAP)

        local button = CreateFrame("Button", nil, menu)
        button:SetSize(LABEL_WIDTH, MENU_ITEM_HEIGHT)
        button:SetPoint("TOPLEFT", menu, "TOPLEFT", x, y)
        -- Clic izq = ingresar (submenú/acción); clic der = regresar al menú previo.
        -- Por defecto un Button plano solo registra clic izquierdo.
        button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        button:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

        -- Texto del ítem. Para los asignables se muestra "<jugador> [<ítem>]"
        -- cuando hay asignación, y se reserva espacio a la derecha para el
        -- botón-icono de asignar/desasignar (como el addon base).
        local text = button:GetFontString()
        if not text then
            text = button:CreateFontString(nil, "OVERLAY")
            button:SetFontString(text)
        end
        text:SetFontObject("GameFontHighlight")
        local display = item.name or ""
        if item.assignable and item.assigned then
            display = item.assigned .. " [" .. display .. "]"
        end
        text:SetText(display)
        local textLeft = 5
        local textRight = item.submenu and -20 or -5

        if item.assignable then
            -- Fondo indicador de asignación: verde si está asignado, oscuro si no
            local bg = button:CreateTexture(nil, "BACKGROUND")
            bg:SetAllPoints()
            if item.assigned then
                bg:SetTexture(0.15, 0.45, 0.15, 0.6)
            else
                bg:SetTexture(0.15, 0.15, 0.15, 0.4)
            end
            button.bg = bg

            -- Botón-icono a la derecha (asignar/desasignar). Clic izquierdo =
            -- asignar/desasignar; clic derecho = anunciar el elemento con la
            -- palabra configurada (assignWord). El icono captura el derecho para
            -- que NO caiga en el "volver al menú anterior" del botón matriz.
            local iconBtn = CreateFrame("Button", nil, button)
            iconBtn:SetSize(18, 18)
            iconBtn:SetPoint("RIGHT", button, "RIGHT", -4, 0)
            iconBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            local iconTex = iconBtn:CreateTexture(nil, "ARTWORK")
            iconTex:SetAllPoints()
            iconTex:SetTexture(item.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
            iconBtn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
            iconBtn:SetScript("OnClick", function(self, btn)
                if btn == "RightButton" then
                    if opts.onIconRightClick then
                        opts.onIconRightClick(item, self)
                    end
                elseif opts.onIconClick then
                    opts.onIconClick(item, self, btn)
                end
            end)
            iconBtn:SetScript("OnEnter", function(self)
                local tooltipEnabled = true
                if type(opts.tooltipEnabled) == "function" then
                    tooltipEnabled = opts.tooltipEnabled()
                end
                if not tooltipEnabled then
                    if GameTooltip:IsOwned(self) then GameTooltip:Hide() end
                    return
                end
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                if item.isBand then
                    GameTooltip:SetText("Banda", 1, 1, 1, 1, true)
                    GameTooltip:AddLine("Clic: abrir el gestor de jugadores de la banda", 1, 0.82, 0, true)
                    GameTooltip:AddLine("Clic der.: anunciar la banda", 1, 0.82, 0, true)
                else
                    GameTooltip:SetText("Asignación rápida", 1, 1, 1, 1, true)
                    GameTooltip:AddLine("Clic: asignar o desasignar el objetivo seleccionado", 1, 0.82, 0, true)
                    -- Las palabras de anuncio del clic (texto / clic derecho) son las
                    -- configuradas en la pestaña de cada lista (announce.<lista>):
                    -- `word` (clic en el texto) y `assignWord` (clic derecho en el icono).
                    local clickWord = tostring(item.clickWord or "NEED"):gsub("^%s+", ""):gsub("%s+$", "")
                    if clickWord == "" then clickWord = "NEED" end
                    local clickRightWord = tostring(item.clickRightWord or ""):gsub("^%s+", ""):gsub("%s+$", "")
                    GameTooltip:AddLine("Clic en el texto: " .. clickWord, 1, 0.82, 0, true)
                    GameTooltip:AddLine("Clic der.: " .. (clickRightWord ~= "" and clickRightWord or "anunciar el elemento"), 1, 0.82, 0, true)
                end
                GameTooltip:Show()
            end)
            iconBtn:SetScript("OnLeave", function()
                GameTooltip:Hide()
            end)
            textRight = -26
        elseif item.icon then
            -- Icono inline a la izquierda (ítems no asignables)
            local icon = button:CreateTexture(nil, "ARTWORK")
            icon:SetSize(16, 16)
            icon:SetPoint("LEFT", button, "LEFT", 4, 0)
            icon:SetTexture(item.icon)
            icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            textLeft = 24
        end

        -- Elemento ACTIVO (banda en spam o regla seleccionada): fondo dorado
        -- PULSANTE + punto dorado a la izquierda del texto (sin glifos de
        -- flecha, que no existen en la fuente de 3.3.5a). Aplica a ítems
        -- asignables (bandas) y NO asignables (reglas). El OnUpdate solo corre
        -- mientras el menú está visible y hay un elemento activo; se apaga al
        -- ocultarse el menú.
        local isActive = item.spamming or item.active
        if isActive then
            local bg = button.bg
            if not bg then
                bg = button:CreateTexture(nil, "BACKGROUND")
                bg:SetAllPoints()
                button.bg = bg
            end
            bg:SetTexture(GOLD_R, GOLD_G, GOLD_B, 0.5)
            bg:SetVertexColor(1, 1, 1, 1)
            -- El punto se coloca después del icono inline cuando lo hay (no asignable)
            local hasInlineIcon = (not item.assignable) and item.icon ~= nil
            local dot = button:CreateTexture(nil, "OVERLAY")
            dot:SetSize(6, 6)
            dot:SetPoint("LEFT", button, "LEFT", hasInlineIcon and 26 or 6, 0)
            dot:SetTexture(GOLD_R, GOLD_G, GOLD_B, 1)
            button.rdDot = dot
            textLeft = hasInlineIcon and 34 or 18
            if not menu.rdSpamPulse then
                menu.rdSpamPulse = 0
                menu.rdSpamButtons = {}
                menu:SetScript("OnUpdate", function(self, elapsed)
                    if not self:IsShown() then return end
                    self.rdSpamPulse = (self.rdSpamPulse or 0) + elapsed
                    local a = 0.45 + 0.3 * (0.5 + 0.5 * math.sin(self.rdSpamPulse * 4))
                    for _, b in ipairs(self.rdSpamButtons or {}) do
                        if b.bg and b.bg.SetAlpha then b.bg:SetAlpha(a) end
                        if b.rdDot and b.rdDot.SetAlpha then b.rdDot:SetAlpha(a) end
                    end
                end)
            end
            table.insert(menu.rdSpamButtons, button)
        end

        if opts.centerLabels then
            text:SetJustifyH("CENTER")
            text:SetPoint("LEFT", button, "LEFT", 0, 0)
            text:SetPoint("RIGHT", button, "RIGHT", 0, 0)
        else
            text:SetJustifyH("LEFT")
            text:SetPoint("LEFT", button, "LEFT", textLeft, 0)
            text:SetPoint("RIGHT", button, "RIGHT", textRight, 0)
        end
        if item.isHint then
            text:SetTextColor(0.6, 0.6, 0.6)
        elseif (item.spamming or item.active) then
            text:SetTextColor(GOLD_R, GOLD_G, GOLD_B)
        else
            text:SetTextColor(1, 1, 1)
        end

        -- Indicador de submenú "»" en el borde derecho
        if item.submenu then
            local indicator = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            indicator:SetText("»")
            indicator:SetTextColor(GOLD_R, GOLD_G, GOLD_B)
            indicator:SetPoint("RIGHT", button, "RIGHT", -6, 0)
        end

        -- OnEnter/OnLeave: color dorado + tooltip
        button:SetScript("OnEnter", function(self)
            if not item.isHint then text:SetTextColor(GOLD_R, GOLD_G, GOLD_B) end
            local tooltipEnabled = true
            if type(opts.tooltipEnabled) == "function" then
                tooltipEnabled = opts.tooltipEnabled()
            end
            if tooltipEnabled and item.tooltip then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(item.name or "", 1, 1, 1, 1, true)
                GameTooltip:AddLine(item.tooltip, GOLD_R, GOLD_G, GOLD_B, true)
                GameTooltip:Show()
            end
        end)
        button:SetScript("OnLeave", function(self)
            if item.isHint then
                text:SetTextColor(0.6, 0.6, 0.6)
            elseif (item.spamming or item.active) then
                text:SetTextColor(GOLD_R, GOLD_G, GOLD_B)
            else
                text:SetTextColor(1, 1, 1)
            end
            if GameTooltip:IsOwned(self) then
                GameTooltip:Hide()
            end
        end)

        -- OnClick: izquierdo ejecuta la acción, derecho el callback alternativo
        button:SetScript("OnClick", function(self, btn)
            if btn == "LeftButton" then
                -- Los hints son informativos: el clic izquierdo no hace nada
                if item.isHint then return end
                if opts.onClick then
                    opts.onClick(item, self)
                end
            elseif btn == "RightButton" then
                -- El clic derecho SIEMPRE vuelve al menú anterior (incluidos hints)
                if opts.onRightClick then
                    opts.onRightClick(item, self)
                end
            end
        end)
    end

    -- Barra inferior de botones-icono
    if barItems and #barItems > 0 then
        local bar = CreateFrame("Frame", nil, menu)
        bar:SetPoint("BOTTOMLEFT", menu, "BOTTOMLEFT", 0, 0)
        bar:SetPoint("BOTTOMRIGHT", menu, "BOTTOMRIGHT", 0, 0)
        bar:SetHeight(BUTTON_SIZE)
        self:RenderBar(bar, barItems, opts)
    end

    -- Dimensiones finales (enteros)
    local width = numColumns * LABEL_WIDTH + (numColumns - 1) * COLUMN_SPACING
    local height = rows * MENU_ITEM_HEIGHT + (rows - 1) * MENU_ITEM_GAP
    if barItems and #barItems > 0 then
        height = height + BUTTON_SIZE + GUTTER
    end

    menu:SetSize(width, height)

    -- Arrastre opcional (el frame flotante principal suele gestionarlo él mismo)
    if opts.movable then
        menu:SetMovable(true)
        menu:RegisterForDrag("LeftButton")
        menu:SetScript("OnDragStart", function(self)
            self:StartMoving()
        end)
        menu:SetScript("OnDragStop", function(self)
            self:StopMovingOrSizing()
        end)
    end

    return menu, width, height
end

--[[
    Barra inferior de botones-icono, estilo base v2:
    - Botones planos de (BUTTON_SIZE - 3)px cuyo icono es la textura a pantalla
      completa (sin template que lo tape).
    - Highlight "UI-Panel-Button-Highlight" (brillo dorado) en ADD al pasar.
    - Posicionados con (i-1)*(BUTTON_SIZE+BUTTON_PADDING) y offset y = -1.
    Cada barItem: { icon, action, actionRight, tooltip, enabled, activeEvent,
    tooltipExtra }.
    - `enabled` (función o booleano) controla la visibilidad del botón: los
      deshabilitados se ocultan y el resto se reposiciona sin huecos (UpdateBar).
    - `activeEvent` (nombre de evento del bus RD) resalta el botón mientras el
      evento se publica con `true` (p.ej. AUTO_LOOT_STATE_CHANGED del modo Auto).
    - `tooltipExtra` ({ title, lines, empty } o lista de secciones) añade líneas
      dinámicas al tooltip, tras las pistas de clic: `lines()` se evalúa en cada
      hover y devuelve una lista de strings (p.ej. el seguimiento de monedas y
      objetos del botón "Jugador"). `empty` se muestra en gris si la sección no
      tiene líneas (descubrimiento).
]]
function MenuFactory:RenderBar(buttonBar, barItems, opts)
    if not buttonBar or not barItems then return end
    opts = opts or {}

    local AB = (RD.constants and RD.constants.ACTION_BAR) or {}
    local buttonSize = AB.BUTTON_SIZE or 27
    local padding = AB.BUTTON_PADDING or 2
    local btnSize = math.max(1, buttonSize - 3)

    buttonBar.rdButtons = {}
    buttonBar.rdSize = buttonSize
    buttonBar.rdPad = padding

    -- Los botones se crean en el ORDEN GUARDADO (ui.actionBar.order): el índice
    -- de la entrada coincide con la posición visual y UpdateBar reordena en vivo
    -- (mismo orden guardado) sin recrear botones.
    local orderedItems = self:OrderBarItems(barItems)
    for i, barItem in ipairs(orderedItems) do
        -- Botón plano: el icono es el fondo, sin plantilla que lo oculte
        local button = CreateFrame("Button", nil, buttonBar)
        button:SetSize(btnSize, btnSize)
        button:RegisterForClicks("AnyUp")
        button:SetPoint("LEFT", buttonBar, "LEFT", (i - 1) * (buttonSize + padding), -1)
        button:SetHighlightTexture("Interface\\Buttons\\UI-Panel-Button-Highlight", "ADD")

        if barItem.icon then
            local icon = button:CreateTexture(nil, "ARTWORK")
            icon:SetAllPoints()
            icon:SetTexture(barItem.icon)
            button.icon = icon
        end

        button:SetScript("OnClick", function(self, btn)
            -- Clic izquierdo ejecuta `action`; clic derecho ejecuta `actionRight`
            local actionId = (btn == "RightButton") and barItem.actionRight or barItem.action
            if actionId then
                pcall(function()
                    if RD.MenuActions and RD.MenuActions.Execute then
                        RD.MenuActions:Execute(actionId, { button = self, item = barItem, buttonName = btn })
                    end
                end)
            end
        end)

        button:SetScript("OnEnter", function(self)
            local tooltipEnabled = true
            if type(opts.tooltipEnabled) == "function" then
                tooltipEnabled = opts.tooltipEnabled()
            end
            if not tooltipEnabled or not barItem.tooltip then return end
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(barItem.name or "", 1, 1, 1, 1, true)
            local lines = { strsplit("\n", barItem.tooltip) }
            for _, line in ipairs(lines) do
                if line ~= "" and line ~= (barItem.name or "") then
                    GameTooltip:AddLine(line, 1, 0.82, 0, true)
                end
            end
            -- Contenido EXTRA declarativo (p.ej. el seguimiento del botón
            -- "Jugador"): barItem.tooltipExtra puede ser UNA sección
            -- { title, lines, empty } o una LISTA de secciones. Cada `lines()`
            -- se evalúa en cada hover (datos frescos, sin suscripciones ni
            -- OnUpdate). Las líneas se indentan 2 espacios bajo su cabecera
            -- dorada; entre secciones va una línea en blanco. Si una sección
            -- sale vacía y declara `empty`, se muestra el aviso en gris
            -- (descubrimiento) en vez de omitir el bloque por completo.
            local extra = barItem.tooltipExtra
            if type(extra) == "table" then
                local sections = (type(extra.lines) == "function") and { extra } or extra
                local first = true
                for _, section in ipairs(sections) do
                    if type(section) == "table" and type(section.lines) == "function" then
                        local ok, extras = pcall(section.lines)
                        if ok and type(extras) == "table" then
                            local has = #extras > 0
                            if has or (section.empty and section.empty ~= "") then
                                if not first then
                                    GameTooltip:AddLine(" ", 1, 1, 1, true)
                                end
                                first = false
                                if section.title and section.title ~= "" then
                                    GameTooltip:AddLine(section.title, 1, 0.82, 0, true)
                                end
                                if has then
                                    for _, line in ipairs(extras) do
                                        GameTooltip:AddLine("  " .. tostring(line), 0.85, 0.85, 0.9, true)
                                    end
                                else
                                    GameTooltip:AddLine("  " .. tostring(section.empty), 0.6, 0.6, 0.6, true)
                                end
                            end
                        end
                    end
                end
            end
            GameTooltip:Show()
        end)
        button:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)

        local entry = { button = button, item = barItem }
        buttonBar.rdButtons[#buttonBar.rdButtons + 1] = entry

        -- Resaltado de "activo" mientras el evento publica `true`
        if barItem.activeEvent then
            self:ApplyBarButtonActive(button, barItem.activeEvent)
        end
    end

    self:UpdateBar(buttonBar)
end

-- Resaltado de "activo" de un botón de barra: se ilumina mientras el evento del
-- bus se publica con `true` (p.ej. la sesión Auto en curso). Compartido por la
-- barra del menú flotante y la barra de la ventana de configuración.
function MenuFactory:ApplyBarButtonActive(button, activeEvent)
    if not button or not activeEvent or not RD.events or not RD.events.Subscribe then return end
    local glow = button:CreateTexture(nil, "OVERLAY")
    glow:SetAllPoints()
    glow:SetTexture("Interface\\Buttons\\UI-Panel-Button-Highlight")
    glow:SetBlendMode("ADD")
    glow:Hide()
    button.rdGlow = glow
    local function Apply(active)
        if glow then
            if active then glow:Show() else glow:Hide() end
        end
    end
    -- Estado inicial desde el módulo dueño (si existe)
    local mod = RD.modules and RD.modules.autoLoot
    if mod and mod.IsActive then
        Apply(mod:IsActive())
    end
    RD.events:Subscribe(activeEvent, Apply)
end

-- Reevalúa la visibilidad de los botones de una barra (barItem.enabled) y
-- reposiciona los visibles sin huecos. Devuelve el nº de botones visibles.
function MenuFactory:UpdateBar(buttonBar)
    if not buttonBar or not buttonBar.rdButtons then return 0 end
    local size = buttonBar.rdSize or 27
    local pad = buttonBar.rdPad or 2
    -- Orden guardado aplicado EN VIVO: reordena las entradas (posición visual)
    -- sin recrear botones. En RenderBar ya llegan ordenadas (no-op); en un
    -- reorden desde la config, las posiciones siguen al orden de ui.actionBar.order.
    buttonBar.rdButtons = self:OrderBySavedOrder(buttonBar.rdButtons,
        SavedOrder("ui.actionBar.order"),
        function(entry) return entry.item and entry.item.action end)
    local n = 0
    for _, entry in ipairs(buttonBar.rdButtons) do
        local item = entry.item
        local visible = true
        if item and item.enabled then
            if type(item.enabled) == "function" then
                local ok, v = pcall(item.enabled)
                visible = (ok and v ~= false)
            else
                visible = (item.enabled ~= false)
            end
        end
        if visible then
            n = n + 1
            entry.button:Show()
            entry.button:ClearAllPoints()
            entry.button:SetPoint("LEFT", buttonBar, "LEFT", (n - 1) * (size + pad), -1)
        else
            entry.button:Hide()
        end
    end
    local width = n > 0 and (n * (size + pad) - pad) or 0
    if buttonBar.SetWidth then
        buttonBar:SetWidth(width)
    end
    return n
end

RD.ui = RD.ui or {}
RD.ui.menuFactory = MenuFactory
return MenuFactory
