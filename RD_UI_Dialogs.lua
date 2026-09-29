--[[
    RD_UI_Dialogs.lua
    PROPÓSITO: Diálogos emergentes (confirmación e entrada de texto) usando
              StaticPopupDialogs de Blizzard, como el addon base.
    API PÚBLICA:
        - RD.ui.dialogs:ShowConfirmDialog(options)
        - RD.ui.dialogs:ShowInputDialog(options)
        - RD.ui.dialogs:ShowDiscordEditPopup()
    EVENTOS: Ninguno.
]]

local addonName, private = ...
local RD = _G.RaidDominion or {}
_G.RaidDominion = RD

local Dialogs = {}

-- ESC en un popup con EditBox: el comportamiento estándar de WoW limpia el
-- texto en la primera pulsación y solo cierra con una segunda ESC. Para que el
-- popup de Discord (y los de entrada de segundos) sean escapables de una sola
-- pulsación se reemplaza el OnEscapePressed del editbox compartido mientras
-- RD_INPUT está visible, y se restaura el original al ocultarse (no debe
-- filtrarse a otros popups que reutilicen ese editbox).
local inputEscapeOriginal = nil
local escOnCancelFired = false
local function InputEscapeHook(editBox)
    editBox:SetScript("OnEscapePressed", inputEscapeOriginal)
    local dlg = StaticPopupDialogs and StaticPopupDialogs["RD_INPUT"]
    local onCancel = dlg and dlg.OnCancel
    -- El cierre por ESC debe ejecutar SIEMPRE el OnCancel del diálogo (p.ej. el
    -- DBM "PULL CANCELADO" del pull), incluso si el cliente no lo dispara en el
    -- hide. El flag evita duplicarlo si StaticPopup_Hide ya lo notificó.
    escOnCancelFired = false
    StaticPopup_Hide("RD_INPUT")
    if onCancel and not escOnCancelFired then
        escOnCancelFired = true
        pcall(onCancel)
    end
end

-- Diálogo de confirmación (estilo base v2)
function Dialogs:ShowConfirmDialog(options)
    if not options or not options.text then return end
    StaticPopupDialogs["RD_CONFIRM"] = {
        text = options.text,
        button1 = options.acceptText or YES,
        button2 = options.cancelText or CANCEL,
        OnAccept = options.onAccept,
        OnCancel = options.onCancel,
        timeout = options.timeout or 0,
        hideOnEscape = (options.hideOnEscape ~= false),
        whileDead = true,
        preferredIndex = 3,
    }
    StaticPopup_Show("RD_CONFIRM")
end

-- Diálogo de entrada de texto (con editbox), estilo base v2
function Dialogs:ShowInputDialog(options)
    if not options or not options.text then return end
    StaticPopupDialogs["RD_INPUT"] = {
        text = options.text,
        button1 = options.acceptText or "Aceptar",
        button2 = options.cancelText or "Cancelar",
        hasEditBox = true,
        maxLetters = options.maxLetters or 255,
        OnShow = function(self)
            if self.editBox then
                -- Capturar el handler original solo la primera vez; en las
                -- siguientes muestras ya es el default de nuevo (se restauró).
                if not inputEscapeOriginal then
                    inputEscapeOriginal = self.editBox:GetScript("OnEscapePressed")
                end
                self.editBox:SetScript("OnEscapePressed", InputEscapeHook)
            end
            if options.onShow then options.onShow(self) end
        end,
        OnHide = function(self)
            -- Restaurar el OnEscapePressed original al cerrar (Guardar/Cancelar)
            -- para no dejar el hook en el editbox compartido de StaticPopup.
            if self.editBox and inputEscapeOriginal then
                if self.editBox:GetScript("OnEscapePressed") == InputEscapeHook then
                    self.editBox:SetScript("OnEscapePressed", inputEscapeOriginal)
                end
            end
        end,
        OnAccept = function(self)
            local value = self.editBox and self.editBox:GetText() or ""
            if options.onAccept then options.onAccept(value) end
        end,
        OnCancel = function(self)
            escOnCancelFired = true
            if options.onCancel then options.onCancel() end
        end,
        timeout = 0,
        hideOnEscape = true,
        whileDead = true,
        exclusive = true,
        preferredIndex = 3,
    }
    StaticPopup_Show("RD_INPUT")
end

-- Popup para editar el enlace de Discord (estilo base v2)
function Dialogs:ShowDiscordEditPopup()
    self:ShowInputDialog({
        text = "Enlace de Discord:",
        acceptText = "Guardar",
        cancelText = "Cancelar",
        maxLetters = 255,
        onShow = function(self)
            local current = (RD.config and RD.config.Get and RD.config:Get("chat.discordLink", "")) or ""
            self.editBox:SetText(current)
            self.editBox:SetFocus()
        end,
        onAccept = function(value)
            if RD.config and RD.config.Set then
                -- Sanea y acota el enlace (se envía por whisper/chat): sin
                -- caracteres de control y con tope de 120 chars.
                local v = tostring(value or ""):gsub("[%c]", " "):gsub("^%s*(.-)%s*$", "%1")
                if #v > 120 then v = v:sub(1, 120):gsub("[\128-\191]*$", "") end
                RD.config:Set("chat.discordLink", v)
            end
        end,
    })
end

RD.ui = RD.ui or {}
RD.ui.dialogs = Dialogs
return Dialogs
