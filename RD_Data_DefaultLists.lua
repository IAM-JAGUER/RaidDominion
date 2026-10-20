--[[
    RD_Data_DefaultLists.lua
    PROPÓSITO: Listas por defecto del addon (contenido "de fábrica"): roles,
              habilidades, buffs y auras. Las consumen
              RD_Config:ResetToDefaults ("Restablecer valores por defecto", tab
              General) y la siembra de RD_Utils_Migrations (primera carga con la
              lista vacía). NO viven en RD_constants.DEFAULT_LISTS/DEFAULT_
              CONFIG a propósito: esas listas alimentan el merge de RD_Config:
              Load (MergeTable recrea los índices de array ausentes, así que un
              usuario que borra o vacía entradas las vería reaparecer en cada
              login) y el botón "Reiniciar" de cada pestaña (documentado como
              "vaciar"). Este archivo es solo DATO: nunca se muta (los
              consumidores copian con DeepCopy).
    API PÚBLICA:
        - RD.data.defaultLists.roles / .abilities / .buffs / .auras
              -> { { name = <string>, icon = <string> }, ... }
        - RD.data.defaultLists.rules
              -> { { title = <string>, icon = <string>, content = <string> }, ... }
    EVENTOS: Ninguno.
]]

local addonName, private = ...
local RD = _G.RaidDominion or {}
_G.RaidDominion = RD

RD.data = RD.data or {}

