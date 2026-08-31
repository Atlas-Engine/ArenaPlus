local ADDON_NAME, ns = ...
local L = ns.L

-- The ladder for whichever bracket the Rated page is showing, down to the last
-- Gladiator place.
--
-- Not a module of its own: it is part of the arena history tweak and is opened
-- from that panel's button, so it exists exactly when that does. It lives in
-- its own file only because the history one is long enough already.
--
-- Reading, never selecting: no rows to click, nothing to configure. Scraped by
-- tools\UpdateLeaderboard.ps1 into Leaderboard.lua, since addons have no
-- network access of their own.

-- Sized and placed exactly like the history window, because it stands in the
-- same spot and the two take turns: swapping between them should look like
-- changing pages rather than one window replacing another.
local ROW_HEIGHT = 18
local WIDTH      = 850
local HEIGHT     = 460
local CONTENT    = 790

-- Columns, as offsets from the left of a row.
local COL_RANK   = 0
-- A row reads left to right: where they stand, what moved, who they are, and
-- what they have done.
--
-- The week's change sits immediately right of the number it belongs to, which
-- is why everything after the rank shifted again -- the rank change was landing
-- on top of the race icon.
local COL_RANK_MOVE = 46
local COL_RACE      = 96
local COL_SPEC      = 116
local COL_NAME      = 138
local COL_REALM     = 324
local COL_RECORD    = 500
local COL_RATING    = 630
local COL_RATE_MOVE = 704

local SPEC_SIZE  = 16

local BRACKET_NAMES = ns.BRACKET_NAMES

-- Drawn right to left from the search box, so the first here ends up rightmost.
-- The labels come from the core, which holds the one spelling of each region.
local REGIONS = { { key="eu" }, { key="us" } }

-- The header row, shared by both windows so they look like one addon.
--
-- HEADER_TOP hangs the 20 point tall controls; HEADER_MID is where their middle
-- falls, and is what the text is levelled against. Anchoring the text by its
-- top instead left every label sitting a couple of points high of the buttons
-- beside it, which reads as sloppy rather than as a mistake.
--
-- BRACKET_X is the same in both windows on purpose: the picker sits in the same
-- place whichever window you opened.
-- A shade larger than the rest of the interface.
--
-- Scaled rather than rebuilt: every offset, font and icon in here is tuned
-- against the others, and nudging thirty numbers to make the text bigger is
-- thirty chances to knock a column out of line. One scale moves the lot and
-- keeps the proportions that already work.
local SCALE = 1.15

local HEADER_TOP = -12
local HEADER_MID = -22

-- The band across the top, and everything measured from the bottom of it.
--
-- The same arrangement as the inspect window, and for the same reason: the
-- column headings, the rule under them and the first row were three separate
-- numbers that happened to sit below the band. Derived, they cannot stop
-- agreeing when the band changes.
local BAND_INSET   = 12
local BAND_HEIGHT  = 52
local COLUMNS_TOP  = -(BAND_INSET+BAND_HEIGHT)        -- the column headings
local DIVIDER_TOP  = COLUMNS_TOP-12                   -- the rule beneath them
local LIST_TOP     = DIVIDER_TOP-6                    -- the scrolling list
local EMPTY_TOP    = DIVIDER_TOP-12                   -- and "nothing to show"
-- Where the button row begins, and it begins late on purpose.
--
-- The heading beside it is "10v10 <flag>  top 5006 players" at its longest, and
-- that runs to about 195 -- so the row starting at 250 was never the constraint
-- it looked like: the first button sat at 250 only until Home was put in front
-- of History and pulled the row back to 182, under the end of the subtitle.
--
-- 208 is as far right as the row can go. Past it the last bracket meets the
-- region flags, which are anchored off the search box at the other end.
local BRACKET_X  = 208

-- History and Home lead the row, in that order: the button that changes window
-- before the one that only changes what you are looking at within it.
local SWAP_W     = 76
local HOME_W     = 60

-- One gap for the whole row, brackets included. It was 8 between Home and
-- History, 6 before 2v2 and 2 between the brackets, which made Home read as
-- something bolted on rather than as the first of six.
local ROW_GAP    = 4

-- The eleven classes, in the order their icons are laid out.
--
-- Written down rather than derived: a spec slug is class-and-spec joined by a
-- hyphen and *both halves can contain one* -- death-knight-frost -- so there is
-- no splitting it without knowing the class names first.
local CLASS_ORDER = {
	"death-knight","druid","hunter","mage","monk","paladin",
	"priest","rogue","shaman","warlock","warrior",
}

local SPEC_ICON_SIZE  = 17
local SPEC_ICON_GAP   = 2    -- between specs of one class
local SPEC_CLASS_GAP  = 11   -- between one class and the next

-- A page of the ladder, rather than all five thousand places at once.
--
-- The list is virtualised, so length costs nothing to draw -- this is not about
-- speed. It is about reach: scrolling to rank three thousand is a long drag,
-- and a page number is a way to get there in one move.
--
-- Search still works across the whole ladder: it finds the match first, then
-- turns to the page holding it.
local PAGE_SIZE = 150

local window
local page = 1
local pageChosen = false  -- true once the buttons have been used
-- Asked for by anything that means "show me this from the top", and
-- honoured by the next Refresh -- which is the first moment the list has
-- the height the new scroll range has to be measured against.
local wantTop = false
local jumpToSelf = false  -- set by the My rank button, cleared once obeyed
local shownBracket        -- which bracket the page number belongs to
local showingAlts = false -- the My alts view, rather than the ladder
local specFilter -- the spec id being shown alone, or nil for all of them
local rows={}    -- the pool, one per visible line rather than one per place
local shown      -- the list the pool is drawing from, and which row is lit
local query=""   -- what is typed in the search box
-- Which of the matching rows to land on, counted from one.
--
-- A name is not unique on a ladder that spans realms: there is a Jaffaar
-- on Ra-den and a Jaffaar on Pagle, and searching found the first and gave
-- no way to reach the second. Enter steps this on, and it wraps.
local searchNth = 1
-- The realm the next search should land on, where something asked for a
-- particular character rather than a name. One-shot: cleared by the refresh
-- that honours it, so Enter cycles freely afterwards.
local wantRealm

----------------------------------------------------------------
-- Reading the data
----------------------------------------------------------------

-- Which region is on screen lives in the core, because the cutoffs box on the
-- Rated page has to agree with it.
local function ViewRegion()
	return ns.ViewRegion()
end

local function Board()
	return ns.ViewLeaderboard()
end

-- Through the core, so the rows arrive with class and spec already joined on
-- from the specs file. Reading the board directly is what left every icon a
-- question mark: the join lived in the index builder, which this never touched.
local function Ladder(bracket)
	return ns.LadderRows(bracket,ViewRegion())
end

-- The class token the game's colour table uses. The scrape stores what the
-- website calls it, which is lower case and hyphenated for death knights and
-- demon hunters.
local function ClassToken(class)
	if not class or class=="" then return nil end
	return (class:upper():gsub("%-",""))
end

-- The game's own stand-in for something it has no art for.
local UNKNOWN_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

-- A player who has hidden their profile. The site publishes their place and
-- their record but no class or spec at all, and writes the missing fields out
-- as the word null -- so that is what a row with nothing behind it looks like.
-- Hidden means the profile was asked for and refused, which the specs file
-- records as 0. A row with no spec merely because nobody has looked it up yet
-- is not hidden, and saying so during the first pass labelled the whole ladder.
local function IsHidden(entry)
	return entry~=nil and entry.hidden==true
end

-- The icon for a scraped row's spec.
--
-- The scrape names the spec rather than numbering it, so it is looked up in the
-- slug table and then through the same two steps the history rows use: this
-- client's own override where it has one, since it answers some specs with art
-- from a later version of the game, and the API otherwise.
--
-- A row the site has no class image for arrives as "null", and every step below
-- simply fails to match it. That ends at a question mark rather than a gap: an
-- empty square reads as a missing icon, and a question mark says the ladder
-- does not know either.
local function SpecIcon(entry)
	-- A numeric id first, which is what your own characters record about
	-- themselves: a character knows its specialisation outright and has no need
	-- of the slug table the ladder rows go through.
	if entry.specID and GetSpecializationInfoByID then
		local _,_,_,icon=GetSpecializationInfoByID(entry.specID)
		if icon then return icon end
	end

	local class,spec=entry.class,entry.spec

	if class and spec and class~="" and spec~="" then
		local id=ns.SPEC_BY_SLUG and ns.SPEC_BY_SLUG[class.."-"..spec]

		if id then
			if ns.SPEC_ICON and ns.SPEC_ICON[id] then return ns.SPEC_ICON[id] end

			if GetSpecializationInfoByID then
				local _,_,_,icon=GetSpecializationInfoByID(id)
				if icon then return icon end
			end
		end
	end

	return UNKNOWN_ICON
end

local function ClassColour(class)
	local token=ClassToken(class)
	local colour=token and RAID_CLASS_COLORS and RAID_CLASS_COLORS[token]
	if colour then return colour.r,colour.g,colour.b end
	return 1,1,1
end

