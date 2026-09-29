--[[
    RD_UI_BandsPlayerEditor_Sections.lua
    PROPÓSITO: Secciones de DATOS del editor de jugador (RD_UI_BandsPlayerEditor)
              distintas de "Información", presentadas como LISTAS. Cada sección
              se abre desde la tira de iconos del borde derecho y solo hay UNA
              visible a la vez:
                - bands     : pertenencias del jugador como ENLACES al gestor de
                              jugadores de cada banda (los datos por banda —rol,
                              dual, líder, sanción y asistencia— se editan allí)
                              + control para AÑADIRLO a otra banda.
                - instances : mazmorras/bandas guardadas (saved instances),
                              SOLO si el jugador es uno mismo (API 3.3.5a).
              Las secciones "equip" (rejilla por calidad + objetivos) y "monedas"
              (rejilla + metas) viven en RD_UI_BandsPlayerEditor_Sections_Grids;
              este archivo DELEGA en ellas y conserva aquí la infraestructura de
              lista (GetList/FinishList) y las secciones de bandas/instancias.
              El editor invoca RD.ui.playerEditorSections:Build(key, container,
              ed) al abrir la sección; cada build limpia y rellena el contenedor
              (los FontString NO aceptan SetParent(nil): se reutiliza un pool de
              filas por contenedor).
    API PÚBLICA:
        - RD.ui.playerEditorSections:Build(key, container, ed)
        - RD.ui.playerEditorSections:Keys()  -> { "equip", "bands", "instances", "monedas" }
        - RD.ui.playerEditorSections:IsSelfOnly(key)
    EVENTOS: Ninguno (el refresco de "monedas" por CURRENCY_DISPLAY_UPDATE lo
             gestiona RD_UI_BandsPlayerEditor_Sections_Grids, suscrito a los
             eventos publicados por RD_Module_ItemGoalsWatch).
]]

local addonName, private = ...
local RD = _G.RaidDominion or {}
_G.RaidDominion = RD

RD.ui = RD.ui or {}
local Sections = {}

-- Nombre del personaje que se está inspeccionando/editando: el texto ACTUAL del
-- campo Nombre si hay algo escrito (puede haberse renombrado), con respaldo en
-- el nombre con el que se abrió el editor.
local function InspectedName(ed)
    local name
    if ed and ed.nameBox and ed.nameBox.GetText then
        name = strtrim(ed.nameBox:GetText() or "")
    end
    if not name or name == "" then
        name = (ed and ed.playerName) or ""
    end
    return name
end

-- Layout de los enlaces a bandas de la sección "Bandas"
local LINK_ROW_H = 20
local LINK_ROW_GAP = 2

-- Margen reservado a la derecha del contenido para la barra de scroll (16 px de
-- barra + 8 px de aire). Debe coincidir con SCROLL_GUTTER de
-- RD_UI_BandsPlayerEditor, que reserva el mismo margen en el cuerpo del editor.
local SCROLL_GUTTER = 24

-- Métricas compartidas (grid 4px, UIUtils.Metrics): gutter lateral común con las
-- demás secciones (las listas usaban 4/0/8 según el tab; ahora PAD = 4 en todos).
local Metrics = (RD.UIUtils and RD.UIUtils.Metrics)
    or { GRID = 4, PAD = 4, LIST_LINE_H = 16 }
local PAD = Metrics.PAD or 4
local LIST_LINE_H = Metrics.LIST_LINE_H or 16
-- Tamaño de fuente por estilo de fila, en px ENTEROS. El render de 3.3.5a es
-- nítido con SetFont(tamaño entero); SetTextHeight deriva un tamaño fraccionario
-- (FreeType sin hinting) que se ve pixelado. Tamaño ABSOLUTO: al ser siempre
-- fijo, no compone escalas en el pool reutilizado (el problema de ScaleFont).
local STYLE_SIZE = { contentText = 12, sectionTitle = 15, hint = 10 }

-- Color de enlace para los nombres de banda (estilo hipervínculo)
local LINK_R, LINK_G, LINK_B = 0.4, 0.75, 1

-- Nombre visible de un enlace: un FontString de 3.3.5a NO parsea |H/|K (se vería
-- crudo y distorsionado), pero sí |c/|r. LinkLabel retira el envoltorio del
-- enlace conservando el color.
local LinkLabel = (RD.UIUtils and RD.UIUtils.LinkLabel)
    or function(t) return tostring(t or "") end

-- ============================================================================
-- Lista con scroll reutilizable dentro de un contenedor de sección
-- ============================================================================

