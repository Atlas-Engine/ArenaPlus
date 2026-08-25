local ADDON_NAME, ns = ...
local L = ns.L

local CURRENT_DB_VERSION = 1

-- What the four brackets are called, everywhere.
--
-- There were six copies of this list and they had stopped agreeing: the history
-- and the bracket picker said 10v10, while the ladder, the tooltip, the inspect
-- panel and the auction house window said RBG. Both are the same bracket. The
-- game calls it 10v10 on its own PvP frame, so that is what it is called here,
-- and there is one list to change if that ever stops being true.
ns.BRACKET_NAMES = { "2v2", "3v3", "5v5", "10v10" }

-- The region flags.
--
-- The client has no region art of its own -- checked, and it has faction crests
-- and nothing named for a country -- so these ship with the addon. Each is a
-- 128x64 file holding the flag at its own size, untouched, rather than squeezed
-- to fill the file: resampling an 80 pixel flag down to fit turned thirteen
-- stripes into a grey smear, so the graphics card is left to scale it instead.
--
-- Which means each needs to say where in the file it lives, and how wide it is
-- for a given height: the European flag is 3:2 and the American 19:10, so at
-- one height they are not one width.
-- One shape for both, so a row of flags is a row of equal rectangles.
--
-- Their true proportions differ -- the American flag is 19:10 and the European
-- 3:2 -- and drawn honestly at the same height one is a fifth wider than the
-- other, which reads as a mistake rather than as a fact about flags. This is
-- the average of the two, so each is a little wrong and neither is obviously
-- so: the American squeezed by about a seventh, the European stretched by half
-- that.
--
-- Each flag keeps its own aspect below, for anywhere that would rather be
-- accurate than tidy.
ns.REGION_FLAG_ASPECT = 1.67

ns.REGION_FLAG = {
	us = {
		texture = "Interface\\AddOns\\ArenaPlus\\Media\\region-us",
		coords  = { 0.1797, 0.8203, 0.1562, 0.8438 },
		texels  = { 23, 105, 10, 54 },
		file    = { 128, 64 },
		aspect  = 1.86,
	},
	eu = {
		texture = "Interface\\AddOns\\ArenaPlus\\Media\\region-eu",
		coords  = { 0.1797, 0.8203, 0.0625, 0.9219 },
		texels  = { 23, 105, 4, 59 },
		file    = { 128, 64 },
		aspect  = 1.49,
	},
}

-- The same flag as a piece of text, for the places a region is named inside a
-- sentence rather than drawn on a button.
--
-- WoW lets a texture be embedded in any string, but the escape wants its crop
-- in texels rather than the fractions SetTexCoord takes -- so both are kept
-- above and neither is worked out from the other at the point of use.
--
--   |Tpath:height:width:xoff:yoff:texWidth:texHeight:left:right:top:bottom|t
function ns.RegionFlagMarkup(region,height)
	local flag = region and ns.REGION_FLAG[region]
	if not flag then return nil end

	height = height or 12

	return ("|T%s:%d:%d:0:0:%d:%d:%d:%d:%d:%d|t"):format(
		flag.texture,
		height, math.floor(height*ns.REGION_FLAG_ASPECT+0.5),
		flag.file[1], flag.file[2],
		flag.texels[1], flag.texels[2], flag.texels[3], flag.texels[4])
end

-- Draws one onto a texture, sized from the height asked for. Answers whether it
-- had anything to draw, so a caller can keep its text when it does not.
function ns.SetRegionFlag(texture,region,height)
	local flag = region and ns.REGION_FLAG[region]
	if not (texture and flag) then return false end

	texture:SetTexture(flag.texture)

	-- A path the client cannot load leaves the texture empty and says nothing,
	-- which is how the inspect panel spent a day drawing an untextured body.
	if not texture:GetTexture() then return false end

	texture:SetTexCoord(unpack(flag.coords))
	texture:SetSize(math.floor(height*ns.REGION_FLAG_ASPECT+0.5),height)
	return true
end

-- Lit for the region being looked at, grey for the other.
--
-- Desaturated rather than merely dimmed: two flags side by side are told apart
-- by colour before anything else, so draining it from one is the clearest way
-- to say which is not chosen.
function ns.LightRegionFlag(texture,chosen)
	if not texture then return end

	texture:SetDesaturated(not chosen)
	texture:SetAlpha(chosen and 1 or 0.45)
end

-- Every tweak is a module: a small table with its own defaults, its own saved
-- settings, an OnEnable and whatever extra options it wants drawn under its
-- heading. Adding one means dropping a file in Modules\ and listing it in the
-- .toc -- nothing here needs to know what it does.
ns.modules = {}
local moduleOrder = {}

local configFrame

local COLUMN_X = 6
-- Sidebar of tweak names, then one tweak's settings beside it. The pane width
-- is what text wraps against, so it is fixed rather than measured: a frame
-- anchored to fill has no width yet while its contents are being built.
local SIDEBAR_WIDTH = 170
local ROW_HEIGHT    = 26
local GROUP_HEIGHT  = 22
local CONTENT_WIDTH = 400

----------------------------------------------------------------
-- Helpers
----------------------------------------------------------------

function ns.Print(fmt,...)
	local msg=(select("#",...)>0) and fmt:format(...) or fmt
	if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
		DEFAULT_CHAT_FRAME:AddMessage(L.CHAT_PREFIX..msg)
	end
end

-- IsAddOnLoaded moved into C_AddOns partway through this client's life and the
-- global is on its way out, so ask whichever one this build actually has.
function ns.IsAddOnLoaded(name)
	if C_AddOns and C_AddOns.IsAddOnLoaded then return C_AddOns.IsAddOnLoaded(name) end
	if IsAddOnLoaded then return IsAddOnLoaded(name) end
	return false
end

-- The same menu sounds TrackerPlus uses, guarded because SOUNDKIT entries vary
-- slightly by client version.
local function PlayMenuOpenSound()
	if SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPEN then PlaySound(SOUNDKIT.IG_MAINMENU_OPEN) end
end

local function PlayMenuCloseSound()
	if SOUNDKIT and SOUNDKIT.IG_MAINMENU_CLOSE then PlaySound(SOUNDKIT.IG_MAINMENU_CLOSE) end
end

-- Coin icons where the client has them, a plain number where it does not.
function ns.Money(copper)
	copper=copper or 0
	if GetCoinTextureString then return GetCoinTextureString(copper) end
	return tostring(copper)
end

----------------------------------------------------------------
-- Ladder tiers
----------------------------------------------------------------

-- White challenger, green rival, blue duellist, purple gladiator, orange rank
-- one -- tested in that order, highest first.
-- Shared, since the history panel lists the cutoffs these colours belong to.
ns.TIERS = {
	{ key="r1",         hex="ff8000" },
	{ key="gladiator",  hex="a335ee" },
	{ key="duelist",    hex="0070dd" },
	{ key="rival",      hex="1eff00" },
	{ key="challenger", hex="ffffff" },
}
local TIERS = ns.TIERS
local BELOW_TIERS_HEX = "b3b3b3"