-- The title a place is worth, as the colour the cutoffs box already uses for it.
--
-- Rank one and Gladiator are a fixed number of places, so those are decided by
-- position on the ladder. Duelist is a share of it and has no place count at
-- all, so that one is decided by rating. Both numbers come from the same
-- scrape as the ladder itself.
--
-- Shared, because the arena history marks opponents with their place too and
-- the two should not disagree about what a number is worth.
-- `region` is optional and only the ladder window passes it: a Gladiator cut is
-- a different rating in each region, so colouring EU rows by US numbers would
-- hand out the wrong titles. Everything else omits it and gets the player's own.
function ns.RankHex(bracket,entry,region)
	local slotsBy=region and ns.ViewCutoffSlots(region) or ns.CUTOFF_SLOTS
	local cutoffsBy=region and ns.ViewCutoffs(region) or ns.CUTOFFS

	local slots=slotsBy and slotsBy[bracket]
	local cutoffs=cutoffsBy and cutoffsBy[bracket]
	local rank=entry.rank or 0
	local rating=entry.rating or 0

	-- Walked highest first, taking the colours from the tier list rather than
	-- writing them out again here. Adding Rival to the ladder needed no change
	-- to this at all, which is the point: the hexes lived in two places before
	-- and only one of them knew about a new tier.
	for _,tier in ipairs(ns.TIERS or {}) do
		local places=slots and slots[tier.key]

		if places and places>0 then
			-- Rank one and Gladiator are a fixed number of places, so position
			-- decides them.
			if rank<=places then return tier.hex end
		elseif cutoffs and cutoffs[tier.key] and cutoffs[tier.key]>0 then
			-- Everything below is a share of the ladder with no place count, so
			-- rating decides instead.
			if rating>=cutoffs[tier.key] then return tier.hex end
		end
	end

	return "b3b3b3"
end

-- The spec id behind a scraped row, or nothing where the site had no class for
-- it -- a hidden profile has neither, and so belongs to no spec.
local function EntrySpec(entry)
	if not (entry and ns.SPEC_BY_SLUG) then return nil end
	local class,spec=entry.class,entry.spec
	if not (class and spec) or class=="" or spec=="" or class=="null" then return nil end
	return ns.SPEC_BY_SLUG[class.."-"..spec]
end

