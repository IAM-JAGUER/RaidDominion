--[[
    RD_Utils_Bands.lua
    PROPÓSITO: Gestión de bandas (CRUD) y de sus jugadores (registrar, escanear,
              eliminar, sanción, rol/dual) + puntos de asistencia. Registra RD.utils.bands.
    API PÚBLICA:
        - RD.utils.bands:GetBands() / GetBand(index) / GetPlayer(index, name)
        - RD.utils.bands:CreateBand(data) / UpdateBand(index, data) / DeleteBand(index)
        - RD.utils.bands:AddPlayer(index, player) / RemovePlayer(index, name)
        - RD.utils.bands:UpdatePlayer(index, oldName, data)
        - RD.utils.bands:GetMemberships(name[, classFile]) -> bandas donde el jugador figura
        - RD.utils.bands:RenamePlayerEverywhere(oldName, newName) -> { renamed, conflicts }
        - RD.utils.bands:SetSanction(index, name, cause)
        - RD.utils.bands:AdjustAttendance(index, name, delta) -> nuevos puntos
        - RD.utils.bands:SetRole(index, name, role)
        - RD.utils.bands:ScanGroupIntoBand(index)
    EVENTOS: Dispara CONFIG_CHANGED vía RD.config:Set.
]]

local addonName, private = ...
local RD = _G.RaidDominion or {}
_G.RaidDominion = RD

local Bands = {}

local function CleanName(name)
    if RD.UIUtils and RD.UIUtils.CleanName then
        return RD.UIUtils.CleanName(name)
    end
    return string.lower(tostring(name or ""))
end

-- Guarda la lista completa. Se pasa una copia nueva del array para que
-- RD.config:Set detecte el cambio y publique CONFIG_CHANGED.
local function SaveBands(bands)
    if RD.config and RD.config.Set then
        local copy = {}
        for i, band in ipairs(bands) do
            copy[i] = band
        end
        RD.config:Set("bands", copy)
    end
end

-- Devuelve la lista de bandas (tabla de config)
function Bands:GetBands()
    local bands = {}
    if RD.config and RD.config.Get then
        bands = RD.config:Get("bands", {})
    end
    if type(bands) ~= "table" then bands = {} end
    return bands
end

function Bands:GetBand(index)
    return self:GetBands()[index]
end

-- Crea una banda; devuelve el índice creado
function Bands:CreateBand(data)
    data = data or {}
    local bands = self:GetBands()
    table.insert(bands, {
        name = data.name or "Nueva banda",
        icon = data.icon or "Interface\\Icons\\INV_Banner_02",
        schedule = data.schedule or "",
        minGS = tonumber(data.minGS) or 0,
        players = data.players or {},
    })
    SaveBands(bands)
    return #bands
end

-- Actualiza los campos de una banda existente
function Bands:UpdateBand(index, data)
    local band = self:GetBand(index)
    if not band then return false end
    if data.name then band.name = data.name end
    if data.icon then band.icon = data.icon end
    if data.schedule ~= nil then band.schedule = data.schedule end
    if data.minGS ~= nil then band.minGS = tonumber(data.minGS) or 0 end
    SaveBands(self:GetBands())
    return true
end

function Bands:DeleteBand(index)
    local bands = self:GetBands()
    if not bands[index] then return false end
    table.remove(bands, index)
    SaveBands(bands)
    return true
end

local function EnsureBandLists(band)
    if not band.players then band.players = {} end
end

