--[[
    RD_UI_Widgets_Scroll.lua
    PROPÓSITO: Visibilidad de filas en los editores de lista con scroll
              (ApplyScrollVisibility / ScheduleVisibilityRefresh /
              SetRowMouseEnabled). En 3.3.5a un ScrollFrame recorta el DIBUJO
              de su contenido pero NO la captura del ratón: las filas que quedan
              fuera del viewport (por scroll o por exceso de ítems) siguen
              recibiendo clics "a través" de lo que quede sobrepuesto. Estas
              funciones inactivan el ratón de esas filas (fila + controles) y lo
              reactivan cuando vuelven a la vista, sin ocultarlas jamás.
              Compartido por CreateList, CreateContentList y CreateBands.
    API PÚBLICA:
        - RD.ui.widgets:ApplyScrollVisibility(scroll, frames)
        - RD.ui.widgets:ScheduleVisibilityRefresh(scroll)
        - RD.ui.widgets:SetRowMouseEnabled(frame, enabled)
    EVENTOS: Ninguno (usa un OnUpdate one-shot auto-limitado, no un loop).
]]

local addonName, private = ...
local RD = _G.RaidDominion or {}
_G.RaidDominion = RD

-- La tabla de widgets se reutiliza si ya existe: así ningún widget de otro
-- archivo (RD_UI_Widgets_*) se pierde aunque el orden de carga varíe.
RD.ui = RD.ui or {}
local Widgets = RD.ui.widgets
if not Widgets then
    Widgets = {}
    RD.ui.widgets = Widgets
end

-- =============================================
-- VISIBILIDAD DE FILAS EN SCROLL (editores de lista)
-- En 3.3.5a un ScrollFrame recorta el DIBUJO de su contenido, pero NO recorta la
-- captura del ratón: las filas que quedan fuera del viewport (por hacer scroll o
-- por tener más ítems de los que caben) siguen recibiendo clics "a través" de lo
-- que quede sobrepuesto (p.ej. los campos de anuncios situados bajo la lista).
-- Esta función inactiva esas filas fuera de rango (fila + todos sus controles,
-- ver SetRowMouseEnabled) para que no intercepten el clic, y las reactiva cuando
-- vuelven a la vista. `frames` es la lista de frames del contenido del scroll
-- (filas del editor). El refresco se registra en scroll.RDRefreshVisibility para
-- re-evaluarse en cada scroll.
--
-- IMPORTANTE (3.3.5a): NO se ocultan las filas con Hide(). Un frame oculto deja
-- de actualizar su layout y sus coordenadas de pantalla (GetTop/GetBottom) al
-- desplazar el scroll child, así que nunca volvería a "entrar" al viewport y los
-- ítems de la cola no se verían jamás (regresión de los iconos que activan el
-- scroll). Manteniendo la fila VISIBLE, el ScrollFrame recorta su dibujo fuera
-- del viewport y el layout sigue vivo: al scrollear la fila vuelve a ser
-- interactiva en cuanto su borde inferior entra en el viewport.
function Widgets:ApplyScrollVisibility(scroll, frames)
    if not scroll or type(frames) ~= "table" then return end
    scroll.RDRefreshVisibility = function()
        local st = scroll:GetTop()
        local sb = scroll:GetBottom()
        if not st or not sb then return end
        for i = 1, #frames do
            local f = frames[i]
            if f and f.GetTop and f.GetBottom then
                local ft = f:GetTop()
                local fb = f:GetBottom()
                if ft and fb then
                    -- Se muestra si su borde INFERIOR queda dentro del viewport
                    -- (fb entre sb y st). NO basta con "interseca": en 3.3.5a el
                    -- ScrollFrame recorta el DIBUJO pero no el ratón, así que la
                    -- cola de una fila que asoma por el borde inferior queda
                    -- físicamente por debajo del scroll, invisible pero capturando
                    -- el clic a través de los campos que haya bajo el editor (p.ej.
                    -- los anuncios de banda). El borde superior no sufre esto: la
                    -- franja fija (addBar/headerBar) se elevó sobre el contenido y
                    -- gana el clic en su zona, por eso ahí se conserva la tolerancia
                    -- de "roza el borde" sin fuga.
                    local visible = (fb <= st) and (fb >= sb)
                    if visible then
                        Widgets:SetRowMouseEnabled(f, true)
                    else
                        -- Antes de inactivar el ratón se libera el foco de teclado:
                        -- un EditBox sin foco real y sobre un área recortada no debe
                        -- conservarlo (y de paso evita el fantasma de 3.3.5a).
                        local nb = f.nameBox
                        if nb and nb.ClearFocus then nb:ClearFocus() end
                        Widgets:SetRowMouseEnabled(f, false)
                    end
                end
            end
        end
    end
    scroll:RDRefreshVisibility()
    Widgets:ScheduleVisibilityRefresh(scroll)
end

-- Programa un refresco de visibilidad one-shot para el frame siguiente.
-- En 3.3.5a, SetVerticalScroll/SetHeight reposicionan el child del ScrollFrame
-- pero la geometría de las filas (GetTop/GetBottom) se resuelve en el siguiente
-- pase de layout: re-evaluar sincrónicamente dentro del evento de scroll usa
-- coordenadas obsoletas y puede dejar la última fila (o la cola) desactivada
-- aunque ya sea visible. El OnUpdate se auto-limita (se limpia al dispararse),
-- no es un loop continuo.
function Widgets:ScheduleVisibilityRefresh(scroll)
    if not scroll or not scroll.SetScript or not scroll.GetScript then return end
    if scroll:GetScript("OnUpdate") then return end
    scroll:SetScript("OnUpdate", function(self)
        self:SetScript("OnUpdate", nil)
        if self.RDRefreshVisibility then self:RDRefreshVisibility() end
    end)
end

-- Inactiva o restaura la captura de ratón de una fila de editor y de todos sus
-- controles (EditBox, botones, dropdowns, grip...), sin tocar su visibilidad.
-- NUNCA oculta la fila: en 3.3.5a ocultar un frame congela sus coordenadas al
-- hacer scroll y la fila no reaparecería; dejándola visible el layout se
-- recalcula al desplazar el child y al volver a entrar en el viewport se
-- reactiva su interacción. El estado original de cada frame se guarda en
-- f.rdMouseStates la primera desactivación y se restaura al reactivar.
function Widgets:SetRowMouseEnabled(frame, enabled)
    if not frame or not frame.EnableMouse then return end
    if enabled then
        if frame.rdMouseStates then
            for c, wasOn in pairs(frame.rdMouseStates) do
                if c and c.EnableMouse then c:EnableMouse(wasOn) end
            end
            frame.rdMouseStates = nil
        end
        return
    end
    -- Desactivar: guarda el estado original solo una vez
    if not frame.rdMouseStates then
        local states = {}
        local function collect(f, depth)
            if not f or not f.EnableMouse or depth > 6 then return end
            states[f] = (f.IsMouseEnabled and f:IsMouseEnabled()) or false
            if f.GetNumChildren and f.GetChildren then
                for i = 1, f:GetNumChildren() do
                    local c = (select(i, f:GetChildren()))
                    if c then collect(c, depth + 1) end
                end
            end
        end
        collect(frame, 1)
        frame.rdMouseStates = states
    end
    local function apply(f, depth)
        if not f or not f.EnableMouse or depth > 6 then return end
        f:EnableMouse(false)
        if f.GetNumChildren and f.GetChildren then
            for i = 1, f:GetNumChildren() do
                local c = (select(i, f:GetChildren()))
                if c then apply(c, depth + 1) end
            end
        end
    end
    apply(frame, 1)
end

return Widgets