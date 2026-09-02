local mq           = require('mq')
local Casting      = require("utils.casting")
local Combat       = require('utils.combat')
local Config       = require('utils.config')
local Core         = require("utils.core")
local Globals      = require('utils.globals')
local Targeting    = require("utils.targeting")

-- Role-based heal thresholds (EQ Might CLR).
-- Keys: HealPct{FastHeal|Light|SingleHoT|GroupHeal|GroupHoT|CompleteHeal}_{Tank|Melee|Caster}
-- FastHeal = old Big Heal Point band (Divine Arb / Burst of Life / Remedy, etc.).
-- Regular (Light) = Healing Light / Renewal.
-- Group Injured Count prefers group spells when their own % count is met.
-- Melee = non-tank melee (RNG/MNK/ROG/BER/BST/BRD). Caster = pure casters + OTH/pets.
local HEAL_ROLE_LIST = { "Tank", "Melee", "Caster", }

local HEAL_TANK_SET = { WAR = true, SHD = true, PAL = true, }
local HEAL_MELEE_SET = {
    RNG = true, MNK = true, ROG = true, BER = true, BST = true, BRD = true,
}

-- Legacy per-class keys used only for one-shot migration into role keys.
local HEAL_LEGACY_CLASS_LIST = {
    "WAR", "SHD", "PAL", "RNG", "MNK", "ROG", "BER", "BST",
    "BRD", "CLR", "DRU", "SHM", "NEC", "WIZ", "MAG", "ENC", "OTH",
}
local HEAL_LEGACY_ROLE_SOURCES = {
    Tank = { "WAR", "SHD", "PAL", },
    Melee = { "MNK", "RNG", "ROG", "BER", "BST", "BRD", },
    Caster = { "WIZ", "CLR", "DRU", "SHM", "NEC", "MAG", "ENC", "OTH", },
}

local HEAL_KIND_LABEL = {
    CompleteHeal = "Complete Heal",
    FastHeal = "Fast Heal",
    Light = "Regular Heal",
    SingleHoT = "Single HoT",
    GroupHeal = "Group Regular Heal",
    GroupHoT = "Group HoT",
}

local HEAL_ROLE_TIP = {
    Tank = "WAR / SHD / PAL",
    Melee = "RNG / MNK / ROG / BER / BST / BRD (non-tank melee)",
    Caster = "CLR / DRU / SHM / NEC / WIZ / MAG / ENC / other",
}

local function defaultHealPct(kind, role)
    if kind == "CompleteHeal" then
        return 80
    elseif kind == "FastHeal" then
        if role == "Tank" then return 45 end
        return 0
    elseif kind == "Light" then
        return 65
    elseif kind == "GroupHeal" then
        return 64
    elseif kind == "SingleHoT" then
        if role == "Tank" then return 95 end
        return 0
    elseif kind == "GroupHoT" then
        return 0
    end
    return 0
end

local function healPctSettingKey(kind, role)
    return string.format("HealPct%s_%s", kind, role)
end

local function classToHealRole(shortName)
    local sn = (shortName or ""):upper()
    if HEAL_TANK_SET[sn] then return "Tank" end
    if HEAL_MELEE_SET[sn] then return "Melee" end
    return "Caster"
end

local function buildClassHealDefaults()
    local kinds = {
        { kind = "CompleteHeal", category = "Class Heal: Complete Heal", indexBase = 150, roles = { "Tank", }, },
        { kind = "Light", category = "Class Heal: Regular Heal", indexBase = 200, roles = HEAL_ROLE_LIST, },
        {
            kind = "GroupHeal",
            category = "Class Heal: Group Regular Heal",
            indexBase = 250,
            roles = HEAL_ROLE_LIST,
            extraTip = " When Group Injured Count is met, Group Regular Heal is preferred over single heals at the same %%.",
        },
        { kind = "SingleHoT", category = "Class Heal: Single HoT", indexBase = 300, roles = HEAL_ROLE_LIST, },
        {
            kind = "GroupHoT",
            category = "Class Heal: Group HoT",
            indexBase = 320,
            roles = HEAL_ROLE_LIST,
            extraTip = " When Group Injured Count is met, Group HoT is preferred over single HoTs at the same %%.",
        },
        { kind = "FastHeal", category = "Class Heal: Fast Heal", indexBase = 350, roles = HEAL_ROLE_LIST, },
    }
    local out = {}
    for _, kinfo in ipairs(kinds) do
        for i, role in ipairs(kinfo.roles) do
            local key = healPctSettingKey(kinfo.kind, role)
            local label = HEAL_KIND_LABEL[kinfo.kind] or kinfo.kind
            local roleTip = HEAL_ROLE_TIP[role] or role
            local def = {
                DisplayName = role,
                Group = "Abilities",
                Header = "Recovery",
                Category = kinfo.category,
                Index = kinfo.indexBase + i,
                Tooltip = string.format(
                    "%s HP%% for %s (%s): candidate when at or below this value. Lower %% = higher priority when multiple heals qualify.\n0 = never use this heal on %s.%s",
                    label, role, roleTip, role, kinfo.extraTip or ""),
                Default = defaultHealPct(kinfo.kind, role),
                Min = 0,
                Max = 99,
                ConfigType = "Advanced",
            }
            out[key] = def
        end
    end
    return out
end

