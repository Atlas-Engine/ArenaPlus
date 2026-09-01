local ADDON_NAME, ns = ...
local L = ns.L

-- Shopping for somebody else's gems, from inside the auction house.
--
-- The gear panel already lists what a player gemmed and enchanted, and clicking
-- a line searches for it. That is the right list in the wrong place: you read it
-- on the ladder, then walk to a mailbox, then try to remember four gem names.
--
-- This puts the same list one button away from the search bar. Pick your spec,
-- pick one of the five best players in it, and their gems are on screen next to
-- the auction house you are standing at.
--
-- Only players we hold gear for are offered. The gear pass covers the top five
-- of each spec in each bracket, so those are exactly the people this can show,
-- and listing anybody else would be offering a window that opens empty.

local PANEL_WIDTH, PANEL_HEIGHT = 250, 374
local PLAYERS_SHOWN = 5

-- The same names and the same order as everywhere else in the addon --
-- literally the same list, so they cannot drift apart again.
local BRACKET_NAMES = ns.BRACKET_NAMES
local BRACKET_DEFAULT = 2

-- Both regions carry gear, and the best of a spec is not the same person in
-- each. Your own is where the window starts, since that is whose gems you are
-- most likely to be copying, but the other is one click away -- and a gem is a
-- gem whichever ladder the idea came from.
local REGIONS = { "us", "eu" }

local panel

-- ---------------------------------------------------------------- data

local QUESTION = "Interface/Icons/INV_Misc_QuestionMark"

-- The class the player is, spelled the way the ladder spells it.
local function MyClassSlug()
	local token = select(2, UnitClass("player"))
	if not token then return nil end

	token = token:lower()
	-- The game says DEATHKNIGHT, the ladder says death-knight.
	if token == "deathknight" then return "death-knight" end
	return token
end

-- The specs of the player's own class.
--
-- From the addon's own tables rather than from GetSpecializationInfo, which
-- this client does not answer: asked for its specs it returned nothing at all,
-- and the window came up empty saying so. The ladder has been drawing spec
-- icons all along through SPEC_BY_SLUG and SPEC_ICON, so those are what work
-- here, and this now uses the same road.
--
-- The slug carries the name: "priest-shadow" is a shadow priest, and the half
-- after the class is the spec, tidied for showing.
local function PrettySpec(slug)
	local text = slug:gsub("-", " ")
	return (text:gsub("(%a)([%w]*)", function(first, rest) return first:upper() .. rest end))
end