-- Rated battlegrounds award different titles to the arena brackets.
--
-- There is no Gladiator at all, and the top title is Hero of the Alliance or
-- Hero of the Horde rather than the arena's rank one. Both are properties of
-- the bracket rather than of the tier, so they live here beside the tiers and
-- everything that draws a cutoff asks rather than assuming.
local RBG_BRACKET = 4

function ns.TierApplies(tier,bracket)
	if bracket==RBG_BRACKET and tier.key=="gladiator" then return false end
	return true
end

function ns.TierName(tier,bracket)
	if bracket==RBG_BRACKET and tier.key=="r1" then
		-- Named for the faction the reader plays, since that is the title they
		-- would actually be awarded. A pandaren who has not chosen yet answers
		-- "Neutral", which is neither, so the plain wording stands in.
		local side=UnitFactionGroup and UnitFactionGroup("player")

		if side=="Alliance" then return L.CUTOFF_HERO_ALLIANCE end
		if side=="Horde" then return L.CUTOFF_HERO_HORDE end

		return L.CUTOFF_HERO
	end
	return L["CUTOFF_"..string.upper(tier.key)] or tier.key
end

-- The live numbers live in Cutoffs-<region>.lua, which
-- tools\UpdateFromBlizzard.ps1 writes from Blizzard's own PvP season endpoint:
-- the game cannot fetch anything itself, so they are handed over as a file.
-- These are the values as of writing, for when that file is missing or stale.
local FALLBACK_CUTOFFS = {
	[1] = { r1=2421, gladiator=2171, duelist=2013, rival=1778, challenger=1056 }, -- 2v2
	[2] = { r1=2337, gladiator=1751, duelist=1710, rival=1575, challenger=768 },  -- 3v3
	-- 5v5 is barely played, so every title below rank one sits on the floor --
	-- which is what the ladder actually says, however odd it looks.
	[3] = { r1=1841, gladiator=192,  duelist=192,  rival=192,  challenger=192 },  -- 5v5
	-- Rated battlegrounds have no Gladiator title, so that tier is simply
	-- absent and skipped rather than defaulted to something.
	[4] = { r1=1945, duelist=1827, rival=1705, challenger=1451 },                 -- 10v10
}

function ns.TierHex(bracket,rating)
	local cutoffs=(ns.CUTOFFS and ns.CUTOFFS[bracket]) or FALLBACK_CUTOFFS[bracket]
	if not (cutoffs and rating) then return BELOW_TIERS_HEX end

	for _,tier in ipairs(TIERS) do
		local cutoff=cutoffs[tier.key]
		if cutoff and rating>=cutoff then return tier.hex end
	end
	return BELOW_TIERS_HEX
end

-- A number in its tier's colour. What is being coloured is always a rating,
-- even when the number shown is a ladder position.
function ns.ColouredRating(bracket,rating,shown)
	return ("|cff%s%d|r"):format(ns.TierHex(bracket,rating),shown or rating)
end

----------------------------------------------------------------
-- Which character this is
----------------------------------------------------------------

-- The realm exactly as the game gives it, matching the folder names under WTF.
-- Not GetNormalizedRealmName: that drops the punctuation -- Ra-den becomes
-- Raden -- and it returns nothing early in the load, so the same character
-- ended up filed under two different keys on different sessions.
-- Whether a name belongs to someone you know: a friend, or a guild member.
--
-- Only a name is ever offered by an invite or a challenge, so both tests are
-- made on the name. The guild roster answers from a cache that stays empty
-- until something asks for it, which is why the tweaks using this warm it when
-- they enable -- a cold cache reads as "not a guild member", which errs
-- towards declining rather than towards letting a stranger through.
-- Whoever a Battle.net friend is playing right now, across every game account
-- they have logged in. This is the list most people's friends are actually on:
-- the character friends list only knows people added on this character's realm,
-- so checking that alone turns a real friend's invite away.
local function IsBattleNetFriend(bare)
	if not (C_BattleNet and type(BNGetNumFriends)=="function") then return false end

	local function Matches(gameAccount)
		local character=gameAccount and gameAccount.characterName
		return character and (character:match("^([^-]+)") or character)==bare
	end

	for index=1,(BNGetNumFriends() or 0) do
		local account=C_BattleNet.GetFriendAccountInfo and C_BattleNet.GetFriendAccountInfo(index)
		if account and Matches(account.gameAccountInfo) then return true end

		-- A friend online on more than one account has the rest here.
		local extra=C_BattleNet.GetFriendNumGameAccounts and C_BattleNet.GetFriendNumGameAccounts(index) or 0
		for account_index=1,extra do
			if Matches(C_BattleNet.GetFriendGameAccountInfo(index,account_index)) then return true end
		end
	end

	return false
end

function ns.IsKnownPlayer(name)
	if not name or name=="" then return false end
	local bare=name:match("^([^-]+)") or name

	if C_FriendList and C_FriendList.GetFriendInfo then
		if C_FriendList.GetFriendInfo(bare) then return true end
	end

	if IsBattleNetFriend(bare) then return true end

	if IsInGuild and IsInGuild() and GetNumGuildMembers and GetGuildRosterInfo then
		for index=1,(GetNumGuildMembers() or 0) do
			local member=GetGuildRosterInfo(index)
			if member and (member:match("^([^-]+)") or member)==bare then return true end
		end
	end

	return false
end

-- Ask the server for the roster, so the test above has something to read.
function ns.WarmGuildRoster()
	if not (IsInGuild and IsInGuild()) then return end

	if C_GuildInfo and C_GuildInfo.GuildRoster then
		C_GuildInfo.GuildRoster()
	elseif GuildRoster then
		GuildRoster()
	end
end

function ns.CharKey()
	local name=UnitName("player") or "?"
	local realm=GetRealmName() or "?"
	return name.."-"..realm
end

-- Anything filed under the old normalised key is moved across, so a session's
-- worth of records is not stranded by the fix above.
function ns.MigrateCharStore(chars)
	if not chars then return end

	local key=ns.CharKey()
	if chars[key] then return end

	local name=UnitName("player")
	if not (name and GetNormalizedRealmName) then return end

	local old=name.."-"..(GetNormalizedRealmName() or "")
	if chars[old] then
		chars[key]=chars[old]
		chars[old]=nil
	end
end

----------------------------------------------------------------
-- Between tweaks
----------------------------------------------------------------

-- The odd thing worked out by one tweak that another wants -- a finished arena,
-- say -- rather than both working it out and disagreeing.
local listeners={}

function ns.On(event,callback)
	listeners[event]=listeners[event] or {}
	table.insert(listeners[event],callback)
end

function ns.Fire(event,...)
	for _,callback in ipairs(listeners[event] or {}) do
		callback(...)
	end
end

-- Seventeen tweaks in one column is a list you read rather than scan. Grouped,
-- it is four short lists, and where a tweak sits says something about it before
-- the description does. Order here is the order they appear.
ns.GROUP_ORDER = { "arena", "gear", "popups", "interface" }

