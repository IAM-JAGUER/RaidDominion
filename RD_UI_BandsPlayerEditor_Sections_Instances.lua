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
              El dato viene EN VIVO de GetSavedInstanceInfo (no se persiste;
              contrato SV del portal sin cambios). ROBUSTO a la semántica del
              campo expires: en el API estándar 3.3.5a es una ÉPOCA absoluta;
              en este servidor (UltimoWoW, como lee SavedInstances) es un OFFSET
              relativo de segundos restantes — se detecta y normaliza. La cuenta
              atrás usa GetServerTime() (fallback time()), inmune a la zona
              horaria del SO. La enumeración es por GetSavedInstanceInfo hasta
              nil (tope de seguridad), NO por GetNumSavedInstances: el contador
              de la cabecera coincide siempre con la lista visible.
              Refresco ante RAID_INSTANCE_INFO / PLAYER_ENTERING_WORLD si la
              sección está abierta (patrón RefreshOpenSection). Solo uno mismo.
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

-- Momento de referencia "ahora": hora del SERVIDOR (época absoluta; inmune a la
-- zona horaria del SO, que era la fuente del día equivocado con date() local).
local function Now()
    if GetServerTime then
        local t = GetServerTime()
        if type(t) == "number" and t > 0 then return t end
    end
    return time()
end

-- El campo `expires` de GetSavedInstanceInfo varía según el cliente/servidor:
-- en el API estándar 3.3.5a es una ÉPOCA absoluta (segundos Unix); en este
-- servidor (UltimoWoW) es un OFFSET relativo de segundos restantes (SavedInstances
-- hace `expires + time()`). Se DETECTA el formato y se devuelven los segundos
-- restantes hasta el reinicio, o nil si no hay reloj válido (expires 0,
-- negativo o ya pasado) — elimina el bug de la "época 0" y las fechas sin
-- sentido.
local function ResolveReset(expires, now)
    if type(expires) ~= "number" or expires <= 0 then return nil end
    local remaining
    if expires > 1e8 then
        -- Época absoluta real (>= ~1973): el reinicio menos el ahora.
        remaining = expires - now
    else
        -- Offset relativo: el reinicio está a `expires` segundos.
        remaining = expires
    end
    if remaining <= 0 then return nil end
    return remaining
end

-- Etiqueta corta de dificultad: "25H" / "10" / "5H" / "40" / "N". PRIORIZA el
-- diffname localizado del API (este servidor lo devuelve), derivando el tamaño
-- (5/10/25/40) y el sufijo heroico; si no hay diffname, usa un mapa
-- CONSERVADOR de diff+raid solo con valores inequívocos (no pintar un tamaño
-- de banda erróneo). nil => sin etiqueta.
local RAID_DIFF_FALLBACK = { [3] = "25", [5] = "25H", [6] = "40", [9] = "40" }
local DUNGEON_DIFF_FALLBACK = { [1] = "5" }
local function DifficultyTag(diff, raid, diffname)
    if diffname and diffname ~= "" then
        local n = diffname:match("(%d+)")
        local hero = (diffname:lower():find("hero", 1, true) ~= nil)
        if n then
            return n .. (hero and "H" or "")
        end
        if hero then return "H" end
        if diffname:find("Normal", 1, true) or diffname:find("Normale", 1, true) then
            return "N"
        end
    end
    if type(diff) == "number" then
        if raid then
            local t = RAID_DIFF_FALLBACK[diff]
            if t then return t end
        end
        local t = DUNGEON_DIFF_FALLBACK[diff]
        if t then return t end
    end
    return nil
end

-- Texto de cuenta atrás: "2d 4h" / "5h 20m" / "12m" / "ahora".
function Instances.FormatRemaining(secs)
    secs = math.floor(tonumber(secs) or 0)
    if secs <= 0 then return "ahora" end
    local days = math.floor(secs / 86400)
    local hours = math.floor((secs % 86400) / 3600)
    local mins = math.floor((secs % 3600) / 60)
    if days > 0 then
        if hours > 0 then return string.format("%dd %dh", days, hours) end
        return string.format("%dd", days)
    end
    if hours > 0 then
        if mins > 0 then return string.format("%dh %dm", hours, mins) end
        return string.format("%dh", hours)
    end
    return string.format("%dm", math.max(1, mins))
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