-- Crea (o devuelve) el ScrollFrame + child de una sección y su pool de filas.
-- Devuelve { scroll, child, Clear(), AddRow(text, color, font) }.
-- Ambos se invocan con `:` (list:AddRow(text, color)), por eso aceptan `self`.
local function GetList(container, width, height)
    if container.rdList then return container.rdList end

    local widgets = RD.ui and RD.ui.widgets
    local createScroll = widgets and widgets.CreateScrollFrame
    local scroll, child
    if createScroll then
        scroll, child = createScroll(container, width, height, 0, 0)
    else
        scroll = CreateFrame("ScrollFrame", nil, container)
        scroll:SetSize(width, height)
        scroll:SetPoint("TOPLEFT", container, "TOPLEFT", 0, 0)
        child = CreateFrame("Frame", nil, scroll)
        child:SetWidth(width)
        scroll:SetScrollChild(child)
    end

    local pool = {}
    local used = 0
    local totalH = 0
    local list          -- upvalue visible a Clear/AddRow (Lua 5.1: debe declararse ANTES)

    local function Clear()
        for _, row in ipairs(pool) do
            row:Hide()
        end
        used = 0
        totalH = 0
        child:SetHeight(10)
        if scroll.UpdateScrollChildRect then scroll:UpdateScrollChildRect() end
        if scroll.SetVerticalScroll then scroll:SetVerticalScroll(0) end
    end

    -- AddRow se invoca como list:AddRow(text, color, font): el `:` pasa `list` como
    -- self. `style` ∈ { contentText, sectionTitle, hint } define la jerarquía
    -- tipográfica de la fila (los subtítulos y pistas se distinguen del cuerpo).
    local function AddRow(self, text, color, font, style)
        used = used + 1
        local row = pool[used]
        if not row then
            row = child:CreateFontString(nil, "OVERLAY", font or "GameFontNormalSmall")
            row:SetJustifyH("LEFT")
            row:SetWordWrap(true)
            row:SetPoint("TOPLEFT", child, "TOPLEFT", PAD, 0)
            pool[used] = row
        end
        local size = STYLE_SIZE[style] or STYLE_SIZE.contentText
        local path = row:GetFont()
        if path then row:SetFont(path, size) end
        row:SetText(text or "")
        if color then row:SetTextColor(color[1], color[2], color[3]) end
        row:SetWidth(width - 2 * PAD - 8)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", child, "TOPLEFT", PAD, -totalH)
        row:Show()
        local lines = 1
        if RD.UIUtils and RD.UIUtils.EstimateWrappedLines then
            lines = math.max(1, RD.UIUtils.EstimateWrappedLines(text or "", width - 2 * PAD - 8, size))
        end
        totalH = totalH + lines * LIST_LINE_H + 4
        list.totalH = totalH
    end

    list = { scroll = scroll, child = child, Clear = Clear, AddRow = AddRow }
    container.rdList = list
    return list
end

-- Finaliza el render de una lista: fija el alto del child y refresca el scroll.
-- extraH reserva espacio bajo las filas para controles adicionales (p.ej. el
-- dropdown + botón "Añadir" de la sección Bandas).
local function FinishList(list, extraH)
    if not list then return end
    local h = math.max(10, (list.totalH or 0) + 8 + (extraH or 0))
    list.child:SetHeight(h)
    if list.scroll.UpdateScrollChildRect then
        list.scroll:UpdateScrollChildRect()
    end
end

-- ============================================================================
-- Bandas (enlaces al gestor de jugadores de cada banda + añadir a otra banda)
-- ============================================================================

-- Fila de enlace a una banda: abre el gestor de jugadores de esa banda (donde
-- viven los datos por banda: rol, dual, líder, sanción y asistencia). El editor
-- NO expone aquí esos datos; solo el nombre como acceso directo al gestor.
-- Devuelve el alto ocupado y la fila (para que BuildBands las reparente a nil).
local function BuildBandLinkRow(child, width, bandIndex, band)
    local link = RD.UIUtils.MakeChipButton(child, nil, width - 2 * PAD - 8, LINK_ROW_H)
    link:SetPoint("TOPLEFT", child, "TOPLEFT", PAD, 0)
    link:RegisterForClicks("LeftButtonUp")
    local label = LinkLabel(band.name or ("Banda " .. bandIndex))
    if link.rdText then
        link.rdText:SetText(label)
        link.rdText:SetTextColor(LINK_R, LINK_G, LINK_B)
    end
    link:SetScript("OnClick", function()
        local bw = RD.ui and RD.ui.bandsWindow
        if bw and bw.ShowBand then
            bw:ShowBand(bandIndex)
        elseif RD.messageManager and RD.messageManager.SendSystemMessage then
            RD.messageManager:SendSystemMessage("|cffff0000[RaidDominion]|r El gestor de jugadores no está disponible.")
        end
    end)
    if RD.UIUtils and RD.UIUtils.AddButtonTooltip then
        RD.UIUtils.AddButtonTooltip(link, function()
            return "Abrir el gestor de jugadores de " .. label
        end)
    end
    return LINK_ROW_H + LINK_ROW_GAP, link
