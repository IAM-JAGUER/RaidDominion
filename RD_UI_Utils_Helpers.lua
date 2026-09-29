--[[
    RD_UI_Utils_Helpers.lua
    PROPÓSITO: Helpers de texto/enlaces y tooltips de RD.UIUtils, extraídos de
              RD_UI_Utils.lua en la ronda 8 de refactor para mantener el padre
              ≤ ~700 líneas. Cubre: limpieza/capitalización de nombres
              (CleanName/CapitalizeName), retirada de marcado de enlaces
              (StripMarkup/LinkLabel), descomposición y re-inyección de enlaces
              (LinkParts/ReinjectVisible), edición segura del texto visible de
              un enlace (MakeLinkAwareEditBox), detección de icono desde enlace
              (LinkInfo), tooltip compartido con ancho acotado (ShowTooltip),
              gate de tooltips (TooltipsEnabled) y hover/tooltip de filas y
              botones (AddRowHover/AddButtonTooltip). Se registra sobre la MISMA
              tabla RD.UIUtils que el padre (ambos archivos la comparten).
    API PÚBLICA (añadida a RD.UIUtils):
        - CleanName(name) / CapitalizeName(name)
        - StripMarkup(text) / LinkLabel(text) / LinkParts(text) / ReinjectVisible(prefix, newVisible, suffix)
        - MakeLinkAwareEditBox(box, initialRaw, opts) / LinkInfo(text)
        - ShowTooltip(owner, text, anchor, maxW) / TooltipsEnabled()
        - AddRowHover(row, getTooltip, extraFrames) / AddButtonTooltip(button, getTooltip, anchor)
    ORDEN: cargar ANTES de RD_UI_Utils.lua (ver RaidDominion.toc); el padre
           reutiliza la tabla creada aquí vía assert(RD.UIUtils, ...).
    EVENTOS: Ninguno.
]]

local addonName, private = ...
local RD = _G.RaidDominion or {}
_G.RaidDominion = RD

local UIUtils = RD.UIUtils or {}
RD.UIUtils = UIUtils

-- =============================================
-- STRINGS
-- =============================================

-- Caché de nombres limpiados: si creciera sin límite, en sesiones largas (roster
-- de banda, comms, enlaces) acumularía entradas para siempre en memoria. Se
-- acota a CLEAN_NAME_CACHE_MAX y al superarlo se vacía (se repuebla solo con los
-- nombres en uso). La caché se vacía por completo: es barato recalcular.
local CLEAN_NAME_CACHE_MAX = 512
local cleanNameCache = {}
local cleanNameCount = 0

-- Limpia un nombre (elimina reino "-xxx" y espacios, minúsculas)
function UIUtils.CleanName(name)
    if not name then return "" end
    if cleanNameCache[name] then return cleanNameCache[name] end
    local clean = string.gsub(name, "%-.*", "")
    clean = string.gsub(clean, "%s+", "")
    local result = string.lower(clean)
    cleanNameCache[name] = result
    cleanNameCount = cleanNameCount + 1
    if cleanNameCount > CLEAN_NAME_CACHE_MAX then
        cleanNameCache = {}
        cleanNameCount = 0
    end
    return result
end

-- Capitaliza un nombre
function UIUtils.CapitalizeName(name)
    if not name or name == "" then return "" end
    local clean = string.gsub(name, "%-.*", "")
    return string.upper(string.sub(clean, 1, 1)) .. string.lower(string.sub(clean, 2))
end

-- Retira el marcado de enlaces/códigos de color de un texto de chat
-- (|H...|h[Visible]|h, |K...|k[Visible]|k, |cRRGGBB, |r) y devuelve SOLO el
-- texto visible. Se usa para ETIQUETAR o ANALIZAR nombres que pueden ser enlaces
-- dinámicos (p.ej. un nombre de banda pegado como enlace a un logro) sin romper
-- el marcado del enlace en el mensaje final. Puro Lua, sin APIs de WoW.
-- Caché de markup limpio (StripMarkup) y del envoltorio de enlace (LinkLabel):
-- acotadas e independientes (mismo patrón que cleanNameCache).
local MARKUP_CACHE_MAX = 128
local markupCache = {}
local markupCount = 0
local linkLabelCache = {}
local linkLabelCount = 0

