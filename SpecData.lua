local ADDON_NAME, ns = ...

-- Specialisations, by the id this client's GetArenaOpponentSpec and
-- GetSpecializationInfo hand out.
--
-- The role table exists because a spec's role is a fact, while reading it back
-- out of a damage meter is a guess -- and every imported match has to be
-- guessed at, having recorded no spec at the time. Where a spec is known, this
-- answers instead.
ns.SPEC_ROLE = {
	-- Druid
	[105]="HEALER",  [103]="DAMAGER", [102]="DAMAGER", [104]="TANK",
	-- Paladin
	[65]="HEALER",   [66]="TANK",     [70]="DAMAGER",
	-- Shaman
	[264]="HEALER",  [262]="DAMAGER", [263]="DAMAGER",
	-- Death Knight
	[252]="DAMAGER", [251]="DAMAGER", [250]="TANK",
	-- Hunter
	[253]="DAMAGER", [254]="DAMAGER", [255]="DAMAGER",
	-- Mage
	[64]="DAMAGER",  [63]="DAMAGER",  [62]="DAMAGER",
	-- Rogue
	[261]="DAMAGER", [259]="DAMAGER", [260]="DAMAGER",
	-- Warlock
	[265]="DAMAGER", [267]="DAMAGER", [266]="DAMAGER",
	-- Warrior
	[73]="TANK",     [71]="DAMAGER",  [72]="DAMAGER",
	-- Priest
	[256]="HEALER",  [257]="HEALER",  [258]="DAMAGER",
	-- Monk
	[270]="HEALER",  [268]="TANK",    [269]="DAMAGER",
}

-- The same specs by slug, so a ladder row can be turned into an icon. The slug
-- is the class and spec Blizzard's character profile returns, lower cased with
-- spaces turned into dashes, and both halves are kept exactly as they come out:
-- death-knight, beast-mastery.
ns.SPEC_BY_SLUG = {
	["druid-balance"]         = 102,
	["druid-feral"]           = 103,
	["druid-guardian"]        = 104,
	["druid-restoration"]     = 105,

	["paladin-holy"]          = 65,
	["paladin-protection"]    = 66,
	["paladin-retribution"]   = 70,

	["shaman-elemental"]      = 262,
	["shaman-enhancement"]    = 263,
	["shaman-restoration"]    = 264,

	["death-knight-blood"]    = 250,
	["death-knight-frost"]    = 251,
	["death-knight-unholy"]   = 252,

	["hunter-beast-mastery"]  = 253,
	["hunter-marksmanship"]   = 254,
	["hunter-survival"]       = 255,

	["mage-arcane"]           = 62,
	["mage-fire"]             = 63,
	["mage-frost"]            = 64,

	["rogue-assassination"]   = 259,
	["rogue-combat"]          = 260,
	["rogue-subtlety"]        = 261,

	["warlock-affliction"]    = 265,
	["warlock-demonology"]    = 266,
	["warlock-destruction"]   = 267,

	["warrior-arms"]          = 71,
	["warrior-fury"]          = 72,
	["warrior-protection"]    = 73,

	["priest-discipline"]     = 256,
	["priest-holy"]           = 257,
	["priest-shadow"]         = 258,

	["monk-brewmaster"]       = 268,
	["monk-windwalker"]       = 269,
	["monk-mistweaver"]       = 270,
}

-- Icons this client returns wrongly for the spec in question. Taken from
-- ArenaAnalytics' own overrides for Mists, which exist for the same reason:
-- the API answers with art that belongs to a later version of the spec.
ns.SPEC_ICON = {
	[66]  = "Interface\\Icons\\spell_holy_devotionaura",        -- Protection Paladin
	[263] = "Interface\\Icons\\spell_shaman_improvedstormstrike", -- Enhancement Shaman
	[253] = "Interface\\Icons\\ability_hunter_bestialdiscipline", -- Beast Mastery
	[254] = "Interface\\Icons\\ability_hunter_focusedaim",       -- Marksmanship
	[255] = "Interface\\Icons\\ability_hunter_camouflage",       -- Survival
	[259] = "Interface\\Icons\\Ability_rogue_deadlybrew",        -- Assassination
	[71]  = "Interface\\Icons\\ability_warrior_savageblow",      -- Arms
	[256] = "Interface\\Icons\\spell_holy_powerwordshield",      -- Discipline
}
