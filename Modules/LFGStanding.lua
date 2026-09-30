local ADDON_NAME, ns = ...
local L = ns.L

-- Where a listed group's leader stands on the ladder, on the group finder's own
-- tooltip.
--
-- "LF 3s 2.2k exp" is a claim, and the person making it is named right there.
-- This answers what anybody reading that listing wants to know: what have they
-- actually done this season.
--
-- The client shows a little of this already -- one line with the leader's
-- rating in the activity's own bracket, for rated activities only. What it does
-- not show is their place on the ladder, or their other brackets.
--
-- The leader and nobody else. The search results can name the rest of the group
-- -- GetSearchResultPlayerInfo carries a name field -- and listing all of them
-- was written and then taken back out: a listing is one person's advertisement,
-- and their record is what it is asking to be judged on. Four lines under the
-- "Leader:" line the client already draws, rather than twenty under nothing in
-- particular.
local module = ns.RegisterModule("lfgstanding",{
	title       = L.LFG_TITLE,
	enableLabel = L.LFG_ENABLE,
	desc        = L.LFG_DESC,
	group       = "arena",
	defaults    = { enabled=true },
})

local BRACKETS = ns.BRACKET_NAMES

-- Counted so the diagnostic can tell three failures apart that look identical
-- on screen: never hooked, hooked but never called, called but the leader is
-- not on the ladder.
local calls,hits,how=0,0,"not hooked"

----------------------------------------------------------------
-- Who is being looked at
----------------------------------------------------------------

-- A name as the ladder spells it.
--
-- The finder gives "Name-Realm" for anyone from another realm and a bare name
-- for its own -- the same shape UnitName answers in, so the same rule applies:
-- attach our realm when none is given, since a bare name only resolves while it
-- happens to be unique.
local function FullName(name)
	if not (name and name~="") then return nil end
	if name:find("-",1,true) then return name end

	local realm=GetRealmName and GetRealmName()
	if realm and realm~="" then return name.."-"..realm end

	return name
end

