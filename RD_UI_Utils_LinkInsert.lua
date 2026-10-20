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
        - UIUtils.EnableLinkDisplay(editBox)     (clic sobre enlaces: ver/enviar)
        - UIUtils.FindLinkAtCursor(text, caret)  (detector puro, testable)
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
    chat y sin botones extra: el propio EditBox los acepta. En 3.3.5a TODAS
    las vías pasan por el global Lua ChatEdit_InsertLink: los ítems pulsados
    con shift en bolsas/banco/mercader/personaje llegan vía
    HandleModifiedItemClick (definido en FrameXML/ItemButtonTemplate.lua, que
    llama a ChatEdit_InsertLink), y misiones/logros/hechizos lo llaman
    directamente. Se envuelve UNA sola vez y, si alguno de los EditBoxes
    registrados está visible y enfocado, se inserta el enlace en el cursor
    (con un espacio previo, como hace el chat, para que sea parseable al
    reenviarlo).

    IMPORTANTE: nunca se toca ACTIVE_CHAT_EDIT_BOX con una caja del addon.
    ChatEdit_ActivateChat/DeactivateChat asumen una caja de chat REAL (header,
    focusLeft/Mid/Right, estrata): al desactivar una caja RD la ocultarían
    (estilo clásico), le borrarían el texto (estilo IM) o darían error, y
    rompería abrir el chat con Intro.

    El auto-registro es CENTRAL: el CreateFrame del addon se envuelve una sola
    vez y todo EditBox cuya propiedad sea del addon (nombre "RD*"/"RaidDominion*"
    o ancestro con ese nombre) hereda este comportamiento automáticamente, con
    o sin nombre. Los campos EXCLUSIVAMENTE numéricos (SetNumeric(true), p.ej.
    duración, gearscore o tiempo) se excluyen en caliente: jamás reciben
    enlaces (un enlace no cabe en un número).
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

function UIUtils.EnableLinkInsertion(editBox)
    if not editBox or not editBox.Insert then return false end
    if editBox.GetObjectType and editBox:GetObjectType() ~= "EditBox" then return false end
    if editBox.RD_linkInsertionDisabled then return false end
    linkBoxes[editBox] = true
    -- Marca de identificación de cajas del addon (la usa EnableLinkDisplay al
    -- elegir destino de chat para no pisar una caja RD). NO se toca
    -- ACTIVE_CHAT_EDIT_BOX: ver la nota del encabezado.
    editBox.RD_linkInsertionRegistered = true

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
    return true
end

-- Devuelve el enlace crudo (|c...|H...|h[...]|h|r) que contiene la posición
-- `caret` de un texto, junto con el índice de su último byte (posición de la
-- 'r' de |r). `caret` usa la convención de GetCursorPosition (nº de bytes a la
-- izquierda del cursor). Un |H suelto sin cierre |h|r no es un enlace.
function UIUtils.FindLinkAtCursor(text, caret)
    if not text or text == "" or not caret or caret < 1 then return nil end
    local pos = 1
    while true do
        local head = text:find("|H", pos, true)
        if not head or head > caret then return nil end
        local closeAt = text:find("|h|r", head + 2, true)
        if not closeAt then return nil end
        local endlink = closeAt + 3
        if caret < endlink then
            -- El enlace incluye su código de color (|cFFRRGGBB) si lo tiene.
            local startlink = head
            local colorAt = head - 10
            if colorAt >= 1 and text:sub(colorAt, colorAt + 1) == "|c"
                and text:sub(colorAt + 2, colorAt + 9):match("^%x%x%x%x%x%x%x%x$") then
                startlink = colorAt
            end
            if caret >= startlink then
                return text:sub(startlink, endlink), endlink
            end
        end
        pos = endlink + 1
    end
end

--[[
    Habilita en un EditBox el comportamiento CLICABLE de los enlaces que
    contenga (ítems, hechizos, misiones, logros...), igual que el chat:
      - clic: ver el enlace (SetItemRef; para ítems abre su ventana/tooltip).
      - shift-clic: enviarlo al chat (usa la ventana activa; si no hay ninguna,
        abre el campo de chat y lo inserta), como es estándar.
      - el clic no deja el texto del enlace en edición: el cursor se retira
        justo después del enlace.
    En 3.3.5a el EditBox NO soporta SetHyperlinksEnabled (esa API solo existe
    en ScrollingMessageFrame y SimpleHTML): se usa la técnica del clásico
    TinyPad — al soltar el botón se lee la posición del cursor que el propio
    clic colocó en el texto y se busca el enlace que la contiene.
    Idempotente por caja; no interfiere con la inserción (EnableLinkInsertion).
]]
function UIUtils.EnableLinkDisplay(editBox)
    if not editBox or not editBox.GetCursorPosition then return false end
    if editBox.RD_linkDisplayRegistered then return true end
    editBox.RD_linkDisplayRegistered = true

    local origMouseUp = editBox:GetScript("OnMouseUp")
    editBox:SetScript("OnMouseUp", function(self, button)
        if origMouseUp then origMouseUp(self, button) end
        local link, endlink = UIUtils.FindLinkAtCursor(self:GetText(), self:GetCursorPosition())
        if not link then return end
        if _G.IsModifiedClick and _G.IsModifiedClick("CHATLINK") then
            -- Shift-clic: enviar el enlace al chat, como es estándar. Se usa la
            -- ventana de chat activa si existe; si no (el clic en la nota
            -- desactivó el chat), se abre el campo de chat de destino
            -- (ChatEdit_ChooseBoxForSend: por defecto el marco de siempre) y se
            -- inserta ahí. Jamás en una caja RD.
            local target = _G.ChatEdit_GetActiveWindow and _G.ChatEdit_GetActiveWindow()
            if not target or target.RD_linkInsertionRegistered then
                target = _G.ChatEdit_ChooseBoxForSend and _G.ChatEdit_ChooseBoxForSend()
            end
            if target and _G.ChatEdit_ActivateChat and not target.RD_linkInsertionRegistered then
                -- Defensa: si ACTIVE apuntase a una caja RD, ChatEdit_ActivateChat
                -- la desactivaría por dentro (ocultar/borrar su texto). Nunca
                -- debe llegar una caja RD a ChatEdit_DeactivateChat.
                local active = _G.ACTIVE_CHAT_EDIT_BOX
                if active and active.RD_linkInsertionRegistered then
                    _G.ACTIVE_CHAT_EDIT_BOX = nil
                end
                _G.ChatEdit_ActivateChat(target)
                target:Insert(link)
                return
            end
        end
        if _G.SetItemRef then
            -- Igual que el chat: primer argumento = dato del enlace.
            local linkData = link:match("|H(.-)|h")
            _G.SetItemRef(linkData or link, link, button)
        end
        -- "Sin ser editable": el cursor sale del enlace (tras su |r).
        self:SetCursorPosition(endlink)
    end)
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
