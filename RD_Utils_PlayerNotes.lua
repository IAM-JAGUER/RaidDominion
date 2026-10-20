--[[
    RD_Utils_PlayerNotes.lua
    PROPÓSITO: Notas de jugador POR PERSONAJE con comportamiento GLOBAL: una nota
              por personaje (clave normalizada) compartida entre TODAS las bandas
              donde figure, y disponible aunque el personaje no esté en ninguna
              banda. Lógica PURA: sin frames, sin mensajes y sin eventos del
              juego, por lo que es testeable con mocks del harness.
              Persistencia: RaidDominionDB.playerNotes["cleanname"] = {
                  text    = "…",      -- la nota (se permite multilínea)
                  display = "Nombre", -- último nombre mostrado (tooltip fuera de bandas)
                  tracked = true,     -- seguimiento en tooltips (opt-in)
              }
              La nota es LOCAL: no viaja por "Obtener" (el codec sanea el campo) ni
              se exporta al portal. La sección "Información" del editor es la que
              escribe (texto + espejo en member.notes cuando el jugador está en
              banda, por compatibilidad con el contrato SV del portal).
    API PÚBLICA:
        - RD.utils.playerNotes:GetKey(name)              -> clave normalizada ("" sin nombre)
        - RD.utils.playerNotes:Get(name)                 -> entrada | nil
        - RD.utils.playerNotes:GetText(name)             -> texto o ""
        - RD.utils.playerNotes:SetText(name, text)       -> crea/actualiza (preserva tracked)
        - RD.utils.playerNotes:IsTracked(name)           -> booleano
        - RD.utils.playerNotes:SetTracked(name, on)      -> crea/actualiza (preserva texto)
        - RD.utils.playerNotes:Rename(oldName, newName)  -> mueve la entrada si cambió la clave
        - RD.utils.playerNotes:TrackedNotes()            -> lista { clean, display, text } (orden alfabético)
        - RD.utils.playerNotes:TrackedNoteLines()        -> líneas para los tooltips de "Jugador"/minimapa
    EVENTOS: Ninguno.
]]

local addonName, private = ...
local RD = _G.RaidDominion or {}
_G.RaidDominion = RD

RD.utils = RD.utils or {}
local PlayerNotes = {}

-- Máximo de caracteres VISIBLES (UTF-8) de una nota en una línea de tooltip:
-- el marcado de enlaces/colores no cuenta hacia el límite ni se parte nunca.
local MAX_NOTE_CHARS = 80

-- Copia profunda local (RD_Config la tiene privada; aquí se evita acoplarse a
-- su implementación y se mantiene el módulo autocontenido para los tests).
local function DeepCopy(orig)
    local t = type(orig)
    if t ~= "table" then return orig end
    local copy = {}
    for k, v in next, orig, nil do
        copy[DeepCopy(k)] = DeepCopy(v)
    end
    return setmetatable(copy, DeepCopy(getmetatable(orig)))
end

local function CleanName(s)
    if RD.UIUtils and RD.UIUtils.CleanName then
        return RD.UIUtils.CleanName(s)
    end
    local clean = string.gsub(tostring(s or ""), "%-.*", "")
    clean = string.gsub(clean, "%s+", "")
    return string.lower(clean)
end

-- Carga el contenedor global como copia de trabajo (una sola tabla raíz).
local function Load()
    local t = {}
    if RD.config and RD.config.Get then
        t = RD.config:Get("playerNotes", {}) or {}
    end
    if type(t) ~= "table" then t = {} end
    return t
end

-- Guarda el contenedor global (en bloque, patrón RD_Utils_Bands/ItemGoals).
local function Save(t)
    if RD.config and RD.config.Set then
        RD.config:Set("playerNotes", DeepCopy(t))
    end
end

