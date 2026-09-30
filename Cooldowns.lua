local ADDON_NAME, ns = ...

-- The cooldowns worth seeing again in a replay: the ones that win a go (burst)
-- and the ones that survive it (a wall, an immunity, a save cast on somebody
-- else). ReplayPlus reads this file out of the game's copy of the addon, as
-- it reads HardCC.lua and SpecSpells.lua, and marks every cast of one on the
-- recording's timeline -- so the list is shipped and updated with the addon,
-- and a replay and the game agree on what counts.
--
-- It is data only. The addon does not load it (it is not in the .toc), so it
-- costs nothing in the game.
--
-- What is NOT here, on purpose:
--   * the PvP trinket, Every Man for Himself and Will of the Forsaken --
--     ReplayPlus marks those as trinkets of their own, with the crowd control
--     they broke;
--   * crowd control and interrupts (HardCC.lua has the crowd control);
--   * heals, dispels and anything pressed on cooldown every few seconds: a
--     Mortal Strike or a Riptide on the timeline is noise, and the dispels are
--     read off the log as dispels, whatever cast them;
--   * procs and passives (Cauterize, Cheat Death): they are never cast, so the
--     log has no cast of them to mark;
--   * pets summoned before the gates open (Water Elemental, Raise Dead).
--
-- Taken from TrackerPlus's catalogue (SpellData.lua), whose ids and categories
-- were checked against Wowhead's Mists Classic tooltips on 2026-09-26, and
-- narrowed to the cooldowns of about half a minute and more. The ids are the
-- cast's, which is what SPELL_CAST_SUCCESS reports. The category is the one
-- TrackerPlus gives, except the Retribution Guardian of Ancient Kings, which is
-- burst and is filed as OFFENSIVE here. The healthstone is the one addition
-- TrackerPlus does not track: an item, but the log reports its use as a cast.
--
-- One line per spell, "[id] = "CATEGORY", -- Name": ReplayPlus reads the
-- tables line by line, so an entry keeps to one line with its name after it.

