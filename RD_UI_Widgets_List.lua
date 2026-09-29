--[[
    RD_UI_Widgets_List.lua
    PROPÓSITO: Editor de listas configurables (CreateList): filas con nombre
              editable, selector de iconos, visibilidad, drag & drop y
              privacidad ante "Obtener". Vive en un archivo aparte para
              mantener RD_UI_Widgets.lua dentro del límite de ~700 líneas.
              El scroll con barra personalizada y el selector de iconos viven
              en RD_UI_Widgets_IconPicker.lua (se carga antes en el .toc).
    API PÚBLICA:
        - RD.ui.widgets:CreateList(parent, field, onChange)
    EVENTOS: Ninguno. Escribe vía RD.config:Set (dispara CONFIG_CHANGED).
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

local UniqueName = Widgets.UniqueName
local GetValue = Widgets.GetValue
local SetValue = Widgets.SetValue
local EnableTabNavigation = RD.UIUtils and RD.UIUtils.EnableTabNavigation
local Log = (RD.UIUtils and RD.UIUtils.Log) or function(msg) print(msg) end

-- Helpers compartidos: el scroll con barra personalizada y el selector de
-- iconos viven en RD_UI_Widgets_IconPicker.lua (se carga antes en el .toc y
-- cuelga ambos de la tabla compartida RD.ui.widgets).
local CreateScrollFrame = Widgets.CreateScrollFrame
local OpenIconPicker = Widgets.OpenIconPicker

local DEFAULT_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

-- =============================================
-- LIST EDITOR (lista de { name, icon } configurable)
-- =============================================

function Widgets:CreateList(parent, field, onChange)
    if not parent or not field then return nil end

    local key = field.key
    local value = GetValue(field)
    local list = {}
    if type(value) == "table" then
        for _, v in ipairs(value) do
            list[#list + 1] = { name = v.name or "", icon = v.icon or "", visible = v.visible }
        end
    end

    -- El editor aprovecha el ancho disponible del frame fila padre, dejando
    -- margen derecho para que la barra de scroll quede contenida en la fila.
    local width = field.width or (parent.GetWidth and (parent:GetWidth() or 0) or 0)
    if width <= 0 then width = 452 end
    local height = field.height or 200
    -- Espacio a la derecha para la barra de scroll (junto al contenido)
    local scrollW = width - 26
    local childW = scrollW
    local rowH = 24
    local gap = 2
    -- Franja fija de creación (Añadir), siempre visible FUERA de la zona de scroll
    local ADD_H = 24
    local GAP_H = 2
    -- Fila de privacidad de la lista ("Obtener"): vive dentro de la franja de
    -- creación, sobre el scroll.
    local PRIV_H = 22

    -- Scroll con barra personalizada (la barra queda a la derecha del contenido).
    -- El scroll se ancla BAJO la franja de creación (offset -(franja + privacidad)).
    local scroll, child = CreateScrollFrame(parent, scrollW, height, 0, -(ADD_H + GAP_H + PRIV_H + GAP_H))
    child:SetWidth(childW)
    -- El viewport del scroll consume el clic en su zona vacía (franja inferior
    -- de la lista) para que NO atraviese a los widgets que quedan debajo del
    -- editor en la ventana de configuración. Las filas (hijas del contenido)
    -- quedan por encima y mantienen sus propios clics.
    scroll:EnableMouse(true)
    scroll:SetScript("OnMouseDown", function() end)
    scroll:SetScript("OnMouseUp", function() end)
    -- La fila de la ventana de config que aloja el editor también consume el
    -- clic en toda su zona vacía: en 3.3.5a el child del scroll sobresale del
    -- viewport por el borde inferior (cola del contenido que no cabe) y ese área,
    -- al quedar fuera del rect del scroll, dejaría caer el clic a través de él
    -- hasta la sección siguiente (p.ej. el título/controles "Anuncios..." que
    -- quedan debajo de la lista). El parent, con EnableMouse, bloquea esa fuga;
    -- los controles (addBar, filas, viewport) son hijos y ganan en su propia zona.
    parent:EnableMouse(true)
    parent:SetScript("OnMouseDown", function() end)
    parent:SetScript("OnMouseUp", function() end)

    -- Franja de creación anclada al TOP del editor: nombre + icono + Añadir +
    -- Obtener/Reiniciar. No forma parte del scroll (no se desplaza ni se oculta).
    -- EnableMouse: la franja captura el clic en su zona vacía para que NO caiga
    -- a través sobre los elementos que quedan debajo del editor.
    local addBar = CreateFrame("Frame", nil, parent)
    addBar:SetSize(childW, ADD_H + GAP_H + PRIV_H + GAP_H)
    addBar:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    addBar:EnableMouse(true)
    addBar:SetScript("OnMouseDown", function() end)
    addBar:SetScript("OnMouseUp", function() end)
    -- En 3.3.5a el ScrollFrame no recorta el ratón de su contenido: una fila que
    -- asoma por el borde superior al hacer scroll solaparía esta franja. Elevar
    -- su frame level sobre el scroll hace que la franja gane siempre el clic.
    local scrollLevel = scroll and scroll.GetFrameLevel and scroll:GetFrameLevel() or 0
    if addBar.SetFrameLevel then addBar:SetFrameLevel(scrollLevel + 5) end

    local itemRows = {}
    local BuildRows

    -- Guarda una copia nueva (para que RD.config:Set detecte el cambio y dispare
    -- CONFIG_CHANGED) pero SIN reasignar `list`: así los closures de los ítems
    -- (nombre/icono) siguen referenciando la misma lista viva y cada edición
    -- posterior se propaga correctamente.
    local function SaveList()
        local copy = {}
        for _, v in ipairs(list) do
            copy[#copy + 1] = { name = v.name, icon = v.icon, visible = v.visible }
        end
        if RD.config and RD.config.Set then
            RD.config:Set(key, copy)
        end
        if onChange then onChange(field, copy) end
    end

    local function ClearRows()
        -- Suelta foco/captura antes de ocultar: en 3.3.5a, ocultar o desanclar
        -- una fila cuyo EditBox conserva el foco de teclado (el clic en un botón
        -- NO lo libera) puede hacer que el frame se congele en pantalla como
        -- fila fantasma. Un error en una fila no debe abortar la limpieza del
        -- resto ni dejar el editor a medio reconstruir.
        for _, r in ipairs(itemRows) do
            if r then
                local ok, err = pcall(function(dead)
                    local nb = dead.nameBox
                    if nb and nb.ClearFocus then nb:ClearFocus() end
                    if dead.nameBox then dead.nameBox:SetAutoFocus(false) end
                    if dead.EnableMouse then dead:EnableMouse(false) end
                    dead:Hide()
                    dead:SetParent(nil)
                end, r)
                if not ok then
                    Log("|cffff0000[RaidDominion]|r error limpiando la lista: " .. tostring(err))
                end
            end
        end
        itemRows = {}
    end

    -- Fila superior: añadir elemento (nombre + selector de icono + botón)
    local pendingIcon = DEFAULT_ICON

    local addName = CreateFrame("EditBox", UniqueName("ANm"), addBar, "InputBoxTemplate")
    addName:SetSize(math.max(90, childW - 24 - 64 - 72 - 76 - 24), 22)
    addName:SetPoint("TOPLEFT", addBar, "TOPLEFT", 6, 0)
    addName:SetAutoFocus(false)
    RD.UIUtils.StyleInput(addName)

    local addIconBtn = CreateFrame("Button", UniqueName("AIB"), addBar)
    addIconBtn:SetSize(24, 24)
    addIconBtn:SetPoint("LEFT", addName, "RIGHT", 4, 0)
    local addIconTex = addIconBtn:CreateTexture(nil, "ARTWORK")
    addIconTex:SetAllPoints()
    addIconTex:SetTexture(pendingIcon)
    addIconBtn:SetScript("OnClick", function()
        OpenIconPicker(addIconBtn, function(icon)
            pendingIcon = icon
            addIconTex:SetTexture(icon)
        end, pendingIcon)
    end)
    addIconBtn:SetScript("OnEnter", function(self)
        if not (RD.UIUtils and RD.UIUtils.TooltipsEnabled and RD.UIUtils.TooltipsEnabled()) then
            GameTooltip:Hide()
            return
        end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Clic: elegir el icono", 1, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    addIconBtn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    -- Vista previa del icono del enlace: al escribir/pegar un enlace (ítem o
    -- hechizo) se detecta su icono y se muestra en el selector ANTES de añadir.
    -- Solo se toca el icono pendiente si se llega a detectar; si no, se respeta
    -- el icono que el usuario haya elegido a mano. El helper MakeLinkAwareEditBox
    -- muestra el texto visible del enlace pegado, así que el icono se detecta con
    -- el RAW (addName:rdGetRaw()), no con el texto visible.
    if RD.UIUtils and RD.UIUtils.MakeLinkAwareEditBox then
        RD.UIUtils.MakeLinkAwareEditBox(addName, "", {
            border = false,   -- el campo de añadir no precisa el borde indicador
            tooltip = false,  -- la preview del icono ya indica que es un enlace
            onChange = function(raw)
                if RD.UIUtils and RD.UIUtils.LinkInfo then
                    local icon = RD.UIUtils.LinkInfo(raw or "")
                    if icon then
                        pendingIcon = icon
                        addIconTex:SetTexture(icon)
                    end
                end
            end,
        })
    else
        addName:SetScript("OnTextChanged", function(self, userInput)
            if not userInput then return end
            local icon = nil
            if RD.UIUtils and RD.UIUtils.LinkInfo then
                icon = RD.UIUtils.LinkInfo(self:GetText() or "")
            end
            if icon then
                pendingIcon = icon
                addIconTex:SetTexture(icon)
            end
        end)
    end
    -- rdGetRaw para leer el RAW al añadir (el campo puede mostrar solo el visible)
    local addBtn = RD.UIUtils.MakeChipButton(addBar, UniqueName("AAd"), 64, 22)
    addBtn:SetText("Añadir")
    RD.UIUtils.AddButtonTooltip(addBtn, function() return "Añade el elemento escrito a la lista." end)
    addBtn:SetPoint("LEFT", addIconBtn, "RIGHT", 4, 0)

    -- Obtener del líder + Reiniciar (confirmaciones) vía helper compartido
    local actions = RD.ui and RD.ui.widgets and RD.ui.widgets.CreateListActionButtons
        and RD.ui.widgets:CreateListActionButtons(addBar, addBtn, {
            listKey = key,
            label = field.label or key,
            obtainWidth = 72,
            resetWidth = 76,
            onReset = function()
                local defaults = (RD.constants and RD.constants.DEFAULT_LISTS and RD.constants.DEFAULT_LISTS[key]) or {}
                for i = #list, 1, -1 do table.remove(list, i) end
                for _, item in ipairs(defaults) do
                    local copy = {}
                    for k, v in pairs(item) do copy[k] = v end
                    list[#list + 1] = copy
                end
                SaveList()
                BuildRows()
            end,
        })

    -- Privacidad de la lista ante "Obtener" (sobre la lista, en la franja fija).
    if RD.ui and RD.ui.widgets and RD.ui.widgets.CreatePrivacyDropdown then
        RD.ui.widgets:CreatePrivacyDropdown(addBar, key, { x = 6, y = -(ADD_H + GAP_H) })
    end

    -- (El botón "Spamear" de la pestaña de reglas se retiró; el spammer de
    -- reglas se abre desde el menú flotante (submenú Reglas → Spamear reglas).)

    -- La franja de creación (addBar) queda FUERA del scroll: no hay frames de
    -- cabecera que ocultar por visibilidad ni que reconstruir en cada build.

    addBtn:SetScript("OnClick", function()
        -- Con el helper activo el campo puede mostrar solo el texto visible del
        -- enlace; al añadir se lee SIEMPRE el raw (enlace re-inyectado o plano).
        local raw = ""
        if addName.rdGetRaw then
            raw = addName.rdGetRaw() or ""
        else
            raw = addName:GetText() or ""
        end
        local name = strtrim(raw)
        if name == "" then
            addName:ClearFocus()
            return
        end
        -- Icono: ya lo detectó la vista previa en vivo (OnTextChanged); al añadir
        -- se vuelve a comprobar por si la cache se resolvió entre medias. Solo se
        -- usa el icono del enlace si se detecta; si no, el elegido por el usuario.
        local detectedIcon = nil
        if RD.UIUtils and RD.UIUtils.LinkInfo then
            detectedIcon = RD.UIUtils.LinkInfo(name)
        end
        local icon = detectedIcon or pendingIcon
        -- El nombre se conserva tal cual (un enlace pegado mantiene su formato y
        -- color al anunciarlo); solo cambia el icono si se detecta.
        table.insert(list, { name = name, icon = icon })
        addName:SetText("")
        addIconTex:SetTexture(DEFAULT_ICON)
        pendingIcon = DEFAULT_ICON
        SaveList()
        BuildRows()
    end)
    -- Enter añade y libera el foco; Escape solo lo libera (para usar atajos).
    addName:SetScript("OnEnterPressed", function(self)
        addBtn:Click()
        self:ClearFocus()
    end)
    addName:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)

    BuildRows = function()
        ClearRows()

        -- Inválida el closure viejo de visibilidad ANTES de tocar el scroll:
        -- child:SetHeight y SetVerticalScroll (más abajo) disparan
        -- OnScrollRangeChanged/OnVerticalScroll, que invocan RDRefreshVisibility.
        -- En 3.3.5a, ese closure (AÚN el anterior; el nuevo se instala al final
        -- con ApplyScrollVisibility) referencia filas ya limpiadas y desancladas,
        -- y al evaluarlas podría resolver coordenadas residuales que "intersecan"
        -- el viewport y llamar Show() sobre ellas: las resucita como filas
        -- fantasma pegadas al scroll child y ya no rastreables por itemRows.
        scroll.RDRefreshVisibility = nil

        -- Los ítems se distribuyen en el máximo de columnas que caben según el
        -- ancho disponible (cada celda necesita un ancho mínimo), aprovechando
        -- todo el espacio del panel.
        local MIN_CELL = 190
        local colGap = 8
        local cols = math.max(1, math.floor((childW + colGap) / (MIN_CELL + colGap)))
        local cellW = math.max(120, math.floor((childW - (cols - 1) * colGap) / cols))
        local gridRows = math.ceil(#list / cols)
        -- Las filas arrancan en el TOP del scroll (la franja de creación quedó
        -- fuera, arriba); el motor de drag usa firstTop = 0 (ver más abajo).
        local totalH = gridRows * (rowH + gap)

        for i, item in ipairs(list) do
            local col = (i - 1) % cols
            local r = math.floor((i - 1) / cols)
            local row = CreateFrame("Frame", nil, child)
            row:SetSize(cellW, rowH)
            row:SetPoint("TOPLEFT", child, "TOPLEFT", col * (cellW + colGap), -r * (rowH + gap))
            RD.UIUtils.AddRowHover(row)

            -- Nombre editable (EditBox en línea). No hay icono a la izquierda:
            -- el único icono de la fila es el botón-toggle del selector (derecha).
            -- Si el nombre es un enlace de chat se muestra SOLO el texto visible y,
            -- al editar/guardar, se re-inyecta en el envoltorio sin dañarlo (lo
            -- gestiona UIUtils.MakeLinkAwareEditBox; aquí solo se cablea el guardado
            -- en vivo en item.name + SaveList).
            local nameBox = CreateFrame("EditBox", UniqueName("INm"), row, "InputBoxTemplate")
            nameBox:SetHeight(22)
            nameBox:SetPoint("LEFT", row, "LEFT", 6, 0)
            nameBox:SetPoint("RIGHT", row, "RIGHT", -96, 0)
            nameBox:SetAutoFocus(false)
            RD.UIUtils.StyleInput(nameBox)
            local linkAware = RD.UIUtils and RD.UIUtils.MakeLinkAwareEditBox
            if linkAware then
                -- El helper configura display (texto visible), borde azul, tooltip y
                -- la re-inyección; el guardado SIEMPRE recibe el raw correcto.
                linkAware(nameBox, item.name or "", {
                    onChange = function(raw)
                        item.name = raw
                        SaveList()
                    end,
                    -- Enter/Esc liberan el foco (el guardado ya fue en vivo).
                    onCommit = function() end,
                })
            else
                -- Fallback plano (entorno de test sin el helper): sin re-inyección.
                nameBox:SetText(item.name or "")
                local function SavePlain()
                    item.name = strtrim(nameBox:GetText() or "")
                    SaveList()
                end
                nameBox:SetScript("OnTextChanged", SavePlain)
                nameBox:SetScript("OnEnterPressed", function(self) SavePlain(); self:ClearFocus() end)
                nameBox:SetScript("OnEscapePressed", function(self) SavePlain(); self:ClearFocus() end)
            end
            row.nameBox = nameBox

            -- Botón de icono editable (abre el selector de iconos)
            local iconBtn = CreateFrame("Button", UniqueName("IIB"), row)
            iconBtn:SetSize(24, 24)
            local itemIconTex = iconBtn:CreateTexture(nil, "ARTWORK")
            itemIconTex:SetAllPoints()
            itemIconTex:SetTexture(item.icon ~= "" and item.icon or DEFAULT_ICON)
            iconBtn:SetScript("OnClick", function()
                OpenIconPicker(iconBtn, function(icon)
                    item.icon = icon
                    itemIconTex:SetTexture(icon)
                    SaveList()
                end, item.icon)
            end)
            iconBtn:SetScript("OnEnter", function(self)
                if not (RD.UIUtils and RD.UIUtils.TooltipsEnabled and RD.UIUtils.TooltipsEnabled()) then
                    GameTooltip:Hide()
                    return
                end
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText("Clic: cambiar el icono", 1, 1, 1, 1, true)
                GameTooltip:Show()
            end)
            iconBtn:SetScript("OnLeave", function()
                GameTooltip:Hide()
            end)

            -- Agarre de arrastre: reordena la lista con click-drag → click-drop.
            local grip = Widgets.CreateGrip and Widgets:CreateGrip(row)
            -- Las 4 listas asignables (roles/habilidades/buffs/auras) comparten
            -- la geometría de cuadrícula calculada más arriba en BuildRows.
            if grip and Widgets.EnableRowDrag then
                local dragParams = {
                    scroll = scroll,
                    child = child,
                    cols = cols,
                    cellW = cellW,
                    colGap = colGap,
                    rowH = rowH,
                    gap = gap,
                    -- Las filas arrancan en el top del scroll (la franja de
                    -- creación quedó fuera), así que la primera fila cae a 0.
                    firstTop = 0,
                    gridRows = gridRows,
                    source = i,
                    itemCount = function() return #list end,
                    label = item.name,
                    commitTarget = function(target)
                        local src = i
                        if target < 1 then target = 1 end
                        if target > #list + 1 then target = #list + 1 end
                        if target == src or target == src + 1 then return end
                        local temp = table.remove(list, src)
                        local idx = target
                        if idx > src then idx = idx - 1 end
                        table.insert(list, idx, temp)
                        SaveList()
                        BuildRows()
                    end,
                }
                -- Cross-tab (solo listas asignables): permite TRASLADAR el ítem a
                -- la lista de OTRO tab soltándolo sobre su pestaña. La clave
                -- destino es la de la zona (dropZone); la lista de origen es `key`.
                if field.dropZones and key and RD.config then
                    dragParams.dropZones = field.dropZones
                    dragParams.onDropTo = function(targetKey)
                        if not targetKey or targetKey == key then return end
                        local moved = list[i]
                        if not moved then return end
                        table.remove(list, i)
                        local target = {}
                        local TV = RD.config.Get and RD.config:Get(targetKey, nil)
                        if type(TV) == "table" then
                            for _, v in ipairs(TV) do
                                target[#target + 1] = { name = v.name or "", icon = v.icon or "", visible = v.visible }
                            end
                        end
                        target[#target + 1] = { name = moved.name or "", icon = moved.icon or "", visible = moved.visible }
                        if RD.config.Set then RD.config:Set(targetKey, target) end
                        SaveList()
                        BuildRows()
                    end
                end
                Widgets:EnableRowDrag(grip, dragParams)
            end

            -- Botón visibilidad en el menú flotante (ojo), antes del eliminar
            local visBtn = RD.ui.widgets:CreateVisibilityToggle(row, item, SaveList, function() BuildRows() end)

            -- Botón quitar
            local removeBtn = CreateFrame("Button", UniqueName("IRm"), row)
            removeBtn:SetSize(20, 20)
            local rmTex = removeBtn:CreateTexture(nil, "ARTWORK")
            rmTex:SetAllPoints()
            rmTex:SetTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")
            removeBtn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")

            -- Posiciona el bloque de acciones a la derecha: [agarre][icono][ojo][quitar]
            removeBtn:SetPoint("RIGHT", row, "RIGHT", 0, 0)
            visBtn:SetPoint("RIGHT", removeBtn, "LEFT", -2, 0)
            iconBtn:SetPoint("RIGHT", visBtn, "LEFT", -2, 0)
            if grip then grip:SetPoint("RIGHT", iconBtn, "LEFT", -2, 0) end
            removeBtn:SetScript("OnClick", function()
                local dialogs = RD.ui and RD.ui.dialogs
                local function DoRemove()
                    table.remove(list, i)
                    SaveList()
                    BuildRows()
                end
                if dialogs and dialogs.ShowConfirmDialog then
                    dialogs:ShowConfirmDialog({
                        text = string.format("¿Eliminar '%s' de la lista?", tostring(item.name or "")),
                        acceptText = "Eliminar",
                        onAccept = DoRemove,
                    })
                else
                    DoRemove()
                end
            end)

            itemRows[#itemRows + 1] = row
        end

        -- Lista vacía: indicación para empezar a crear elementos (anclada al top
        -- del scroll, igual que las filas; la franja de creación está fuera).
        if #list == 0 then
            local empty = RD.UIUtils and RD.UIUtils.CreateEmptyList
                and RD.UIUtils.CreateEmptyList(child, childW, "Lista vacía: pulsa 'Añadir' para crear el primer elemento.", 0)
            if empty then itemRows[#itemRows + 1] = empty end
            totalH = 20
        end

        -- Navegación con Tab entre los campos de la lista: la caja de añadir y el
        -- nombre de cada fila, en orden (con salto circular).
        if EnableTabNavigation then
            local boxes = { addName }
            for _, r in ipairs(itemRows) do
                if r.nameBox then boxes[#boxes + 1] = r.nameBox end
            end
            EnableTabNavigation(boxes)
        end

        child:SetHeight(totalH)

        if scroll.SetVerticalScroll then scroll:SetVerticalScroll(0) end
        -- Viewport dinámico: se ajusta al contenido real (compacto si la lista
        -- está vacía), con tope en field.height. Así todas las pestañas de lista
        -- siguen la misma regla que Bandas. La altura total incluye la franja de
        -- creación fija (ADD_H + GAP_H) que vive fuera del scroll.
        local viewH = math.max(1, math.min(height, math.max(1, totalH)))
        scroll:SetHeight(viewH)
        if parent.SetHeight then parent:SetHeight(ADD_H + GAP_H + PRIV_H + GAP_H + viewH) end

        -- Interactividad de las filas dentro del viewport: inactiva el ratón de
        -- solo las filas que quedan fuera de rango para que no reciban clics
        -- "a través" de los campos que haya debajo de la lista (p.ej. los
        -- anuncios). Las filas se mantienen VISIBLES (no se ocultan: en 3.3.5a
        -- Hide congelaría su layout y no reaparecerían al scrollear). La franja
        -- de creación (addBar) queda siempre visible y nunca se inactiva.
        if Widgets.ApplyScrollVisibility then
            Widgets:ApplyScrollVisibility(scroll, itemRows)
        end
    end

    BuildRows()

    return scroll
end

return Widgets
