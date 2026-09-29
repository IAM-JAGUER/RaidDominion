--[[
    RD_UI_Widgets_IconTabs.lua
    PROPÓSITO: Tira vertical de iconos tipo "pestañas de folder" sobre el borde
              derecho de un frame padre, con un REBORDE (backdrop) que envuelve
              al grupo de iconos. Sustituye a los acordeones/pills de texto:
              cada sección es un botón cuadrado de 28px con un icono del juego
              (24px) y tooltip propio; la pestaña activa se resalta con el
              borde/fondo dorado de UIUtils.PaintTabButton. Definida POR DATOS
              (filosofía AGENTS.md §7): el orden de la lista es el orden de arriba
              abajo y la posición Y se pila en la cuadrícula de 4px.
              El grupo (reborde) sobresale `overhang` px hacia FUERA del borde
              derecho del padre (estética de folder); con `overhang` igual al
              ancho del grupo (icono + 2*pad) la tira queda íntegramente fuera
              del padre, sin invadir su contenido. Con `overhang` MENOR que el
              ancho del grupo la tira SOLAPA al padre por (ancho - overhang) px:
              el modo "pegada" (los dos backdrops se tocan). El caller debe
              garantizar la holgura horizontal de su contenido (p.ej. la barra
              de scroll); el frame de la tira es EnableMouse(true), absorbe el clic y no
              lo deja pasar a lo de debajo (no roba el arrastre del borde).
    API PÚBLICA:
        - RD.ui.widgets:CreateIconTabStrip(parent, defs, opts) -> strip
              defs = { { key, icon, label, tip }, ... }
              opts = {
                  size          = 28   (botón, cuadrado)
                  gap           = 4    (separación vertical, grid 4px)
                  pad           = 4    (reborde alrededor del grupo, grid 4px)
                  overhang      = size + 2*pad (px del borde derecho del PADRE al
                                 borde del grupo; por defecto la tira sobresale
                                 ÍNTEGRA, sin invadir el contenido del padre.
                                 Menor que el ancho del grupo => tira "pegada"
                                 (solape ancho - overhang). Grid 4px: múltiplo de 4.)
                  x, y          = 0, -40 (ancla TOPRIGHT del strip en el padre)
                  onSelect      = fn(key)
                  isVisible     = fn(key) -> bool   (filtro dinámico, p.ej. selfOnly)
                  tooltipAnchor = "ANCHOR_LEFT"      (por defecto, para el borde derecho)
              }
              strip:SetActive(key)   -- repinta activo/inactivo (sin callback)
              strip:Refresh()        -- re-aplica isVisible y reflow vertical
              strip.keys             -- { key, ... } en orden visible
    EVENTOS: Ninguno. Solo OnClick de cada botón.
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

-- Ajuste de recorte del icono: con texcoords recortados el borde del icono no
-- se "come" el del botón (convención estándar de WoW para iconos en botones).
local TEX_INSET = 0.08

-- Estados del icono: activo a color pleno, inactivo atenuado.
local ACTIVE_VERTEX = { 1, 1, 1 }
local INACTIVE_VERTEX = { 0.55, 0.55, 0.55 }

-- Backdrop del reborde del grupo (mismo estilo que la ventana: fondo oscuro y
-- borde claro; edgeSize menor para no comerse los iconos de 28px).
local REBORDE = {
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 8,
    insets = { left = 2, right = 2, top = 2, bottom = 2 },
}

-- ============================================================================
-- Crea la tira y devuelve su API
-- ============================================================================

function Widgets:CreateIconTabStrip(parent, defs, opts)
    if not parent or type(defs) ~= "table" then return nil end
    opts = opts or {}

    local size = opts.size or 28
    local gap = opts.gap or 4
    local pad = opts.pad or 4
    -- Por defecto overhang = ancho del grupo: la tira sobresale ÍNTEGRA y no
    -- invade el contenido del padre. Con overhang MENOR, el frame solapa al
    -- padre (ancho - overhang) px ("pegada"); el caller valida la holgura.
    local overhang = opts.overhang or (size + 2 * pad)
    local x = opts.x or 0
    local y = opts.y or -40

    local strip = CreateFrame("Frame", UniqueName("Tabs"), parent)
    -- EnableMouse(true): el contenedor del folder NO deja pasar el clic a lo que
    -- haya debajo (la ventana u otros frames), pedido UX. Los botones hijos (sí
    -- clicables) reciben su clic por estar encima; el área del folder solo
    -- "absorbe" el clic (sin OnClick propio), así que ya no arrastra el editor
    -- si se agarra por la tira (el borde de la ventana sigue arrastrable).
    strip:EnableMouse(true)
    -- Reborde que envuelve al grupo de iconos (estilo ventana, borde claro).
    strip:SetBackdrop(REBORDE)
    strip:SetBackdropColor(0, 0, 0, 0.85)
    strip:SetBackdropBorderColor(1, 1, 1, 0.5)
    -- El strip mide el grupo (size + 2*pad de ancho); el alto se ajusta en
    -- Refresh según los botones visibles. El ancla TOPRIGHT lleva x + overhang:
    -- overhang es la distancia del borde derecho del PADRE al borde del grupo.
    strip:SetSize(size + 2 * pad, 1)
    strip:SetPoint("TOPRIGHT", parent, "TOPRIGHT", x + overhang, y)
    strip.rdTabs = {}

    -- ---------------------------------------------------------------------
    -- Construcción de cada botón (una sola vez)
    -- ---------------------------------------------------------------------
    local function BuildButton(def, i)
        local btn = CreateFrame("Button", UniqueName("Tb"), strip)
        btn:SetSize(size, size)
        -- Backdrop imprescindible para PaintTabButton (borde/fondo dorado).
        btn:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 12,
            insets = { left = 2, right = 2, top = 2, bottom = 2 },
        })
        btn:SetBackdropColor(0.1, 0.1, 0.1, 0.75)
        btn:SetBackdropBorderColor(1, 0.82, 0, 0.4)
        -- Icono del juego, recortado para no comerse el borde del botón.
        local tex = btn:CreateTexture(nil, "ARTWORK")
        tex:SetPoint("TOPLEFT", btn, "TOPLEFT", 2, -2)
        tex:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -2, 2)
        tex:SetTexture(def.icon or DEFAULT_ICON)
        tex:SetTexCoord(TEX_INSET, 1 - TEX_INSET, TEX_INSET, 1 - TEX_INSET)
        btn.rdIcon = tex
        btn:SetHighlightTexture("Interface\\Buttons\\ButtonHilt-Square", "ADD")
        -- Anclas: dentro del reborde (TOPLEFT con pad) y Y en pila vertical.
        btn:SetPoint("TOPLEFT", strip, "TOPLEFT", pad, -(pad + (i - 1) * (size + gap)))
        -- Tooltip gateado por ui.showTooltips, abre hacia la IZQUIERDA (la tira
        -- está en el borde derecho; ANCHOR_RIGHT la sacaría de pantalla).
        if RD.UIUtils and RD.UIUtils.AddButtonTooltip then
            RD.UIUtils.AddButtonTooltip(btn, function()
                return def.tip or def.label or ""
            end, opts.tooltipAnchor or "ANCHOR_LEFT")
        end
        btn:SetScript("OnClick", function()
            if opts.onSelect then opts.onSelect(def.key) end
        end)
        return btn
    end

    -- Crea todos los botones (defs es estable; solo cambia la visibilidad).
    for i, def in ipairs(defs) do
        strip.rdTabs[def.key] = BuildButton(def, i)
    end

    -- ---------------------------------------------------------------------
    -- Repintado de estado activo/inactivo
    -- ---------------------------------------------------------------------
    function strip:SetActive(key)
        for _, def in ipairs(defs) do
            local btn = strip.rdTabs[def.key]
            if btn then
                local visible = (not opts.isVisible) or opts.isVisible(def.key)
                local active = (def.key == key) and visible
                if RD.UIUtils and RD.UIUtils.PaintTabButton then
                    RD.UIUtils.PaintTabButton(btn, active)
                end
                local v = active and ACTIVE_VERTEX or INACTIVE_VERTEX
                if btn.rdIcon and btn.rdIcon.SetVertexColor then
                    btn.rdIcon:SetVertexColor(v[1], v[2], v[3])
                end
            end
        end
    end

    -- Re-aplica la visibilidad (isVisible), re-pila vertical SOLO los botones
    -- visibles (sin huecos) y ajusta el alto del reborde al grupo. Devuelve la
    -- lista de keys visibles en orden.
    function strip:Refresh()
        local visible = {}
        for _, def in ipairs(defs) do
            local show = (not opts.isVisible) or opts.isVisible(def.key)
            local btn = strip.rdTabs[def.key]
            if btn then
                if show then
                    btn:ClearAllPoints()
                    btn:SetPoint("TOPLEFT", strip, "TOPLEFT", pad, -(pad + #visible * (size + gap)))
                    btn:Show()
                    visible[#visible + 1] = def.key
                else
                    btn:Hide()
                end
            end
        end
        local groupH = #visible * (size + gap) - gap + 2 * pad
        strip:SetHeight(math.max(size + 2 * pad, groupH))
        strip.keys = visible
        return visible
    end

    -- Geometría de la cuadrícula (QA: offsets enteros múltiplos de 4).
    strip.size = size
    strip.gap = gap
    strip.pad = pad
    strip.overhang = overhang

    -- Alto inicial del reborde (se ajusta en cada Refresh).
    strip:SetHeight(math.max(size + 2 * pad, #defs * (size + gap) - gap + 2 * pad))

    return strip
end

return Widgets