RD.data.defaultLists = {
    roles = {
        { name = "MAIN TANK", icon = "Interface\\Icons\\Ability_Warrior_DefensiveStance" },
        { name = "OFF TANK", icon = "Interface\\Icons\\Ability_Warrior_OffensiveStance" },
        { name = "HEALER 1", icon = "Interface\\Icons\\Spell_Holy_HolyBolt" },
        { name = "HEALER 2", icon = "Interface\\Icons\\Spell_Holy_FlashHeal" },
        { name = "HEALER 3", icon = "Interface\\Icons\\Spell_Holy_GreaterHeal" },
        { name = "HEALER 4", icon = "Interface\\Icons\\Ability_Paladin_BeaconOfLight" },
        { name = "HEALER 5", icon = "Interface\\Icons\\Spell_Holy_GreaterHeal" },
        { name = "FRAGMENTADOR", icon = "Interface\\Icons\\Ability_Warrior_Riposte" },
        { name = "ABOMINACION", icon = "Interface\\Icons\\Spell_Shadow_AbominationExplosion" },
        { name = "SANGRES", icon = "Interface\\Icons\\Spell_Shadow_LifeDrain" },
    },
    abilities = {
        { name = "|cff71d5ff|Hspell:698|h[RITUAL DE INVOCACION]|h|r", icon = "Interface\\Icons\\Spell_Shadow_Twilight" },
        { name = "|cff71d5ff|Hspell:32182|h[HERO]|h|r", icon = "Interface\\Icons\\Ability_Shaman_Heroism" },
        { name = "|cff71d5ff|Hspell:34477|h[REDIRECCION]|h|r", icon = "Interface\\Icons\\Ability_Hunter_Misdirection" },
        { name = "|cff71d5ff|Hspell:53601|h[SACRO]|h|r", icon = "Interface\\Icons\\Ability_Paladin_BlessedMending" },
        { name = "|cff71d5ff|Hspell:10278|h[MANO PROTECCION]|h|r", icon = "Interface\\Icons\\Spell_Holy_SealOfProtection" },
        { name = "|cff71d5ff|Hspell:6940|h[MANO SACRIFICIO]|h|r", icon = "Interface\\Icons\\Spell_Holy_SealOfSacrifice" },
        { name = "|cff71d5ff|Hspell:48817|h[COLERA]|h|r", icon = "Interface\\Icons\\Spell_Holy_Excorcism" },
        { name = "|cff71d5ff|Hspell:31821|h[MAESTRIA]|h|r", icon = "Interface\\Icons\\Spell_Holy_AuraMastery" },
        { name = "|cff71d5ff|Hspell:16190|h[TOTEM MAREA MANA]|h|r", icon = "Interface\\Icons\\Spell_Frost_SummonWaterElemental" },
        { name = "|cff71d5ff|Hspell:29166|h[ESTIMULAR]|h|r", icon = "Interface\\Icons\\Spell_Nature_Lightning" },
        { name = "|cff71d5ff|Hspell:33786|h[CICLON]|h|r", icon = "Interface\\Icons\\Spell_Nature_EarthBind" },
        { name = "|cff71d5ff|Hspell:6552|h[ZURRAR]|h|r", icon = "Interface\\Icons\\INV_Gauntlets_04" },
        { name = "|cff71d5ff|Hspell:676|h[DESARMAR]|h|r", icon = "Interface\\Icons\\Ability_Warrior_Disarm" },
        { name = "|cff71d5ff|Hspell:29858|h[DESPEDAZAR ALMA]|h|r", icon = "Interface\\Icons\\Spell_Arcane_Arcane01" },
        { name = "|cff71d5ff|Hspell:10326|h[AHUYENTAR MAL]|h|r", icon = "Interface\\Icons\\Spell_Holy_TurnUndead" },
        { name = "|cff71d5ff|Hspell:53308|h[RAICES]|h|r", icon = "Interface\\Icons\\Spell_Nature_StrangleVines" },
        { name = "|cff71d5ff|Hspell:48020|h[TELETRANSPORTE]|h|r", icon = "Interface\\Icons\\Spell_Shadow_DemonicCircleTeleport" },
        { name = "|cff71d5ff|Hspell:1044|h[MANO LIBERTAD]|h|r", icon = "Interface\\Icons\\Spell_Holy_SealOfValor" },
        { name = "|cff71d5ff|Hspell:1038|h[MANO SALVACION]|h|r", icon = "Interface\\Icons\\Spell_Holy_SealOfSalvation" },
        { name = "|cff71d5ff|Hspell:498|h[PROTECCION DIVINA]|h|r", icon = "Interface\\Icons\\Spell_Holy_Restoration" },
        { name = "|cff71d5ff|Hspell:20271|h[SENTENCIA LUZ]|h|r", icon = "Interface\\Icons\\Spell_Holy_RighteousFury" },
        { name = "|cff71d5ff|Hspell:48788|h[IMPOSICION]|h|r", icon = "Interface\\Icons\\Spell_Holy_LayOnHands" },
        { name = "|cff71d5ff|Hspell:47889|h[ARMADURA DEMONIACA]|h|r", icon = "Interface\\Icons\\Spell_Shadow_RagingScream" },
        { name = "|cff71d5ff|Hspell:1842|h[DESACTIVAR TRAMPA]|h|r", icon = "Interface\\Icons\\Spell_Shadow_GrimWard" },
        { name = "|cff71d5ff|Hspell:57934|h[SECRETOS]|h|r", icon = "Interface\\Icons\\Ability_Rogue_TricksOftheTrade" },
        { name = "|cff71d5ff|Hspell:50763|h[REVIVIR]|h|r", icon = "Interface\\Icons\\Ability_Druid_LunarGuidance" },
        { name = "|cff71d5ff|Hspell:19801|h[TRANQUILIZANTE]|h|r", icon = "Interface\\Icons\\Spell_Nature_Drowsy" },
        { name = "|cff71d5ff|Hspell:58659|h[REFRIGERIO]|h|r", icon = "Interface\\Icons\\Spell_Arcane_MassDispel" },
        { name = "|cff71d5ff|Hspell:42917|h[NOVA]|h|r", icon = "Interface\\Icons\\Spell_Frost_FrostNova" },
        { name = "|cff71d5ff|Hspell:49576|h[ATRACCION]|h|r", icon = "Interface\\Icons\\Spell_DeathKnight_Strangulate" },
        { name = "|cff71d5ff|Hspell:33206|h[SUPRESION]|h|r", icon = "Interface\\Icons\\Spell_Holy_PainSupression" },
        { name = "|cff71d5ff|Hspell:6346|h[RESGUARDO]|h|r", icon = "Interface\\Icons\\Spell_Holy_Excorcism" },
        { name = "|cff71d5ff|Hspell:64901|h[HIMNO MANA]|h|r", icon = "Interface\\Icons\\Spell_Holy_SymbolOfHope" },
    },
    buffs = {
        { name = "|cff71d5ff|Hspell:25898|h[REYES]|h|r", icon = "Interface\\Icons\\Spell_Magic_GreaterBlessingofKings" },
        { name = "|cff71d5ff|Hspell:48934|h[PODERIO]|h|r", icon = "Interface\\Icons\\Spell_Holy_GreaterBlessingofKings" },
        { name = "|cff71d5ff|Hspell:48938|h[SABIDURIA]|h|r", icon = "Interface\\Icons\\Spell_Holy_GreaterBlessingofWisdom" },
        { name = "|cff71d5ff|Hspell:48470|h[DON SALVAJE]|h|r", icon = "Interface\\Icons\\Spell_Nature_GiftoftheWild" },
        { name = "|cff71d5ff|Hspell:48162|h[REZOS]|h|r", icon = "Interface\\Icons\\Spell_Holy_PrayerOfFortitude" },
        { name = "|cffffffff|Hitem:36895:0:0:0:0:0:0:0:80|h[PIEDRA DE ALMA]|h|r", icon = "Interface\\Icons\\INV_Misc_Orb_04" },
        { name = "|cff71d5ff|Hspell:49284|h[ESCUDO TIERRA]|h|r", icon = "Interface\\Icons\\Spell_Nature_SkinofEarth" },
        { name = "|cff71d5ff|Hspell:47440|h[GRITO ORDEN]|h|r", icon = "Interface\\Icons\\Ability_Warrior_RallyingCry" },
        { name = "|cff71d5ff|Hspell:47436|h[GRITO BATALLA]|h|r", icon = "Interface\\Icons\\Ability_Warrior_BattleShout" },
        { name = "|cff71d5ff|Hspell:25780|h[FURIA RECTA]|h|r", icon = "Interface\\Icons\\Spell_Holy_SealOfFury" },
        { name = "|cff71d5ff|Hspell:43002|h[INTELECTO]|h|r", icon = "Interface\\Icons\\Spell_Holy_ArcaneIntellect" },
        { name = "|cff71d5ff|Hspell:54646|h[ENFOCAR]|h|r", icon = "Interface\\Icons\\Spell_Arcane_StudentOfMagic" },
    },
    auras = {
        { name = "|cff71d5ff|Hspell:48945|h[AURA RES ESCARCHA]|h|r", icon = "Interface\\Icons\\Spell_Frost_WizardMark" },
        { name = "|cff71d5ff|Hspell:58745|h[TOTEM RES ESCARCHA]|h|r", icon = "Interface\\Icons\\Spell_FrostResistanceTotem_01" },
        { name = "|cff71d5ff|Hspell:48943|h[AURA RES SOMBRAS]|h|r", icon = "Interface\\Icons\\Spell_Shadow_SealOfKings" },
        { name = "|cff71d5ff|Hspell:58749|h[TOTEM RES NATURALEZA]|h|r", icon = "Interface\\Icons\\Spell_Nature_NatureResistanceTotem" },
        { name = "|cff71d5ff|Hspell:48947|h[AURA RES FUEGO]|h|r", icon = "Interface\\Icons\\Spell_Fire_SealOfFire" },
        { name = "|cff71d5ff|Hspell:58739|h[TOTEM RES FUEGO]|h|r", icon = "Interface\\Icons\\Spell_FireResistanceTotem_01" },
        { name = "|cff71d5ff|Hspell:8170|h[TOTEM LIMPIEZA]|h|r", icon = "Interface\\Icons\\Spell_Nature_DiseaseCleansingTotem" },
        { name = "|cff71d5ff|Hspell:58774|h[TOTEM FUENTE MANA]|h|r", icon = "Interface\\Icons\\Spell_Nature_ManaRegenTotem" },
        { name = "|cff71d5ff|Hspell:54043|h[AURA REPRENSION]|h|r", icon = "Interface\\Icons\\Spell_Holy_AuraOfLight" },
        { name = "|cff71d5ff|Hspell:32223|h[AURA CRUZADO]|h|r", icon = "Interface\\Icons\\Spell_Holy_CrusaderAura" },
        { name = "|cff71d5ff|Hspell:3738|h[TOTEM COLERA AIRE]|h|r", icon = "Interface\\Icons\\Spell_Nature_SlowingTotem" },
        { name = "|cff71d5ff|Hspell:58643|h[TOTEM FUERZA TIERRA]|h|r", icon = "Interface\\Icons\\Spell_Nature_EarthBindTotem" },
        { name = "|cff71d5ff|Hspell:8512|h[TOTEM VIENTO FURIOSO]|h|r", icon = "Interface\\Icons\\Spell_Nature_Windfury" },
        { name = "|cff71d5ff|Hspell:58757|h[TOTEM SANACION]|h|r", icon = "Interface\\Icons\\INV_Spear_04" },
        { name = "|cff71d5ff|Hspell:2484|h[TOTEM NEXO]|h|r", icon = "Interface\\Icons\\Spell_Nature_StrengthOfEarthTotem02" },
        { name = "|cff71d5ff|Hspell:8143|h[TOTEM TREMOR]|h|r", icon = "Interface\\Icons\\Spell_Nature_TremorTotem" },
        { name = "|cff71d5ff|Hspell:48947|h[RESISTENCIA FUEGO]|h|r", icon = "Interface\\Icons\\Spell_Fire_SealOfFire" },
        { name = "|cff71d5ff|Hspell:48943|h[RESISTENCIA SOBRAS]|h|r", icon = "Interface\\Icons\\Spell_Shadow_SealOfKings" },
        { name = "|cff71d5ff|Hspell:32223|h[CRUZADO]|h|r", icon = "Interface\\Icons\\Spell_Holy_CrusaderAura" },
        { name = "|cff71d5ff|Hspell:54043|h[REPRENSION]|h|r", icon = "Interface\\Icons\\Spell_Holy_AuraOfLight" },
        { name = "|cff71d5ff|Hspell:48945|h[RESISTENCIA ESCARCHA]|h|r", icon = "Interface\\Icons\\Spell_Frost_WizardMark" },
        { name = "|cff71d5ff|Hspell:13159|h[MANADA]|h|r", icon = "Interface\\Icons\\Ability_Mount_WhiteTiger" },
    },
    rules = {
        {
            title = "RaidDominion",
            icon = "Interface\\Icons\\INV_Letter_01",
            content = "Addon: macros de roles de raid y spam de mensajes personalizados. Descarga y uso del addon. Portal: https://raid-dominion.netlify.app/",
        },
    },
}

return RD.data.defaultLists
