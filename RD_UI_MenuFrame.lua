--[[
    RD_UI_MenuFrame.lua
    PROPÓSITO: Menú flotante principal. Arrastrable, posición persistente en config,
              con submenús renderizados por datos (RD.ui.menuFactory) y vinculado
              a la ventana de configuración.
    API PÚBLICA:
        - RD.ui.menuFrame:Create()
        - RD.ui.menuFrame:Show() / Hide() / Toggle()
        - RD.ui.menuFrame:ShowMainMenu()
        - RD.ui.menuFrame:NavigateTo(menuKey)
        - RD.ui.menuFrame:GoBack()
        - RD.ui.menuFrame:SavePosition() / RestorePosition()
        - RD.ui.menuFrame:Refresh()
    EVENTOS: UI_SHOW, UI_HIDE; reacciona a CONFIG_CHANGED (debounce) y CONFIG_RESET
]]

local addonName, private = ...
local RD = _G.RaidDominion or {}
_G.RaidDominion = RD

local MenuFrame = {
    frame = nil,
    content = nil,
    isShown = false,
    currentSource = { type = "def", key = "MainFrameOptions" },
    history = {},
    refreshFrame = nil,
    pendingCombatAction = nil,
    regenFrame = nil,
    -- Registro del jugador pendiente tras asignar un rol tank/healer: la vista
    -- "pickband" lista las bandas y al elegir una registra al jugador con su rol.
    pendingRoleAssign = nil,
}

local CONTENT_OFFSET_X = 8
local CONTENT_OFFSET_Y = 8
local BAR_HEIGHT = 30       -- alto de la barra inferior (como la base v2)
local BAR_BOTTOM = 4        -- margen inferior: la barra queda DENTRO del marco
local BAR_BOTTOM_PAD = 6    -- espacio entre el contenido y la barra

-- Aplica la escala de la interfaz (general.scale) al frame raíz. Delega en el
-- helper compartido de RD.UIUtils (único lugar permitido por AGENTS.md §6.3
-- para usar SetScale).
function MenuFrame:ApplyScale()
    if RD.UIUtils and RD.UIUtils.ApplyScale then
        RD.UIUtils.ApplyScale(self.frame)
    end
end

-- Aplica la movilidad del frame según ui.menu.lockPosition
function MenuFrame:ApplyMovable()
    if not self.frame then return end
    local lock = false
    if RD.config and RD.config.Get then
        lock = RD.config:Get("ui.menu.lockPosition", false)
    end
    if lock then
        self.frame:SetMovable(false)
        self.frame:RegisterForDrag()
    else
        self.frame:SetMovable(true)
        self.frame:RegisterForDrag("LeftButton")
    end
end