-- Añade o actualiza un jugador en la banda (por nombre normalizado)
function Bands:AddPlayer(index, playerData)
    if not playerData or not playerData.name then return false end
    local band = self:GetBand(index)
    if not band then return false end
    EnsureBandLists(band)
    local clean = CleanName(playerData.name)
    if clean == "" then return false end
    for _, m in ipairs(band.players) do
        if CleanName(m.name) == clean then
            if playerData.class then m.class = playerData.class end
            if playerData.role then m.role = playerData.role end
            if playerData.dual then m.dual = playerData.dual end
            if playerData.leader ~= nil then m.leader = playerData.leader end
            if playerData.sanction ~= nil then
                m.sanction = playerData.sanction
                m.banned = m.sanction ~= ""
            elseif playerData.banned ~= nil then
                m.banned = playerData.banned and true or false
            end
            if playerData.notes ~= nil then m.notes = playerData.notes end
            SaveBands(self:GetBands())
            return true
        end
    end
    table.insert(band.players, {
        name = playerData.name,
        class = playerData.class or "",
        role = playerData.role or "",
        dual = playerData.dual or "",
        leader = playerData.leader or "",
        sanction = playerData.sanction or "",
        banned = (playerData.sanction ~= nil and playerData.sanction ~= "") or (playerData.banned and true or false),
        notes = playerData.notes or "",
        points = tonumber(playerData.points) or 0,
    })
    SaveBands(self:GetBands())
    return true
end

function Bands:RemovePlayer(index, name)
    local band = self:GetBand(index)
    if not band then return false end
    local clean = CleanName(name)
    if clean == "" then return false end
    for i, m in ipairs(band.players or {}) do
        if CleanName(m.name) == clean then
            table.remove(band.players, i)
            SaveBands(self:GetBands())
            return true
        end
    end
    return false
end

-- Banea o desbanea a un jugador
-- Establece la causal de sanción de un jugador ("" = sin sanción). Una causal
-- implica estar sancionado (m.banned = true); sin causal, queda desancionado.
function Bands:SetSanction(index, name, cause)
    local band = self:GetBand(index)
    if not band then return false end
    local clean = CleanName(name)
    if clean == "" then return false end
    for _, m in ipairs(band.players or {}) do
        if CleanName(m.name) == clean then
            cause = cause or ""
            m.sanction = cause
            m.banned = cause ~= ""
            SaveBands(self:GetBands())
            return true
        end
    end
    return false
end

-- Un jugador está sancionado si tiene una causal o (datos legacy) banned = true
function Bands:IsSanctioned(p)
    return p ~= nil and ((p.sanction and p.sanction ~= "") or p.banned)
end

-- Ajusta los puntos de asistencia de un jugador (+/-). Nunca baja de 0.
-- Devuelve el nuevo valor (o nil si el jugador no existe).
function Bands:AdjustAttendance(index, name, delta)
    local player = self:GetPlayer(index, name)
    if not player then return nil end
    local value = (tonumber(player.points) or 0) + (tonumber(delta) or 0)
    if value < 0 then value = 0 end
    player.points = value
    SaveBands(self:GetBands())
    return value
end

-- Devuelve el jugador (o nil) de una banda por nombre normalizado
function Bands:GetPlayer(index, name)
    local band = self:GetBand(index)
    if not band then return nil end
    local clean = CleanName(name)
    if clean == "" then return nil end
    for _, m in ipairs(band.players or {}) do
        if CleanName(m.name) == clean then
            return m
        end
    end
    return nil
end

-- Bandas donde figura el jugador (nombre normalizado, insensible a mayúsculas y
-- reino). Devuelve { { index = i, name = band.name, player = m, band = band }, ... }
-- SOLO de las bandas cuyo jugador está realmente en ellas; con nombre vacío, {}.
-- `classFile` (opcional) es la clase en vivo del personaje que se está editando:
-- si el miembro de la banda tiene clase y NO coincide, es OTRO personaje con el
-- mismo nombre (colisión de nombres) y NO se cuenta como pertenencia real. Si el
-- miembro no tiene clase o no se pasa classFile, se acepta por nombre (no se
-- puede descartar).
function Bands:GetMemberships(name, classFile)
    local out = {}
    local clean = CleanName(name)
    if clean == "" then return out end
    local wantClass = (type(classFile) == "string") and string.lower(classFile) or ""
    for i, band in ipairs(self:GetBands() or {}) do
        if type(band.players) == "table" then
            for _, m in ipairs(band.players) do
                if m and m.name and CleanName(m.name) == clean then
                    local mClass = string.lower(tostring(m.class or ""))
                    if wantClass == "" or mClass == "" or mClass == wantClass then
                        out[#out + 1] = {
                            index = i,
                            name = band.name or ("Banda " .. i),
                            player = m,
                            band = band,
                        }
                    end
                    break
                end
            end
        end
    end
    return out