local _ClassConfig = {
    _version              = "2.6 - EQ Might",
    _author               = "Algar, Derple, Robban",
    -- Who-to-heal scan uses max Class Heal %%; per-kind thresholds gate actual casts (Tank/Melee/Caster).
    ['ModeChecks']        = {
        IsHealing = function() return true end,
        IsCuring = function() return Config:GetSetting('DoCures') end,
        IsRezing = function()
            local rezAction = Casting.CanUseAA("Blessing of Resurrection") or mq.TLO.FindItem("=Water Sprinkler of Nem Ankh")() or Core.GetResolvedActionMapItem('RezStaff')
            return ((Core.GetResolvedActionMapItem('RezSpell') or rezAction) and not Targeting.HasXTHaters()) or (Config:GetSetting('DoBattleRez') and rezAction)
        end,
    },
    ['Rez']               = {
        ['Combat'] = {
            {
                type = "Item",
                name = "Legendary Fabled Staff of Forbidden Rites",
                load_cond = function(self, item, target)
                    return Core.GetResolvedActionMapItem('RezStaff') == "Legendary Fabled Staff of Forbidden Rites" -- prefer this one if its available
                end,
            },
            { type = "AA",   name = "Blessing of Resurrection", },
            {
                type = "Item",
                name = "RezStaff",
                load_cond = function(self, item, target)
                    local rezStaff = Core.GetResolvedActionMapItem('RezStaff')
                    return rezStaff and rezStaff ~= "Legendary Fabled Staff of Forbidden Rites" -- otherwise BoR casts faster
                end,
            },
            { type = "Item", name = "Water Sprinkler of Nem Ankh", },
        },
        ['Downtime'] = {
            {
                type = "Spell",
                name = "Larger Reviviscence",
                cond = function(self, spell, target)
                    return Casting.DowntimeRezOkay()
                        and mq.TLO.SpawnCount("pccorpse radius 80 zradius 30")() > 2
                end,
            },
            { type = "AA",   name = "Blessing of Resurrection", },
            { type = "Item", name = "RezStaff", },
            { type = "Item", name = "Water Sprinkler of Nem Ankh", },
            {
                type = "Spell",
                name = "RezSpell",
                cond = function(self, spell, target)
                    return Casting.DowntimeRezOkay()
                        and not Casting.CanUseAA('Blessing of Resurrection')
                end,
            },
        },
    },
    ['Modes']             = {
        'Heal',
    },
    ['Cure']              = {
        ['DetDispel'] = {
            { type = "AA", name = "Group Purify Soul", },
            { type = "AA", name = "Radiant Cure", },
            { type = "AA", name = "Purify Soul",       selfOnly = true, },
        },
        ['Poison'] = {
            { type = "Spell", name = "GroupHeal",  load_cond = function(self) return self.Helpers.UseGroupHealCure(self, 'KeepPoisonMemmed') end, },
            { type = "Spell", name = "CurePoison", },
        },
        ['Disease'] = {
            { type = "Spell", name = "GroupHeal",   load_cond = function(self) return self.Helpers.UseGroupHealCure(self, 'KeepDiseaseMemmed') end, },
            { type = "Spell", name = "CureDisease", },
        },
        ['Curse'] = {
            { type = "Spell", name = "GroupHeal", load_cond = function(self) return self.Helpers.UseGroupHealCure(self, 'KeepCurseMemmed') end, },
            { type = "Spell", name = "CureCurse", },
        },
        ['Corruption'] = {
            { type = "Spell", name = "CureCorrupt", },
        },
    },
    ['Themes']            = {
        ['Heal'] = {
            { element = ImGuiCol.TitleBgActive,    color = { r = 0.70, g = 0.65, b = 0.50, a = 0.8, }, },
            { element = ImGuiCol.TableHeaderBg,    color = { r = 0.70, g = 0.65, b = 0.50, a = 0.8, }, },
            { element = ImGuiCol.Tab,              color = { r = 0.30, g = 0.28, b = 0.21, a = 0.8, }, },
            { element = ImGuiCol.TabSelected,      color = { r = 0.70, g = 0.65, b = 0.50, a = 0.8, }, },
            { element = ImGuiCol.TabHovered,       color = { r = 0.70, g = 0.65, b = 0.50, a = 1.0, }, },
            { element = ImGuiCol.Header,           color = { r = 0.30, g = 0.28, b = 0.21, a = 0.8, }, },
            { element = ImGuiCol.HeaderActive,     color = { r = 0.70, g = 0.65, b = 0.50, a = 0.8, }, },
            { element = ImGuiCol.HeaderHovered,    color = { r = 0.70, g = 0.65, b = 0.50, a = 1.0, }, },
            { element = ImGuiCol.FrameBgHovered,   color = { r = 0.70, g = 0.65, b = 0.50, a = 0.7, }, },
            { element = ImGuiCol.Button,           color = { r = 0.48, g = 0.44, b = 0.34, a = 0.8, }, },
            { element = ImGuiCol.ButtonActive,     color = { r = 0.70, g = 0.65, b = 0.50, a = 0.8, }, },
            { element = ImGuiCol.ButtonHovered,    color = { r = 0.70, g = 0.65, b = 0.50, a = 1.0, }, },
            { element = ImGuiCol.TextSelectedBg,   color = { r = 0.70, g = 0.65, b = 0.50, a = 0.1, }, },
            { element = ImGuiCol.FrameBg,          color = { r = 0.30, g = 0.28, b = 0.21, a = 0.8, }, },
            { element = ImGuiCol.SliderGrab,       color = { r = 1.00, g = 0.99, b = 0.90, a = 0.8, }, },
            { element = ImGuiCol.SliderGrabActive, color = { r = 1.00, g = 0.99, b = 0.90, a = 0.9, }, },
            { element = ImGuiCol.FrameBgActive,    color = { r = 0.70, g = 0.65, b = 0.50, a = 1.0, }, },
        },
    },
    ['ItemSets']          = {
        ['RezStaff'] = {
            "Legendary Fabled Staff of Forbidden Rites",
            "Fabled Staff of Forbidden Rites",
            "Legendary Staff of Forbidden Rites",
        },
        ['Epic'] = {
            "Harmony of the Soul",
            "Aegis of Superior Divinity",
        },
        ['BlueBand'] = {
            "Legendary Ancient Frozen Blue Band",
            "Ancient Frozen Blue Band",
            "Fabled Blue Band of the Oak",
            "Blue Band of the Oak",
        },
        ['VampiricBlueBand'] = {
            "Mythical Ancient Vampiric Blue Band",
            "Legendary Ancient Vampiric Blue Band",
            "Ancient Vampiric Blue Band",
        },
        ['Timer2HealItem'] = {
            "Legendary Weighted Hammer of Conviction",
            "Legendary Aged Shissar Apothic Staff",
            "Weighted Hammer of Conviction",
            "Aged Shissar Apothic Staff",
        },
        ['OoW_Chest'] = {
            "Faithbringer's Breastplate of Conviction",
            "Sanctified Chestguard",
        },
    },
    ['AbilitySets']       = {
        -- ['WardSelfBuff'] = {
        --     "Ward of Retribution", -- Level 69
        -- },
        ['HealingLight'] = {
            "Sacred Light",            -- Level 71
            "Ancient: Hallowed Light", -- Level 70
            "Pious Light",             -- Level 67
            "Holy Light",              -- Level 65
            "Supernal Light",          -- Level 63
            "Ethereal Light",          -- Level 58
            "Divine Light",            -- Level 53
            "Healing Light",           -- Level 39
            "Superior Healing",        -- Level 30
            "Greater Healing",         -- Level 20
            "Healing",                 -- Level 10
            "Light Healing",           -- Level 4
            "Minor Healing",           -- Level 1
        },
        ['RemedyHeal'] = {             -- Not great until 96/RoF (Graceful)
            "Pious Remedy",            -- Level 66
            "Supernal Remedy",         -- Level 61
            "Ethereal Remedy",         -- Level 59
            "Remedy",                  -- Level 51
        },
        ['Renewal'] = {                -- Level 70 +, large heal, slower cast
            "Desperate Renewal",       -- Level 70
        },
        ['GroupHeal'] = {
            "Word of Vivacity",      -- Level 80
            "Word of Vivification",  -- Level 69
            "Word of Replenishment", -- Level 64
            "Word of Restoration",   -- Level 57, No good NoCure in these level ranges using w/Cure... Note Word of Redemption omitted (12sec cast)
            "Word of Vigor",         -- Level 52
            "Word of Healing",       -- Level 45
            "Word of Health",        -- Level 30
        },
        ['SelfHPBuff'] = {
            --Self Buff for Mana Regen and armor
            "Armor of the Pious",             -- Level 70
            "Armor of the Zealot",            -- Level 65
            "Ancient: High Priest's Bulwark", -- Level 60
            "Blessed Armor of the Risen",     -- Level 58
            "Armor of Protection",            -- Level 34
        },
        ['AegoBuff'] = {
            "Hand of Conviction",        -- Level 70
            "Hand of Virtue",            -- Level 65
            "Ancient: Gift of Aegolism", -- Level 60
            "Blessing of Aegolism",      -- Level 60
            "Blessing of Temperance",    -- Level 45
            "Temperance",                -- Level 40
        },
        ['ACBuff'] = {
            "Ward of Valiance",  -- Level 66
            "Ward of Gallantry", -- Level 61
            "Bulwark of Faith",  -- Level 57
            "Shield of Words",   -- Level 45
            "Armor of Faith",    -- Level 35
            "Guard",             -- Level 25
            "Spirit Armor",      -- Level 15
            "Holy Armor",        -- Level 1
        },
        ['HPTypeOne'] = {
            -- "Fortitude", -- Level 55, weaker but longer duration
            "Heroic Bond", -- Level 52 Group
            "Heroism",     -- Level 52
            "Resolution",  -- Level 42
            "Valor",       -- Level 32
            "Bravery",     -- Level 22
            "Daring",      -- Level 17
            "Center",      -- Level 7
            "Courage",     -- Level 1
        },
        ['SingleVieBuff'] = {
            "Aegis of Vie",      -- Level 71
            "Panoply of Vie",    -- Level 67
            "Bulwark of Vie",    -- Level 62
            "Protection of Vie", -- Level 54
            "Guard of Vie",      -- Level 40
            "Ward of Vie",       -- Level 20
        },
        ['GroupSymbolBuff'] = {
            ----Group Symbols
            "Balikor's Mark",    -- Level 70
            "Kazad's Mark",      -- Level 63
            "Marzin's Mark",     -- Level 60
            "Naltron's Mark",    -- Level 58
            "Symbol of Marzin",  -- Level 54
            "Symbol of Naltron", -- Level 41
            "Symbol of Pinzarn", -- Level 31
            "Symbol of Ryltan",  -- Level 21
            "Symbol of Transal", -- Level 11
        },
        ['AbsorbAura'] = {
            ----Aura Buffs - Aura Name is seperate than the buff name
            "Aura of the Pious",  -- Level 66
            "Aura of the Zealot", -- Level 55
        },
        ['DivineBuff'] = {
            --Divine Buffs REQUIRES extra spell slot because of the 90s recast
            "Divine Incursion",    -- Level 69 EQM Custom
            "Divine Interaction",  -- Level 65 EQM Custom
            "Divine Intervention", -- Level 60
            "Death Pact",          -- Level 51
        },
        ['RezSpell'] = {
            "Reviviscence",   -- Level 56
            "Resurrection",   -- Level 47
            "Restoration",    -- Level 42
            "Resuscitate",    -- Level 37
            "Renewal",        -- Level 32
            "Revive",         -- Level 27
            "Reparation",     -- Level 22
            "Reconstitution", -- Level 18
            "Reanimation",    -- Level 12
        },
        ['SingleElixir'] = {
            "Sacred Elixir",     -- Level 71
            "Pious Elixir",      -- Level 67
            "Holy Elixir",       -- Level 65
            "Supernal Elixir",   -- Level 62
            "Celestial Elixir",  -- Level 59
            "Celestial Healing", -- Level 44
            "Celestial Health",  -- Level 29
            "Celestial Remedy",  -- Level 19
        },
        ['GroupElixir'] = {
            "Elixir of Divinity", -- Level 70
            "Ethereal Elixir",    -- Level 60
        },
        ['SpellBlessing'] = {
            "Aura of Purpose",       -- Level 71
            "Blessing of Purpose",   -- Level 71
            "Aura of Devotion",      -- Level 69
            "Blessing of Devotion",  -- Level 67
            "Aura of Reverence",     -- Level 64
            "Blessing of Reverence", -- Level 62
            "Blessing of Faith",     -- Level 35
            "Blessing of Piety",     -- Level 15
        },
        -- ['CureAll'] = { -- The single target cures that come after outclass this
        --     "Pure Blood", -- Level 51
        -- },
        ['CurePoison'] = {
            "Antidote",          -- Level 58
            "Eradicate Poison",  -- Level 52
            "Abolish Poison",    -- Level 48
            "Counteract Poison", -- Level 22
            "Cure Poison",       -- Level 1
        },
        ['CureDisease'] = {
            "Eradicate Disease",  -- Level 58
            "Counteract Disease", -- Level 28
            "Cure Disease",       -- Level 4
        },
        ['CureCurse'] = {
            "Eradicate Curse",      -- Level 54
            "Remove Greater Curse", -- Level 54
            "Remove Curse",         -- Level 38
            "Remove Lesser Curse",  -- Level 23
            "Remove Minor Curse",   -- Level 8
        },
        ['CureCorrupt'] = {
            "Cure Corruption", -- Level 70
        },
        ['YaulpSpell'] = {
            "Yaulp VII",         -- Level 69
            "Yaulp VI",          -- Level 65
            "Yaulp V",           -- Level 56, first rank with haste/mana regen. We won't use it before this.
        },
        ['StunTimer6'] = {       -- Timer 6 Stun, Fast Cast, Level 63+ (with ToT Heal 88+)
            "Sound of Zeal",     -- Level 71, works up to level 75
            "Sound of Divinity", -- Level 68, works up to level 70
            "Sound of Might",    -- Level 63
            --Filler before this
            "Tarnation",         -- Level 61, Timer 4, up to Level 65
            "Force",             -- Level 31, No Timer #, up to Level 58
            "Holy Might",        -- Level 16, No Timer #, up to Level 55
        },
        ['StunTimer4'] = {
            "Shock of Wonder", -- Level 66
        },
        ['LowLevelStun'] = {   --Adding a second stun at low levels
            "Stun",            -- Level 2
        },
        ['UndeadNuke'] = {     -- Level 4+
            "Desolate Undead", -- Level 68
            "Destroy Undead",  -- Level 64
            "Exile Undead",    -- Level 55
            "Banish Undead",   -- Level 43
            "Expel Undead",    -- Level 33
            "Dismiss Undead",  -- Level 23
            "Expulse Undead",  -- Level 13
            "Ward Undead",     -- Level 4
        },
        ['MagicNuke'] = {
            "Reproval",               -- Level 71
            "Chromastrike",           -- Level 69
            "Reproach",               -- Level 67
            "Ancient: Chaos Censure", -- Level 65
            "Order",                  -- Level 65
            "Condemnation",           -- Level 62
            "Judgment",               -- Level 56
            "Reckoning",              -- Level 54
            "Retribution",            -- Level 44
            "Wrath",                  -- Level 29
            "Smite",                  -- Level 14
            "Furor",                  -- Level 5
            "Strike",                 -- Level 1
        },
        ['QuickNuke'] = {             -- Might specific
            "Verdict of Ascension",   -- Level 69 EQM Custom
            "Verdict of Radiance",    -- Level 65 EQM Custom
            "Verdict of Light",       -- Level 60 EQM Custom
        },
        -- ['HammerPet'] = {
        --     "Unswerving Hammer of Retribution", -- Level 68
        --     "Unswerving Hammer of Faith",       -- Level 54
        -- },
        ['CompleteHeal'] = {
            "Complete Heal",      -- Level 39
        },
        ['PBAENuke'] = {          --This isn't worthwhile before these spells come around.
            "Calamity",           -- Level 69
            "Catastrophe",        -- Level 64
        },
        ['PBAEStun'] = {          --This isn't worthwhile before these spells come around. The stun won't land in many cases (level) but the damage is okay.
            "Silent Dictation",   -- Level 70
            "The Silent Command", -- Level 65
        },
        ['PromisedHeal'] = {
            "Promised Renewal", -- Level 71
        },
    },                          -- end AbilitySets
    ['AASets']            = {
        ['Spire'] = {
            "Fundament: Second Spire of Divinity",
            "Fundament: First Spire of Divinity",
        },
    },
    ['Helpers']           = {
        -- Artifact of Aegis is Aegis of Vie Rk. I
        PreferAegisSpell = function(self)
            if mq.TLO.Me.Level() < 69 or not mq.TLO.FindItem("=Artifact of Aegis")() then return true end
            local vieBuff = self.ResolvedActionMap['SingleVieBuff']
            return vieBuff and vieBuff() and vieBuff.Name() == "Aegis of Vie" and (vieBuff.RankName.Rank() or 0) >= 2
        end,
        UseGroupHealCure = function(self, keepSetting)
            local ghealSpell = Core.GetResolvedActionMapItem('GroupHeal')
            return Config:GetSetting('GroupHealAsCure') and not Config:GetSetting(keepSetting) and (ghealSpell and ghealSpell.Level() or 0) >= 64
        end,
        ClassShort = function(self, target)
            if not (target and target()) then return "OTH" end
            if Targeting.TargetIsType("pet", target) then return "OTH" end
            local sn = (target.Class.ShortName() or ""):upper()
            if sn == "" then return "OTH" end
            return sn
        end,
        HealRole = function(self, target)
            return classToHealRole(self.Helpers.ClassShort(self, target))
        end,
        HealPct = function(self, kind, target)
            local role = self.Helpers.HealRole(self, target)
            -- CompleteHeal settings exist only for Tank. SortHealRotationByThreshold still
            -- asks for Melee/Caster — avoid GetSetting cache miss spam.
            if kind == "CompleteHeal" and role ~= "Tank" then
                return 0
            end
            local key = healPctSettingKey(kind, role)
            return tonumber(Config:GetSetting(key)) or defaultHealPct(kind, role)
        end,
        ClassBelow = function(self, kind, target)
            if not (target and target()) then return false end
            local threshold = self.Helpers.HealPct(self, kind, target)
            if not threshold or threshold <= 0 then return false end -- 0 = disabled for this role/kind
            return (target.PctHPs() or 999) <= threshold
        end,
        CompleteHealWanted = function(self, target)
            if not Config:GetSetting("DoCompleteHeal") then return false end
            if not (target and target()) then return false end
            if self.Helpers.HealRole(self, target) ~= "Tank" then return false end
            return self.Helpers.ClassBelow(self, "CompleteHeal", target)
        end,
        GroupClassInjureCount = function(self, kind)
            local count = 0
            local function consider(spawn, isSelf)
                if not (spawn and spawn()) then return end
                if spawn.Dead() then return end
                if not isSelf and (spawn.OtherZone() or spawn.Offline()) then return end
                if not isSelf and (spawn.Distance3D() or 999) > 300 then return end
                if self.Helpers.ClassBelow(self, kind, spawn) then
                    count = count + 1
                end
            end
            consider(mq.TLO.Me, true)
            for i = 1, mq.TLO.Group.Members() or 0 do
                consider(mq.TLO.Group.Member(i), false)
            end
            return count
        end,
        GroupClassHealsNeeded = function(self)
            -- Count members at/below Group Regular Heal %; preferred when Group Injured Count is met.
            return self.Helpers.GroupClassInjureCount(self, "GroupHeal") >= Config:GetSetting('GroupInjureCnt')
        end,
        GroupClassHoTsNeeded = function(self)
            -- Count members at/below Group HoT %; preferred when Group Injured Count is met.
            return self.Helpers.GroupClassInjureCount(self, "GroupHoT") >= Config:GetSetting('GroupInjureCnt')
        end,
        MainHealWanted = function(self, target)
            if not (target and target()) then return false end
            if self.Helpers.CompleteHealWanted(self, target) then return true end
            if self.Helpers.ClassBelow(self, "FastHeal", target) then return true end
            if self.Helpers.ClassBelow(self, "Light", target) then return true end
            if self.Helpers.ClassBelow(self, "SingleHoT", target) then return true end
            return false
        end,
        HealWanted = function(self, target)
            if not (target and target()) then return false end
            if self.Helpers.MainHealWanted(self, target) then return true end
            if self.Helpers.GroupClassHealsNeeded(self) then return true end
            if self.Helpers.GroupClassHoTsNeeded(self) then return true end
            return false
        end,

        -- Single HoT refresh: local expiry timer + BuffDuration resync (focus-aware).
        -- Prefer the SingleElixir rank actually in a gem (not just the resolved/book best).
        SingleHoTBuffName = function(self)
            local function buffNameFromGem(lookupName)
                if not lookupName or lookupName == "" then return nil end
                local slot = mq.TLO.Me.Gem(lookupName)()
                if not slot then return nil end
                local gem = mq.TLO.Me.Gem(slot)
                if not (gem and gem()) then return nil end
                -- BuffDuration matches buff-window name; BaseName is reliable on EQ Might.
                return gem.BaseName() or gem.Name() or gem.RankName() or lookupName
            end

            local list = self.ClassConfig and self.ClassConfig.AbilitySets and self.ClassConfig.AbilitySets.SingleElixir
            for _, name in ipairs(list or {}) do
                local buffName = buffNameFromGem(name)
                if buffName then return buffName end
            end
            return nil
        end,
        SingleHoTCastMs = function(self, spell)
            if not (spell and spell()) then return 0 end
            local castMs = tonumber(spell.MyCastTime()) or 0
            if castMs <= 0 then
                castMs = (tonumber(spell.MyCastTime.TotalSeconds()) or 0) * 1000
            end
            return castMs
        end,
        SetSingleHoTTimer = function(self, targetId, durationMs)
            if not targetId or not durationMs or durationMs <= 0 then return end
            self.TempSettings.SingleHoTExpires = self.TempSettings.SingleHoTExpires or {}
            self.TempSettings.SingleHoTExpires[targetId] = Globals.GetTimeMS() + durationMs
        end,
        GetSingleHoTRemainingMs = function(self, targetId)
            local expires = self.TempSettings.SingleHoTExpires and self.TempSettings.SingleHoTExpires[targetId]
            if not expires then return 0 end
            return math.max(0, expires - Globals.GetTimeMS())
        end,
        FindDanNetPeer = function(self, target)
            if not (target and target()) then return nil end
            local clean = target.CleanName() or target.DisplayName()
            if not clean or clean == "" then return nil end

            -- Prefer the full DanNet peer key from the peers list (e.g. "project might_elleair").
            -- Bare CleanName ("Elleair") can appear valid but return bad Q/O data vs the real peer.
            local peers = mq.TLO.DanNet.Peers() or ""
            local lower = clean:lower()
            local escaped = lower:gsub("(%W)", "%%%1")
            local best = nil
            for peer in string.gmatch(peers, "([^|]+)") do
                peer = peer:match("^%s*(.-)%s*$") or peer
                if peer ~= "" then
                    local peerLower = peer:lower()
                    local match = peerLower == lower
                        or peerLower:match("_" .. escaped .. "$")
                        or peerLower:match("%s" .. escaped .. "$")
                    if match and mq.TLO.DanNet(peer)() then
                        if peerLower == lower then return peer end
                        if not best or #peer > #best then best = peer end
                    end
                end
            end
            if best then return best end
            if mq.TLO.DanNet(clean)() then return clean end
            return nil
        end,
        -- Fresh Me.BuffDuration via /dquery (full peer key).
        QueryPeerBuffDurationMs = function(self, peer, buffName)
            if not peer or not buffName then return nil end

            local function parseDuration(raw)
                if raw == nil then return nil end
                if type(raw) == "number" then
                    return raw > 0 and raw or nil
                end
                local s = tostring(raw)
                if s == "" or s:lower() == "null" then return nil end
                local n = tonumber(s)
                return (n and n > 0) and n or nil
            end

            -- BuffDuration[Name] (not [=Name]): exact form can stick at max via DanNet.
            local buffQuery = string.format("Me.BuffDuration[%s]", buffName)

            local function oneQuery()
                local before = tonumber(mq.TLO.DanNet(peer).Q(buffQuery).Received()) or 0
                mq.cmdf('/dquery "%s" -q "%s"', peer, buffQuery)
                mq.delay(25)
                mq.delay(750, function()
                    return (tonumber(mq.TLO.DanNet(peer).Q(buffQuery).Received()) or 0) > before
                end)
                local after = tonumber(mq.TLO.DanNet(peer).Q(buffQuery).Received()) or 0
                if after <= before then return nil end
                return parseDuration(mq.TLO.DanNet(peer).Q(buffQuery)())
            end

            local ms = oneQuery()
            if ms then return ms end
            mq.delay(300)
            return oneQuery()
        end,
        -- Returns remaining BuffDuration in ms (focus included), or nil if unavailable.
        GetSingleHoTDurationMs = function(self, spell, target)
            if not (target and target()) then return nil end
            local buffName = self.Helpers.SingleHoTBuffName(self)
            if not buffName then return nil end

            local function parseDuration(raw)
                if raw == nil then return nil end
                if type(raw) == "number" then
                    return raw > 0 and raw or nil
                end
                local s = tostring(raw)
                if s == "" or s:lower() == "null" then return nil end
                local n = tonumber(s)
                return (n and n > 0) and n or nil
            end

            if target.ID() == mq.TLO.Me.ID() then
                local bd = mq.TLO.Me.BuffDuration(buffName)
                local ms = parseDuration(bd and bd())
                if ms then return ms end
                if bd and bd.TotalSeconds then
                    local secs = tonumber(bd.TotalSeconds())
                    if secs and secs > 0 then return secs * 1000 end
                end
                return nil
            end

            local peer = self.Helpers.FindDanNetPeer(self, target)
            if not peer then return nil end
            return self.Helpers.QueryPeerBuffDurationMs(self, peer, buffName)
        end,
        -- True when SingleElixir should cast on target.
        SingleHoTWanted = function(self, spell, target)
            if not self.Helpers.ClassBelow(self, "SingleHoT", target) then return false end
            if not (spell and spell() and target and target()) then return false end

            -- Missing buff → cast immediately (no duration query).
            if Casting.GroupBuffCheck(spell, target) then
                self.TempSettings.SingleHoTPendingId = target.ID()
                return true
            end

            local castMs = self.Helpers.SingleHoTCastMs(self, spell)
            -- Cast time + 6.5s: cover EQ 6s tick rounding on BuffDuration vs local ms timer.
            local refreshAtMs = castMs + 6500
            local remMs = self.Helpers.GetSingleHoTRemainingMs(self, target.ID())
            if remMs > refreshAtMs then return false end

            -- Local timer says refresh is due: verify live BuffDuration before casting.
            local liveMs = self.Helpers.GetSingleHoTDurationMs(self, spell, target)
            if liveMs == nil or liveMs <= refreshAtMs then
                self.TempSettings.SingleHoTPendingId = target.ID()
                return true
            end
            self.Helpers.SetSingleHoTTimer(self, target.ID(), liveMs)
            return false
        end,
        SingleHoTOnCastComplete = function(self, spell, success)
            local tid = self.TempSettings.SingleHoTPendingId
            self.TempSettings.SingleHoTPendingId = nil
            if not success or not tid then return end
            local target = mq.TLO.Spawn(tid)
            if not (target and target()) then return end
            mq.delay(350)
            local ms = self.Helpers.GetSingleHoTDurationMs(self, spell, target)
            if ms and ms > 0 then
                self.Helpers.SetSingleHoTTimer(self, tid, ms)
            end
        end,
    },

    -- Single heal rotation: class thresholds gate each spell; runtime sorts heal_kind entries by
    -- threshold ascending (lower %% = higher priority). Group Regular Heal / Group HoT have their
    -- own %%; when Group Injured Count is met, group spells sort ahead of equal-%% singles.
    ['HealRotationOrder'] = {
        {
            name = 'Heal',
            state = 1,
            steps = 1,
            doFullRotation = true,
            sortByHealThreshold = true,
            cond = function(self, target)
                return self.Helpers.HealWanted(self, target)
            end,
        },
    },
    ['HealRotations']     = {
        ['Heal'] = {
            -- No heal_kind: always checked first (mana panic clickies only).
            {
                name = "Timer2HealItem",
                type = "Item",
                cond = function(self, itemName, target)
                    return mq.TLO.Me.PctMana() < 10
                end,
            },
            {
                name = "Braided Kirin Mane",
                type = "Item",
                load_cond = function(self) return mq.TLO.FindItem("=Braided Kirin Mane")() end,
                cond = function(self, itemName, target)
                    return mq.TLO.Me.PctMana() < 10
                end,
            },
            -- Threshold-sorted (heal_kind). Same %% keeps this list order as tie-break.
            {
                name = "Divine Arbitration",
                type = "AA",
                heal_kind = "FastHeal",
                cond = function(self, aaName, target)
                    if not self.Helpers.ClassBelow(self, "FastHeal", target) then return false end
                    if not Targeting.GroupedWithTarget(target) then return false end
                    return Targeting.TargetIsTanking(target)
                end,
            },
            {
                name = "Sanctuary",
                type = "AA",
                heal_kind = "FastHeal",
                cond = function(self, aaName, target)
                    if not self.Helpers.ClassBelow(self, "FastHeal", target) then return false end
                    return Targeting.TargetIsMyself(target)
                end,
            },
            {
                name = "Burst of Life",
                type = "AA",
                heal_kind = "FastHeal",
                cond = function(self, aaName, target)
                    return self.Helpers.ClassBelow(self, "FastHeal", target)
                end,
            },
            {
                name = "Epic",
                type = "Item",
                heal_kind = "FastHeal",
                cond = function(self, itemName, target)
                    if not self.Helpers.ClassBelow(self, "FastHeal", target) then return false end
                    if not Targeting.GroupedWithTarget(target) then return false end
                    return Targeting.TargetIsTanking(target)
                end,
            },
            {
                name = "RemedyHeal",
                type = "Spell",
                heal_kind = "FastHeal",
                cond = function(self, spell, target)
                    return self.Helpers.ClassBelow(self, "FastHeal", target)
                end,
            },
            {
                name = "Renewal",
                type = "Spell",
                heal_kind = "Light",
                cond = function(self, spell, target)
                    return self.Helpers.ClassBelow(self, "Light", target)
                end,
            },
            {
                name = "Focused Celestial Regeneration",
                type = "AA",
                heal_kind = "FastHeal",
                cond = function(self, aaName, target)
                    if not self.Helpers.ClassBelow(self, "FastHeal", target) then return false end
                    return Targeting.TargetIsTanking(target)
                end,
            },
            {
                name = "Blessing of Sanctuary",
                type = "AA",
                heal_kind = "FastHeal",
                cond = function(self, aaName, target)
                    if not self.Helpers.ClassBelow(self, "FastHeal", target) then return false end
                    return target.ID() == (mq.TLO.Target.AggroHolder.ID() or 0) and not Targeting.TargetIsTanking(target)
                end,
            },
            {
                name = "Celestial Rapidity",
                type = "AA",
                heal_kind = "FastHeal",
                cond = function(self, aaName, target)
                    return self.Helpers.ClassBelow(self, "FastHeal", target)
                end,
            },
            {
                name = "Forceful Rejuvenation",
                type = "AA",
                heal_kind = "FastHeal",
                cond = function(self, aaName, target)
                    return self.Helpers.ClassBelow(self, "FastHeal", target)
                end,
            },
            {
                name = "Beacon of Life",
                type = "AA",
                heal_kind = "GroupHeal",
                cond = function(self)
                    return self.Helpers.GroupClassHealsNeeded(self)
                end,
            },
            {
                name = "Celestial Regeneration",
                type = "AA",
                heal_kind = "GroupHeal",
                cond = function(self)
                    return self.Helpers.GroupClassHealsNeeded(self)
                end,
                pre_activate = function(self)
                    if Casting.AAReady("Mass Group Buff") and Globals.AutoTargetIsNamed then
                        Casting.UseAA("Mass Group Buff", Globals.AutoTargetID)
                    end
                end,
            },
            {
                name = "GroupElixir",
                type = "Spell",
                heal_kind = "GroupHoT",
                load_cond = function() return Config:GetSetting('DoGroupElixir') end,
                cond = function(self, spell, target)
                    if not self.Helpers.GroupClassHoTsNeeded(self) then return false end
                    return Casting.GroupBuffCheck(spell, target)
                end,
            },
            {
                name = "Exquisite Benediction",
                type = "AA",
                heal_kind = "GroupHeal",
                cond = function(self)
                    return Casting.BurnCheck() and self.Helpers.GroupClassHealsNeeded(self)
                end,
            },
            {
                name = "VampiricBlueBand",
                type = "Item",
                heal_kind = "GroupHeal",
                load_cond = function(self) return Core.GetResolvedActionMapItem("VampiricBlueBand") and mq.TLO.Me.Level() >= 68 end,
                cond = function(self)
                    return self.Helpers.GroupClassHealsNeeded(self)
                end,
            },
            {
                name = "BlueBand",
                type = "Item",
                heal_kind = "GroupHeal",
                load_cond = function(self) return Core.GetResolvedActionMapItem("BlueBand") and (mq.TLO.Me.Level() < 68 or not Core.GetResolvedActionMapItem("VampiricBlueBand")) end,
                cond = function(self)
                    return self.Helpers.GroupClassHealsNeeded(self)
                end,
            },
            {
                name = "GroupHeal",
                type = "Spell",
                heal_kind = "GroupHeal",
                cond = function(self)
                    return self.Helpers.GroupClassHealsNeeded(self)
                end,
            },
            {
                name = "CompleteHeal",
                type = "Spell",
                heal_kind = "CompleteHeal",
                cond = function(self, spell, target)
                    return self.Helpers.CompleteHealWanted(self, target)
                end,
            },
            {
                name = "HealingLight",
                type = "Spell",
                heal_kind = "Light",
                cond = function(self, spell, target)
                    return self.Helpers.ClassBelow(self, "Light", target)
                end,
            },
            {
                name = "SingleElixir",
                type = "Spell",
                heal_kind = "SingleHoT",
                load_cond = function(self) return Config:GetSetting('DoSingleElixir') end,
                cond = function(self, spell, target)
                    return self.Helpers.SingleHoTWanted(self, spell, target)
                end,
                post_activate = function(self, spell, success)
                    self.Helpers.SingleHoTOnCastComplete(self, spell, success)
                end,
            },
        },
    },
    ['Charm']             = {
        ['Assist'] = {
            { name = "LowLevelStun", type = "Spell", cond = function(self, spell, target) return Targeting.TargetNotStunned() end, },
            { name = "StunTimer6",   type = "Spell", cond = function(self, spell, target) return Targeting.TargetNotStunned() end, },
            { name = "PBAEStun",     type = "Spell", cond = function(self, spell, target) return Targeting.TargetNotStunned() and Targeting.InSpellRange(spell, target) end, },
        },
    },
    ['RotationOrder']     = {
        -- Downtime doesn't have state because we run the whole rotation at once.
        {
            name = 'Downtime',
            targetId = function(self) return { mq.TLO.Me.ID(), } end,
            cond = function(self, combat_state)
                return combat_state == "Downtime" and Core.CombatActionsCheck() and Casting.OkayToBuff() and Casting.AmIBuffable()
            end,
        },
        { --Spells that should be checked on group members
            name = 'GroupBuff',
            state = 1,
            steps = 1,
            targetId = function(self) return Casting.GetBuffableIDs() end,
            cond = function(self, combat_state)
                return combat_state == "Downtime" and Core.CombatActionsCheck() and Casting.OkayToBuff()
            end,
        },
        {
            name = 'Burn',
            state = 1,
            steps = 3,
            targetId = function(self) return Targeting.CheckForAutoTargetID() end,
            cond = function(self, combat_state)
                return combat_state == "Combat" and Casting.BurnCheck() and Core.CombatActionsCheck()
            end,
        },
        {
            name = 'ManaRestore',
            timer = 30,
            state = 1,
            steps = 1,
            load_cond = function() return Config:GetSetting('DoManaRestore') and (Casting.CanUseAA("Veturika's Perseverance") or Casting.CanUseAA("Quiet Miracle")) end,
            targetId = function(self) return { Combat.FindWorstHurtMana(Config:GetSetting('ManaRestorePct')), } end,
            cond = function(self, combat_state)
                local downtime = combat_state == "Downtime" and Casting.OkayToBuff()
                local combat = combat_state == "Combat"
                return (downtime or combat) and Core.CombatActionsCheck()
            end,
        },
        {
            name = 'DPS(AE)',
            state = 1,
            steps = 1,
            load_cond = function(self)
                return (Config:GetSetting('DoPBAENuke') and self:GetResolvedActionMapItem('PBAENuke')) or
                    (Config:GetSetting('DoPBAEStun') and self:GetResolvedActionMapItem('PBAEStun'))
            end,
            doFullRotation = true,
            targetId = function(self) return Targeting.CheckForAutoTargetID() end,
            cond = function(self, combat_state)
                return combat_state == "Combat" and Core.CombatActionsCheck() and Config:GetSetting('DoAEDamage') and Combat.AETargetCheck(true)
            end,
        },
        {
            name = 'DPS',
            state = 1,
            steps = 1,
            doFullRotation = true,
            targetId = function(self) return Targeting.CheckForAutoTargetID() end,
            cond = function(self, combat_state)
                return combat_state == "Combat" and Core.CombatActionsCheck()
            end,
        },
        {
            name = 'CombatBuffs',
            state = 1,
            steps = 1,
            targetId = function(self) return Casting.GetBuffableTankingIDs() end, -- change back to buffableIDs if we ever add non-tank stuff here
            cond = function(self, combat_state)
                return combat_state == "Combat" and Core.CombatActionsCheck()
            end,
        },
    },
    ['Rotations']         = {
        ['ManaRestore'] = {
            {
                name = "Veturika's Perseverance",
                type = "AA",
                cond = function(self, aaName, target)
                    return Targeting.TargetIsMyself(target) and Casting.AmIBuffable()
                end,
            },
            {
                name = "Quiet Miracle",
                type = "AA",
                cond = function(self, aaName, target)
                    if Targeting.TargetIsMyself(target) then return false end
                    local rezSearch = string.format("pccorpse %s radius 100 zradius 50", target.DisplayName())
                    return mq.TLO.SpawnCount(rezSearch)() == 0
                end,
            },
        },
        ['Burn'] = {
            {
                name = "Celestial Hammer",
                type = "AA",
            },
            {
                name = "Flurry of Life",
                type = "AA",
            },
            {
                name = "Healing Frenzy",
                type = "AA",
            },
            {
                name = "Spire",
                type = "AA",
            },
            {
                name = "OoW_Chest",
                type = "Item",
            },
            {
                name = "Divine Avatar",
                type = "AA",
                cond = function(self)
                    return Config:GetSetting('DoMelee') and mq.TLO.Me.Combat()
                end,
            },
            { --homework: This is a defensive proc, likely need to add elsewhere
                name = "Divine Retribution",
                type = "AA",
                cond = function(self)
                    return Config:GetSetting('DoMelee') and mq.TLO.Me.Combat()
                end,
            },
            {
                name = "Battle Frenzy",
                type = "AA",
            },
            {
                name = "Improved Twincast",
                type = "AA",
            },
            { --homework: Check if this is necessary (does not exceed 50% spell haste cap)
                name = "Celestial Rapidity",
                type = "AA",
            },
        },
        ['CombatBuffs'] = {
            {
                name = "DivineBuff",
                type = "Spell",
                load_cond = function(self) return Config:GetSetting('DoDivineBuff') end,
                cond = function(self, spell, target)
                    if not Casting.CastReady(spell) then return false end --avoid constant group buff checks
                    return Casting.GroupBuffCheck(spell, target)
                end,
            },
            {
                name = "Artifact of Aegis",
                type = "Item",
                load_cond = function(self) return Config:GetSetting('VieBuffMode') > 2 and not self.Helpers.PreferAegisSpell(self) end,
                cond = function(self, itemName, target)
                    return Casting.AddedBuffCheck(43037, target) and Casting.GroupBuffItemCheck(itemName, target) -- Bulwark of the Pegasus
                end,
            },
            {
                name = "SingleVieBuff",
                type = "Spell",
                load_cond = function(self) return Config:GetSetting('VieBuffMode') > 2 and self.Helpers.PreferAegisSpell(self) end,
                cond = function(self, spell, target)
                    return Casting.AddedBuffCheck(43037, target) and Casting.GroupBuffCheck(spell, target) -- Bulwark of the Pegasus
                end,
            },
        },
        ['DPS'] = {
            {
                name = "GroupElixir",
                type = "Spell",
                allowDead = true,
                load_cond = function(self) return Config:GetSetting('DoGroupElixir') end,
                cond = function(self, spell)
                    if not Config:GetSetting('GroupElixirUptime') then return false end
                    -- Full uptime: refresh when song is short. Also refresh early if anyone is at/below class Group HoT %.
                    local songSecs = mq.TLO.Me.Song(spell).Duration.TotalSeconds() or 0
                    if not spell.RankName.Stacks() then return false end
                    if songSecs < 6 then return true end
                    return self.Helpers.GroupClassInjureCount(self, "SingleHoT") > 0 and songSecs < 12
                end,
            },
            {
                name = "Yaulp",
                type = "AA",
                allowDead = true,
                load_cond = function(self) return Config:GetSetting('DoYaulp') and Casting.CanUseAA("Yaulp") end,
                cond = function(self, aaName)
                    return not mq.TLO.Me.Mount() and Casting.SelfBuffAACheck(aaName)
                end,
            },
            {
                name = "YaulpSpell",
                type = "Spell",
                allowDead = true,
                load_cond = function(self) return Config:GetSetting('DoYaulp') and not Casting.CanUseAA("Yaulp") end,
                cond = function(self, spell)
                    return not mq.TLO.Me.Mount() and Casting.SelfBuffCheck(spell)
                end,
            },
            {
                name = "StunTimer6",
                type = "Spell",
                load_cond = function(self) return Config:GetSetting('DoTimer6Stun') end,
                cond = function(self, spell, target)
                    return Casting.HaveManaToNuke(true) -- no stun checks because these are Recourse of Life procs as well
                end,
            },
            {
                name = "StunTimer4",
                type = "Spell",
                load_cond = function(self) return Config:GetSetting('DoTimer4Stun') end,
                cond = function(self, spell, target)
                    return Casting.HaveManaToNuke(true) -- no stun checks because these are Recourse of Life procs as well
                end,
            },
            {
                name = "LowLevelStun",
                type = "Spell",
                load_cond = function(self) return Config:GetSetting('DoLLStun') end,
                cond = function(self, spell, target)
                    local targetLevel = Targeting.GetAutoTargetLevel()
                    if targetLevel == 0 or targetLevel > 55 then return false end
                    return Casting.HaveManaToNuke(true) and Targeting.TargetNotStunned() and not Globals.AutoTargetIsNamed
                end,
            },
            {
                name = "Turn Undead",
                type = "AA",
                cond = function(self, aaName, target)
                    return Targeting.TargetBodyIs(target, "Undead") and Targeting.AggroCheckOkay()
                end,
            },
            {
                name = "QuickNuke",
                type = "Spell",
                load_cond = function(self) return Config:GetSetting('DoQuickNuke') end,
                cond = function(self)
                    return Casting.OkayToNuke(true)
                end,
            },
            {
                name = "UndeadNuke",
                type = "Spell",
                load_cond = function(self) return Config:GetSetting('DoUndeadNuke') end,
                cond = function(self, aaName, target)
                    if not Targeting.TargetBodyIs(target, "Undead") then return false end
                    return Casting.OkayToNuke(true)
                end,
            },
            {
                name = "MagicNuke",
                type = "Spell",
                load_cond = function(self) return Config:GetSetting('DoMagicNuke') end,
                cond = function(self)
                    return Casting.OkayToNuke(true)
                end,
            },
            {
                name = "Bash",
                type = "Ability",
                cond = function(self, abilityName, target)
                    return Config:GetSetting('DoMelee') and Core.ShieldEquipped()
                end,
            },
        },
        ['DPS(AE)'] = {
            {
                name = "PBAEStun",
                type = "Spell",
                allowDead = true,
                load_cond = function(self) return Config:GetSetting('DoPBAEStun') end,
                cond = function(self, spell, target)
                    return Casting.HaveManaToNuke(true) and Targeting.InSpellRange(spell, target)
                end,
            },
            {
                name = "PBAENuke",
                type = "Spell",
                allowDead = true,
                load_cond = function(self) return Config:GetSetting('DoPBAENuke') end,
                cond = function(self, spell, target)
                    return Casting.OkayToNuke(true) and Targeting.InSpellRange(spell, target)
                end,
            },
        },
        ['Downtime'] = {
            {
                name = "SelfHPBuff",
                type = "Spell",
                load_cond = function() return Config:GetSetting('AegoSymbol') ~= 3 end,
                cond = function(self, spell)
                    return Casting.SelfBuffCheck(spell)
                end,
            },
            {
                name = "AbsorbAura",
                type = "Spell",
                pre_activate = function(self, spell) --remove the old aura if we leveled up, otherwise we will be spammed because of no focus.
                    ---@diagnostic disable-next-line: undefined-field
                    if not Casting.AuraActiveByName(spell.BaseName()) then mq.TLO.Me.Aura(1).Remove() end
                end,
                cond = function(self, spell)
                    return not Casting.AuraActiveByName(spell.BaseName())
                end,
            },
        },
        ['GroupBuff'] = {
            {
                name = "Divine Guardian",
                type = "AA",
                cond = function(self, aaName, target)
                    if not Targeting.TargetIsTanking(target) then return false end
                    return Casting.GroupBuffAACheck(aaName, target)
                end,
            },
            {
                name_func = function(self) return Casting.GetFirstMapItem({ 'AegoBuff', 'HPTypeOne', }) end,
                type = "Spell",
                load_cond = function(self) return Config:GetSetting('AegoSymbol') <= 2 end,
                cond = function(self, spell, target)
                    return Casting.GroupBuffCheck(spell, target)
                end,
            },
            {
                name_func = function(self)
                    if mq.TLO.FindItem("=Mythical Armband of Elushar")() then return "Mythical Armband of Elushar" end
                    if mq.TLO.FindItem("=Legendary Armband of Mithaniel")() then return "Legendary Armband of Mithaniel" end
                    return "Symbol Buff Clicky"
                end,
                type = "Item",
                load_cond = function()
                    return Config:GetSetting('AegoSymbol') >= 2 and Config:GetSetting('AegoSymbol') <= 3 and
                        mq.TLO.Me.Level() >= 68 and (mq.TLO.FindItem("=Mythical Armband of Elushar")() or mq.TLO.FindItem("=Legendary Armband of Mithaniel")())
                end,
                cond = function(self, itemName, target)
                    return Casting.GroupBuffItemCheck(itemName, target)
                end,
            },
            {
                name = "GroupSymbolBuff",
                type = "Spell",
                load_cond = function()
                    return Config:GetSetting('AegoSymbol') >= 2 and Config:GetSetting('AegoSymbol') <= 3 and
                        (mq.TLO.Me.Level() < 68 or not mq.TLO.FindItem("=Legendary Armband of Mithaniel")())
                end,
                cond = function(self, spell, target)
                    if (spell.TargetType() or ""):lower() == "single" and not Targeting.TargetIsTanking(target) then return false end
                    return Casting.GroupBuffCheck(spell, target)
                end,
            },
            {
                name = "SpellBlessing",
                type = "Spell",
                cond = function(self, spell, target)
                    if mq.TLO.Me.Level() > 91 then return false end
                    return Casting.GroupBuffCheck(spell, target)
                end,
            },
            {
                name = "ACBuff",
                type = "Spell",
                load_cond = function(self) return Config:GetSetting('DoACBuff') end,
                cond = function(self, spell, target)
                    if (spell.TargetType() or ""):lower() == "single" and not Targeting.TargetIsTanking(target) then return false end
                    return Casting.GroupBuffCheck(spell, target)
                end,
            },
            {
                name = "Artifact of Aegis",
                type = "Item",
                load_cond = function(self) return Config:GetSetting('VieBuffMode') > 1 and not self.Helpers.PreferAegisSpell(self) end,
                cond = function(self, itemName, target)
                    return Casting.AddedBuffCheck(43037, target) and Casting.GroupBuffItemCheck(itemName, target) -- Bulwark of the Pegasus
                end,
            },
            {
                name = "SingleVieBuff",
                type = "Spell",
                load_cond = function(self) return Config:GetSetting('VieBuffMode') > 1 and self.Helpers.PreferAegisSpell(self) end,
                cond = function(self, spell, target)
                    return Casting.AddedBuffCheck(43037, target) and Casting.GroupBuffCheck(spell, target) -- Bulwark of the Pegasus
                end,
            },
            {
                name = "DivineBuff",
                type = "Spell",
                load_cond = function(self) return Config:GetSetting('DoDivineBuff') end,
                cond = function(self, spell, target)
                    if not Targeting.TargetIsTanking(target) then return false end
                    return Casting.CastReady(spell) and Casting.GroupBuffCheck(spell, target)
                end,
            },
        },
    },
    -- New style spell list, gemless, priority-based. Will use the first set whose conditions are met.
    -- The list name ("Default" in the list below) is abitrary, it is simply what shows up in the UI when this spell list is loaded.
    -- Virtually any helper function or TLO can be used as a condition. Example: Mode or level-based lists.
    -- The first list without conditions or whose conditions returns true will be loaded, all subsequent lists will be ignored.
    -- Spells will be loaded in order (if the conditions are met), until all gem slots are full.
    -- Loadout checks (such as scribing a spell or using the "Rescan Loadout" or "Reload Spells" buttons) will re-check these lists and may load a different set if things have changed.
    ['SpellList']         = {
        {
            name = "Default",
            -- cond = function(self) return true end, --Kept here for illustration, this line could be removed in this instance since we aren't using conditions.
            spells = {
                -- Both memmed when DoCompleteHeal is ON (CH for tanks; Light for others / CH fallback).
                { name = "HealingLight", },
                { name = "CompleteHeal",  cond = function(self) return Config:GetSetting('DoCompleteHeal') end, },
                { name = "RemedyHeal", }, -- Class Heal: Fast Heal (keep gemmed even when Renewal exists)
                { name = "Renewal", },
                { name = "GroupHeal", },
                { name = "SingleElixir",  cond = function(self) return Config:GetSetting('DoSingleElixir') end, },
                { name = "GroupElixir",   cond = function(self) return Config:GetSetting('DoGroupElixir') end, },
                { name = "CurePoison",    cond = function(self) return Config:GetSetting('KeepPoisonMemmed') end, },
                { name = "CureDisease",   cond = function(self) return Config:GetSetting('KeepDiseaseMemmed') end, },
                { name = "CureCurse",     cond = function(self) return Config:GetSetting('KeepCurseMemmed') end, },
                { name = "CureCorrupt",   cond = function(self) return Config:GetSetting('KeepCorruptMemmed') end, },
                { name = "DivineBuff",    cond = function(self) return Config:GetSetting('DoDivineBuff') end, },
                { name = "YaulpSpell",    cond = function(self) return Config:GetSetting('DoYaulp') and not Casting.CanUseAA("Yaulp") end, },
                { name = "SingleVieBuff", cond = function(self) return Config:GetSetting('VieBuffMode') > 1 and self.Helpers.PreferAegisSpell(self) end, },
                { name = "StunTimer6",    cond = function(self) return Config:GetSetting('DoTimer6Stun') end, },
                { name = "StunTimer4",    cond = function(self) return Config:GetSetting('DoTimer4Stun') end, },
                { name = "LowLevelStun",  cond = function(self) return Config:GetSetting('DoLLStun') and mq.TLO.Me.Level() < 59 end, },
                { name = "QuickNuke",     cond = function(self) return Config:GetSetting('DoQuickNuke') end, },
                { name = "MagicNuke",     cond = function(self) return Config:GetSetting('DoMagicNuke') end, },
                { name = "PBAEStun",      cond = function(self) return Config:GetSetting('DoPBAEStun') end, },
                { name = "PBAENuke",      cond = function(self) return Config:GetSetting('DoPBAENuke') end, },
                { name = "UndeadNuke",    cond = function(self) return Config:GetSetting('DoUndeadNuke') end, },
                { name = "PromisedHeal", }, -- filler, for manual use only, the config does not use it automatically
                { name = "RezSpell",      cond = function(self) return not Casting.CanUseAA('Blessing of Resurrection') end, },
            },
        },
    },
    ['DefaultConfig']     = {
        ['Mode']              = {
            DisplayName = "Mode",
            Category = "Combat",
            Tooltip = "Select the Combat Mode for this Toon",
            Type = "Custom",
            RequiresLoadoutChange = true,
            Default = 1,
            Min = 1,
            Max = 1,
            FAQ = "What is the difference between the modes?",
            Answer = "Clerics currently only have one Mode. This may change in the future.",
        },
        --Buffs
        ['AegoSymbol']        = {
            DisplayName = "Aego/Symbol Choice:",
            Group = "Abilities",
            Header = "Buffs",
            Category = "Group",
            Index = 101,
            Tooltip =
            "Choose whether to use the Aegolism or Symbol Line of HP Buffs.\nPlease note using both is supported for party members who block buffs, but these buffs do not stack once we transition from using a HP Type-One buff in place of Aegolism.",
            Type = "Combo",
            ComboOptions = { 'Aegolism', 'Both (See Tooltip!)', 'Symbol', 'None', },
            Default = 1,
            Min = 1,
            Max = 4,
            RequiresLoadoutChange = true,
        },
        ['DoACBuff']          = {
            DisplayName = "Use AC Buff",
            Group = "Abilities",
            Header = "Buffs",
            Category = "Group",
            Index = 102,
            Tooltip =
                "Use your single-slot AC Buff on the Main Assist. USE CASES:\n" ..
                "You have Aegolism selected and are below level 40 (We are still using a HP Type One buff).\n" ..
                "You have Symbol selected and don't have someone else providing a Type One buff.\n" ..
                "Leaving this on in other cases is not likely to cause issue, but may cause unnecessary buff checking.",
            RequiresLoadoutChange = true,
            Default = false,
        },
        ['VieBuffMode']       = {
            DisplayName = "Use Vie Buff",
            Group = "Abilities",
            Header = "Buffs",
            Category = "Group",
            Index = 103,
            Tooltip = "Use your Melee Damage absorb (Vie) line.",
            Type = "Combo",
            ComboOptions = { 'None', 'Downtime Only', 'Downtime + Combat', },
            Default = 3,
            Min = 1,
            Max = 3,
            RequiresLoadoutChange = true,
        },
        ['DoDivineBuff']      = {
            DisplayName = "Do Divine Intervetion",
            Group = "Abilities",
            Header = "Buffs",
            Category = "Group",
            Index = 105,
            Tooltip = "Use your Divine Intervention line (death save) on the MA.",
            RequiresLoadoutChange = true,
            Default = true,
            ConfigType = "Advanced",
        },

        --Combat
        ['DoTimer6Stun']      = {
            DisplayName = "Timer 6 Stun",
            Group = "Abilities",
            Header = "Debuffs",
            Category = "Stun",
            Index = 101,
            Tooltip = "Use the Timer 6 Stun (\"Sound of\" Line).",
            RequiresLoadoutChange = true,
            Default = true,
        },
        ['DoTimer4Stun']      = {
            DisplayName = "Timer 4 Stun",
            Group = "Abilities",
            Header = "Debuffs",
            Category = "Stun",
            Index = 102,
            Tooltip = "Use the Timer 4 Stun (Shock of Wonder).",
            RequiresLoadoutChange = true,
            Default = true,
        },
        ['DoLLStun']          = {
            DisplayName = "Low Level Stun",
            Group = "Abilities",
            Header = "Debuffs",
            Category = "Stun",
            Index = 103,
            Tooltip = "Use the Level 2 \"Stun\" spell, as long as it is level-appropriate (works on targets up to Level 55).",
            RequiresLoadoutChange = true,
            Default = true,
            ConfigType = "Advanced",
            FAQ = "Why is a Cleric stunning? It should be healing!?",
            Answer =
            "At low levels, Cleric stuns are often more efficient than healing the damage an non-stunned mob would cause.",
        },
        ['DoUndeadNuke']      = {
            DisplayName = "Do Undead Nuke",
            Group = "Abilities",
            Header = "Damage",
            Category = "Direct",
            Index = 102,
            Tooltip = "Use the Undead nuke line.",
            RequiresLoadoutChange = true,
            Default = false,
        },
        ['DoMagicNuke']       = {
            DisplayName = "Do Magic Nuke",
            Group = "Abilities",
            Header = "Damage",
            Category = "Direct",
            Index = 103,
            Tooltip = "Use the Magic nuke line.",
            RequiresLoadoutChange = true,
            Default = false,
        },
        ['DoQuickNuke']       = {
            DisplayName = "Do Verdict Nuke",
            Group = "Abilities",
            Header = "Damage",
            Category = "Direct",
            Index = 104,
            Tooltip = "Use the Verdict Quicknuke line.",
            RequiresLoadoutChange = true,
            Default = true,
        },
        -- Heals and Cures
        ['DoCompleteHeal']    = {
            DisplayName = "Use Complete Heal",
            Group = "Abilities",
            Header = "Recovery",
            Category = "General Healing",
            Index = 104,
            Tooltip =
                "Memorize Complete Heal alongside Healing Light.\n" ..
                "WAR / PAL / SHD use Complete Heal when at/below Class Heal: Complete Heal %.\n" ..
                "Among qualifying heals, lower Class Heal %% is cast first (Fast / Regular / Complete / Group / HoT).",
            RequiresLoadoutChange = true,
            Default = false,
            ConfigType = "Advanced",
            FAQ = "Does RGMercs support Complete Heal Chains (CHC)?",
            Answer =
            "No, it does not. If this is important to you, there are resources on RedGuides that can handle it! You could, though, consider staggering Complete Heal percentages (Class Heal: Complete Heal) to break up CH usage amongst multiple clerics.",
        },
        ['DoSingleElixir']    = {
            DisplayName = "Single Elixir",
            Group = "Abilities",
            Header = "Recovery",
            Category = "General Healing",
            Index = 101,
            Tooltip = "Use your single-target Elixir Line.",
            RequiresLoadoutChange = true,
            Default = true,
            ConfigType = "Advanced",
        },
        ['DoGroupElixir']     = {
            DisplayName = "Group Elixir",
            Group = "Abilities",
            Header = "Recovery",
            Category = "General Healing",
            Index = 102,
            Tooltip = "Use your group-wide Elixir Line.",
            RequiresLoadoutChange = true,
            Default = false,
            ConfigType = "Advanced",
        },
        ['GroupElixirUptime'] = {
            DisplayName = "Group Elixir Uptime",
            Group = "Abilities",
            Header = "Recovery",
            Category = "General Healing",
            Index = 103,
            Tooltip = "In combat, attempt to keep full uptime on your Group Elixir. Note: There are scenarios where single elixirs could interfere with uptime.",
            Default = false,
            ConfigType = "Advanced",
        },
        ['KeepPoisonMemmed']  = {
            DisplayName = "Mem Cure Poison",
            Group = "Abilities",
            Header = "Recovery",
            Category = "Curing",
            Index = 101,
            Tooltip = "Memorize cure poison spell when possible (depending on other selected options). \n" ..
                "Please note that we will still memorize a cure out-of-combat if needed, and AA will always be used if available.",
            RequiresLoadoutChange = true,
            Default = false,
            ConfigType = "Advanced",
        },
        ['KeepDiseaseMemmed'] = {
            DisplayName = "Mem Cure Disease",
            Group = "Abilities",
            Header = "Recovery",
            Category = "Curing",
            Index = 102,
            Tooltip = "Memorize cure disease spell when possible (depending on other selected options). \n" ..
                "Please note that we will still memorize a cure out-of-combat if needed, and AA will always be used if available.",
            RequiresLoadoutChange = true,
            Default = false,
            ConfigType = "Advanced",
        },
        ['KeepCurseMemmed']   = {
            DisplayName = "Mem Remove Curse",
            Group = "Abilities",
            Header = "Recovery",
            Category = "Curing",
            Index = 103,
            Tooltip = "Memorize remove curse spell when possible (depending on other selected options). \n" ..
                "Please note that we will still memorize a cure out-of-combat if needed, and AA will always be used if available.",
            RequiresLoadoutChange = true,
            Default = false,
            ConfigType = "Advanced",
        },
        ['KeepCorruptMemmed'] = {
            DisplayName = "Mem Cure Corruption",
            Group = "Abilities",
            Header = "Recovery",
            Category = "Curing",
            Index = 104,
            Tooltip = "Memorize cure corruption spell when possible (depending on other selected options). \n" ..
                "Please note that we will still memorize a cure out-of-combat if needed, and AA will always be used if available.",
            RequiresLoadoutChange = true,
            Default = false,
            ConfigType = "Advanced",
        },
        ['GroupHealAsCure']   = {
            DisplayName = "Use Group Heal to Cure",
            Group = "Abilities",
            Header = "Recovery",
            Category = "Curing",
            Index = 104,
            Tooltip = "If Word of Replenishment or Vivification are available, use these to cure instead of individual cure spells. \n" ..
                "Please note that we will prioritize single target cures if you have selected to keep them memmed above (due to the counter disparity).",
            RequiresLoadoutChange = true,
            Default = true,
            ConfigType = "Advanced",
        },
        ['DoPBAENuke']        = {
            DisplayName = "Use PBAE Nuke",
            Group = "Abilities",
            Header = "Damage",
            Category = "AE",
            Index = 101,
            RequiresLoadoutChange = true,
            Tooltip =
            "**WILL BREAK MEZ** Use your Magic PB AE Spells . **WILL BREAK MEZ**",
            Default = false,
        },
        ['DoPBAEStun']        = {
            DisplayName = "Use PBAE Stun",
            Group = "Abilities",
            Header = "Damage",
            Category = "AE",
            Index = 102,
            RequiresLoadoutChange = true,
            Tooltip =
            "**WILL BREAK MEZ** Use your Magic PB AE Stun Spells . **WILL BREAK MEZ**",
            Default = false,
        },

        --Utility
        ['DoManaRestore']     = {
            DisplayName = "Use Mana Restore AAs",
            Group = "Abilities",
            Header = "Recovery",
            Category = "Other Recovery",
            Index = 101,
            Tooltip = "Use Veturika's Prescence (on self) or Quiet Miracle (on others) at critically low mana.",
            RequiresLoadoutChange = true, -- used as a load condition
            Default = true,
            ConfigType = "Advanced",
        },
        ['ManaRestorePct']    = {
            DisplayName = "Mana Restore Pct",
            Group = "Abilities",
            Header = "Recovery",
            Category = "Other Recovery",
            Index = 102,
            Tooltip = "Min Mana to use restore AA.",
            Default = 10,
            Min = 1,
            Max = 99,
            ConfigType = "Advanced",
        },
        ['DoYaulp']           = {
            DisplayName = "Use Yaulp",
            Group = "Abilities",
            Header = "Buffs",
            Category = "Self",
            Index = 101,
            Tooltip = "Use your Yaulp (AA or spell line) to help maintain your mana and buff your melee ability.",
            RequiresLoadoutChange = true,
            Default = true,
            FAQ = "Why am I using Yaulp? Clerics are not supposed to melee!",
            Answer = "The Yaulp spells we use also contain a mana regen component. You can disable this behavior on the Utility tab in the Class Options.",
        },
    },
}

