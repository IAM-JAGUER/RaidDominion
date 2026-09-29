--[[
    RD_UI_Widgets_Drag.lua
    PROPÓSITO: Reordenación por arrastre (click-drag → click-drop) para los
              editores de lista de la ventana de configuración. Sustituye a los
              botones subir/bajar: cada fila muestra un agarre (grip) que se
              pulsa y arrastra; un fantasma sigue al cursor, una línea dorada
              indica el hueco de inserción y soltar confirma el reorden.
              Compartido por CreateList, CreateContentList y CreateBands.
              Motor independiente del editor: el objetivo se calcula desde la
              geometría del scroll visible (nunca GetTop/GetBottom de filas
              ocultas, que devuelven nil en 3.3.5a con scroll).
    API PÚBLICA:
        - RD.ui.widgets:CreateGrip(parent, size)   -> botón agarre (20x20, o `size`)
        - RD.ui.widgets:EnableRowDrag(handle, params)
            params = {
                scroll, child,            -- scroll y contenido del editor
                cols, cellW, colGap,      -- geometría de la cuadrícula
                rowH, gap,                -- alto de fila y espaciado
                firstTop,                 -- distancia del top del contenido a la
                                          -- fila nº 1 (defecto: rowH+gap; en Bandas
                                          -- incluye fila de añadir + cabeceras)
                gridRows,                 -- filas de la cuadrícula (función/valor)
                source,                   -- índice original del ítem (1-based)
                itemCount = function() end, -- nº de ítems actual (función)
                label,                    -- texto del fantasma
                commitTarget = function(target) end, -- persiste el reorden
                dropZones = function() end, -- opcional: zonas de soltado inter-list
                                            -- [{ key, frame, hilite, unhilite }]
                onDropTo = function(targetKey) end, -- opcional: traslada el ítem
                                            -- a la lista del tab soltado (cross-tab)
                -- Modo FILA (anchos variables): pestañas superiores y barra de
                -- la configuración. El destino se calcula por el CENTRO real de
                -- cada ítem y la línea dorada es VERTICAL (entre elementos).
                mode = "row",
                row = frame,              -- frame que define la geometría (GetLeft/
                                          -- GetTop); también vale como `scroll`
                items = function() return { f1, f2, ... } end, -- ítems en orden visual
                rowH = 24,                -- alto de la fila (alto de la línea vertical)
            }
    EVENTOS: Ninguno directo (el editor persiste vía SaveList / RD.config:Set).
]]

local addonName, private = ...
local RD = _G.RaidDominion or {}
_G.RaidDominion = RD

RD.ui = RD.ui or {}
local Widgets = RD.ui.widgets
if not Widgets then
    Widgets = {}
    RD.ui.widgets = Widgets
end

local UniqueName = (Widgets.UniqueName) or (RD.UIUtils and RD.UIUtils.UniqueName)
local Log = (RD.UIUtils and RD.UIUtils.Log) or function(msg) print(msg) end

-- Oro del addon (línea de inserción)
local GOLD = { 1, 0.82, 0 }

-- ============================================================
-- ESTADO DEL ARRASTRE (una sola operación activa en todo el addon)
-- ============================================================
local drag = nil        -- estado actual (o nil)
local ghost = nil       -- fantasma con el nombre del ítem
local indLine = nil     -- línea dorada de inserción
local indHost = nil     -- child al que está parentada la línea
local tracker = nil     -- frame OnUpdate que sigue al cursor durante el drag
                        -- (se crea más abajo; declarado aquí por el lexical scope
                        -- de Lua 5.1: los closures lo referencian antes de crearlo)

local function EnsureGhosts()
    if ghost then return end

    ghost = CreateFrame("Frame", nil, UIParent)
    -- El fantasma de arrastre es transitorio y sigue al cursor: se mantiene por
    -- encima de las ventanas (HIGH) para no quedar cubierto durante el arrastre.
    if RD.UIUtils and RD.UIUtils.SetupWindow then
        RD.UIUtils.SetupWindow(ghost, { strata = "HIGH" })
    else
        ghost:SetFrameStrata("HIGH")
        ghost:SetToplevel(true)
        ghost:SetClampedToScreen(true)
    end
    ghost:EnableMouse(false)
    ghost:SetSize(180, 24)
    ghost:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 5, right = 5, top = 4, bottom = 4 },
    })
    ghost:SetBackdropColor(0.05, 0.05, 0.05, 0.92)
    ghost:SetBackdropBorderColor(GOLD[1], GOLD[2], GOLD[3], 0.9)
    local fsl = ghost:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fsl:SetPoint("LEFT", ghost, "LEFT", 8, 0)
    fsl:SetPoint("RIGHT", ghost, "RIGHT", -8, 0)
    fsl:SetJustifyH("LEFT")
    fsl:SetJustifyV("MIDDLE")
    fsl:SetTextColor(1, 1, 1, 1)
    ghost.label = fsl

    indLine = CreateFrame("Frame", nil, UIParent)
    indLine:SetHeight(2)
    indLine:EnableMouse(false)
    local tex = indLine:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints()
    tex:SetTexture(GOLD[1], GOLD[2], GOLD[3], 1)