-- Crea el frame flotante raíz (solo una vez)
function MenuFrame:Create()
    if self.frame then return self.frame end

    local frame = CreateFrame("Frame", "RaidDominionMenuFrame", UIParent)
    -- Strata MEDIUM (paridad con los paneles de personaje de WoW, que viven en
    -- MEDIUM): el menú se cubre/descubre con la UI del juego como un panel
    -- nativo y pasa al frente al activarlo. NO usar DIALOG: los StaticPopups de
    -- WoW (confirmaciones, edición de Discord) viven en DIALOG y deben quedar
    -- SIEMPRE por encima de este menú (un frame del addon a DIALOG con
    -- Toplevel(true) taparía el popup y robaría el foco del teclado).
    if RD.UIUtils and RD.UIUtils.SetupWindow then
        RD.UIUtils.SetupWindow(frame)
    else
        frame:SetFrameStrata("MEDIUM")
        frame:SetToplevel(true)
        frame:SetClampedToScreen(true)
    end
    frame:EnableMouse(true)

    -- Clic derecho sobre el fondo del menú = regresar al menú anterior.
    -- (Los clics sobre los ítems los capturan los botones hijos: izq ingresa, der regresa.)
    frame:SetScript("OnMouseUp", function(_, btn)
        if btn == "RightButton" then
            self:GoBack()
        end
    end)

    self.frame = frame

    -- Arrastre (siempre que no esté bloqueada la posición)
    frame:SetScript("OnDragStart", function()
        frame:StartMoving()
    end)
    frame:SetScript("OnDragStop", function()
        frame:StopMovingOrSizing()
        self:SavePosition()
    end)
    self:ApplyMovable()
    self:ApplyScale()
    -- Registra el frame en la escala global central: así también se re-escala en
    -- vivo cuando general.scale cambia con el menú oculto (TrackScale lo aplica
    -- al instante y el suscriptor central cubre cambios posteriores).
    if RD.UIUtils and RD.UIUtils.TrackScale then
        RD.UIUtils.TrackScale(frame)
    end

    -- Clic sobre el fondo del menú lo sube al frente (ventanas del addon).
    -- Lo aplica SetupWindow (toplevel + Raise en OnMouseDown).

    -- Backdrop estilo v2
    frame:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    frame:SetBackdropColor(0, 0, 0, 0.9)
    frame:SetBackdropBorderColor(1, 1, 1, 0.5)

    -- Contenedor del menú
    local content = CreateFrame("Frame", nil, frame)
    content:SetPoint("TOPLEFT", frame, "TOPLEFT", CONTENT_OFFSET_X, -CONTENT_OFFSET_Y)
    self.content = content

    -- Barra de botones inferior (centrada), como la base v2. Los botones se
    -- posicionan en RenderCurrentMenu según el ancho final del marco.
    local actionBar = CreateFrame("Frame", nil, frame)
    actionBar:SetHeight(BAR_HEIGHT)
    self.actionBar = actionBar

    -- Frame auxiliar para re-render diferido al salir de combate
    local regenFrame = CreateFrame("Frame")
    regenFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    regenFrame:SetScript("OnEvent", function()
        if self.pendingCombatAction then
            self.pendingCombatAction = false
            if self.isShown and self.frame then
                self:RenderCurrentMenu()
                self:ApplyMovable()
                self:ApplyScale()
            end
        end
    end)
    self.regenFrame = regenFrame

    -- Frame persistente para el debounce de re-render (sin C_Timer): solo tiene
    -- OnUpdate mientras está visible (ventana de debounce).
    local refreshFrame = CreateFrame("Frame")
    refreshFrame:Hide()
    refreshFrame:SetScript("OnUpdate", function(self, elapsed)
        local t = (self.rdElapsed or 0) + elapsed
        if t >= (self.rdDelay or 0.15) then
            self:Hide()
            if self.rdOnFire then
                self.rdOnFire()
            end
        else
            self.rdElapsed = t
        end
    end)
    self.refreshFrame = refreshFrame

    -- Re-render al cambiar la configuración. Si cambia la lista que se está
    -- viendo (roles, abilities, ...), la actualización es inmediata (en vivo).
    if RD.events and RD.events.Subscribe then
        RD.events:Subscribe("CONFIG_CHANGED", function(key)
            if key == "ui.menu.position" then return end
            -- La posición del botón de minimapa cambia continuamente durante el
            -- arrastre: no debe re-renderizar el menú.
            if key == "ui.minimap.position" then return end
            if self.currentSource and self.currentSource.type == "list" and key == self.currentSource.key then
                if self.isShown and self.frame then
                    if not InCombatLockdown() then
                        -- Debounce (Refresh difiere 0.15 s): editar una lista con
                        -- el menú abierto dispara varios Sets encadenados; antes
                        -- cada uno re-renderizaba el menú al instante (ráfaga de
                        -- creación de frames). El render final es idéntico.
                        self:Refresh()
                    else
                        -- En combate no se crean frames: se difiere al salir.
                        self.pendingCombatAction = true
                    end
                else
                    -- Oculto: se marca pendiente para re-renderizar al reabrir
                    -- (Show) y no mostrar contenido stale.
                    self.needsRefresh = true
                end
                return
            end
            if not self.isShown then
                -- Oculto: cualquier cambio de config relevante se marca pendiente
                -- para re-renderizar al reabrir (Show) y no mostrar contenido stale.
                self.needsRefresh = true
            end
            self:Refresh()
        end)
        RD.events:Subscribe("CONFIG_RESET", function()
            if not self.isShown then
                self.needsRefresh = true
            end
            self:Refresh()
        end)
        -- El estado de spam de banda cambia (inicio/parada): re-render para
        -- aplicar/quit­ar el efecto "en spam" del submenú Bandas en vivo.
        RD.events:Subscribe("SPAM_STATE_CHANGED", function()
            if self.isShown then
                self:Refresh()
            end
        end)
    end

    self:RestorePosition()
    self:ShowMainMenu()

    return frame