local function MySpecs()
	local mine = MyClassSlug()
	if not (mine and ns.SPEC_BY_SLUG) then return {} end

	local specs = {}
	for slug, id in pairs(ns.SPEC_BY_SLUG) do
		if slug:sub(1, #mine + 1) == mine .. "-" then
			local specSlug = slug:sub(#mine + 2)

			local icon = ns.SPEC_ICON and ns.SPEC_ICON[id]
			if not icon and GetSpecializationInfoByID then
				icon = select(4, GetSpecializationInfoByID(id))
			end

			specs[#specs + 1] = {
				id = id,
				slug = specSlug,
				name = PrettySpec(specSlug),
				icon = icon or QUESTION,
			}
		end
	end

	-- By spec id, so the three sit in the same order every time rather than in
	-- whatever order the table happened to be walked in.
	table.sort(specs, function(a, b) return a.id < b.id end)

	return specs
end

-- The best players of one spec in one bracket that we actually hold gear for.
--
-- One bracket at a time rather than the best of all four, because how a spec is
-- geared is not the same question in 2v2 as in rated battlegrounds -- and the
-- gear pass collects the top five of each spec in each bracket, so a bracket is
-- exactly the unit it holds.
local function TopOfSpec(classSlug, specSlug, bracket, region)
	local list = {}

	for _, entry in ipairs(ns.LadderRows and ns.LadderRows(bracket, region) or {}) do
		if entry.class == classSlug and entry.spec == specSlug and entry.rating then
			if ns.HasInspectData and ns.HasInspectData(entry.name, entry.realm, region) then
				list[#list + 1] = entry
			end
		end
	end

	-- The ladder arrives in rank order, so this is already sorted; sorted again
	-- rather than assumed, since it costs nothing on five rows.
	table.sort(list, function(a, b) return (a.rating or 0) > (b.rating or 0) end)

	while #list > PLAYERS_SHOWN do table.remove(list) end
	return list
end

-- What the window opens on, worked out fresh every time.
--
-- Deliberately not saved. Looking at another spec, bracket or region is a
-- glance at somebody else's gear, not a change of mind about who you are, and
-- coming back tomorrow to a window still set to EU rogues would be a small
-- puzzle every time.
local function Defaults()
	return {
		-- Our own SpecIndex and OwnSpecID rather than the plain calls: this
		-- client answers GetSpecialization() with nil unless it is told which
		-- spec group is active, which ArenaHistory already worked out.
		specID = ns.OwnSpecID and ns.OwnSpecID() or nil,
		-- The history's own answer, which already exists for this: the windows
		-- open on the bracket you last played, and reading the PvP page instead
		-- says 2v2 for a page nobody has opened.
		bracket = (ns.LastPlayedBracket and ns.LastPlayedBracket()) or BRACKET_DEFAULT,
		region = (ns.PlayerRegion and ns.PlayerRegion()) or "us",
	}
end

-- ---------------------------------------------------------------- window

-- Anything a previous version stored about where this window sat.
--
-- It was briefly draggable and remembered where it landed. Now that it is fixed
-- to the auction house, a leftover offset is not merely unused -- it is the one
-- thing that could still put the window somewhere wrong if this ever reads that
-- table again. Cleared once, rather than left as a trap.
local function ForgetStoredPosition()
	if ArenaPlus_SavedVars then ArenaPlus_SavedVars.auctionPvP = nil end
end

-- Named before they are written, because BuildPanel's drag handler calls
-- Attach and both of those are defined further down.
local Attach, OpenPanel

local function BuildPanel()
	if panel then return panel end

	-- A child of the auction house when there is one.
	--
	-- Parented to UIParent it was only ever *near* the house: its own scale,
	-- its own coordinates, and an offset tuned by eye on one monitor. A child
	-- inherits its parent's scale and position, so the two line up at any UI
	-- Scale and stay lined up if the house moves -- and it hides with the house
	-- for free.
	panel = CreateFrame("Frame", "ArenaPlus_AuctionPvP", AuctionHouseFrame or UIParent, "BackdropTemplate")
	panel:SetSize(PANEL_WIDTH, PANEL_HEIGHT)
	panel:Hide()

	-- Above the auction house, which is a high strata of its own: at HIGH this
	-- panel sat behind it and read as transparent when it was simply covered.
	panel:SetFrameStrata("FULLSCREEN_DIALOG")
	panel:SetToplevel(true)

	-- The same styling as every other window this addon puts up, so it looks
	-- like it belongs to the same addon.
	if ns.StyleAsPanel then ns.StyleAsPanel(panel) end

	-- Its own opaque layer under everything. The shared styling has a
	-- see-through layer, which is why the first version of this window showed
	-- the world through it -- the same fault the inspect panel had.
	local solid = panel:CreateTexture(nil, "BACKGROUND", nil, -7)
	solid:SetPoint("TOPLEFT", panel, "TOPLEFT", 11, -12)
	solid:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -12, 11)
	solid:SetColorTexture(0.04, 0.04, 0.05, 1)
	panel.solid = solid

	-- Takes the mouse, but does not move.
	--
	-- It was draggable, and dragging stored where it landed so the position
	-- survived a reload. That is the wrong trade for a window that belongs to
	-- another window: every stored position is a chance to be wrong, and "it
	-- opened somewhere odd" is a worse bug than "it cannot be nudged". Fixed to
	-- the auction house, there is exactly one place it can be.
	panel:EnableMouse(true)

	panel.title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	panel.title:SetPoint("TOP", 0, -14)
	panel.title:SetText(L.AH_PVP_TITLE)

	local close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -4, -4)

	-- Filled in by RefreshSpecs, which runs every time the window opens rather
	-- than once when it is made: whether the client will name your specs is not
	-- something to find out once and then live with.
	panel.specs = {}

	-- Which bracket, under the specs. Four small buttons rather than a dropdown:
	-- there are only ever four and they are worth being able to flick between.
	panel.bracket = BRACKET_DEFAULT
	panel.brackets = {}

	for index, name in ipairs(BRACKET_NAMES) do
		local tab = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
		tab:SetSize(50, 20)
		tab:SetPoint("TOPLEFT", 18 + (index - 1) * 54, -80)
		tab:SetText(name)
		tab.bracket = index

		tab:SetScript("OnClick", function(self)
			panel.bracket = self.bracket
			if panel.spec then ns.AuctionPvPShow(panel.spec) end
		end)

		panel.brackets[index] = tab
	end

	-- Which region, beside the brackets.
	panel.region = (ns.PlayerRegion and ns.PlayerRegion()) or "us"
	panel.regions = {}

	for index, region in ipairs(REGIONS) do
		-- A flag on its own, as on the ladder: no border, since the frame
		-- around a flag reads as a stamp rather than a button.
		local tab = CreateFrame("Button", nil, panel)
		tab:SetSize(40, 20)
		tab:SetPoint("TOPLEFT", 18 + (index - 1) * 44, -104)
		tab.region = region

		tab.flag = tab:CreateTexture(nil, "ARTWORK")
		tab.flag:SetPoint("CENTER")

		if ns.SetRegionFlag and ns.SetRegionFlag(tab.flag, region, 14) then
			tab:SetWidth(tab.flag:GetWidth() + 8)

			local glow = tab:CreateTexture(nil, "HIGHLIGHT")
			glow:SetAllPoints(tab.flag)
			glow:SetColorTexture(1, 1, 1, 0.18)
			tab:SetHighlightTexture(glow)
		else
			-- Nothing to draw, so the letters and their frame come back. The
			-- borderless one is hidden rather than left behind: it has no art,
			-- so it would be an invisible frame still taking clicks.
			tab.flag:Hide()
			tab:Hide()
			tab = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
			tab:SetSize(40, 20)
			tab:SetPoint("TOPLEFT", 18 + (index - 1) * 44, -104)
			tab.region = region
			tab:SetText(ns.RegionShort and ns.RegionShort(region) or region:upper())
		end

		tab:SetScript("OnClick", function(self)
			panel.region = self.region
			if panel.spec then ns.AuctionPvPShow(panel.spec) end
		end)

		panel.regions[index] = tab
	end

	panel.note = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	panel.note:SetPoint("TOPLEFT", 18, -132)
	panel.note:SetPoint("TOPRIGHT", -18, -132)
	panel.note:SetJustifyH("LEFT")
	panel.note:SetText(L.AH_PVP_PICK)

	-- One row per player.
	panel.rows = {}
	for index = 1, PLAYERS_SHOWN do
		local row = CreateFrame("Button", nil, panel)
		row:SetSize(PANEL_WIDTH - 36, 30)
		if index == 1 then
			row:SetPoint("TOPLEFT", 18, -152)
		else
			row:SetPoint("TOPLEFT", panel.rows[index - 1], "BOTTOMLEFT", 0, -4)
		end

		local glow = row:CreateTexture(nil, "HIGHLIGHT")
		glow:SetAllPoints()
		glow:SetColorTexture(1, 1, 1, 0.10)
		row:SetHighlightTexture(glow)

		row.rank = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		row.rank:SetPoint("LEFT", 2, 0)
		row.rank:SetWidth(28)
		row.rank:SetJustifyH("LEFT")

		row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		row.name:SetPoint("LEFT", row.rank, "RIGHT", 4, 6)
		row.name:SetPoint("RIGHT", -4, 0)
		row.name:SetJustifyH("LEFT")

		row.detail = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
		row.detail:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -2)
		row.detail:SetJustifyH("LEFT")

		row:SetScript("OnClick", function(self)
			if not self.entry then return end

			-- The region the row came from, not the one you play in: opening a
			-- EU player against the US tables would find nobody.
			local region = panel.region

			-- Straight to the gems, because that is what this window is for.
			if ns.ShowInspect then ns.ShowInspect(self.entry, region, panel.bracket) end
			if ns.InspectShowPage then ns.InspectShowPage("sockets") end
		end)

		row:Hide()
		panel.rows[index] = row
	end

	panel.hint = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	panel.hint:SetPoint("BOTTOMLEFT", 18, 14)
	panel.hint:SetPoint("BOTTOMRIGHT", -18, 14)
	panel.hint:SetJustifyH("LEFT")
	panel.hint:SetText(L.AH_PVP_HINT)

	return panel
