-- ReplaySignal's mark under a stub client: the colours it draws decode, by the
-- rules ReplayPlus's Marker.cs reads them with, to the arena's phase, map and
-- bracket with a valid check. From the addon folder:
--
--     lua5.1 tests/signal_test.lua . mop
local ROOT = arg[1] or "."
local fails, passes = 0, 0
local function check(ok, what) if ok then passes = passes + 1 else fails = fails + 1; print("FAIL  " .. what) end end

-- A frame or a texture: records what is done to it.
local function Widget()
	local w = { shown = true, points = {} }
	local mt = { __index = function(t, k)
		-- Methods only (they start with a capital); a field not set is nil.
		if not k:match("^%u") then return nil end
		return function(self, ...)
			local a = { ... }
			if k == "Show" then self.shown = true
			elseif k == "Hide" then self.shown = false
			elseif k == "IsShown" then return self.shown
			elseif k == "SetColorTexture" then self.colour = { a[1], a[2], a[3] }
			elseif k == "CreateTexture" then local tex = Widget(); self.textures = self.textures or {}; table.insert(self.textures, tex); return tex
			elseif k == "SetScale" then self.scale = a[1]
			elseif k == "SetScript" then self.scripts = self.scripts or {}; self.scripts[a[1]] = a[2]
			end
		end
	end }
	return setmetatable(w, mt)
end

local frames = {}
CreateFrame = function(kind, name) local f = Widget(); table.insert(frames, f); if name then _G[name] = f end; return f end
WorldFrame = Widget()
bit = { band = function(a, b) local r, p = 0, 1; while a > 0 and b > 0 do if a % 2 == 1 and b % 2 == 1 then r = r + p end; a, b, p = math.floor(a / 2), math.floor(b / 2), p * 2 end; return r end,
	bxor = function(a, b) local r, p = 0, 1; while a > 0 or b > 0 do if (a % 2) ~= (b % 2) then r = r + p end; a, b, p = math.floor(a / 2), math.floor(b / 2), p * 2 end; return r end }
local tickers = {}
C_Timer = { NewTicker = function(s, f) table.insert(tickers, f); return {} end, After = function() end }
GetPhysicalScreenSize = function() return 3440, 1440 end
local now = 100
GetTime = function() return now end
local inArena, instanceId, winner, faction, runTime = false, 617, nil, 0, 0
IsActiveBattlefieldArena = function() return inArena end
IsInInstance = function() return inArena, inArena and "arena" or "none" end
GetInstanceInfo = function() return "Dalaran Arena", "arena", 0, "", 5, 0, false, instanceId end
GetBattlefieldWinner = function() return winner end
GetBattlefieldArenaFaction = function() return faction end
GetBattlefieldInstanceRunTime = function() return runTime end
GetMaxBattlefieldID = function() return 1 end
GetBattlefieldStatus = function() return inArena and "active" or "none", "Dalaran Arena", 2, true end
COMBATLOG_OBJECT_REACTION_HOSTILE, COMBATLOG_OBJECT_TYPE_PLAYER = 0x40, 0x400

local ns = { L = setmetatable({}, { __index = function(t, k) return k end }), SlashCommands = {} }
ns.RegisterModule = function(key, m) m.key = key; m.db = { enabled = true }; ns.module = m; return m end
ns.Print = function() end
ns.ClientVersion = function() return arg[2] or "mop" end
local chunk = assert(loadfile(ROOT .. "/Modules/ReplaySignal.lua"))
chunk("ArenaPlus", ns)
local module = ns.module
module:OnEnable()

-- The mark as ReplayPlus reads it: each cell's colour as red 4 + green 2 + blue 1.
local function Read()
	local sig = _G.ArenaPlusSignal
	if not sig or not sig.shown then return nil end
	local v = {}
	for i, tex in ipairs(sig.textures) do
		local c = tex.colour
		v[i] = (c[1] == 1 and 4 or 0) + (c[2] == 1 and 2 or 0) + (c[3] == 1 and 1 or 0)
	end
	return v
end
local function valid(v)
	return v and v[1] == 5 and v[7] == 2 and v[6] == 7 - bit.bxor(bit.bxor(v[2], v[3]), bit.bxor(v[4], v[5]))
end
local function tick() now = now + 0.25; for _, f in ipairs(tickers) do f() end end

tick()
check(Read() == nil, "out of any arena: no mark")
inArena, runTime = true, 1000
tick()
local v = Read()
check(valid(v), "in the arena: a valid mark")
check(v and v[2] == 1 and v[3] == 4 and v[4] == 1, "prep, Dalaran (617), rated 2v2")
check(math.abs(_G.ArenaPlusSignal.scale - 768 / 1440) < 1e-9, "one unit one pixel")
local seq = v[5]
tick()
check(Read()[5] ~= seq, "the sequence counts on")
-- The gates, from the chat line.
local handler = frames[1].scripts and frames[1].scripts.OnEvent
for _, f in ipairs(frames) do if f.scripts and f.scripts.OnEvent then handler = f.scripts.OnEvent end end
handler(nil, "CHAT_MSG_BG_SYSTEM_NEUTRAL", "The Arena battle has begun!")
tick()
check(Read()[2] == 2 and valid(Read()), "fighting, the gates seen")
winner = 0
tick()
check(Read()[2] == 4 and valid(Read()), "won: our side is the winner")
winner = 1
tick()
check(Read()[2] == 5, "lost")
-- Leaving: hidden at the loading screen, then out for half a minute.
handler(nil, "PLAYER_LEAVING_WORLD")
check(Read() == nil, "the loading screen out: hidden")
inArena, winner = false, nil
handler(nil, "PLAYER_ENTERING_WORLD")
check(Read() and Read()[2] == 7 and valid(Read()), "out of the arena")
now = now + 31
tick()
check(Read() == nil, "and gone half a minute later")
-- A requeue into the same arena starts over: no gates seen yet.
inArena, runTime = true, 500
tick()
check(Read()[2] == 1, "the next arena starts in the prep room, same map or not")
runTime = 63000
tick()
check(Read()[2] == 3, "the minute run out: fighting, inferred")
module.db.enabled = false
tick()
check(Read() == nil, "switched off: no mark")
print("signal: passed " .. passes .. ", failed " .. fails)
os.exit(fails == 0 and 0 or 1)
