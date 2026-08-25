local ADDON_NAME, ns = ...

-- Hard crowd control: the things that take a player out of the match for their
-- duration. Stuns, incapacitates, fears, disorients, horrors, mind control --
-- and silences, which are counted here at David's request. A silence leaves
-- the player walking about, so it is the softest thing on this list, but it
-- ends a healer's game just as surely while it runs.
--
-- Roots, snares, disarms, taunts and knockbacks are deliberately NOT here. A
-- root is answered differently from a stun and a Hamstring is pressed
-- constantly; counting either would drown the number that matters.
--
-- Taken from DRList-1.0's Mists list, which is what the diminishing-returns
-- trackers run on. These are the ids that appear on the *debuff*, which is
-- what the combat log reports -- a spell's cast id is often a different number
-- and never shows up as an aura at all, so a table built from cast ids counts
-- nothing.
ns.HARD_CC = {
	-- Stuns
	[408    ] = true,  -- Kidney Shot
	[853    ] = true,  -- Hammer of Justice
	[1833   ] = true,  -- Cheap Shot
	[5211   ] = true,  -- Mighty Bash
	[9005   ] = true,  -- Pounce
	[20549  ] = true,  -- War Stomp (Racial)
	[22570  ] = true,  -- Maim
	[22703  ] = true,  -- Inferno Effect
	[24394  ] = true,  -- Intimidation
	[30283  ] = true,  -- Shadowfury
	[44572  ] = true,  -- Deep Freeze
	[50519  ] = true,  -- Sonic Blast
	[56626  ] = true,  -- Sting (Wasp)
	[89766  ] = true,  -- Axe Toss (Felguard)
	[90337  ] = true,  -- Bad Manner (Monkey)
	[91797  ] = true,  -- Monstrous Blow (Dark Transformation Ghoul)
	[91800  ] = true,  -- Gnaw (Ghoul)
	[102795 ] = true,  -- Bear Hug
	[105593 ] = true,  -- Fist of Justice
	[107570 ] = true,  -- Storm Bolt
	[108194 ] = true,  -- Asphyxiate
	[110698 ] = true,  -- Hammer of Justice (Symbiosis)
	[113801 ] = true,  -- Bash (Treants)
	[115001 ] = true,  -- Remorseless Winter
	[115752 ] = true,  -- Blinding Light (Glyphed)
	[117526 ] = true,  -- Binding Shot
	[118271 ] = true,  -- Combustion
	[118345 ] = true,  -- Pulverize (Primal Earth Elemental)
	[118905 ] = true,  -- Static Charge (Capacitor Totem)
	[119072 ] = true,  -- Holy Wrath
	[119381 ] = true,  -- Leg Sweep
	[119392 ] = true,  -- Charging Ox Wave
	[120086 ] = true,  -- Fists of Fury
	[122242 ] = true,  -- Clash
	[126246 ] = true,  -- Lullaby (Crane pet)
	[126355 ] = true,  -- Quill (Porcupine pet)
	[126423 ] = true,  -- Petrifying Gaze (Basilisk pet)
	[132168 ] = true,  -- Shockwave

	-- Stuns that land on their own
	[100    ] = true,  -- Charge
	[77505  ] = true,  -- Earthquake
	[113953 ] = true,  -- Paralysis
	[118000 ] = true,  -- Dragon Roar
	[118895 ] = true,  -- Dragon Roar

	-- Incapacitates
	[118    ] = true,  -- Polymorph
	[710    ] = true,  -- Banish
	[1776   ] = true,  -- Gouge
	[2637   ] = true,  -- Hibernate
	[3355   ] = true,  -- Freezing Trap Effect
	[6770   ] = true,  -- Sap
	[9484   ] = true,  -- Shackle Undead
	[19386  ] = true,  -- Wyvern Sting
	[20066  ] = true,  -- Repentance
	[28271  ] = true,  -- Polymorph: Turtle
	[28272  ] = true,  -- Polymorph: Pig
	[51514  ] = true,  -- Hex
	[61025  ] = true,  -- Polymorph: Serpent
	[61305  ] = true,  -- Polymorph: Black Cat
	[61721  ] = true,  -- Polymorph: Rabbit
	[61780  ] = true,  -- Polymorph: Turkey
	[76780  ] = true,  -- Bind Elemental
	[82691  ] = true,  -- Ring of Frost
	[107079 ] = true,  -- Quaking Palm (Racial)
	[115078 ] = true,  -- Paralysis

	-- Disorients
	[99     ] = true,  -- Disorienting Roar
	[19503  ] = true,  -- Scatter Shot
	[31661  ] = true,  -- Dragon's Breath
	[88625  ] = true,  -- Holy Word: Chastise
	[123394 ] = true,  -- Breath of Fire (TODO: verify id)

	-- Fears
	[1513   ] = true,  -- Scare Beast
	[2094   ] = true,  -- Blind
	[5246   ] = true,  -- Intimidating Shout
	[5484   ] = true,  -- Howl of Terror
	[5782   ] = true,  -- Fear
	[6358   ] = true,  -- Seduction (Succubus)
	[8122   ] = true,  -- Psychic Scream
	[10326  ] = true,  -- Turn Evil
	[20511  ] = true,  -- Intimidating Shout (secondary targets)
	[104045 ] = true,  -- Sleep (Metamorphosis)
	[113004 ] = true,  -- Intimidating Roar (Symbiosis)
	[113056 ] = true,  -- Intimidating Roar (Symbiosis)
	[113792 ] = true,  -- Psychic Terror (Psyfiend)
	[115268 ] = true,  -- Mesmerize (Shivarra)
	[118699 ] = true,  -- Fear 2
	[145067 ] = true,  -- Turn Evil (Evil is a Point of View)

	-- Horrors -- like a stun, and not stopped by a stun break
	[6789   ] = true,  -- Death Coil
	[64044  ] = true,  -- Psychic Horror
	[137143 ] = true,  -- Blood Horror

	-- Cyclone
	[33786  ] = true,  -- Cyclone
	[113506 ] = true,  -- Cyclone (Symbiosis)

	-- Taken over entirely
	[605    ] = true,  -- Dominate Mind
	[13181  ] = true,  -- Gnomish Mind Control Cap (Item)
	[67799  ] = true,  -- Mind Amplification Dish (Item)

	-- Silences -- no casting at all, though the player can still move
	[1330   ] = true,  -- Garrote - Silence
	[15487  ] = true,  -- Silence
	[18498  ] = true,  -- Silenced - Gag Order
	[24259  ] = true,  -- Spell Lock
	[25046  ] = true,  -- Arcane Torrent (Racial, Energy)
	[28730  ] = true,  -- Arcane Torrent (Racial, Mana)
	[31935  ] = true,  -- Avenger's Shield
	[34490  ] = true,  -- Silencing Shot
	[47476  ] = true,  -- Strangulate
	[50613  ] = true,  -- Arcane Torrent (Racial, Runic Power)
	[55021  ] = true,  -- Counterspell
	[69179  ] = true,  -- Arcane Torrent (Rage version)
	[80483  ] = true,  -- Arcane Torrent (Focus version)
	[102051 ] = true,  -- Frostjaw
	[108194 ] = true,  -- Asphyxiate (TODO: check silence id)
	[114237 ] = true,  -- Glyph of Fae Silence (TODO: verify id)
	[115782 ] = true,  -- Optical Blast (Observer)
	[116709 ] = true,  -- Spear Hand Strike
	[137460 ] = true,  -- Ring of Peace (Silence effect)

}

