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

-- TBC names a talent tree where Mists names a spec.
--
-- The Anniversary data calls the druid's cat tree "Feral Combat"; Mists split
-- that tree into Feral and Guardian and calls the first one "feral". Every
-- other class lines up between the two games, so this is a single alias rather
-- than a second table per game.
--
-- An alias rather than another key in SPEC_BY_SLUG, because that table is
-- reversed into SLUG_BY_SPEC: two slugs sharing id 103 would make the reverse
-- depend on pairs() order and could rewrite a Mists druid as "feral-combat".
ns.SPEC_SLUG_ALIAS = {
	["druid-feral-combat"] = "druid-feral",
}

-- The one way to turn a class-spec slug into a spec id.
--
-- Every caller used to index SPEC_BY_SLUG directly, which meant a slug the
-- other game spells differently missed in four separate places.
function ns.SpecIdForSlug(slug)
	if not slug then return nil end

	local id=ns.SPEC_BY_SLUG and ns.SPEC_BY_SLUG[slug]
	if id then return id end

	local alias=ns.SPEC_SLUG_ALIAS[slug]
	return alias and ns.SPEC_BY_SLUG and ns.SPEC_BY_SLUG[alias] or nil
end

-- Classes a game never had.
--
-- Death knights arrived in Wrath and monks in Mists, so neither exists on the
-- Anniversary realms. Their specs are still in SPEC_BY_SLUG -- that table
-- describes Mists, and the ladder for Mists needs them -- so the filtering is
-- done where a list is built for a player to look at.
ns.CLASS_ABSENT = {
	tbc = { ["death-knight"] = true, ["monk"] = true },
}

-- Whether a class-spec slug is playable in the given game.
function ns.SpecExists(slug,version)
	if not slug then return false end
	version = version or (ns.ClientVersion and ns.ClientVersion()) or "mop"

	local absent = ns.CLASS_ABSENT[version]
	if not absent then return true end

	for class in pairs(absent) do
		if slug:sub(1,#class+1) == class.."-" then return false end
	end
	return true
end

-- The one place an icon is chosen for a spec id.
--
-- Our own art, on every client. Three chains used to answer this -- the API,
-- the ladder's own SpecIcon, and the auction panel -- each with its own set of
-- hand-written overrides for art Mists reports wrongly and a fallback on a
-- Mists API the Anniversary client does not have. The shipped set below
-- covers every spec, so the overrides and the fallback are gone with the
-- chains: one look on Mists and Anniversary alike, and nothing that can come
-- back a green square.
function ns.SpecIconForID(id)
	local art = id and ns.SPEC_ART and ns.SPEC_ART[id]
	if art then return "Interface\\AddOns\\ArenaPlus\\Media\\spec\\"..art end
	return nil
end

-- The spec art this addon ships, by spec id.
--
-- Shipped because the client cannot be relied on for it. The Anniversary
-- client has no death knight or monk icons at all -- those classes do not
-- exist there -- and none of the Cataclysm or Mists art Blizzard later gave
-- Enhancement, Assassination and the hunter specs. Asked for any of them it
-- draws a green square, which is what a missing texture looks like.
--
-- 32x32: the largest place any of these is drawn is the inspect panel at 24.
ns.SPEC_ART = {
	[250] = "death-knight-blood",
	[251] = "death-knight-frost",
	[252] = "death-knight-unholy",
	[102] = "druid-balance",
	[103] = "druid-feral",
	[104] = "druid-guardian",
	[105] = "druid-restoration",
	[253] = "hunter-beast-mastery",
	[254] = "hunter-marksmanship",
	[255] = "hunter-survival",
	[62] = "mage-arcane",
	[63] = "mage-fire",
	[64] = "mage-frost",
	[268] = "monk-brewmaster",
	[270] = "monk-mistweaver",
	[269] = "monk-windwalker",
	[65] = "paladin-holy",
	[66] = "paladin-protection",
	[70] = "paladin-retribution",
	[256] = "priest-discipline",
	[257] = "priest-holy",
	[258] = "priest-shadow",
	[259] = "rogue-assassination",
	[260] = "rogue-combat",
	[261] = "rogue-subtlety",
	[262] = "shaman-elemental",
	[263] = "shaman-enhancement",
	[264] = "shaman-restoration",
	[265] = "warlock-affliction",
	[266] = "warlock-demonology",
	[267] = "warlock-destruction",
	[71] = "warrior-arms",
	[72] = "warrior-fury",
	[73] = "warrior-protection",
}

