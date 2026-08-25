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

local function Append(tooltip,resultID)
	calls=calls+1

	if not module.db.enabled then return end
	if not (tooltip and tooltip.AddLine and resultID and C_LFGList) then return end

	local ok,info=pcall(C_LFGList.GetSearchResultInfo,resultID)
	if not (ok and info) then return end

	-- Looked up before a single line is drawn, because a leader who is not on
	-- the ladder should add nothing at all -- not a header over an empty space.
	-- Most listings are that listing: the ladder stops at the Rival cutoff.
	local found=Standing(FullName(info.leaderName))
	if not found then return end
	hits=hits+1

	-- No name on these lines. The client's own "Leader:" line sits directly
	-- above them, and repeating the name would only push the numbers right.
	tooltip:AddLine(" ")
	tooltip:AddLine(L.UNITTIP_HEADER,1,0.82,0)

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
