--[[
    RD_UI_BandsList.lua
    PROPÓSITO: Render de la lista de jugadores del gestor de una banda: tabla
              ordenable con pestañas Core / Sancionados, rol
              (T/H/R/M), gearscore editable, puntos de asistencia (+/-) y
              sanción. Vive en un archivo aparte para mantener
              RD_UI_BandsWindow.lua dentro del límite de ~700 líneas.
              Registra RD.ui.bandsList.
    API PÚBLICA:
        - RD.ui.bandsList:Render(bandsWindow)
    EVENTOS: Ninguno.
]]

local addonName, private = ...
local RD = _G.RaidDominion or {}
_G.RaidDominion = RD

local List = {}
-- Construye el texto del whisper de invitación (función PURA testeable): el
-- enlace de Discord es config libre, se sanea de caracteres de control (no debe
-- inyectar saltos de línea en el whisper) y se acota para que el mensaje nunca
-- exceda el límite de 255 del canal.
function List:InviteWhisperText(bandName, minGS, roleKey, discord)
    local roleText = ({ tank = "tanque", healer = "healer", rango = "rango", melee = "melee" })[roleKey]
    local tpl
    if roleText then
        tpl = string.format("¡Te invito a la banda %s! Te necesitamos como %s. Gearscore mínimo %d.",
            bandName or "?", roleText, tonumber(minGS) or 0)
    else
        tpl = string.format("¡Te invito a la banda %s! Gearscore mínimo %d.",
            bandName or "?", tonumber(minGS) or 0)
    end
    discord = tostring(discord or ""):gsub("[%c]", " "):gsub("^%s*(.-)%s*$", "%1")
    if #discord > 90 then discord = discord:sub(1, 90) end
    if discord ~= "" then tpl = tpl .. " || Discord: " .. discord end
    return tpl
end

local GOLD_R, GOLD_G, GOLD_B = unpack((RD.constants and RD.constants.COLORS and RD.constants.COLORS.GOLD) or { 1, 0.82, 0 })
local ROW_H = 24

-- Nombre único para frames con template (los templates crean hijos con $parent).
-- Se delega en el contador ÚNICO de RD.UIUtils para evitar colisiones entre archivos.
local UniqueName = RD.UIUtils and RD.UIUtils.UniqueName

local ROLE_KEYS = { "tank", "healer", "rango", "melee" }

-- Convierte tablas de datos en opciones para CreateOptionsDropdown (helper central)
local function DataOptions(dataTable)
    local w = RD.ui and RD.ui.widgets
    return w and w.DataOptions and w.DataOptions(dataTable) or {}
end
local ROLE_ORDER = {}
for i, k in ipairs(ROLE_KEYS) do ROLE_ORDER[k] = i end
-- Orden de líder: No (""), Sí, Ayudante
local LEADER_ORDER = { [""] = 0, si = 1, ayudante = 2 }

local function CleanName(name)
    if RD.UIUtils and RD.UIUtils.CleanName then
        return RD.UIUtils.CleanName(name)
    end
    return string.lower(tostring(name or ""))
end

local function Bands()
    return RD.utils and RD.utils.bands
end

-- Un jugador está sancionado si tiene una causal o (legacy) banned = true
local function IsSanctioned(p)
    return p ~= nil and ((p.sanction and p.sanction ~= "") or p.banned)
end

-- Pestañas/filtros de la lista: Core · Tanque · Healer · Rango · Melee · Sancionados
local TAB_KEYS = {
    { key = "core", label = "Core" },
    { key = "tank", label = "Tanque" },
    { key = "healer", label = "Healer" },
    { key = "rango", label = "Rango" },
    { key = "melee", label = "Melee" },
    { key = "sanctioned", label = "Sancionados" },
}