function UIUtils.StripMarkup(text)
    if type(text) ~= "string" then return tostring(text or "") end
    -- Caché acotada: estos textos se repiten mucho (nombres de enlaces en hovers,
    -- tooltips, análisis de spam). Se cachea solo texto razonablemente corto
    -- para acotar memoria.
    if #text <= 200 and markupCache[text] then return markupCache[text] end
    local out = text:gsub("%|H[^|]*%|h(.-)%|h", "%1")  -- enlace clásico: conserva el texto visible
    out = out:gsub("%|K[^|]*%|k(.-)%|k", "%1")         -- vínculo de jugador: igual
    out = out:gsub("%|c%x%x%x%x%x%x%x%x", "")          -- códigos de color
    out = out:gsub("%|r", "")                          -- cierre de color
    out = out:gsub("%|k", "")                          -- cierres sueltos de vínculo
    out = out:gsub("%|h", "")                          -- cierres sueltos de enlace
    if #text <= 200 then
        markupCache[text] = out
        markupCount = markupCount + 1
        if markupCount > MARKUP_CACHE_MAX then
            markupCache = {}
            markupCount = 0
        end
    end
    return out
end

-- Retira SOLO el envoltorio de enlace (|H...|h[Visible]|h y |K...|k[Visible]|k)
-- conservando los códigos de color |cRRGGBB/|r. Es la variante para ETIQUETAR en
-- FontStrings de 3.3.5a: un FontString normal NO parsea |H/|K (se vería crudo y
-- distorsionado), pero SÍ parsea |c/|r. Así el nombre de un enlace se muestra
-- visible SIN distorsión y conservando su color (p.ej. la rareza de un ítem).
-- NO usar para análisis numérico (los dígitos de |cRRGGBB falsearían un
-- tonumber); para eso sigue existiendo StripMarkup.
function UIUtils.LinkLabel(text)
    if type(text) ~= "string" then return tostring(text or "") end
    if #text <= 200 and linkLabelCache[text] then return linkLabelCache[text] end
    local out = text:gsub("%|H[^|]*%|h(.-)%|h", "%1")  -- enlace clásico: conserva el texto visible
    out = out:gsub("%|K[^|]*%|k(.-)%|k", "%1")         -- vínculo de jugador: igual
    out = out:gsub("%|k", "")                          -- cierres sueltos (sin |c abierto: inocuo)
    out = out:gsub("%|h", "")                          -- cierres sueltos (sin |H abierto: inocuo)
    if #text <= 200 then
        linkLabelCache[text] = out
        linkLabelCount = linkLabelCount + 1
        if linkLabelCount > MARKUP_CACHE_MAX then
            linkLabelCache = {}
            linkLabelCount = 0
        end
    end
    return out
end

-- Separa un enlace WoW en sus tres componentes: envoltorio de apertura (prefix),
-- texto visible (visible) y envoltorio de cierre (suffix).  Permite re-construir
-- el enlace con un texto visible distinto sin romper el marcado.
--   |cffffff00|Hachievement:...|h[ICC25N]|h|r  → prefix, visible, suffix
--   |Hitem:123|h[Item]|h                       → prefix, visible, suffix
--   |Kplayer-name|k[Nombre]|k                   → prefix, visible, suffix
-- Retorna nil si no es un enlace reconocible.
-- Puro Lua 5.1 (sin APIs de WoW); compatible con harness.
function UIUtils.LinkParts(text)
    if type(text) ~= "string" then return nil end
    -- Enlace con color |cRRGGBB + |H...|h[vis]|h|r
    local color, prefix, visible, suffix = text:match(
        "^(|c%x%x%x%x%x%x%x%x)(|H[^|]*|h)(.*)(|h|r)$")
    if prefix then return color .. prefix, visible, suffix end
    -- Enlace sin color + |H...|h[vis]|h|r
    prefix, visible, suffix = text:match("^(|H[^|]*|h)(.*)(|h|r)$")
    if prefix then return prefix, visible, suffix end
    -- Enlace sin color + |H...|h[vis]|h  (sin |r de cierre de color)
    prefix, visible, suffix = text:match("^(|H[^|]*|h)(.*)(|h)$")
    if prefix then return prefix, visible, suffix end
    -- Vínculo de jugador |K...|k (con color opcional)
    color, prefix, visible, suffix = text:match(
        "^(|c%x%x%x%x%x%x%x%x)(|K[^|]*|k)(.*)(|k|r)$")
    if prefix then return color .. prefix, visible, suffix end
    prefix, visible, suffix = text:match("^(|K[^|]*|k)(.*)(|k)$")
    if prefix then return prefix, visible, suffix end
    return nil