ns.COOLDOWNS = {
	-- Racials, and a healthstone
	[20594  ] = "DEFENSIVE",  -- Stoneform
	[58984  ] = "DEFENSIVE",  -- Shadowmeld
	[59544  ] = "DEFENSIVE",  -- Gift of the Naaru
	[6262   ] = "DEFENSIVE",  -- Healthstone
	[26297  ] = "OFFENSIVE",  -- Berserking
	[20572  ] = "OFFENSIVE",  -- Blood Fury
	[33697  ] = "OFFENSIVE",  -- Blood Fury
	[33702  ] = "OFFENSIVE",  -- Blood Fury

	-- Death Knight
	[48707  ] = "DEFENSIVE",  -- Anti-Magic Shell
	[51052  ] = "DEFENSIVE",  -- Anti-Magic Zone
	[48792  ] = "DEFENSIVE",  -- Icebound Fortitude
	[49039  ] = "DEFENSIVE",  -- Lichborne
	[48743  ] = "DEFENSIVE",  -- Death Pact
	[55233  ] = "DEFENSIVE",  -- Vampiric Blood
	[108201 ] = "DEFENSIVE",  -- Desecrated Ground
	[49028  ] = "OFFENSIVE",  -- Dancing Rune Weapon
	[51271  ] = "OFFENSIVE",  -- Pillar of Frost
	[49016  ] = "OFFENSIVE",  -- Unholy Frenzy
	[49206  ] = "OFFENSIVE",  -- Summon Gargoyle
	[47568  ] = "OFFENSIVE",  -- Empower Rune Weapon
	[77606  ] = "OFFENSIVE",  -- Dark Simulacrum

	-- Druid
	[22812  ] = "DEFENSIVE",  -- Barkskin
	[61336  ] = "DEFENSIVE",  -- Survival Instincts
	[106922 ] = "DEFENSIVE",  -- Might of Ursoc
	[108238 ] = "DEFENSIVE",  -- Renewal
	[102342 ] = "DEFENSIVE",  -- Ironbark
	[132158 ] = "DEFENSIVE",  -- Nature's Swiftness
	[740    ] = "DEFENSIVE",  -- Tranquility
	[106731 ] = "OFFENSIVE",  -- Incarnation
	[112071 ] = "OFFENSIVE",  -- Celestial Alignment
	[106952 ] = "OFFENSIVE",  -- Berserk
	[50334  ] = "OFFENSIVE",  -- Berserk (Bear Form)
	[48505  ] = "OFFENSIVE",  -- Starfall
	[108288 ] = "OFFENSIVE",  -- Heart of the Wild
	[124974 ] = "OFFENSIVE",  -- Nature's Vigil

	-- Hunter
	[19263  ] = "DEFENSIVE",  -- Deterrence
	[109304 ] = "DEFENSIVE",  -- Exhilaration
	[53480  ] = "DEFENSIVE",  -- Roar of Sacrifice
	[3045   ] = "OFFENSIVE",  -- Rapid Fire
	[19574  ] = "OFFENSIVE",  -- Bestial Wrath
	[121818 ] = "OFFENSIVE",  -- Stampede
	[131894 ] = "OFFENSIVE",  -- A Murder of Crows
	[120697 ] = "OFFENSIVE",  -- Lynx Rush

	-- Mage
	[45438  ] = "DEFENSIVE",  -- Ice Block
	[110959 ] = "DEFENSIVE",  -- Greater Invisibility
	[66     ] = "DEFENSIVE",  -- Invisibility
	[108978 ] = "DEFENSIVE",  -- Alter Time
	[11958  ] = "DEFENSIVE",  -- Cold Snap
	[12472  ] = "OFFENSIVE",  -- Icy Veins
	[12042  ] = "OFFENSIVE",  -- Arcane Power
	[11129  ] = "OFFENSIVE",  -- Combustion
	[12043  ] = "OFFENSIVE",  -- Presence of Mind
	[55342  ] = "OFFENSIVE",  -- Mirror Image
	[84714  ] = "OFFENSIVE",  -- Frozen Orb
	[80353  ] = "OFFENSIVE",  -- Time Warp

	-- Monk
	[115203 ] = "DEFENSIVE",  -- Fortifying Brew
	[115176 ] = "DEFENSIVE",  -- Zen Meditation
	[122278 ] = "DEFENSIVE",  -- Dampen Harm
	[122783 ] = "DEFENSIVE",  -- Diffuse Magic
	[122470 ] = "DEFENSIVE",  -- Touch of Karma
	[137562 ] = "DEFENSIVE",  -- Nimble Brew
	[115213 ] = "DEFENSIVE",  -- Avert Harm
	[116849 ] = "DEFENSIVE",  -- Life Cocoon
	[115310 ] = "DEFENSIVE",  -- Revival
	[115080 ] = "OFFENSIVE",  -- Touch of Death
	[123904 ] = "OFFENSIVE",  -- Invoke Xuen, the White Tiger

	-- Paladin
	[642    ] = "DEFENSIVE",  -- Divine Shield
	[498    ] = "DEFENSIVE",  -- Divine Protection
	[1022   ] = "DEFENSIVE",  -- Hand of Protection
	[6940   ] = "DEFENSIVE",  -- Hand of Sacrifice
	[633    ] = "DEFENSIVE",  -- Lay on Hands
	[31850  ] = "DEFENSIVE",  -- Ardent Defender
	[86659  ] = "DEFENSIVE",  -- Guardian of Ancient Kings
	[86669  ] = "DEFENSIVE",  -- Guardian of Ancient Kings (Holy)
	[31821  ] = "DEFENSIVE",  -- Devotion Aura
	[86698  ] = "OFFENSIVE",  -- Guardian of Ancient Kings (Retribution)
	[31884  ] = "OFFENSIVE",  -- Avenging Wrath
	[105809 ] = "OFFENSIVE",  -- Holy Avenger
	[114157 ] = "OFFENSIVE",  -- Execution Sentence
	[31842  ] = "OFFENSIVE",  -- Divine Favor

	-- Priest
	[47585  ] = "DEFENSIVE",  -- Dispersion
	[33206  ] = "DEFENSIVE",  -- Pain Suppression
	[62618  ] = "DEFENSIVE",  -- Power Word: Barrier
	[47788  ] = "DEFENSIVE",  -- Guardian Spirit
	[109964 ] = "DEFENSIVE",  -- Spirit Shell
	[112833 ] = "DEFENSIVE",  -- Spectral Guise
	[19236  ] = "DEFENSIVE",  -- Desperate Prayer
	[108968 ] = "DEFENSIVE",  -- Void Shift
	[6346   ] = "DEFENSIVE",  -- Fear Ward
	[64843  ] = "DEFENSIVE",  -- Divine Hymn
	[10060  ] = "OFFENSIVE",  -- Power Infusion
	[34433  ] = "OFFENSIVE",  -- Shadowfiend
	[123040 ] = "OFFENSIVE",  -- Mindbender

	-- Rogue
	[31224  ] = "DEFENSIVE",  -- Cloak of Shadows
	[5277   ] = "DEFENSIVE",  -- Evasion
	[74001  ] = "DEFENSIVE",  -- Combat Readiness
	[1856   ] = "DEFENSIVE",  -- Vanish
	[14185  ] = "DEFENSIVE",  -- Preparation
	[121471 ] = "OFFENSIVE",  -- Shadow Blades
	[13750  ] = "OFFENSIVE",  -- Adrenaline Rush
	[51690  ] = "OFFENSIVE",  -- Killing Spree
	[51713  ] = "OFFENSIVE",  -- Shadow Dance
	[79140  ] = "OFFENSIVE",  -- Vendetta

	-- Shaman
	[8143   ] = "DEFENSIVE",  -- Tremor Totem
	[108271 ] = "DEFENSIVE",  -- Astral Shift
	[30823  ] = "DEFENSIVE",  -- Shamanistic Rage
	[108270 ] = "DEFENSIVE",  -- Stone Bulwark Totem
	[98008  ] = "DEFENSIVE",  -- Spirit Link Totem
	[108280 ] = "DEFENSIVE",  -- Healing Tide Totem
	[108281 ] = "DEFENSIVE",  -- Ancestral Guidance
	[16188  ] = "DEFENSIVE",  -- Ancestral Swiftness
	[108285 ] = "DEFENSIVE",  -- Call of the Elements
	[114049 ] = "OFFENSIVE",  -- Ascendance
	[2825   ] = "OFFENSIVE",  -- Bloodlust
	[32182  ] = "OFFENSIVE",  -- Heroism
	[16166  ] = "OFFENSIVE",  -- Elemental Mastery
	[51533  ] = "OFFENSIVE",  -- Feral Spirit
	[2894   ] = "OFFENSIVE",  -- Fire Elemental Totem
	[120668 ] = "OFFENSIVE",  -- Stormlash Totem

	-- Warlock
	[104773 ] = "DEFENSIVE",  -- Unending Resolve
	[110913 ] = "DEFENSIVE",  -- Dark Bargain
	[108359 ] = "DEFENSIVE",  -- Dark Regeneration
	[108416 ] = "DEFENSIVE",  -- Sacrificial Pact
	[108482 ] = "DEFENSIVE",  -- Unbound Will
	[17767  ] = "DEFENSIVE",  -- Shadow Bulwark
	[113858 ] = "OFFENSIVE",  -- Dark Soul: Instability
	[113860 ] = "OFFENSIVE",  -- Dark Soul: Misery
	[113861 ] = "OFFENSIVE",  -- Dark Soul: Knowledge
	[108501 ] = "OFFENSIVE",  -- Grimoire of Service
	[18540  ] = "OFFENSIVE",  -- Summon Doomguard
	[1122   ] = "OFFENSIVE",  -- Summon Infernal

	-- Warrior
	[871    ] = "DEFENSIVE",  -- Shield Wall
	[114028 ] = "DEFENSIVE",  -- Mass Spell Reflection
	[23920  ] = "DEFENSIVE",  -- Spell Reflection
	[118038 ] = "DEFENSIVE",  -- Die by the Sword
	[97462  ] = "DEFENSIVE",  -- Rallying Cry
	[12975  ] = "DEFENSIVE",  -- Last Stand
	[55694  ] = "DEFENSIVE",  -- Enraged Regeneration
	[114030 ] = "DEFENSIVE",  -- Vigilance
	[1160   ] = "DEFENSIVE",  -- Demoralizing Shout
	[18499  ] = "DEFENSIVE",  -- Berserker Rage
	[1719   ] = "OFFENSIVE",  -- Recklessness
	[107574 ] = "OFFENSIVE",  -- Avatar
	[12292  ] = "OFFENSIVE",  -- Bloodbath
	[114207 ] = "OFFENSIVE",  -- Skull Banner
	[46924  ] = "OFFENSIVE",  -- Bladestorm
	[64382  ] = "OFFENSIVE",  -- Shattering Throw
}