for key, def in pairs(buildClassHealDefaults()) do
    _ClassConfig.DefaultConfig[key] = def
end

--- One-shot: copy legacy HealPct*_{CLASS} into HealPct*_{Tank|Melee|Caster} before ResolveDefaults
--- strips the old keys. Prefers the first listed source class that has a saved value.
---@param settings table
function _ClassConfig.MigrateSettings(settings)
    if type(settings) ~= "table" then return end

    local kinds = { "CompleteHeal", "FastHeal", "Light", "GroupHeal", "SingleHoT", "GroupHoT", }
    local anyLegacy = false
    for _, kind in ipairs(kinds) do
        for _, class in ipairs(HEAL_LEGACY_CLASS_LIST) do
            if settings[healPctSettingKey(kind, class)] ~= nil then
                anyLegacy = true
                break
            end
        end
        if anyLegacy then break end
    end
    if not anyLegacy then return end

    local function firstLegacy(kind, sources)
        for _, class in ipairs(sources) do
            local v = settings[healPctSettingKey(kind, class)]
            if v ~= nil then return v end
        end
        return nil
    end

    for _, kind in ipairs(kinds) do
        for role, sources in pairs(HEAL_LEGACY_ROLE_SOURCES) do
            if kind == "CompleteHeal" and role ~= "Tank" then
                -- no CompleteHeal role setting for Melee/Caster
            else
                local newKey = healPctSettingKey(kind, role)
                if settings[newKey] == nil then
                    local old = firstLegacy(kind, sources)
                    if old ~= nil then
                        settings[newKey] = old
                    end
                end
            end
        end
    end
end

return _ClassConfig
