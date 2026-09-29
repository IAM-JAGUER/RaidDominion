--[[
    RD_UI_Widgets_ItemGrid.lua
    PROPÓSITO: Rejilla de iconos (ítems de equipo) agrupada por secciones con
              cabecera, tooltips PROPIOS multi-línea y celdas interactivas (clic
              izquierdo/derecho). La usa la sección Equipamiento del editor de
              jugador (grupo Equipamiento + grupo Objetivos). Cada celda puede
              llevar un BADGE de iLvL sobre el icono (chip oscuro + número
              dorado en la esquina inferior derecha). Todos los offsets caen en
              el grid de 4px (AGENTS §6); el alto del contenido lo devuelve
              GetContentHeight para que el ScrollFrame padre lo ajuste.
    API PÚBLICA:
        - RD.ui.widgets:CreateItemGrid(parent, opts) -> grid
              opts = { width, columns?, tooltipAnchor?, onSelect(cell)?,
                       onRightSelect(cell)?, onShareLink(cell)? }
              Cada cell: { key, icon, name?, quality?, borderColor?,
                           label?,       -- texto corto sobre el icono (badge, opcional)
                           link?,        -- enlace de ítem (Mayús+clic lo inserta en el chat)
                           tooltip = { { text, r, g, b }, ... } }
        - grid:SetGroups(groups)   -> renderiza; groups = { { title, color?, items = {...} } }
        - grid:GetContentHeight()  -> alto total usado (para el ScrollFrame)
        - grid:Clear()             -> oculta todas las celdas/cabeceras
    EVENTOS: OnEnter/OnLeave de cada celda (tooltip propio, gated por
             ui.showTooltips); OnClick izq/der; OnClick con Mayús (onShareLink).
]]

local addonName, private = ...
local RD = _G.RaidDominion or {}
_G.RaidDominion = RD

-- La tabla de widgets se reutiliza si ya existe (convención RD_UI_Widgets_*).
RD.ui = RD.ui or {}
local Widgets = RD.ui.widgets
if not Widgets then
    Widgets = {}
    RD.ui.widgets = Widgets
end

local UniqueName = (RD.UIUtils and RD.UIUtils.UniqueName)
    or function(prefix) return prefix end

local DEFAULT_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

-- Geometría (grid 4px):
--  BTN      = botón cuadrado del icono (40 px)
--  INSET    = margen de la textura dentro del botón (2 px) → icono 36 px
--  SLOT     = paso horizontal entre celdas (44 px = 40 + 4 de hueco)
--  HEADER_H = alto reservado por la cabecera de grupo (20 px)
--  BADGE_W/H = indicador iLvL sobre el icono (20×12, múltiplos de 4): chip fijo
--              para que luzca idéntico con 1, 2 o 3 dígitos (luego ajustable).
local BTN = 40
local INSET = 2
local SLOT = 44
local HEADER_H = 20
local BADGE_W = 20
local BADGE_H = 12
local TEX_INSET = 0.08

-- Estado de SELECCIÓN de una celda (afordancia): fondo cálido + borde dorado,
-- distinguible del borde por calidad y del estado "meta alcanzada" (borde
-- dorado + ✓). Se aplica en Paint (build) y en grid:SetSelected (sin rebuild).
local SEL_BORDER = { 1, 0.82, 0, 1 }
local SEL_BG = { 0.2, 0.16, 0.06, 0.6 }

