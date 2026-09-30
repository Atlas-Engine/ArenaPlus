-- CombatLogging under a stub client: on as an arena queue pops, off LINGER
-- seconds after leaving -- counted from leaving, not pushed back by every
-- event -- and never switched off inside a dungeon, a raid or a scenario.
-- From the addon folder:
--
--     lua5.1 tests/combatlog_test.lua .
local ROOT = arg[1] or "."
local fails, passes = 0, 0
local function check(ok, what) if ok then passes = passes + 1 else fails = fails + 1; print("FAIL  " .. what) end end

local handler
CreateFrame = function()
	return { RegisterEvent = function() end, SetScript = function(self, _, f) handler = f end }
end
local now = 1000
GetTime = function() return now end
-- Timers run when the clock passes them (Advance).
local timers = {}
C_Timer = { After = function(s, f) table.insert(timers, { at = now + s, f = f }) end }
local function Advance(seconds)
	now = now + seconds
	local due = {}
	for i = #timers, 1, -1 do if timers[i].at <= now then table.insert(due, 1, timers[i]); table.remove(timers, i) end end
	for _, t in ipairs(due) do t.f() end
end

local logging = false
LoggingCombat = function(on) if on ~= nil then logging = on end; return logging end
local where, popped = "none", false
IsActiveBattlefieldArena = function() return where == "arena" end
IsInInstance = function() return where ~= "none", where end
GetMaxBattlefieldID = function() return 1 end
GetBattlefieldStatus = function() return popped and "confirm" or "none", "", 2, 0, 0, "ARENA" end

local ns = { L = setmetatable({}, { __index = function(t, k) return k end }), SlashCommands = {} }
ns.RegisterModule = function(key, m) m.db = { enabled = true }; ns.module = m; return m end
ns.Print = function() end
assert(loadfile(ROOT .. "/Modules/CombatLogging.lua"))("ArenaPlus", ns)
local module = ns.module
local function Event(name) handler(nil, name) end

-- An arena: on at the pop, kept on in it.
popped = true
Event("UPDATE_BATTLEFIELD_STATUS")
check(logging and module.db.started, "on as the queue pops, and ArenaPlus's")
where = "arena"
Event("PLAYER_ENTERING_WORLD")
popped = false
where = "none"
Event("PLAYER_ENTERING_WORLD")
check(logging, "still on just after leaving")
-- Events after leaving do not push the switch-off back.
Advance(600)
Event("UPDATE_BATTLEFIELD_STATUS")
Advance(301)
check(not logging and not module.db.started, "off fifteen minutes after leaving, whatever came between")

-- Out of an arena into a dungeon inside the fifteen minutes: kept on in it.
popped = true
Event("UPDATE_BATTLEFIELD_STATUS")
where = "arena"
Event("PLAYER_ENTERING_WORLD")
popped = false
where = "none"
Event("PLAYER_ENTERING_WORLD")
Advance(300)
where = "raid"
Event("PLAYER_ENTERING_WORLD")
Advance(3600)
check(logging, "never switched off inside a raid")
-- Out of the raid: fifteen minutes more, then off.
where = "none"
Event("PLAYER_ENTERING_WORLD")
Advance(899)
check(logging, "the linger starts again once out")
Advance(2)
check(not logging, "and ends")

-- A log you started yourself is left alone.
logging = true
module.db.started = nil
Event("PLAYER_ENTERING_WORLD")
Advance(3600)
check(logging, "a log ArenaPlus did not start stays on")

print("combatlog: passed " .. passes .. ", failed " .. fails)
os.exit(fails == 0 and 0 or 1)