end

function MenuFrame:Show()
    if not self.frame then return end
    -- Re-render defensivo si el contenido aún no se construyó
    if not self.content or not self.content.menuFrame then
        self:RenderCurrentMenu()
    elseif self.needsRefresh then
        -- Hubo un cambio de la lista activa mientras el menú estaba oculto:
        -- se re-renderiza para no mostrar contenido stale.
        self.needsRefresh = false
        self:RenderCurrentMenu()
    end
    if RD.UIUtils and RD.UIUtils.ActivateWindow then
        RD.UIUtils.ActivateWindow(self.frame)
    else
        self.frame:Show()
        self.frame:Raise()
    end
    self.isShown = true
    if RD.events and RD.events.Publish then
        RD.events:Publish("UI_SHOW")
    end
end

function MenuFrame:Hide()
    if not self.frame then return end
    self.frame:Hide()
    self.isShown = false
    if RD.events and RD.events.Publish then
        RD.events:Publish("UI_HIDE")
    end
end

-- Toggle basado en la VISIBILIDAD REAL del frame (no en el flag isShown, que
-- puede quedar desincronizado). Así el botón de minimapa y /rd siempre pueden
-- volver a mostrar el menú aunque se oculte al iniciar con ui.menu.showOnStart.
function MenuFrame:Toggle()
    if not self.frame then self:Create() end
    if self.frame and self.frame:IsShown() then
        self:Hide()
    else
        self:Show()
    end
end

-- Re-render del menú principal según config
function MenuFrame:ShowMainMenu()
    self.history = {}
    self.currentSource = { type = "def", key = "MainFrameOptions" }
    if self.frame then
        self:RenderCurrentMenu()
    end
end

-- Navega a un submenú por clave de definición estática
function MenuFrame:NavigateTo(menuKey)
    if not menuKey then return end
    if self.currentSource.type == "def" and self.currentSource.key == menuKey then return end
    table.insert(self.history, self.currentSource)
    self.currentSource = { type = "def", key = menuKey }
    if self.frame then
        self:RenderCurrentMenu()
    end
end

-- Muestra un submenú dinámico con los elementos de una lista de configuración
-- (clave de RD.config, p.ej. "roles", "abilities", ...). Cada elemento se
-- muestra con su nombre e icono tal como está guardado.
function MenuFrame:ShowDynamicList(listKey)
    if not listKey then return end
    if self.currentSource.type == "list" and self.currentSource.key == listKey then return end
    table.insert(self.history, self.currentSource)
    self.currentSource = { type = "list", key = listKey }
    if self.frame then
        self:RenderCurrentMenu()
    end
end

-- Retrocede al menú anterior (si hay historial)
function MenuFrame:GoBack()
    if #self.history > 0 then
        -- Al salir del selector de banda se descarta el registro pendiente
        if self.currentSource.type == "pickband" then
            self.pendingRoleAssign = nil
        end
        self.currentSource = table.remove(self.history)
        if self.frame then
            self:RenderCurrentMenu()
        end
    end
end

-- Guarda la posición en config (ui.menu.position)
function MenuFrame:SavePosition()
    if not self.frame then return end
    local point, relativeTo, relativePoint, xOfs, yOfs = self.frame:GetPoint(1)
    if not point then return end

    local relativeName = "UIParent"
    if relativeTo and relativeTo.GetName then
        relativeName = relativeTo:GetName()
    end

    if RD.config and RD.config.Set then
        RD.config:Set("ui.menu.position", {
            point = point,
            relativeTo = relativeName,
            relativePoint = relativePoint or point,
            x = xOfs or 0,
            y = yOfs or 0,
        })
    end