-- Construye la entrada canónica (text/display + tracked opcional). Devuelve nil
-- cuando no queda nada que guardar (sin texto ni seguimiento).
local function MakeEntry(display, text, tracked)
    text = tostring(text or "")
    if text == "" and not tracked then return nil end
    local entry = { text = text, display = tostring(display or "") }
    if tracked then entry.tracked = true end
    return entry
end

-- ============================================================================
-- Lectura
-- ============================================================================

function PlayerNotes:GetKey(name)
    if name == nil then return "" end
    return CleanName(name)
end

function PlayerNotes:Get(name)
    local key = self:GetKey(name)
    if key == "" then return nil end
    local t = Load()
    local entry = t[key]
    if type(entry) ~= "table" then return nil end
    return entry
end

function PlayerNotes:GetText(name)
    local entry = self:Get(name)
    return (entry and tostring(entry.text or "")) or ""
end

function PlayerNotes:IsTracked(name)
    local entry = self:Get(name)
    return (entry and entry.tracked == true) or false
end

-- ============================================================================
-- Escritura
-- ============================================================================

-- Escribe la entrada completa de `name` (preserva el seguimiento si no se pasa).
local function WriteEntry(self, name, text, trackedOverride)
    local key = self:GetKey(name)
    if key == "" then return end
    local t = Load()
    local prev = t[key]
    local tracked = trackedOverride
    if tracked == nil then
        tracked = (type(prev) == "table" and prev.tracked == true) or false
    end
    local entry = MakeEntry(name, text, tracked)
    if entry then
        t[key] = entry
    else
        t[key] = nil
    end
    Save(t)
end

function PlayerNotes:SetText(name, text)
    WriteEntry(self, name, text, nil)
end

function PlayerNotes:SetTracked(name, on)
    local key = self:GetKey(name)
    if key == "" then return end
    local text = self:GetText(name)
    WriteEntry(self, name, text, on and true or false)
end

-- Mueve la nota de `oldName` a `newName` cuando la clave normalizada cambia.
-- Fusiona si ya existe una entrada en el destino (nunca deja huérfano el origen):
-- el texto del destino manda; si el destino no tiene texto, adopta el del origen.
function PlayerNotes:Rename(oldName, newName)
    local oldKey = self:GetKey(oldName)
    local newKey = self:GetKey(newName)
    if oldKey == "" or newKey == "" or oldKey == newKey then return end
    local t = Load()
    local entry = t[oldKey]
    if type(entry) ~= "table" then return end
    local dest = t[newKey]
    if type(dest) ~= "table" then
        dest = { text = "", display = tostring(newName or "") }
        t[newKey] = dest
    end
    if (dest.text == nil or dest.text == "") and entry.text and entry.text ~= "" then
        dest.text = entry.text
    end
    if entry.tracked == true then dest.tracked = true end
    dest.display = tostring(newName or dest.display or "")
    t[oldKey] = nil
    Save(t)
end

-- ============================================================================
-- Proyección para tooltips
-- ============================================================================