end

-- Asigna el rol de un jugador (claves: tank / healer / rango / melee)
function Bands:SetRole(index, name, role)
    local band = self:GetBand(index)
    if not band then return false end
    local clean = CleanName(name)
    if clean == "" then return false end
    for _, m in ipairs(band.players or {}) do
        if CleanName(m.name) == clean then
            m.role = role or ""
            SaveBands(self:GetBands())
            return true
        end
    end
    return false
end

function Bands:SetDual(index, name, dual)
    local band = self:GetBand(index)
    if not band then return false end
    local clean = CleanName(name)
    if clean == "" then return false end
    for _, m in ipairs(band.players or {}) do
        if CleanName(m.name) == clean then
            m.dual = dual or ""
            SaveBands(self:GetBands())
            return true
        end
    end
    return false
end

-- Establece el estado de líder de raid del jugador ("" / "si" / "ayudante")
function Bands:SetLeader(index, name, leader)
    local band = self:GetBand(index)
    if not band then return false end
    local clean = CleanName(name)
    if clean == "" then return false end
    for _, m in ipairs(band.players or {}) do
        if CleanName(m.name) == clean then
            m.leader = leader or ""
            SaveBands(self:GetBands())
            return true
        end
    end
    return false
end

-- Actualiza los datos de un jugador existente. Si se cambia el nombre, renombra
-- (sin duplicar); devuelve false si el nuevo nombre ya pertenece a otro jugador.
function Bands:UpdatePlayer(index, oldName, data)
    if not data then return false end
    local band = self:GetBand(index)
    if not band then return false end
    EnsureBandLists(band)
    local oldClean = CleanName(oldName)
    if oldClean == "" then return false end
    for _, m in ipairs(band.players) do
        if CleanName(m.name) == oldClean then
            local newName = (data.name ~= nil and data.name ~= "") and data.name or m.name
            if CleanName(newName) ~= oldClean then
                for _, other in ipairs(band.players) do
                    if other ~= m and CleanName(other.name) == CleanName(newName) then
                        return false
                    end
                end
                m.name = newName
            end
            if data.class ~= nil then m.class = data.class end
            if data.role ~= nil then m.role = data.role end
            if data.dual ~= nil then m.dual = data.dual end
            if data.sanction ~= nil then
                m.sanction = data.sanction
                m.banned = m.sanction ~= ""
            end
            if data.banned ~= nil then m.banned = data.banned and true or false end
            if data.leader ~= nil then m.leader = data.leader end
            if data.notes ~= nil and data.notes ~= "" then m.notes = data.notes end
            -- Nota: las notas nunca viajan por "Obtener" (privacidad, AGENTS.md
            -- §14.3), así que un `data.notes` vacío conserva la nota local.
            if data.points ~= nil then m.points = tonumber(data.points) or 0 end
            SaveBands(self:GetBands())
            return true
        end
    end
    return false
end