-- The Anniversary client's own: TBC cooldowns Mists took away or renamed. On
-- that client ReplayPlus matches the lists by name as well as id, as it does
-- the crowd control -- every rank of a TBC spell is an id of its own -- so a
-- spell both games call the same is already found through the list above.
ns.COOLDOWNS_TBC = {
	[23989  ] = "DEFENSIVE",  -- Readiness
	[10278  ] = "DEFENSIVE",  -- Blessing of Protection
	[17116  ] = "DEFENSIVE",  -- Nature's Swiftness
	[12328  ] = "OFFENSIVE",  -- Sweeping Strikes
	[13877  ] = "OFFENSIVE",  -- Blade Flurry
	[14177  ] = "OFFENSIVE",  -- Cold Blood
	[20216  ] = "OFFENSIVE",  -- Divine Favor
	[12292  ] = "OFFENSIVE",  -- Death Wish
}

-- Mists ids, and their names, that are no cooldown on the Anniversary client:
-- Demoralizing Shout is a debuff warriors keep up there, not a wall, and
-- Devotion Aura a paladin's everyday armour aura, not Mists' raid cooldown.
ns.COOLDOWNS_NOT_TBC = {
	[1160   ] = true,  -- Demoralizing Shout
	[31821  ] = true,  -- Devotion Aura
}
