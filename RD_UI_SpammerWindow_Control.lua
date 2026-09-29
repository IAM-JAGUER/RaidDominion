--[[
    RD_UI_SpammerWindow_Control.lua
    PROPÓSITO: Control del modal del spammer (RD_UI_SpammerWindow): apertura/cierre,
              toggle, estado del bucle, y precarga/sincronización de composición
              por banda (nombre compacto ICC25H/SR10H → campo Nombre, cupo 10/25,
              dificultad N/H). Separado para mantener RD_UI_SpammerWindow.lua ≤ ~700.
              Se adjuntan como métodos a la tabla RD.ui.spammerWindow (definida en
              el archivo principal, que carga primero en el .toc).
    API PÚBLICA:
        - RD.ui.spammerWindow:Open(bandIndex) / OpenEmpty() / SelectBand(idx) / Close() / Toggle()
        - RD.ui.spammerWindow:SetRunning(bool) / ToggleSpam() / RefreshBandDropdown()
        - RD.ui.spammerWindow:AutoComposition(bandIndex)
        - RD.ui.spammerWindow:SetChannelTab("loop"|"output")
    EVENTOS: Ninguno directo (escribe vía RD.config:Set -> CONFIG_CHANGED).
]]

local addonName, private = ...
local RD = _G.RaidDominion or {}
_G.RaidDominion = RD

local SpammerWindow = RD.ui and RD.ui.spammerWindow
if not SpammerWindow then
    SpammerWindow = {}
    RD.ui = RD.ui or {}
    RD.ui.spammerWindow = SpammerWindow
end

local Log = (RD.UIUtils and RD.UIUtils.Log) or function(msg) print(msg) end

-- Para el selector de banda (dropdown del título): el label mostrado no debe
-- llevar el envoltorio |H/|K de un enlace (un FontString normal lo mostraría
-- crudo y distorsionado), pero sí conserva el color |c/|r (que sí parsea).
local LinkLabel = (RD.UIUtils and RD.UIUtils.LinkLabel)
    or function(t) return tostring(t or "") end

