--[[
    RD_UI_Widgets_Dropdown.lua
    PROPÓSITO: Dropdowns de opciones reutilizables (DataOptions,
              CreateOptionsDropdown, CreatePrivacyDropdown). Compartidos por
              BandsList, BandsPlayerEditor, Spammer, Loot, RulesSpammer y los
              editores de lista (privacidad ante "Obtener" del líder).
              CreateOptionsDropdown evita el botón alto del template
              UIDropDownMenuTemplate dentro de filas de 20px: un botón pequeño
              muestra el valor actual y abre el menú al hacer clic.
    API PÚBLICA:
        - RD.ui.widgets.DataOptions(dataTable)
        - RD.ui.widgets:CreateOptionsDropdown(parent, width, opts)
        - RD.ui.widgets:CreatePrivacyDropdown(parent, listKey, opts)
    EVENTOS: Ninguno directo (escribe en RD.config vía RD.config:Set).
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

-- Nombre único para frames con templates: se delega en el contador ÚNICO de
-- RD.UIUtils (o en el exportado por RD_UI_Widgets.lua si ya cargó antes).
local UniqueName = (Widgets.UniqueName) or (RD.UIUtils and RD.UIUtils.UniqueName)

-- =============================================
-- DROPDOWN DE OPCIONES (rol, dual, líder, sanción)
-- =============================================

-- Convierte tablas de datos (BAND_ROLE/BAND_LEADER/BAND_SANCTION) en opciones
-- para CreateOptionsDropdown. Centraliza el patrón de BandsList/PlayerEditor.
function Widgets.DataOptions(dataTable)
    local opts = {}
    for _, d in ipairs(dataTable or {}) do
        opts[#opts + 1] = { key = d.key, label = d.label or d.short or d.key, color = d.color }
    end
    return opts
end

-- Botón pequeño que muestra el valor actual y abre un menú UIDropDownMenu con
-- las opciones. Evita el botón alto del template dentro de filas de 20px.
-- opts: { options = { {key,label,color}, ... }, current, onSelect(key), emptyLabel }
-- Devuelve { button, menu, text, GetValue(), SetValue(v) }.
function Widgets:CreateOptionsDropdown(parent, width, opts)
    if not parent or not opts then return nil end
    local options = opts.options or {}
    local emptyLabel = opts.emptyLabel or "—"
    local current = opts.current or ""
    -- Color del texto del valor mostrado (por defecto gris claro). Permite un
    -- acento más vivo (p.ej. dorado) para los dropdown de título de ventana.
    local textColor = opts.textColor or { 0.6, 0.6, 0.6 }

    local function LabelFor(key)
        if key == nil or key == "" then return emptyLabel end
        for _, o in ipairs(options) do
            if o.key == key then return o.label end
        end
        return emptyLabel
    end
    local function ColorFor(key)
        for _, o in ipairs(options) do
            if o.key == key then return o.color or textColor end
        end
        return textColor
    end

    local btn = CreateFrame("Button", UniqueName("ODb"), parent)
    btn:SetSize(width or 140, 20)
    btn:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    local text = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    btn:SetFontString(text)
    text:SetJustifyH("CENTER")
    text:SetPoint("LEFT", btn, "LEFT", 2, 0)
    text:SetPoint("RIGHT", btn, "RIGHT", -2, 0)

    local menu = CreateFrame("Frame", UniqueName("ODm"), parent, "UIDropDownMenuTemplate")
    menu:Hide()

    local function Paint()
        text:SetText(LabelFor(current))
        local c = ColorFor(current)
        text:SetTextColor(c[1], c[2], c[3])
    end
    Paint()

    local function InitFunc()
        -- Opción vacía ("—") opcional: se omite cuando hideEmpty=true (p.ej. en
        -- el título de una ventana que siempre tiene un valor válido).
        if not opts.hideEmpty then
            local info = UIDropDownMenu_CreateInfo()
            info.text = emptyLabel
            info.value = ""
            info.checked = (current == "" or current == nil)
            info.func = function()
                current = ""
                Paint()
                if opts.onSelect then opts.onSelect("") end
            end
            UIDropDownMenu_AddButton(info)
        end
        for _, o in ipairs(options) do
            local info2 = UIDropDownMenu_CreateInfo()
            info2.text = o.label
            info2.value = o.key
            info2.checked = (current == o.key)
            if o.color then
                info2.colorR, info2.colorG, info2.colorB = o.color[1], o.color[2], o.color[3]
            end
            info2.func = function()
                current = o.key
                Paint()
                if opts.onSelect then opts.onSelect(o.key) end
            end
            UIDropDownMenu_AddButton(info2)
        end
    end

    btn:SetScript("OnClick", function()
        UIDropDownMenu_Initialize(menu, InitFunc)
        UIDropDownMenu_SetAnchor(menu, 0, 0)
        -- En 3.3.5a NO existe ToggleDropdown: se usa ToggleDropDownMenu con el
        -- nombre del frame ancla (el botón trigger).
        ToggleDropDownMenu(1, nil, menu, btn:GetName(), 0, 0)
    end)

    return {
        button = btn,
        menu = menu,
        text = text,
        GetValue = function() return current end,
        SetValue = function(self, v)
            -- Soportar llamada con `:` (dd:SetValue(x)) y con `.` (dd.SetValue(x)):
            -- con `:`, self es la tabla y v el valor; con `.`, self es el valor.
            if type(self) ~= "table" then
                v = self
            end
            current = v or ""
            Paint()
        end,
    }
end

-- ============================================================
-- PRIVACIDAD DE LISTAS ANTE "Obtener" (líder)
-- Selector que se renderiza SOBRE cada lista (en la franja superior de los
-- editores con botón Obtener/Reiniciar): el líder decide cómo responde a las
-- peticiones de esa lista.
--   private = privado (no se responde)
--   ask     = preguntar primero (diálogo al líder mostrando quién pide)
--   open    = compartir sin restricción (se responde automáticamente)
-- Devuelve { label, dropdown } para leer/forzar el valor actual.
-- ============================================================
local PRIVACY_OPTIONS = {
    { key = "private", label = "Privado", color = { 0.8, 0.35, 0.35 } },
    { key = "ask",     label = "Preguntar primero", color = { 0.85, 0.75, 0.35 } },
    { key = "open",    label = "Compartir sin restricción", color = { 0.35, 0.8, 0.35 } },
}
local PRIVACY_VALID = { private = true, ask = true, open = true }

function Widgets:CreatePrivacyDropdown(parent, listKey, opts)
    if not parent then return nil end
    opts = opts or {}
    local key = tostring(listKey or "")
    local current = "open"
    if RD.config and RD.config.Get then
        current = RD.config:Get("privacy." .. key, "open")
    end
    if not PRIVACY_VALID[current] then current = "open" end

    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetText(opts.label or "Privacidad:")
    label:SetJustifyH("LEFT")
    label:SetTextColor(0.7, 0.7, 0.7)

    local dd = self:CreateOptionsDropdown(parent, opts.width or 172, {
        options = PRIVACY_OPTIONS,
        hideEmpty = true,
        current = current,
        onSelect = function(value)
            if RD.config and RD.config.Set then
                RD.config:Set("privacy." .. key, value or "open")
            end
        end,
    })

    label:SetPoint("TOPLEFT", parent, "TOPLEFT", opts.x or 0, opts.y or 0)
    if dd and dd.button then
        dd.button:SetPoint("LEFT", label, "RIGHT", 6, -5)
        if RD.UIUtils and RD.UIUtils.AddButtonTooltip and dd.button.SetScript then
            RD.UIUtils.AddButtonTooltip(dd.button, function()
                return opts.tooltip or
                    "Privacidad ante 'Obtener' del líder\n• Privado: no responde\n• Preguntar primero: pide tu confirmación\n• Compartir: responde al instante"
            end)
        end
    end

    return { label = label, dropdown = dd }
end

return Widgets