local ADDON_NAME, ns = ...
local L = ns.L

-- Open the Player vs Player panel on Rated -- ConquestQueueFrame, the 2v2 /
-- 3v3 / 5v5 and rated battleground page -- instead of Random Battleground,
-- with the chosen row already picked.
--
-- The names below are this client's own, from Blizzard_PVPUI: PVPQueueFrame is
-- a child of PVEFrame and holds the four pages it lists in its pvpFrames table
-- (HonorQueueFrame, ConquestQueueFrame, WarGamesQueueFrame, LFGListPVPStub),
-- and PVPQueueFrame_ShowFrame(frame) is what its own category buttons call.
-- Despite the name, this build has no PVPUIFrame frame to hang anything on.
local module = ns.RegisterModule("pvp",{
	title       = L.PVP_TITLE,
	enableLabel = L.PVP_ENABLE,
	desc        = L.PVP_DESC,
	group       = "arena",
	defaults    = { enabled=true },
})

local hooked=false

----------------------------------------------------------------
-- Touching Blizzard's panel without breaking the queue
----------------------------------------------------------------

-- Their functions, run without our fingerprints on them.
--
-- None of the calls below are protected, so ordinary calls succeed and the
-- page looks right -- but each one records something the page keeps, and the
-- Join Battle button reads those records before calling JoinArena, which is
-- protected. Our taint went into the record and the client then refused the
-- queue: "AddOn 'ArenaPlus' tried to call the protected function
-- 'JoinArena()'". Picking a bracket cost the ability to join one.
--
-- securecall runs the function as though the game had called it, which is what
-- it is for. The direct call is the fallback for a build without it, where a
-- panel that opens on the wrong page beats a panel that cannot queue.
local function Secure(func,...)
	if type(func)~="function" then return end
	if type(securecall)=="function" then return securecall(func,...) end
	return func(...)
end

----------------------------------------------------------------
-- Which tab the window opens on
----------------------------------------------------------------

-- PVEFrame is one window with three tabs -- Group Finder, PvP, Challenges --
-- and PVEFrame_ShowFrame with no tab named falls back to activeTabIndex, the
-- last one used. So once you have been to PvP, opening the group finder puts
-- you back in PvP. That is Blizzard's behaviour and predates this tweak, but
-- this tweak is what makes it obvious: you land on Rated rather than on the
-- battleground page you would have ignored.
local GROUP_FINDER = "GroupFinderFrame"

-- TogglePVPUI is a client function, not Lua, so there is no reading whether it
-- names its tab or leaves it to the remembered one. Rather than assume: the
-- redirect waits a frame, and a TogglePVPUI that ran in the meantime calls it
-- off. If it does name its tab this never triggers at all; if it does not, the
-- redirect still keeps its hands off a deliberate trip to PvP.
local pvpOpenedAt=0
local redirecting=false

local function RedirectToGroupFinder()
	if redirecting then return end
	if not module.db.enabled then return end
	if InCombatLockdown() then return end
	if type(PVEFrame_ShowFrame)~="function" then return end

	-- Somebody asked for PvP by name in the meantime.
	if GetTime()-pvpOpenedAt<0.2 then return end
	if not (PVEFrame and PVEFrame:IsShown()) then return end
	if GroupFinderFrame and GroupFinderFrame:IsShown() then return end

	redirecting=true
	PVEFrame_ShowFrame(GROUP_FINDER)
	redirecting=false
end

local function HookTabMemory()
	if type(hooksecurefunc)~="function" then return end

	if type(PVEFrame_ShowFrame)=="function" then
		hooksecurefunc("PVEFrame_ShowFrame",function(sidePanelName)
			-- A named tab is somebody asking for that tab. Only the nameless
			-- call -- "show whatever was last" -- is the one to override.
			if sidePanelName then return end
			C_Timer.After(0,RedirectToGroupFinder)
		end)
	end

	if type(TogglePVPUI)=="function" then
		hooksecurefunc("TogglePVPUI",function() pvpOpenedAt=GetTime() end)
	end
end

----------------------------------------------------------------
-- Switching to the Rated page
----------------------------------------------------------------

-- Below the level Conquest unlocks, Blizzard only disables the category
-- button: PVPQueueFrame_ShowFrame would still happily show the page, so the
-- button is what has to be asked.
local function RatedReachable()
	local button=PVPQueueFrame and PVPQueueFrame.CategoryButton2
	if button and button.IsEnabled and not button:IsEnabled() then return false end
	return true
end

