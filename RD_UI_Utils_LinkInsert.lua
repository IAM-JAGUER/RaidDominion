--[[
    RD_UI_Utils_LinkInsert.lua
    PROPÓSITO: Inserción de enlaces del juego en los EditBoxes del addon (ítems,
              hechizos/profesiones, misiones y logros), igual que el cuadro de
              chat y sin botones extra: el propio campo los acepta. El registro
              es CENTRAL: una sola vez se envuelve CreateFrame y todo EditBox
              perteneciente al addon hereda el comportamiento; los campos
              exclusivamente numéricos se excluyen.
    API PÚBLICA (registrada sobre RD.UIUtils):
        - UIUtils.EnableLinkInsertion(editBox)   (idempotente por caja)
        - UIUtils.DisableLinkInsertion(editBox)  (opt-out de campos numéricos)
    ORDEN: cargar DESPUÉS de RD_UI_Utils.lua y ANTES de cualquier widget que
           cree EditBoxes (ver RaidDominion.toc).
    EVENTOS: Ninguno.
]]

local addonName, private = ...
local RD = _G.RaidDominion or {}
local UIUtils = RD.UIUtils or {}
--[[
    Habilita en un EditBox la inserción de enlaces del juego (shift-clic de
    ítems, hechizos/profesiones, misiones y logros), igual que el cuadro de
    chat y sin botones extra: el propio EditBox los acepta. Dos vías en 3.3.5a:
      - Misiones/logros/hechizos llaman al global ChatEdit_InsertLink: se
        envuelve UNA sola vez y, si alguno de los EditBoxes registrados está
        visible y enfocado, se inserta el enlace en el cursor (con un espacio
        previo, como hace el chat, para que sea parseable al reenviarlo).
      - Ítems: HandleModifiedItemClick (C-side, no pasa por Lua) inserta en
        ACTIVE_CHAT_EDIT_BOX — el mismo receptor que usa ChatEdit_InsertLink —,
        que solo se setea para cajas de chat reales (ChatEdit_ActivateChat).
        Mientras una caja registrada esté visible y enfocada se registra como
        ACTIVE_CHAT_EDIT_BOX y se libera al perder el foco u ocultarse; con eso
        el shift-clic de un ítem llega a la caja. Nunca se usa
        ChatEdit_ActivateChat: toca header/focusLeft/Mid/Right y frame strata,
        recursos que una caja de contenido no tiene.

    El auto-registro es CENTRAL: el CreateFrame del addon se envuelve una sola
    vez y todo EditBox cuya propiedad sea del addon (nombre "RD*"/"RaidDominion*"
    o ancestro con ese nombre) hereda este comportamiento automáticamente, con
    o sin nombre. Los campos EXCLUSIVAMENTE numéricos (SetNumeric(true), p.ej.
    duración, gearscore o tiempo) se excluyen en caliente: jamás reciben ACTIVE
    ni enlaces (un enlace no cabe en un número).
]]
local linkBoxes = {}
local linkHookInstalled = false

local function IsNumericBox(box)
    if not (box and box.GetNumeric) then return false end
    local ok, numeric = pcall(box.GetNumeric, box)
    return ok and numeric == true
end

-- Un EditBox recibe enlaces solo si no está deshabilitado y no es numérico.
local function LinkBoxAllowed(box)
    if not box then return false end
    if box.RD_linkInsertionDisabled then return false end
    if IsNumericBox(box) then return false end
    return true
end

local function LinkBoxReady(box)
    if not (box and box.IsShown and box.HasFocus) then return false end
    -- Métodos de widget con ':' (en WoW hay que pasar el frame como primer
    -- argumento; `.IsShown()` sin argumentos da "used '.' instead of ':'").
    if not LinkBoxAllowed(box) then return false end
    return box:IsShown() and box:HasFocus()
end

local function FocusedLinkBox()
    for box in pairs(linkBoxes) do
        if LinkBoxReady(box) then
            return box
        end
    end
    return nil
end

local function ClearActiveEditBox(box)
    if _G.ACTIVE_CHAT_EDIT_BOX == box then
        _G.ACTIVE_CHAT_EDIT_BOX = nil
    end