end

-- The spec buttons, made on first sight and kept.
local function RefreshSpecs()
	local specs = MySpecs()

	for index, spec in ipairs(specs) do
		local button = panel.specs[index]

		if not button then
			button = CreateFrame("Button", nil, panel)
			button:SetSize(36, 36)
			button:SetPoint("TOPLEFT", 18 + (index - 1) * 44, -38)

			button.icon = button:CreateTexture(nil, "ARTWORK")
			button.icon:SetAllPoints()
			button.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

			-- A border, so an icon on a dark panel reads as a button.
			button.edge = button:CreateTexture(nil, "BORDER")
			button.edge:SetPoint("TOPLEFT", -2, 2)
			button.edge:SetPoint("BOTTOMRIGHT", 2, -2)
			button.edge:SetColorTexture(0.35, 0.35, 0.35, 1)

			-- Which one is chosen, since dimmed icons and one bright one is the
			-- whole state this window has.
			button.chosen = button:CreateTexture(nil, "OVERLAY")
			button.chosen:SetAllPoints()
			button.chosen:SetColorTexture(1, 0.82, 0, 0.25)
			button.chosen:Hide()

			button:SetScript("OnEnter", function(self)
				GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
				GameTooltip:SetText(self.spec and self.spec.name or "")
				GameTooltip:Show()
			end)
			button:SetScript("OnLeave", function() GameTooltip:Hide() end)
			button:SetScript("OnClick", function(self)
				if self.spec then ns.AuctionPvPShow(self.spec) end
			end)

			panel.specs[index] = button
		end

		button.spec = spec
		button.icon:SetTexture(spec.icon)
		button:Show()
	end

	for index = #specs + 1, #panel.specs do panel.specs[index]:Hide() end

	return specs
