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
--
-- All of which still holds, and none of it was worked around below. What the
-- section further down does instead is give up on selecting anything: it lights
-- a row without choosing it and holds Join Battle down until you choose. The
-- rule stands -- the selection is never written from here.

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

----------------------------------------------------------------
-- Opening on the bracket you last played
----------------------------------------------------------------

local preselect = ns.RegisterModule("pvpbracket",{
	title       = L.PREPICK_TITLE,
	enableLabel = L.PREPICK_ENABLE,
	desc        = L.PREPICK_DESC,
	group       = "arena",
	-- Same page of settings as the tweak above: both are about how the panel
	-- opens.
	parent      = "pvp",
	defaults    = { enabled=true },
})

-- The row that is lit while nothing has been chosen by hand, or nil.
--
-- This is a picture, not a selection, and the distinction is the whole design.
-- Blizzard's selectedButton is left exactly as they set it, because writing it
-- is what taints the queue -- and the note above is wrong about only one thing:
-- greying Join Battle would not have saved it. Their own select function reads
-- the old value before overwriting it, so a click on a dirty field catches the
-- taint and writes it straight back. The click meant to clean it re-dirties it.
--
-- So nothing of theirs is written. A texture is hidden, another is shown, and
-- both are widget calls that carry no taint whatsoever.
--
-- The picture would be a lie left alone: Join Battle still queues whatever is
-- selected underneath, and a page showing 3v3 that queues 10v10 is a worse bug
-- than the one being fixed. Hence the button is held down for exactly as long
-- as the light and the selection disagree. It is not a nicety, it is what
-- makes the lit row honest.
local armed

-- What Blizzard really had selected at the moment the light went on.
--
-- The way out of this state cannot depend on catching the click. It did at
-- first -- a hook on their row OnClick -- and that hook never fired, so nothing
-- ever stood down: every redraw put the lit row back and picking a different
-- bracket bounced straight back to the old one.
--
-- Comparing against this instead asks the question that actually matters, which
-- is whether anything has selected a row since. It does not care what did it or
-- through which function, so there is no entry point left to miss.
local armedOver

-- Followed by the history panel and the ladder window, which track the page.
-- While a row is lit but unchosen, the light is the thing to follow.
function ns.PendingBracket()
	return armed and armed.id or nil
end

-- The rows, in bracket order. The same keys the Rated page tweak uses.
local ROW_KEYS = { "Arena2v2", "Arena3v3", "Arena5v5", "RatedBG" }

local function Row(bracket)
	local key=ROW_KEYS[bracket or 0]
	return (key and ConquestQueueFrame and ConquestQueueFrame[key]) or nil
end

local function HoldJoin()
	local join=ConquestJoinButton
	if join and join.Disable then join:Disable() end
end

-- Their own function decides the button again, run as though the game called
-- it so that nothing it writes arrives dirty.
local function LetThemDecide()
	if type(ConquestQueueFrame_UpdateJoinButton)=="function" then
		Secure(ConquestQueueFrame_UpdateJoinButton)
	end
end

-- Whether a row has been chosen since the light went on. The one question that
-- decides everything below, and it is asked of the state rather than of a hook.
local function Chosen()
	if not armed then return false end
	return (ConquestQueueFrame and ConquestQueueFrame.selectedButton)~=armedOver
end

-- Out of the way: the page goes back to being entirely Blizzard's.
local function Release()
	if not armed then return end

	local real=ConquestQueueFrame and ConquestQueueFrame.selectedButton

	-- Unless it is now the real selection. Clicking the lit row means their
	-- select function has just shown that very texture, and hiding it here
	-- would undo the click in front of you.
	if armed~=real and armed.SelectedTexture then
		armed.SelectedTexture:Hide()
	end

	-- And whatever is really selected gets its texture back. A redraw of ours
	-- can land between the click and this, and it hides the real row on its way
	-- past -- which is how clicking 3v3 could leave nothing lit but 2v2.
	if real and real.SelectedTexture then real.SelectedTexture:Show() end

	-- Cleared before the button is reconsidered, or the hooks below would put
	-- it straight back down.
	armed=nil
	armedOver=nil
	LetThemDecide()