end

-- Reconstruye un enlace con un texto visible nuevo, preservando los envoltorios
-- prefix y suffix obtenidos de LinkParts.  Si prefix o suffix es nil, retorna
-- solo el texto plano (útil cuando el campo no es un enlace).
function UIUtils.ReinjectVisible(prefix, newVisible, suffix)
    if not prefix or not suffix then
        return tostring(newVisible or "")
    end
    return prefix .. tostring(newVisible or "") .. suffix
end

--[[
    Configura un EditBox para la edición SEGURA del texto visible de un enlace de
    chat: al pegar un enlace completo el campo muestra SOLO su texto visible
    (p.ej. "[ICC25N]") y, al editar/salvar, se re-inyecta en los envoltorios
    originales (auto-detect + re-inyección). Encapsula el patrón usado en las
    filas de lista para reutilizarlo en TODOS los campos editables donde un
    enlace es un valor válido (List.lua, Widgets_Bands, ContentList, config).

    Comportamiento:
      1) init: si initialRaw es un enlace se muestra su texto visible; si no, el
         texto plano. Borde azul y tooltip cuando hay enlace activo.
      2) OnTextChanged: re-detecta cada tecla SIN liberar el foco (guardado en
         vivo). Si se pega un enlace completo nuevo se adopta y se muestra su
         texto visible; si se edita el visible de un enlace existente se
         re-inyecta; si es texto plano se guarda tal cual.
      3) OnEnterPressed/OnEscapePressed: si opts.onCommit existe, lo invoca y
         libera el foco (confirmación). Si no, solo libera el foco.
      4) box.rdGetRaw() devuelve SIEMPRE el valor a guardar (enlace re-inyectado
         o texto plano), aunque el box muestre solo el texto visible. Útil para
         flujos tipo "Guardar" que leen el campo al pulsar un botón.

    opts:
      onChange(raw)    : opcional, en cada tecla (no se suelta el foco).
      onCommit(raw)    : opcional, en Enter/Esc (tras onChange, para confirmar).
      tooltip=boolean  : tooltip indicador de enlace (default true).
      border=boolean   : borde azul cuando hay enlace (default true).
    Puro Lua 5.1 + API de EditBox; seguro en harness (strtrim/GameTooltip stub).