end

-- Fill the list for one spec.
function ns.AuctionPvPShow(spec)
	BuildPanel()
	RefreshSpecs()

	local classSlug = MyClassSlug() or ""

	panel.spec = spec

	-- The chosen spec in colour, the others grey. Desaturated rather than
	-- merely dimmed: three lit icons with one slightly brighter is a thing you
	-- have to compare, and grey against colour is a thing you just see.
	for _, button in ipairs(panel.specs) do
		local chosen = (button.spec.id == spec.id)

		button.chosen:SetShown(chosen)
		button.icon:SetDesaturated(not chosen)
		button.icon:SetAlpha(chosen and 1 or 0.4)
		button.edge:SetColorTexture(chosen and 0.9 or 0.3, chosen and 0.75 or 0.3, chosen and 0.2 or 0.3, 1)
	end

	-- The chosen bracket and region, shown by their buttons being the ones that
	-- are not dimmed.
	for index, tab in ipairs(panel.brackets) do
		tab:SetAlpha(index == panel.bracket and 1 or 0.5)
	end
	for _, tab in ipairs(panel.regions) do
		if tab.flag and tab.flag:IsShown() then
			ns.LightRegionFlag(tab.flag, tab.region == panel.region)
		else
			tab:SetAlpha(tab.region == panel.region and 1 or 0.5)
		end
	end

	local bracketName = BRACKET_NAMES[panel.bracket] or "?"
	-- The region is not named here. The two flags sit lit and grey a few
	-- pixels above this line, which says the same thing better than repeating
	-- it in the sentence did.
	local list = TopOfSpec(classSlug, spec.slug, panel.bracket, panel.region)

	panel.note:SetText(#list > 0
		and L.AH_PVP_TOP:format(spec.name, bracketName)
		or L.AH_PVP_NONE:format(spec.name, bracketName))

	for index, row in ipairs(panel.rows) do
		local entry = list[index]
		if not entry then
			row:Hide()
		else
			row.entry = entry
			row.rank:SetText(("|cffffd100#%d|r"):format(index))

			local who = entry.name or "?"
			row.name:SetText(who)

			local realm = entry.realm or ""
			row.detail:SetText(("%d  %s"):format(entry.rating or 0, realm))
			row:Show()
		end
	end

	panel:Show()
end