end

-- Sanitiza el texto del fantasma: sin códigos de color/markup de enlace y
-- truncado, para no romper pipes sueltos en la cadena.
local function GhostLabel(raw, source)
    local text = tostring(raw or "")
    text = string.gsub(text, "|c%x%x%x%x%x%x%x%x", "")
    text = string.gsub(text, "|r", "")
    text = string.gsub(text, "%b||", "") -- |color:...| enlaces
    text = string.gsub(text, "||", "")
    if #text > 56 then text = string.sub(text, 1, 53) .. "..." end
    if text == "" then text = ("#%d"):format(source or 1) end
    return text
end

-- ============================================================
-- CÁLCULO DEL DESTINO (geometría del scroll, no de filas ocultas)
-- ============================================================

-- Devuelve (target, row, col): target es el índice flat [1, n+1] donde insertar.
local function ComputeTarget(p, x, y)
    -- Modo FILA de anchos variables (tabs superiores y barra de la config): el
    -- destino se calcula por el CENTRO real de cada ítem (no por una rejilla
    -- uniforme, que no puede resolver anchos distintos). r devuelve el propio
    -- target para que PositionIndicator dibuje la línea vertical en ese hueco.
    if p.mode == "row" then
        local items = p.items and p.items()
        if not items or #items == 0 then return p.source, 0, 0 end
        for i, f in ipairs(items) do
            if f and f.GetLeft and f.GetRight then
                local l = f:GetLeft()
                local r = f:GetRight()
                if l and r and x < (l + r) / 2 then return i, i, 0 end
            end
        end
        return #items + 1, #items + 1, 0
    end

    local scroll = p.scroll
    local n = p.itemCount and p.itemCount() or 0
    local sTop, sLeft
    if scroll and scroll.GetTop and scroll.GetLeft then
        sTop = scroll:GetTop()
        sLeft = scroll:GetLeft()
    end
    if not sTop or not sLeft or n <= 0 then
        return p.source, 0, 0
    end

    local v = (scroll.GetVerticalScroll and scroll:GetVerticalScroll()) or 0
    -- d: distancia hacia abajo desde el top del contenido (unidades UI).
    -- En 3.3.5a el cursor y GetTop comparten espacio al dividir GetCursorPosition
    -- por la escala efectiva del scroll (se hace en el tracker).
    local d = sTop - y + v

    local rowH = p.rowH or 24
    local gap = p.gap or 2
    local rowStride = rowH + gap
    -- Desplazamiento del top del contenido a la fila de ítems nº 1 (cada editor
    -- lo define en firstTop: en listas de cuadrícula es rowH+gap; en Bandas hay
    -- fila de añadir + cabeceras por encima).
    local firstTop = p.firstTop or rowStride
    local cols = p.cols or 1
    local gridRows = p.gridRows
    if type(gridRows) == "function" then gridRows = gridRows() end
    gridRows = gridRows or math.ceil(n / cols)

    -- Sobre la primera fila
    if d < firstTop then
        return 1, 0, 0
    end
    -- Debajo de la última fila (final de lista)
    local lastTop = firstTop + (gridRows - 1) * rowStride
    if d > lastTop + rowH then
        -- r = gridRows marca el hueco "bajo la última fila" para el indicador
        return n + 1, gridRows, 0
    end

    -- Fila visual bajo el cursor (incluye los huecos entre filas)
    local r
    for rr = 0, gridRows - 1 do
        local top = firstTop + rr * rowStride
        local bot = top + rowH
        if d >= top and d <= bot then
            r = rr
            break
        end
        if d > bot and d < top + rowStride then
            -- Cae en el hueco entre rr y rr+1: inserta al inicio de rr+1
            return math.min((rr + 1) * cols + 1, n + 1), rr + 1, 0
        end
    end
    if not r then r = math.max(0, gridRows - 1) end

    -- Columna según la posición horizontal
    local stride = (p.cellW or 0) + (p.colGap or 0)
    local c = 0
    if stride > 0 then
        c = math.floor((x - sLeft) / stride)
        if c < 0 then c = 0 end
        if c > cols - 1 then c = cols - 1 end
    end
    -- Clamp a las columnas reales de la fila
    local first = r * cols + 1
    local maxCol = math.min(n, first + cols - 1) - first
    if c > maxCol then c = maxCol end

    return r * cols + (c + 1), r, c