end

local function BuildBands(container, ed, width, height)
    -- Limpiar controles del render anterior (FontStrings NO aceptan
    -- SetParent(nil); los Frames sí). Se ocultan y se reparentan a nil.
    for _, extra in ipairs(container.rdExtras or {}) do
        if extra.Hide then extra:Hide() end
        if extra.GetObjectType and extra:GetObjectType() ~= "FontString" then
            extra:SetParent(nil)
        end
    end
    container.rdExtras = {}

    local list = GetList(container, width, height)
    list:Clear()

    local widgets = RD.ui and RD.ui.widgets
    local bandsApi = RD.utils and RD.utils.bands
    -- Pertenencias reales del personaje (nombre y clase actuales del editor):
    -- SOLO se enlazan bandas donde el personaje está realmente inscrito. La
    -- clase en vivo descarta miembros con el mismo nombre pero distinta clase
    -- (colisión de nombres = otro personaje).
    local memberships = (bandsApi and bandsApi.GetMemberships and bandsApi:GetMemberships(InspectedName(ed), (ed and ed.class) or "")) or {}
    local memberIdx = {}
    for _, mc in ipairs(memberships) do memberIdx[mc.index] = true end
    local notMember = {}
    local memberCount = 0

    local function Track(frame)
        container.rdExtras[#container.rdExtras + 1] = frame
    end

    -- Línea de ayuda: los datos por banda se editan en el gestor de cada banda
    list:AddRow("Los datos de cada banda (rol, dual, líder, sanción y asistencia) se editan en su gestor de jugadores.", { 0.7, 0.7, 0.7 }, nil, "hint")
    local y = list.totalH

    -- Subtítulo: bajo él SOLO se enlazan bandas donde el personaje está en la
    -- lista de jugadores (pertenencias verificadas por GetMemberships).
    if #memberships > 0 then
        list:AddRow("Bandas donde está registrado:", { 1, 0.82, 0 }, nil, "sectionTitle")
        y = list.totalH
    end

    if bandsApi and bandsApi.GetBands then
        local allBands = bandsApi:GetBands() or {}
        if type(allBands) == "table" then
            for _, mc in ipairs(memberships) do
                local rowH, row = BuildBandLinkRow(list.child, width, mc.index, mc.band)
                row:SetPoint("TOPLEFT", list.child, "TOPLEFT", 0, -y)
                Track(row)
                y = y + rowH
                memberCount = memberCount + 1
            end
            -- Bandas donde NO está (para el control de "Añadir a otra banda")
            for i, band in ipairs(allBands) do
                if not memberIdx[i] then
                    notMember[#notMember + 1] = { index = i, name = band.name or ("Banda " .. i) }
                end
            end
        end
    end

    if memberCount == 0 then
        list:AddRow("No figura en ninguna banda.", { 0.7, 0.7, 0.7 }, nil, "hint")
        y = list.totalH
    end
    list.totalH = y

    -- Control para añadir a otra banda (lista desplegable de las bandas donde NO está)
    local lbl = list.child:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lbl:SetText("Añadir a otra banda (donde NO está registrado):")
    lbl:SetJustifyH("LEFT")
    lbl:SetTextColor(1, 0.82, 0)
    local lblFont = lbl:GetFont()
    if lblFont then lbl:SetFont(lblFont, STYLE_SIZE.sectionTitle) end
    lbl:SetPoint("TOPLEFT", list.child, "TOPLEFT", PAD, -(list.totalH + 8))
    lbl:Show()
    container.rdExtras[#container.rdExtras + 1] = lbl

    -- El desplegable ocupa el ancho disponible y el botón queda a su derecha,
    -- SIN dejar el hueco muerto a la derecha (antes se acotaba a 170 px y el
    -- botón terminaba a mitad de la fila).
    local ddY = list.totalH + 28
    local addW = 84
    local ddW = math.max(120, width - 2 * PAD - addW - 6)
    local dd = nil
    if widgets and widgets.CreateOptionsDropdown then
        local options = {}
        for _, nb in ipairs(notMember) do
            options[#options + 1] = { key = tostring(nb.index), label = nb.name }
        end
        dd = widgets:CreateOptionsDropdown(list.child, ddW, {
            emptyLabel = "Elegir banda",
            current = "",
            options = options,
            onSelect = function() end,
        })
        if dd and dd.button then
            dd.button:SetPoint("TOPLEFT", list.child, "TOPLEFT", PAD, -ddY)
            dd.button:SetHeight(20)
            container.rdExtras[#container.rdExtras + 1] = dd.button
        end
    end

    local addBtn = RD.UIUtils.MakeChipButton(list.child, nil, addW, 20)
    addBtn:SetText("Añadir")
    addBtn:SetPoint("LEFT", dd and dd.button or lbl, "RIGHT", 6, 0)
    container.rdExtras[#container.rdExtras + 1] = addBtn
    addBtn:SetScript("OnClick", function()
        local idx = dd and tonumber(dd:GetValue() or "") or nil
        if not idx then
            if RD.messageManager and RD.messageManager.SendSystemMessage then
                RD.messageManager:SendSystemMessage("|cffff8000[RaidDominion]|r Elige una banda de la lista para añadir al jugador.")
            end
            return
        end
        local name = InspectedName(ed)
        if name == "" then
            if RD.messageManager and RD.messageManager.SendSystemMessage then
                RD.messageManager:SendSystemMessage("|cffff8000[RaidDominion]|r El nombre del jugador está vacío.")
            end
            return
        end
        local bandsApi = RD.utils and RD.utils.bands
        if not bandsApi or not bandsApi.AddPlayer then return end
        -- Solo identidad: los datos por banda (rol/dual/líder/sanción/asistencia)
        -- no se copian de otra pertenencia; se empiezan con sus valores por defecto.
        bandsApi:AddPlayer(idx, {
            name = name,
            class = (ed and ed.class) or "",
            notes = (ed and ed.notesBox and ed.notesBox:GetText()) or "",
        })
        if RD.messageManager and RD.messageManager.SendSystemMessage then
            RD.messageManager:SendSystemMessage("|cff00ff00[RaidDominion]|r " .. name .. " añadido a la banda.")
        end
        -- Reconstruir la sección para reflejar la nueva pertenencia
        if ed and ed.SwitchTo and ed.openSection == "bands" then
            ed:SwitchTo("bands")
        end
    end)

    -- Reserve bajo las filas: 56 px para la etiqueta (8+15), el desplegable (20)
    -- y 8 px de aire bajo la fila de acción (antes 38 no llegaba: el desplegable
    -- quedaba pegado al borde inferior del contenido).
    FinishList(list, 56)
end

-- ============================================================================
-- API pública
-- ============================================================================

local SECTION_BUILDERS = {
    bands = BuildBands,
}

function Sections:Keys()
    return { "equip", "bands", "instances", "monedas" }
end

function Sections:IsSelfOnly(key)
    return key == "equip" or key == "instances" or key == "monedas"
end

-- Construye la sección `key` dentro de `container` (un Frame ya dimensionado).
-- `ed` es el frame del editor (lee nameBox/class/role/... y llama ed:SwitchTo).
-- Las secciones "equip", "monedas" y "instances" DELEGAN en sus módulos
-- dedicados (rejillas de iconos y sección de bloqueos); las de lista se
-- resuelven aquí.
function Sections:Build(key, container, ed)
    local width = ((container and container:GetWidth()) or 420) - SCROLL_GUTTER
    local height = container and container:GetHeight() or 300

    if key == "equip" or key == "monedas" then
        local grids = RD.ui and RD.ui.playerEditorSectionsGrids
        if grids and grids.Build then
            grids:Build(key, container, ed, width, height)
        end
        return
    end

    if key == "instances" then
        local instances = RD.ui and RD.ui.playerEditorSectionsInstances
        if instances and instances.Build then
            instances:Build(container, ed, width, height)
        end
        return
    end

    local builder = SECTION_BUILDERS[key]
    if builder then
        builder(container, ed, width, height)
    end
end

-- Helpers de lista compartidos con los módulos de sección delegados
-- (RD_UI_BandsPlayerEditor_Sections_Instances). Se resuelven en tiempo de
-- Build (no al cargar) para no depender del orden del .toc.
Sections.ListHelpers = {
    GetList = GetList,
    FinishList = FinishList,
    STYLE_SIZE = STYLE_SIZE,
}

RD.ui.playerEditorSections = Sections
return Sections