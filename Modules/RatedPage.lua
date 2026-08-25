local ADDON_NAME, ns = ...
local L = ns.L

-- Rework the Rated page of the PvP panel: the "Best" column becomes your
-- ladder position, coloured by the real title cutoffs, and the wins column
-- shows the season record as wins against losses.
--
-- The rank is the eleventh return of GetPersonalRatedInfo and the record is
-- its fourth and fifth. Nothing here is scraped from the frames, so it does
-- not depend on the panel having been opened before.
local module = ns.RegisterModule("ratedpage",{
	title       = L.RATED_TITLE,
	enableLabel = L.RATED_ENABLE,
	desc        = L.RATED_DESC,
	group       = "arena",
	-- Same window as the PvP panel tweak, so the same page of settings.
	parent      = "pvp",
	defaults    = { enabled=true },
})

-- Row keys on ConquestQueueFrame, and the bracket each one asks about.
local ROWS = {
	{ key="Arena2v2", bracket=1 },
	{ key="Arena3v3", bracket=2 },
	{ key="Arena5v5", bracket=3 },
	{ key="RatedBG",  bracket=4 },
}

local hooked=false

-- The last answer that had a ladder position in it, per bracket. Opening the
-- panel can catch the rated info stale -- no rank, no glow -- and then redraw a
-- moment later once the server replies, which reads as a flicker. Showing the
-- last good numbers until the fresh ones arrive keeps the page still.
local lastGood={}

-- Blizzard leaves the rank and record columns in a small font while the rating
-- beside them is large. Matching the rating reads better and keeps the three
-- columns level.
local VALUE_FONT = "GameFontNormalLarge"

-- Blizzard rewrites their own strings on every one of the many redraws a
-- single open provokes -- 25 passes was the measured case -- so overwriting
-- theirs afterwards means redrawing 25 times and hoping none of it lands on
-- screen. Instead their two strings are hidden once and ours are drawn in the
-- same places. They can then update as often as they like against nothing
-- visible, and ours change only when the numbers do.
local ours = setmetatable({},{ __mode="k" })

local function Ours(row)
	local set=ours[row]
	if set then return set end

	set={}
	if row.BestRating and row.BestLabel then
		row.BestRating:Hide()
		set.rank=row:CreateFontString(nil,"OVERLAY",VALUE_FONT)
		set.rank:SetPoint("TOP",row.BestLabel,"BOTTOM",0,-2)
	end
	if row.Wins and row.WinsLabel then
		row.Wins:Hide()
		set.record=row:CreateFontString(nil,"OVERLAY",VALUE_FONT)
		set.record:SetPoint("TOP",row.WinsLabel,"BOTTOM",0,-2)
	end

	ours[row]=set
	return set
end

-- Their three columns are centred at -40, +28 and +100 across the row, so the
-- neighbours are 68 and 72 apart and a value has about 60 before it starts
-- touching one. A long record -- "152 - 148" -- is what runs out first, so the
-- font steps down until it fits rather than overlapping.
local COLUMN_WIDTH  = 60
local MIN_FONT_SIZE = 9

local function SetValue(fontString,text)
	if not fontString then return end

	-- Blizzard redraws this page many times over for a single open -- 25 passes
	-- with identical numbers was the measured case -- and resetting the font
	-- and re-measuring each time is what made it flicker. If the string
	-- already reads what it should, there is nothing to do. Comparing the text
	-- rather than the data is deliberate: it also catches the passes where
	-- their update has overwritten ours.
	if fontString:GetText()==text then return end

	-- Back to full size first, so a shorter value later grows again.
	fontString:SetFontObject(VALUE_FONT)
	fontString:SetText(text)

	local file,size,flags=fontString:GetFont()
	if not file then return end

	while size>MIN_FONT_SIZE and fontString:GetStringWidth()>COLUMN_WIDTH do
		size=size-1
		fontString:SetFont(file,size,flags)
	end
end

----------------------------------------------------------------
-- The glow behind the rank
----------------------------------------------------------------

-- The glow itself lives in the core, since the cutoffs box wants the same one
-- at a fifth of the size. Only the measurements are decided here.
local function SetGlow(row,anchorTo,hex)
	local height=math.max(32,(row:GetHeight() or 46)-6)
	ns.SetGlow(row,anchorTo,hex,{ height=height, y=8 })
end

----------------------------------------------------------------
-- Filling a row
----------------------------------------------------------------

