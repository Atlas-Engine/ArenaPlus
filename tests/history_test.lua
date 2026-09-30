-- What the match history counts off the combat log -- trinkets, dispels both
-- ways, interrupts both ways, crowd control broken by its own side -- run
-- through the module's real handler (history_harness.lua). From the addon
-- folder, once per client:
--
--     lua5.1 tests/history_test.lua . mop
--     lua5.1 tests/history_test.lua . tbc
local ROOT, CLIENT = arg[1] or ".", arg[2] or "mop"
local h = dofile((arg[0]:gsub("history_test.lua$", "")) .. "history_harness.lua")
local log, advance = h.log, h.advance
local fails, passes = 0, 0
local function check(ok, what) if ok then passes = passes + 1 else fails = fails + 1; print("FAIL  " .. what) end end

-- Trinkets: Mists' id, and on Anniversary a name.
log("SPELL_CAST_SUCCESS", "P-ME", nil, 42292, "PvP Trinket")
log("SPELL_CAST_SUCCESS", "E-MAGE", nil, 99999, "PvP Trinket")
-- A party dispel, a purge, a steal, and the felhunter's purge for its warlock.
log("SPELL_DISPEL", "P-ME", "P-MATE", 527, "Purify", 118, "Polymorph", "DEBUFF")
log("SPELL_DISPEL", "P-ME", "E-MAGE", 528, "Dispel Magic", 11426, "Ice Barrier", "BUFF")
log("SPELL_STOLEN", "E-MAGE", "P-MATE", 30449, "Spellsteal", 1044, "Hand of Freedom", "BUFF")
log("SPELL_DISPEL", "PET-FEL", "P-ME", 19505, "Devour Magic", 17, "Power Word: Shield", "BUFF")
-- Interrupts: the rogue kicks the mage; the felhunter locks me.
log("SPELL_INTERRUPT", "P-MATE", "E-MAGE", 1766, "Kick", 116, "Frostbolt")
log("SPELL_INTERRUPT", "PET-FEL", "P-ME", 19647, "Spell Lock", 2060, "Greater Heal")
-- Breaks: Frosty sheeps my rogue and Locky breaks it; Frosty sheeps me and
-- breaks it himself; Locky's Fear on me is broken by Frosty.
log("SPELL_AURA_APPLIED", "E-MAGE", "P-MATE", 118, "Polymorph", nil, nil, "DEBUFF")
advance(2)
log("SPELL_AURA_BROKEN_SPELL", "E-LOCK", "P-MATE", 118, "Polymorph", 172, "Corruption", "DEBUFF")
log("SPELL_AURA_APPLIED", "E-MAGE", "P-ME", 118, "Polymorph", nil, nil, "DEBUFF")
advance(1)
log("SPELL_AURA_BROKEN_SPELL", "E-MAGE", "P-ME", 118, "Polymorph", 2136, "Fire Blast", "DEBUFF")
log("SPELL_AURA_APPLIED", "E-LOCK", "P-ME", 5782, "Fear", nil, nil, "DEBUFF")
advance(1)
log("SPELL_AURA_BROKEN", "E-MAGE", "P-ME", 5782, "Fear", nil, nil, "DEBUFF")
-- A Kidney Shot ended the ordinary way: no break.
log("SPELL_AURA_APPLIED", "P-MATE", "E-MAGE", 408, "Kidney Shot", nil, nil, "DEBUFF")
advance(4)
log("SPELL_AURA_REMOVED", "P-MATE", "E-MAGE", 408, "Kidney Shot", nil, nil, "DEBUFF")
-- Pets and guardians: the Succubus seduces my rogue and Locky's Corruption
-- breaks it (crowd control landed by a pet is its owner's); a Mindbender I
-- summon breaks my own Psychic Scream on the mage; a Grimoire felhunter
-- summoned mid-match locks me (a guardian is its summoner's).
log("SPELL_AURA_APPLIED", "PET-FEL", "P-MATE", 6358, "Seduction", nil, nil, "DEBUFF")
advance(2)
log("SPELL_AURA_BROKEN_SPELL", "E-LOCK", "P-MATE", 6358, "Seduction", 172, "Corruption", "DEBUFF")
log("SPELL_SUMMON", "P-ME", "MB-1", 123040, "Mindbender")
log("SPELL_AURA_APPLIED", "P-ME", "E-MAGE", 8122, "Psychic Scream", nil, nil, "DEBUFF")
advance(1)
log("SPELL_AURA_BROKEN", "MB-1", "E-MAGE", 8122, "Psychic Scream", nil, nil, "DEBUFF")
log("SPELL_SUMMON", "E-LOCK", "GUARD-1", 111897, "Grimoire: Felhunter")
log("SPELL_INTERRUPT", "GUARD-1", "P-ME", 19647, "Spell Lock", 2061, "Flash Heal")

h.handlers.ARENA_RESULT({ bracket = 1, rating = 1800, delta = 12, won = true })

local store = h.module.db.chars["Me-Realm"]
local match
for _, list in pairs(store.matches or store) do
	if type(list) == "table" then for _, m in ipairs(list) do if m.mine then match = m end end end
end
check(match ~= nil, "a match was filed")
if not match then print("passed " .. passes .. ", failed " .. fails); os.exit(1) end
check(match.plays == true, "the match says it counted")
local by = {}
for _, side in ipairs({ match.mine, match.theirs }) do for _, p in ipairs(side) do by[p.guid] = p end end
local function n(guid, key) return by[guid] and by[guid][key] or 0 end

check(n("P-ME", "trink") == 1, "my trinket")
check(n("E-MAGE", "trink") == (CLIENT == "tbc" and 1 or 0), CLIENT .. ": the mage's trinket by name only on Anniversary")
check(n("P-ME", "disp") == 1 and n("P-ME", "purge") == 1, "my party dispel and my purge")
check(n("E-MAGE", "purge") == 1, "the steal is an offensive dispel")
check(n("E-LOCK", "purge") == 1, "the felhunter's purge is the warlock's")
check(n("P-MATE", "kick") == 1 and n("E-MAGE", "kicked") == 1, "the rogue's kick, the mage kicked")
check(n("E-LOCK", "kick") == 2 and n("P-ME", "kicked") == 2, "the felhunter's and the Grimoire felhunter's locks are the warlock's; I was locked twice")
check(n("E-LOCK", "brk") == 2, "Locky broke his mage's sheep, and his own Succubus's Seduction")
check(n("E-MAGE", "brk") == 2, "Frosty broke his own sheep, and Locky's Fear")
check(n("P-MATE", "brk") == 0, "my rogue broke nothing")
check(n("P-ME", "brk") == 1, "my Mindbender broke my own Psychic Scream: mine")
check((by["P-MATE"].ccTaken or 0) > 3.9 and (by["P-MATE"].ccTaken or 0) < 4.1, "the broken sheep and Seduction still counted their two seconds each")
check(n("E-MAGE", "ccTakenCount") == 2, "the Kidney Shot and the Scream counted as crowd control")
print(CLIENT .. ": passed " .. passes .. ", failed " .. fails)
os.exit(fails == 0 and 0 or 1)