-- Sincroniza nombre / composición desde el nombre de la banda al abrir (o al
-- renombrar). Propaga cambios de band.name → campo Nombre (ICC25H → "ICC 25H"),
-- detecta cupo (10/25) y dificultad, y rellena roles si aún no hay personalización
-- o si el tamaño cambió respecto a la última sync.
function SpammerWindow:AutoComposition(bandIndex)
    -- Supresión: durante un "Vaciar" explícito (ClearAll) no se re-sembra nada
    -- (AutoComposition se dispara vía CONFIG_CHANGED al guardar, y volvería a
    -- rellenar los campos que se acaban de vaciar).
    if self._suppressAutoComp then return false end
    local spammer = RD.modules and RD.modules.spammer
    if not spammer or not spammer.DetectRaidInfo then return false end
    local info = spammer:DetectRaidInfo(bandIndex)
    if not info then return false end
    local bands = RD.utils and RD.utils.bands
    if not bands then return false end
    local s = bands:GetSpammer(bandIndex)
    if not s then return false end

    local bandName = tostring(info.bandName or "")
    local lastSynced = tostring(s.syncedBandName or "")
    local bandChanged = (bandName ~= "" and bandName ~= lastSynced)
    local currentName = tostring(s.name or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local partial = {}

    -- Nombre: se sincroniza con la banda abierta (ICC25H → "ICC 25H"). Se aplica
    -- si el campo está vacío, si la banda cambió, o si el valor guardado es un
    -- nombre legacy de plantilla (contiene corchetes internos, p.ej. "Armo [Icc
    -- 25H]"): el nombre del spam debe ser solo el nombre de la banda, sin
    -- prefijos extra ni corchetes anidados.
    local staleName = currentName:find("%[") ~= nil or currentName:find("%]") ~= nil
    if info.suggestedName and info.suggestedName ~= "" then
        -- IMPORTANTE (anti-bucle): si el nombre actual YA es el sugerido NO se
        -- re-sembra, aunque contenga corchetes internos (un nombre-enlace
        -- |H...|h[Logro]|h se conserva y staleName lo ve "stale" para siempre).
        -- Reescribir el mismo valor para siempre re-publicaba CONFIG_CHANGED
        -- ("bands") en cadena (RD.config:Set compara por referencia y SaveBands
        -- copia la tabla), provocando un bucle reentrante que re-renderizaba el
        -- submenú Bandas en bucle hasta el error de pila → menú desdibujado.
        if currentName ~= info.suggestedName then
            if currentName == "" or bandChanged or staleName then
                partial.name = info.suggestedName
            end
        end
    end
    if bandName ~= "" and (bandChanged or lastSynced == "") then
        partial.syncedBandName = bandName
    end

    -- Composición según cupo detectado (jugadores 10/25)
    if info.size then
        local lastSize = tonumber(s.syncedSize) or 0
        local sizeChanged = (lastSize > 0 and lastSize ~= info.size)
        local customized = (tonumber(s.tank) or 0) > 0 or (tonumber(s.healer) or 0) > 0
            or (tonumber(s.melee) or 0) > 0 or (tonumber(s.ranged) or 0) > 0
        if (not customized) or (bandChanged and sizeChanged) then
            local size = info.size
            local tankN, healN, meleeN, rangedN
            if size == 25 then
                tankN, healN, meleeN, rangedN = 2, 5, 9, 9
            else
                tankN, healN, meleeN, rangedN = 2, 2, 3, 3
            end
            partial.tank = tankN
            partial.tankClass = "pala dk war druid"
            partial.healer = healN
            partial.healerClass = "shmn druid pala pri"
            partial.melee = meleeN
            partial.meleeClass = "pala war dk rog shmn frl"
            partial.ranged = rangedN
            partial.rangedClass = "hunt pollo dmon mgo shdw"
        end
        if lastSize ~= info.size then
            partial.syncedSize = info.size
        end
    end

    -- Limpia placeholders legacy que se llegaron a guardar en el campo Mensaje:
    --   - mensaje vacío por defecto de versiones previas
    --   - fragmento de la plantilla "Raid ICC" con {players} redundante
    local msg = tostring(s.message or "")
    if msg == "Need {tank}T {healer}H {melee}M {ranged}R, GS {gs}+, {players}" then
        partial.message = ""
    elseif msg == "De 0,ConDC,CupoFrag,GS {gs}+,{players}" then
        -- Retira el ",{players}": el cupo (X/Y) ya se añade solo al final del
        -- mensaje cuando el nombre tiene número (cola de BuildMessageFrom).
        -- El "Wisp Func+GS" queda a cargo del mensaje inicial (no hardcodeado).
        partial.message = (RD.constants and RD.constants.SPAMMER_INITIAL_MESSAGE) or "De 0,ConDC,CupoFrag,GS {gs}+"
    end

    if next(partial) then
        bands:UpdateSpammer(bandIndex, partial)
        return true
    end
    return false
end

function SpammerWindow:Open(bandIndex)
    if not self.frame then
        local ok, err = pcall(function() self:Create() end)
        if not ok then
            -- Si Create falló a mitad (frame parcial), limpiar y reintentar en
            -- el próximo clic en lugar de quedarse con una ventana rota.
            self.frame = nil
            Log("|cffff0000[RaidDominion]|r Error al abrir el spammer: " .. tostring(err))
            return
        end
    end
    if not self.frame then return end
    self.bandIndex = bandIndex
    -- El spammer SIEMPRE requiere una banda válida: sin banda (nil) o con un
    -- índice inexistente no se abre (no existe el modo "Sin banda").
    local bands = RD.utils and RD.utils.bands
    if not bands or not bands.GetBand or not bands:GetBand(self.bandIndex) then return end

    -- El bucle en curso NO se detiene al abrir la ventana (ni al reabrirla ni al
    -- abrirla para otra banda): solo se detiene con su botón Detener.
    local spammer = RD.modules and RD.modules.spammer

    -- Propagar renombre / detectar cupo y dificultad antes de pintar campos
    self:AutoComposition(bandIndex)

    -- Selector de banda (título de la ventana): refleja la banda abierta
    if self.RefreshBandDropdown then self:RefreshBandDropdown() end

    self:RefreshFields()
    self.running = false
    self:SetRunning(spammer and spammer.IsActive and spammer.IsActive())
    if RD.UIUtils and RD.UIUtils.ActivateWindow then
        RD.UIUtils.ActivateWindow(self.frame)
    else
        self.frame:Show()
        self.frame:Raise()
    end
    self.isShown = true
    -- Activa el OnUpdate del countdown mientras la ventana está visible
    if self.timeFrame then self.timeFrame:Show() end
end

-- Reconstruye el dropdown de selección de banda (título de la ventana) con las
-- bandas actuales, usando el widget estándar del addon (CreateOptionsDropdown,
-- mismo patrón que la ventana de banda): se destruye el botón anterior y se crea
-- uno nuevo; se omite el trabajo si la lista de bandas o la selección no
-- cambiaron. La ventana siempre abre con una banda válida (hideEmpty), por lo
-- que el dropdown no ofrece la opción "Sin banda".
function SpammerWindow:RefreshBandDropdown()
    if not self.frame or not self.bandLabel then return end
    local bands = RD.utils and RD.utils.bands
    if not bands then return end
    local list = bands:GetBands() or {}
    local keyParts = { tostring(self.bandIndex or 1) }
    for i, b in ipairs(list) do
        keyParts[#keyParts + 1] = tostring(i) .. "=" .. tostring(b.name or "")
    end
    local key = table.concat(keyParts, ";")
    if key == self._bandDropdownKey then return end
    self._bandDropdownKey = key

    if self.bandDropdown and self.bandDropdown.button then
        self.bandDropdown.button:Hide()
        self.bandDropdown.button:SetParent(nil)
        self.bandDropdown = nil
    end

    local options = {}
    for i, b in ipairs(list) do
        options[#options + 1] = { key = tostring(i), label = LinkLabel(b.name) or ("Banda " .. i) }
    end

    local widgets = RD.ui and RD.ui.widgets
    local gold = (RD.constants and RD.constants.COLORS and RD.constants.COLORS.GOLD) or { 1, 0.82, 0 }
    self.bandDropdown = widgets and widgets.CreateOptionsDropdown
        and widgets:CreateOptionsDropdown(self.frame, 320, {
            emptyLabel = "Sin banda",
            hideEmpty = true, -- no existe el modo "Sin banda": siempre hay una banda
            current = self.bandIndex and tostring(self.bandIndex) or "",
            textColor = gold,
            options = options,
            onSelect = function(key)
                local idx = tonumber(key)
                if idx and idx >= 1 then
                    self:SelectBand(idx)
                end
            end,
        })
    if self.bandDropdown and self.bandDropdown.button then
        self.bandDropdown.button:SetPoint("LEFT", self.bandLabel, "RIGHT", 6, 0)
        if RD.UIUtils and RD.UIUtils.StyleTitleDropdown then
            RD.UIUtils.StyleTitleDropdown(self.bandDropdown)
        end
    end
end

-- Guarda el separador de partes del mensaje elegido en el dropdown y recompone
-- la preview en vivo. El separador es UN SOLO símbolo ("" = sin separador). No
-- debe pisar campos del usuario (prefijo/sufijo/nombre): primero se commitean
-- los editboxes pendientes, y se suprime AutoComposition para que el
-- CONFIG_CHANGED disparado por UpdateSpammer no re-siembre ni borre.
function SpammerWindow:CommitSeparator(key)
    local bands = RD.utils and RD.utils.bands
    if not bands or not self.bandIndex then return end
    -- Persistir lo escrito en los campos (sin commitear aún) antes de refrescar
    if self._commitTexts then self:_commitTexts() end
    self._suppressAutoComp = true
    bands:UpdateSpammer(self.bandIndex, { separator = key or "" })
    self._suppressAutoComp = false
    if self.RebuildPreview then self:RebuildPreview() end
end

-- Cambia la banda activa del spammer desde el dropdown del título sin cerrar la
-- ventana: sincroniza composición, repinta los campos y actualiza el selector.
-- El bucle en curso NO se detiene al cambiar de banda en la lista: solo se
-- detiene con su botón Detener.
function SpammerWindow:SelectBand(idx)
    if not idx or idx < 1 then return end
    local bands = RD.utils and RD.utils.bands
    if not bands or not bands:GetBand(idx) then return end

    self.bandIndex = idx
    self:AutoComposition(idx)
    self:RefreshFields()
    if self.RebuildPreview then self:RebuildPreview() end
    if self.RefreshBandDropdown then self:RefreshBandDropdown() end
end

function SpammerWindow:Close()
    if not self.frame then return end
    -- Commit de campos pendientes antes de ocultar
    if self._commitTexts then self:_commitTexts() end
    if self.timeFrame then self.timeFrame:Hide() end
    self.frame:Hide()
    self.isShown = false
end

-- Acción del submenú Bandas del menú flotante ("Spamear banda"). Si ya hay un
-- spam de banda en curso, abre la ventana con ESA banda seleccionada y el bucle
-- sigue corriendo (solo se detiene con su botón Detener). Si no hay ningún spam
-- corriendo, abre la primera banda disponible. El spammer SIEMPRE requiere una
-- banda: sin bandas registradas no se abre (no existe el modo "Sin banda").
function SpammerWindow:OpenEmpty()
    local spammer = RD.modules and RD.modules.spammer
    local activeIdx = spammer and spammer.ActiveIndex and spammer.ActiveIndex()
    if activeIdx and activeIdx >= 1 then
        self:Open(activeIdx)
        return
    end
    -- Sin spam en curso: abre la primera banda disponible. El spammer siempre
    -- requiere una banda/índice; no existe el modo "Sin banda".
    local bands = RD.utils and RD.utils.bands
    local firstIdx = nil
    if bands and bands.GetBands then
        for i, b in ipairs(bands:GetBands() or {}) do
            firstIdx = i
            break
        end
    end
    if not firstIdx then
        Log("|cffff8000[RaidDominion]|r No hay bandas para abrir el spammer.")
        return
    end
    self:Open(firstIdx)
end

function SpammerWindow:Toggle()
    if self.isShown then self:Close() else self:Open(self.bandIndex or 1) end
end

-- Restablece la config del spammer de la banda y la reinicia según la banda de
-- origen: nombre detectado (ICC25H → "ICC 25H"), composición por cupo (con
-- druid entre los tanques) y el campo Mensaje con el texto inicial
-- (SPAMMER_INITIAL_MESSAGE). Se reconstruye band.spammer desde cero para no
-- dejar restos de la config anterior.
function SpammerWindow:ResetToBandDefaults()
    local bands = RD.utils and RD.utils.bands
    if not bands or not self.bandIndex then return false end
    local band = bands:GetBand(self.bandIndex)
    if not band then return false end
    local defaults = (RD.constants and RD.constants.SPAMMER_DEFAULTS) or {}
    local data = {}
    for k, v in pairs(defaults) do
        if type(v) == "table" then
            data[k] = {}
            for kk, vv in pairs(v) do data[k][kk] = vv end
        else
            data[k] = v
        end
    end
    -- Mensaje con el texto inicial de reclutamiento (no vacío) y sin sync previa
    data.message = (RD.constants and RD.constants.SPAMMER_INITIAL_MESSAGE) or ""
    data.syncedBandName = ""
    data.syncedSize = 0
    -- Reemplazo TOTAL: la config del spammer vuelve a defaults (composición en
    -- cero), así AutoComposition re-sembrará nombre + composición de la banda.
    band.spammer = data
    bands:UpdateSpammer(self.bandIndex, {})
    -- Re-sembrar según la banda de origen: nombre detectado + composición
    if self.AutoComposition then self:AutoComposition(self.bandIndex) end
    self:RefreshFields()
    Log("|cff33ff99[RaidDominion]|r Spammer restablecido según la banda de origen.")
    return true
end

-- Vacía por completo la config del spammer de la banda: mensaje en blanco,
-- campos editables vacíos, composición en cero, duración por defecto, canales al
-- default (solo RAID) y sin sincronización previa. Se reconstruye band.spammer
-- desde cero para que no queden restos de valores anteriores (UpdateSpammer
-- mergea tablas y no limpia claves, por eso se fuerza el reemplazo total).
function SpammerWindow:ClearAll()
    local bands = RD.utils and RD.utils.bands
    if not bands or not self.bandIndex then return false end
    local band = bands:GetBand(self.bandIndex)
    if not band then return false end
    local defaults = (RD.constants and RD.constants.SPAMMER_DEFAULTS) or {}
    local data = {}
    for k, v in pairs(defaults) do
        if type(v) == "table" then
            data[k] = {}
            for kk, vv in pairs(v) do data[k][kk] = vv end
        else
            data[k] = v
        end
    end
    -- Vaciar: mensaje en blanco y sin sincronización previa
    data.message = ""
    data.syncedBandName = ""
    data.syncedSize = 0
    -- Reemplazo TOTAL del spammer: no queda ninguna clave de la config anterior
    band.spammer = data
    -- Suprime AutoComposition para que el CONFIG_CHANGED disparado por UpdateSpammer
    -- no re-llene nombre/composición recién vaciados.
    self._suppressAutoComp = true
    bands:UpdateSpammer(self.bandIndex, {})
    self._suppressAutoComp = false
    self:RefreshFields()
    Log("|cff33ff99[RaidDominion]|r Spammer vaciado.")
    return true
end

-- Refleja el estado del bucle en el botón
function SpammerWindow:SetRunning(running)
    self.running = (running == true)
    if self.startBtn then
        if self.running then
            self.startBtn:SetText("Detener")
        else
            self.startBtn:SetText("Iniciar")
        end
    end
end

-- Muestra una sola pestaña de canales (bucle o salida puntual) a la vez.
function SpammerWindow:SetChannelTab(tab)
    self.channelTab = tab
    local isLoop = (tab == "loop")
    for _, ctrl in ipairs(self.loopControls or {}) do
        for k = 1, 3 do
            if isLoop then ctrl[k]:Show() else ctrl[k]:Hide() end
        end
    end
    for _, btn in ipairs(self.outputControls or {}) do
        if isLoop then btn:Hide() else btn:Show() end
    end
    for key, btn in pairs(self.channelTabButtons or {}) do
        if RD.UIUtils and RD.UIUtils.PaintTabButton then
            RD.UIUtils.PaintTabButton(btn, key == tab)
        end
    end
end

-- Inicia/detiene el spam del módulo
function SpammerWindow:ToggleSpam()
    local spammer = RD.modules and RD.modules.spammer
    if not spammer or not self.bandIndex then return end
    if spammer.IsActive and spammer.IsActive() then
        spammer:Stop()
        self:SetRunning(false)
        return
    end
    -- Commit de campos antes de iniciar (el bucle lee de la config)
    if self._commitTexts then self:_commitTexts() end
    local ok = spammer:Start(self.bandIndex)
    if not ok then
        Log("|cffff0000[RaidDominion]|r No se pudo iniciar el spam: revisa el mensaje (vacío o >255 caracteres) y los canales.")
    end
    self:SetRunning(spammer.IsActive and spammer.IsActive())
end

return SpammerWindow