-- Convierte una nota multilínea en una sola línea (colapsa espacios) y la
-- recorta de forma segura para UTF-8 Y para el marcado de chat: las secuencias
-- de escape (`|cRRGGBB`, `|H...|h[Visible]|h`, `|K...|k[Visible]|k`, `|r`) no
-- cuentan hacia `maxChars` y NUNCA se parten. Cada enlace es una unidad
-- atómica: si no cabe entero, el corte ocurre ANTES del enlace y el '…' final
-- cierra el color abierto (`|r`). Así el tooltip recibe siempre marcado válido
-- (contar caracteres crudos partía el `|H...` con 2+ enlaces y GameTooltip
-- mostraba el payload crudo como texto llano).
local function OneLine(text, maxChars)
    text = tostring(text or "")
    text = string.gsub(text, "[\r\n]+", " ")
    text = string.gsub(text, "%s+", " ")
    text = string.gsub(text, "^%s+", "")
    text = string.gsub(text, "%s+$", "")
    if text == "" then return "" end

    local UTF8Len = (RD.UIUtils and RD.UIUtils.UTF8Len) or function(b)
        if b >= 0xF0 then return 4 elseif b >= 0xE0 then return 3
        elseif b >= 0xC0 then return 2 end
        return 1
    end

    -- Longitud VISIBLE (UTF-8) de un segmento sin escapes de apertura.
    local function VisibleLen(s)
        local n = 0
        local i = 1
        while i <= #s do
            i = i + UTF8Len(string.byte(s, i))
            n = n + 1
        end
        return n
    end

    -- Estado del marcado mientras se recorre el texto: byte donde abrió el |c
    -- aún abierto (nil = cerrado) y byte justo tras ese |c. Se declaran ANTES
    -- de CutAt para que el closure los capture como locales (no globales).
    local colorStart = nil
    local colorEnd = nil

    -- Corte seguro en `pos`: sin espacios finales, cierra el color SOLO si su
    -- código quedó dentro del corte (si no, sería un `|r` huérfano) y añade '…'.
    local function CutAt(pos)
        local cut = string.gsub(string.sub(text, 1, pos), "%s+$", "")
        if colorStart and colorStart <= pos then cut = cut .. "|r" end
        return cut .. "…"
    end

    local count = 0
    local byte = 1
    local limit = #text
    while byte <= limit do
        -- 1) Código de color |cRRGGBB: no cuenta ni se parte.
        local color = string.match(text, "^|c%x%x%x%x%x%x%x%x", byte)
        if color then
            colorStart = byte
            colorEnd = byte + #color
            byte = colorEnd
        else
            -- 2) Enlace completo (|H...|h[Visible]|h o |K...|k[Visible]|k):
            -- unidad atómica; su texto visible SÍ cuenta hacia el límite.
            local link = string.match(text, "^|H[^|]*|h.-|h", byte)
                or string.match(text, "^|K[^|]*|k.-|k", byte)
            if link then
                local visible = string.match(link, "|h(.-)|h")
                    or string.match(link, "|k(.-)|k") or ""
                local vlen = VisibleLen(visible)
                if count + vlen > maxChars then
                    -- Si un |c precede INMEDIATAMENTE al enlace, cortar ANTES
                    -- del color: evita dejar un `|c...|r` vacío colgante.
                    if colorStart and colorEnd == byte then
                        return CutAt(colorStart - 1)
                    end
                    return CutAt(byte - 1)
                end
                count = count + vlen
                byte = byte + #link
            else
                -- 3) Cierres sueltos y |r: no cuentan.
                local close = string.match(text, "^|[rkh]", byte)
                if close then
                    if close == "|r" then colorStart = nil end
                    byte = byte + #close
                else
                    -- 4) Carácter visible (UTF-8).
                    if count >= maxChars then
                        return CutAt(byte - 1)
                    end
                    byte = byte + UTF8Len(string.byte(text, byte))
                    count = count + 1
                end
            end
        end
    end
    return text
end

-- Lista de notas en seguimiento (solo con texto), orden alfabético por display.
function PlayerNotes:TrackedNotes()
    local list = {}
    local t = Load()
    for key, entry in pairs(t) do
        if type(entry) == "table" and entry.tracked == true then
            local text = OneLine(entry.text, MAX_NOTE_CHARS)
            if text ~= "" then
                local display = tostring(entry.display or "")
                if display == "" then display = key end
                list[#list + 1] = { clean = key, display = display, text = text }
            end
        end
    end
    table.sort(list, function(a, b)
        return string.lower(a.display) < string.lower(b.display)
    end)
    return list
end

-- Líneas para el tooltip ("• Nombre: nota"). Devuelve {} si no hay ninguna.
function PlayerNotes:TrackedNoteLines()
    local lines = {}
    for _, note in ipairs(self:TrackedNotes()) do
        lines[#lines + 1] = "• " .. note.display .. ": " .. note.text
    end
    return lines
end

RD.utils.playerNotes = PlayerNotes
return PlayerNotes