end

-- Posiciona la línea dorada sobre el hueco de inserción (fila/columna dadas)
local function PositionIndicator(p, r, c)
    if not indLine then return end
    -- Modo fila: línea VERTICAL (2px) en el borde izquierdo del ítem destino,
    -- o en el borde derecho del último si el target es el hueco final (n+1).
    if p.mode == "row" then
        local items = p.items and p.items()
        local n = (p.itemCount and p.itemCount()) or (items and #items or 0)
        if not items or n <= 0 then return end
        local row = p.row or p.child
        local rowLeft = (row and row.GetLeft and row:GetLeft()) or 0
        local xOff
        if r > n then
            local last = items[n]
            local rr = (last and last.GetRight and last:GetRight()) or rowLeft
            xOff = rr - rowLeft
        else
            local it = items[r]
            local il = (it and it.GetLeft and it:GetLeft()) or rowLeft
            xOff = il - rowLeft
        end
        if indHost ~= p.child then
            indHost = p.child
            if p.child then indLine:SetParent(p.child) end
        end
        indLine:ClearAllPoints()
        indLine:SetPoint("TOPLEFT", p.child, "TOPLEFT", xOff - 1, 0)
        indLine:SetSize(2, p.rowH or 24)
        if not indLine:IsShown() then indLine:Show() end
        return
    end
    local rowH = p.rowH or 24
    local gap = p.gap or 2
    local rowStride = rowH + gap
    local firstTop = p.firstTop or rowStride
    local gridRows = p.gridRows
    if type(gridRows) == "function" then gridRows = gridRows() end
    gridRows = gridRows or 1
    local yOff
    -- El target "final" es la posición n+1: hueco bajo la última fila
    if r >= gridRows then
        yOff = -firstTop - (gridRows - 1) * rowStride - rowH + 1
    else
        yOff = -firstTop - r * rowStride + 1
    end
    local xOff = (c or 0) * ((p.cellW or 0) + (p.colGap or 0)) - 2
    if indHost ~= p.child then
        indHost = p.child
        if p.child then indLine:SetParent(p.child) end
    end
    indLine:ClearAllPoints()
    indLine:SetPoint("TOPLEFT", p.child, "TOPLEFT", xOff, yOff)
    indLine:SetSize((p.cellW or 0) + 4, 2)
    if not indLine:IsShown() then indLine:Show() end
end

-- Auto-scroll vertical mientras el cursor se acerca a los bordes del viewport
local function AutoScroll(p, x, y)
    local scroll = p.scroll
    if not scroll or not scroll.GetTop or not scroll.GetBottom then return end
    local sTop, sBot = scroll:GetTop(), scroll:GetBottom()
    if not sTop or not sBot then return end
    local margin = 16
    local v = (scroll.GetVerticalScroll and scroll:GetVerticalScroll()) or 0
    if y > sTop - margin then
        v = v - 10
        if v < 0 then v = 0 end
    elseif y < sBot + margin then
        local maxV = 0
        if scroll.scrollBar and scroll.scrollBar.GetMinMaxValues then
            _, maxV = scroll.scrollBar:GetMinMaxValues()
        end
        v = v + 10
        if v > maxV then v = maxV end
    else
        return
    end
    if scroll.SetVerticalScroll then scroll:SetVerticalScroll(v) end
end

-- ============================================================
-- ZONAS DE SOLTADO INTER-LIST (arrastrar un ítem a OTRO tab)
-- ============================================================
-- Durante el arrastre, si el cursor cae sobre una zona registrada (p.ej. la
-- pestaña "Habilidades"), se resalta y al soltar se traslada el ítem a la lista
-- de ese tab en lugar de reordenar dentro de la misma lista.
-- La geometría se resuelve con las coordenadas del cursor en el espacio del
-- scroll (xSc, ySc): la ventana de config aplica SetScale en el frame raíz, así
-- que las pestañas (hijas del mismo árbol) comparten escala efectiva con el
-- scroll y GetTop/GetLeft de las zonas son comparables con las de ComputeTarget.

-- Devuelve la zona bajo el cursor (o nil). Cada zona:
--   { key = <clave config destino>, frame = <Frame/Button>,
--     hilite = fn()  (opcional: resalta la zona al sobrevolarla),
--     unhilite = fn() (opcional: restaura la zona al salir/soltar) }
local function ZoneUnder(p, x, y)
    local zones = p.dropZones and p.dropZones()
    if not zones then return nil end
    local zone = nil
    local best = 0
    for _, z in ipairs(zones) do
        local f = z.frame
        if f and f.GetTop then
            local top = f.GetTop and f:GetTop()
            local bottom = f.GetBottom and f:GetBottom() or (top and (top - (f:GetHeight() or 0)))
            local left = f.GetLeft and f:GetLeft()
            local right = f.GetRight and f:GetRight() or (left and (left + (f:GetWidth() or 0)))
            if top and bottom and left and right
                and y <= top and y >= bottom and x >= left and x <= right then
                -- Solo se admite si la zona es del usuario (primera que coincide);
                -- el área cubierta se usa para desempatar solapamientos.
                local area = (right - left) * (top - bottom)
                if area > best then
                    best = area
                    zone = z
                end
            end
        end
    end
    return zone
end

-- ============================================================
-- CICLO DE VIDA DEL ARRASTRE
-- ============================================================
local function ShowGhostAt(x, y)
    if not ghost then return end
    ghost:ClearAllPoints()
    ghost:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x + 12, y + 12)
    ghost:Raise()
    if not ghost:IsShown() then ghost:Show() end
