-- Unknown arena API answers must not suppress or erase combat-log spec reads.
-- lua5.1 tests/history_spec_test.lua . tbc
-- lua5.1 tests/history_spec_test.lua . mop
local ROOT, CLIENT, CASE = arg[1] or ".", arg[2] or "tbc", arg[3] or "zero"
local answer = CASE == "valid" and 73 or CASE == "negative" and -1 or 0
if CASE == "nil" then answer = nil end
GetArenaOpponentSpec = function(index)
	if index == 1 then return answer end
	return 267
end
local h = dofile(ROOT .. "/tests/history_harness.lua")
local failures, passes = 0, 0
local function check(ok, label)
	if ok then passes = passes + 1 else failures = failures + 1; print("FAIL " .. label) end
end
local function finish()
	h.handlers.ARENA_RESULT({ bracket = 1, rating = 1800, delta = 12, won = true })
	local store = h.module.db.chars["Me-Realm"]
	local found
	for _, list in pairs(store.matches or store) do
		if type(list) == "table" then for _, match in ipairs(list) do
			if match.mine then
				for _, p in ipairs(match.theirs) do if p.guid == "E-MAGE" then found = p.spec end end
			end
		end end
	end
	return found
end
-- TBC's ranked Mortal Strike has a different id but the same name. The API
-- returns zero before and after the spell; the inferred Arms spec must survive.
h.units.arena1[3] = "WARRIOR"
h.sample()
if CASE == "unknown" then
	h.log("SPELL_CAST_SUCCESS", "E-MAGE", "P-ME", 78, "Heroic Strike")
else
	h.log("SPELL_CAST_SUCCESS", "E-MAGE", "P-ME", 30330, "Mortal Strike")
end
h.sample()
if CASE == "authority" then
	answer=72
	h.sample()
	h.log("SPELL_CAST_SUCCESS", "E-MAGE", "P-ME", 12294, "Mortal Strike")
	answer=0
	h.sample()
end
local expected = CASE == "valid" and 73 or CASE == "authority" and 72 or 71
if CASE == "unknown" then expected = nil end
check(finish() == expected, CLIENT .. ": " .. CASE .. " spec detection")
print(CLIENT .. ": passed " .. passes .. ", failed " .. failures)
os.exit(failures == 0 and 0 or 1)