-- Renombra a un jugador en TODAS las bandas donde figura (UpdatePlayer solo actúa
-- en una banda). Devuelve { renamed = n, conflicts = { {index=, name=}, ... } }.
-- Si en alguna banda el nombre nuevo ya pertenece a otro jugador, esa banda se
-- deja intacta y se registra en `conflicts` (nunca se pisan datos). No escribe
-- nada si el nombre no cambia de verdad (CleanName) o es vacío; guarda una sola
-- vez al final.
function Bands:RenamePlayerEverywhere(oldName, newName)
    local res = { renamed = 0, conflicts = {} }
    local oldClean = CleanName(oldName)
    local newClean = CleanName(newName)
    if oldClean == "" or newClean == "" or oldClean == newClean then return res end
    local bands = self:GetBands() or {}
    local changed = false
    for i, band in ipairs(bands) do
        if type(band.players) == "table" then
            for _, m in ipairs(band.players) do
                if m and m.name and CleanName(m.name) == oldClean then
                    local taken = false
                    for _, other in ipairs(band.players) do
                        if other ~= m and other.name and CleanName(other.name) == newClean then
                            taken = true
                            break
                        end
                    end
                    if taken then
                        res.conflicts[#res.conflicts + 1] = { index = i, name = band.name or ("Banda " .. i) }
                    else
                        m.name = newName
                        res.renamed = res.renamed + 1
                        changed = true
                    end
                    break
                end
            end
        end
    end
    if changed then SaveBands(bands) end
    return res
end

-- Escanea los miembros del grupo/banda actual y los añade a la banda
function Bands:ScanGroupIntoBand(index)
    local band = self:GetBand(index)
    if not band then return 0 end
    local raidCount = GetNumRaidMembers()
    local partyCount = GetNumPartyMembers()
    local total = raidCount > 0 and raidCount or partyCount
    local added = 0
    for i = 1, total do
        local unit = (raidCount > 0) and ("raid" .. i) or ("party" .. i)
        if UnitExists(unit) then
            local name = UnitName(unit)
            local _, class = UnitClass(unit)
            if self:AddPlayer(index, { name = name, class = class or "" }) then
                added = added + 1
            end
        end
    end
    return added
end

-- Devuelve la configuración de spam de la banda (copia de SPAMMER_DEFAULTS si la
-- banda no tiene spammer aún — aplica lazy sin escribir en la DB). nil si la
-- banda no existe.
function Bands:GetSpammer(index)
    local band = self:GetBand(index)
    if not band then return nil end
    local defaults = (RD.constants and RD.constants.SPAMMER_DEFAULTS) or {}
    local src = band.spammer
    if type(src) ~= "table" then src = defaults end
    -- Merge shallow: usa el valor guardado o el default para cada campo
    local out = {}
    for k, v in pairs(defaults) do
        if type(v) == "table" then
            local copy = {}
            local saved = src[k]
            if type(saved) == "table" then
                for kk, vv in pairs(saved) do copy[kk] = vv end
            else
                for kk, vv in pairs(v) do copy[kk] = vv end
            end
            out[k] = copy
        elseif src[k] ~= nil then
            out[k] = src[k]
        else
            out[k] = v
        end
    end
    -- Normalización defensiva de campos numéricos (valores basura de DB legacy)
    for _, k in ipairs({ "duration", "tank", "healer", "melee", "ranged" }) do
        local n = tonumber(out[k])
        out[k] = n or 0
    end
    if out.duration < 1 then out.duration = 60 end
    -- Separador válido SOLO si es una de las opciones actuales (un símbolo o "").
    -- Valores legacy ("//", ", ") se normalizan a "sin separador" para que el
    -- dropdown y la composición nunca divergan.
    if out.separator ~= nil then
        local allowed = {}
        for _, o in ipairs((RD.constants and RD.constants.SPAMMER_SEPARATORS) or {}) do
            allowed[o.key] = true
        end
        if not allowed[out.separator] then out.separator = "" end
    end
    return out
end

-- Merge parcial de la config de spam de la banda: escribe los campos no-nil de
-- `partial` sobre band.spammer (creando la clave si falta), guarda y dispara
-- CONFIG_CHANGED("bands"). Devuelve true si la banda existe.
function Bands:UpdateSpammer(index, partial)
    local band = self:GetBand(index)
    if not band then return false end
    if type(band.spammer) ~= "table" then
        local defaults = (RD.constants and RD.constants.SPAMMER_DEFAULTS) or {}
        band.spammer = {}
        for k, v in pairs(defaults) do
            if type(v) == "table" then
                band.spammer[k] = {}
                for kk, vv in pairs(v) do band.spammer[k][kk] = vv end
            else
                band.spammer[k] = v
            end
        end
    end
    if type(partial) == "table" then
        for k, v in pairs(partial) do
            if v ~= nil then
                if type(v) == "table" and type(band.spammer[k]) == "table" then
                    -- Merge de tablas (p.ej. channels): preserva claves no tocadas
                    for kk, vv in pairs(v) do band.spammer[k][kk] = vv end
                else
                    band.spammer[k] = v
                end
            end
        end
    end
    SaveBands(self:GetBands())
    return true
end

RD.utils = RD.utils or {}
RD.utils.bands = Bands
return Bands