end

local function EndDrag()
    if not drag then return end
    local d = drag
    drag = nil
    tracker:Hide()
    if ghost then ghost:Hide() end
    if indLine then
        indLine:Hide()
        indLine:SetParent(nil)
        indLine:ClearAllPoints()
    end
    indHost = nil
    if d.handle then d.handle.rdIsDrag = false end
    -- Restaura la zona resaltada (si el cursor la estaba sobrevolando)
    if d.hoverZone and d.hoverZone.unhilite then pcall(d.hoverZone.unhilite) end
    if d.moved and d.dropZone and d.onDropTo then
        -- Cross-tab: el ítem se TRASLADA a la lista del tab destino
        -- (onDropTo acepta la clave destino; la fuente se infiere del closure)
        local ok, err = pcall(d.onDropTo, d.dropZone)
        if not ok then
            Log("|cffff0000[RaidDominion]|r error trasladando el elemento a otra lista: " .. tostring(err))
        end
    elseif d.moved and d.commit and d.target then
        -- pcall: un error al reconstruir no debe romper el estado del addon
        local ok, err = pcall(d.commit, d.target)
        if not ok then
            Log("|cffff0000[RaidDominion]|r error reordenando la lista: " .. tostring(err))
        end
    end
end

local function StartDrag(handle, p)
    if drag then EndDrag() end
    local scale = (UIParent.GetEffectiveScale and UIParent:GetEffectiveScale()) or 1
    local x, y = GetCursorPosition()
    x, y = x / scale, y / scale
    EnsureGhosts()
    drag = {
        p = p,
        source = p.source or 1,
        handle = handle,
        scale = scale,
        sx = x,
        sy = y,
        moved = false,
        target = p.source,
        commit = p.commitTarget,
        dropZones = p.dropZones,
        onDropTo = p.onDropTo,
        dropZone = nil,
        hoverZone = nil,
    }
    handle.rdIsDrag = true
    ghost.label:SetText(GhostLabel(p.label, drag.source))
    local tw = ghost.label:GetStringWidth() or 90
    ghost:SetWidth(math.max(140, math.min(300, tw + 44)))
    tracker:Show()
end

