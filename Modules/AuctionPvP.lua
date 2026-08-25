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

local function BuildPanel()
	if panel then return panel end

	panel = CreateFrame("Frame", "ArenaPlus_AuctionPvP", UIParent, "BackdropTemplate")
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

	panel:EnableMouse(true)
	panel:SetMovable(true)
	panel:RegisterForDrag("LeftButton")
	panel:SetScript("OnDragStart", panel.StartMoving)
	panel:SetScript("OnDragStop", panel.StopMovingOrSizing)

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

	button:SetScript("OnClick", function()
		BuildPanel()
		if panel:IsShown() then
			panel:Hide()
			return
		end

		-- Beside the auction house rather than over it: the whole point is to
		-- read one and type into the other.
		--
		-- Pulled back rather than pushed out. Both windows carry a border whose
		-- outer edge is transparent -- ours starts eleven pixels in, and the
		-- auction house has padding of its own -- so butting the two frames
		-- together at zero leaves a gap the width of both.
		--
		-- Fifteen, settled by looking. Twenty-seven closed the gap completely
		-- and went too far: the auction house keeps its close button in that
		-- corner and the panel started covering it.
		panel:ClearAllPoints()
		panel:SetPoint("TOPLEFT", AuctionHouseFrame, "TOPRIGHT", -15, 0)
		panel:Show()

		-- Back to your own spec, your last bracket and your own region every
		-- time it opens, whatever was being looked at when it was closed.
		local want = Defaults()
		panel.bracket = want.bracket
		panel.region = want.region

		local specs = RefreshSpecs()

		-- Matched by id rather than by position: our list is sorted by spec id
		-- and the game's index is its own ordering.
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
	PlaceButton()
end)

-- Closed with the house it belongs to.
local closer = CreateFrame("Frame")
closer:RegisterEvent("AUCTION_HOUSE_CLOSED")
closer:SetScript("OnEvent", function()
	if panel then panel:Hide() end
end)