-- Actualiza el texto, el resaltado y el ancho de las pestañas según los conteos.
-- Autodimensiona y re-layout (running x): las 6 pestañas (Core + 4 roles +
-- Sancionados) deben caber en el panel, así que el ancho sale del texto real.
local function BuildTabs(self, counts)
    if not self.tabButtons or not self.tabContainer then return end
    local x = 0
    for _, tab in ipairs(self.tabButtons) do
        local n = counts[tab.key] or 0
        local text = string.format("%s (%d)", tab.label, n)
        tab.btn:SetText(text)
        -- Resalta el chip de la pestaña activa (fondo/borde dorados), como las
        -- pestañas "Dados"/"Historial" del gestor de botín.
        if RD.UIUtils and RD.UIUtils.PaintTabButton then
            RD.UIUtils.PaintTabButton(tab.btn, self.category == tab.key)
        end
        local fs = tab.btn:GetFontString()
        if fs then
            if self.category == tab.key then
                fs:SetTextColor(GOLD_R, GOLD_G, GOLD_B)
            else
                fs:SetTextColor(0.8, 0.8, 0.8)
            end
        end
        local textW = (fs and fs.GetStringWidth and (fs:GetStringWidth() or 0)) or 0
        tab.btn:SetWidth(math.max(56, textW + 20))
        tab.btn:SetPoint("TOPLEFT", self.tabContainer, "TOPLEFT", x, 0)
        x = x + tab.btn:GetWidth() + 6
    end
end

-- Ordena los jugadores según sortKey/sortDir (ctx = datos precalculados)
local function SortPlayers(self, players, ctx)
    local key = self.sortKey
    local dir = self.sortDir
    table.sort(players, function(a, b)
        local function cmp(x, y)
            if x < y then return dir == 1 end
            if x > y then return dir == -1 end
            return nil
        end
        local av, bv, r
        if key == "name" then
            r = cmp(CleanName(a.name), CleanName(b.name))
        elseif key == "role" then
            r = cmp(ROLE_ORDER[a.role or ""] or 99, ROLE_ORDER[b.role or ""] or 99)
        elseif key == "dual" then
            r = cmp(ROLE_ORDER[a.dual or ""] or 99, ROLE_ORDER[b.dual or ""] or 99)
        elseif key == "leader" then
            r = cmp(LEADER_ORDER[a.leader or ""] or 99, LEADER_ORDER[b.leader or ""] or 99)
        elseif key == "sanction" then
            local sa = a.sanction or ""
            local sb = b.sanction or ""
            r = cmp((sa ~= "") and 0 or 1, (sb ~= "") and 0 or 1)
            if r == nil then r = cmp(sa, sb) end
        elseif key == "attendance" then
            r = cmp(ctx.att[a.name] or 0, ctx.att[b.name] or 0)
        end
        if r ~= nil then return r end
        return CleanName(a.name) < CleanName(b.name)
    end)
end

local function PaintRowBackground(row, banned)
    if row.bg then
        if banned then
            row.bg:SetTexture(0.4, 0.1, 0.1, 0.45)
        else
            row.bg:SetTexture(0.1, 0.1, 0.1, 0.3)
        end
    end
end

local function EmptyMessage(parent, text, y)
    if RD.UIUtils and RD.UIUtils.CreateEmptyMessage then
        return RD.UIUtils.CreateEmptyMessage(parent, text, y)
    end
    return nil
end