end

local function Arm()
	if not (preselect.db and preselect.db.enabled) then return end
	if InCombatLockdown() then return end
	if armed then return end
	if not (ConquestQueueFrame and ConquestQueueFrame:IsVisible()) then return end

	local bracket=ns.LastPlayedBracket and ns.LastPlayedBracket()
	if not bracket then return end

	local row=Row(bracket)
	if not (row and row.SelectedTexture) then return end

	-- Already there. Their selection is genuine, so it keeps it and Join Battle
	-- stays live: there is nothing here worth correcting, and interfering would
	-- only take away a queue that was ready to go.
	local real=ConquestQueueFrame.selectedButton
	if real==row then return end

	if real and real.SelectedTexture then real.SelectedTexture:Hide() end
	row.SelectedTexture:Show()
	armed=row
	armedOver=real

	HoldJoin()
end

-- Their Update runs many times over for a single open -- 25 passes measured on
-- the Rated page next door -- and it draws the row textures from selectedButton
-- as it goes. Without this the light lands and is gone again a frame later.
local function Reapply()
	if not armed then return end

	-- The redraw that follows a click arrives here too, and this is where the
	-- old bug lived: it faithfully put the lit row back over the row you had
	-- just picked. Standing down first is the fix.
	if Chosen() then return Release() end

	local real=ConquestQueueFrame and ConquestQueueFrame.selectedButton
	if real and real~=armed and real.SelectedTexture then real.SelectedTexture:Hide() end
	if armed.SelectedTexture then armed.SelectedTexture:Show() end
	HoldJoin()
end

-- Switched off with a row still lit, this would otherwise leave the light on
-- and -- far worse -- Join Battle held down, with the thing that was holding it
-- now disabled and no longer listening. Off has to mean the page is handed back
-- immediately.
function preselect:OnToggle(enabled)
	if not enabled then Release() end
end

local function HookConquest()
	if not ConquestQueueFrame then return end

	-- A frame late, the same reason the page switch waits: their OnShow picks
	-- a row of its own, and this has to be the one that gets the last word.
	ConquestQueueFrame:HookScript("OnShow",function() C_Timer.After(0,Arm) end)
	ConquestQueueFrame:HookScript("OnHide",Release)

	-- A row chosen by hand is the whole point of the exercise. From here the
	-- selection is theirs and clean, and this steps back.
	--
	-- On their select function rather than on the row's OnClick: the OnClick
	-- hook was the first attempt and it never fired once, which left the light
	-- stuck on and every other bracket unreachable. This one is what actually
	-- performs a selection, whatever route the click took to reach it -- the
	-- history panel has hung off it for as long as it has existed.
	if type(ConquestQueueFrame_SelectButton)=="function" then
		hooksecurefunc("ConquestQueueFrame_SelectButton",Release)
	end

	if type(ConquestQueueFrame_Update)=="function" then
		hooksecurefunc("ConquestQueueFrame_Update",Reapply)
	end

	-- Two ways the button can come back up, and both are covered rather than
	-- reasoned about: their update, and anything at all that enables it.
	if type(ConquestQueueFrame_UpdateJoinButton)=="function" then
		hooksecurefunc("ConquestQueueFrame_UpdateJoinButton",function()
			if Chosen() then return Release() end
			if armed then HoldJoin() end
		end)
	end

	local join=ConquestJoinButton
	if join and join.HookScript then
		pcall(join.HookScript,join,"OnEnable",function(self)
			if armed then self:Disable() end
		end)

		-- And it says why in terms of the row you can see.
		--
		-- Blizzard's own reason is computed from what is really selected, which
		-- while a row is lit is the 10v10 they picked -- so hovering a greyed
		-- button under a lit 2v2 explained that rated battlegrounds need ten
		-- players. True of a bracket that is not on screen, which makes it
		-- worse than saying nothing.
		--
		-- After theirs rather than instead of it: this runs on the same
		-- GameTooltip they have just filled, and rewrites it. Theirs is the
		-- right answer again the moment a row is chosen, so this steps aside
		-- with everything else.
		pcall(join.HookScript,join,"OnEnter",function(self)
			if not armed then return end

			local names=ns.BRACKET_NAMES or {}
			GameTooltip:SetOwner(self,"ANCHOR_RIGHT")
			GameTooltip:SetText(L.PREPICK_TIP_TITLE,1,1,1,1,true)
			GameTooltip:AddLine(L.PREPICK_TIP:format(names[armed.id] or "?"),
				nil,nil,nil,true)
			GameTooltip:Show()
		end)
	end
