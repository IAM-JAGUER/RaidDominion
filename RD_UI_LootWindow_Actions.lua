--[[
    RD_UI_LootWindow_Actions.lua
    PROPÓSITO: Sección de acciones y navegación del gestor de botín
              (RD_UI_LootWindow). Incluye los botones de acción ("Declarar
              ganador", "Desempatar" y "Limpiar") y la fila de navegación de la
              cola del cadáver ("Anterior" / "Siguiente"), que sirven para el
              caso "nadie ha tirado dados": se salta al siguiente pendiente o se
              vuelve al anterior (con los dados reiniciados). "Limpiar" solo
              borra los dados del ítem actual: NO descarta el ítem ni avanza.
              La navegación solo se habilita con la ronda limpia (sin dados
              registrados): si los hay, se pierden al cambiar de ítem, así que
              el flujo es "Limpiar" y después saltar. Todo el grupo se ancla
              por ABAJO (AGENTS §6): la ventana crece hacia arriba y la
              posición no depende de la altura total.
    API PÚBLICA:
        - RD.ui.lootWindow:BuildActions(mainView)   -- construye la sección
        - RD.ui.lootWindow:RefreshActions(st)        -- estado de los botones
    EVENTOS: Ninguno propio; el padre (RD_UI_LootWindow) refresca al recibir los
             eventos LOOT_*.
    DEPENDENCIA: RD_UI_LootWindow.lua (tabla Win) y RD_UI_Utils.lua (chips).
]]

local addonName, private = ...
local RD = _G.RaidDominion or {}
_G.RaidDominion = RD

local Win = RD.ui and RD.ui.lootWindow
if not Win then
    Win = {}
    RD.ui = RD.ui or {}
    RD.ui.lootWindow = Win
end

local UniqueName = RD.UIUtils and RD.UIUtils.UniqueName
local Log = (RD.UIUtils and RD.UIUtils.Log) or function(msg) print(msg) end

local PAD, G = 12, 8
local BTN_H = 24
-- Offsets (multiplos de 4, AGENTS §6) medidos desde el borde INFERIOR de la
-- ventana: la fila de navegación, la fila de acciones y el hueco de la etiqueta.
local NAV_BOTTOM = PAD                     -- 12
local ACT_BOTTOM = NAV_BOTTOM + BTN_H + G  -- 44
local LBL_TOP = ACT_BOTTOM + BTN_H + 16    -- 84 (borde SUPERIOR de la etiqueta)

-- Construye la sección de acciones y de navegación al final de la vista
-- principal del gestor de botín.
function Win:BuildActions(mainView)
    if not mainView or self._actionsBuilt then return end
    self._actionsBuilt = true

    -- Ancho útil real de la vista (el de la ventana menos los márgenes).
    local inner = (mainView:GetWidth() or 420) - PAD * 2

    local label = mainView:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetText("Acciones:")
    label:SetTextColor(0.8, 0.8, 0.8)
    -- La etiqueta se ancla por abajo, pero su offset se calcula con la altura
    -- REAL del texto: así su borde superior no se mueve hacia el área de dados
    -- si la fuente fuese más alta de lo previsto (AGENTS §6.1.4).
    local lblH = label:GetStringHeight() or 12
    label:SetPoint("BOTTOMLEFT", mainView, "BOTTOMLEFT", PAD, LBL_TOP - lblH)

    -- Tres botones por fila: 3*w + 2*G <= inner (124*3 + 8*2 = 388 <= 396).
    local actBtnW = math.floor((inner - G * 2) / 12) * 4

    -- ==================== Fila de acciones ====================
    self.winnerBtn = RD.UIUtils.MakeChipButton(mainView, UniqueName("LW"), actBtnW, BTN_H)
    self.winnerBtn:SetPoint("BOTTOMLEFT", mainView, "BOTTOMLEFT", PAD, ACT_BOTTOM)
    self.winnerBtn:SetText("Declarar ganador")
    self.winnerBtn:SetScript("OnClick", function()
        local loot = RD.modules and RD.modules.loot
        if loot and loot.AnnounceWinner then
            if loot:AnnounceWinner() then
                local st = loot.GetState and loot:GetState()
                if st and st.itemLink then
                    Log("|cff33ff99[RaidDominion]|r Ganador declarado. Siguiente ítem cargado.")
                else
                    -- Sin pendientes: el aviso ya lo da el propio gestor.
                    Log("|cff33ff99[RaidDominion]|r Ganador declarado.")
                end
            else
                Log("|cffff0000[RaidDominion]|r No hay ítem o ganador para declarar.")
            end
        end
        Win:Refresh()
    end)

    self.duelBtn = RD.UIUtils.MakeChipButton(mainView, UniqueName("LD"), actBtnW, BTN_H)
    self.duelBtn:SetPoint("BOTTOMLEFT", mainView, "BOTTOMLEFT", PAD + (actBtnW + G), ACT_BOTTOM)
    self.duelBtn:SetText("Desempatar")
    self.duelBtn:SetScript("OnClick", function()
        local loot = RD.modules and RD.modules.loot
        if loot and loot.StartDuel then
            if loot:StartDuel() then
                Log("|cff33ff99[RaidDominion]|r Desempate iniciado: solo tiran los empatados.")
            else
                Log("|cffff0000[RaidDominion]|r No hay empate que desempatar.")
            end
        end
        Win:Refresh()
    end)

    self.clearBtn = RD.UIUtils.MakeChipButton(mainView, UniqueName("LCl"), actBtnW, BTN_H)
    self.clearBtn:SetPoint("BOTTOMLEFT", mainView, "BOTTOMLEFT", PAD + 2 * (actBtnW + G), ACT_BOTTOM)
    self.clearBtn:SetText("Limpiar")
    self.clearBtn:SetScript("OnClick", function()
        local loot = RD.modules and RD.modules.loot
        if loot and loot.ClearRolls then
            loot:ClearRolls()
            Log("|cff33ff99[RaidDominion]|r Dados del ítem limpiados.")
        end
        Win:Refresh()
    end)

    -- ==================== Fila de navegación de la cola ====================
    self.prevBtn = RD.UIUtils.MakeChipButton(mainView, UniqueName("LP"), actBtnW, BTN_H)
    self.prevBtn:SetPoint("BOTTOMLEFT", mainView, "BOTTOMLEFT", PAD, NAV_BOTTOM)
    self.prevBtn:SetText("Anterior")
    self.prevBtn:SetScript("OnClick", function()
        local loot = RD.modules and RD.modules.loot
        if loot and loot.PreviousItem then
            if loot:PreviousItem() then
                Log("|cff33ff99[RaidDominion]|r Ítem anterior cargado (dados reiniciados).")
            else
                Log("|cffff0000[RaidDominion]|r No hay ningún ítem anterior.")
            end
        end
        Win:Refresh()
    end)

    self.nextBtn = RD.UIUtils.MakeChipButton(mainView, UniqueName("LN"), actBtnW, BTN_H)
    self.nextBtn:SetPoint("BOTTOMLEFT", mainView, "BOTTOMLEFT", PAD + (actBtnW + G), NAV_BOTTOM)
    self.nextBtn:SetText("Siguiente")
    self.nextBtn:SetScript("OnClick", function()
        local loot = RD.modules and RD.modules.loot
        if loot and loot.SkipItem then
            if loot:SkipItem() then
                Log("|cff33ff99[RaidDominion]|r Siguiente ítem cargado.")
            else
                Log("|cffff0000[RaidDominion]|r No hay más ítems en la cola del cadáver.")
            end
        end
        Win:Refresh()
    end)

    -- Indicador de posición en la cola (a la derecha de los botones).
    self.queueLabel = mainView:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    self.queueLabel:SetPoint("LEFT", self.nextBtn, "RIGHT", G, 0)
    self.queueLabel:SetJustifyH("LEFT")
    self.queueLabel:SetText("")
    self.queueLabel:SetTextColor(0.8, 0.8, 0.8)

    -- Ayudas de los botones (respetan el toggle de tooltips del addon).
    if RD.UIUtils and RD.UIUtils.AddButtonTooltip then
        RD.UIUtils.AddButtonTooltip(self.clearBtn, function()
            return "Limpia los dados del ítem actual.\nNo lo descarta ni avanza: para eso están Siguiente y Anterior."
        end)
        RD.UIUtils.AddButtonTooltip(self.prevBtn, function()
            return "Vuelve al ítem anterior de la cola del cadáver.\nLos dados se reinician (nadie ha tirado todavía).\nSi hay dados registrados, usa primero Limpiar: al navegar se perderían."
        end)
        RD.UIUtils.AddButtonTooltip(self.nextBtn, function()
            return "Salta al siguiente ítem pendiente del cadáver (nadie ha tirado).\nEl ítem actual no se descarta: puedes volver con Anterior.\nSi hay dados registrados, usa primero Limpiar: al navegar se perderían."
        end)
    end
end

-- Refresca el estado de los botones de acción y navegación a partir del estado
-- del gestor de botín. "Anterior"/"Siguiente" se habilitan solo cuando hay
-- destino real (navegar nunca descarta el ítem actual).
function Win:RefreshActions(st)
    if not self._actionsBuilt then return end
    local loot = RD.modules and RD.modules.loot
    local hasItem = st and st.itemLink ~= nil

    if self.winnerBtn then
        local canDeclare = hasItem and st.winner ~= nil
        if canDeclare then self.winnerBtn:Enable() else self.winnerBtn:Disable() end
    end
    if self.duelBtn then
        local hasTie = hasItem and not st.duel and loot and loot.HasTie and loot:HasTie()
        if hasTie then self.duelBtn:Enable() else self.duelBtn:Disable() end
    end
    if self.clearBtn then
        local dirty = hasItem and ((st.rolls and #st.rolls > 0)
            or st.winner ~= nil or st.countdownActive)
        if dirty then self.clearBtn:Enable() else self.clearBtn:Disable() end
    end

    local info = (loot and loot.GetQueueInfo) and loot:GetQueueInfo() or nil
    -- Navegar SOLO con la ronda limpia: si hay dados registrados, se pierden al
    -- cambiar de ítem. El flujo explícito es "Limpiar" (borra los dados) y
    -- después "Siguiente"/"Anterior".
    local clean = not (st.rolls and #st.rolls > 0)
    if self.prevBtn then
        if info and info.canPrev and clean then self.prevBtn:Enable() else self.prevBtn:Disable() end
    end
    if self.nextBtn then
        if info and info.canNext and clean then self.nextBtn:Enable() else self.nextBtn:Disable() end
    end
    if self.queueLabel then
        local text = "Sin cola"
        if info and info.total > 0 then
            if info.pos > 0 then
                text = string.format("Ítem %d/%d", info.pos, info.total)
            else
                text = "De la bolsa"
            end
        end
        self.queueLabel:SetText(text)
    end
end

return Win
