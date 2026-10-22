--[[
    RD_UI_BandsPlayerEditor_Sections_Instances.lua
    PROPÓSITO: Sección de DATOS "Instancias" del editor de jugador. Lista
              TODAS las instancias guardadas del personaje propio con una
              presentación COMPACTA y SIN doble espaciado: cabecera FIJA con el
              CHECK GENERAL de seguimiento (fuera del scroll, siempre visible) y,
              debajo, el scroll con filas propias de DOS COLUMNAS (nombre con
              dificultad a la izquierda + meta alineada a la derecha: "reinicia
              en 2d 4h" con color de urgencia / "extendido" en gris). Las filas
              se agrupan bajo "Con reinicio (N)" / "Sin reinicio (N)" con
              interlineado compacto (15px de fila + 2px de hueco). El check
              guarda itemGoals.<key>.instancesTracked (RD_Utils_ItemGoals) y
              alimenta los tooltips del botón "Jugador" (TrackedLines) y del
              botón de minimapa (TooltipLines): ambos se OMITEN si el check está
              apagado o no hay instancias.
              La lectura EN VIVO y la normalización del campo `expires` viven en
              RD_Utils_Instances (módulo puro compartido con los tooltips y el
              snapshot del registro); esta sección solo decide la PRESENTACIÓN.
              El snapshot que viaja al portal lo proyecta Registry:Export
              (AGENTS.md §14). Refresco ante RAID_INSTANCE_INFO /
              PLAYER_ENTERING_WORLD si la sección está abierta (patrón
              RefreshOpenSection). Solo uno mismo.
              Usa los helpers compartidos de RD_UI_BandsPlayerEditor_Sections_Grids
              (que DEBE cargarse antes en el .toc) vía RD.ui.playerEditorSectionsGrids.Helpers.
    API PÚBLICA:
        - RD.ui.playerEditorSectionsInstances:Build(container, ed, width, height)
        - RD.ui.playerEditorSectionsInstances:TooltipLines() -> { {text,r,g,b}, ... } | nil
        - RD.ui.playerEditorSectionsInstances:TrackedLines() -> { string, ... } | {}
        - RD.ui.playerEditorSectionsInstances:IsTracking()  -> bool
        - RD.ui.playerEditorSectionsInstances.FormatRemaining(seg) -> "2d 4h"
    EVENTOS consumidos: RAID_INSTANCE_INFO, PLAYER_ENTERING_WORLD (refresco de
                        la sección abierta; registro perezoso en el primer Build).
]]

local addonName, private = ...
local RD = _G.RaidDominion or {}
_G.RaidDominion = RD

RD.ui = RD.ui or {}
local Instances = {}

-- Helpers compartidos de rejilla (RD_UI_BandsPlayerEditor_Sections_Grids, carga
-- anterior en el .toc). Se resuelven en tiempo de Build con fallbacks locales
-- (patrón de la sección Monedas) para no depender del orden del .toc.
local function H()
    local g = RD.ui and RD.ui.playerEditorSectionsGrids and RD.ui.playerEditorSectionsGrids.Helpers
    return g or {}
end
local CleanExtras = H().CleanExtras or function(container)
    container.rdGridExtras = {}
end
local Track = H().Track or function(container, frame)
    container.rdGridExtras = container.rdGridExtras or {}
    container.rdGridExtras[#container.rdGridExtras + 1] = frame
end
local ShowMessage = H().ShowMessage or function(container, width, text, color)
    local fs = container:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetText(text)
    fs:SetTextColor(color[1], color[2], color[3])
    fs:SetPoint("TOPLEFT", container, "TOPLEFT", 4, 0)
    fs:SetWidth((width or 300) - 8)
    fs:SetWordWrap(true)
end
-- Métricas compartidas (grid 4px): el MISMO contrato de equip/monedas.
local Metrics = H().Metrics
    or (RD.UIUtils and RD.UIUtils.Metrics)
    or { GRID = 4, PAD = 4, TRACK_S = 20, TRACK_GAP = 4 }
local PAD = Metrics.PAD or 4
local TRACK_S = Metrics.TRACK_S or 20
local UniqueName = (RD.UIUtils and RD.UIUtils.UniqueName)
    or function(prefix) return "RD" .. tostring(prefix) end
local ApplyFontStyle = (RD.UIUtils and RD.UIUtils.ApplyFontStyle) or function() end
local TruncateToWidth = H().TruncateToWidth
    or function(text, width, size)
        return tostring(text or "")
    end
local AddButtonTooltip = (RD.UIUtils and RD.UIUtils.AddButtonTooltip) or function() end

-- Util compartido (RD_Utils_Instances). Carga DESPUÉS de esta UI en el .toc,
-- por eso se resuelve en tiempo de llamada (mismo patrón que la sección
-- Monedas con RD.utils.currencies).
local function InUtils()
    return RD.utils and RD.utils.instances
end

-- Momento de referencia "ahora" (hora del servidor; ver RD_Utils_Instances).
local function Now()
    local util = InUtils()
    if util then return util:Now() end
    return time()
end

-- Texto de cuenta atrás: "2d 4h" / "5h 20m" / "12m" / "ahora". API pública
-- conservada: delega en el util compartido.
function Instances.FormatRemaining(secs)
    local util = InUtils()
    if util then return util:FormatRemaining(secs) end
    return "ahora"
end

-- Color de la meta por urgencia (segundos restantes).
local function MetaColor(secs)
    if not secs then return { 0.7, 0.7, 0.7 } end
    if secs < 3600 then return { 1, 0.5, 0.5 } end
    if secs < 86400 then return { 1, 0.82, 0 } end
    return { 0.7, 0.7, 0.7 }
end

-- Color a hex inline para |cffRRGGBB (el FontString de 3.3.5a sí parsea |c/|r).
local function Hex(r, g, b)
    return string.format("%02x%02x%02x",
        math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
end

-- Nombre visible de una fila: "Nombre (25H)" sin el prefijo de viñeta (la viñeta
-- queda solo para los tooltips). Fuente única de la presentación de filas.
local function NameText(e)
    local label = e.name
    if e.tag then label = label .. " (" .. e.tag .. ")" end
    return label
end

-- Meta de una fila (texto + color): "reinicia en 2d 4h" (urgencia) o
-- "extendido" (gris). nil => sin meta (fila libre).
local function MetaOf(e)
    if e.extended then
        return "extendido", 0.55, 0.55, 0.55
    end
    if e.rem then
        local c = MetaColor(e.rem)
        return "reinicia en " .. Instances.FormatRemaining(e.rem), c[1], c[2], c[3]
    end
    return nil
end

-- Texto de UNA línea para los tooltips (dict {text,r,g,b}): viñeta + nombre +
-- meta en color inline. Es la presentación "lista" que ven el minimapa y el
-- botón "Jugador" (no la de dos columnas de la sección).
local function RowText(e)
    local label = "• " .. NameText(e)
    local meta, r, g, b = MetaOf(e)
    if meta then
        return label .. " · |cff" .. Hex(r, g, b) .. meta .. "|r"
    end
    return label
end

-- Enumeración y separación: delegan en el util compartido (RD_Utils_Instances).
-- Sin el util (instalación desincronizada) no hay datos que pintar.
local function CollectEntries(now)
    local util = InUtils()
    if not util then return {} end
    return util:Collect(now)
end

local function SplitEntries(entries)
    local util = InUtils()
    if not util then return {}, {} end
    return util:Split(entries)
end

-- ---------------------------------------------------------------------------
-- Refresco de la sección abierta ante cambios de reinicios. Registro perezoso
-- en el primer Build; el handler sale con 2 comparaciones si el editor está
-- cerrado o no está en la pestaña (coste despreciable, sin OnUpdate).
-- ---------------------------------------------------------------------------
local eventFrame = nil
local function EnsureEvents()
    if eventFrame then return eventFrame end
    eventFrame = CreateFrame("Frame", nil)
    local function Refresh()
        local pe = RD.ui and RD.ui.playerEditor
        if not pe or not pe.GetFrame then return end
        local ed = pe:GetFrame()
        if not ed or not ed.IsShown or not ed:IsShown() or not ed.SwitchTo then return end
        if ed.openSection ~= "instances" then return end
        ed:SwitchTo("instances")
    end
    eventFrame:RegisterEvent("RAID_INSTANCE_INFO")
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    eventFrame:SetScript("OnEvent", Refresh)
    return eventFrame
end

-- ---------------------------------------------------------------------------
-- Render
-- ---------------------------------------------------------------------------

-- Geometría (grid 4px; enteros). Interlineado COMPACTO: fila 15px para fuente
-- de 12px + hueco 2px = 17px por fila (antes 16px de slot + 4px de hueco = 20px
-- para la MISMA fuente: era el "doble espaciado"). Cabeceras agrupadas.
-- HEAD_H es el mínimo de la cabecera FIJA: su alto real se calcula en Build
-- según las líneas que ocupe la etiqueta (con anchos pequeños envuelve a 2) más
-- HEAD_GAP de aire; sin ese margen la 2ª línea pisaba el título del scroll.
local HEAD_H = 24           -- cabecera FIJA (check general), fuera del scroll
local HEAD_GAP = 12         -- aire mínimo entre la cabecera FIJA y su contenido
local TITLE_H = 20          -- "Instancias guardadas (N)" (fuente 15px + aire)
local GROUP_H = 16          -- cabecera de grupo ("Con reinicio (N)" / "Sin reinicio (N)")
local ROW_H = 15            -- fila de instancia (fuente 12px)
local ROW_GAP = 2           -- hueco entre filas DENTRO del grupo
local GROUP_GAP = 4         -- aire extra tras cada grupo
local META_GAP = 6          -- hueco entre el nombre y la meta de la columna derecha

function Instances:Build(container, ed, width, height)
    local Hh = H()
    local MakeScroll = Hh.MakeScroll
    CleanExtras(container)
    width = width or ((container and container:GetWidth()) or 396) - 24

    if not ed or not ed.isSelf then
        ShowMessage(container, width, "Solo visible para tu propio personaje.", { 0.7, 0.7, 0.7 })
        return
    end

    EnsureEvents()
    local entries = CollectEntries(Now())

    -- ----- Cabecera FIJA (fuera del scroll): check GENERAL de seguimiento -----
    -- El check guarda itemGoals.<key>.instancesTracked y decide si las
    -- instancias aparecen en los tooltips de "Jugador" y del minimapa. El toggle
    -- NO reconstruye la lista (respeta scroll): su estado lo muestra el check.
    local goals = RD.utils and RD.utils.itemGoals
    local header = CreateFrame("Frame", nil, container)
    header:SetSize(width, HEAD_H)
    header:SetPoint("TOPLEFT", container, "TOPLEFT", 0, 0)
    Track(container, header)

    local labelText = "Seguimiento: instancias en el tooltip del botón Jugador"
    local labelW = math.max(40, width - 2 * PAD - TRACK_S - PAD - 8)
    local label = header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetJustifyH("LEFT")
    ApplyFontStyle(label, "contentText")
    label:SetText(labelText)
    label:SetTextColor(0.75, 0.75, 0.75)
    label:SetPoint("TOPLEFT", header, "TOPLEFT", PAD, -6)
    label:SetWidth(labelW)

    -- Alto de la cabecera DINÁMICO (§6.4) con AIRE GARANTIZADO: la etiqueta
    -- envuelve a 2 líneas con el ancho del editor y su 2ª línea pisaba el título
    -- del scroll ("Instancias guardadas (N)"). El alto se estima SIEMPRE con la
    -- heurística de ancho medio (0.55 × tamaño, la misma de TruncateToWidth) y
    -- se toma el MAYOR entre medición y estimación: GetStringHeight puede
    -- devolver una sola línea con el layout diferido de 3.3.5a aunque el texto
    -- acabe envolviendo (era la causa de que el piso continuara). Entre la
    -- etiqueta y el contenido se reservan HEAD_GAP px de aire (≥ 12 pedidos).
    local cpl = math.max(1, math.floor(labelW / (12 * 0.55)))
    local estH = math.max(1, math.ceil(#labelText / cpl)) * 15
    local measuredH = label.GetStringHeight and label:GetStringHeight() or 0
    local labelH = math.max(estH, measuredH or 0)
    local headH = math.max(HEAD_H, 6 + math.floor(labelH + 0.5) + HEAD_GAP)
    headH = math.ceil(headH / 4) * 4
    header:SetSize(width, headH)

    local track = CreateFrame("CheckButton", UniqueName("InstTrk"), header, "UICheckButtonTemplate")
    track:SetSize(TRACK_S, TRACK_S)
    track:SetPoint("RIGHT", header, "RIGHT", -PAD, 0)
    track:SetChecked((goals and goals.IsInstancesTracked and goals:IsInstancesTracked()) == true)
    track:RegisterForClicks("LeftButtonUp")
    track:SetScript("OnClick", function(self)
        local checked = self:GetChecked()
        local value = (checked == true) or (checked == 1)
        if goals and goals.SetInstancesTracked then
            goals:SetInstancesTracked(value)
        end
    end)
    AddButtonTooltip(track, function()
        return "Check = seguimiento de instancias.\nAparecen en el tooltip del botón Jugador y en el del minimapa.\nViene ACTIVADO por defecto; quítalo si no quieres ese bloque."
    end)
    header.rdTrack = track

    -- El check de seguimiento es SIEMPRE visible (para el personaje propio): sin
    -- instancias guardadas se muestra el aviso bajo la cabecera y NO se arma el
    -- scroll, pero el usuario ya puede activar/desactivar el seguimiento.
    if #entries == 0 then
        local msg = container:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        msg:SetJustifyH("LEFT")
        ApplyFontStyle(msg, "contentText")
        msg:SetText("No hay mazmorras ni bandas guardadas.")
        msg:SetTextColor(0.7, 0.7, 0.7)
        msg:SetPoint("TOPLEFT", container, "TOPLEFT", PAD, -headH)
        msg:SetWidth(width - 2 * PAD)
        msg:SetWordWrap(true)
        Track(container, msg)
        container.rdInstanceData = { count = 0, title = "Instancias guardadas (0)", rows = {}, groups = {} }
        return
    end

    -- ----- Scroll con filas propias (2 columnas: nombre izq + meta der.) -----
    local scrollH = math.max(40, (height or 300) - headH)
    local scroll, content
    if MakeScroll then
        scroll, content = MakeScroll(container, width, scrollH, headH, 0)
    else
        scroll = CreateFrame("ScrollFrame", nil, container)
        scroll:SetSize(width, scrollH)
        scroll:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -headH)
        content = CreateFrame("Frame", nil, scroll)
        content:SetWidth(width)
        scroll:SetScrollChild(content)
        Track(container, scroll)
    end

    local pending, free = SplitEntries(entries)
    local data = { count = #entries, title = "Instancias guardadas (" .. #entries .. ")", rows = {}, groups = {} }
    local y = 0
    local rowIdx = 0

    -- Cabecera: contador total (dorado).
    local title = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    ApplyFontStyle(title, "sectionTitle")
    title:SetJustifyH("LEFT")
    title:SetText("Instancias guardadas (" .. #entries .. ")")
    title:SetTextColor(1, 0.82, 0)
    title:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, -y)
    title:SetWidth(width - 2 * PAD)
    y = y + TITLE_H

    -- Fila de una instancia: nombre (truncado para dejar sitio a la meta) +
    -- meta alineada a la derecha con su color de urgencia.
    local function EmitRow(e, group)
        local meta, mr, mg, mb = MetaOf(e)
        local metaFS = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        metaFS:SetJustifyH("LEFT")
        ApplyFontStyle(metaFS, "contentText")
        local metaW = 0
        if meta then
            metaFS:SetText(meta)
            metaFS:SetTextColor(mr, mg, mb)
            metaW = (metaFS.GetStringWidth and (metaFS:GetStringWidth() or 0))
                or (#meta * 6)
        else
            metaFS:SetText("")
        end
        metaFS:SetPoint("TOPRIGHT", content, "TOPRIGHT", -PAD, -y)
        metaFS:SetWidth(math.floor(metaW + 0.5))

        local nameW = math.max(20, width - 2 * PAD - math.floor(metaW + 0.5) - META_GAP)
        local name = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        name:SetJustifyH("LEFT")
        ApplyFontStyle(name, "contentText")
        name:SetText(TruncateToWidth(NameText(e), nameW, 12))
        if e.rem then
            name:SetTextColor(1, 1, 1)
        else
            name:SetTextColor(0.55, 0.55, 0.55)
        end
        name:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, -y)
        name:SetWidth(nameW)

        rowIdx = rowIdx + 1
        data.rows[rowIdx] = {
            name = e.name,
            tag = e.tag,
            meta = meta,
            rem = e.rem,
            extended = e.extended,
            free = not e.rem,
            y = y,
            group = group,
        }
        y = y + ROW_H + ROW_GAP
    end

    local function EmitGroup(titleText, groupKey, list)
        local g = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        ApplyFontStyle(g, "hint")
        g:SetJustifyH("LEFT")
        g:SetText(titleText .. " (" .. #list .. ")")
        g:SetTextColor(0.9, 0.72, 0.25)
        g:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, -y)
        g:SetWidth(width - 2 * PAD)
        y = y + GROUP_H
        local first = rowIdx + 1
        for _, e in ipairs(list) do
            EmitRow(e, groupKey)
        end
        data.groups[#data.groups + 1] = { key = groupKey, title = titleText, first = first, last = rowIdx }
        y = y + GROUP_GAP
    end

    if #pending > 0 then
        EmitGroup("Con reinicio", "pending", pending)
    end
    if #free > 0 then
        EmitGroup("Sin reinicio", "free", free)
    end

    content:SetHeight(math.max(10, y + 4))
    if scroll.UpdateScrollChildRect then scroll:UpdateScrollChildRect() end
    if scroll.SetVerticalScroll then scroll:SetVerticalScroll(0) end

    -- Datos estructurados (los consumen los tests/harness, patrón rdCurrencyData).
    container.rdInstanceData = data
    container.rdInstanceScroll = scroll
end

-- ---------------------------------------------------------------------------
-- Líneas para los tooltips (minimapa y botón "Jugador")
-- ---------------------------------------------------------------------------

-- ¿Seguimiento activo? El check GENERAL de la sección (instancesTracked). Sin
-- el flag (o sin el módulo de objetivos cargado) no se muestran instancias en
-- los tooltips.
function Instances:IsTracking()
    local goals = RD.utils and RD.utils.itemGoals
    return (goals and goals.IsInstancesTracked and goals:IsInstancesTracked()) == true
end

-- Líneas listas para GameTooltip (dicts {text,r,g,b}): instancias guardadas
-- formateadas como la sección (con reloj primero, dificultad y cuenta atrás).
-- SOLO si el check de seguimiento está marcado; si no, nil (bloque omitido).
-- El cap evita un tooltip inmanejable con decenas de entradas. El bloque ya
-- recibe su título del llamador ("Seguimiento de instancias:"), así que aquí
-- NO se emite cabecera propia (el contador vive en la pestaña del editor).
local MAX_TOOLTIP_LINES = 12
function Instances:TooltipLines()
    if not self:IsTracking() then return nil end
    local entries = CollectEntries(Now())
    if #entries == 0 then return nil end

    local pending, free = SplitEntries(entries)
    local lines = {}

    local shown = 0
    for _, e in ipairs(pending) do
        if shown >= MAX_TOOLTIP_LINES then break end
        lines[#lines + 1] = { text = RowText(e), r = 1, g = 1, b = 1 }
        shown = shown + 1
    end
    for _, e in ipairs(free) do
        if shown >= MAX_TOOLTIP_LINES then break end
        lines[#lines + 1] = { text = RowText(e), r = 0.55, g = 0.55, b = 0.55 }
        shown = shown + 1
    end
    if #entries > shown then
        lines[#lines + 1] = {
            text = (RD.UIUtils and RD.UIUtils.TruncHint and RD.UIUtils.TruncHint(#entries - shown))
                or ("|cff808080… y " .. (#entries - shown) .. " más|r"),
            r = 1, g = 1, b = 1,
        }
    end
    return lines
end

-- Líneas como STRINGS para el tooltip del botón "Jugador" (tooltipExtra de
-- RD_Constants; el render de MenuFactory las indentaba): extrae el texto de
-- TooltipLines (los códigos |c inline se conservan). Vacío si el check está
-- apagado o no hay instancias (la sección se omite, sin aviso "empty").
function Instances:TrackedLines()
    if not self:IsTracking() then return {} end
    local lines = self:TooltipLines()
    if not lines then return {} end
    local out = {}
    for _, l in ipairs(lines) do
        out[#out + 1] = l.text
    end
    return out
end

RD.ui.playerEditorSectionsInstances = Instances
return Instances