local function OnUpdate(self, elapsed)
    if not drag then self:Hide() return end
    if not IsMouseButtonDown("LeftButton") then
        EndDrag()
        return
    end

    local p = drag.p
    local scScale = p.scroll and p.scroll.GetEffectiveScale and p.scroll:GetEffectiveScale()
    if not scScale or scScale <= 0 then scScale = UIParent:GetEffectiveScale() end
    local rx, ry = GetCursorPosition()
    -- Coordenadas en el espacio del scroll para la geometría (ComputeTarget)
    local xSc = rx / scScale
    local ySc = ry / scScale
    -- Coordenadas en el espacio de UIParent para el fantasma (parentado a él)
    local xUi = rx / drag.scale
    local yUi = ry / drag.scale

    if not drag.moved then
        local dx = xUi - drag.sx
        local dy = yUi - drag.sy
        if (dx * dx + dy * dy) < 36 then return end -- umbral ~6px antes de activar
        drag.moved = true
    end

    ShowGhostAt(xUi, yUi)

    -- Detección de zona de soltado cross-tab: si el cursor cae sobre una zona
    -- registrada (p.ej. la pestaña "Habilidades"), se resalta y el indicador de
    -- inserción de la misma lista se oculta (el destino es OTRO tab).
    local zone = drag.dropZones and ZoneUnder(drag, xSc, ySc) or nil
    drag.dropZone = zone and zone.key or nil
    if zone ~= drag.hoverZone then
        if drag.hoverZone and drag.hoverZone.unhilite then pcall(drag.hoverZone.unhilite) end
        drag.hoverZone = zone
        if zone and zone.hilite then pcall(zone.hilite) end
    end
    -- Guarda defensiva: un callback de resaltado (ratio) no debe dejar el
    -- Estado del drag a medias si acaba cancelándolo de forma reentrante en
    -- 3.3.5a (pcall re-entre a OnUpdate con cardinal cambiado).
    if not drag then return end

    if zone then
        -- Sobre una zona: sin línea de inserción de la lista origen
        if indLine and indLine.IsShown then indLine:Hide() end
        drag.target = nil
    else
        AutoScroll(p, xSc, ySc)
        if not drag then return end
        local target, r, c = ComputeTarget(p, xSc, ySc)
        if not drag then return end
        drag.target = target
        PositionIndicator(p, r, c)
    end
end

tracker = CreateFrame("Frame")
tracker:SetScript("OnUpdate", OnUpdate)
tracker:Hide()

-- ============================================================
-- API PÚBLICA
-- ============================================================

-- Agarre de arrastre: botón (por defecto 20x20) con tres barras verticales.
-- Para el usuario significa "esto se puede reordenar arrastrando". `size`
-- permite un agarre compacto (p.ej. 12px) para las pestañas y la barra de la
-- ventana de configuración.
function Widgets:CreateGrip(parent, size, tipFn)
    if not parent then return nil end
    size = size or 20
    local name = UniqueName and UniqueName("Grip") or nil
    local grip = CreateFrame("Button", name, parent)
    grip:SetSize(size, size)
    local BAR_GAP = 4
    for i = 1, 3 do
        local bar = grip:CreateTexture(nil, "ARTWORK")
        bar:SetWidth(2)
        bar:SetHeight(8)
        bar:SetPoint("CENTER", grip, "CENTER", (i - 2) * BAR_GAP, 0)
        bar:SetTexture(1, 1, 1, 0.45)
    end
    grip:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    if RD.UIUtils and RD.UIUtils.AddButtonTooltip then
        RD.UIUtils.AddButtonTooltip(grip, tipFn or function()
            return "Arrastrar para reordenar: pulsa, mueve el ratón y suelta donde quieras dejar el elemento."
        end)
    end
    return grip
end

-- Conecta el agarre a una fila concreta del editor (params, ver cabecera).
-- La función es idempotente por handle (no se re-conecta si ya está activo).
function Widgets:EnableRowDrag(handle, params)
    if not handle or not params then return nil end
    if handle.rdDragEnabled then return handle end
    handle.rdDragEnabled = true

    -- Registra el arrastre sobre el agarre: reclama el evento de drag para que la
    -- ventana de config (arrastrable) NO se mueva al arrastrar una fila, y acota
    -- el inicio/fin del arrastre del sistema (OnDragStart/OnDragStop no-op aquí;
    -- nosotros atendemos el ciclo con OnMouseDown/OnMouseUp + tracker OnUpdate).
    handle:RegisterForDrag("LeftButton")
    handle:SetScript("OnDragStart", function() end)
    handle:SetScript("OnDragStop", function(self)
        if self.rdIsDrag then EndDrag() end
    end)
    handle:SetScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" then return end
        StartDrag(self, params)
    end)
    handle:SetScript("OnMouseUp", function(self, button)
        if button ~= "LeftButton" then return end
        EndDrag()
    end)
    -- Si un rebuild/scroll oculta la fila durante el arrastre, se cancela
    handle:SetScript("OnHide", function(self)
        -- SOLO si el usuario ya soltó el botón: durante un drag activo el
        -- auto-scroll oculta la fila arrastrada (RDRefreshVisibility) y EndDrag
        -- aquí NO debe dispararse (rompería el drag y, reentrante, nil'd drag a
        -- mitad del OnUpdate → error). Con el ratón fuera, el tracker ya habría
        -- cancelado; esta rama cubre cierres de rebuild sin ratón.
        if not IsMouseButtonDown("LeftButton") then
            if self.rdIsDrag then EndDrag() end
        end
    end)
    return handle
end

return Widgets