end

-- Restaura la posición desde config (offsets redondeados al grid)
function MenuFrame:RestorePosition()
    if not self.frame then return end
    local pos = nil
    if RD.config and RD.config.Get then
        pos = RD.config:Get("ui.menu.position")
    end
    if type(pos) ~= "table" or not pos.point then
        return
    end

    local relativeTo = UIParent
    if pos.relativeTo and pos.relativeTo ~= "UIParent" then
        relativeTo = _G[pos.relativeTo] or UIParent
    end

    local layout = RD.ui and RD.ui.layout
    local x = layout and layout.Snap and layout.Snap(pos.x or 0) or 0
    local y = layout and layout.Snap and layout.Snap(pos.y or 0) or 0

    self.frame:ClearAllPoints()
    self.frame:SetPoint(pos.point, relativeTo, pos.relativePoint or pos.point, x, y)

    if layout and layout.EnsureVisible then
        layout:EnsureVisible(self.frame, 8)
    end
end

-- Render del menú actual dentro del contenedor y redimensiona el frame
function MenuFrame:RenderCurrentMenu()
    if not self.frame or not self.content then return end

    -- Liberar el menú previo (cada BuildMenu crea un frame nuevo)
    if self.content.menuFrame then
        if GameTooltip and GameTooltip.Hide then GameTooltip:Hide() end
        self.content.menuFrame:Hide()
        self.content.menuFrame:SetParent(nil)
        self.content.menuFrame = nil
    end

    -- Resolver los ítems según el origen del menú actual:
    --   def  -> definición estática (RD.constants.MENU_DEFINITIONS)
    --   list -> elementos de una lista de configuración (roles, abilities, ...)
    local defs = nil
    if self.currentSource.type == "def" then
        if RD.constants and RD.constants.MENU_DEFINITIONS then
            defs = RD.constants.MENU_DEFINITIONS[self.currentSource.key]
        end
        if not defs then
            self.currentSource = { type = "def", key = "MainFrameOptions" }
            if RD.constants and RD.constants.MENU_DEFINITIONS then
                defs = RD.constants.MENU_DEFINITIONS["MainFrameOptions"]
            end
        end
        -- Orden del usuario (ui.menu.itemOrder): solo el menú principal se
        -- reordena (se arrastra el grip de una pestaña de la config). Se aplica
        -- sobre una COPIA: la tabla de constantes nunca se muta.
        if self.currentSource.key == "MainFrameOptions"
            and RD.ui and RD.ui.menuFactory and RD.ui.menuFactory.OrderMainDefs then
            defs = RD.ui.menuFactory:OrderMainDefs(defs)
        end
    elseif self.currentSource.type == "list" then
        local list = {}
        if RD.config and RD.config.Get then
            list = RD.config:Get(self.currentSource.key, {})
        end

        -- Lista especial de bandas: cada ítem se compone de DOS partes, como los
        -- ítems asignables — el TEXTO anuncia la banda por el canal configurado y
        -- el botón-ICONO abre el gestor de jugadores de esa banda (CRUD). Además
        -- la banda en spam (si la hay) recibe un efecto visual (ver BuildBandsDefs).
        if self.currentSource.key == "bands" then
            defs = self:BuildBandsDefs(list)
        else
            -- Las listas de roles/abilities/buffs/auras son asignables; sus ítems
            -- llevan la asignación actual para mostrarla en el label.
            local assignable = not (self.currentSource.key == "mechanics" or self.currentSource.key == "rules")
            local assignments = {}
            if assignable and RD.config and RD.config.Get then
                assignments = RD.config:Get("assignments." .. self.currentSource.key, {})
            end
            -- Palabras de anuncio del botón de asignación (tooltip "Asignación
            -- rápida"): `word` (clic en el texto del ítem) y `assignWord` (clic
            -- derecho en el icono). Se muestran en el tooltip del icono.
            local clickWord, clickRightWord = nil, nil
            if assignable and RD.config and RD.config.Get then
                local saved = RD.config:Get("announce." .. self.currentSource.key, nil)
                if type(saved) == "table" then
                    clickWord = saved.word
                    clickRightWord = saved.assignWord
                end
            end
            defs = {}
            local hadItems = false
            -- Regla activa del spammer de reglas: su ítem recibe el mismo efecto que la
            -- banda en spam (fondo dorado pulsante + punto dorado), pero SOLO
            -- mientras el spammer esté INICIADO (IsActive); si está detenido o
            -- no hay selección, ningún ítem se marca.
            local activeRule = nil
            if self.currentSource.key == "rules" then
                local rsp = RD.modules and RD.modules.rulesSpammer
                if rsp and rsp.IsActive and rsp:IsActive() and rsp.GetSettings then
                    activeRule = rsp:GetSettings().selectedTitle or nil
                end
            end
            if type(list) == "table" then
                for _, v in ipairs(list) do
                    hadItems = true
                    -- Control de visibilidad: los elementos ocultos no aparecen aquí.
                    if v.visible ~= false then
                        local itemName = v.name or v.title
                        -- Reglas/Mecánicas no son asignables: muestran su contenido en
                        -- el tooltip, que respeta ui.showTooltips (vía tooltipEnabled).
                        local tooltip = nil
                        if not assignable and v.content and v.content ~= "" then
                            tooltip = v.content
                            -- GameTooltip no clampea: se acota el contenido largo.
                            -- Truncado UTF-8 seguro (Lua 5.1, sin utf8): se descartan
                            -- los bytes de continuación sobrantes del último carácter.
                            if #tooltip > 200 then
                                tooltip = string.sub(tooltip, 1, 200):gsub("[\128-\191]*$", "") .. "…"
                            end
                        end
                        local isActiveRule = (activeRule ~= nil and itemName == activeRule)
                        if isActiveRule then
                            tooltip = (tooltip or "") .. "\n|r|cff1dbf00REGLA ACTIVA: es la seleccionada en el spammer de reglas."
                        end
                        defs[#defs + 1] = {
                            name = itemName,
                            icon = v.icon,
                            content = v.content,
                            tooltip = tooltip,
                            assignable = assignable,
                            assigned = (type(assignments) == "table" and itemName) and assignments[itemName] or nil,
                            active = isActiveRule,
                            clickWord = clickWord,
                            clickRightWord = clickRightWord,
                        }
                    end
                end
            end
            -- Lista vacía: indicador que lleva a configurarla (como el de bandas)
            if #defs == 0 then
                local emptyLabels = {
                    roles = "No hay roles registrados",
                    abilities = "No hay habilidades registradas",
                    buffs = "No hay buffs registrados",
                    auras = "No hay auras registradas",
                    mechanics = "No hay mecánicas registradas",
                    rules = "No hay reglas registradas",
                }
                local emptyActions = {
                    roles = "ShowRoles",
                    abilities = "ShowSkills",
                    buffs = "ShowBuffs",
                    auras = "ShowAuras",
                    mechanics = "ShowMechanics",
                    rules = "ShowRaidRules",
                }
                -- Si había ítems pero TODOS están ocultos por visibilidad, se
                -- indica para no confundir con una lista vacía.
                if hadItems then
                    defs[#defs + 1] = {
                        name = "Todos los elementos están ocultos",
                        tooltip = "Actívalos con el botón-ojo de la pestaña de esa lista en Configuración.",
                        isHint = true,
                    }
                else
                    defs[#defs + 1] = {
                        name = emptyLabels[self.currentSource.key] or ("No hay ítems registrados"),
                        action = emptyActions[self.currentSource.key],
                        tooltip = "Crea los elementos desde la configuración (Configuración)",
                    }
                end
                -- Aviso temporal: el clic derecho regresa al menú anterior
                defs[#defs + 1] = {
                    name = "Clic derecho para volver al menú anterior",
                    tooltip = "El clic derecho en cualquier parte del menú regresa al menú anterior.",
                    isHint = true,
                }
            elseif self.currentSource.key == "rules" and hadItems then
                -- Hay reglas registradas: se ofrece además abrir el spammer de
                -- reglas (rotar el mensaje de una regla por el canal elegido).
                defs[#defs + 1] = {
                    name = "Spamear reglas",
                    action = "OpenRulesSpammer",
                    icon = "Interface\\Icons\\INV_Misc_GroupNeedMore",
                    tooltip = "Abre el spammer: rota el mensaje de una regla por el canal elegido.",
                }
            end
        end
    elseif self.currentSource.type == "pickband" then
        -- Selector de banda tras asignar un rol tank/healer: lista las bandas y
        -- al elegir una se registra al jugador pendiente con su rol (vuelve al
        -- menú de roles). El clic derecho (GoBack) cancela el registro.
        defs = self:BuildPickBandDefs()
    end

    local menuFactory = RD.ui and RD.ui.menuFactory
    if not menuFactory or not defs then
        self.content:SetSize(1, 1)
        return
    end

    local menu, w, h = menuFactory:BuildMenu(defs, {
        parent = self.content,
        yOffset = 0,
        noBackdrop = true,
        centerLabels = false,
        -- Elementos por columna configurables por el usuario; las columnas se
        -- derivan solas en BuildMenu (determinista: clamp(ceil(n/esto), 2, MAX)).
        itemsPerColumn = RD.config and RD.config.Get and RD.config:Get("ui.menu.itemsPerColumn", 9) or 9,
        tooltipEnabled = function()
            local enabled = true
            if RD.config and RD.config.Get then
                enabled = RD.config:Get("ui.showTooltips", true)
            end
            return enabled
        end,
        onClick = function(item, button)
            self:OnItemClick(item, button)
        end,
        onRightClick = function(item, button)
            self:GoBack()
        end,
        onIconClick = function(item, iconButton)
            if item.isBand then
                -- ICONO de la banda: abrir el gestor de jugadores (CRUD)
                self:OpenBandManager(item)
            else
                self:ToggleAssignment(item)
            end
        end,
        onIconRightClick = function(item, iconButton)
            -- Clic derecho en el botón de asignación: anunciar el elemento con
            -- la palabra configurada (announce.<lista>.assignWord).
            if item.isBand then
                self:AnnounceBand(item)
            else
                self:AnnounceAssign(item)
            end
        end,
    })

    self.content.menuFrame = menu

    -- Anclar y redimensionar el contenido (offset fijo, sin botón Atrás:
    -- la navegación hacia atrás es con clic derecho en el menú).
    self.content:ClearAllPoints()
    self.content:SetPoint("TOPLEFT", self.frame, "TOPLEFT", CONTENT_OFFSET_X, -CONTENT_OFFSET_Y)
    self.content:SetSize(w, h)

    -- Barra de botones inferior centrada en la base del marco. Se renderiza UNA
    -- vez y UpdateBar reevalúa cada render la visibilidad (barItem.enabled) y
    -- reposiciona los visibles sin huecos, ajustando el ancho de la barra.
    local barItems = (RD.constants and RD.constants.ACTION_BAR and RD.constants.ACTION_BAR.ITEMS) or {}
    local barSize = (RD.constants and RD.constants.ACTION_BAR and RD.constants.ACTION_BAR.BUTTON_SIZE) or 20
    local barPad = (RD.constants and RD.constants.ACTION_BAR and RD.constants.ACTION_BAR.BUTTON_PADDING) or 4
    local visibleBar = 0
    if #barItems > 0 and self.actionBar and RD.ui and RD.ui.menuFactory then
        self.actionBar:SetPoint("BOTTOM", self.frame, "BOTTOM", 0, BAR_BOTTOM)
        if not self.actionBar.rendered then
            RD.ui.menuFactory:RenderBar(self.actionBar, barItems, {
                tooltipEnabled = function()
                    local enabled = true
                    if RD.config and RD.config.Get then
                        enabled = RD.config:Get("ui.showTooltips", true)
                    end
                    return enabled
                end,
            })
            self.actionBar.rendered = true
            -- Re-setear texturas poco después: en 3.3.5a los iconos nuevos a
            -- veces no cargan hasta re-asignarlos.
            local mm = RD.modules and RD.modules.messageManager
            if mm and mm.Schedule then
                mm:Schedule(0.5, function()
                    if not self.actionBar then return end
                    for _, btn in ipairs({ self.actionBar:GetChildren() }) do
                        if btn.icon and btn.icon.SetTexture and btn.icon:GetTexture() then
                            btn.icon:SetTexture(btn.icon:GetTexture())
                        end
                    end
                end)
            end
        end
        if RD.ui.menuFactory.UpdateBar then
            visibleBar = RD.ui.menuFactory:UpdateBar(self.actionBar) or 0
        else
            visibleBar = #barItems
        end
    end
    local barWidth = math.max(0, visibleBar * (barSize + barPad) - barPad)

    -- Redimensionar el marco para contener SIEMPRE contenido y barra (margen 8px).
    local sideMargin = 8
    local frameWidth = math.max(w + 2 * sideMargin, barWidth + 2 * sideMargin)
    local frameHeight = CONTENT_OFFSET_Y + h + BAR_HEIGHT + BAR_BOTTOM + BAR_BOTTOM_PAD
    self.frame:SetSize(frameWidth, frameHeight)

    if RD.ui and RD.ui.layout and RD.ui.layout.EnsureVisible then
        RD.ui.layout:EnsureVisible(self.frame, 8)
    end
