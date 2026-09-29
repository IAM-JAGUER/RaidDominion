--[[
    RD_UI_Widgets_ItemSearch.lua
    PROPÓSITO: Buscador de ítems para registrar un objetivo ("meta") de
              equipamiento: un EditBox con lista filtrada (helper de búsqueda)
              sobre los ítems que el jugador ha VISTO (bolsas, equipo e
              historial de botín; no hay base de datos de ítems en 3.3.5a).
              El usuario escribe el nombre, elige un resultado de la lista (o
              pulsa Registrar para aceptar el texto tal cual). Normaliza
              minúsculas + acentos esMX para que "Corona" encuentre "Corona".
              Con opts.linkOnly = true el campo NO busca por nombre: acepta
              únicamente un ENLACE de ítem (Mayús+clic o pegar) que se resuelve
              con opts.parseLink(texto) -> entry|nil; el texto inválido se
              tiñe de rojo y rdSearchFirstMatch() devuelve nil.
    API PÚBLICA:
        - RD.ui.widgets:CreateItemSearch(parent, opts) -> edit
              opts = { width, placeholder?, maxResults? = 8, onPick(entry)?,
                       linkOnly? = false, parseLink?(texto) -> entry|nil }
              entry = { name, itemID?, quality?, ilvl?, icon?, link? }
              edit.rdSearchSetItems(list)      -- fuente de la búsqueda (no en linkOnly)
              edit.rdSearchGetText()           -- texto real (sin el placeholder)
              edit.rdSearchSetText(t)          -- fija texto y refresca la lista
              edit.rdSearchClear()             -- limpia (vuelve al placeholder)
              edit.rdSearchFirstMatch()        -- mejor resultado actual o nil
        - RD.ui.widgets.NormalizeItemName(text)   -> minúsculas + plegado de acentos
        - RD.ui.widgets.FilterItemSearch(query, items, max) -> resultados ordenados
    EVENTOS: OnTextChanged/OnEscapePressed/OnEnterPressed/OnEditFocus* del
             EditBox; OnClick de cada fila de resultados.
]]

local addonName, private = ...
local RD = _G.RaidDominion or {}
_G.RaidDominion = RD

-- La tabla de widgets se reutiliza si ya existe (convención RD_UI_Widgets_*).
RD.ui = RD.ui or {}
local Widgets = RD.ui.widgets
if not Widgets then
    Widgets = {}
    RD.ui.widgets = Widgets
end

local UniqueName = (RD.UIUtils and RD.UIUtils.UniqueName)
    or function(prefix) return prefix end

local DEFAULT_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

-- ============================================================================
-- Normalización de nombres (minúsculas + plegado de acentos esMX)
-- ============================================================================

-- Mapa de pares de bytes UTF-8 de letras acentuadas → su base sin acento.
local FOLD = {
    ["\195\129"] = "a", ["\195\160"] = "a", ["\195\161"] = "a",
    ["\195\137"] = "e", ["\195\168"] = "e", ["\195\169"] = "e",
    ["\195\141"] = "i", ["\195\172"] = "i", ["\195\173"] = "i",
    ["\195\147"] = "o", ["\195\178"] = "o", ["\195\179"] = "o",
    ["\195\154"] = "u", ["\195\185"] = "u", ["\195\186"] = "u", ["\195\188"] = "u",
    ["\195\145"] = "n", ["\195\177"] = "n",
    ["\195\135"] = "c", ["\195\167"] = "c",
}

function Widgets.NormalizeItemName(text)
    local s = string.lower(tostring(text or ""))
    return (s:gsub("[\194-\195][\128-\191]", function(pair)
        return FOLD[pair] or pair
    end))
end