--]]
function UIUtils.MakeLinkAwareEditBox(box, initialRaw, opts)
    if not box or not box.SetScript or not box.SetText then return end
    opts = opts or {}

    local LinkParts = UIUtils.LinkParts
    local ReinjectVisible = UIUtils.ReinjectVisible
    local linkPrefix, linkSuffix = nil, nil
    local syncingBox = false

    local function UpdateBorder(hasPrefix)
        if opts.border == false or not box.SetBackdropBorderColor then return end
        if hasPrefix then
            box:SetBackdropBorderColor(0.3, 0.5, 0.85, 0.7)
        else
            box:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
        end
    end

    local function UpdateTooltip(hasPrefix)
        if opts.tooltip == false or not box.SetScript then return end
        if hasPrefix then
            box:SetScript("OnEnter", function(self)
                if not UIUtils.TooltipsEnabled() then
                    GameTooltip:Hide()
                    return
                end
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText("Enlace: el texto visible es editable; el enlace se conserva automáticamente.", 1, 1, 1, 1, true)
                GameTooltip:Show()
            end)
            box:SetScript("OnLeave", function() GameTooltip:Hide() end)
        else
            box:SetScript("OnEnter", nil)
            box:SetScript("OnLeave", nil)
        end
    end

    -- Valor canónico a guardar sea cual sea el display del box.
    local function GetRaw()
        local cur = box.GetText and box:GetText() or ""
        if linkPrefix and linkSuffix and ReinjectVisible then
            return ReinjectVisible(linkPrefix, cur, linkSuffix)
        end
        return cur
    end

    -- Inicializa display + estado a partir de un valor (enlace o plano).
    -- Se usa tanto al crear el campo como para resetearlo programáticamente
    -- (box.rdSetRaw), p.ej. al reabrir un modal con otro elemento.
    local function ApplyInitial(raw)
        raw = tostring(raw or "")
        if box.SetText then
            syncingBox = true
            box:SetText(raw)
            syncingBox = false
        end
        if LinkParts then
            local p, v, s = LinkParts(raw)
            if p then
                linkPrefix, linkSuffix = p, s
                if box.SetText then
                    syncingBox = true
                    box:SetText(v or raw)
                    syncingBox = false
                end
                UpdateBorder(true)
                UpdateTooltip(true)
                return
            end
        end
        linkPrefix, linkSuffix = nil, nil
        UpdateBorder(false)
        UpdateTooltip(false)
    end

    -- Reconciliación en vivo (cada tecla): re-detecta y mantiene el estado del enlace.
    local function OnTextChanged(self)
        if syncingBox then return end
        local raw = strtrim(self.GetText and self:GetText() or "")
        local newP, newV, newS = nil, nil, nil
        if LinkParts then
            newP, newV, newS = LinkParts(raw)
        end
        if newP and newV and newS then
            -- Pegó un enlace completo: se adopta y se muestra su texto visible.
            linkPrefix, linkSuffix = newP, newS
            if newV ~= raw then
                syncingBox = true
                self:SetText(newV)
                syncingBox = false
            end
        elseif linkPrefix and linkSuffix then
            -- Edición del texto visible de un enlace existente (GetRaw re-inyecta).
            if raw == "" then
                linkPrefix, linkSuffix = nil, nil
            end
        else
            linkPrefix, linkSuffix = nil, nil
        end
        UpdateBorder(linkPrefix ~= nil)
        UpdateTooltip(linkPrefix ~= nil)
        if opts.onChange then opts.onChange(GetRaw()) end
    end

    local function OnCommit(self)
        if opts.onCommit then opts.onCommit(GetRaw()) end
        if self and self.ClearFocus and opts.clearFocusOnCommit ~= false then
            self:ClearFocus()
        end
    end

    box:SetScript("OnTextChanged", OnTextChanged)
    box:SetScript("OnEnterPressed", OnCommit)
    box:SetScript("OnEscapePressed", OnCommit)
    box.rdGetRaw = GetRaw
    box.rdSetRaw = ApplyInitial
    ApplyInitial(initialRaw)
end

-- Detecta si el texto es un enlace y devuelve el TEXTO del icono del elemento:
--   - Enlace a un ÍTEM (|Hitem:<id>:...) → GetItemIcon (cache de ítems).
--   - Enlace a un HECHIZO (|Hspell:<id>|h) → tercer retorno de GetSpellInfo.
--   - nil si no hay enlace o el icono no se puede resolver (no cacheado / id
--     inválido): quien llama usa su icono por defecto. Solo se fija el icono
--     cuando se detecta de verdad.
-- NO cambia el nombre: el texto del enlace se conserva tal cual (mantiene su
-- formato/color al anunciarlo). Puro Lua + APIs de cache de WoW; sin frames.
function UIUtils.LinkInfo(text)
    if type(text) ~= "string" then return nil end
    local itemID = text:match("|Hitem:(%d+):")
    if itemID then
        if GetItemIcon then
            local ok, result = pcall(GetItemIcon, tonumber(itemID))
            if ok and type(result) == "string" and result ~= "" then return result end
        end
        return nil
    end
    local spellID = text:match("|Hspell:(%d+)")
    if spellID then
        if GetSpellInfo then
            local ok, _, _, result = pcall(GetSpellInfo, tonumber(spellID))
            if ok and type(result) == "string" and result ~= "" then return result end
        end
        return nil
    end
    return nil
end

-- =============================================
-- TOOLTIPS (ancho acotado y gate ui.showTooltips)
-- =============================================