-- What they have done, in every bracket the ladder has them in.
local function Standing(full)
	if not (full and ns.LadderEntry) then return nil end

	local out
	for bracket=1,4 do
		local entry=ns.LadderEntry(bracket,full)
		if entry then
			out=out or {}
			out[#out+1]={ bracket=bracket, entry=entry }
		end
	end

	return out
end

----------------------------------------------------------------
-- Drawing it
----------------------------------------------------------------

-- The leader's spec, on our own header.
--
-- It sat on the client's "Leader:" line first, which put it beside the name --
-- the same place SocialPlus draws one in the friends list. Beside a name in a
-- list of names it reads as an attribute of the person; here, on a tooltip that
-- has just said who the leader is, it read as clutter on somebody else's line.
--
-- On the header it captions the block instead: this is their standing, and this
-- is what they play. It also stops the code reaching into Blizzard's lines to
-- find a name, which was the fragile part -- the finder draws a different
-- number of them depending on the activity, whether the group is rated and
-- whether it has a comment.
--
-- The icon comes from ArenaPlusAPI.GetSpecIcon rather than from
-- GetSpecializationInfoByID, because this client answers some specs with art
-- from a later version of the game and that function already knows which ones.
-- Asking the API directly draws a protection paladin as something else, quietly.
local ICON = "|T%s:14:14:0:0:64:64:5:59:5:59|t"

-- The block itself, under whatever the tooltip already says: a gap, the header
-- with their spec, and a line per bracket. Shared by the group finder and the
-- guild roster below, so a standing reads the same in both.
local function AddStanding(tooltip,found)
	tooltip:AddLine(" ")

	-- Any bracket's row will do: they are the same character, so they carry the
	-- same spec. Where the ladder has no spec for them the header is drawn plain
	-- rather than with a gap where an icon would have been.
	local icon=ArenaPlusAPI and ArenaPlusAPI.GetSpecIcon
		and ArenaPlusAPI.GetSpecIcon(found[1] and found[1].entry)

	tooltip:AddLine(icon and (L.UNITTIP_HEADER.."  "..ICON:format(icon))
		or L.UNITTIP_HEADER,1,0.82,0)

	for _,row in ipairs(found) do
		-- The same tier colour the ladder, the cutoffs and the player tooltip
		-- use, so a rating means one thing wherever it is read.
		local hex=(ns.RankHex and ns.RankHex(row.bracket,row.entry)) or "ffffff"

		tooltip:AddLine(L.UNITTIP_LINE:format(
			BRACKETS[row.bracket] or "?",hex,row.entry.rating or 0,row.entry.rank or 0),
			0.8,0.8,0.8)
	end

	tooltip:Show()
end

local function Append(tooltip,resultID)
	calls=calls+1

	if not module.db.enabled then return end
	if not (tooltip and tooltip.AddLine and resultID and C_LFGList) then return end

	local ok,info=pcall(C_LFGList.GetSearchResultInfo,resultID)
	if not (ok and info) then return end

	-- Looked up before a single line is drawn, because a leader who is not on
	-- the ladder should add nothing at all -- not a header over an empty space.
	-- Most listings are that listing: the ladder stops at the Rival cutoff.
	--
	-- No name on the block's lines. The client's own "Leader:" line sits
	-- directly above them, and repeating the name would only push the numbers
	-- right.
	local found=Standing(FullName(info.leaderName))
	if not found then return end
	hits=hits+1

	AddStanding(tooltip,found)
end

function module:OnEnable()
	-- The finder builds its tooltip in one function, so one post-hook reaches
	-- every listing in every category -- arenas, battlegrounds, world PvP and
	-- custom alike -- without knowing how the categories are numbered.
	--
	-- Nothing is filtered to the PvP ones. A dungeon group's leader is not on an
	-- arena ladder, so the block simply does not appear there; a category test
	-- would be one more thing to keep in step with Blizzard for no visible
	-- difference.
	local function Hook(why)
		hooksecurefunc("LFGListUtil_SetSearchEntryTooltip",Append)
		how=why
	end

	if LFGListUtil_SetSearchEntryTooltip then
		Hook("LFGListUtil_SetSearchEntryTooltip")
		return
	end

	-- Loaded on demand, like the auction house: the group finder's files need
	-- not be there when this runs.
	local waiting=CreateFrame("Frame")
	waiting:RegisterEvent("ADDON_LOADED")
	waiting:SetScript("OnEvent",function(self)
		if not LFGListUtil_SetSearchEntryTooltip then return end
		Hook("LFGListUtil_SetSearchEntryTooltip, once the group finder loaded")
		self:UnregisterEvent("ADDON_LOADED")
	end)

	how="waiting for the group finder to load"
end

-- Which way it hooked, whether that hook has fired, and what a name resolves
-- to. Those failures look the same on screen and only the last is about the
-- data.
--
--   open the group finder, hover a listing, then: /arena lfg
ns.SlashCommands["lfg"]=function(argument)
	ns.Print("hooked via: %s",how)
	ns.Print("  LFGListUtil_SetSearchEntryTooltip: %s   C_LFGList: %s",
		LFGListUtil_SetSearchEntryTooltip and "yes" or "no",
		C_LFGList and "yes" or "no")
	ns.Print("  called %d time(s), of which %d found the leader on the ladder.",calls,hits)

	local wanted=(argument or ""):match("^%s*(.-)%s*$")
	if wanted=="" then return end

	local full=FullName(wanted)
	local rows=Standing(full)
	if not rows then
		ns.Print("  \"%s\": nothing",full or wanted)
		return
	end

	for _,row in ipairs(rows) do
		ns.Print("  \"%s\" %s: #%d rating %d",
			full,BRACKETS[row.bracket],row.entry.rank or 0,row.entry.rating or 0)
	end
end

----------------------------------------------------------------
-- The guild roster
----------------------------------------------------------------

-- The same block for a guild member, when the pointer is on their row -- a
-- guildmate's claim is judged the same way as a stranger's listing.
--
-- There are two guild windows. Mists always opens the Communities one; the
-- Anniversary client opens it too, unless its "useClassicGuildUI" setting
-- brings back the old guild tab in the Friends window. Both are hooked, and the
-- one never opened costs nothing.
--
-- The Communities roster draws a tooltip of its own only when a name, rank,
-- note or zone is cut short, so in the full roster view most rows have none.
-- For a member on the ladder one is started with their name; for anyone else,
-- the row stays as Blizzard left it.
local guild = ns.RegisterModule("guildstanding",{
	title       = L.GUILDSTANDING_TITLE,
	enableLabel = L.GUILDSTANDING_ENABLE,
	desc        = L.GUILDSTANDING_DESC,
	group       = "arena",
	defaults    = { enabled=true },
})

local guildCalls,guildHits=0,0
local communitiesHooked,tabHooked=false,false

-- The row's tooltip moved out beside the guild window: past its right edge and
-- whatever sticks out of it there (the Communities window's side tabs), level
-- with the row. Blizzard puts it over the top of the window, where it hides
-- the list being read. Where the screen has no room on the right, it goes to
-- the window's left instead.
--
-- Worked in screen pixels, since the window, its tabs, the row and the tooltip
-- can each carry a scale of their own.
local function PlaceBeside(row,window,edges)
	if not (window and window.GetRight and window:GetRight() and row:GetTop()) then return end

	local right=window:GetRight()*window:GetEffectiveScale()
	for _,edge in ipairs(edges or {}) do
		if edge and edge:IsShown() and edge:GetRight() then
			right=math.max(right,edge:GetRight()*edge:GetEffectiveScale())
		end
	end
	local left=window:GetLeft()*window:GetEffectiveScale()
	local top=row:GetTop()*row:GetEffectiveScale()

	local scale=GameTooltip:GetEffectiveScale()
	local width=GameTooltip:GetWidth()*scale
	local screen=UIParent:GetWidth()*UIParent:GetEffectiveScale()
	local gap=4*scale

	-- Blizzard's tooltip is anchored to the row, and would go back there the
	-- next time it lays itself out.
	if GameTooltip.SetAnchorType then GameTooltip:SetAnchorType("ANCHOR_NONE") end
	GameTooltip:ClearAllPoints()
	if right+gap+width<=screen then
		GameTooltip:SetPoint("TOPLEFT",UIParent,"BOTTOMLEFT",(right+gap)/scale,top/scale)
	else
		GameTooltip:SetPoint("TOPRIGHT",UIParent,"BOTTOMLEFT",(left-gap)/scale,top/scale)
	end
end

-- Their standing on the row's tooltip, starting one when the row has none, and
-- the tooltip -- theirs or Blizzard's -- put beside the window by `place`.
local function ShowMember(owner,name,place)
	guildCalls=guildCalls+1
	if not guild.db.enabled then return end

	local found=Standing(FullName(name))
	if found then
		guildHits=guildHits+1
		if not (GameTooltip:GetOwner()==owner and GameTooltip:IsShown()) then
			GameTooltip:SetOwner(owner,"ANCHOR_NONE")
			GameTooltip:AddLine(name,1,1,1)
		end
		AddStanding(GameTooltip,found)
	end

	if place and GameTooltip:GetOwner()==owner and GameTooltip:IsShown() then place(owner) end
end

-- Whether a frame sits inside another, so a row from some other list that uses
-- the same template is left where Blizzard puts its tooltip.
local function Inside(frame,window)
	while frame do
		if frame==window then return true end
		frame=frame.GetParent and frame:GetParent()
	end
	return false
end

-- The Communities window's rows. Each row copies the mixin's OnEnter as it is
-- made, so the mixin is hooked for the rows still to come and any row already
-- made is hooked on its own.
local function HookCommunities()
	if communitiesHooked or not CommunitiesMemberListEntryMixin then return communitiesHooked end

	local function Place(row)
		local window=CommunitiesFrame
		if not (window and Inside(row,window)) then return end
		PlaceBeside(row,window,{ window.ChatTab,window.RosterTab,window.GuildBenefitsTab,window.GuildInfoTab })
	end

	local function OnEnter(self)
		local info=self.GetMemberInfo and self:GetMemberInfo()
		if info and info.name then ShowMember(self,info.name,Place) end
	end

	hooksecurefunc(CommunitiesMemberListEntryMixin,"OnEnter",OnEnter)

	local list=CommunitiesFrame and CommunitiesFrame.MemberList
	local box=list and list.ScrollBox
	if box and box.ForEachFrame then
		pcall(box.ForEachFrame,box,function(row)
			if row.OnEnter then hooksecurefunc(row,"OnEnter",OnEnter) end
		end)
	end

	communitiesHooked=true
	return true
end

-- The old guild tab: two sets of rows (who is online and where, and their
-- guild status), neither with a tooltip of its own. The roster index is on the
-- row, set as the list scrolls.
local function HookGuildTab()
	if tabHooked or not _G.GuildFrameButton1 then return tabHooked end

	local function Place(row)
		if FriendsFrame then PlaceBeside(row,FriendsFrame) end
	end

	local function OnEnter(self)
		if not (self.guildIndex and GetGuildRosterInfo) then return end
		local name=GetGuildRosterInfo(self.guildIndex)
		if name then ShowMember(self,name,Place) end
	end

	local function OnLeave(self)
		if GameTooltip:GetOwner()==self then GameTooltip:Hide() end
	end

	for i=1,(GUILDMEMBERS_TO_DISPLAY or 13) do
		for _,prefix in ipairs({ "GuildFrameButton","GuildFrameGuildStatusButton" }) do
			local row=_G[prefix..i]
			if row then
				row:HookScript("OnEnter",OnEnter)
				row:HookScript("OnLeave",OnLeave)
			end
		end
	end

	tabHooked=true
	return true
end

function guild:OnEnable()
	HookGuildTab()
	HookCommunities()
	if tabHooked and communitiesHooked then return end

	-- Either window can arrive later: the Communities one loads on demand, the
	-- first time it is opened.
	local waiting=CreateFrame("Frame")
	waiting:RegisterEvent("ADDON_LOADED")
	waiting:SetScript("OnEvent",function(self)
		HookGuildTab()
		HookCommunities()
		if tabHooked and communitiesHooked then self:UnregisterEvent("ADDON_LOADED") end
	end)
end

-- Which windows are hooked, whether the hooks have fired, and what a name
-- resolves to.
--
--   open the guild window, point at a member, then: /arena guild [name]
ns.SlashCommands["guild"]=function(argument)
	ns.Print("hooked: Communities roster %s, old guild tab %s",
		communitiesHooked and "yes" or "not yet",tabHooked and "yes" or "not yet")
	ns.Print("  called %d time(s), of which %d found the member on the ladder.",guildCalls,guildHits)

	local wanted=(argument or ""):match("^%s*(.-)%s*$")
	if wanted=="" then return end

	local full=FullName(wanted)
	local rows=Standing(full)
	if not rows then
		ns.Print("  \"%s\": nothing",full or wanted)
		return
	end

	for _,row in ipairs(rows) do
		ns.Print("  \"%s\" %s: #%d rating %d",
			full,BRACKETS[row.bracket],row.entry.rank or 0,row.entry.rating or 0)
	end
end