local function ShowRated()
	if not (PVPQueueFrame and ConquestQueueFrame) then return false end
	if ConquestQueueFrame:IsShown() then return true end
	if not RatedReachable() then return false end

	if type(PVPQueueFrame_ShowFrame)=="function" then
		-- Their own switcher: it hides the other pages, tints the matching
		-- category button and records the selection, which is what the panel
		-- reads the next time it opens.
		Secure(PVPQueueFrame_ShowFrame,ConquestQueueFrame)
	elseif PVPQueueFrame.CategoryButton2 then
		Secure(PVPQueueFrame.CategoryButton2.Click,PVPQueueFrame.CategoryButton2)
	end

	return ConquestQueueFrame:IsShown()
end

-- There used to be a FocusBracket here that opened the page on your bracket
-- rather than the 10v10 row Blizzard picks by default. It cannot be done, and
-- this note exists so it does not get built a third time.
--
-- Selecting a row stores it in ConquestQueueFrame.selectedButton, which Join
-- Battle reads before calling the protected JoinArena. Set from addon code the
-- value is tainted, and the client refuses the queue outright:
-- ADDON_ACTION_FORBIDDEN, from ConquestQueueFrameJoinButton_OnClick.
--
-- Measured twice, because the first reading was taken with two suspects live
-- and blamed the wrong one:
--
--   dropdown parented to ConquestQueueFrame + securecall'd select -> refused
--   no dropdown at all                      + securecall'd select -> refused
--
-- So it is the selection, not the frame parenting. securecall does not help:
-- it stops a called function's taint reaching its caller, not the reverse, and
-- the row is a value our own code looked up so it arrives dirty regardless.
--
-- Clicking a row yourself sets the same field cleanly. One click after the
-- panel opens is the whole difference, and it is a click that works.

----------------------------------------------------------------
-- Reacting to the panel opening
----------------------------------------------------------------

local function Apply()
	if not module.db.enabled then return end
	if InCombatLockdown() then return end
	-- IsVisible rather than IsShown: the page frames carry their own shown
	-- flag while PVEFrame, their parent, is closed.
	if not (PVPQueueFrame and PVPQueueFrame:IsVisible()) then return end
	ShowRated()
end

local function OnQueueFrameShown()
	Apply()
	-- PVEFrame re-applies the remembered selection as part of showing the tab,
	-- and the page picks its own row when it updates; both can land after this
	-- hook. A second pass at the start of the next frame gets the last word.
	C_Timer.After(0,Apply)
end

local function HookPvPUI()
	if hooked or not PVPQueueFrame then return end
	hooked=true
	PVPQueueFrame:HookScript("OnShow",OnQueueFrameShown)

	-- Switched on from the options while the panel is already open.
	if PVPQueueFrame:IsVisible() then OnQueueFrameShown() end
end

local watcher=CreateFrame("Frame")
watcher:SetScript("OnEvent",function(self,event,name)
	if name=="Blizzard_PVPUI" then
		HookPvPUI()
		self:UnregisterEvent("ADDON_LOADED")
	end
end)

function module:OnEnable()
	HookTabMemory()

	-- Blizzard_PVPUI is load-on-demand: it arrives the first time the panel is
	-- opened, and everything above only exists from then on.
	if ns.IsAddOnLoaded("Blizzard_PVPUI") then
		HookPvPUI()
	else
		watcher:RegisterEvent("ADDON_LOADED")
	end
end

----------------------------------------------------------------
-- Diagnostics
----------------------------------------------------------------

-- Who, if anybody, has dirtied the fields Join Battle reads.
--
-- Taint is invisible until the moment the queue is refused, and the refusal
-- names whichever addon is on the execution path rather than whichever one put
-- the value there. issecurevariable names the culprit outright, so this settles
-- the question instead of leaving it to be argued from a red error line.
--
-- Open the PvP panel, pick a bracket, then run it.
ns.SlashCommands["taint"]=function()
	ns.Print("securecall: %s",type(securecall)=="function" and "yes" or "MISSING")

	if not ConquestQueueFrame then
		ns.Print("Rated page not loaded yet - open the PvP panel first.")
		return
	end

	if type(issecurevariable)~="function" then
		ns.Print("issecurevariable missing - cannot check.")
		return
	end

	local function Report(owner,field,label)
		if not owner then return end
		local secure,culprit=issecurevariable(owner,field)
		ns.Print("%s: %s%s",label,secure and "clean" or "TAINTED",
			(not secure and culprit) and (" by "..culprit) or "")
	end

	Report(ConquestQueueFrame,"selectedButton","selected bracket")
	Report(ConquestQueueFrame,"lastSelectedButton","last selected")
	Report(PVPQueueFrame,"selectedIndex","selected page")
end