local function BuildPlayerRow(self, child, player)
    local row = CreateFrame("Frame", nil, child)
    row:SetSize(self.playersChild:GetWidth(), ROW_H)

    local bg = row:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    row.bg = bg
    PaintRowBackground(row, IsSanctioned(player))

    -- Nombre con color de clase (clic: abre el editor del jugador)
    local nameBtn = CreateFrame("Button", nil, row)
    nameBtn:SetSize(120, 20)
    nameBtn:SetPoint("LEFT", row, "LEFT", 0, 0)
    nameBtn:RegisterForClicks("LeftButtonUp")
    local nameText = nameBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nameBtn:SetFontString(nameText)
    nameText:SetText(player.name)
    nameText:SetJustifyH("LEFT")
    local classColor = (player.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[player.class:upper()])
        or (player.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[player.class])
    if classColor then
        nameText:SetTextColor(classColor.r, classColor.g, classColor.b)
    else
        nameText:SetTextColor(0.9, 0.9, 0.9)
    end
    nameBtn:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    nameBtn:SetScript("OnClick", function()
        local pe = RD.ui and RD.ui.playerEditor
        if pe and pe.OpenPlayerEditor then
            pe:OpenPlayerEditor({
                bandIndex = self.bandIndex,
                player = player,
                onSaved = function()
                    self:Refresh()
                end,
            })
        end
    end)
    nameBtn:SetScript("OnEnter", function()
        if not (RD.UIUtils and RD.UIUtils.TooltipsEnabled and RD.UIUtils.TooltipsEnabled()) then
            GameTooltip:Hide()
            return
        end
        GameTooltip:SetOwner(nameBtn, "ANCHOR_RIGHT")
        GameTooltip:SetText(player.name, 1, 1, 1)
        -- Incluye la nota si el jugador tiene una
        if player.notes and player.notes ~= "" then
            GameTooltip:AddLine("Nota: " .. tostring(player.notes), 1, 1, 1, true)
        end
        GameTooltip:AddLine("Clic: editar jugador", GOLD_R, GOLD_G, GOLD_B, true)
        GameTooltip:Show()
    end)
    nameBtn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    local widgetW = RD.ui and RD.ui.widgets
    local function MakeDD(x, options, emptyLabel, current, onSelect)
        if not widgetW or not widgetW.CreateOptionsDropdown then return nil end
        local dd = widgetW:CreateOptionsDropdown(row, 96, {
            options = options,
            emptyLabel = emptyLabel,
            current = current,
            onSelect = onSelect,
        })
        dd.button:SetPoint("LEFT", row, "LEFT", x, 0)
        return dd
    end

    -- Rol (dropdown T/H/R/M/—)
    MakeDD(128, DataOptions(RD.constants and RD.constants.BAND_ROLE_DATA), "—", player.role or "", function(key)
        player.role = key
        local b = Bands()
        if b then b:SetRole(self.bandIndex, player.name, player.role) end
    end)

    -- Dual (dropdown, segunda especialización)
    MakeDD(232, DataOptions(RD.constants and RD.constants.BAND_ROLE_DATA), "—", player.dual or "", function(key)
        player.dual = key
        local b = Bands()
        if b then b:SetDual(self.bandIndex, player.name, player.dual) end
    end)

    -- Líder de raid (dropdown No / Sí / Ayudante)
    MakeDD(336, DataOptions(RD.constants and RD.constants.BAND_LEADER_DATA), "No", player.leader or "", function(key)
        player.leader = key
        local b = Bands()
        if b and b.SetLeader then b:SetLeader(self.bandIndex, player.name, player.leader) end
    end)

    -- Puntos de asistencia (ajustables individualmente con + / -)
    local attBox = CreateFrame("Frame", nil, row)
    attBox:SetSize(92, 20)
    attBox:SetPoint("LEFT", row, "LEFT", 440, 0)
    local minus = CreateFrame("Button", nil, attBox)
    minus:SetSize(16, 16)
    minus:SetPoint("LEFT", attBox, "LEFT", 0, 0)
    local minusTex = minus:CreateTexture(nil, "ARTWORK")
    minusTex:SetAllPoints()
    minusTex:SetTexture("Interface\\Buttons\\UI-SpellbookIcon-PrevPage-Up")
    minus:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    local plus = CreateFrame("Button", nil, attBox)
    plus:SetSize(16, 16)
    plus:SetPoint("RIGHT", attBox, "RIGHT", 0, 0)
    local plusTex = plus:CreateTexture(nil, "ARTWORK")
    plusTex:SetAllPoints()
    plusTex:SetTexture("Interface\\Buttons\\UI-SpellbookIcon-NextPage-Up")
    plus:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    local attValue = attBox:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    attValue:SetJustifyH("CENTER")
    attValue:SetPoint("LEFT", minus, "RIGHT", 4, 0)
    attValue:SetPoint("RIGHT", plus, "LEFT", -4, 0)
    attValue:SetText(tostring(tonumber(player.points) or 0))
    local attBandIndex = self.bandIndex
    local function AdjustPoints(delta)
        local b = Bands()
        if b and b.AdjustAttendance then
            local v = b:AdjustAttendance(attBandIndex, player.name, delta)
            if v ~= nil then attValue:SetText(tostring(v)) end
        end
    end
    minus:SetScript("OnClick", function() AdjustPoints(-1) end)
    plus:SetScript("OnClick", function() AdjustPoints(1) end)

    -- Tooltip del campo asistencia (solo en los controles - / +; el dato no):
    -- sugiere que la asistencia mide el compromiso/fidelidad del jugador.
    local function AttEnter(self)
        if not (RD.UIUtils and RD.UIUtils.TooltipsEnabled and RD.UIUtils.TooltipsEnabled()) then
            GameTooltip:Hide()
            return
        end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Asistencia", 1, 1, 1, 1, true)
        GameTooltip:AddLine("Compromiso del jugador con la banda.", 1, 1, 1, true)
        GameTooltip:AddLine("- / +: ajustar manualmente", GOLD_R, GOLD_G, GOLD_B, true)
        GameTooltip:Show()
    end
    local function AttLeave()
        GameTooltip:Hide()
    end
    minus:SetScript("OnEnter", AttEnter)
    minus:SetScript("OnLeave", AttLeave)
    plus:SetScript("OnEnter", AttEnter)
    plus:SetScript("OnLeave", AttLeave)

    -- Columna de sanción: LISTA DESPLEGABLE siempre visible (el input de sanción)
    local sancDD = widgetW and widgetW.CreateOptionsDropdown and widgetW:CreateOptionsDropdown(row, 96, {
        options = DataOptions(RD.constants and RD.constants.BAND_SANCTION_DATA),
        emptyLabel = "—",
        current = player.sanction or "",
        onSelect = function(key)
            player.sanction = key
            local b = Bands()
            if b then b:SetSanction(self.bandIndex, player.name, player.sanction) end
            self:Refresh()
        end,
    })
    if sancDD then
        sancDD.button:SetPoint("LEFT", row, "LEFT", 540, 0)
    end

    -- Botón susurrar plantilla de invitación con datos de la banda. El mensaje
    -- es INTELIGENTE según el tab activo: si el filtro es de rol (Tanque/Healer/
    -- Rango/Melee) la invitación indica ese rol.
    local whisperBtn = CreateFrame("Button", UniqueName("Ws"), row)
    whisperBtn:SetSize(20, 20)
    local whisperTex = whisperBtn:CreateTexture(nil, "ARTWORK")
    whisperTex:SetAllPoints()
    whisperTex:SetTexture("Interface\\Icons\\INV_Letter_06")
    whisperBtn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    whisperBtn:SetScript("OnEnter", function(self)
        if not (RD.UIUtils and RD.UIUtils.TooltipsEnabled and RD.UIUtils.TooltipsEnabled()) then
            GameTooltip:Hide()
            return
        end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Susurrar invitación", 1, 0.82, 0, 1, true)
        GameTooltip:AddLine("Envía una invitación con los datos de la banda.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    whisperBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    whisperBtn:SetScript("OnClick", function()
        local b = Bands()
        local band = b and b:GetBand(self.bandIndex)
        if not band or not player.name or player.name == "" then return end
        local discord = (RD.config and RD.config.Get and RD.config:Get("chat.discordLink", "")) or ""
        local tpl = List:InviteWhisperText(band.name, band.minGS, self.category, discord)
        -- Por el embudo: trocea si es largo y espacia por destinatario.
        local mm = RD.modules and RD.modules.messageManager
        if mm and mm.SendWhisper then
            mm:SendWhisper(tpl, player.name)
            if RD.messageManager and RD.messageManager.SendSystemMessage then
                RD.messageManager:SendSystemMessage(string.format("|cff33ff99[RaidDominion]|r Invitación susurrada a %s.", player.name))
            end
            return
        end
        local ok, err = pcall(SendChatMessage, tpl, "WHISPER", nil, player.name)
        if ok then
            if RD.messageManager and RD.messageManager.SendSystemMessage then
                RD.messageManager:SendSystemMessage(string.format("|cff33ff99[RaidDominion]|r Invitación susurrada a %s.", player.name))
            end
        else
            if RD.messageManager and RD.messageManager.SendSystemMessage then
                RD.messageManager:SendSystemMessage("|cffff0000[RaidDominion]|r No se pudo susurrar a " .. player.name .. ": " .. tostring(err))
            end
        end
    end)

    -- Botón invitar al jugador a la banda/grupo
    local inviteBtn = CreateFrame("Button", UniqueName("In"), row)
    inviteBtn:SetSize(20, 20)
    inviteBtn:SetPoint("RIGHT", whisperBtn, "LEFT", -2, 0)
    local inviteTex = inviteBtn:CreateTexture(nil, "ARTWORK")
    inviteTex:SetAllPoints()
    inviteTex:SetTexture("Interface\\Icons\\INV_Misc_GroupNeedMore")
    inviteBtn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    inviteBtn:SetScript("OnEnter", function(self)
        if not (RD.UIUtils and RD.UIUtils.TooltipsEnabled and RD.UIUtils.TooltipsEnabled()) then
            GameTooltip:Hide()
            return
        end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Invitar a la banda", 1, 0.82, 0, 1, true)
        GameTooltip:AddLine("Invita al grupo/banda si está cerca.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    inviteBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    inviteBtn:SetScript("OnClick", function()
        if not player.name or player.name == "" then return end
        -- InviteUnit en 3.3.5a solo funciona si el jugador está en RANGO (misma
        -- zona o unidad conocida). Para alguien fuera de rango no hay API que lo
        -- invite; se informa honestamente y se sugiere el susurro. pcall solo
        -- captura errores: el valor de retorno de InviteUnit (true si invita,
        -- nil/false si no) es lo que decide el mensaje.
        local success, inviteOk = pcall(InviteUnit, player.name)
        local msg
        if success and inviteOk then
            msg = string.format("|cff33ff99[RaidDominion]|r Invitación enviada a %s (solo si está en rango).", player.name)
        else
            msg = string.format("|cffff0000[RaidDominion]|r No se pudo invitar a %s (fuera de rango o no está en línea).", player.name)
        end
        if RD.messageManager and RD.messageManager.SendSystemMessage then
            RD.messageManager:SendSystemMessage(msg)
        end
    end)

    -- Botón eliminar con icono (cruz de quitar/borrar)
    local delBtn = CreateFrame("Button", UniqueName("Dl"), row)
    delBtn:SetSize(20, 20)
    local delTex = delBtn:CreateTexture(nil, "ARTWORK")
    delTex:SetAllPoints()
    delTex:SetTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")
    delBtn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    delBtn:SetScript("OnEnter", function(self)
        if not (RD.UIUtils and RD.UIUtils.TooltipsEnabled and RD.UIUtils.TooltipsEnabled()) then
            GameTooltip:Hide()
            return
        end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Eliminar jugador de la banda", 1, 0.82, 0, 1, true)
        GameTooltip:Show()
    end)
    delBtn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    delBtn:SetScript("OnClick", function()
        local b = Bands()
        if not b then return end
        local function DoDelete()
            b:RemovePlayer(self.bandIndex, player.name)
            self:Refresh()
        end
        local dialogs = RD.ui and RD.ui.dialogs
        if dialogs and dialogs.ShowConfirmDialog then
            dialogs:ShowConfirmDialog({
                text = string.format("¿Eliminar a '%s' de la banda?", player.name),
                acceptText = "Eliminar",
                cancelText = "Cancelar",
                onAccept = DoDelete,
            })
        else
            DoDelete()
        end
    end)

    -- Posición del bloque de acciones a la derecha (derecha->izquierda):
    -- [invitar][susurrar][eliminar]
    delBtn:SetPoint("RIGHT", row, "RIGHT", -2, 0)
    whisperBtn:SetPoint("RIGHT", delBtn, "LEFT", -2, 0)
    inviteBtn:SetPoint("RIGHT", whisperBtn, "LEFT", -2, 0)

    return row
end

local function RebuildPlayers(self)
    local bands = Bands()
    if not bands or not self.playersScroll then return end
    local band = bands:GetBand(self.bandIndex)
    local child = self.playersChild

    for _, r in ipairs(self.rows) do
        r:Hide(); r:SetParent(nil)
    end
    self.rows = {}

    if not band then
        self.rows[1] = EmptyMessage(child, "No hay una banda seleccionada.")
        child:SetHeight(20)
        if self.pageLabel then self.pageLabel:SetText("Página 1 / 1") end
        if self.pagePrevBtn and self.pagePrevBtn.SetButtonState then self.pagePrevBtn:SetButtonState("DISABLED") end
        if self.pageNextBtn and self.pageNextBtn.SetButtonState then self.pageNextBtn:SetButtonState("DISABLED") end
        return
    end

    -- Clasificar por pestaña (Core / Roles / Sancionados) y contar. Los
    -- SANCIONADOS solo aparecen en su filtro (Sancionados): NO en Core ni en los
    -- filtros de rol. Los filtros de rol (Tanque/Healer/Rango/Melee) consideran
    -- el rol principal o el DUAL de los jugadores NO sancionados.
    local ctx = { att = {} }
    local categorized = { core = {}, sanctioned = {} }
    for _, k in ipairs(ROLE_KEYS) do categorized[k] = {} end
    for _, p in ipairs(band.players or {}) do
        ctx.att[p.name] = tonumber(p.points) or 0
        if IsSanctioned(p) then
            categorized.sanctioned[#categorized.sanctioned + 1] = p
        else
            categorized.core[#categorized.core + 1] = p
            for _, k in ipairs(ROLE_KEYS) do
                if p.role == k or p.dual == k then
                    categorized[k][#categorized[k] + 1] = p
                end
            end
        end
    end
    BuildTabs(self, {
        core = #categorized.core,
        tank = #categorized.tank,
        healer = #categorized.healer,
        rango = #categorized.rango,
        melee = #categorized.melee,
        sanctioned = #categorized.sanctioned,
    })

    local players = categorized[self.category]
    if not players then players = categorized.core end
    SortPlayers(self, players, ctx)

    -- Paginación: máximo 25 jugadores por página
    local PAGE_SIZE = 25
    local total = #players
    local totalPages = math.max(1, math.ceil(total / PAGE_SIZE))
    if self.page < 1 then self.page = 1 end
    if self.page > totalPages then self.page = totalPages end
    local first = (self.page - 1) * PAGE_SIZE + 1
    local last = math.min(total, first + PAGE_SIZE - 1)

    local y = 0
    for i = first, last do
        local player = players[i]
        local row = BuildPlayerRow(self, child, player)
        row:SetPoint("TOPLEFT", child, "TOPLEFT", 0, y)
        self.rows[#self.rows + 1] = row
        y = y - ROW_H
    end

    if total == 0 then
        self.rows[#self.rows + 1] = EmptyMessage(child, "Sin jugadores en esta pestaña.")
        y = y - 20
    end

    child:SetHeight(math.max(1, -y))
    -- Fuerza la actualización del rango del ScrollFrame y vuelve a la parte
    -- superior (evita que el desplazamiento de una página anterior corte la vista).
    if self.playersScroll then
        if self.playersScroll.UpdateScrollChildRect then
            self.playersScroll:UpdateScrollChildRect()
        end
        if self.playersScroll.SetVerticalScroll then
            self.playersScroll:SetVerticalScroll(0)
        end
    end

    -- Barra de paginación (máximo 25 por página)
    if self.pageLabel then
        self.pageLabel:SetText(string.format("Página %d / %d", self.page, totalPages))
    end
    if self.pagePrevBtn and self.pagePrevBtn.SetButtonState then
        self.pagePrevBtn:SetButtonState(self.page > 1 and "NORMAL" or "DISABLED")
    end
    if self.pageNextBtn and self.pageNextBtn.SetButtonState then
        self.pageNextBtn:SetButtonState(self.page < totalPages and "NORMAL" or "DISABLED")
    end
end

local HEADERS_PLAYERS = {
    { label = "Jugador",    key = "name",       x = 0,   w = 120 },
    { label = "Rol",        key = "role",       x = 128, w = 96 },
    { label = "Dual",       key = "dual",       x = 232, w = 96 },
    { label = "Líder",      key = "leader",     x = 336, w = 96 },
    { label = "Asistencia", key = "attendance", x = 440, w = 92 },
    { label = "Sanción",    key = "sanction",   x = 540, w = 96 },
}

local function ClearHeaderButtons(self)
    for _, b in ipairs(self.headerButtons) do
        b:Hide(); b:SetParent(nil)
    end
    self.headerButtons = {}
end

-- Construye la fila de cabeceras del panel de jugadores
local function BuildHeaders(self, container)
    ClearHeaderButtons(self)
    local headers = HEADERS_PLAYERS

    local y = 0
    for _, h in ipairs(headers) do
        local btn = CreateFrame("Button", nil, container)
        btn:SetSize(h.w, 18)
        btn:SetPoint("TOPLEFT", container, "TOPLEFT", h.x, y)
        local text = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        btn.text = text
        btn:SetFontString(text)
        text:SetJustifyH("CENTER")
        text:SetPoint("LEFT", btn, "LEFT", 0, 0)
        text:SetPoint("RIGHT", btn, "RIGHT", 0, 0)

        -- Flecha de ordenación por TEXTURA (los glifos ▲/▼ no existen en la
        -- fuente de 3.3.5a y renderizan "?"). Solo la columna activa la muestra,
        -- colocada justo después del texto centrado.
        local arrow = btn:CreateTexture(nil, "OVERLAY")
        arrow:SetSize(10, 10)
        arrow:SetTexture("Interface\\Buttons\\UI-SortArrow")
        arrow:Hide()
        btn.rdArrow = arrow

        local isActive = (h.key and h.key == self.sortKey)
        text:SetText(h.label or "")
        text:SetTextColor(GOLD_R, GOLD_G, GOLD_B)
        if isActive then
            arrow:Show()
            if self.sortDir == 1 then
                arrow:SetTexCoord(0, 1, 1, 0) -- ascendente: flecha arriba
            else
                arrow:SetTexCoord(0, 1, 0, 1) -- descendente: flecha abajo
            end
            local tw = text:GetStringWidth() or 0
            arrow:SetPoint("LEFT", btn, "LEFT", math.floor((h.w - tw) / 2) + tw + 2, 0)
        end

        btn:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        if h.key then
            btn:RegisterForClicks("LeftButtonUp")
            btn:SetScript("OnClick", function()
                if self.sortKey == h.key then
                    self.sortDir = -self.sortDir
                else
                    self.sortKey = h.key
                    self.sortDir = 1
                end
                self.page = 1
                BuildHeaders(self, container)
                self:Refresh()
            end)
        end
        self.headerButtons[#self.headerButtons + 1] = btn
    end
end

-- Render de la vista de jugadores (pestañas + cabeceras + tabla)
function List:Render(self)
    BuildHeaders(self, self.headerContainer)
    RebuildPlayers(self)
end

-- Definición de pestañas compartida con el gestor (RD_UI_BandsWindow)
List.TAB_KEYS = TAB_KEYS

RD.ui = RD.ui or {}
RD.ui.bandsList = List
return List