-- A tweak may name another as its parent, and then it has no row of its own:
-- its switch and its options are drawn on the parent's page instead. Two
-- tweaks that only ever touch the same window are one page to the person
-- reading the list, however sensible they are as separate files.
function ns.RegisterModule(key,module)
	module.key=key
	-- A tweak with no group of its own falls in at the end rather than
	-- vanishing from the list.
	module.group=module.group or "interface"
	ns.modules[key]=module
	moduleOrder[#moduleOrder+1]=key
	return module
end

-- The tweaks drawn on one page: the module itself, then anything naming it.
function ns.ChildModules(key)
	local children={}
	for _,other in ipairs(moduleOrder) do
		if ns.modules[other].parent==key then children[#children+1]=ns.modules[other] end
	end
	return children
end

-- The tweaks in the order the list shows them: by group, and within a group in
-- the order they registered.
function ns.OrderedModules()
	local rank={}
	for index,group in ipairs(ns.GROUP_ORDER) do rank[group]=index end

	local position={}
	for index,key in ipairs(moduleOrder) do position[key]=index end

	local sorted={}
	for _,key in ipairs(moduleOrder) do
		if not ns.modules[key].parent then sorted[#sorted+1]=key end
	end

	table.sort(sorted,function(a,b)
		local ra=rank[ns.modules[a].group] or #ns.GROUP_ORDER+1
		local rb=rank[ns.modules[b].group] or #ns.GROUP_ORDER+1
		if ra~=rb then return ra<rb end
		return position[a]<position[b]
	end)

	return sorted
end

----------------------------------------------------------------
-- The line above the Leave Arena button
----------------------------------------------------------------

-- One line, shared. Any tweak with something to say when a match ends puts its
-- piece in and they are shown together, rather than each overwriting the last.
local scoreboardLabel
local scoreboardParts={}

local function ScoreboardLabel()
	if scoreboardLabel then return scoreboardLabel end

	local frame=WorldStateScoreFrame
	if not frame then return nil end

	scoreboardLabel=frame:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
	scoreboardLabel:SetJustifyH("CENTER")

	local leave=WorldStateScoreFrameLeaveButton
	if leave then
		scoreboardLabel:SetPoint("BOTTOM",leave,"TOP",0,10)
	else
		scoreboardLabel:SetPoint("BOTTOM",frame,"BOTTOM",0,70)
	end

	return scoreboardLabel
end

local function RenderScoreboard()
	local label=ScoreboardLabel()
	if not label then return end

	-- Sorted by the order each tweak asked for, so the line reads the same way
	-- every time however the pieces arrive.
	table.sort(scoreboardParts,function(a,b) return a.order<b.order end)

	local pieces={}
	for _,part in ipairs(scoreboardParts) do
		if part.text and part.text~="" then pieces[#pieces+1]=part.text end
	end

	label:SetText(table.concat(pieces,"  |cff808080-|r  "))
end

-- order decides where the piece sits on the line; text of "" removes it.
function ns.ScoreboardSay(key,text,order)
	for _,part in ipairs(scoreboardParts) do
		if part.key==key then
			part.text=text
			return RenderScoreboard()
		end
	end

	scoreboardParts[#scoreboardParts+1]={ key=key, text=text, order=order or 100 }
	RenderScoreboard()
end

function ns.ScoreboardClear()
	if not scoreboardLabel then return end
	for _,part in ipairs(scoreboardParts) do part.text="" end
	scoreboardLabel:SetText("")
end

-- The score frame is shared with battlegrounds, so last match's line is
-- cleared on any move rather than only on the way out of an arena.
local zoneWatcher=CreateFrame("Frame")
zoneWatcher:RegisterEvent("PLAYER_ENTERING_WORLD")
zoneWatcher:SetScript("OnEvent",function() ns.ScoreboardClear() end)

----------------------------------------------------------------
-- Saved variables
----------------------------------------------------------------

-- These modules used to live in QoLPlus, and their settings and recorded
-- matches with them.
local INHERITED = { "history", "mmr", "ratedpage", "pvp" }

-- Brought across once, and only where nothing is here yet.
--
-- Copied rather than moved: QoLPlus keeps its own copy untouched, so going back
-- to it loses nothing and this can be run again without consequence. Match
-- history is the reason for the care -- specs, crowd control and damage taken
-- for hundreds of games that the scoreboard cannot reproduce.
local function InheritFromQoLPlus(db,force)
	if db.inherited and not force then return end

	-- Addons load in folder order, and ArenaPlus comes before QoLPlus in the
	-- alphabet -- so at our own ADDON_LOADED, QoLPlus_SavedVars does not exist
	-- yet. Marking the job done here would have skipped it for good and looked
	-- exactly like the history having been lost.
	--
	-- So nothing is written until there is something to read. Called again at
	-- PLAYER_LOGIN, by which time every addon has loaded and the answer is
	-- final either way.
	local old=QoLPlus_SavedVars
	if not (old and old.modules) then return end

	db.inherited=true

	local function Copy(value)
		if type(value)~="table" then return value end

		local out={}
		for key,inner in pairs(value) do out[key]=Copy(inner) end
		return out
	end

	-- Merged into what is here rather than only filling empty slots.
	--
	-- InitDB has already given every module a table of its defaults by this
	-- point, so "copy it if nothing is there" was never true of anything and
	-- quietly brought nothing across. What the old install says wins, since on
	-- a first run everything here is a default nobody chose.
	local brought=0
	for _,key in ipairs(INHERITED) do
		local from=old.modules[key]
		if type(from)=="table" then
			local into=db.modules[key] or {}
			db.modules[key]=into

			for field,value in pairs(from) do into[field]=Copy(value) end
			brought=brought+1
		end
	end

	if brought>0 then
		-- Said out loud, because it happens once and silently otherwise.
		C_Timer.After(2,function() ns.Print(L.INHERITED,brought) end)
	end
end

local function InitDB()
	ArenaPlus_SavedVars=ArenaPlus_SavedVars or {}
	local db=ArenaPlus_SavedVars
	db.version=db.version or CURRENT_DB_VERSION
	db.modules=db.modules or {}

	InheritFromQoLPlus(db)

	-- Fill each module's settings in from its own defaults, leaving anything
	-- the player has already chosen alone.
	for _,key in ipairs(moduleOrder) do
		local module=ns.modules[key]
		local saved=db.modules[key]
		if not saved then saved={} db.modules[key]=saved end
		if module.defaults then
			for k,v in pairs(module.defaults) do
				-- A table default is copied rather than handed over: shared, the
				-- first edit would rewrite the default itself for everything
				-- else that ever reads it.
				if saved[k]==nil and type(v)=="table" then
					local copy={}
					for innerKey,innerValue in pairs(v) do copy[innerKey]=innerValue end
					saved[k]=copy
				elseif saved[k]==nil then saved[k]=v end
			end
		end
		module.db=saved
	end

end

----------------------------------------------------------------
-- Enabling and disabling
----------------------------------------------------------------

-- A module that is switched off after it has started keeps its hooks in place:
-- hooks cannot be removed, so modules are written to check module.db.enabled
-- when they fire rather than to be torn down and rebuilt.
function ns.SetModuleEnabled(module,enabled)
	module.db.enabled=enabled and true or false
	if enabled and not module.started then
		module.started=true
		if module.OnEnable then module:OnEnable() end
	end
	-- A module with something on screen needs to put it away and bring it back;
	-- the rest just check db.enabled when they fire, since hooks cannot be
	-- removed once installed.
	if module.OnToggle then module:OnToggle(module.db.enabled) end
end

-- Whatever the ticks say, which is what they are for.
--
-- This forced everything on for a while, during the stretch with no settings
-- window: a tweak switched off then would have had no way back. With the window
-- returned, honouring the saved value is right again.
local function StartModules()
	for _,key in ipairs(moduleOrder) do
		local module=ns.modules[key]
		if module.db.enabled then ns.SetModuleEnabled(module,true) end
	end
end

----------------------------------------------------------------
-- Widgets
----------------------------------------------------------------

-- Shared so a tweak's own window looks like the settings one.
----------------------------------------------------------------
-- Which region the scraped numbers describe
----------------------------------------------------------------

-- GetCurrentRegion's numbering.
local REGION_NAMES = { [1]="us", [2]="kr", [3]="eu", [4]="tw", [5]="cn" }

-- Written out rather than abbreviated. There is room for it in both headings,
-- and "NA" is a thing you decode where "North America" is a thing you read.
local REGION_LABELS = {
	us = "North America",
	eu = "Europe",
	kr = "Korea",
	tw = "Taiwan",
	cn = "China",
}

function ns.PlayerRegion()
	if not GetCurrentRegion then return nil end
	return REGION_NAMES[GetCurrentRegion()]
end

-- The short form, for headings with something else already on the same line.
local REGION_SHORT = { us="NA", eu="EU", kr="KR", tw="TW", cn="CN" }

function ns.RegionLabel(region)
	region=region or ns.ViewRegion()
	if not region then return "?" end
	return REGION_LABELS[region] or region:upper()
end

function ns.RegionShort(region)
	region=region or ns.ViewRegion()
	if not region then return "?" end
	return REGION_SHORT[region] or region:upper()
end

----------------------------------------------------------------
-- The region being looked at
----------------------------------------------------------------

-- Yours, unless the ladder's buttons say otherwise.
--
-- Kept here rather than in the ladder because the cutoffs box has to agree with
-- it: rows coloured by EU cutoffs beside a box listing NA ones is the window
-- contradicting itself, and the colours are the part nobody would question.
--
-- Not saved. Looking at the other region is a minute's curiosity, and a window
-- that opened on somebody else's ladder tomorrow would read as a fault.
local viewRegion, viewBracket, chosenBracket

-- Which bracket the windows are showing.
--
-- Docked against the Rated page they follow it: the page is the picker, and two
-- pickers disagreeing about one thing is worse than none. Opened from the
-- minimap there is no page to follow -- SelectedBracket reads a field off
-- Blizzard's frame and answers 2v2 for a frame that was never opened -- so the
-- windows carry their own buttons and this holds what they chose.
function ns.ViewBracket()
	local panel=ns.HistoryPanel and ns.HistoryPanel()
	if panel and panel:IsVisible() then
		return (ns.SelectedBracket and ns.SelectedBracket()) or 1
	end

	-- Failing an explicit choice, the bracket you last played. SelectedBracket
	-- is the last resort rather than the first: off the Rated page it is not a
	-- selection at all, just the default value of a field nobody set.
	if chosenBracket then return chosenBracket end

	local played=ns.LastPlayedBracket and ns.LastPlayedBracket()
	if played then return played end

	return (ns.SelectedBracket and ns.SelectedBracket()) or 1
end

-- A row of 2v2 / 3v3 / 5v5 / 10v10 buttons for a window that is standing on its
-- own, built the same way in both so they cannot drift apart.
--
-- `onPick` is called after the choice is stored, for the window to redraw
-- itself. The returned function shows or hides the row and marks the current
-- one, and is called on every refresh.
-- `point` is "TOPLEFT" or "TOPRIGHT" on the frame itself, with x and y from
-- that corner. Pinned to the frame rather than trailed after a heading: the
-- heading's width changes with the bracket and the region, so anything anchored
-- behind it moved every time the picker was used, which is the one thing a row
-- of buttons must never do.
function ns.BuildBracketPicker(frame,point,x,y)
	local names=ns.BRACKET_NAMES
	local buttons={}
	local previous

	for bracket=1,4 do
		local button=CreateFrame("Button",nil,frame,"UIPanelButtonTemplate")
		button:SetSize(46,20)
		button:SetText(names[bracket])
		button.bracket=bracket

		-- From the right, the row is built leftwards so the first button named
		-- still ends up leftmost on screen.
		local rightwards=point~="TOPRIGHT"

		if previous then
			if rightwards then
				button:SetPoint("LEFT",previous,"RIGHT",2,0)
			else
				button:SetPoint("RIGHT",previous,"LEFT",-2,0)
			end
		else
			button:SetPoint(rightwards and "TOPLEFT" or "TOPRIGHT",frame,point,x,y)
		end
		previous=button

		button:SetScript("OnClick",function(self)
			if ns.ViewBracket()==self.bracket then return end
			ns.SetViewBracket(self.bracket)

			-- Both windows read the same bracket, and the ladder's region
			-- resets with it, so whichever is open redraws itself.
			if ns.RefreshLadder then ns.RefreshLadder() end
			if ns.RefreshArenaHistory then ns.RefreshArenaHistory() end
			if ns.RefreshRatedPanel then ns.RefreshRatedPanel() end
		end)

		buttons[bracket]=button
	end

	return function()
		-- Hidden while the Rated page is up: that page is the picker there, and
		-- a second one beside it that has to agree is a thing to get wrong.
		local panel=ns.HistoryPanel and ns.HistoryPanel()
		local docked=panel and panel:IsVisible()
		local current=ns.ViewBracket()

		for bracket=1,4 do
			local button=buttons[bracket]
			button:SetShown(not docked)

			local active=bracket==current
			if active then button:Disable() else button:Enable() end

			local label=button.GetFontString and button:GetFontString()
			if label then
				if active then
					label:SetTextColor(1,0.82,0)
				else
					label:SetTextColor(0.75,0.75,0.75)
				end
			end
		end
	end
end

-- Forgotten when the windows close, so the next open works the bracket out
-- again rather than reopening on whatever was last poked at. Without this the
-- picker outlived the window: opening the history on a warrior whose last game
-- was 2v2 still showed 3v3, because 3v3 had been clicked half an hour earlier.
function ns.ClearViewBracket()
	chosenBracket=nil
end

function ns.SetViewBracket(bracket)
	if type(bracket)=="number" and bracket>=1 and bracket<=4 then
		chosenBracket=bracket
	end
end

function ns.ViewRegion()
	-- Changing bracket puts it back to yours.
	--
	-- Done by watching the bracket rather than by hooking whatever changes it:
	-- the selection can move without telling us, and every reader of this
	-- passes through here anyway.
	local bracket=ns.ViewBracket() or 0
	if bracket~=viewBracket then
		viewBracket=bracket

		-- Back to yours, but only against the Rated page. There the numbers are
		-- about you -- your rank, your rating, what you need for the next title
		-- -- so another region's cutoffs beside them would be nonsense.
		--
		-- In a window opened on its own you are reading somebody else's ladder
		-- on purpose, and having it jump home every time you changed bracket
		-- meant picking EU again for each one.
		local panel=ns.HistoryPanel and ns.HistoryPanel()
		if panel and panel:IsVisible() then viewRegion=nil end
	end

	viewRegion=viewRegion or ns.PlayerRegion() or "us"
	return viewRegion
end

function ns.SetViewRegion(region)
	viewRegion=region
end

function ns.ViewingOwnRegion()
	return ns.ViewRegion()==(ns.PlayerRegion() or "us")
end

-- The shipped tables for whichever region is being looked at.
--
-- ChooseRegion below sets ns.CUTOFFS and friends once at login for everything
-- that neither knows nor cares about regions. These are for the two windows
-- that do.
local function ForRegion(byRegion,fallback,region)
	region=region or ns.ViewRegion()
	if type(byRegion)=="table" and byRegion[region] then return byRegion[region] end
	return fallback
end

function ns.ViewCutoffs(region)      return ForRegion(ns.CUTOFFS_BY_REGION,ns.CUTOFFS,region) end
function ns.ViewCutoffSlots(region)  return ForRegion(ns.CUTOFF_SLOTS_BY_REGION,ns.CUTOFF_SLOTS,region) end
function ns.ViewLeaderboard(region)  return ForRegion(ns.LEADERBOARD_BY_REGION,ns.LEADERBOARD,region) end

-- Pick the region's numbers out of the files that shipped.
--
-- Each region is its own file writing its own key, and this chooses between
-- them once at load. Everything downstream still reads ns.CUTOFFS and
-- ns.LEADERBOARD and knows nothing about regions, which is the point: there is
-- one place where the wrong choice could be made rather than dozens.
--
-- No file for your region falls back to whatever did ship, and the warning
-- below then says so. Wrong numbers with an explanation beat no panel at all.
local function ChooseRegion()
	local mine=ns.PlayerRegion()

	local function pick(byRegion,fallback)
		if type(byRegion)~="table" then return fallback end
		if mine and byRegion[mine] then return byRegion[mine] end

		for _,data in pairs(byRegion) do return data end
		return fallback
	end

	ns.CUTOFFS=pick(ns.CUTOFFS_BY_REGION,ns.CUTOFFS)
	ns.CUTOFF_SLOTS=pick(ns.CUTOFF_SLOTS_BY_REGION,ns.CUTOFF_SLOTS)
	ns.LEADERBOARD=pick(ns.LEADERBOARD_BY_REGION,ns.LEADERBOARD)
end

-- Said once, at login, and only when it is wrong.
--
-- The cutoffs and the ladder are scraped for one region and shipped as files.
-- On the region they were taken from that is invisible and correct; on any
-- other it is silently wrong -- a European player would get American cutoffs,
-- a glow lighting the wrong title and a rank that means nothing, with no hint
-- that anything was amiss. The scripts take -Region, so the fix is one word;
-- knowing it is needed is the hard part.
local function CheckRegion()
	local mine=ns.PlayerRegion()
	local theirs=(ns.CUTOFFS and ns.CUTOFFS.region) or (ns.LEADERBOARD and ns.LEADERBOARD.region)

	if not (mine and theirs) then return end
	if mine==theirs then return end

	ns.Print(L.REGION_MISMATCH,theirs:upper(),mine:upper(),mine)
end

-- The gold level-up atlas, desaturated and then tinted, so one texture serves
-- every title colour.
local GLOW_ATLAS = "levelup-glow-gold"

-- Kept in a table of our own rather than hung off Blizzard's objects: writing
-- fields onto their frames is what taints them. Weak keys, so a frame going
-- away takes its glow with it.
local glows = setmetatable({},{ __mode="k" })

function ns.HexToRGB(hex)
	return tonumber(hex:sub(1,2),16)/255,
	       tonumber(hex:sub(3,4),16)/255,
	       tonumber(hex:sub(5,6),16)/255
end

-- Behind a number, in the colour of the title it is worth.
--
-- Shared because it is used at two very different sizes -- a 46 pixel row on
-- the PvP panel and an 18 pixel line in the cutoffs box -- so the height comes
-- in rather than being worked out from the owner.
--
-- Options, because there are five of them now and remembering their order was
-- never going to last:
--
--   height    how tall the glow is
--   width     how wide, defaulting to a little wider than it is tall
--   y         lifted by this much. The art sits low inside its own bounds, so
--             centring it on a line leaves it looking like an underline
--   layer     behind everything is right when the owner is one of Blizzard's
--             transparent rows, and invisible when the owner is a panel with a
--             background of its own -- that backdrop is in BACKGROUND too and
--             wins
--   sublevel  within that layer
function ns.SetGlow(owner,anchorTo,hex,opts)
	if not (owner and owner.CreateTexture) then return end
	opts=opts or {}

	local glow=glows[owner]
	if not glow then
		glow=owner:CreateTexture(nil,opts.layer or "BACKGROUND",nil,opts.sublevel or -1)
		glow:Hide()
		glows[owner]=glow
	end

	if not (hex and anchorTo) then
		glow.appliedHex=nil
		return glow:Hide()
	end

	-- Same tint as last time and already up: leave it alone, so a redraw does
	-- not restart the fade.
	if glow.appliedHex==hex and glow:IsShown() then return end
	glow.appliedHex=hex

	local height=opts.height or 32
	glow:SetSize(opts.width or height*1.05,height)
	glow:ClearAllPoints()
	glow:SetPoint("CENTER",anchorTo,"CENTER",opts.x or 0,opts.y or 0)

	-- A texture where one is named, the atlas otherwise.
	--
	-- The atlas fades left and right but ends flat top and bottom, which is
	-- invisible at the size the PvP panel uses it and looks sliced off on an
	-- eighteen pixel line. A caller working in a tight space passes something
	-- soft on all four sides instead.
	if opts.texture then
		glow:SetTexture(opts.texture)
		glow:SetBlendMode(opts.blend or "ADD")
	elseif glow.SetAtlas then
		glow:SetAtlas(GLOW_ATLAS)
		glow:SetBlendMode("BLEND")
	end

	if glow.SetDesaturated then glow:SetDesaturated(true) end
	if glow.SetVertexColor then glow:SetVertexColor(ns.HexToRGB(hex)) end
	glow:SetAlpha(opts.alpha or 1)

	glow:Show()
end

function ns.StyleAsPanel(frame)
	frame:SetBackdrop({
		bgFile="Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
		edgeFile="Interface\\DialogFrame\\UI-DialogBox-Border",
		tile=true,tileEdge=true,tileSize=32,edgeSize=32,
		insets={left=11,right=12,top=12,bottom=11}
	})
	frame:SetBackdropColor(0,0,0,1)
	frame:SetBackdropBorderColor(1,1,1,1)

	local solid=frame:CreateTexture(nil,"BACKGROUND",nil,-8)
	solid:SetPoint("TOPLEFT",frame,"TOPLEFT",11,-12)
	solid:SetPoint("BOTTOMRIGHT",frame,"BOTTOMRIGHT",-12,11)
	if solid.SetColorTexture then solid:SetColorTexture(0,0,0,1) else solid:SetTexture(0,0,0,1) end

	local tint=CreateFrame("Frame",nil,frame,"BackdropTemplate")
	tint:SetAllPoints()
	-- Pinned to the parent's own level so it stays behind the parent's
	-- FontStrings, which live at that level too -- a child frame otherwise
	-- draws its whole backdrop above them.
	tint:SetFrameLevel(frame:GetFrameLevel())
	tint:SetBackdrop({
		bgFile="Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile="Interface\\Tooltips\\UI-Tooltip-Border",
		tile=true,tileEdge=true,tileSize=16,edgeSize=16,
		insets={left=5,right=5,top=5,bottom=5}
	})
	tint:SetBackdropColor(TOOLTIP_DEFAULT_BACKGROUND_COLOR.r,TOOLTIP_DEFAULT_BACKGROUND_COLOR.g,TOOLTIP_DEFAULT_BACKGROUND_COLOR.b)
	tint:SetBackdropBorderColor(TOOLTIP_DEFAULT_COLOR.r,TOOLTIP_DEFAULT_COLOR.g,TOOLTIP_DEFAULT_COLOR.b)
end


----------------------------------------------------------------
-- Settings
----------------------------------------------------------------

-- A short list of ticks, one per tweak, and nothing else.
--
-- There was a settings window before, and it was removed on the grounds that
-- nothing in it was worth switching off. That was true of what existed then.
-- What has been added since is not all of the same kind: rated PvP on every
-- player tooltip is a thing some people will want and others will find
-- intrusive, which is exactly the sort of choice a settings window is for.
--
-- What it is not is the old one rebuilt. No sidebar, no per-tweak pages, no
-- sub-options -- one tick and one line of explanation each. If a tweak ever
-- needs a page of its own again, that is a sign the tweak is too complicated,
-- not that this window is too simple.
local CONFIG_WIDTH  = 460
local CONFIG_ROW    = 44

local function CreateConfig()
	if configFrame then return configFrame end

	local frame=CreateFrame("Frame","ArenaPlus_Config",UIParent,"BackdropTemplate")
	configFrame=frame
	frame:Hide()
	frame:SetPoint("CENTER",UIParent,"CENTER",0,0)
	frame:SetFrameStrata("DIALOG")
	frame:SetToplevel(true)
	frame:EnableMouse(true)
	frame:SetMovable(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart",frame.StartMoving)
	frame:SetScript("OnDragStop",frame.StopMovingOrSizing)
	ns.StyleAsPanel(frame)

	tinsert(UISpecialFrames,"ArenaPlus_Config")

	local title=frame:CreateFontString(nil,"OVERLAY","GameFontHighlightLarge")
	title:SetPoint("TOPLEFT",frame,"TOPLEFT",16,-14)
	title:SetText(L.WINDOW_TITLE)

	local close=CreateFrame("Button",nil,frame,"UIPanelCloseButton")
	close:SetPoint("TOPRIGHT",frame,"TOPRIGHT",0,0)

	local y=44
	frame.checks={}

	for _,key in ipairs(moduleOrder) do
		local module=ns.modules[key]

		local check=CreateFrame("CheckButton",nil,frame,"UICheckButtonTemplate")
		check:SetPoint("TOPLEFT",frame,"TOPLEFT",16,-y)
		check.module=module

		local label=check:CreateFontString(nil,"OVERLAY","GameFontNormal")
		label:SetPoint("LEFT",check,"RIGHT",4,0)
		label:SetText(module.enableLabel or module.title or key)

		local desc=frame:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
		desc:SetPoint("TOPLEFT",check,"BOTTOMLEFT",6,2)
		desc:SetWidth(CONFIG_WIDTH-48)
		desc:SetJustifyH("LEFT")
		desc:SetTextColor(0.55,0.55,0.55)
		desc:SetText(module.desc or "")

		check:SetScript("OnClick",function(self)
			ns.SetModuleEnabled(self.module,self:GetChecked() and true or false)
		end)

		frame.checks[#frame.checks+1]=check

		-- Two lines of description need more room than one.
		y=y+CONFIG_ROW+math.max(0,(desc:GetStringHeight() or 12)-12)

		-- A tweak may add a row of its own beneath, and says how tall it was.
		if module.BuildExtra then
			y=y+(module:BuildExtra(frame,desc) or 0)
		end
	end

	frame:SetSize(CONFIG_WIDTH,y+16)

	-- Read off the modules each time it opens rather than tracked: a tweak can
	-- be switched off from somewhere else, and a tick that disagrees with what
	-- is running is worse than no tick at all.
	frame:SetScript("OnShow",function(self)
		for _,check in ipairs(self.checks) do
			check:SetChecked(check.module.db and check.module.db.enabled)
		end
	end)

	return frame
end

function ns.ToggleConfig()
	local frame=CreateConfig()
	if frame:IsShown() then frame:Hide() else frame:Show() end
end

-- Was: there is no settings window, on purpose.
--
-- There was one: a page per tweak, each with a tick to switch it off. Every
-- tick was for something nobody would want off -- match history, an MMR
-- estimate, the cutoffs on the panel -- so the window existed to offer choices
-- that were not really choices, and each new feature quietly grew another.
--
-- Modules keep their `enabled` flag and their guards. It is forced on at load
-- and never written to, which costs nothing and leaves the seam in place should
-- something genuinely worth switching off ever turn up.

----------------------------------------------------------------
-- Slash command
----------------------------------------------------------------

----------------------------------------------------------------
-- The ladder
----------------------------------------------------------------

-- Whether somebody is on the top of their bracket's ladder.
--
-- Leaderboard.lua holds the top hundred of each, scraped out here because
-- addons have no network access. This is not for browsing -- the website does
-- that better -- it is so a name met in the arena can be recognised, which is a
-- different fact about a match than the rating alone.
local ladderIndex={}

-- One name written two ways is still one name.
--
-- The game calls a realm "Ra-den" and the site calls it "Raden"; elsewhere
-- there are spaces and apostrophes. Only those three are taken out -- anything
-- broader, such as keeping letters and digits alone, would eat the bytes of an
-- accented name and turn Bâz into Bz.
function ns.PlainName(text)
	return (text or ""):lower():gsub("[%s%-']","")
end

-- Indexed per region as well as per bracket.
--
-- Both regions ship, and a friend playing on the other one has to be looked up
-- in theirs: searching a EU name in the NA file finds nothing, which reads
-- exactly like "not on the ladder" and is not the same thing at all.
-- The eleven class slugs, longest first.
--
-- A spec slug is class and spec joined by a hyphen and *both halves can contain
-- one* -- death-knight-frost -- so the class cannot be found by splitting. It
-- has to be matched from a known list, longest first so "death-knight" wins
-- before anything shorter could.
local CLASS_SLUGS = {
	"death-knight","paladin","warrior","warlock","priest","shaman",
	"hunter","druid","mage","monk","rogue",
}

-- Class and spec, filled onto a ladder row from the separate specs file.
--
-- They are not in the leaderboard the ladder comes from: Blizzard publishes
-- ratings and ranks there and nothing about the character, so the spec is
-- fetched per character into its own file and joined back on here. Doing it in
-- this one place means every icon, colour and tooltip downstream carries on
-- reading entry.class and entry.spec exactly as it always did.
local function AttachSpec(entry,region)
	if entry.class or not entry.name then return end

	local specs=ns.SPECS_BY_REGION and ns.SPECS_BY_REGION[region]
	-- This region's own list. The two regions number their specs differently,
	-- so an index read against the other region's list names the wrong spec.
	local slugs=(ns.SPEC_SLUGS_BY_REGION and ns.SPEC_SLUGS_BY_REGION[region]) or ns.SPEC_SLUGS
	if not (specs and slugs) then return end

	local key=(entry.name.."-"..(entry.realm or "")):lower()
	-- Race and gender, written by the same pass that wrote the spec and stored
	-- as race times ten plus gender. Attached here so a row only has to read
	-- the entry it already has.
	local looks=ns.LOOKS_BY_REGION and ns.LOOKS_BY_REGION[region]
	local look=looks and looks[key]
	if look and look>0 then
		entry.race=math.floor(look/10)
		entry.gender=look%10
	end

	local recorded=specs[key]

	-- 0 means asked and refused: a hidden profile, or a character since renamed
	-- or transferred. Absent means nobody has asked yet, which is a different
	-- thing and must not read as hidden -- during the first pass that would be
	-- almost everybody.
	if recorded==0 then entry.hidden=true return end

	local slug=slugs[recorded or 0]
	if not slug then return end

	for _,class in ipairs(CLASS_SLUGS) do
		if slug:sub(1,#class+1)==class.."-" then
			entry.class=class
			entry.spec=slug:sub(#class+2)
			return
		end
	end
end

-- Every row of one bracket, with class and spec joined on.
--
-- Exposed because two different readers want it and only one of them used to
-- get it: the name index below, which serves tooltips, and the ladder window,
-- which reads the board straight and so never saw a spec at all.
--
-- Done once per bracket and region; the flag lives on the list itself.
function ns.LadderRows(bracket,region)
	region=region or ns.PlayerRegion() or "us"

	local board=(ns.LEADERBOARD_BY_REGION and ns.LEADERBOARD_BY_REGION[region]) or ns.LEADERBOARD
	local rows=(board and board[bracket]) or {}

	if not rows.specsAttached then
		for _,entry in ipairs(rows) do AttachSpec(entry,region) end
		rows.specsAttached=true
	end

	return rows
end

local function LadderFor(bracket,region)
	region=region or ns.PlayerRegion() or "us"

	ladderIndex[region]=ladderIndex[region] or {}
	if ladderIndex[region][bracket] then return ladderIndex[region][bracket] end

	local board=(ns.LEADERBOARD_BY_REGION and ns.LEADERBOARD_BY_REGION[region]) or ns.LEADERBOARD

	local index={}
	for _,entry in ipairs(ns.LadderRows(bracket,region)) do
		local name=ns.PlainName(entry.name)

		-- Keyed both ways round: the game reports a realm on cross-realm
		-- opponents and leaves it off your own, and the site always has one.
		-- Both halves have their own punctuation stripped first, so the hyphen
		-- joining them is the only one left and cannot be mistaken for part of
		-- a realm called Ra-den.
		index[name.."-"..ns.PlainName(entry.realm)]=entry

		-- The bare name answers only while it is unambiguous. Two realms with
		-- the same name on one ladder would otherwise vouch for each other.
		if index[name]==nil then
			index[name]=entry
		elseif index[name]~=entry then
			index[name]=false
		end
	end

	ladderIndex[region][bracket]=index
	return index
end

function ns.LadderEntry(bracket,name,region)
	if not (bracket and name and name~="") then return nil end

	local index=LadderFor(bracket,region)

	-- Split at the first hyphen only: what follows is the realm, and it may
	-- well contain hyphens of its own.
	local person,realm=name:match("^([^%-]+)%-(.+)$")
	person=person or name

	if realm then
		local found=index[ns.PlainName(person).."-"..ns.PlainName(realm)]
		if found then return found end
	end

	-- Realm-less, for an opponent from your own.
	local found=index[ns.PlainName(person)]
	if found then return found end

	return nil
end

----------------------------------------------------------------
-- What other addons may read
----------------------------------------------------------------

-- A global, because two addons cannot see each other's namespace.
--
-- Everything above this line is private to ArenaPlus and free to change. This
-- table is not: SocialPlus reads it to put a friend's rating in its tooltip,
-- and anything else may too. Additions are fine, removals and changes of shape
-- are not -- hence `version`, so a consumer can tell what it is talking to.
--
-- Whoever reads this must cope with it being absent: ArenaPlus is not required
-- by anything, and a tooltip that errors because a PvP addon is missing is a
-- worse failure than one that simply says nothing.
ArenaPlusAPI = {
	version = 1,

	-- 1 to 4, matching GetPersonalRatedInfo.
	BRACKETS = { "2v2", "3v3", "5v5", "Rated BG" },
}

-- A copy, never the live row.
--
-- These tables are the shipped ladder itself. Handed out directly, a consumer
-- holding onto one -- or writing to it -- would be editing our data, and the
-- resulting bug would surface here rather than where it was caused.
local function CopyEntry(entry)
	if not entry then return nil end
	return {
		rank   = entry.rank,
		name   = entry.name,
		realm  = entry.realm,
		rating = entry.rating,
		won    = entry.won,
		lost   = entry.lost,
		class  = entry.class,
		spec   = entry.spec,
	}
end

-- One bracket. `name` may carry a realm ("Somebody-Ra-den") or not.
-- `region` is optional: "us", "eu" and so on, defaulting to the player's own.
-- A friend on another region is on another ladder, and we ship both.
function ArenaPlusAPI.GetLadderBracket(bracket,name,region)
	if type(bracket)~="number" or bracket<1 or bracket>4 then return nil end
	return CopyEntry(ns.LadderEntry(bracket,name,region))
end

-- GetCurrentRegion's numbering, which is also what a Battle.net game account
-- reports, turned into the names the shipped files are keyed by.
function ArenaPlusAPI.RegionFromID(id)
	local names={ [1]="us", [2]="kr", [3]="eu", [4]="tw", [5]="cn" }
	return names[tonumber(id) or 0]
end

-- Whether a region was scraped at all. Only the two files ship, so a friend on
-- Korea or Taiwan can be answered honestly rather than as "not on the ladder".
function ArenaPlusAPI.HasRegion(region)
	if not region then return false end
	return (ns.LEADERBOARD_BY_REGION and ns.LEADERBOARD_BY_REGION[region])~=nil
end

-- Every bracket the player appears in, keyed by bracket number.
--
-- Nil rather than an empty table when they appear in none, so a caller can
-- skip the whole section with one test. Most players are in none: the ladder
-- stops at the Rival cutoff, which is a small share of everyone playing.
function ArenaPlusAPI.GetLadder(name,region)
	if not (name and name~="") then return nil end

	local found,any=nil,false
	for bracket=1,4 do
		local entry=CopyEntry(ns.LadderEntry(bracket,name,region))
		if entry then
			found=found or {}
			found[bracket]=entry
			any=true
		end
	end

	return any and found or nil
end

-- The spec icon for a ladder row, as a texture path.
--
-- Offered because the scrape names a spec rather than numbering it -- "priest"
-- and "shadow" -- and turning that pair into art needs the slug table and this
-- client's own icon overrides, both of which live in here. A consumer holding
-- an entry has the words and no way to draw them.
--
-- Per row, so a player who heals 2v2 and casts shadow in 3v3 gets the right
-- icon on each line rather than one guess for both.
function ArenaPlusAPI.GetSpecIcon(entry)
	if not (entry and entry.class and entry.spec) then return nil end
	if entry.class=="" or entry.spec=="" or entry.class=="null" then return nil end

	local id=ns.SPEC_BY_SLUG and ns.SPEC_BY_SLUG[entry.class.."-"..entry.spec]
	if not id then return nil end

	-- This client answers some specs with art from a later version of the game,
	-- so its own overrides win where they exist -- the same order the ladder
	-- window uses.
	if ns.SPEC_ICON and ns.SPEC_ICON[id] then return ns.SPEC_ICON[id] end

	if GetSpecializationInfoByID then
		local _,_,_,icon=GetSpecializationInfoByID(id)
		if icon then return icon end
	end

	return nil
end

-- The colour a place is worth, as a "ff8000" style hex.
--
-- Offered because a consumer cannot work it out: a title is a rating measured
-- against this season's cutoffs in that region, and those live here. Without
-- it every rating would come out one flat colour, which throws away the only
-- part of a number anybody reads at a glance.
function ArenaPlusAPI.GetRankColour(bracket,entry)
	if not (ns.RankHex and bracket and entry) then return nil end
	return ns.RankHex(bracket,entry)
end

-- Where the numbers came from, so a consumer can caption them honestly: this
-- is a snapshot of one region, up to a day old, not a live reading.
function ArenaPlusAPI.GetSource()
	local board=ns.LEADERBOARD
	return {
		region  = ns.PlayerRegion(),
		updated = board and board.checked or nil,
		count   = board and #(board[1] or {}) or 0,
	}
end

SLASH_ARENAPLUS1="/arenaplus"
SLASH_ARENAPLUS2="/arena"
-- Everything is a tick in the window, so the command has nothing to parse.
-- Subcommands, for the diagnostics a module wants to expose. A long /run gets
-- cut off by the chat box without saying so, which is why these live in here
-- rather than being handed over as one-liners.
ns.SlashCommands={}

-- Run the copy from QoLPlus again, whatever the flag says.
--
-- Here because the first attempt marked itself done having copied nothing, and
-- an addon that cannot be told to try again leaves hand-editing saved
-- variables as the only way out of that.
-- What the public lookup answers for a name.
--
-- The only way to see it before SocialPlus is wired up: the API has no UI of
-- its own, and "the tooltip shows nothing" cannot tell a broken lookup from a
-- friend who is simply not on the ladder. Try a name from the ladder window.
--
--   /arena who Gcwr
--   /arena who Gcwr-Ra-den
ns.SlashCommands["who"]=function(argument)
	local name=(argument or ""):match("^%s*(.-)%s*$")
	if name=="" then
		ns.Print("Usage: /arena who <name>, or <name-realm>.")
		return
	end

	local source=ArenaPlusAPI.GetSource()
	ns.Print("Ladder for %s, %d place(s) in 2v2, read %s.",
		tostring(source.region),source.count,tostring(source.updated))

	local found=ArenaPlusAPI.GetLadder(name)
	if not found then
		ns.Print("%s: nothing. Below the Rival cutoff, another region, or a different spelling.",name)
		return
	end

	for bracket=1,4 do
		local entry=found[bracket]
		if entry then
			ns.Print("  %-8s #%d  rating %d  %d-%d  %s %s",
				ArenaPlusAPI.BRACKETS[bracket],entry.rank,entry.rating,
				entry.won,entry.lost,entry.class or "?",entry.spec or "?")
		end
	end
end

-- The same window the minimap button's middle click opens.
--
-- Here because the minimap button is itself one of the ticks: switching it off
-- with no other way in would hide the only way to switch it back on.
ns.SlashCommands["config"]=function()
	if ns.ToggleConfig then ns.ToggleConfig() end
end

ns.SlashCommands["inherit"]=function()
	if not ArenaPlus_SavedVars then return end

	InheritFromQoLPlus(ArenaPlus_SavedVars,true)
	ns.Print(L.INHERIT_AGAIN)
end

SlashCmdList["ARENAPLUS"]=function(input)
	input=input or ""
	local command=input:lower():match("^%s*(%S*)")
	local handler=command~="" and ns.SlashCommands[command]

	-- Whatever followed the command word, so a subcommand can take arguments.
	-- Not lowercased: a name or a path would not survive it.
	if handler then return handler(input:match("^%s*%S+%s*(.*)$") or "") end

	-- No window to configure, so the plain command opens the thing you would
	-- have gone looking for.
	if ns.ToggleArenaHistory then ns.ToggleArenaHistory() end
end

----------------------------------------------------------------
-- Load
----------------------------------------------------------------

local loader=CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent",function(self,event,name)
	-- Our own ADDON_LOADED fires once every file in the .toc has run, so all
	-- the modules have registered themselves by the time we get here.
	if event=="ADDON_LOADED" and name==ADDON_NAME then
		InitDB()
		StartModules()
		self:UnregisterEvent("ADDON_LOADED")
		return
	end

	-- Everything has loaded by now, whatever order it went in, so this is the
	-- moment QoLPlus's saved variables are certain to be there if they are
	-- going to be. Does nothing on later logins.
	if event=="PLAYER_LOGIN" then
		if ArenaPlus_SavedVars then InheritFromQoLPlus(ArenaPlus_SavedVars) end

		-- Chosen at login rather than at load: GetCurrentRegion is not
		-- answerable until the world is up.
		ChooseRegion()
		CheckRegion()
		self:UnregisterEvent("PLAYER_LOGIN")
	end
end)