-- Filtra `items` por `query` (subcadena normalizada), ordenando primero los que
-- empiezan con el prefijo y luego alfabético. Acotado a `max` resultados.
function Widgets.FilterItemSearch(query, items, max)
    if type(items) ~= "table" then return {} end
    max = max or 8
    local q = Widgets.NormalizeItemName(query)
    if q == "" then return {} end

    local out = {}
    for i = 1, #items do
        local it = items[i]
        if it and it.name then
            if Widgets.NormalizeItemName(it.name):find(q, 1, true) then
                out[#out + 1] = it
            end
        end
    end
    table.sort(out, function(a, b)
        local an, bn = Widgets.NormalizeItemName(a.name), Widgets.NormalizeItemName(b.name)
        local ap = an:sub(1, #q) == q
        local bp = bn:sub(1, #q) == q
        if ap ~= bp then return ap end
        return an < bn
    end)
    if #out > max then
        local cut = {}
        for i = 1, max do cut[i] = out[i] end
        return cut
    end
    return out
end

-- ============================================================================
-- Widget: EditBox + lista de resultados desplegable
-- ============================================================================

local ROW_H = 18
local ROW_GAP = 2

function Widgets:CreateItemSearch(parent, opts)
    if not parent then return nil end
    opts = opts or {}
    local width = opts.width or 200
    local maxResults = opts.maxResults or 8
    local placeholder = opts.placeholder or ""

    local edit = CreateFrame("EditBox", UniqueName("ISe"), parent, "InputBoxTemplate")
    -- Alto de la fila de acción (Metrics.ACTION_H = 24): StyleInput lo refuerza
    -- de todos modos; usar la misma constante que los botones de la fila evita
    -- el desfase de altura entre el input (24) y los chips (20) en los paneles.
    local actionH = (RD.UIUtils and RD.UIUtils.Metrics and RD.UIUtils.Metrics.ACTION_H) or 24
    edit:SetSize(width, actionH)
    edit:SetAutoFocus(false)
    if RD.UIUtils and RD.UIUtils.StyleInput then RD.UIUtils.StyleInput(edit) end

    -- Texto "real": si es el placeholder, cuenta como vacío.
    local function GetRealText()
        local t = edit:GetText() or ""
        if placeholder ~= "" and t == placeholder then return "" end
        return t
    end

    -- ============================================================================
    -- Modo "solo enlaces de ítem": sin lista de búsqueda. El campo acepta un
    -- enlace de ítem (Mayús+clic desde bolsas/chat o pegar el enlace) y lo
    -- resuelve con opts.parseLink(texto) -> entry|nil. El texto inválido se
    -- tiñe de rojo y rdSearchFirstMatch() devuelve nil (Registrar no procede).
    -- ============================================================================
    if opts.linkOnly then
        local parseLink = opts.parseLink
        local current = nil

        local function ParseText()
            local t = GetRealText()
            current = nil
            if t == "" then
                edit:SetTextColor(1, 1, 1)
                return
            end
            -- Solo un ENLACE de ítem real (marca |Hitem:) se acepta; el texto
            -- plano o de otro tipo de enlace se marca como inválido en rojo.
            local entry = (parseLink and string.find(t, "|Hitem:") and parseLink(t)) or nil
            if entry and entry.name then
                current = entry
                edit:SetTextColor(1, 1, 1)
            else
                edit:SetTextColor(1, 0.4, 0.4)
            end
        end

        edit.rdSearchSetItems = function() end
        edit.rdSearchGetText = function() return GetRealText() end
        edit.rdSearchSetText = function(self, t)
            edit:SetTextColor(1, 1, 1)
            edit:SetText(t or "")
            ParseText()
        end
        edit.rdSearchClear = function()
            current = nil
            if placeholder ~= "" then
                edit:SetText(placeholder)
                edit:SetTextColor(0.6, 0.6, 0.6)
            else
                edit:SetText("")
                edit:SetTextColor(1, 1, 1)
            end
        end
        edit.rdSearchFirstMatch = function()
            return current
        end

        if placeholder ~= "" then
            edit:SetText(placeholder)
            edit:SetTextColor(0.6, 0.6, 0.6)
        end
        edit:SetScript("OnEditFocusGained", function(self)
            if placeholder ~= "" and self:GetText() == placeholder then
                self:SetText("")
                self:SetTextColor(1, 1, 1)
            end
        end)
        edit:SetScript("OnEditFocusLost", function(self)
            if self:GetText() == "" and placeholder ~= "" then
                self:SetText(placeholder)
                self:SetTextColor(0.6, 0.6, 0.6)
            end
        end)
        edit:SetScript("OnTextChanged", function(self, userInput)
            if userInput then ParseText() end
        end)
        edit:SetScript("OnEscapePressed", function()
            edit.rdSearchClear()
            edit:ClearFocus()
        end)
        edit:SetScript("OnEnterPressed", function()
            local first = edit.rdSearchFirstMatch()
            if first and opts.onPick then opts.onPick(first) end
            edit:ClearFocus()
        end)

        return edit
    end

    -- Lista de resultados: hija del EditBox (se oculta/desmonta con él) y
    -- anclada bajo él; los Frames planos no recortan hijos, así que se dibuja
    -- por encima del contenido de la sección.
    local list = CreateFrame("Frame", UniqueName("ISl"), edit)
    list:SetSize(width, 1)
    list:SetPoint("TOPLEFT", edit, "TOPLEFT", 0, -22)
    list:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 8,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    list:SetBackdropColor(0, 0, 0, 0.9)
    list:SetBackdropBorderColor(1, 0.82, 0, 0.5)
    list:Hide()

    local rows = {}
    local items = {}

    local function HideList()
        list:Hide()
        for i = 1, #rows do rows[i]:Hide() end
    end

    local function MakeRow()
        local r = CreateFrame("Button", UniqueName("ISr"), list)
        r:SetSize(width, ROW_H)
        r:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 8,
            insets = { left = 1, right = 1, top = 1, bottom = 1 },
        })
        r:SetBackdropColor(0.1, 0.1, 0.1, 0.6)
        r:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.4)
        r:SetHighlightTexture("Interface\\Buttons\\UI-Listbox-Highlight2", "ADD")
        local icon = r:CreateTexture(nil, "ARTWORK")
        icon:SetSize(16, 16)
        icon:SetPoint("LEFT", r, "LEFT", 3, 0)
        icon:SetTexture(DEFAULT_ICON)
        local name = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        name:SetPoint("LEFT", icon, "RIGHT", 4, 0)
        name:SetPoint("RIGHT", r, "RIGHT", -2, 0)
        name:SetJustifyH("LEFT")
        name:SetTextHeight(11)
        r.rdIcon = icon
        r.rdName = name
        r:SetScript("OnClick", function()
            local entry = r.rdEntry
            if entry and opts.onPick then opts.onPick(entry) end
        end)
        return r
    end

    local function Refresh()
        local q = GetRealText()
        if q == "" then HideList() return end
        local res = Widgets.FilterItemSearch(q, items, maxResults)
        if #res == 0 then HideList() return end

        local y = 4
        for i = 1, #res do
            local r = rows[i]
            if not r then
                r = MakeRow()
                rows[i] = r
            end
            r.rdEntry = res[i]
            r.rdIcon:SetTexture(res[i].icon or DEFAULT_ICON)
            local qc = (RD.constants and RD.constants.ITEM_QUALITY_COLORS and RD.constants.ITEM_QUALITY_COLORS[res[i].quality])
                or { 1, 1, 1 }
            r.rdName:SetText(res[i].name or "")
            r.rdName:SetTextColor(qc[1], qc[2], qc[3])
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", list, "TOPLEFT", 2, -y)
            r:Show()
            y = y + ROW_H + ROW_GAP
        end
        for i = #res + 1, #rows do rows[i]:Hide() end
        list:SetHeight(y + 2)
        list:Show()
    end

    -- Placeholder (el EditBox de 3.3.5a no tiene texto de marcador nativo)
    if placeholder ~= "" then
        edit:SetText(placeholder)
        edit:SetTextColor(0.6, 0.6, 0.6)
    end
    edit:SetScript("OnEditFocusGained", function(self)
        if placeholder ~= "" and self:GetText() == placeholder then
            self:SetText("")
            self:SetTextColor(1, 1, 1)
        end
    end)
    edit:SetScript("OnEditFocusLost", function(self)
        if self:GetText() == "" and placeholder ~= "" then
            self:SetText(placeholder)
            self:SetTextColor(0.6, 0.6, 0.6)
        end
        HideList()
    end)

    -- API del buscador (sobre el frame del EditBox)
    edit.rdSearchSetItems = function(self, list)
        items = list or {}
    end
    edit.rdSearchGetText = function()
        return GetRealText()
    end
    edit.rdSearchSetText = function(self, t)
        edit:SetTextColor(1, 1, 1)
        edit:SetText(t or "")
        Refresh()
    end
    edit.rdSearchClear = function()
        if placeholder ~= "" then
            edit:SetText(placeholder)
            edit:SetTextColor(0.6, 0.6, 0.6)
        else
            edit:SetText("")
        end
        HideList()
    end
    edit.rdSearchFirstMatch = function()
        local q = GetRealText()
        if q == "" then return nil end
        return Widgets.FilterItemSearch(q, items, 1)[1]
    end

    edit:SetScript("OnTextChanged", function(self, userInput)
        if userInput then Refresh() end
    end)
    edit:SetScript("OnEscapePressed", function()
        edit.rdSearchClear()
        edit:ClearFocus()
    end)
    edit:SetScript("OnEnterPressed", function()
        local first = edit.rdSearchFirstMatch()
        if first and opts.onPick then opts.onPick(first) end
        edit:ClearFocus()
    end)

    return edit
end

return Widgets