end

-- Maneja el clic en un ítem del menú
function MenuFrame:OnItemClick(item, button)
    if not item then return end
    if item.chooseBand then
        -- Selector de banda: registra al jugador pendiente en la banda elegida
        self:ChooseBandForPendingRole(item.bandIndex)
        return
    end
    if item.isBand then
        -- TEXTO de la banda: anunciar en el canal configurado
        self:AnnounceBand(item)
        return
    end
    if item.dynamic then
        -- Submenú dinámico con los elementos de una lista de configuración
        self:ShowDynamicList(item.dynamic)
    elseif item.submenu then
        self:NavigateTo(item.submenu)
    elseif item.action then
        -- La acción puede no estar registrada aún al construir la UI
        pcall(function()
            if RD.MenuActions and RD.MenuActions.Execute then
                RD.MenuActions:Execute(item.action, { button = button, item = item })
            end
        end)
    elseif self.currentSource and self.currentSource.type == "list" then
        -- Elemento de una lista dinámica: anunciar por el canal configurado
        self:AnnounceListItem(self.currentSource.key, item)
    end
end

-- Re-render con debounce (CONFIG_CHANGED / CONFIG_RESET).
-- Sin C_Timer: se usa un frame OnUpdate persistente (creado en Create) que solo
-- está activo durante la ventana de debounce (0.15s).
function MenuFrame:Refresh()
    if not self.frame or not self.refreshFrame then return end
    if self.refreshFrame:IsShown() then return end

    self.refreshFrame.rdElapsed = 0
    self.refreshFrame.rdDelay = 0.15
    self.refreshFrame.rdOnFire = function()
        if self.isShown and self.frame then
            -- No crear/modificar frames en combate: diferir hasta PLAYER_REGEN_ENABLED
            if InCombatLockdown() then
                self.pendingCombatAction = true
                return
            end
            self:RenderCurrentMenu()
            self:ApplyMovable()
            self:ApplyScale()
        end
    end
    self.refreshFrame:Show()
end

RD.ui = RD.ui or {}
-- Simétrico ante reorden del .toc: si RD_UI_MenuFrame_Announce.lua cargó primero
-- (tabla con los métodos de anuncio), se fusionan sus métodos en esta tabla.
if RD.ui.menuFrame then
    for k, v in pairs(RD.ui.menuFrame) do
        if MenuFrame[k] == nil then MenuFrame[k] = v end
    end
end
RD.ui.menuFrame = MenuFrame
return MenuFrame