-- Put it back against the auction house.
--
-- Frames and artwork are not the same rectangle, and this is the whole of why
-- it looked crooked while being anchored perfectly. Measured with
-- /arena ahalign:
--
--   auction house  L36 T844 R836 B306   scale 0.800
--   top pvp gear   L825 T844 R1075 B470 scale 0.800
--   horizontal -11.0 (anchored at -11)  vertical 0.0 (anchored at 0)
--
-- Both tops on 844 exactly: the frames agreed and the windows still did not
-- line up. This panel's opaque layer starts 11 in and 12 down from its own
-- corner, while the auction house draws from textures with no backdrop inset to
-- read -- its art begins at its frame edge. So the horizontal already
-- compensated and the vertical never did.
--
-- Then measured again, because a correction that assumed which way the art was
-- offset overshot. What the textures actually say:
--
--   auction house  NineSlice top 844   = its frame top
--   top pvp gear   opaque fill top    -12 from its frame top
--
-- The two windows cannot be aligned by both criteria at once, because their
-- borders are different thicknesses. At 0 the *borders* meet exactly, both on
-- 844, and our darker fill starts 12 lower. At 12 the *fills* meet and our
-- border stands 12 proud of theirs.
--
-- Settled by looking: -1, 1.
--
-- Worth saying that neither reading won. The measurements narrowed each axis to
-- a choice of two -- borders meeting (0) or fills meeting (-11 across, -12
-- down) -- and the answer was a unit off *border* to border on both, which is
-- neither. Two windows with borders of different thicknesses do not have a
-- correct offset, only one that reads as deliberate, and no amount of reading
-- texture bounds produces it.
--
-- The arithmetic was still worth doing: it is what turned an open-ended nudge
-- into a one-unit correction from a known reference, and it is what says these
-- numbers hold at any UI scale rather than only on the monitor they were found
-- on.
--
-- Re-measure or re-nudge with /arena ahalign, which takes <x> <y> and moves the
-- window live. Both numbers are relative to the auction house's own corner, so
-- they only need revisiting if Blizzard changes that window's art.
local ATTACH_X, ATTACH_Y = -1, 1

function Attach()
	if not (panel and AuctionHouseFrame) then return end

	-- Re-parented as well as re-anchored: the panel may have been built before
	-- the auction house existed, in which case it is still a child of UIParent
	-- and would not follow the house at all.
	if panel:GetParent() ~= AuctionHouseFrame then
		panel:SetParent(AuctionHouseFrame)
		panel:SetFrameStrata("FULLSCREEN_DIALOG")
		panel:SetToplevel(true)
	end

	ForgetStoredPosition()

	panel:ClearAllPoints()
	panel:SetPoint("TOPLEFT", AuctionHouseFrame, "TOPRIGHT", ATTACH_X, ATTACH_Y)

	-- Anything already hanging off this one comes with it.
	if ns.InspectReanchor then ns.InspectReanchor() end
end

-- Everything that opening it involves, in one place.
--
-- It was inline in the button's OnClick, which was fine while clicking the
-- button was the only way in. Opening with the auction house needs the same
-- steps, and two copies of them would drift.
function OpenPanel()
	BuildPanel()
	Attach()
	panel:Show()

	-- Back to your own spec, your last bracket and your own region every time
	-- it opens, whatever was being looked at when it was closed.
	local want = Defaults()
	panel.bracket = want.bracket
	panel.region = want.region

	local specs = RefreshSpecs()

	-- Matched by id rather than by position: our list is sorted by spec id and
	-- the game's index is its own ordering.
	local chosen = specs[1]
	if want.specID then
		for _, spec in ipairs(specs) do
			if spec.id == want.specID then chosen = spec break end
		end
	end

	if chosen then
		ns.AuctionPvPShow(chosen)
	else
		-- Said out loud rather than shown as an empty row of nothing.
		panel.note:SetText(L.AH_PVP_NO_SPECS)
	end
end