-- The ladder narrowed to one spec, for the bracket already being shown.
local function Filtered(list)
	if not specFilter then return list end

	local out={}
	for _,entry in ipairs(list) do
		if EntrySpec(entry)==specFilter then out[#out+1]=entry end
	end
	return out
end

-- Whether a row answers what was typed. The name only: a realm matches
-- hundreds of rows at once, which is the opposite of finding somebody.
local function Searched(entry)
	if query=="" then return false end

	-- A hyphen makes it name-and-realm: "bistwo-pagle" is one character, not
	-- everybody called Bistwo. Character names cannot contain a hyphen, so the
	-- first one is always the separator, and what follows may contain more of
	-- its own -- Ra-den, arugal-au -- which is why the realm half is taken
	-- whole rather than split again.
	--
	-- This narrows and never widens. A realm typed on its own has no hyphen, so
	-- it is read as a name and matches nobody, which keeps the behaviour the
	-- name-only rule was written for: "pagle" must not list everyone on Pagle.
	--
	-- Assigned straight from the match. Putting a guard in front of it with an
	-- `and` would collapse the two captures into one, which is exactly how the
	-- realm went missing in ShowLadderFor.
	local person,realm=query:match("^([^%-]+)%-(.+)$")

	if not person then
		return ((entry.name or ""):lower()):find(query,1,true)~=nil
	end

	if not ((entry.name or ""):lower()):find(person,1,true) then return false end

	-- Punctuation off both sides before they are compared, so a typed "ra-den"
	-- and the ladder's "raden" meet.
	return ns.PlainName(entry.realm or ""):find(ns.PlainName(realm),1,true)~=nil
end

-- Whether a row is you, so it can be picked out of four hundred.
--
-- Name and realm compared separately, both stripped of the punctuation the two
-- sources disagree about: the game says "Ra-den" and the site says "Raden",
-- which quietly rejected every row until it was noticed.
local function IsPlayer(entry)
	local name=UnitName and UnitName("player")
	if not (name and entry.name) then return false end
	if ns.PlainName(entry.name)~=ns.PlainName(name) then return false end

	local realm=GetRealmName and GetRealmName()
	if not (realm and entry.realm and entry.realm~="") then return true end

	return ns.PlainName(entry.realm)==ns.PlainName(realm)
end

----------------------------------------------------------------
-- Your own row, from the client rather than the scrape
----------------------------------------------------------------

-- What the game says about you right now.
--
-- The ladder is a snapshot rebuilt once a day, and the row that looks wrongest
-- is always your own -- because yours is the rating that moved. Seen live:
-- #213 at 1719 in the file against #143 at 1906 in the game, and most of that
-- gap was an evening's play rather than the ladder drifting.
--
-- None of it is scraped. The client knows your rating and, as the eleventh
-- return, your ladder position; the Rated page on the PvP panel has been using
-- exactly this all along, which is why that panel was right while this window
-- was wrong.
local function LiveSelf(bracket)
	if not GetPersonalRatedInfo then return nil end

	local rating,_,_,played,won=GetPersonalRatedInfo(bracket)
	local ranking=select(11,GetPersonalRatedInfo(bracket))

	rating,played,won=tonumber(rating),tonumber(played) or 0,tonumber(won) or 0
	ranking=tonumber(ranking)

	-- No games this season is no position, whatever the other numbers say.
	if played<=0 or not rating or rating<=0 then return nil end

	return rating,(ranking and ranking>0) and ranking or nil,won,played
end

-- Your live standing, for the line under the list.
--
-- Deliberately *not* merged into the rows. Two attempts at that, and each broke
-- a different column: placed by rating the # column read 138, 143, 139; placed
-- by rank the Rating column read 1893, 1892, 1906, 1890. The snapshot's ranks
-- and ratings agree with each other, and a live row agrees with neither, so
-- wherever it is put one of the two columns is lying.
--
-- The list is therefore left exactly as scraped -- internally consistent, and
-- honest about being a day old -- and what the client knows for certain is said
-- once, on its own line, where it contradicts nothing.
local function LiveStanding(bracket)
	if not (ns.ViewingOwnRegion and ns.ViewingOwnRegion()) then return nil end

	local rating,ranking=LiveSelf(bracket)
	if not (rating and ranking) then return nil end

	-- Nothing to say when the list already says it.
	--
	-- This line exists to correct a snapshot that has fallen behind, so when
	-- the snapshot agrees it is not a correction: it is the same two numbers a
	-- second time, three rows under the highlighted row that already has them.
	for _,entry in ipairs(Ladder(bracket)) do
		if IsPlayer(entry) then
			if entry.rank==ranking and entry.rating==rating then return nil end
			break
		end
	end

	local hex=ns.RankHex and ns.RankHex(bracket,{ rank=ranking, rating=rating },ViewRegion())
	hex=hex or "ffffff"
	return L.LADDER_LIVE_SELF:format(hex,ranking,hex,rating)
end

-- "13 minutes ago", from the stamp the companion script wrote.
--
-- That stamp is local time on the machine that ran the script, which is this
-- one -- so it is compared against local time here. If the collector ever moves
-- to a machine in another timezone, this is the line that has to learn about
-- it.
--
-- Falls back to the stamp itself rather than to nothing: a time the reader has
-- to subtract is still better than a blank.
local function Ago(stamp)
	if not stamp or stamp=="" then return "?" end

	local y,mo,d,h,mi,ap=stamp:match("(%d+)-(%d+)-(%d+)%s+(%d+):(%d+)%s*([AP]M)")
	if not y then return stamp:match("(%d+:%d+%s*[AP]?M?)") or stamp end

	h=tonumber(h)
	-- 12 AM is hour 0 and 12 PM is hour 12; every other PM adds twelve.
	if ap=="AM" then
		if h==12 then h=0 end
	elseif h~=12 then
		h=h+12
	end

	local when=time({ year=tonumber(y), month=tonumber(mo), day=tonumber(d),
	                  hour=h, min=tonumber(mi), sec=0 })
	if not when then return stamp end

	local seconds=difftime(time(),when)
	if seconds<0 then return L.LADDER_AGO_NOW end

	local minutes=math.floor(seconds/60)
	if minutes<1  then return L.LADDER_AGO_NOW end
	if minutes<60 then return L.LADDER_AGO_MINUTES:format(minutes) end

	local hours=math.floor(minutes/60)
	if hours==1 then return L.LADDER_AGO_HOUR end
	if hours<24 then return L.LADDER_AGO_HOURS:format(hours) end

	local days=math.floor(hours/24)
	if days==1 then return L.LADDER_AGO_DAY end
	return L.LADDER_AGO_DAYS:format(days)
end

----------------------------------------------------------------
-- Drawing
----------------------------------------------------------------

-- Rows are a small fixed pool that moves with the scroll, not one frame per
-- place on the ladder.
--
-- One frame each meant opening 2v2 built fourteen hundred and fifty two rows of
-- six font strings and two textures apiece -- some twelve thousand objects,
-- made on first open and never given back. Two dozen of them cover the visible
-- area, and the rest of the ladder is just numbers waiting to be pointed at.
-- Blizzard files its race icons by name rather than by the number the API
-- answers with, so the two are joined here. Pandaren answer as three races --
-- neutral, Alliance and Horde -- and share one icon.
local RACE_FILES = {
	[1]="human", [2]="orc", [3]="dwarf", [4]="nightelf", [5]="scourge",
	[6]="tauren", [7]="gnome", [8]="troll", [9]="goblin", [10]="bloodelf",
	[11]="draenei", [22]="worgen", [24]="pandaren", [25]="pandaren", [26]="pandaren",
}

-- The undead are "Scourge" in the API and everywhere else in the game files,
-- and the icon set is the one place they are not: twelve of the thirteen race
-- icons answered to their own name and this one did not. Asked for by both.
local RACE_ALSO = { scourge="undead" }

-- The icon as an atlas, which is how the character sheet draws it.
--
-- Tried and dropped rather than assumed: if this build has no such atlas the
-- texture is simply left empty, because a wrong icon on every row would be
-- worse than none.
local function SetRaceIcon(texture,entry)
	local file=entry and entry.race and RACE_FILES[entry.race]
	if not file then
		texture:SetTexture(nil)
		texture:Hide()
		return
	end

	local sex=(entry.gender==1) and "female" or "male"

	-- Asked for by name before it is set.
	--
	-- SetAtlas does not fail on an atlas the client has never heard of: it
	-- leaves the texture exactly as it was and reports nothing. Rows are pooled
	-- and reused, so a row that had drawn a night elf kept drawing one for the
	-- undead character that came after it -- a wrong answer, which is worse than
	-- an empty square.
	local known=C_Texture and C_Texture.GetAtlasInfo

	local names={}
	for _,who in ipairs({ file, RACE_ALSO[file] }) do
		if who then
			names[#names+1]=("raceicon-%s-%s"):format(who,sex)
			names[#names+1]=("raceicon128-%s-%s"):format(who,sex)
		end
	end

	for _,name in ipairs(names) do
		if texture.SetAtlas and known and C_Texture.GetAtlasInfo(name) then
			texture:SetAtlas(name)
			texture:Show()
			return
		end
	end

	-- Nothing to draw. Cleared rather than left holding the last row's icon.
	texture:SetTexture(nil)
	texture:Hide()
end

-- A week's movement, written the way the sites write it.
--
-- Green is good and red is bad, which is not the same as positive and negative:
-- a rank going from 3485 to 723 reads -2762 and is the best row on the ladder,
-- while a rating going the same direction reads +391.
local function Movement(amount,lowerIsBetter)
	if not amount or amount==0 then return "" end

	local better=(lowerIsBetter and amount<0) or ((not lowerIsBetter) and amount>0)
	local colour=better and "00ff00" or "ff4040"

	-- The sign is always shown, including the plus, so a column of them lines
	-- up and reads as movement rather than as a second rating.
	return ("|cff%s%s%d|r"):format(colour,(amount>0) and "+" or "",amount)
end

-- Your own characters as ladder rows.
--
-- Numbered from one among themselves rather than by where they sit on the
-- ladder: the question this answers is "which of mine is furthest along", and
-- an alt at 1400 has no ladder place to show at all.
--
-- An alt that IS on the ladder is merged with its row, so it keeps its spec
-- icon, race, faction and record. One that is not gets the little the store
-- knows -- name, realm, rating, games -- which is still enough to compare.
local function AltRows(bracket)
	local alts=ns.MyAlts and ns.MyAlts(bracket) or {}
	local out={}

	for _,alt in ipairs(alts) do
		local full=alt.realm and (alt.name.."-"..alt.realm) or alt.name
		local listed=ns.LadderEntry and ns.LadderEntry(bracket,full)

		local row
		if listed then
			-- Copied rather than used directly: the rank is about to be
			-- rewritten, and the ladder's own table must not be edited.
			row={}
			for key,value in pairs(listed) do row[key]=value end
		else
			-- Not on the ladder, which for an alt is the normal case: the
			-- leaderboard stops at the challenger cutoff and most alts are
			-- below it. Everything shown here comes from what the character
			-- recorded about itself the last time it logged in.
			row={
				name  = alt.name,
				realm = alt.realm,
				class  = alt.who and alt.who.class,
				specID = alt.who and alt.who.spec,
				race  = alt.who and alt.who.race,
				gender= alt.who and alt.who.gender,
				-- No won and lost on purpose. The store keeps games played, not
				-- the split, and printing "0/0" for a character with fifty
				-- games states something false rather than admitting a gap.
				played= alt.played,
			}
		end

		-- What the character itself last recorded beats the ladder's copy, for
		-- the same reason the live pass exists.
		row.rating=alt.rating
		row.rank=#out+1
		out[#out+1]=row
	end

	return out
end

local function CreateRow(parent)
	local row=CreateFrame("Frame",nil,parent)
	row:SetHeight(ROW_HEIGHT)
	row:SetPoint("RIGHT",parent,"RIGHT",0,0)

	-- Clicking a row opens what they are wearing and running. Only the top of
	-- each bracket is covered, so the panel says so itself rather than this
	-- guessing and refusing to open.
	row:EnableMouse(true)
	row:SetScript("OnMouseUp",function(self,button)
		if not self.entry then return end

		-- Right-clicking offers the name to copy. Name and realm together,
		-- because the name alone is what makes two people one: there is a
		-- Jaffaar on Ra-den and a Jaffaar on Pagle.
		if button=="RightButton" then
			local who=self.entry.name or ""
			if self.entry.realm and self.entry.realm~="" then
				who=who.."-"..self.entry.realm
			end
			if ns.CopyName then ns.CopyName(who,window) end
			return
		end

		if button~="LeftButton" then return end
		-- The bracket too, so the panel can colour a rating against the right
		-- cutoffs: 2200 is not the same achievement in 2v2 as in rated
		-- battlegrounds.
		-- Asked for at click time rather than captured when the row was made:
		-- rows outlive the bracket they were first drawn for, and the local
		-- named bracket belongs to a different function entirely.
		if ns.ToggleInspect then ns.ToggleInspect(self.entry,ViewRegion(),ns.ViewBracket()) end
	end)

	row:SetScript("OnEnter",function(self)
		if self.highlight and not self.highlight:IsShown() then
			self.hover=true
			self.highlight:SetColorTexture(1,1,1,0.08)
			self.highlight:Show()
		end

		-- What the right button does, since the left one's job -- opening the
		-- inspect panel -- is the obvious one and this is not.
		if self.entry then
			GameTooltip:SetOwner(self,"ANCHOR_RIGHT")
			GameTooltip:SetText(L.COPY_HINT,1,1,1,1,true)
			GameTooltip:Show()
		end
	end)

	row:SetScript("OnLeave",function(self)
		GameTooltip:Hide()
		if self.hover then
			self.hover=nil
			self.highlight:Hide()
			-- Back to the colour that marks your own place, which this borrowed.
			self.highlight:SetColorTexture(1,0.82,0,0.22)
		end
	end)

	-- Every other row, a shade darker.
	--
	-- Four hundred rows of identical dark background is hard to read across:
	-- the eye loses the line somewhere around the rating column and comes back
	-- on the wrong one. Retail stripes its lists for the same reason. Kept very
	-- faint -- this should be felt rather than seen.
	row.stripe=row:CreateTexture(nil,"BACKGROUND",nil,-8)
	row.stripe:SetAllPoints()
	row.stripe:SetColorTexture(1,1,1,0.025)
	row.stripe:Hide()

	-- Behind the text, for marking your own place. Above the stripe, so a
	-- striped row that is also yours reads as yours.
	row.highlight=row:CreateTexture(nil,"BACKGROUND",nil,-7)
	row.highlight:SetAllPoints()
	row.highlight:SetColorTexture(1,0.82,0,0.22)
	row.highlight:Hide()

	local function Label(x,width,justify,font)
		local text=row:CreateFontString(nil,"OVERLAY",font or "GameFontHighlightSmall")
		text:SetPoint("LEFT",row,"LEFT",x,0)
		text:SetWidth(width)
		text:SetJustifyH(justify or "LEFT")
		return text
	end

	row.race=row:CreateTexture(nil,"ARTWORK")
	row.race:SetSize(SPEC_SIZE,SPEC_SIZE)
	row.race:SetPoint("LEFT",row,"LEFT",COL_RACE,0)

	row.spec=row:CreateTexture(nil,"ARTWORK")
	row.spec:SetSize(SPEC_SIZE,SPEC_SIZE)
	row.spec:SetPoint("LEFT",row,"LEFT",COL_SPEC,0)
	-- The icons come with a border baked in that reads as a grid at this size.
	row.spec:SetTexCoord(0.07,0.93,0.07,0.93)

	row.rank   = Label(COL_RANK,44,"RIGHT")

	-- What the week did, beside the number it happened to. Coloured by whether
	-- it was good news, not by the sign: climbing the ladder makes the rank
	-- number smaller, so -2762 is the best thing on the row.
	row.rankMove   = Label(COL_RANK_MOVE,46,"LEFT","GameFontNormalSmall")
	row.ratingMove = Label(COL_RATE_MOVE,56,"LEFT","GameFontNormalSmall")
	row.name   = Label(COL_NAME,180)
	row.realm  = Label(COL_REALM,170)
	row.record = Label(COL_RECORD,120)
	row.rating = Label(COL_RATING,70,"RIGHT")

	row.realm:SetTextColor(0.55,0.55,0.55)

	return row
end

-- Point the pool at whatever the scroll is currently over.
--
-- Called on every scroll as well as on a refresh, so it does no thinking: the
-- list, the bracket and the lit row were all worked out once and kept.
local function Layout()
	if not (window and window:IsShown() and shown) then return end

	local list,bracket,focus=shown.list,shown.bracket,shown.focus
	local scroll=window.scroll:GetVerticalScroll() or 0
	local height=window.scroll:GetHeight() or 0

	-- One row above the top edge, so a part-scrolled row is drawn rather than
	-- appearing when it becomes whole.
	local first=math.max(1,math.floor(scroll/ROW_HEIGHT))
	local visible=math.ceil(height/ROW_HEIGHT)+2

	for slot=1,visible do
		local index=first+slot-1
		local row=rows[slot]

		if not row then
			row=CreateRow(window.content)
			rows[slot]=row
		end

		local entry=list[index]
		if not entry then
			row:Hide()
		else
			-- Placed by which entry it is showing, not by which slot it is, so
			-- the pool can sit anywhere in the ladder.
			row:ClearAllPoints()
			row:SetPoint("TOPLEFT",window.content,"TOPLEFT",0,-(index-1)*ROW_HEIGHT)
			row:SetPoint("RIGHT",window.content,"RIGHT",0,0)

			-- One colour for the row's two numbers, so the place and the rating
			-- always agree about which title is being described.
			--
			-- Worked out differently in the two views, and it has to be. On the
			-- ladder a place IS the title -- the top 31 are rank one however
			-- close the ratings are -- so the slots decide it. Among your alts
			-- the number is only an index, your best of three being "#1", and
			-- reading it as a place would award rank one to a 1400 rating. So
			-- there the rating decides, against the cutoffs.
			local hex=showingAlts and ns.TierHex(bracket,entry.rating or 0)
				or ns.RankHex(bracket,entry,ViewRegion())

			row.rank:SetText(("|cff%s#%d|r"):format(hex,entry.rank or 0))

			-- Said outright, so a question mark beside an uncoloured name reads
			-- as a choice that player made rather than as missing data.
			local name=entry.name or "?"
			if IsHidden(entry) then name=name..L.LADDER_HIDDEN end

			row.name:SetText(name)
			row.name:SetTextColor(ClassColour(entry.class))

			SetRaceIcon(row.race,entry)
			row.spec:SetTexture(SpecIcon(entry))
			row.realm:SetText(entry.realm or "")
			-- The split where it is known, the total where only that is.
			if entry.won or entry.lost then
				row.record:SetText(L.HISTORY_RECORD:format(entry.won or 0,entry.lost or 0))
			elseif entry.played and entry.played>0 then
				row.record:SetText(L.LADDER_PLAYED:format(entry.played))
			else
				row.record:SetText("")
			end
			row.rating:SetText(("|cff%s%d|r"):format(hex,entry.rating or 0))

			-- Only where there is a week to compare against: a character who
			-- was not on the ladder last week has no change, which is different
			-- from a change of zero.
			row.rankMove:SetText(Movement(entry.dk,true))
			row.ratingMove:SetText(Movement(entry.dr,false))

			-- Every other one, counted by where it sits on screen rather than by
			-- its rank: the stripes should stay put while paging, not shuffle
			-- because page two happens to start on an odd number.
			row.stripe:SetShown(index%2==0)

			-- One row, never several. Nothing at all while a search matches
			-- nothing yet: your own row left lit through it reads as a hit.
			row.highlight:SetShown(index==focus)

			-- Kept on the row so the click handler reads what is under the
			-- cursor now, not what was there when the handler was written: the
			-- pool reuses rows as the list is filtered and paged.
			row.entry=entry
			row:Show()
		end
	end

	-- Anything the pool grew to on a taller window and no longer needs.
	for slot=visible+1,#rows do rows[slot]:Hide() end
end

ns.LayoutLadder=Layout

local function Refresh()
	-- Only while it is up. This is called from the history panel's own redraw so
	-- that switching brackets on the Rated page changes what the ladder shows,
	-- and there is nothing to change while it is closed.
	if not (window and window:IsShown()) then return end

	local bracket=ns.ViewBracket()

	-- A new bracket is a new list, so page five of the old one means nothing in
	-- it. Noticed here rather than hooked onto the bracket buttons, because the
	-- bracket also changes from the Rated page and from the history window, and
	-- only one of those three was ever going to get remembered.
	if bracket~=shownBracket then
		shownBracket=bracket
		page=1
		pageChosen=false
	end

	-- Your characters, or everybody's.
	local full
	if showingAlts then
		full=AltRows(bracket)
	else
		full=Filtered(Ladder(bracket))
	end

	-- Found in the whole ladder before it is cut into pages, so a search can
	-- reach somebody who is not on the page you happen to be looking at.
	-- The row the search is pointing at, and how many it could have pointed at.
	--
	-- Every match is collected rather than stopping at the first, because the
	-- first is not always the one wanted: same name, different realm. searchNth
	-- picks among them and Enter moves it on.
	local hit,matchCount
	if query~="" then
		local matches
		for index,entry in ipairs(full) do
			if Searched(entry) then
				matches=matches or {}
				matches[#matches+1]=index
			end
		end

		if matches then
			matchCount=#matches

			-- A realm was asked for, so land on that character rather than on
			-- whichever of the name-alikes happens to come first.
			--
			-- This is what sent a click on Bistwo-Pagle's rank to a Bistwo on
			-- another realm: the rank link searches the bare name, because the
			-- ladder matches on names and "Bistwo-Pagle" would match nothing,
			-- and the bare name found the wrong one.
			local pick
			if wantRealm then
				for position,index in ipairs(matches) do
					if ns.PlainName(full[index].realm or "")==wantRealm then
						pick=position
						break
					end
				end
				-- One-shot either way. Not on the ladder at all is an answer,
				-- and holding it would bend every later search too.
				wantRealm=nil
			end

			-- Wrapped, so Enter on the last match comes back round to the first
			-- rather than stopping at an end nothing announces. Taken modulo the
			-- count on every pass, so a counter left high by a longer search still
			-- lands somewhere real when the query narrows.
			hit=matches[pick or (((searchNth-1)%matchCount)+1)]
		end
	end

	-- Your own place, found whether or not anything is about to jump to it: the
	-- row is lit wherever it falls, and the My rank button needs to know
	-- whether there is anywhere to go.
	local mine
	for index,entry in ipairs(full) do
		if IsPlayer(entry) then mine=index break end
	end

	local pages=math.max(1,math.ceil(#full/PAGE_SIZE))

	-- Opens at the top of the ladder. Rank one is what a leaderboard is for, and
	-- your own place is a button away rather than where it always begins.
	--
	-- A search still turns to its match, unless a page was chosen by hand --
	-- otherwise every refresh dragged the view back and the next button
	-- appeared to do nothing.
	local goingToSelf=(jumpToSelf and mine)
	if hit and not pageChosen then
		page=math.ceil(hit/PAGE_SIZE)
	elseif goingToSelf then
		page=math.ceil(mine/PAGE_SIZE)
	end
	jumpToSelf=false
	page=math.max(1,math.min(page,pages))

	local first=(page-1)*PAGE_SIZE
	local list={}
	for index=first+1,math.min(first+PAGE_SIZE,#full) do
		list[#list+1]=full[index]
	end

	window.title:SetText((showingAlts and L.LADDER_TITLE_ALTS or L.LADDER_TITLE)
		:format(BRACKET_NAMES[bracket] or "?")
		..L.REGION_TAG:format((ns.RegionFlagMarkup and ns.RegionFlagMarkup(ViewRegion(),12))
			or ns.RegionShort(ViewRegion())))
	window.subtitle:SetText(#full>0
		and (showingAlts and L.LADDER_SUBTITLE_ALTS or L.LADDER_SUBTITLE):format(#full)
		or "")
	-- Said outright when there is nothing to show, rather than an empty window
	-- that reads as a fault. "No alts in this bracket" and "no ladder" are
	-- different sentences.
	window.empty:SetShown(#full==0)
	if #full==0 then
		window.empty:SetText(showingAlts and L.LADDER_NO_ALTS or L.LADDER_EMPTY)
	end

	if window.pageLabel then
		window.pageLabel:SetText(L.LADDER_PAGE:format(page,pages))
		-- Enable/Disable rather than SetEnabled: the same reason the region
		-- buttons use them, namely that SetEnabled is not on every build here
		-- and would fail without saying so.
		local back,forward=page>1,page<pages
		if back then window.pagePrev:Enable() else window.pagePrev:Disable() end
		if back then window.pageFirst:Enable() else window.pageFirst:Disable() end
		if forward then window.pageNext:Enable() else window.pageNext:Disable() end
		if forward then window.pageLast:Enable() else window.pageLast:Disable() end
	end

	if window.source then
		local board=Board()
		-- Blizzard's own build time, not ours.
		--
		-- The two differ by more than anyone expects: measured at nearly two
		-- hours, and a rating that moved inside that window is in no version of
		-- this file, however often the task runs. Showing when we read it made
		-- the data look fresher than it is and turned Blizzard's lag into an
		-- apparent fault in the addon.
		-- Times only, not dates. Both stamps are almost always today, and the
		-- full form ran into the buttons at the other end of the line.
		local read
		local snapshot=board and board.snapshot and board.snapshot:match("(%d%d:%d%d)$")
		if snapshot then
			read=L.CUTOFF_SOURCE_SNAPSHOT:format(snapshot,Ago(board.checked))
		else
			read=L.CUTOFF_SOURCE:format((board and board.checked) or "?")
		end

		-- The one number in this window the client can vouch for, beside the
		-- date that says how old everything else is.
		local standing=LiveStanding(bracket)
		if standing then read=read..standing end

		window.source:SetText(read)
	end

	for _,button in ipairs(window.specs or {}) do
		local chosen=specFilter==button.spec
		button.lit:SetShown(chosen)
		-- The rest fade back while one is chosen, so the row says at a glance
		-- that it is filtered.
		button.icon:SetAlpha((not specFilter or chosen) and 1 or 0.35)
	end

	if window.UpdateBrackets then window.UpdateBrackets() end

	-- The one being shown is the dead one; the other is pressable.
	for _,button in ipairs(window.regions or {}) do
		local active=button.region==ViewRegion()

		-- Enable and Disable rather than SetEnabled, which is not on every
		-- build of this client and would fail without saying so.
		if active then button:Disable() else button:Enable() end

		-- A disabled button greys its label, which reads as unavailable rather
		-- than as the one you are looking at, so the colour is put back: gold
		-- for the region on screen, plain for the one you can switch to.
		local label=button.GetFontString and button:GetFontString()
		if label then
			if active then
				-- The same gold the headings use for the region, so the button
				-- and the two titles are visibly saying one thing.
				label:SetTextColor(1,0.82,0)
			else
				label:SetTextColor(0.6,0.6,0.6)
			end
		end
	end

	-- Which single row is the one being looked at: the first the search matches,
	-- or your own place when nothing is typed.
	--
	-- Worked out before the rows are drawn so exactly one can be lit. Lighting
	-- every match meant typing one letter lit a dozen people, which says
	-- nothing -- the point is to be shown somebody.
	-- The same row again, as a position on this page.
	local focus
	-- Lit wherever it falls: the search match if there is one, otherwise your
	-- own row.
	local target=hit or mine
	if target and target>first and target<=first+PAGE_SIZE then focus=target-first end

	-- Scrolled to only when something asked for it -- a search, or the My rank
	-- button. Otherwise the window opens at the top of the ladder, which is
	-- what a leaderboard is for. Lighting your row and scrolling to it are two
	-- different things, and only the second should need asking for.
	local centre
	local wanted=hit or (goingToSelf and mine)
	if wanted and wanted>first and wanted<=first+PAGE_SIZE then centre=wanted-first end

	if window.mineButton then
		if mine then window.mineButton:Enable() else window.mineButton:Disable() end
	end

	-- The chosen region's flag in colour and the other drained, redone on every
	-- refresh rather than only when a button is clicked: the region can also be
	-- changed from the Rated page, and a flag left lit for a ladder nobody is
	-- looking at is worse than no marking at all.
	for _,button in ipairs(window.regions or {}) do
		if button.flag then
			ns.LightRegionFlag(button.flag,button.region==ViewRegion())
		end
	end

	-- What the rows are drawing from, kept for the scroll handler: it repaints
	-- as you move without any of this being worked out again.
	shown={ list=list, bracket=bracket, focus=focus, centre=centre }

	-- The scroll bar still needs to believe the whole ladder is there, so the
	-- content keeps its full height even though only a screenful exists.
	window.content:SetHeight(math.max(1,#list*ROW_HEIGHT))

	-- Back to the top, the scroll bar included.
	--
	-- Every caller above already did SetVerticalScroll(0), and every one of them
	-- was quietly undone. The scroll frame moves at once, so the rows redraw at
	-- the top and it looks right; the bar only hears about it from
	-- OnScrollRangeChanged a frame later, still holding its old value, and puts
	-- the list straight back. Turning from page 2 to page 1 left the ladder
	-- showing #132 under a header reading "page 1 of 5".
	--
	-- It also has to happen here rather than at the callers, because the list
	-- only takes the new page's height on the line above -- a range set before
	-- that is the old page's.
	--
	-- Not when something asked to be centred: My rank resets the scroll and then
	-- wants Refresh to find your row, and returning here would strand it at the
	-- top of the ladder instead.
	if wantTop and not centre then
		wantTop=false

		window.scroll:UpdateScrollChildRect()
		local range=window.scroll:GetVerticalScrollRange() or 0

		local bar=window.scroll.ScrollBar
		if not bar then
			local barName=window.scroll:GetName()
			bar=barName and _G[barName.."ScrollBar"] or nil
		end

		if bar then
			bar:SetMinMaxValues(0,range)
			bar:SetValue(0)
		end

		window.scroll:SetVerticalScroll(0)
		return Layout()
	end

	-- Opened on your own place, and at the top where you have none.
	--
	-- Finding yourself is the first thing anybody does with a leaderboard, and
	-- two thousand rows is a long way to scroll to do it by hand. Done on every
	-- refresh rather than only on opening, so switching bracket lands on your
	-- place in the new one too. A search takes over that job: the same
	-- centring, on somebody else.
	--
	-- Half a name matches nothing yet, and staying put beats jumping back to
	-- your own row between keystrokes.
	if query~="" and not centre then return Layout() end

	-- Centred on that row, so there are as many places above it as below.
	--
	-- Measured off the scrolling area rather than counted in rows, so it stays
	-- centred if the window is ever resized. Near the top or the bottom of the
	-- ladder it cannot centre and the clamp below leaves it as close as it can
	-- get.
	-- Left where it is unless something asked to be scrolled to. Without this
	-- the window centred on your own row whenever it happened to fall on the
	-- page being shown, which is the very behaviour the My rank button exists
	-- to replace.
	if not centre then return Layout() end

	local height=window.scroll:GetHeight() or 0
	local offset=math.max(0,(centre-1)*ROW_HEIGHT-(height-ROW_HEIGHT)/2)

	window.scroll:UpdateScrollChildRect()
	local range=window.scroll:GetVerticalScrollRange() or 0
	local want=math.min(offset,range)

	-- The bar is told the new range here rather than waiting to be told.
	--
	-- UpdateScrollChildRect refreshes the *scroll frame's* range at once, but the
	-- bar only learns it from OnScrollRangeChanged, which arrives a frame later.
	-- Setting the position in between moved the rows and left the bar clamped to
	-- its old maximum -- so the window opened on your own place with the thumb
	-- sitting at the top, and everything above you was unreachable, the ladder
	-- behaving as though your row were the first.
	local bar=window.scroll.ScrollBar
	if not bar then
		local name=window.scroll:GetName()
		bar=name and _G[name.."ScrollBar"] or nil
	end

	if bar then
		bar:SetMinMaxValues(0,range)
		bar:SetValue(want)
	end

	window.scroll:SetVerticalScroll(want)

	-- Setting the scroll fires the handler, which lays out -- but not when the
	-- position happens to be unchanged, so it is done here too.
	Layout()
end

local function CreateWindow()
	if window then return window end

	-- Built on UIParent and re-homed each time it opens -- see Anchor below.
	--
	-- It used to be a child of the history panel, which is a child of the PvP
	-- frame: opened from the minimap with that frame closed, it was a child of
	-- something hidden and so invisible, and clicking the button appeared to do
	-- nothing at all.
	local frame=CreateFrame("Frame","ArenaPlus_ArenaLadder",UIParent,"BackdropTemplate")
	-- Never wider or taller than the screen it opens on. SCALE is what to
	-- aim for, not what to insist on.
	frame:SetScale(ns.FitScale and ns.FitScale(WIDTH,HEIGHT,SCALE) or SCALE)
	window=frame
	frame:Hide()
	frame:SetSize(WIDTH,HEIGHT)
	frame:SetFrameStrata("DIALOG")
	frame:SetToplevel(true)
	frame:EnableMouse(true)
	ns.StyleAsPanel(frame)

	tinsert(UISpecialFrames,"ArenaPlus_ArenaLadder")

	-- A band across the top, so the title and the bracket picker sit on
	-- something rather than floating on the same flat panel as the list.
	--
	-- Blizzard's own art where the client has it, a plain gradient where it
	-- does not. SetAtlas leaves the texture untouched and says nothing when it
	-- does not know a name, so every one is checked before it is used -- the
	-- same trap that had race icons drawing the previous row's portrait.
	local band=frame:CreateTexture(nil,"BORDER")
	band:SetPoint("TOPLEFT",frame,"TOPLEFT",11,-BAND_INSET)
	band:SetPoint("TOPRIGHT",frame,"TOPRIGHT",-12,-BAND_INSET)
	band:SetHeight(BAND_HEIGHT)

	-- Dark, and darker at the bottom where it meets the list.
	--
	-- Blizzard's own header atlases were tried first and thrown out: they are
	-- painted for a light frame, and on this panel the window wore a grey-white
	-- bar across the top that fought everything under it. Their art is not
	-- neutral, and a gradient in the panel's own colours belongs here better
	-- than a texture borrowed from a window that looks nothing like this one.
	--
	-- Two spellings of the same call, because it was renamed and retyped
	-- between client versions -- colour objects now, nine loose numbers before
	-- -- and a flat band if neither is understood.
	band:SetColorTexture(1,1,1,1)

	local shaded=false
	if band.SetGradient and CreateColor then
		shaded=pcall(band.SetGradient,band,"VERTICAL",
			CreateColor(0.05,0.05,0.07,1),CreateColor(0.12,0.13,0.17,1))
	end
	if not shaded and band.SetGradientAlpha then
		shaded=pcall(band.SetGradientAlpha,band,"VERTICAL",
			0.05,0.05,0.07,1,0.12,0.13,0.17,1)
	end
	if not shaded then band:SetColorTexture(0.09,0.10,0.13,1) end

	-- A line under it, brighter than the one between the columns, so the top
	-- of the window reads as a header and the list reads as a list.
	local underline=frame:CreateTexture(nil,"ARTWORK")
	underline:SetPoint("TOPLEFT",band,"BOTTOMLEFT",0,0)
	underline:SetPoint("TOPRIGHT",band,"BOTTOMRIGHT",0,0)
	underline:SetHeight(1)
	underline:SetColorTexture(1,0.82,0,0.35)

	frame.title=frame:CreateFontString(nil,"OVERLAY","GameFontHighlightLarge")
	frame.title:SetPoint("LEFT",frame,"TOPLEFT",16,HEADER_MID)

	frame.subtitle=frame:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
	frame.subtitle:SetPoint("LEFT",frame.title,"RIGHT",10,0)
	frame.subtitle:SetTextColor(0.55,0.55,0.55)

	-- Only of use when this is standing on its own; the helper hides it while
	-- the Rated page is up.
	-- Clear of the heading and its place count at their widest.
	-- After History and Home. Written as the sum rather than as a number so the
	-- row cannot come apart when one of the two buttons is resized.
	frame.UpdateBrackets=ns.BuildBracketPicker(frame,"TOPLEFT",
		BRACKET_X+SWAP_W+ROW_GAP+HOME_W+ROW_GAP,HEADER_TOP)

	local close=CreateFrame("Button",nil,frame,"UIPanelCloseButton")
	close:SetPoint("TOPRIGHT",frame,"TOPRIGHT",0,0)

	-- Find somebody the same way the window finds you: bring their row to the
	-- middle and light it. Two thousand places is more than anybody scrolls.
	local ok,search=pcall(CreateFrame,"EditBox",nil,frame,"SearchBoxTemplate")
	if not (ok and search) then
		ok,search=pcall(CreateFrame,"EditBox",nil,frame,"InputBoxTemplate")
	end

	if ok and search then
		search:SetSize(180,20)
		search:SetPoint("TOPRIGHT",frame,"TOPRIGHT",-32,HEADER_TOP)
		search:SetAutoFocus(false)
		if search.SetMaxLetters then search:SetMaxLetters(40) end
		if search.Instructions then search.Instructions:SetText(L.LADDER_SEARCH) end

		search:SetScript("OnTextChanged",function(self,userInput)
			-- The template owns its placeholder and clear button, and without
			-- this they never learn anything was typed.
			if SearchBoxTemplate_OnTextChanged then
				pcall(SearchBoxTemplate_OnTextChanged,self,userInput)
			end

			query=(self:GetText() or ""):lower()
			-- A changed query is a new search, so it starts at the first match
			-- again rather than carrying the last one's position into it.
			searchNth=1
			-- Searching means "take me there", which outranks the page you
			-- happened to be on.
			pageChosen=false
			Refresh()
		end)
		-- Enter steps to the next row of the same name.
		--
		-- Focus is kept rather than cleared, which is the opposite of what a
		-- search box usually does with Enter: here the key is the control, and
		-- letting go of the box after one press would make the second one do
		-- nothing.
		search:SetScript("OnEnterPressed",function()
			if query=="" then return end
			searchNth=searchNth+1
			-- The next match may be on another page, and this is a request to be
			-- taken to it.
			pageChosen=false
			Refresh()
		end)

		search:SetScript("OnEscapePressed",function(self) self:SetText("") self:ClearFocus() end)

		frame.search=search
	end

	-- Which region's ladder to read.
	--
	-- Both files ship, so the other region is already sitting in memory and
	-- costs nothing to show. Placed left of the search box rather than beside
	-- the title, so the two things that change what is listed sit together.
	--
	-- The player's own region is not marked out or ordered first: it is simply
	-- the one already pressed when the window opens.
	frame.regions={}

	local previous
	for _,choice in ipairs(REGIONS) do
		-- A flag and nothing else.
		--
		-- Built plain rather than from UIPanelButtonTemplate: the template's
		-- border and fill around a flag made each one look like a stamp on a
		-- form, and the flag is a clear enough target on its own.
		--
		-- The template is still used when the art will not load, since two bare
		-- words with no frame would not read as clickable at all.
		local button=CreateFrame("Button",nil,frame)
		button:SetHeight(20)
		button.region=choice.key

		button.flag=button:CreateTexture(nil,"ARTWORK")
		button.flag:SetPoint("CENTER")

		if ns.SetRegionFlag(button.flag,choice.key,14) then
			button:SetWidth(button.flag:GetWidth()+8)

			-- Lit under the cursor, so a grey flag still answers to a hover.
			local glow=button:CreateTexture(nil,"HIGHLIGHT")
			glow:SetAllPoints(button.flag)
			glow:SetColorTexture(1,1,1,0.18)
			button:SetHighlightTexture(glow)
		else
			button.flag:Hide()

			-- Sized to the words rather than to a guess: "North America" and
			-- "Europe" are nothing like each other in length, and a fixed width
			-- either clips one or leaves the other floating in space.
			local fallback=CreateFrame("Button",nil,frame,"UIPanelButtonTemplate")
			fallback:SetHeight(20)
			fallback.region=choice.key
			fallback:SetText(ns.RegionShort(choice.key))

			local label=fallback.GetFontString and fallback:GetFontString()
			fallback:SetWidth(label and (label:GetStringWidth()+24) or 100)

			button:Hide()
			button=fallback
		end

		if previous then
			button:SetPoint("RIGHT",previous,"LEFT",-2,0)
		elseif frame.search then
			button:SetPoint("RIGHT",frame.search,"LEFT",-8,0)
		else
			button:SetPoint("TOPRIGHT",frame,"TOPRIGHT",-32,-14)
		end
		previous=button

		button:SetScript("OnClick",function(self)
			if ns.ViewRegion()==self.region then return end
			ns.SetViewRegion(self.region)
			page=1
			pageChosen=false

			-- The cutoffs box on the page behind follows the same choice, so it
			-- is redrawn too rather than sitting there listing another region's
			-- numbers beside these rows.
			if ns.RefreshRatedPanel then ns.RefreshRatedPanel() end

			-- The search goes with it. A name typed to find somebody on one
			-- ladder means nothing on the other, and leaving it there showed an
			-- empty list as though the region had no players in it.
			query=""
			if frame.search then
				frame.search:SetText("")
				frame.search:ClearFocus()
			end

			-- Back to the top. The row you were looking at was a place on a
			-- different ladder, and holding the scroll there lands on a
			-- stranger with no sign of why.
			if frame.scroll then frame.scroll:SetVerticalScroll(0) end
			wantTop=true
			Refresh()
		end)

		frame.regions[#frame.regions+1]=button
	end

	-- A heading row, outside the scrolling area so it stays put.
	local header=CreateFrame("Frame",nil,frame)
	-- One icon per spec, grouped by class with a wider gap between groups, so
	-- eleven clusters read as eleven classes rather than as thirty-four squares.
	--
	-- Filters the bracket already on screen; clicking the lit one again clears
	-- it. No "all" button: the thing you press to undo a filter should be the
	-- thing you pressed to apply it.
	frame.specs={}

	local x=0
	-- No divider between the classes. There was one, briefly: with the pills
	-- already grouping them it was a second device doing the first one's job,
	-- and the row went from readable to busy. The gap is the separator.
	for _,class in ipairs(CLASS_ORDER) do
		local groupStart=x
		local first
		local slugs={}
		for slug in pairs(ns.SPEC_BY_SLUG or {}) do
			if slug:sub(1,#class+1)==class.."-" then slugs[#slugs+1]=slug end
		end
		table.sort(slugs)

		for _,slug in ipairs(slugs) do
			local id=ns.SPEC_BY_SLUG[slug]

			local button=CreateFrame("Button",nil,frame)
			button:SetSize(SPEC_ICON_SIZE,SPEC_ICON_SIZE)
			button:SetPoint("TOPLEFT",frame,"TOPLEFT",16+x,-36)
			button.spec=id

			button.icon=button:CreateTexture(nil,"ARTWORK")
			button.icon:SetAllPoints()
			button.icon:SetTexture(SpecIcon({ class=class, spec=slug:sub(#class+2) }))
			button.icon:SetTexCoord(0.08,0.92,0.08,0.92)

			-- Only ever shown on the chosen one, so the row reads as a single
			-- choice rather than as thirty-four independent switches.
			button.lit=button:CreateTexture(nil,"OVERLAY")
			button.lit:SetPoint("TOPLEFT",-2,2)
			button.lit:SetPoint("BOTTOMRIGHT",2,-2)
			button.lit:SetTexture("Interface\\Buttons\\CheckButtonHilight")
			button.lit:SetBlendMode("ADD")
			button.lit:Hide()

			button:SetScript("OnEnter",function(self)
				local name=GetSpecializationInfoByID and select(2,GetSpecializationInfoByID(self.spec))
				GameTooltip:SetOwner(self,"ANCHOR_RIGHT")
				GameTooltip:SetText(name or slug)
				GameTooltip:Show()
			end)
			button:SetScript("OnLeave",function() GameTooltip:Hide() end)

			button:SetScript("OnClick",function(self)
				-- Written out, because "a and nil or b" cannot ever yield nil:
				-- the true branch gives nil, and `nil or b` then gives b. So the
				-- clever version re-applied the filter instead of clearing it.
				-- The same trap is commented in the history window's row click,
				-- and I walked straight into it here.
				if specFilter==self.spec then
					specFilter=nil
				else
					specFilter=self.spec
				end
				page=1
				pageChosen=false
				-- A different set of rows means the old scroll position points
				-- at nobody.
				if window and window.scroll then window.scroll:SetVerticalScroll(0) end
				wantTop=true
				Refresh()
			end)

			first=first or button
			frame.specs[#frame.specs+1]=button
			x=x+SPEC_ICON_SIZE+SPEC_ICON_GAP
		end

		-- A class-coloured underline, and nothing behind the icons.
		--
		-- The tinted pill that used to sit here read as a coloured box rather
		-- than as grouping -- at any alpha strong enough to see, eleven of them
		-- in a row is eleven boxes competing with the artwork they were meant
		-- to be supporting. The underline does the same two jobs, joining the
		-- specs of a class into one run and naming the class by its colour,
		-- without putting anything behind the icons at all.
		if first then
			local width=(x-SPEC_ICON_GAP)-groupStart

			local underline=frame:CreateTexture(nil,"BORDER")
			underline:SetPoint("TOPLEFT",frame,"TOPLEFT",16+groupStart,-36-SPEC_ICON_SIZE-3)
			underline:SetSize(width,2)
			underline:SetTexture("Interface\\Buttons\\WHITE8X8")

			local r,g,b=ClassColour(class)
			underline:SetVertexColor(r,g,b,0.8)
		end

		x=x+SPEC_CLASS_GAP-SPEC_ICON_GAP
	end

	header:SetPoint("TOPLEFT",frame,"TOPLEFT",16,COLUMNS_TOP)
	header:SetSize(CONTENT,14)

	local function Heading(x,width,text,justify)
		local label=header:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
		label:SetPoint("LEFT",header,"LEFT",x,0)
		label:SetWidth(width)
		label:SetJustifyH(justify or "LEFT")
		label:SetTextColor(0.6,0.6,0.6)
		label:SetText(text)
		return label
	end

	Heading(COL_RANK,44,L.LADDER_COL_RANK,"RIGHT")
	Heading(COL_NAME,180,L.LADDER_COL_NAME)
	Heading(COL_REALM,170,L.LADDER_COL_REALM)
	Heading(COL_RECORD,120,L.LADDER_COL_RECORD)
	Heading(COL_RATING,70,L.LADDER_COL_RATING,"RIGHT")

	local divider=frame:CreateTexture(nil,"ARTWORK")
	divider:SetPoint("TOPLEFT",frame,"TOPLEFT",12,DIVIDER_TOP)
	divider:SetPoint("TOPRIGHT",frame,"TOPRIGHT",-12,DIVIDER_TOP)
	divider:SetHeight(1)
	divider:SetColorTexture(1,1,1,0.20)

	frame.empty=frame:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
	frame.empty:SetPoint("TOPLEFT",frame,"TOPLEFT",18,EMPTY_TOP)
	frame.empty:SetTextColor(0.55,0.55,0.55)
	frame.empty:SetText(L.LADDER_EMPTY)

	local scroll=CreateFrame("ScrollFrame","ArenaPlus_ArenaLadderScroll",frame,"UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT",frame,"TOPLEFT",16,LIST_TOP)
	scroll:SetPoint("BOTTOMRIGHT",frame,"BOTTOMRIGHT",-36,30)

	local content=CreateFrame("Frame",nil,scroll)
	content:SetSize(CONTENT,10)
	scroll:SetScrollChild(content)
	frame.content=content
	frame.scroll=scroll

	-- Moving repaints the pool onto whatever is now under the window. The
	-- template's own handler keeps the scroll bar honest, so it runs first.
	scroll:SetScript("OnVerticalScroll",function(self,offset)
		if ScrollFrameTemplate_OnVerticalScroll then
			pcall(ScrollFrameTemplate_OnVerticalScroll,self,offset)
		end
		if ns.LayoutLadder then ns.LayoutLadder() end
	end)

	-- Where the numbers came from and when, the same line the cutoffs box uses.
	-- Paging, at the foot beside the source line. Not in the header: that row
	-- already carries the heading, the bracket picker, both regions and the
	-- search box, and this belongs with the list rather than with the filters.
	-- One body for all four buttons: they differed only in the page they asked
	-- for. The single arrows step, the double arrows go to the ends -- HUGE is
	-- clamped down to the last page by Refresh, so this needs no page count.
	local function TurnPage(target)
		page=target
		pageChosen=true
		-- Turning a page while a search is live would immediately be undone:
		-- the search finds its match and turns back. Clearing it is the honest
		-- reading of "I want to browse now".
		query=""
		if frame.search then frame.search:SetText("") end
		if frame.scroll then frame.scroll:SetVerticalScroll(0) end
		wantTop=true
		Refresh()
	end

	local function PageButton(text,width)
		local b=CreateFrame("Button",nil,frame,"UIPanelButtonTemplate")
		b:SetSize(width or 28,20)
		b:SetText(text)
		return b
	end

	frame.pagePrev=PageButton("<")
	frame.pagePrev:SetPoint("BOTTOMRIGHT",frame,"BOTTOMRIGHT",-152,8)
	frame.pagePrev:SetScript("OnClick",function() TurnPage(page-1) end)

	frame.pageNext=PageButton(">")
	frame.pageNext:SetPoint("LEFT",frame.pagePrev,"RIGHT",78,0)
	frame.pageNext:SetScript("OnClick",function() TurnPage(page+1) end)

	-- Outside the single arrows, so the four read as one group in the order
	-- they act: first, back, the count, forward, last.
	-- Your own characters, instead of the ladder.
	frame.altsButton=PageButton(L.LADDER_ALTS,86)
	frame.altsButton:SetScript("OnClick",function()
		showingAlts=not showingAlts

		-- A different list entirely, so nothing about where you were in the old
		-- one carries over.
		query=""
		if frame.search then frame.search:SetText("") end
		if frame.scroll then frame.scroll:SetVerticalScroll(0) end
		wantTop=true
		page=1
		pageChosen=false
		Refresh()
	end)

	-- What opening the window used to do, now asked for rather than assumed.
	frame.mineButton=PageButton(L.LADDER_MINE,86)
	-- Left of the page arrows, not at the bottom left corner: the source line
	-- lives there and the two would have sat on top of each other.
	frame.mineButton:SetScript("OnClick",function()
		-- Out of the alts list first, if that is where we are. Your rank means
		-- your rank on the ladder; in a list of five of your own characters
		-- numbered from one it would mean nothing.
		showingAlts=false

		query=""
		if frame.search then frame.search:SetText("") end
		if frame.scroll then frame.scroll:SetVerticalScroll(0) end
		wantTop=true
		-- Outranks a page chosen by hand: this is the one button whose whole
		-- job is to move the page.
		pageChosen=false
		jumpToSelf=true
		Refresh()
	end)

	frame.pageFirst=PageButton("<<",32)
	frame.pageFirst:SetPoint("RIGHT",frame.pagePrev,"LEFT",-2,0)
	frame.pageFirst:SetScript("OnClick",function() TurnPage(1) end)

	-- My rank first, then My alts: the ladder is what this window is, and
	-- your own characters are the aside. The source line anchors to whichever
	-- of the two ends up leftmost, which is now My rank.
	frame.altsButton:SetPoint("RIGHT",frame.pageFirst,"LEFT",-10,0)
	frame.mineButton:SetPoint("RIGHT",frame.altsButton,"LEFT",-6,0)

	frame.pageLast=PageButton(">>",32)
	frame.pageLast:SetPoint("LEFT",frame.pageNext,"RIGHT",2,0)
	frame.pageLast:SetScript("OnClick",function() TurnPage(math.huge) end)

	frame.pageLabel=frame:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
	frame.pageLabel:SetPoint("LEFT",frame.pagePrev,"RIGHT",6,0)
	frame.pageLabel:SetWidth(72)
	frame.pageLabel:SetJustifyH("CENTER")
	frame.pageLabel:SetTextColor(0.7,0.7,0.7)

	frame.source=frame:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
	-- To the history, keeping the bracket.
	--
	-- The two windows already share one bracket, held in the core -- but both
	-- of them clear it in OnHide, so closing this one to open the other throws
	-- it away and the history opens on whatever was last played. Hence reading
	-- it before the swap and putting it back after: the alternative is teaching
	-- OnHide the difference between being closed and being replaced, which is a
	-- thing neither window can see.
	frame.swapButton=PageButton(L.LADDER_SWAP,SWAP_W)
	frame.swapButton:SetPoint("TOPLEFT",frame,"TOPLEFT",BRACKET_X,HEADER_TOP)

	-- Home, in the bracket row rather than down among the page buttons.
	--
	-- It was a "Top" button there first and read as another page control, which
	-- is the one thing it is not: "<<" moves you within whatever you are looking
	-- at, and this changes what you are looking at -- clearing the search, the
	-- spec filter and the alts list on the way.
	--
	-- A word, not a picture. Three icons were tried and none worked: the
	-- innkeeper tracking texture reads as a person, an up arrow reads as a page
	-- control, and the garrison building did not resolve on this client at all.
	-- None of them said "and it clears your filters" anyway, which is half of
	-- what this does, so the tooltip carries the detail either way.
	frame.homeButton=PageButton(L.LADDER_HOME,HOME_W)
	-- After History, not before it. In front, it was the first thing in the row
	-- and the first thing over the heading; behind, the row grows rightwards
	-- from one fixed point and the heading has the whole left of the band.
	frame.homeButton:SetPoint("LEFT",frame.swapButton,"RIGHT",ROW_GAP,0)

	-- And the heading stops where the row starts, whatever it says. Anchoring
	-- only its left edge is what let "top 5006 players" run under a button:
	-- given both edges and no wrapping it is cut short instead, which is a
	-- reading of the number rather than a loss of it.
	frame.subtitle:SetPoint("RIGHT",frame.swapButton,"LEFT",-10,0)
	frame.subtitle:SetWordWrap(false)
	frame.subtitle:SetJustifyH("LEFT")

	frame.homeButton:SetScript("OnEnter",function(self)
		GameTooltip:SetOwner(self,"ANCHOR_RIGHT")
		GameTooltip:SetText(L.LADDER_HOME_TIP,1,1,1,1,true)
		GameTooltip:Show()
	end)
	frame.homeButton:SetScript("OnLeave",function() GameTooltip:Hide() end)

	frame.homeButton:SetScript("OnClick",function()
		showingAlts=false
		specFilter=nil

		query=""
		if frame.search then frame.search:SetText("") end
		wantTop=true

		-- Chosen by hand, so nothing else moves the page afterwards -- and page
		-- one is the page this button means.
		page=1
		pageChosen=true
		Refresh()
	end)
	frame.swapButton:SetScript("OnClick",function()
		local bracket=ns.ViewBracket and ns.ViewBracket()

		if ns.ToggleArenaHistory then ns.ToggleArenaHistory() end

		if bracket and ns.SetViewBracket then
			ns.SetViewBracket(bracket)
			if ns.RefreshArenaHistory then ns.RefreshArenaHistory() end
		end
	end)

	-- The corner is its own again, the swap button having gone up to the
	-- bracket row.
	frame.source:SetPoint("BOTTOMLEFT",frame,"BOTTOMLEFT",16,12)
	-- Stopped short of the buttons at the other end, so a longer line is cut
	-- rather than drawn over them.
	frame.source:SetPoint("RIGHT",frame.mineButton,"LEFT",-10,0)
	frame.source:SetJustifyH("LEFT")
	frame.source:SetWordWrap(false)
	frame.source:SetTextColor(0.45,0.45,0.45)

	frame:SetScript("OnShow",Refresh)
	-- A search left behind is the window opening tomorrow centred on a stranger
	-- with no sign of why, so it goes when the window does.
	-- Same rule as the history window: it reopens as it first opened, rather
	-- than in whatever state it was abandoned in.
	frame:SetScript("OnHide",function(self)
		query=""
		page=1
		pageChosen=false
		-- Back to the ladder, not whichever view was left open: the window's
		-- job is the ladder and My alts is a detour from it.
		showingAlts=false
		if self.search then
			self.search:SetText("")
			self.search:ClearFocus()
		end

		specFilter=nil
		if self.scroll then self.scroll:SetVerticalScroll(0) end
		wantTop=true
		if ns.ClearViewBracket then ns.ClearViewBracket() end
	end)
	return frame
end

-- Beside the panel when the panel is up, and in the middle of the screen when
-- it is not.
--
-- Two ways in, two right answers. Opened from the history panel's button it
-- belongs against that panel, where it and the history window take turns in one
-- place. Opened from the minimap there is no panel to sit beside, and hanging
-- it off a hidden frame is how it managed to open into nowhere.
local function Anchor(frame)
	-- One fixed spot, shared with the history window through the core.
	--
	-- This used to dock to the history panel while the Rated page was up and
	-- return to the middle when it closed, so the window moved out from under
	-- you every time that page opened or shut. It also had to: docking meant
	-- parenting, and a child of a hidden frame is hidden.
	--
	-- Nothing to avoid now either. The panel hangs off PVEFrame on the left, and
	-- this sits right of centre, so the two never meet whether the page is open
	-- or not.
	ns.PlaceFullWindow(frame)
	return false
end

-- Opened from the history panel's button, or from the minimap.
function ns.ToggleLadder()
	local frame=CreateWindow()
	if not frame then return end

	if frame:IsShown() then
		frame:Hide()
		return
	end

	-- Always the other one away first.
	--
	-- Docked they share one spot and it was self-evident; standing on their own
	-- they are both centred on the screen, so without this they simply stack on
	-- top of each other.
	if ns.CloseArenaHistory then ns.CloseArenaHistory() end

	Anchor(frame)
	frame:Show()
	Refresh()
end

-- Open the ladder on a bracket, looking for one person.
--
-- Setting the search box's text is the whole implementation: its OnTextChanged
-- already sets the query, forgets whichever page was being read, refreshes, and
-- the refresh turns to the match and lights the row. Reaching past it to set
-- `query` directly would be a second copy of all that, out of step the first
-- time either changed.
--
-- The bare name, because that is what the ladder searches on -- a realm matches
-- hundreds of rows at once, which is the opposite of finding somebody.
function ns.ShowLadderFor(bracket,name)
	local frame=CreateWindow()
	if not frame then return end

	if bracket and ns.SetViewBracket then ns.SetViewBracket(bracket) end

	-- Same rule as ToggleLadder: undocked the two windows both sit centred, so
	-- without this they stack on each other.
	if ns.CloseArenaHistory then ns.CloseArenaHistory() end

	Anchor(frame)
	frame:Show()

	-- The name is searched without its realm, because the ladder matches on
	-- names -- but the realm is remembered so the refresh can pick the right
	-- one of several people called the same thing.
	-- Split in an if, not with an and.
	--
	-- "local bare,realm = name and name:match(...)" reads fine and is wrong:
	-- the and collapses the multiple return to one value, so realm was always
	-- nil and the realm was never remembered at all. Written once already in
	-- _brain/WOW-API.md, and written again here anyway.
	local bare,realm
	if name then bare,realm=name:match("^([^%-]+)%-(.+)$") end
	bare=bare or (name and (name:match("^([^%-]+)") or name))
	wantRealm=realm and ns.PlainName(realm) or nil

	if frame.search and bare and bare~="" then
		frame.search:SetText(bare)
	else
		Refresh()
	end
end

function ns.CloseLadder()
	if window and window:IsShown() then window:Hide() end
end

-- Put back where it belongs when the panel arrives or leaves.
--
-- Anchor runs once, when the window opens. Opened from the minimap with no
-- Rated page up there was nothing to sit beside, so it centred itself -- and
-- opening the Rated page afterwards laid the panel straight over it.
--
-- IsShown rather than IsVisible on purpose: a window anchored to the panel is
-- a child of it, so while the panel is hidden this one is invisible but still
-- shown, and it is exactly the window that needs moving back to the middle.
function ns.ReanchorLadder()
	if window and window:IsShown() then Anchor(window) end
end


ns.RefreshLadder=Refresh

-- Why your own row is or is not being found. Both sides of the comparison
-- printed as they actually are, plus anything on the ladder sharing your name,
-- since a realm that does not match is the likeliest reason.
ns.SlashCommands["ladder"]=function()
	local bracket=ns.ViewBracket()
	local list=Ladder(bracket)

	local name=UnitName and UnitName("player")
	local realm=GetRealmName and GetRealmName()

	ns.Print("You: name=%q realm=%q",tostring(name),tostring(realm))
	ns.Print("Bracket %d holds %d places.",bracket,#list)

	local found
	for index,entry in ipairs(list) do
		if IsPlayer(entry) then found=index break end
	end
	ns.Print("Matched: %s",found and ("row "..found) or "no")

	-- Anything with your name on it, whatever realm it says.
	local lower=(name or ""):lower()
	for _,entry in ipairs(list) do
		if entry.name and entry.name:lower()==lower then
			ns.Print("  same name: #%d %q on %q, rating %d",
				entry.rank or 0,entry.name,tostring(entry.realm),entry.rating or 0)
		end
	end

	-- And whatever is sitting at your rating, in case the name itself differs.
	local mine=select(1,GetPersonalRatedInfo and GetPersonalRatedInfo(bracket))
	if mine then
		ns.Print("Your rating is %d. Rows there:",mine)
		for _,entry in ipairs(list) do
			if (entry.rating or 0)==mine then
				ns.Print("  #%d %q on %q",entry.rank or 0,entry.name,tostring(entry.realm))
			end
		end
	end
end