end

----------------------------------------------------------------
-- Hanging it all on Blizzard's panel
----------------------------------------------------------------

local function HookPvPUI()
	if hooked or not PVPQueueFrame then return end
	hooked=true
	PVPQueueFrame:HookScript("OnShow",OnQueueFrameShown)
	HookConquest()

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

-- What the Rated page actually looks like on this client.
--
-- Everything below is a question the plan for pre-selecting a bracket turns
-- on, and none of it can be answered from outside the game: whether Blizzard
-- picks a row for you, whether Join Battle is live before you touch anything,
-- what the selected row is drawn with, and what the button is called.
--
-- Open the PvP panel on Rated, then run it. Nothing here changes anything.
ns.SlashCommands["pvpdump"]=function()
	if not ConquestQueueFrame then
		ns.Print("Rated page not loaded - open the PvP panel first.")
		return
	end

	-- What is selected before anything of ours has run.
	local chosen=ConquestQueueFrame.selectedButton
	ns.Print("selected: %s (id %s)",
		chosen and (chosen:GetName() or "unnamed") or "nothing",
		chosen and tostring(chosen.id) or "-")

	-- Where Join Battle lives, and whether it is already live. If it is, a
	-- pre-selected row that disagrees with it is a wrong queue waiting to
	-- happen, and disabling it is not a nicety but the whole safety of this.
	local names={ "JoinButton", "JoinBattleButton" }
	local join
	for _,field in ipairs(names) do
		if ConquestQueueFrame[field] then join=ConquestQueueFrame[field] break end
	end
	join=join or _G.ConquestQueueFrameJoinButton or _G.ConquestJoinButton

	if join then
		ns.Print("join button: %s, %s",
			join:GetName() or "unnamed",
			(join.IsEnabled and join:IsEnabled()) and "ENABLED" or "disabled")

		-- Buttons take OnEnable in most builds. If this one does, keeping the
		-- button down costs one hook instead of a check every frame.
		local ok=pcall(join.HookScript,join,"OnEnable",function() end)
		ns.Print("OnEnable hookable: %s",ok and "yes" or "no")
	else
		ns.Print("join button: NOT FOUND")
	end

	-- What a row carries, so the selected look can be borrowed rather than
	-- guessed at. Textures only, and named, since that is what a highlight is.
	local row=ConquestQueueFrame.Arena3v3
	if row then
		local found={}
		for key,value in pairs(row) do
			if type(value)=="table" and value.GetObjectType then
				found[#found+1]=key.." ("..value:GetObjectType()..")"
			end
		end
		table.sort(found)
		ns.Print("Arena3v3 parts: %s",table.concat(found,", "))
	else
		ns.Print("Arena3v3: NOT FOUND")
	end

	-- Their own functions, which are what a hook can hang on.
	local funcs={}
	for name in pairs(_G) do
		if type(name)=="string" and name:find("^Conquest") and type(_G[name])=="function" then
			funcs[#funcs+1]=name
		end
	end
	table.sort(funcs)
	ns.Print("functions: %s",table.concat(funcs,", "))
end