-- Medidor de texto reutilizable: envuelve el tooltip a un ancho máximo para que
-- no se estire a casi toda la pantalla. En 3.3.5a, wrap=true de GameTooltip
-- dimensiona la caja según la línea más larga ANTES de envolver, así que se
-- mide con una fuente real y se insertan saltos de línea a mano.
local measureFS = nil
local function MeasureTextWidth(text)
    if not measureFS then
        measureFS = CreateFrame("Frame", nil, UIParent)
        measureFS:SetSize(10, 10)
        measureFS:Hide()
        measureFS.fs = measureFS:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    end
    measureFS.fs:SetText(text)
    return measureFS.fs:GetStringWidth() or 0
end

-- Envuelve palabras a un ancho máximo (px) respetando saltos de línea previos.
local function WrapTextToWidth(text, maxW)
    maxW = maxW or 300
    local out = {}
    for line in tostring(text or ""):gmatch("[^\r\n]+") do
        if MeasureTextWidth(line) <= maxW then
            out[#out + 1] = line
        else
            local current = ""
            for w in line:gmatch("%S+") do
                local candidate = (current == "") and w or (current .. " " .. w)
                if MeasureTextWidth(candidate) <= maxW then
                    current = candidate
                else
                    if current ~= "" then out[#out + 1] = current end
                    current = w
                end
            end
            if current ~= "" then out[#out + 1] = current end
        end
    end
    return table.concat(out, "\n")
end

-- Tooltip compartido con ancho acotado (no abarca toda la pantalla). Las
-- explicaciones de 2+ líneas separan TÍTULO (ámbar, primera línea) del CUERPO
-- (blanco, resto); antes todo el bloque se pintaba en ámbar de título.
function UIUtils.ShowTooltip(owner, text, anchor, maxW)
    if not owner or not owner.SetPoint then return end
    local t = tostring(text or "")
    if t == "" then return end
    GameTooltip:SetOwner(owner, anchor or "ANCHOR_RIGHT")
    local title, rest = t:match("^([^\n]*)\n(.*)$")
    if title and rest and rest ~= "" then
        GameTooltip:SetText(title, 1, 0.82, 0, 1, true)
        for line in rest:gmatch("[^\n]+") do
            GameTooltip:AddLine(line, 1, 1, 1, true)
        end
    else
        GameTooltip:SetText(WrapTextToWidth(t, maxW), 1, 0.82, 0, 1, true)
    end
    GameTooltip:Show()
end

-- ¿Están activos los tooltips de ayuda? (config General > ui.showTooltips).
-- Todos los tooltips informativos del addon deben consultar este gate para que
-- la opción "Mostrar información de ayuda" los cubra de forma uniforme.
function UIUtils.TooltipsEnabled()
    local enabled = true
    if RD.config and RD.config.Get then
        enabled = RD.config:Get("ui.showTooltips", true)
    end
    return enabled
end

-- Muestra el tooltip de ayuda de una fila si "ui.showTooltips" está activo.
local function ShowRowTooltip(owner, getTooltip, anchor)
    if not UIUtils.TooltipsEnabled() then return end
    local text = getTooltip and getTooltip()
    if not text or text == "" then return end
    UIUtils.ShowTooltip(owner, text, anchor)
end

-- Hover sutil en filas interactivas (feedback de legibilidad). Opcionalmente
-- muestra el tooltip de ayuda de la fila (gated por ui.showTooltips). Los
-- controles del widget (checkbox, slider, botón, etc.) capturan el ratón, así
-- que `extraFrames` (p.ej. widget.rdHoverTargets) recibe los mismos handlers
-- para que el hover/tooltip cubra TODO el elemento.
function UIUtils.AddRowHover(row, getTooltip, extraFrames)
    if not row or not row.CreateTexture or row.rdRowFx then return end
    local hl = row:CreateTexture(nil, "OVERLAY")
    hl:SetAllPoints()
    hl:SetTexture("Interface\\Buttons\\UI-Listbox-Highlight2")
    hl:SetBlendMode("ADD")
    hl:SetAlpha(0.12)
    hl:Hide()
    row.rdRowFx = true
    local function Enter(self)
        hl:Show()
        ShowRowTooltip(self, getTooltip)
    end
    local function Leave()
        hl:Hide()
        GameTooltip:Hide()
    end
    row:EnableMouse(true)
    row:SetScript("OnEnter", Enter)
    row:SetScript("OnLeave", Leave)
    for _, f in ipairs(extraFrames or {}) do
        if f and f.SetScript and f ~= row then
            f:SetScript("OnEnter", Enter)
            f:SetScript("OnLeave", Leave)
        end
    end
end

-- Tooltip de ayuda para BOTONES principales (p.ej. "Añadir"/"Obtener" de los
-- editores de lista), gated por ui.showTooltips. `anchor` (opcional) es el punto
-- de GameTooltip:SetOwner; útil para elementos de borde (p.ej. una tira de
-- iconos en el borde derecho usa "ANCHOR_LEFT").
function UIUtils.AddButtonTooltip(button, getTooltip, anchor)
    if not button or not button.SetScript or button.rdBtnTip then return end
    button.rdBtnTip = true
    button:SetScript("OnEnter", function(self)
        -- Conserva el highlight hover del chip (MakeChipButton) si lo tiene,
        -- ya que este OnEnter reemplaza al del chip.
        if button.rdHl then button.rdHl:Show() end
        ShowRowTooltip(self, getTooltip, anchor)
    end)
    button:SetScript("OnLeave", function()
        if button.rdHl then button.rdHl:Hide() end
        GameTooltip:Hide()
    end)
end

-- Longitud en bytes del carácter UTF-8 que empieza en `byte` (1-4 bytes).
-- Fuente única de la escalera multibyte: la usan MessageManager.SplitAt y
-- Spammer.CharCount (antes duplicaban esta lógica).
function UIUtils.UTF8Len(byte)
    if byte >= 0xF0 then return 4
    elseif byte >= 0xE0 then return 3
    elseif byte >= 0xC0 then return 2 end
    return 1
end

-- Cuenta CARACTERES de un string sin romper multibyte (no bytes).
function UIUtils.CountChars(text)
    text = tostring(text or "")
    local count = 0
    local byte = 1
    while byte <= #text do
        local b = string.byte(text, byte)
        byte = byte + UIUtils.UTF8Len(b)
        count = count + 1
    end
    return count
end

-- =============================================
-- VOCABULARIO COMPARTIDO (tooltips y ayuda)
-- =============================================

-- Prefijos de interacción ÚNICOS para todos los tooltips (fuente única; antes
-- convivían 6 variantes: "Clic: X" / "Clic: x" / "Clic izq.:" / "Clic der."
-- / "Clic texto:" / "Clic para"). Siempre minúscula tras los dos puntos.
local CLICK_LABELS = {
    click = "Clic: ",
    left  = "Clic izq.: ",
    right = "Clic der.: ",
    shift = "Mayús+clic: ",
    alt   = "Alt+arrastrar: ",
}

-- Compone una pista de interacción: ClickHint("left", "gestionar objetivo") →
-- "Clic izq.: gestionar objetivo". `text` va en minúscula tras los dos puntos.
function UIUtils.ClickHint(kind, text)
    local prefix = CLICK_LABELS[kind or "click"] or "Clic: "
    return prefix .. tostring(text or "")
end

-- Ruta canónica a la ventana de configuración: ConfigPath("Bandas") →
-- "Configuración > Bandas". Antes había 4 redacciones distintas ("Opciones >
-- Configuración > Bandas", "Configuración > la pestaña de esta lista", etc.).
function UIUtils.ConfigPath(tabName)
    if tabName and tabName ~= "" then
        return "Configuración > " .. tabName
    end
    return "Configuración"
end

-- Pista única de seguimiento: dónde aparece lo que el usuario marca con un
-- check. Antes había 5 redacciones con 3 estilos de comillas distintas.
function UIUtils.TrackHint()
    return "Aparece en el tooltip del botón Jugador de la barra inferior."
end

-- Marcador de recorte de listas en tooltips ("… y N más"). Antes se
-- implementaba dos veces con formato distinto (se veían a la vez en el mismo
-- tooltip del minimapa).
function UIUtils.TruncHint(n)
    return "|cff808080… y " .. tostring(n) .. " más|r"
end

RD.UIUtils = UIUtils
return UIUtils