local function UpdateRow(row,bracket)
	if not row or not GetPersonalRatedInfo then return end

	local rating,_,_,played,won=GetPersonalRatedInfo(bracket)
	-- Assigned before converting: select returns everything from the eleventh
	-- value on, and tonumber would take the twelfth -- the team size -- as a
	-- number base, which blows up when it is 0.
	local ranking=select(11,GetPersonalRatedInfo(bracket))
	ranking=tonumber(ranking)

	rating,played,won=tonumber(rating) or 0,tonumber(played) or 0,tonumber(won) or 0

	-- The server hands back a ladder position for brackets never played, which
	-- is a place on a ladder you are not on. If the record reads "-", so should
	-- the rank.
	if played<=0 then ranking=nil end

	if ranking and ranking>0 then
		lastGood[bracket]={ ranking=ranking, rating=rating, played=played, won=won }
	else
		-- Nothing yet this time round: keep showing what was there rather than
		-- blanking the row while the server catches up.
		local kept=lastGood[bracket]
		if kept then
			ranking,rating,played,won=kept.ranking,kept.rating,kept.played,kept.won
		end
	end

	if row.BestLabel then row.BestLabel:SetText(L.RATED_RANK_LABEL) end
	if row.WinsLabel then row.WinsLabel:SetText(L.RATED_WINS_LABEL) end

	local set=Ours(row)

	if ranking and ranking>0 then
		-- Coloured by the rating that earned the place, not by the place
		-- itself: the cutoffs are ratings.
		SetValue(set.rank,ns.ColouredRating(bracket,rating,ranking))
		SetGlow(row,set.rank,ns.TierHex(bracket,rating))
	else
		SetValue(set.rank,L.RATED_NONE)
		SetGlow(row,set.rank,nil)
	end

	-- A bracket never played reads as nothing, not as nothing to nothing.
	if played>0 then
		SetValue(set.record,L.RATED_RECORD:format(won,math.max(0,played-won)))
	else
		SetValue(set.record,L.RATED_NONE)
	end
end

local function UpdateAll()
	if not module.db.enabled then return end
	local frame=ConquestQueueFrame
	if not frame then return end

	for _,row in ipairs(ROWS) do
		UpdateRow(frame[row.key],row.bracket)
	end
end

----------------------------------------------------------------
-- Load
----------------------------------------------------------------

local function HookPvPUI()
	if hooked or not ConquestQueueFrame then return end
	hooked=true

	-- The rows carry a tooltip of weekly and season stats that opens over the
	-- arena history beside the panel.
	--
	-- It is not GameTooltip: ConquestQueueFrameButton_OnEnter fills and shows a
	-- frame of its own called ConquestTooltip, which is why hiding GameTooltip
	-- -- from the row's OnEnter and then from the tooltip itself -- changed
	-- nothing twice over. Hiding it as it shows catches every path to it.
	if ConquestTooltip and ConquestTooltip.HookScript then
		ConquestTooltip:HookScript("OnShow",function(self)
			-- Always, now there is no settings window to say otherwise. It was
			-- a tick, and a tick left off in somebody's saved variables would
			-- have had no way back on.
			if module.db.enabled then self:Hide() end
		end)
	end

	-- Their update writes the columns, so ours has to run after it. Only text
	-- is rewritten -- no frame is given fields of ours, and nothing protected
	-- is touched, so the Join button is left alone.
	if type(ConquestQueueFrame_Update)=="function" then
		hooksecurefunc("ConquestQueueFrame_Update",UpdateAll)
	end
	-- One ask on open. Asking repeatedly only multiplies the redraws: the
	-- numbers were already correct on the very first pass.
	ConquestQueueFrame:HookScript("OnShow",function()
		if RequestRatedInfo then RequestRatedInfo() end
		UpdateAll()
	end)

	UpdateAll()
end

local watcher=CreateFrame("Frame")
watcher:SetScript("OnEvent",function(self,event,name)
	if event=="ADDON_LOADED" then
		if name=="Blizzard_PVPUI" then
			HookPvPUI()
			self:UnregisterEvent("ADDON_LOADED")
		end
		return
	end

	-- Ratings changed while the page is open.
	if ConquestQueueFrame and ConquestQueueFrame:IsVisible() then UpdateAll() end
end)

function module:OnEnable()
	if ns.IsAddOnLoaded("Blizzard_PVPUI") then
		HookPvPUI()
	else
		watcher:RegisterEvent("ADDON_LOADED")
	end
	watcher:RegisterEvent("PVP_RATED_STATS_UPDATE")

	-- Ask early so the numbers are already in hand the first time the panel is
	-- opened, rather than arriving just after it is drawn.
	if RequestRatedInfo then RequestRatedInfo() end
end