end

function UIUtils.EnableLinkInsertion(editBox)
    if not editBox or not editBox.Insert then return false end
    if editBox.GetObjectType and editBox:GetObjectType() ~= "EditBox" then return false end
    if editBox.RD_linkInsertionDisabled then return false end
    linkBoxes[editBox] = true

    -- Registrar la caja como ACTIVE_CHAT_EDIT_BOX mientras esté visible y
    -- enfocada (vía de inserción de ítems). Solo se toma el rol si no hay otra
    -- caja activa o esta ya es propia: jamás se pisa una caja de chat real.
    -- Los campos numéricos/deshabilitados quedan fuera. Preserva los scripts
    -- previos (WrapScript encadena) y es idempotente por caja.
    if not editBox.RD_linkInsertionRegistered then
        editBox.RD_linkInsertionRegistered = true
        local function WrapScript(name, handler)
            local orig = editBox:GetScript(name)
            editBox:SetScript(name, function(self, ...)
                if orig then orig(self, ...) end
                return handler(self, ...)
            end)
        end
        WrapScript("OnEditFocusGained", function(self)
            if not LinkBoxAllowed(self) then return end
            local active = _G.ACTIVE_CHAT_EDIT_BOX
            if not active or active == self or linkBoxes[active] then
                _G.ACTIVE_CHAT_EDIT_BOX = self
            end
        end)
        WrapScript("OnEditFocusLost", function(self)
            ClearActiveEditBox(self)
        end)
        WrapScript("OnHide", function(self)
            ClearActiveEditBox(self)
        end)
    end

    if linkHookInstalled then return true end
    linkHookInstalled = true
    local origInsertLink = _G.ChatEdit_InsertLink
    _G.ChatEdit_InsertLink = function(text)
        local box = FocusedLinkBox()
        if box then
            pcall(function()
                box:Insert(" " .. tostring(text or ""))
            end)
            return true
        end
        if origInsertLink then
            return origInsertLink(text)
        end
        return false
    end
    return true
end

-- Excluye un EditBox del soporte de enlaces (para campos exclusivamente
-- numéricos como duración, gearscore o tiempo: un enlace no cabe en un número).
-- Complementa/refuerza el chequeo numérico dinámico de LinkBoxAllowed.
function UIUtils.DisableLinkInsertion(editBox)
    if not editBox then return false end
    editBox.RD_linkInsertionDisabled = true
    linkBoxes[editBox] = nil
    ClearActiveEditBox(editBox)
    return true
end

-- Auto-registro central de la inserción de enlaces (ver EnableLinkInsertion).
-- Se envuelve CreateFrame UNA sola vez: todo EditBox que pertenezca al addon
-- (nombre RD*/RaidDominion* o bajo un ancestro así) hereda el comportamiento a
-- partir de su creación, sin tocar sitios de llamada a futuro. La identificación
-- por propiedad evita registrar EditBoxes de OTROS addons. El wrap nunca debe
-- romper la creación de frames del resto del cliente: la parte de registro va
-- envuelta en pcall y el CreateFrame original queda intacto (no es función
-- protegida en 3.3.5a).
do
    local origCreateFrame = _G.CreateFrame
    if origCreateFrame then
        local function BelongsToAddon(frame)
            if not frame then return false end
            local name = frame.GetName and frame:GetName()
            if name and (name:sub(1, 2) == "RD" or name:sub(1, 13) == "RaidDominion") then
                return true
            end
            local parent = frame.GetParent and frame:GetParent()
            while parent and parent ~= UIParent do
                local pname = parent.GetName and parent:GetName()
                if pname and (pname:sub(1, 2) == "RD" or pname:sub(1, 13) == "RaidDominion") then
                    return true
                end
                parent = parent.GetParent and parent:GetParent()
            end
            return false
        end
        _G.CreateFrame = function(kind, ...)
            local frame = origCreateFrame(kind, ...)
            if kind == "EditBox" and frame and BelongsToAddon(frame) then
                pcall(UIUtils.EnableLinkInsertion, frame)
            end
            return frame
        end
    end
end

RD.UIUtils = UIUtils
return UIUtils
