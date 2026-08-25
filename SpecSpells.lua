local ADDON_NAME, ns = ...

-- Spells that give away a specialisation, so a spec can be read off the combat
-- log rather than asked for.
--
-- The two sources that came first both fail quietly. GetArenaOpponentSpec needs
-- the arena unit to exist; an inspect needs CanInspect to pass, allows one
-- outstanding request at a time, and simply never answers if the client feels
-- like it. A teammate whose inspect went missing kept a blank spec for the
-- whole match, which is what prompted this.
--
-- This needs none of that. A shaman who casts Stormstrike is Enhancement, from
-- across the map, whether or not anything can be inspected -- and it works the
-- same for both teams.
--
-- Chosen so that no entry belongs to two specs of the same class. Anything
-- shared is worse than useless: it would name a spec confidently and wrongly.
-- Where an id below turns out to be shared after all, the loader at the bottom
-- disarms it rather than letting the last one written win.
--
-- Ids are from Mists. The name beside each is not decoration: the combat log
-- reports both, and a name catches a spell whose id has moved since. Names only
-- help an English client, so the ids carry non-English ones on their own.

-- { spec = { { id, name }, ... } }
local SIGNATURES = {

	----------------------------------------------------------------
	-- Death Knight
	----------------------------------------------------------------

	[250] = { -- Blood
		{ 55050,  "Heart Strike" },
		{ 55233,  "Vampiric Blood" },
		{ 48982,  "Rune Tap" },
		{ 49028,  "Dancing Rune Weapon" },
	},
	[251] = { -- Frost
		{ 49143,  "Frost Strike" },
		{ 49184,  "Howling Blast" },
		{ 49020,  "Obliterate" },
		{ 51271,  "Pillar of Frost" },
	},
	[252] = { -- Unholy
		{ 55090,  "Scourge Strike" },
		{ 85948,  "Festering Strike" },
		{ 49206,  "Summon Gargoyle" },
		{ 63560,  "Dark Transformation" },
	},

	----------------------------------------------------------------
	-- Druid
	----------------------------------------------------------------

	[102] = { -- Balance
		{ 78674,  "Starsurge" },
		{ 48505,  "Starfall" },
		{ 24858,  "Moonkin Form" },
		{ 78675,  "Solar Beam" },
	},
	[103] = { -- Feral
		{ 1079,   "Rip" },
		{ 22568,  "Ferocious Bite" },
		{ 5217,   "Tiger's Fury" },
		{ 52610,  "Savage Roar" },
	},
	[104] = { -- Guardian
		{ 33917,  "Mangle" },
		{ 62606,  "Savage Defense" },
		{ 22842,  "Frenzied Regeneration" },
	},
	[105] = { -- Restoration
		{ 18562,  "Swiftmend" },
		{ 48438,  "Wild Growth" },
		{ 33763,  "Lifebloom" },
	},

	----------------------------------------------------------------
	-- Hunter
	----------------------------------------------------------------

	[253] = { -- Beast Mastery
		{ 19574,  "Bestial Wrath" },
		{ 34026,  "Kill Command" },
		{ 82692,  "Focus Fire" },
	},
	[254] = { -- Marksmanship
		{ 19434,  "Aimed Shot" },
		{ 53209,  "Chimera Shot" },
		{ 53220,  "Steady Focus" },
	},
	[255] = { -- Survival
		{ 53301,  "Explosive Shot" },
		{ 3674,   "Black Arrow" },
		{ 56453,  "Lock and Load" },
	},

	----------------------------------------------------------------
	-- Mage
	----------------------------------------------------------------

	[62] = { -- Arcane
		{ 30451,  "Arcane Blast" },
		{ 44425,  "Arcane Barrage" },
		{ 12042,  "Arcane Power" },
	},
	[63] = { -- Fire
		{ 11366,  "Pyroblast" },
		{ 11129,  "Combustion" },
		{ 108853, "Inferno Blast" },
	},
	[64] = { -- Frost
		{ 84714,  "Frozen Orb" },
		{ 12472,  "Icy Veins" },
		{ 44572,  "Deep Freeze" },
		{ 31687,  "Summon Water Elemental" },
	},

	----------------------------------------------------------------
	-- Monk
	----------------------------------------------------------------

	[268] = { -- Brewmaster
		{ 121253, "Keg Smash" },
		{ 115181, "Breath of Fire" },
		{ 115295, "Guard" },
		{ 115308, "Elusive Brew" },
	},
	[270] = { -- Mistweaver
		{ 115175, "Soothing Mist" },
		{ 115151, "Renewing Mist" },
		{ 124682, "Enveloping Mist" },
		{ 115310, "Revival" },
	},
	[269] = { -- Windwalker
		{ 113656, "Fists of Fury" },
		{ 137639, "Storm, Earth, and Fire" },
		{ 115288, "Energizing Brew" },
	},

	----------------------------------------------------------------
	-- Paladin
	----------------------------------------------------------------

	[65] = { -- Holy
		{ 20473,  "Holy Shock" },
		{ 53563,  "Beacon of Light" },
		{ 85222,  "Light of Dawn" },
		{ 82326,  "Holy Radiance" },
	},
	[66] = { -- Protection
		{ 31935,  "Avenger's Shield" },
		{ 53600,  "Shield of the Righteous" },
		{ 31850,  "Ardent Defender" },
	},
	[70] = { -- Retribution
		{ 85256,  "Templar's Verdict" },
		{ 53385,  "Divine Storm" },
		{ 84963,  "Inquisition" },
	},

	----------------------------------------------------------------
	-- Priest
	----------------------------------------------------------------

	[256] = { -- Discipline
		{ 47540,  "Penance" },
		{ 62618,  "Power Word: Barrier" },
		{ 33206,  "Pain Suppression" },
		{ 81700,  "Archangel" },
	},
	[257] = { -- Holy
		{ 34861,  "Circle of Healing" },
		{ 47788,  "Guardian Spirit" },
		{ 88684,  "Holy Word: Serenity" },
		{ 88625,  "Holy Word: Chastise" },
	},
	[258] = { -- Shadow
		{ 15407,  "Mind Flay" },
		{ 34914,  "Vampiric Touch" },
		{ 2944,   "Devouring Plague" },
		{ 15473,  "Shadowform" },
		{ 47585,  "Dispersion" },
	},

	----------------------------------------------------------------
	-- Rogue
	----------------------------------------------------------------

	[259] = { -- Assassination
		{ 1329,   "Mutilate" },
		{ 32645,  "Envenom" },
		{ 79140,  "Vendetta" },
		{ 111240, "Dispatch" },
	},
	[260] = { -- Combat
		{ 13877,  "Blade Flurry" },
		{ 51690,  "Killing Spree" },
		{ 13750,  "Adrenaline Rush" },
		{ 84617,  "Revealing Strike" },
	},
	[261] = { -- Subtlety
		{ 53,     "Backstab" },
		{ 16511,  "Hemorrhage" },
		{ 51713,  "Shadow Dance" },
		{ 14183,  "Premeditation" },
	},

	----------------------------------------------------------------
	-- Shaman
	----------------------------------------------------------------

	[262] = { -- Elemental
		{ 61882,  "Earthquake" },
		{ 51490,  "Thunderstorm" },
		-- Lava Burst is deliberately absent. It reads like the obvious
		-- Elemental spell and is not one: Restoration casts it too, rarely
		-- enough that testing would probably never have caught it. David did.
	},
	[263] = { -- Enhancement
		{ 17364,  "Stormstrike" },
		{ 60103,  "Lava Lash" },
		{ 51533,  "Feral Spirit" },
	},
	[264] = { -- Restoration
		{ 61295,  "Riptide" },
		{ 73920,  "Healing Rain" },
		{ 974,    "Earth Shield" },
		{ 98008,  "Spirit Link Totem" },
		{ 108280, "Healing Tide Totem" },
	},

	----------------------------------------------------------------
	-- Warlock
	----------------------------------------------------------------

	[265] = { -- Affliction
		{ 30108,  "Unstable Affliction" },
		{ 103103, "Malefic Grasp" },
		{ 48181,  "Haunt" },
		{ 86121,  "Soul Swap" },
	},
	[266] = { -- Demonology
		{ 103958, "Metamorphosis" },
		{ 105174, "Hand of Gul'dan" },
		{ 103964, "Touch of Chaos" },
	},
	[267] = { -- Destruction
		{ 116858, "Chaos Bolt" },
		{ 17962,  "Conflagrate" },
		{ 29722,  "Incinerate" },
		{ 348,    "Immolate" },
	},

	----------------------------------------------------------------
	-- Warrior
	----------------------------------------------------------------

	[71] = { -- Arms
		{ 12294,  "Mortal Strike" },
		{ 7384,   "Overpower" },
		{ 12328,  "Sweeping Strikes" },
	},
	[72] = { -- Fury
		{ 23881,  "Bloodthirst" },
		{ 85288,  "Raging Blow" },
		{ 100130, "Wild Strike" },
	},
	[73] = { -- Protection
		{ 23922,  "Shield Slam" },
		{ 6572,   "Revenge" },
		{ 20243,  "Devastate" },
		{ 112048, "Shield Barrier" },
	},
}

----------------------------------------------------------------
-- Lookups
----------------------------------------------------------------

ns.SPEC_SPELLS      = {}   -- [spellID]   = spec, or false where shared
ns.SPEC_SPELL_NAMES = {}   -- [spellName] = spec, or false where shared

-- Written once, and never overwritten by a different spec.
--
-- Two specs laying claim to the same spell means the table is wrong about one
-- of them, and there is no telling which. Answering "false" is how it says so:
-- the lookup treats that as no answer, and the spell stops naming anybody
-- rather than naming half of them incorrectly.
local function Claim(map,key,spec)
	if key==nil or key=="" then return end

	local held=map[key]
	if held==nil then
		map[key]=spec
	elseif held~=spec then
		map[key]=false
	end
end

for spec,spells in pairs(SIGNATURES) do
	for _,entry in ipairs(spells) do
		Claim(ns.SPEC_SPELLS,entry[1],spec)
		Claim(ns.SPEC_SPELL_NAMES,entry[2],spec)
	end
end
