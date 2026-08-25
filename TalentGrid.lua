local ADDON_NAME, ns = ...

-- Which talent sits in which tier and column, for every class.
--
-- Read out of the game client, not worked out. GetTalentInfoByID returns a
-- talent's row and column directly, and walking the ids this expansion actually
-- uses -- 15000 to 20500, not the 1 to 400 they look like they should be --
-- returned 215 entries: 197 real talents and eighteen "Dummy 5.0 Talent"
-- placeholders sitting in a fourth column that no class has.
--
-- What the client does not say is which class a talent belongs to. That came
-- from two independent signals, and only where they agreed:
--
--   the cell it fills -- 197 talents land in a clean 6x3 grid at eleven per
--   cell, one per class, so a talent in a cell only one class is still missing
--   belongs to that class;
--
--   the company it keeps -- talent ids run in blocks by class, so an id sitting
--   inside a run of paladin ids is a paladin talent.
--
-- Eleven needed that treatment, of which seven fell to the first signal alone
-- and four to both together. One talent, paladin tier 3 column 3, the client
-- never returned at all; it is the only paladin talent seen in real builds that
-- had nowhere else to go.
--
-- This replaces a constraint solver that inferred the layout from thousands of
-- observed builds. That solver was wrong in ways that showed: it put Halo in
-- tier 3 when it belongs in tier 6, left holes where a class had few builds to
-- learn from, once placed the same monk talent in two tiers at once, and its
-- coverage wandered between 184 and 189 of 198 from one run to the next with no
-- code change at all. This file is 198 of 198 and does not move.
--
-- Harvested 2026-08-23 with /arena talents. It describes the game, not the ladder, so
-- it needs regenerating only if Blizzard changes a talent.

ns.TALENT_GRID = ns.TALENT_GRID or {}

for klass, tiers in pairs({
	["death-knight"]={[1]={108170,123693,115989},[2]={49039,51052,114556},[3]={96268,50041,108194},[4]={48743,108196,119975},[5]={45529,81229,51462},[6]={108199,108200,108201}},
	["druid"]={[1]={131768,102280,102401},[2]={145108,108238,102351},[3]={106707,102359,132469},[4]={114107,106731,106737},[5]={99,102793,5211},[6]={108288,108373,124974}},
	["hunter"]={[1]={109215,109298,118675},[2]={109248,19386,19577},[3]={109304,109260,109212},[4]={82726,120679,109306},[5]={131894,130392,120697},[6]={117050,109259,120360}},
	["mage"]={[1]={12043,108843,108839},[2]={115610,140468,11426},[3]={113724,111264,102051},[4]={110959,86949,11958},[5]={114923,44457,112948},[6]={114003,116011,1463}},
	["monk"]={[1]={115173,116841,115174},[2]={115098,124081,123986},[3]={121817,115396,115399},[4]={116844,119392,119381},[5]={122280,122278,122783},[6]={116847,123904,115008}},
	["paladin"]={[1]={85499,87172,26023},[2]={105593,20066,110301},[3]={85804,114163,20925},[4]={114039,114154,105622},[5]={105809,53376,86172},[6]={114165,114158,114157}},
	["priest"]={[1]={108920,108921,605},[2]={64129,121536,108942},[3]={109186,123040,139139},[4]={19236,112833,108945},[5]={109142,10060,109175},[6]={121135,110744,120517}},
	["rogue"]={[1]={14062,108208,108209},[2]={26679,108210,74001},[3]={31230,108211,79008},[4]={138106,36554,108212},[5]={131511,108215,108216},[6]={114014,137619,114015}},
	["shaman"]={[1]={30884,108270,108271},[2]={63374,51485,108273},[3]={108285,108284,108287},[4]={16166,16188,108283},[5]={147074,108281,108282},[6]={117012,117013,117014}},
	["warlock"]={[1]={108359,108370,108371},[2]={47897,6789,30283},[3]={108415,108416,110913},[4]={111397,111400,108482},[5]={108499,108501,108503},[6]={108505,137587,108508}},
	["warrior"]={[1]={103826,103827,103828},[2]={55694,29838,103840},[3]={107566,12323,102060},[4]={46924,46968,118000},[5]={114028,114029,114030},[6]={107574,12292,107570}},
}) do
	ns.TALENT_GRID[klass] = tiers
end