-- Where the three windows actually are, in the game's own numbers.
--
-- The panel anchors TOPLEFT to the auction house's TOPRIGHT, which lines up the
-- two *frames*. What a player sees is the two backdrops, and a frame is not its
-- backdrop: Blizzard's windows carry transparent padding, and the portrait on
-- this one hangs above the frame entirely. So "aligned" by anchor can still
-- read as crooked, and the correction is whatever the difference turns out to
-- be rather than whatever looks right in a screenshot.
--
--   open the auction house, click a player, then: /arena ahalign
ns.SlashCommands["ahalign"] = function(argument)
	-- With a number, move it and look: the alignment that reads best is a
	-- judgement about two borders of different thicknesses, and that is settled
	-- by looking rather than by arithmetic. Not saved -- tell me the number
	-- that wins and it goes in the file, where it belongs.
	local first, second = (argument or ""):match("^%s*(-?%d+)%s*(-?%d*)%s*$")
	if first then
		if second and second ~= "" then
			ATTACH_X, ATTACH_Y = tonumber(first), tonumber(second)
		else
			-- One number is the vertical, which is the axis that needed
			-- settling first and the one most likely to be tweaked again.
			ATTACH_Y = tonumber(first)
		end

		if Attach then Attach() end
		ns.Print("offset now x=%d y=%d. No number measures instead; the pair is x then y.",
			ATTACH_X, ATTACH_Y)
		return
	end

	local function Say(frame, label)
		if not frame then
			ns.Print("  %s: not there", label)
			return
		end
		if not frame:IsShown() then
			ns.Print("  %s: exists but hidden", label)
			return
		end

		ns.Print("  %-14s L%.0f T%.0f R%.0f B%.0f   %.0fx%.0f   scale %.3f",
			label,
			frame:GetLeft() or 0, frame:GetTop() or 0,
			frame:GetRight() or 0, frame:GetBottom() or 0,
			frame:GetWidth() or 0, frame:GetHeight() or 0,
			frame:GetEffectiveScale() or 0)
	end

	local house = AuctionHouseFrame
	local shelf = _G.ArenaPlus_AuctionPvP
	local gems  = _G.ArenaPlus_Inspect

	ns.Print("frames, in UI units:")
	Say(house, "auction house")
	Say(shelf, "top pvp gear")
	Say(gems,  "shopping list")

	-- The number that matters. Anchored TOPLEFT to TOPRIGHT, these should be
	-- zero apart in the vertical and ATTACH_X apart in the horizontal; whatever
	-- they are instead is the correction to apply.
	if house and shelf and house:IsShown() and shelf:IsShown() then
		ns.Print("gaps, house -> panel:")
		ns.Print("  horizontal %.1f  (anchored at %d)", (shelf:GetLeft() or 0) - (house:GetRight() or 0), ATTACH_X)
		ns.Print("  vertical   %.1f  (anchored at %d)", (shelf:GetTop() or 0) - (house:GetTop() or 0), ATTACH_Y)
	end

	if shelf and gems and shelf:IsShown() and gems:IsShown() then
		ns.Print("gaps, panel -> shopping list:")
		ns.Print("  horizontal %.1f", (gems:GetLeft() or 0) - (shelf:GetRight() or 0))
		ns.Print("  vertical   %.1f", (gems:GetTop() or 0) - (shelf:GetTop() or 0))
	end

	-- Where the paint actually is.
	--
	-- The frame numbers above already agreed once while the windows plainly did
	-- not line up, and guessing which way the art was offset from that made it
	-- worse. A frame is an invisible rectangle; what a player sees is textures,
	-- and those have their own edges. So this reads them.
	local function Extent(frame, label)
		if not (frame and frame:IsShown()) then return end

		local top, left, right, bottom
		for _, region in ipairs({ frame:GetRegions() }) do
			if region.GetObjectType and region:GetObjectType() == "Texture"
				and region:IsShown() and region:GetTop() then
				top    = math.max(top or -99999, region:GetTop())
				bottom = math.min(bottom or 99999, region:GetBottom() or 99999)
				left   = math.min(left or 99999, region:GetLeft() or 99999)
				right  = math.max(right or -99999, region:GetRight() or -99999)
			end
		end

		if top then
			ns.Print("  %-14s textures  L%.0f T%.0f R%.0f B%.0f", label, left, top, right, bottom)
			ns.Print("       vs frame            %+.0f  %+.0f  %+.0f  %+.0f",
				left - (frame:GetLeft() or 0), top - (frame:GetTop() or 0),
				right - (frame:GetRight() or 0), bottom - (frame:GetBottom() or 0))
		else
			ns.Print("  %-14s no textures of its own (drawn by children)", label)
		end
	end

	ns.Print("painted edges, and how far they sit from the frame:")
	Extent(house, "auction house")
	Extent(shelf, "top pvp gear")

	-- Modern Blizzard windows put their border in a NineSlice child, which is
	-- the thing whose top edge a player reads as "the top of the window".
	if house and house.NineSlice and house.NineSlice:GetTop() then
		ns.Print("  auction house NineSlice top %.0f  (frame top %.0f, difference %+.0f)",
			house.NineSlice:GetTop(), house:GetTop() or 0,
			house.NineSlice:GetTop() - (house:GetTop() or 0))
	else
		ns.Print("  auction house has no NineSlice")
	end

	if shelf and shelf.solid and shelf.solid:GetTop() then
		ns.Print("  top pvp gear opaque top %.0f  (frame top %.0f, difference %+.0f)",
			shelf.solid:GetTop(), shelf:GetTop() or 0,
			shelf.solid:GetTop() - (shelf:GetTop() or 0))
		ns.Print("  top pvp gear opaque left %.0f  (frame left %.0f, difference %+.0f)",
			shelf.solid:GetLeft() or 0, shelf:GetLeft() or 0,
			(shelf.solid:GetLeft() or 0) - (shelf:GetLeft() or 0))
	end

	-- The horizontal has the same two readings as the vertical had. Border to
	-- border is our frame left meeting their frame right; fill to fill is 11
	-- further in, which is what -11 has been doing all along and why the gap
	-- looked closed while the tops did not.
	if house and shelf and house:IsShown() and shelf:IsShown() then
		ns.Print("  borders meet at x=%d, fills meet at x=%d, currently x=%d",
			0, -11, ATTACH_X)
	end

	ns.Print("ATTACH_Y is %d. Add whatever the two painted tops differ by.", ATTACH_Y)