-- Rejilla: el widget reusa un pool de celdas y cabeceras (se recrean solo al
-- crecer) y reposiciona según SetGroups. Sin OnUpdate ni layout recursivo.
function Widgets:CreateItemGrid(parent, opts)
    if not parent then return nil end
    opts = opts or {}

    local width = opts.width or (parent.GetWidth and parent:GetWidth()) or 300
    local cols = opts.columns or math.max(1, math.floor(width / SLOT))

    local grid = CreateFrame("Frame", UniqueName("Grid"), parent)
    grid:SetSize(width, 1)
    grid:EnableMouse(false)

    local cells = {}
    local headers = {}
    local usedCells = 0
    local usedHeaders = 0
    local contentH = 0

    -- ---------------------------------------------------------------------
    -- Pool de celdas
    -- ---------------------------------------------------------------------
    local function NewCell()
        local btn = CreateFrame("Button", UniqueName("Gc"), grid)
        btn:SetSize(BTN, BTN)
        btn:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 12,
            insets = { left = 2, right = 2, top = 2, bottom = 2 },
        })
        btn:SetBackdropColor(0, 0, 0, 0.4)
        btn:SetBackdropBorderColor(1, 1, 1, 0.9)
        local tex = btn:CreateTexture(nil, "ARTWORK")
        tex:SetPoint("TOPLEFT", btn, "TOPLEFT", INSET, -INSET)
        tex:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -INSET, INSET)
        tex:SetTexture(DEFAULT_ICON)
        tex:SetTexCoord(TEX_INSET, 1 - TEX_INSET, TEX_INSET, 1 - TEX_INSET)
        btn.rdIcon = tex
        btn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
        btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")

        -- Indicador iLvL SOBRE el icono: chip oscuro translúcido con el número
        -- dorado, anclado a la esquina inferior derecha del art (no debajo).
        -- Se muestra/oculta en Paint según cell.label.
        local badge = btn:CreateTexture(nil, "OVERLAY")
        badge:SetSize(BADGE_W, BADGE_H)
        badge:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -INSET, INSET)
        -- Color plano: en 3.3.5a NO existe SetColorTexture (llegó con Cataclysm);
        -- la forma plana de la época es SetTexture(r, g, b, a). Regla en
        -- harness/rules.json (forbidden_apis) para que no vuelva a usarse.
        badge:SetTexture(0, 0, 0, 0.75)
        badge:Hide()
        btn.rdBadge = badge

        local btxt = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        btxt:SetPoint("CENTER", badge, "CENTER", 0, 0)
        btxt:SetJustifyH("CENTER")
        btxt:SetTextHeight(10)
        btxt:SetTextColor(1, 0.82, 0)
        btxt:Hide()
        btn.rdBadgeText = btxt

        btn:SetScript("OnEnter", function(self)
            local lines = self.rdTooltip
            if not lines or #lines == 0 then return end
            if RD.UIUtils and RD.UIUtils.TooltipsEnabled and not RD.UIUtils.TooltipsEnabled() then return end
            GameTooltip:SetOwner(self, opts.tooltipAnchor or "ANCHOR_RIGHT")
            GameTooltip:SetText(lines[1].text, lines[1].r, lines[1].g, lines[1].b, 1)
            for i = 2, #lines do
                GameTooltip:AddLine(lines[i].text, lines[i].r, lines[i].g, lines[i].b, 1)
            end
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", function()
            if GameTooltip then GameTooltip:Hide() end
        end)
        btn:SetScript("OnClick", function(self, button)
            local cell = self.rdCell
            if not cell then return end
            -- Mayús+clic (izq o der) = insertar el enlace del ítem en el chat activo:
            -- se antepone al resto y NO selecciona ni borra el objetivo.
            if type(IsShiftKeyDown) == "function" and IsShiftKeyDown() then
                if opts.onShareLink then opts.onShareLink(cell) end
                return
            end
            if button == "RightButton" then
                if opts.onRightSelect then opts.onRightSelect(cell) end
            elseif opts.onSelect then
                opts.onSelect(cell)
            end
        end)
        return btn
    end

    local function GetCell()
        usedCells = usedCells + 1
        local btn = cells[usedCells]
        if not btn then
            btn = NewCell()
            cells[usedCells] = btn
        end
        btn:Show()
        return btn
    end

    local function GetHeader()
        usedHeaders = usedHeaders + 1
        local h = headers[usedHeaders]
        if not h then
            h = grid:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            h:SetJustifyH("LEFT")
            h:SetTextHeight(12)
            headers[usedHeaders] = h
        end
        h:Show()
        return h
    end

    -- ---------------------------------------------------------------------
    -- Pintado de una celda
    -- ---------------------------------------------------------------------
    local function Paint(btn, cell, col, rowTop)
        btn.rdCell = cell
        btn.rdTooltip = cell.tooltip or {}
        btn.rdIcon:SetTexture(cell.icon or DEFAULT_ICON)
        -- Desaturación (gris) para iconos que no son silueta gris del paperdoll:
        -- la capa de espalda se muestra en tono gris como el resto de slots.
        if btn.rdIcon.SetDesaturated then
            btn.rdIcon:SetDesaturated(cell.desaturated or false)
        end
        local bc = cell.borderColor or { 1, 1, 1 }
        btn.rdBaseColor = { bc[1], bc[2], bc[3], 0.9 }
        if cell.selected then
            btn:SetBackdropBorderColor(SEL_BORDER[1], SEL_BORDER[2], SEL_BORDER[3], SEL_BORDER[4])
            btn:SetBackdropColor(SEL_BG[1], SEL_BG[2], SEL_BG[3], SEL_BG[4])
        else
            btn:SetBackdropBorderColor(bc[1], bc[2], bc[3], 0.9)
            btn:SetBackdropColor(0, 0, 0, 0.4)
        end
        btn:SetPoint("TOPLEFT", grid, "TOPLEFT", 4 + col * SLOT, -rowTop)
        -- Badge iLvL sobre el icono (se oculta entero si la celda no trae label).
        if cell.label then
            btn.rdBadgeText:SetText(cell.label)
            btn.rdBadge:Show()
            btn.rdBadgeText:Show()
        else
            btn.rdBadge:Hide()
            btn.rdBadgeText:Hide()
        end
        -- El botón se recoloca (ClearAllPoints previo no hace falta: un solo ancla)
    end

    -- ---------------------------------------------------------------------
    -- Render
    -- ---------------------------------------------------------------------
    local function DoClear()
        for i = 1, usedCells do
            cells[i]:Hide()
        end
        for i = 1, usedHeaders do
            headers[i]:Hide()
        end
        usedCells = 0
        usedHeaders = 0
        contentH = 0
        grid:SetHeight(1)
    end

    function grid:Clear()
        DoClear()
    end

    function grid:GetContentHeight()
        return contentH
    end

    -- Repinta la celda seleccionada (afordancia de selección) SIN reconstruir
    -- la rejilla: restaura el borde/fondo base del resto. `key` es cell.key.
    function grid:SetSelected(key)
        for i = 1, usedCells do
            local btn = cells[i]
            local cell = btn and btn.rdCell
            if cell then
                local isSel = (key ~= nil) and (cell.key == key)
                if isSel then
                    btn:SetBackdropBorderColor(SEL_BORDER[1], SEL_BORDER[2], SEL_BORDER[3], SEL_BORDER[4])
                    btn:SetBackdropColor(SEL_BG[1], SEL_BG[2], SEL_BG[3], SEL_BG[4])
                elseif btn.rdBaseColor then
                    local c = btn.rdBaseColor
                    btn:SetBackdropBorderColor(c[1], c[2], c[3], c[4])
                    btn:SetBackdropColor(0, 0, 0, 0.4)
                end
            end
        end
    end

    function grid:SetGroups(groups)
        DoClear()
        if type(groups) ~= "table" then return end

        local y = 0
        for gi = 1, #groups do
            local g = groups[gi]
            if g and type(g.items) == "table" and #g.items > 0 then
                -- Cabecera del grupo
                local h = GetHeader()
                h:SetText(g.title or "")
                h:SetPoint("TOPLEFT", grid, "TOPLEFT", 4, -y)
                local hc = g.color or { 1, 1, 1 }
                h:SetTextColor(hc[1], hc[2], hc[3])
                y = y + HEADER_H

                -- Filas de celdas: el badge vive DENTRO del icono, así que todas
                -- las filas tienen el mismo paso SLOT (ya no hay SLOT_H).
                local n = #g.items
                local rowH = SLOT
                local rows = math.max(1, math.ceil(n / cols))
                local rowTop = y
                for r = 0, rows - 1 do
                    for c = 0, cols - 1 do
                        local idx = r * cols + c + 1
                        if idx <= n then
                            local cell = g.items[idx]
                            local btn = GetCell()
                            Paint(btn, cell, c, rowTop)
                        end
                    end
                    rowTop = rowTop + rowH
                end
                y = rowTop + 4
            end
        end
        contentH = y + 4
        grid:SetHeight(contentH)
    end

    -- Geometría de la cuadrícula (QA: offsets enteros múltiplos de 4).
    grid.cellSize = BTN
    grid.slotSize = SLOT
    grid.columns = cols

    grid:SetHeight(1)
    return grid
end

return Widgets