-- Tope de seguridad para la enumeración (el API termina con nil; el cap evita
-- bucear sin límite en clientes raros).
local MAX_INSTANCES = 60

-- Enumeración de TODAS las instancias guardadas (con y sin reloj): se lee
-- GetSavedInstanceInfo hasta que devuelva nil, NO GetNumSavedInstances (el
-- contador coincide siempre con la lista). Leemos los 10 retornos de este
-- cliente (diffname y raid incluidos); un cliente estándar de 5 retornos deja
-- los extras en nil y el código los tolera. Compartido por la sección y los
-- tooltips.
local function CollectEntries(now)
    local entries = {}
    for i = 1, MAX_INSTANCES do
        local name, id, expires, diff, locked, extended, mostsig, raid, players, diffname =
            GetSavedInstanceInfo(i)
        if not name or name == "" then break end
        local rem
        if locked then
            rem = ResolveReset(expires, now)
        end
        entries[#entries + 1] = {
            name = name,
            rem = rem,
            extended = extended and true or false,
            tag = DifficultyTag(diff, raid, diffname),
        }
    end
    return entries
end

-- Separa instancias con reloj pendiente del resto y las ordena: con reloj
-- primero por el más próximo (desempate por nombre; table.sort en Lua 5.1 NO
-- es estable), el resto después por nombre.
local function SplitEntries(entries)
    local pending, free = {}, {}
    for _, e in ipairs(entries) do
        if e.rem then pending[#pending + 1] = e else free[#free + 1] = e end
    end
    table.sort(pending, function(a, b)
        if a.rem ~= b.rem then return a.rem < b.rem end
        return a.name < b.name
    end)
    table.sort(free, function(a, b) return a.name < b.name end)
    return pending, free
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
local HEAD_H = 24           -- cabecera FIJA (check general), fuera del scroll
local TITLE_H = 18          -- "Instancias guardadas (N)"
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

    if #entries == 0 then
        ShowMessage(container, width, "No hay mazmorras ni bandas guardadas.", { 0.7, 0.7, 0.7 })
        return
    end

    -- ----- Cabecera FIJA (fuera del scroll): check GENERAL de seguimiento -----
    -- El check guarda itemGoals.<key>.instancesTracked y decide si las
    -- instancias aparecen en los tooltips de "Jugador" y del minimapa. El toggle
    -- NO reconstruye la lista (respeta scroll): su estado lo muestra el check.
    local goals = RD.utils and RD.utils.itemGoals
    local header = CreateFrame("Frame", nil, container)
    header:SetSize(width, HEAD_H)
    header:SetPoint("TOPLEFT", container, "TOPLEFT", 0, 0)
    Track(container, header)

    local label = header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetJustifyH("LEFT")
    ApplyFontStyle(label, "contentText")
    label:SetText("Seguimiento: instancias en el tooltip del botón Jugador")
    label:SetTextColor(0.75, 0.75, 0.75)
    label:SetPoint("TOPLEFT", header, "TOPLEFT", PAD, -6)
    label:SetWidth(math.max(40, width - 2 * PAD - TRACK_S - PAD - 8))

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
        return "Check = seguimiento de instancias.\nAparecen en el tooltip del botón Jugador y en el del minimapa."
    end)
    header.rdTrack = track

    -- ----- Scroll con filas propias (2 columnas: nombre izq + meta der.) -----
    local scrollH = math.max(40, (height or 300) - HEAD_H)
    local scroll, content
    if MakeScroll then
        scroll, content = MakeScroll(container, width, scrollH, HEAD_H, 0)
    else
        scroll = CreateFrame("ScrollFrame", nil, container)
        scroll:SetSize(width, scrollH)
        scroll:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -HEAD_H)
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
-- El cap evita un tooltip inmanejable con decenas de entradas.
local MAX_TOOLTIP_LINES = 12
function Instances:TooltipLines()
    if not self:IsTracking() then return nil end
    local entries = CollectEntries(Now())
    if #entries == 0 then return nil end

    local pending, free = SplitEntries(entries)
    local lines = {}
    lines[#lines + 1] = {
        text = "|cffffd200Instancias guardadas (" .. #entries .. ")|r",
        r = 1, g = 1, b = 1,
    }

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