end

-- ---------------------------------------------------------------- the button

local hooked = false

local function PlaceButton()
	if hooked then return end

	-- The modern auction house, which is what this client has: a search bar
	-- with a Filter button on its right. The button goes to the left of it,
	-- where there is room and where the eye already is.
	local bar = AuctionHouseFrame and AuctionHouseFrame.SearchBar
	local anchor = bar and (bar.FilterButton or bar.SearchButton)
	if not anchor then return end

	local button = CreateFrame("Button", "ArenaPlus_AuctionPvPButton", bar, "UIPanelButtonTemplate")
	button:SetSize(56, 22)
	button:SetText(L.AH_PVP_BUTTON)
	button:SetPoint("RIGHT", anchor, "LEFT", -4, 0)

	-- The button is now a way to put it *back*, since it opens with the house.
	button:SetScript("OnClick", function()
		BuildPanel()
		if panel:IsShown() then
			panel:Hide()
			return
		end
		OpenPanel()
	end)

	button:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText(L.AH_PVP_TOOLTIP, nil, nil, nil, nil, true)
		GameTooltip:Show()
	end)
	button:SetScript("OnLeave", function() GameTooltip:Hide() end)

	hooked = true
end

-- The auction house frame is loaded on demand, so the button cannot be made
-- until it exists. Both the addon loading and the house opening are watched,
-- because either can happen first.
local watcher = CreateFrame("Frame")
watcher:RegisterEvent("AUCTION_HOUSE_SHOW")
watcher:RegisterEvent("ADDON_LOADED")
watcher:SetScript("OnEvent", function(_, event, name)
	if event == "ADDON_LOADED" and name ~= "Blizzard_AuctionHouseUI" then return end
	-- The button, and only the button.
	--
	-- This used to open the panel with the house as well, on the reasoning
	-- that somebody at an auctioneer probably wants it. Usually they do not:
	-- most trips to the auction house are about something else entirely, and a
	-- panel that opens itself over the search box every time is in the way far
	-- more often than it is wanted.
	--
	-- The button is the whole answer. It sits there saying what it does, and
	-- one click is a smaller price than closing a window on every visit.
	PlaceButton()
end)

-- Closed with the house it belongs to.
local closer = CreateFrame("Frame")
closer:RegisterEvent("AUCTION_HOUSE_CLOSED")
closer:SetScript("OnEvent", function()
	if panel then panel:Hide() end
end)
