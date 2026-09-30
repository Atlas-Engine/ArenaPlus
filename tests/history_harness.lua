-- Runs ArenaPlus's Modules/ArenaHistory.lua under a stub client: an arena with
-- two players a side and one enemy pet, combat log events fired through the
-- module's own event handler, and the match it files read back. Plain Lua 5.1,
-- nothing to install: see history_test.lua for how it is run.
local ROOT = arg[1] or "."
local CLIENT = arg[2] or "mop"

-- Anything not stubbed: indexing it gives it back, calling it gives nil.
local none
none = setmetatable({}, { __index = function() return none end, __call = function() return nil end })
setmetatable(_G, { __index = function() return none end })

local function Frame()
	local f = { scripts = {}, events = {} }
	return setmetatable(f, { __index = function(t, k)
		if k == "SetScript" then return function(self, what, fn) self.scripts[what] = fn end end
		if k == "GetScript" then return function(self, what) return self.scripts[what] end end
		if k == "RegisterEvent" then return function(self, e) self.events[e] = true end end
		if k == "IsShown" then return function() return false end end
		return function() return Frame() end
	end })
end
frames = {}
CreateFrame = function(...) local f = Frame(); frames[#frames + 1] = f; return f end
C_Timer = { NewTicker = function() end, After = function() end }
time = os.time
GetTime = function() return clock end
clock = 100

-- The arena: me and a teammate, two opponents, the second a warlock with a pet.
local units = {
	player   = { "P-ME", "Me", "PRIEST" },   party1 = { "P-MATE", "Mate", "ROGUE" },
	arena1   = { "E-MAGE", "Frosty", "MAGE" }, arena2 = { "E-LOCK", "Locky", "WARLOCK" },
	arenapet2 = { "PET-FEL", "Felhunter", nil },
}
UnitExists = function(u) return units[u] ~= nil end
UnitGUID = function(u) return units[u] and units[u][1] end
UnitName = function(u) return units[u] and units[u][2], nil end
UnitClass = function(u) local x = units[u]; if x and x[3] then return x[3], x[3] end end
UnitRace = function(u) return "Human", "Human" end
UnitSex = function() return 2 end
IsActiveBattlefieldArena = function() return true end
GetBattlefieldInstanceRunTime = function() return 0 end
GetSpellInfo = function(id) return SPELL_NAMES[id] end
C_Spell = nil
SPELL_NAMES = { [118] = "Polymorph", [5782] = "Fear", [408] = "Kidney Shot" }
if CLIENT == "tbc" then
	WOW_PROJECT_ID, WOW_PROJECT_BURNING_CRUSADE_CLASSIC = 5, 5
end

-- The addon's namespace, as Core.lua would leave it.
local ns = {}
ns.L = setmetatable({}, { __index = function(_, k) return k end })
local module
ns.RegisterModule = function(key, def) module = { db = { enabled = true } }; return module end
ns.SlashCommands = {}
local handlers = {}
ns.On = function(e, fn) handlers[e] = fn end
ns.MigrateCharStore = function() end
ns.CharKey = function() return "Me-Realm" end
ns.IsAddOnLoaded = function() return false end
ns.SPEC_SPELLS, ns.SPEC_SPELL_NAMES = {}, {}
ns.ClientVersion = function() return CLIENT end
ns.TIERS = {}

-- The files start with a byte-order mark, which the game skips and Lua does not.
local function load(path)
	local file = assert(io.open(ROOT .. "/" .. path, "rb"))
	local text = file:read("*a"):gsub("^\239\187\191", "")
	file:close()
	assert(loadstring(text, "@" .. path))("ArenaPlus", ns)
end
load("HardCC.lua")
load("Modules/ArenaHistory.lua")
module:OnEnable()

local watcher
for _, f in ipairs(frames) do if f.events.COMBAT_LOG_EVENT_UNFILTERED then watcher = f end end
assert(watcher, "no frame registered for the combat log")
local fire = watcher.scripts.OnEvent
fire(watcher, "PLAYER_ENTERING_WORLD")

-- Log events: GUIDs only, the rest of each unit's fields empty.
local function log(event, src, dst, spellID, spellName, extraID, extraName, aura)
	CombatLogGetCurrentEventInfo = function()
		return 0, event, false, src, nil, 0, 0, dst, nil, 0, 0, spellID, spellName, 0, extraID, extraName, 0, aura
	end
	fire(watcher, "COMBAT_LOG_EVENT_UNFILTERED")
end

return { log = log, handlers = handlers, module = module, advance = function(s) clock = clock + s end }
