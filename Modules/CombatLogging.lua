local ADDON_NAME, ns = ...
local L = ns.L

-- The combat log, on for arenas and off again afterwards.
--
-- ReplayPlus -- or anything else that reads Logs\WoWCombatLog*.txt -- needs the
-- game writing it, and /combatlog is easy to forget before a match and easy to
-- leave on after one, writing every fight in the open world to disk as well.
-- This does both halves: on when an arena queue pops, off once you are out.
--
-- On at the pop rather than on arrival. Entering the arena is itself a line in
-- the log (ZONE_CHANGE), and it is written during the loading screen -- before
-- anything here gets to run on the other side of it.
--
-- Off only LINGER seconds after leaving. The game writes the log to disk in
-- 48 KiB blocks, holding the rest in memory (measured 2026-09-30): the last
-- seconds of a match and the line saying you left reach the file only when
-- the next block fills, and nothing more is logged once the log is off -- so
-- switched off ten seconds after leaving, they waited for the next arena. Kept
-- on, world combat or the next arena's first block writes them sooner, and
-- the game writes what is left when it closes. Nothing an addon does can make
-- it write sooner: switching logging off and on from Lua writes nothing.
-- ReplayPlus starts and stops recording from ArenaPlus's mark (ReplaySignal)
-- and fills the match in whenever the log comes.
--
-- And on again on arrival, and ARRIVAL_CHECK seconds after it. Another addon
-- may switch the log off at every loading screen -- Details' "Auto Start
-- Combatlog" does, a second after arriving, and only switches it back on in
-- dungeons and raids -- which left the match unlogged and ReplayPlus recording
-- with no end in sight. A loading screen (a /reload too) is the one moment the
-- log is put back; after it, a /combatlog you type to stop it is left alone.
--
-- Only ever switched off if this switched it on. A log you started yourself --
-- for a raid, say -- is left alone. Which one it was is kept in the saved
-- variables, so a /reload in the arena does not lose track of it. Never
-- switched off inside a dungeon, a raid or a scenario either, where a log is
-- wanted for its own sake -- the linger ran out fifteen minutes into one, and
-- the log someone meant to upload stopped there. The linger starts again once
-- out of it; it runs from leaving, not from the last event, which pushed it
-- back at every queue update.
--
-- Off by default: it writes a file per arena into the game's Logs folder,
-- which is only worth having for something that reads them.
local module = ns.RegisterModule("combatlog",{
	title       = L.COMBATLOG_TITLE,
	enableLabel = L.COMBATLOG_ENABLE,
	desc        = L.COMBATLOG_DESC,
	group       = "arena",
	defaults    = { enabled=false },
})

local LINGER        = 900
local ARRIVAL_CHECK = 3

-- Bumped by every decision, so a switch-off still waiting on its delay can
-- tell it has been overtaken -- by the next queue popping, say.
local generation=0

-- Whether an arena was underway at the last look. The log is switched on as
-- one begins (and on arriving) rather than whenever one is found underway, so
-- a /combatlog you type mid-match to stop it is not undone by the next event.
local underwayBefore=false

local function InArena()
	if IsActiveBattlefieldArena and IsActiveBattlefieldArena() then return true end
	local _,kind=IsInInstance()
	return kind=="arena"
end

-- An arena queue that has popped ("confirm", while the invitation is up) or
-- been accepted ("active", from then until you leave the arena). queueType
-- says which queues are arenas -- "ARENA" and "ARENASKIRMISH" -- and where a
-- client leaves it out, an arena is the only queue with a team size.
local function ArenaPopped()
	if not (GetMaxBattlefieldID and GetBattlefieldStatus) then return false end

	for index=1,(GetMaxBattlefieldID() or 0) do
		local status,_,teamSize,_,_,queueType=GetBattlefieldStatus(index)
		if status=="confirm" or status=="active" then
			local arena
			if type(queueType)=="string" then
				arena=queueType:find("ARENA",1,true)~=nil
			else
				arena=(teamSize or 0)>0
			end
			if arena then return true end
		end
	end

	return false
end

local function Logging()
	return LoggingCombat() and true or false
end

local function InGroupInstance()
	local _,kind=IsInInstance()
	return kind=="party" or kind=="raid" or kind=="scenario"
end

-- When the waiting switch-off is due; nil when none waits.
local offAt=nil

-- `fresh` treats an arena already underway as just begun: at load, on
-- arriving, and when the tick is switched on.
local function Update(fresh)
	if not (module.db and LoggingCombat) then return end

	local underway=InArena() or ArenaPopped()

	if underway then
		generation=generation+1
		offAt=nil
		if (fresh or not underwayBefore) and module.db.enabled and not Logging() then
			LoggingCombat(true)
			module.db.started=true
		end
	elseif module.db.started and not Logging() then
		-- Already off -- the log does not outlast the session, so this is a
		-- flag left from the last one. Forgotten now rather than acted on
		-- later, where it could stop a log you have just started yourself --
		-- and the switch-off waiting for it is called off, for the same reason.
		generation=generation+1
		module.db.started=nil
		offAt=nil
	elseif module.db.started and InGroupInstance() then
		-- Kept on while inside; the switch-off waiting is called off.
		generation=generation+1
		offAt=nil
	elseif module.db.started and not offAt then
		-- Whether or not the tick is still on: switched off in the middle of a
		-- match, the log runs until you leave rather than stopping partway
		-- through it, and is then put away like any other.
		generation=generation+1
		offAt=GetTime()+LINGER
		local mine=generation
		C_Timer.After(LINGER,function()
			if mine~=generation or not module.db.started then return end
			offAt=nil
			if InArena() or ArenaPopped() or InGroupInstance() then return end
			if Logging() then LoggingCombat(false) end
			module.db.started=nil
		end)
	end

	underwayBefore=underway
end

-- Listening whether or not the tick is on, which is what lets a log started
-- before it was switched off still be put away. module.db is there from our
-- own ADDON_LOADED, before either of these can fire for anything that matters.
local watcher=CreateFrame("Frame")
watcher:RegisterEvent("PLAYER_ENTERING_WORLD")
watcher:RegisterEvent("UPDATE_BATTLEFIELD_STATUS")
watcher:SetScript("OnEvent",function(_,event)
	if event=="PLAYER_ENTERING_WORLD" and InArena() then
		Update(true)
		C_Timer.After(ARRIVAL_CHECK,function()
			if InArena() then Update(true) end
		end)
		return
	end
	Update(false)
end)

function module:OnToggle(enabled)
	Update(enabled)
end

-- What it sees and what it would do, since none of it shows on screen.
--
--   /arena combatlog
ns.SlashCommands["combatlog"]=function()
	ns.Print("Switched on: %s.  Logging now: %s.  Started by ArenaPlus: %s.",
		module.db and module.db.enabled and "yes" or "no",
		LoggingCombat and Logging() and "yes" or "no",
		module.db and module.db.started and "yes" or "no")
	ns.Print("In an arena: %s.  An arena queue popped or accepted: %s.",
		InArena() and "yes" or "no",
		ArenaPopped() and "yes" or "no")
end