-- Soft crowd control: roots and disarms.
--
-- Kept apart from the hard list and scored lower. A root stops you walking, not
-- playing: you can still cast, still trinket, still heal through it. Counting
-- it beside a fear would drown the number that matters, which is why it was
-- left out to begin with -- but it is work, so it is worth something.
--
-- Snares are still out. A Hamstring is pressed constantly and would swamp both
-- lists; DRList does not track them either, since they do not diminish.
ns.SOFT_CC = {
	-- Roots
	[122    ] = true,  -- Frost Nova
	[339    ] = true,  -- Entangling Roots
	[4167   ] = true,  -- Web (Spider)
	[19975  ] = true,  -- Nature's Grasp
	[33395  ] = true,  -- Freeze (Water Elemental)
	[50245  ] = true,  -- Pin (Crab)
	[53148  ] = true,  -- Charge (Tenacity pet)
	[54706  ] = true,  -- Venom Web Spray (Silithid)
	[63685  ] = true,  -- Freeze (Frost Shock)
	[90327  ] = true,  -- Lock Jaw (Dog)
	[96294  ] = true,  -- Chains of Ice (Chilblains Root)
	[102359 ] = true,  -- Mass Entanglement
	[107566 ] = true,  -- Staggering Shout
	[110693 ] = true,  -- Frost Nova (Symbiosis)
	[113275 ] = true,  -- Entangling Roots (Symbiosis)
	[114404 ] = true,  -- Void Tendrils
	[115197 ] = true,  -- Partial Paralysis
	[116706 ] = true,  -- Disable
	[128405 ] = true,  -- Narrow Escape

	-- Roots that land on their own
	[64695  ] = true,  -- Earthgrab Totem
	[64803  ] = true,  -- Entrapment
	[111340 ] = true,  -- Ice Ward
	[123407 ] = true,  -- Spinning Fire Blossom

	-- Disarms
	[676    ] = true,  -- Disarm
	[50541  ] = true,  -- Clench (Scorpid)
	[51722  ] = true,  -- Dismantle
	[64058  ] = true,  -- Psychic Horror (Disarm Effect)
	[91644  ] = true,  -- Snatch (Bird of Prey)
	[117368 ] = true,  -- Grapple Weapon
	[118093 ] = true,  -- Disarm (Voidwalker/Voidlord)
	[126458 ] = true,  -- Grapple Weapon (Symbiosis)
	[137461 ] = true,  -- Ring of Peace (Disarm effect)

}

-- The same crowd control ships under many ids -- every Polymorph variant, the
-- Symbiosis copies, each hunter pet's own version -- and no list of ids is ever
-- complete. So the names of everything above are resolved once and matched too,
-- which catches the ids nobody listed. Details does the same, for the same
-- reason.
--
-- Names are only consulted for spells landing on players already in the match,
-- so a mob casting something similarly named cannot get in.
ns.HARD_CC_NAMES = nil

function ns.BuildHardCCNames()
	if ns.HARD_CC_NAMES then return end

	local names={}
	for spellID in pairs(ns.HARD_CC) do
		local name
		if C_Spell and C_Spell.GetSpellInfo then
			local info=C_Spell.GetSpellInfo(spellID)
			name=info and info.name
		end
		if not name and GetSpellInfo then name=GetSpellInfo(spellID) end
		if name then names[name]=true end
	end

	ns.HARD_CC_NAMES=names

	local soft={}
	for spellID in pairs(ns.SOFT_CC) do
		local name
		if C_Spell and C_Spell.GetSpellInfo then
			local info=C_Spell.GetSpellInfo(spellID)
			name=info and info.name
		end
		if not name and GetSpellInfo then name=GetSpellInfo(spellID) end
		-- A spell in both lists belongs to the hard one.
		if name and not names[name] then soft[name]=true end
	end

	ns.SOFT_CC_NAMES=soft
end

-- A stun that outlasts this was almost certainly never seen to end -- the
-- player left, or the removal was missed -- so it stops counting there.
ns.HARD_CC_MAX_SECONDS = 12
