local ADDON_NAME, ns = ...
local L = ns.L

-- What one ladder character is wearing, running and glyphed with.
--
-- The panel this replaces was cut because the gear behind it was scraped, and
-- scraping every top player's kit was more traffic than a third-party site
-- should be asked for. Blizzard publishes all of it first-party, so the data is
-- ours to take and the panel can come back.
--
-- Laid out as Blizzard's own inspect window: a paper doll, and tabs along the
-- foot for Character, PvP and Talents. Guild is not among them -- the
-- leaderboard does not carry one, and a tab that is always empty is worse than
-- no tab.
--
-- Everything shown is read out of Inspect-<region>.lua, which covers the top
-- 100 of each bracket. Deeper rows have nothing to show, and neither do hidden
-- profiles -- one in five at the top of the US ladder, which is why the empty
-- case is a written sentence rather than a blank window.

local WIDTH, HEIGHT = 660, 560
local SLOT_SIZE     = 40
local SLOT_GAP      = 6
-- The band across the top of the window, and where content begins under it.
--
-- TOP is derived rather than chosen. Every page places its contents from TOP,
-- so as long as TOP is the bottom of the band plus a gap, changing the header
-- moves all four pages with it. When the two were separate numbers that
-- happened to agree, adding the band put the talent grid inside the title bar
-- and left the PvP rows flush against it -- one edit, three places to notice.
local BAND_INSET    = 12
local BAND_HEIGHT   = 52
local BAND_GAP      = 12
local TOP           = -(BAND_INSET+BAND_HEIGHT+BAND_GAP)
local FOOT          = 44          -- room for the tab row

local BRACKET_NAMES = ns.BRACKET_NAMES

-- Only the three the gear proves. Blizzard's classic API has no professions
-- endpoint -- it 404s -- so these are read off what somebody could not have
-- fitted without the profession: a tinker, an enchanted ring of their own, an
-- extra socket somewhere no belt buckle can go.
-- Every major glyph of a class shares one icon in this expansion, and every
-- minor glyph another, so the class is enough to draw them properly. The API
-- hands back only a glyph's name and id -- no item, no spell, nothing the
-- client can resolve -- so this is the whole of what is available.
local GLYPH_ICON_CLASS = {
	warrior="Warrior", paladin="Paladin", hunter="Hunter", rogue="Rogue",
	priest="Priest", ["death-knight"]="DeathKnight", shaman="Shaman",
	mage="Mage", warlock="Warlock", monk="Monk", druid="Druid",
}

-- Whether a glyph is major or minor.
--
-- Two pages ask now -- the talent page draws them under the grid, the shopping
-- list puts them beside the gems -- and the awkward part is worth getting right
-- only once: three of a character's six are minor and Blizzard's profile does
-- not say which, so the answer comes from the game's own GlyphProperties table,
-- falling back to whatever /arena glyphs has recorded for classes shipped after
-- that harvest.
local function GlyphKind(glyphID)
	-- Numbers only, from either source.
	--
	-- The first version of /arena glyphs stored a table per entry and keyed it
	-- wrongly, so a saved-variables file written before it was fixed still holds
	-- {name=...,kind=...} at ids 1 and 2. Reading that back as a type would
	-- compare a table against 1 and quietly draw nothing; ignoring anything that
	-- is not a number costs one check and makes the old rubbish inert.
	local kind=ns.GLYPH_TYPE and ns.GLYPH_TYPE[glyphID]
	if type(kind)=="number" then return kind end

	local learned=ArenaPlus_SavedVars and ArenaPlus_SavedVars.glyphTypes
	kind=learned and learned[glyphID]
	if type(kind)=="number" then return kind end

	return nil
end

-- The glyphs a character wears, in a settled order: major first, then minor,
-- then anything we cannot place, and alphabetical within each group so the same
-- character reads the same way every time.
local function GlyphList(ids)
	local out={}
	for _,glyphID in ipairs(ids or {}) do
		out[#out+1]={
			id   = glyphID,
			kind = GlyphKind(glyphID),
			name = (ns.GLYPH_NAMES and ns.GLYPH_NAMES[glyphID])
				or L.INSPECT_GLYPH_UNKNOWN:format(glyphID),
		}
	end

	table.sort(out,function(a,b)
		local ka,kb=a.kind or 3,b.kind or 3
		if ka~=kb then return ka<kb end
		return a.name<b.name
	end)

	return out
end

-- The body to show, by race and gender.
--
-- SetCustomRace does not exist on this client -- asked, and told no -- so the
-- model is set by display id instead, which does. These are the long-standing
-- player display ids; a wrong one here shows the wrong body, so a race not
-- listed falls back to the viewer's own rather than guessing at a number.
local RACE_DISPLAY = {
	[1]  = { 49, 50 },        -- human
	[2]  = { 51, 52 },        -- orc
	[3]  = { 53, 54 },        -- dwarf
	[4]  = { 55, 56 },        -- night elf
	[5]  = { 57, 58 },        -- undead
	[6]  = { 59, 60 },        -- tauren
	[7]  = { 1563, 1564 },    -- gnome
	[8]  = { 1478, 1479 },    -- troll
	[10] = { 15476, 15475 },  -- blood elf
	[11] = { 16125, 16126 },  -- draenei
}

local PROFESSION_ICONS = {
	engineering    = "Interface/Icons/Trade_Engineering",
	enchanting     = "Interface/Icons/Trade_Engraving",
	blacksmithing  = "Interface/Icons/Trade_BlackSmithing",
	tailoring      = "Interface/Icons/Trade_Tailoring",
}

-- Blizzard's own paper doll order, so the panel reads the way the character
-- sheet does rather than the order the API happened to answer in.
-- The belt buckle, by name rather than by number.
--
-- Two wrong ids were written here before this. 55054 is the Cataclysm buckle,
-- which resolves and names a real belt buckle of the wrong expansion. 82443 is
-- Cerulean Spellthread, which resolves and names a leg enchant -- and printed
-- "Cerulean Spellthread" beside somebody's belt, in the shopping list, looking
-- exactly like a fact.
--
-- Both failed the same way: a guessed id turns into a confident name. So the
-- name is the constant now and the id, if it is ever wanted, is looked up from
-- it. Get the name wrong and nothing resolves at all, which is a mistake that
-- shows itself.
local BELT_BUCKLE_NAME = "Living Steel Belt Buckle"
local BELT_BUCKLE      = 90046

-- The item, and only if it really is the item.
--
-- The id buys the icon, the quality colour and the tooltip link, none of which
-- a name alone can give. What it must not buy is the label: two ids have been
-- wrong here already and each one turned straight into a confident wrong name
-- on screen.
--
-- So the id is checked against the name before anything from it is used. An id
-- that resolves to something else is treated as no id at all, which turns the
-- next wrong guess into a missing icon rather than a lie.
local function BuckleItem()
	if not (GetItemInfo and BELT_BUCKLE) then return nil end

	local name,link,quality=GetItemInfo(BELT_BUCKLE)

	if not name then
		if C_Item and C_Item.RequestLoadItemDataByID then
			pcall(C_Item.RequestLoadItemDataByID,BELT_BUCKLE)
		end
		return nil
	end

	if name~=BELT_BUCKLE_NAME then return nil end

	return name,link,quality,select(10,GetItemInfo(BELT_BUCKLE))
end

-- Declared here and written further down, because the paper doll draws long
-- before the socket page is defined and both have to ask the same question.
local HasBuckle

local LEFT_SLOTS   = { "head", "neck", "shoulder", "back", "chest", "shirt", "tabard", "wrist" }
local RIGHT_SLOTS  = { "hands", "waist", "legs", "feet", "finger_1", "finger_2", "trinket_1", "trinket_2" }
local BOTTOM_SLOTS = { "main_hand", "off_hand" }

local frame

-- ---------------------------------------------------------------- data

-- The same key the writing script builds: name and realm joined by a hyphen and
-- lower cased. Lua's :lower() is ASCII-only, which is exactly why the script
-- lowers that way too -- see UpdateSpecs.ps1 for the forty characters lost when
-- the two disagreed.
local function InspectKey(name,realm)
	if not name then return nil end
	return (name.."-"..(realm or "")):lower()
end

local function InspectData(name,realm,region)
	local by=ns.INSPECT_BY_REGION and ns.INSPECT_BY_REGION[region or ""]
	if not by then return nil end
	return by[InspectKey(name,realm) or ""]
end

function ns.HasInspectData(name,realm,region)
	return InspectData(name,realm,region)~=nil
end

-- ---------------------------------------------------------------- slots

-- The item as the game writes it: id, enchant, then up to four gems.
--
-- Worth building rather than passing the bare id, because the client then does
-- all the rest itself -- the enchant line, the sockets with the gems sitting in
-- them, the quality colour. Handing SetItemByID the id alone produces the item
-- as it comes out of the vendor, with the sockets empty, which is what made the
-- gems look like they were outside the item.
local function ItemLink(record)
	if type(record)~="table" or not record[1] then return nil end
	return ("item:%d:%d:%d:%d:%d:%d"):format(
		record[1],record[2] or 0,record[3] or 0,record[4] or 0,record[5] or 0,record[6] or 0)
end

-- What the last hovered slot's set line did, sampled twice.
--
-- The first fix for "the set reads 0/5 until you change tab" assumed the client
-- was rebuilding the tooltip underneath us and throwing our line away. That did
-- not fix it, so the assumption is what needs testing rather than patching
-- again: this records what the correction saw when it ran, and what the tooltip
-- actually says a third of a second later.
--
--   hover a set piece, then: /arena settip
local setProbe

local function SlotTooltip(self)
	if not self.itemID then return end

	GameTooltip:SetOwner(self,"ANCHOR_RIGHT")

	-- The whole item, gems and enchant included, drawn by the client.
	local ok=self.link and pcall(GameTooltip.SetHyperlink,GameTooltip,self.link)
	if not ok then
		ok=pcall(GameTooltip.SetItemByID,GameTooltip,self.itemID)
		if not ok then GameTooltip:SetText("item "..self.itemID) end
	end

	-- The tinker, which the item link cannot carry: an engineer's glove or belt
	-- enchant sits alongside the ordinary one, and a link holds a single enchant
	-- and no more.
	--
	-- Written under the item's own enchant rather than added to the end. AddLine
	-- can only append, and on a tooltip with other addons on it that put Synapse
	-- Springs below the vendor price and a block of item ids -- present, and
	-- nowhere anybody would look for an enchant.
	--
	-- A tooltip line cannot be inserted, but it can be made taller: the enchant
	-- line is found by its text and the tinker added inside it after a newline,
	-- which puts it exactly where the game would.
	if self.tinker and self.tinker>0 then
		local text=ns.ENCHANT_TEXT and ns.ENCHANT_TEXT[self.tinker]
		text=text or L.INSPECT_ENCHANT_UNKNOWN:format(self.tinker)

		-- And what it actually does.
		--
		-- Blizzard's own wording first. The client can describe the spell from
		-- its id, and that was tried, but it writes the bare effect where the
		-- game's item tooltip says "Use: ... (1 Min Cooldown)" -- the same
		-- information, not the same sentence, and the sentence is what somebody
		-- reading a glove is expecting.
		--
		-- The spell id stays as the fallback, for a tinker met before this text
		-- was being collected.
		local does=ns.ENCHANT_USE and ns.ENCHANT_USE[self.tinker]

		if not does then
			local spellID=ns.ENCHANT_SPELL and ns.ENCHANT_SPELL[self.tinker]
			does=spellID and GetSpellDescription and GetSpellDescription(spellID)
		end

		if does and does~="" then text=text.."|n"..does end

		local wanted=self.enchant and self.enchant>0
			and ns.ENCHANT_TEXT and ns.ENCHANT_TEXT[self.enchant]
		local placed=false

		if wanted then
			for index=1,GameTooltip:NumLines() do
				local line=_G["GameTooltipTextLeft"..index]
				local existing=line and line:GetText()

				if existing and existing:find(wanted,1,true) then
					line:SetText(existing.."|n"..text)

					-- The colour of the line as a whole, so the tinker reads the
					-- same green as the enchant it now shares a line with.
					line:SetTextColor(0.2,1,0.2)
					placed=true
					break
				end
			end
		end

		-- No enchant to sit under -- a glove with a tinker and nothing else --
		-- so the end of the tooltip is the only place left.
		if not placed then
			GameTooltip:AddLine(text,0.2,1,0.2)
		end
	end

	-- The client writes a set line of its own -- and gets it wrong here, because
	-- it counts how many of that set *the viewer* is wearing. Looking at a
	-- rogue's tier on a warlock it says 0/5. The line is corrected in place
	-- rather than a second one added beneath it, which would leave both on show
	-- disagreeing with each other.
	local setID=ns.SET_OF_ITEM and ns.SET_OF_ITEM[self.itemID]
	local worn=setID and frame.setCounts and frame.setCounts[setID]

	setProbe={
		itemID  = self.itemID,
		cached  = (GetItemInfo(self.itemID))~=nil,
		setID   = setID,
		name    = setID and ns.SET_NAMES and ns.SET_NAMES[setID] or nil,
		worn    = worn and worn[1] or nil,
		total   = worn and worn[2] or nil,
		lines   = GameTooltip:NumLines(),
		matched = nil,
		wrote   = nil,
		before  = nil,
		later   = nil,
	}

	if worn then
		local name=ns.SET_NAMES and ns.SET_NAMES[setID]
		local header
		for index=1,GameTooltip:NumLines() do
			local line=_G["GameTooltipTextLeft"..index]
			local text=line and line:GetText()
			if text and text:match("%(%d+/%d+%)") then
				setProbe.before=text
				line:SetText(L.INSPECT_SET_TOOLTIP:format(name or text:gsub("%s*%(%d+/%d+%)",""),worn[1],worn[2]))
				setProbe.matched=index
				setProbe.wrote=line:GetText()
				header=index
				break
			end
		end

		-- Sampled again after the client has had a chance to redraw, which is the
		-- thing the first fix assumed was happening.
		if C_Timer and C_Timer.After then
			local probe=setProbe
			C_Timer.After(0.35,function()
				probe.later={}
				for index=1,GameTooltip:NumLines() do
					local line=_G["GameTooltipTextLeft"..index]
					local text=line and line:GetText()
					if text and text:match("%(%d+/%d+%)") then
						probe.later[#probe.later+1]=index..": "..text
					end
				end
				probe.laterLines=GameTooltip:NumLines()
				probe.laterShown=GameTooltip:IsShown() and "yes" or "no"
			end)
		end

		-- Nothing to correct: the client did not name the set at all.
		if not header and name then
			GameTooltip:AddLine(L.INSPECT_SET_TOOLTIP:format(name,worn[1],worn[2]),1,0.82,0)
		end

		-- The client lists the set's pieces and greys every one of them, because
		-- it is asking which the *viewer* owns. The ones this character has on
		-- are brightened back up, so the list reads the way it does when you
		-- inspect somebody standing in front of you.
		--
		-- By name, not by position.
		--
		-- This used to pair the Nth line with the Nth bit of a mask, on the
		-- reasoning that both lists were in item id order. They are not: the
		-- client lists this set as Gloves, Helm, Leggings, Robe, Mantle, which
		-- is neither our order nor alphabetical, so a character wearing the
		-- gloves had the mantle lit instead.
		--
		-- The names do match, despite looking as though they cannot. The list
		-- names the plain "Gladiator's Mooncloth Gloves" while the item worn is
		-- the "Grievous Gladiator's Mooncloth Gloves" -- the list entry is the
		-- tail of the worn name, so testing for that pairs them exactly, in
		-- whatever order either side chooses.
		--
		-- Counted from the header line, which also keeps this away from the
		-- item's own name at the top -- recolouring that turned an epic's purple
		-- title white.
		--
		-- Pale yellow for a piece this character is wearing.
		--
		-- Measured, not chosen. White was guessed, then tooltip gold, and both
		-- were wrong in a way that looked close enough in a screenshot to
		-- believe.
		--
		-- Settled by building a tooltip off-screen for a set piece the player
		-- was wearing -- one the engine had just filled in itself -- and reading
		-- the colour off each line: the header came back 1.00 0.82 0.00 and the
		-- pieces 1.00 1.00 0.59, which is LIGHTYELLOW_FONT_COLOR. Neither guess
		-- was near it. Worth repeating that way if it ever needs checking
		-- again; the throwaway command that did it has been removed.
		--
		-- Green stays for the bonuses that are actually running.
		local pr,pg,pb=1,1,0.59
		if LIGHTYELLOW_FONT_COLOR then
			pr,pg,pb=LIGHTYELLOW_FONT_COLOR.r,LIGHTYELLOW_FONT_COLOR.g,LIGHTYELLOW_FONT_COLOR.b
		end

		local r,g,b=0.1,1,0.1
		if GREEN_FONT_COLOR then r,g,b=GREEN_FONT_COLOR.r,GREEN_FONT_COLOR.g,GREEN_FONT_COLOR.b end

		-- What this character has on out of this set, by name.
		local mineNames={}
		for _,itemID in ipairs((frame.setItems and frame.setItems[setID]) or {}) do
			local itemName=GetItemInfo(itemID)
			if itemName then mineNames[#mineNames+1]=itemName end
		end

		local function Trim(text)
			return (text:gsub("^%s+",""):gsub("%s+$",""))
		end

		if header and #mineNames>0 then
			for index=header+1,GameTooltip:NumLines() do
				local line=_G["GameTooltipTextLeft"..index]
				local text=line and line:GetText()
				if not text then break end

				local piece=Trim(text)

				-- The list runs until a blank line or the first set bonus.
				if piece=="" or piece:match("^%(%d+%)%s*Set:") then break end

				for _,itemName in ipairs(mineNames) do
					if itemName==piece or itemName:sub(-#piece)==piece then
						line:SetTextColor(pr,pg,pb)
						break
					end
				end
			end
		elseif header then
			-- No names yet -- the client has not loaded those items. The old
			-- bitmask, which is wrong about which line but right about how many,
			-- is not worth showing, so nothing is brightened until the names
			-- arrive rather than the wrong piece being lit in the meantime.
			for _,itemID in ipairs((frame.setItems and frame.setItems[setID]) or {}) do
				if C_Item and C_Item.RequestLoadItemDataByID then
					pcall(C_Item.RequestLoadItemDataByID,itemID)
				end
			end
		end

		-- The bonuses, green once enough of the set is on. The client greys these
		-- for the same reason it greys the pieces: it is answering for the
		-- viewer, who is wearing none of it.
		--
		-- Found by their own shape rather than by counting lines down from the
		-- header. Working out where the list ended assumed the pieces run in an
		-- unbroken block immediately below it, and one blank line in between put
		-- every bonus out of reach -- which is why they stayed grey at 5/5.
		if header then
			local count=worn[1] or 0
			for index=header+1,GameTooltip:NumLines() do
				local line=_G["GameTooltipTextLeft"..index]
				local text=line and line:GetText()
				local needed=text and text:match("^%s*%((%d+)%)%s*Set:")
				if needed and count>=tonumber(needed) then
					line:SetTextColor(r,g,b)
				end
			end
		end
	end

	-- Only when the client could not name the enchant itself. On this build it
	-- usually can, from the link above; this is the fallback that keeps an
	-- enchant from vanishing rather than a line printed twice.
	if self.enchant and self.enchant>0 and not ok then
		local text=ns.ENCHANT_TEXT and ns.ENCHANT_TEXT[self.enchant]
		GameTooltip:AddLine(text or (L.INSPECT_ENCHANT_UNKNOWN:format(self.enchant)),0.2,1,0.2)
	end

	GameTooltip:Show()
end

local function CreateSlot(parent,side)
	local button=CreateFrame("Button",nil,parent)
	button:SetSize(SLOT_SIZE,SLOT_SIZE)

	-- The enchant written beside the slot, the way the character sheet does it,
	-- so a missing one is read at a glance rather than found by hovering
	-- seventeen slots in turn. Text runs away from the model on both sides.
	button.enchantText=button:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
	button.enchantText:SetWidth(132)
	button.enchantText:SetTextColor(0.1,0.9,0.1)
	if side=="right" then
		button.enchantText:SetPoint("RIGHT",button,"LEFT",-6,0)
		button.enchantText:SetJustifyH("RIGHT")
	else
		button.enchantText:SetPoint("LEFT",button,"RIGHT",6,0)
		button.enchantText:SetJustifyH("LEFT")
	end

	-- The slot's edge, which carries the item's quality colour.
	--
	-- Retail rings a paper doll slot in the colour of what is in it, and it is
	-- the fastest read on the whole panel: purple everywhere and one green
	-- square says more at a glance than any amount of hovering. Drawn as a
	-- backing one pixel proud of the icon rather than as four separate edges,
	-- since the icon is inset by exactly that much already.
	button.edge=button:CreateTexture(nil,"BACKGROUND",nil,-8)
	button.edge:SetPoint("TOPLEFT",-1,1)
	button.edge:SetPoint("BOTTOMRIGHT",1,-1)
	button.edge:SetColorTexture(0.25,0.25,0.25,1)

	button.bg=button:CreateTexture(nil,"BACKGROUND")
	button.bg:SetAllPoints()
	button.bg:SetColorTexture(0.12,0.12,0.12,0.9)

	button.icon=button:CreateTexture(nil,"ARTWORK")
	button.icon:SetPoint("TOPLEFT",1,-1)
	button.icon:SetPoint("BOTTOMRIGHT",-1,1)
	button.icon:SetTexCoord(0.07,0.93,0.07,0.93)

	-- A green pip for an enchant, so a missing enchant is visible without
	-- hovering every slot in turn -- which is most of why anyone opens this.
	button.enchantMark=button:CreateTexture(nil,"OVERLAY")
	button.enchantMark:SetSize(8,8)
	button.enchantMark:SetPoint("TOPRIGHT",-1,-1)
	button.enchantMark:SetColorTexture(0.2,1,0.2,0.9)
	button.enchantMark:Hide()

	button.gems={}
	for index=1,3 do
		local gem=button:CreateTexture(nil,"OVERLAY")
		gem:SetSize(10,10)
		if index==1 then
			gem:SetPoint("BOTTOMLEFT",1,1)
		else
			gem:SetPoint("LEFT",button.gems[index-1],"RIGHT",1,0)
		end
		gem:Hide()
		button.gems[index]=gem
	end

	-- Marked so the item-info watcher can tell one of these from any other
	-- frame that happens to own the tooltip.
	button.isGearSlot=true

	button:SetScript("OnEnter",SlotTooltip)
	button:SetScript("OnLeave",function() GameTooltip:Hide() end)

	return button
end

local function FillSlot(button,record,tinker,slotKey)
	button.itemID=nil
	button.enchant=nil
	button.gemIDs=nil
	button.link=nil
	button.tinker=nil
	button.enchantText:SetText("")
	button.enchantMark:Hide()
	for _,gem in ipairs(button.gems) do gem:Hide() end

	if type(record)~="table" or not record[1] then
		button.icon:SetTexture(nil)
		button.bg:SetColorTexture(0.12,0.12,0.12,0.9)
		button.edge:SetColorTexture(0.25,0.25,0.25,1)
		return
	end

	button.itemID=record[1]
	button.enchant=record[2]
	button.link=ItemLink(record)
	button.tinker=tinker

	-- Beside the slot: the enchant, and under it the tinker if there is one.
	--
	-- The tooltip line for a tinker can only be appended, so it lands beneath
	-- whatever other addons have already added -- on a busy tooltip it ends up
	-- below the vendor price, which is not where anybody looks for an enchant.
	-- Here it sits next to the glove it is on.
	local lines={}
	if record[2] and record[2]>0 then
		local text=ns.ENCHANT_TEXT and ns.ENCHANT_TEXT[record[2]]
		lines[#lines+1]=text or L.INSPECT_ENCHANT_UNKNOWN:format(record[2])
	end
	if tinker and tinker>0 then
		local text=ns.ENCHANT_TEXT and ns.ENCHANT_TEXT[tinker]
		lines[#lines+1]=text or L.INSPECT_ENCHANT_UNKNOWN:format(tinker)
	end

	-- And the buckle, which is neither of those.
	--
	-- It sits beside the belt with the enchant and the tinker because that is
	-- where somebody looks for "what has been done to this piece" -- and a
	-- buckle is the most commonly done thing of the three.
	if slotKey=="waist" and HasBuckle(record) then
		lines[#lines+1]=BELT_BUCKLE_NAME
	end

	button.enchantText:SetText(table.concat(lines,"|n"))

	-- GetItemInfoInstant reads the client's own database and answers at once.
	-- GetItemInfo can return nil for an item nobody has seen this session, which
	-- would leave the slot blank until something else happened to load it.
	local _,_,_,_,icon=GetItemInfoInstant(record[1])
	button.icon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
	button.bg:SetColorTexture(0.2,0.2,0.2,0.9)

	-- Quality comes from GetItemInfo, which is the slow one: it answers nil
	-- until the client has the item, and the icon above deliberately uses the
	-- instant call so the slot is never blank. So the edge is grey until the
	-- name arrives and coloured afterwards -- the sockets tab already asks for
	-- these items, and looking at a character asks for them again.
	local quality=select(3,GetItemInfo(record[1]))
	if quality and GetItemQualityColor then
		local r,g,b=GetItemQualityColor(quality)
		button.edge:SetColorTexture(r,g,b,1)
	else
		button.edge:SetColorTexture(0.25,0.25,0.25,1)
		if C_Item and C_Item.RequestLoadItemDataByID then
			pcall(C_Item.RequestLoadItemDataByID,record[1])
		end
	end

	if record[2] and record[2]>0 then button.enchantMark:Show() end

	local gems={}
	for index=3,#record do gems[#gems+1]=record[index] end
	button.gemIDs=gems

	for index,gemID in ipairs(gems) do
		local slot=button.gems[index]
		if not slot then break end
		local _,_,_,_,gemIcon=GetItemInfoInstant(gemID)
		slot:SetTexture(gemIcon or "Interface\\Icons\\INV_Misc_QuestionMark")
		slot:Show()
	end
end

-- ---------------------------------------------------------------- model

-- Their kit on the model, not ours.
--
-- The first version called Undress and TryOn inside pcall and neither did
-- anything, so the model stood there in the viewer's own gear wearing a rogue's
-- glyphs -- a warlock's robes on the rank one rogue. Two causes, both silent:
-- SetUnit re-dresses the model as the player every time it is called, putting
-- our gear back after the undress; and TryOn wants an item link, not a bare
-- numeric id, so every piece was quietly declined.
--
-- Auto-dress is turned off first, which is what stops SetUnit dressing it.
local function Dress(gear,look)
	local model=frame.model
	if not model then return end

	if model.SetAutoDress then pcall(model.SetAutoDress,model,false) end

	-- Their own race and gender when we know it, which is now: the specs pass
	-- already asks for the profile that carries both, so it costs nothing.
	-- Falling back to the viewer's own body if the call is not on this build.
	-- Your own body, wearing their gear.
	--
	-- Not the choice anybody wanted. The character's real race and gender are
	-- known -- the specs pass reads both -- and SetDisplayInfo takes a race
	-- display id, so this drew them properly for about a day.
	--
	-- Except it did not: it drew a white silhouette. Geometry with no skin.
	-- Tested from every angle before giving up on it -- SetCustomRace does not
	-- exist on this client, re-lighting after ClearModel changed nothing, and
	-- /arena model 49 puts a plain human male display on the frame and it comes
	-- up white as well. This client will not texture a body it was handed by
	-- display id; MogPlus only ever renders you, and that is why it never hit
	-- this.
	--
	-- So: your own body, which the client textures without complaint, wearing
	-- the gear that is the point of the panel. The hint underneath says so
	-- rather than letting anyone think the race is theirs.
	model:SetUnit("player")

	-- Lit again, every time.
	--
	-- The light is set once when the window is built, and ClearModel above
	-- throws it away along with the model it clears -- so from the second
	-- character onwards the body rendered as a flat white silhouette: geometry
	-- with no lighting, which looks exactly like geometry with no texture and
	-- sent us looking for the wrong fault. MogPlus never hit this because it
	-- never clears its model; its own note says an unlit model is a silhouette.
	if frame and frame.Relight then frame.Relight() end

	pcall(model.Undress,model)

	if type(gear)~="table" then return end

	-- Weapons have to name their slot. Without it both daggers are offered to
	-- the main hand, the second replaces the first, and a dual wielder shows up
	-- holding one.
	local MODEL_SLOT={ main_hand="MAINHANDSLOT", off_hand="SECONDARYHANDSLOT" }

	local function Wear(list)
		for _,slotKey in ipairs(list) do
			local piece=gear[slotKey]
			local link=ItemLink(piece)
			if link then
				-- A link, not an id. The bare number is accepted by the call and
				-- then ignored, which is the worst of both.
				local slot=MODEL_SLOT[slotKey]
				if not (slot and pcall(model.TryOn,model,link,slot)) then
					pcall(model.TryOn,model,link)
				end
			end
		end
	end

	Wear(LEFT_SLOTS)
	Wear(RIGHT_SLOTS)
	Wear(BOTTOM_SLOTS)
end

-- What the model is currently wearing, so it can be put back on.
--
-- A model loses everything when its frame is hidden, and switching tabs hides
-- this one -- so going to Talents and back left the character standing there
-- naked, with nothing to notice and re-dress it. Dressing only ever happened
-- when the window opened.
--
-- Kept beside the character it belongs to: opening somebody else sets
-- frame.showing before the page is shown, so a stale re-dress cannot put the
-- last player's gear on the new one for a frame.
local dressGear,dressLook,dressFor

-- Dressed once now and once a moment later.
--
-- A model that has not finished loading accepts TryOn and does nothing with it,
-- which is how it ended up standing there in its underwear: the panel was
-- dressed before it was ever shown, so there was nothing to dress. Showing
-- first fixes the common case and the second pass covers a slow load.
local function DressWhenReady(gear,look)
	dressGear,dressLook,dressFor=gear,look,frame and frame.showing

	Dress(gear,look)
	if C_Timer and C_Timer.After then
		C_Timer.After(0.1,function()
			if frame and frame:IsShown() then Dress(gear,look) end
		end)
	end
end

-- Put the clothes back on, when this page comes back into view.
local function RedressOnShow()
	if not (dressGear and frame and frame.showing and dressFor==frame.showing) then return end
	DressWhenReady(dressGear,dressLook)
end

-- ---------------------------------------------------------------- pages

local function BuildCharacterPage(parent)
	local page=CreateFrame("Frame",nil,parent)
	page:SetPoint("TOPLEFT",0,0)
	page:SetPoint("BOTTOMRIGHT",0,0)
	page:SetScript("OnShow",RedressOnShow)

	page.slots={}

	local function Column(list,anchorPoint,xOffset)
		local previous
		for _,slotKey in ipairs(list) do
			local button=CreateSlot(page,anchorPoint=="TOPRIGHT" and "right" or "left")
			if previous then
				button:SetPoint("TOP",previous,"BOTTOM",0,-SLOT_GAP)
			else
				button:SetPoint(anchorPoint,page,anchorPoint,xOffset,TOP)
			end
			page.slots[slotKey]=button
			previous=button
		end
	end

	Column(LEFT_SLOTS,"TOPLEFT",16)
	Column(RIGHT_SLOTS,"TOPRIGHT",-16-SLOT_SIZE)

	-- Centred under the model, the way the character sheet has them, with each
	-- weapon's enchant running outwards so the two cannot collide.
	local weaponSide={ main_hand="right", off_hand="left" }
	local previous
	for index,slotKey in ipairs(BOTTOM_SLOTS) do
		local button=CreateSlot(page,weaponSide[slotKey] or "left")
		if previous then
			button:SetPoint("LEFT",previous,"RIGHT",SLOT_GAP,0)
		else
			button:SetPoint("BOTTOMRIGHT",page,"BOTTOM",-math.floor(SLOT_GAP/2),FOOT+46)
		end
		page.slots[slotKey]=button
		previous=button
	end

	-- The model, dressed in their kit.
	--
	-- It wears our own race and gender: the leaderboard says who somebody is,
	-- not what they look like, and asking for that is another request per
	-- character for a detail nobody opens this to check. Said plainly in the
	-- hint underneath rather than left to be noticed.
	local model=CreateFrame("DressUpModel",nil,page)
	model:SetPoint("TOPLEFT",page,"TOPLEFT",16+SLOT_SIZE+SLOT_GAP,TOP)
	model:SetPoint("BOTTOMRIGHT",page,"BOTTOMRIGHT",-(16+SLOT_SIZE+SLOT_GAP),FOOT+92)
	if model.SetAutoDress then pcall(model.SetAutoDress,model,false) end
	model:SetUnit("player")
	frame.model=model

	local function Light()
		if CreateVector3D then
			local ok=pcall(model.SetLight,model,true,{
				omnidirectional  = false,
				point            = CreateVector3D(-1,1,-1),
				ambientIntensity = 1.05,
				ambientColor     = CreateColor(1,1,1),
				diffuseIntensity = 1.0,
				diffuseColor     = CreateColor(1,1,1),
			})
			if ok then return end
		end
		pcall(model.SetLight,model,true,false,-1,1,-1,1.05,1,1,1,1.0,1,1,1)
	end
	Light()

	-- Kept, because the light does not survive ClearModel. See Dress.
	frame.Relight=Light

	-- Far enough back to show a whole person. At 1.0 the camera sits close
	-- enough that a tall race loses its feet to the bottom of the frame.
	local ZOOM_DEFAULT,ZOOM_MIN,ZOOM_MAX=1.55,0.4,3.0

	local function Reframe(zoom)
		model.zoom=math.max(ZOOM_MIN,math.min(ZOOM_MAX,zoom or ZOOM_DEFAULT))
		pcall(model.SetPortraitZoom,model,0)
		pcall(model.SetPosition,model,0,0,0)
		pcall(model.SetCamDistanceScale,model,model.zoom)
	end
	Reframe(ZOOM_DEFAULT)

	model:EnableMouse(true)
	model:EnableMouseWheel(true)

	model:SetScript("OnMouseDown",function(self,button)
		if button=="RightButton" then
			self.facing=0
			pcall(self.SetFacing,self,0)
			Reframe(ZOOM_DEFAULT)
			return
		end
		self.turning=true
		self.grabX=GetCursorPosition()
		self.grabFacing=self.facing or 0
	end)

	model:SetScript("OnMouseUp",function(self) self.turning=nil end)

	model:SetScript("OnUpdate",function(self)
		if not self.turning then return end
		local x=GetCursorPosition()
		self.facing=(self.grabFacing or 0)+(x-(self.grabX or x))/50
		pcall(self.SetFacing,self,self.facing)
	end)

	model:SetScript("OnMouseWheel",function(self,delta)
		Reframe((self.zoom or ZOOM_DEFAULT)-delta*0.15)
	end)

	page.hint=page:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
	-- FOOT is the room the tab row needs; sitting 4 INTO it put this line on
	-- top of the tabs. Cleared above it instead.
	page.hint:SetPoint("BOTTOM",page,"BOTTOM",0,FOOT+8)
	page.hint:SetText(L.INSPECT_HINT)
	page.hint:SetTextColor(0.4,0.4,0.4)

	return page
end

local TALENT_COLUMNS = 3
local TALENT_TIERS   = 6

local function BuildTalentsPage(parent)
	local page=CreateFrame("Frame",nil,parent)
	page:SetPoint("TOPLEFT",0,0)
	page:SetPoint("BOTTOMRIGHT",0,0)
	page:Hide()

	-- The whole grid, not only what they picked: six tiers of three, the one
	-- taken lit and the two passed over dimmed. Seeing what somebody chose
	-- against what they turned down is the point of looking at all.
	local cellWidth=math.floor((WIDTH-82)/TALENT_COLUMNS)
	local cellHeight=34

	page.cells={}
	for tier=1,TALENT_TIERS do
		page.cells[tier]={}
		for column=1,TALENT_COLUMNS do
			local cell=CreateFrame("Button",nil,page)
			cell:SetSize(cellWidth-6,cellHeight-4)
			-- Indented past the tier numbers down the left, which were being
			-- drawn outside the panel.
			cell:SetPoint("TOPLEFT",page,"TOPLEFT",
				46+(column-1)*cellWidth,TOP-(tier-1)*cellHeight)

			cell.bg=cell:CreateTexture(nil,"BACKGROUND")
			cell.bg:SetAllPoints()

			cell.icon=cell:CreateTexture(nil,"ARTWORK")
			cell.icon:SetSize(cellHeight-10,cellHeight-10)
			cell.icon:SetPoint("LEFT",cell,"LEFT",3,0)
			cell.icon:SetTexCoord(0.07,0.93,0.07,0.93)

			cell.label=cell:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
			cell.label:SetPoint("LEFT",cell.icon,"RIGHT",6,0)
			cell.label:SetPoint("RIGHT",cell,"RIGHT",-4,0)
			cell.label:SetJustifyH("LEFT")

			cell:SetScript("OnEnter",function(self)
				if not self.spellID then return end
				GameTooltip:SetOwner(self,"ANCHOR_RIGHT")
				pcall(GameTooltip.SetSpellByID,GameTooltip,self.spellID)
				GameTooltip:Show()
			end)
			cell:SetScript("OnLeave",function() GameTooltip:Hide() end)

			page.cells[tier][column]=cell
		end

		local level=page:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
		level:SetPoint("RIGHT",page.cells[tier][1],"LEFT",-4,0)
		level:SetText(tier*15)
		level:SetTextColor(0.35,0.35,0.35)

		-- Kept, because these are the levels MISTS unlocks its tiers at. TBC
		-- stops at 70 and has no tiers at all, so they have to go with the grid
		-- rather than being left down the side of a tree list.
		page.levels=page.levels or {}
		page.levels[tier]=level
	end

	-- The Burning Crusade layout, built beside the grid above rather than
	-- instead of it.
	--
	-- TBC has no tiers: it has three talent TREES, each taken to whatever
	-- depth the player paid for, and a build is read as "17/0/44" plus which
	-- talents those points bought. The six-by-three grid describes nothing
	-- there -- it was drawing Mists tiers with TBC spell ids in them, which is
	-- how a rogue came out showing "spell 108208" against level 15.
	--
	-- Which layout is used is decided by the DATA, not the client: a Mists
	-- player looking at an Anniversary character needs this one too.
	local treeRows=18
	local treeRowHeight=18
	page.trees={}

	for column=1,TALENT_COLUMNS do
		local tree={}
		local left=46+(column-1)*cellWidth

		tree.heading=page:CreateFontString(nil,"OVERLAY","GameFontNormal")
		tree.heading:SetPoint("TOPLEFT",page,"TOPLEFT",left,TOP)
		tree.heading:SetWidth(cellWidth-6)
		tree.heading:SetJustifyH("LEFT")

		tree.rows={}
		for index=1,treeRows do
			local row=CreateFrame("Button",nil,page)
			row:SetSize(cellWidth-8,treeRowHeight-2)
			row:SetPoint("TOPLEFT",page,"TOPLEFT",left,TOP-18-(index-1)*treeRowHeight)

			row.icon=row:CreateTexture(nil,"ARTWORK")
			row.icon:SetSize(treeRowHeight-4,treeRowHeight-4)
			row.icon:SetPoint("LEFT",row,"LEFT",0,0)
			row.icon:SetTexCoord(0.07,0.93,0.07,0.93)

			row.rank=row:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
			row.rank:SetPoint("RIGHT",row,"RIGHT",-2,0)
			row.rank:SetJustifyH("RIGHT")
			row.rank:SetTextColor(0.7,0.7,0.7)

			row.label=row:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
			row.label:SetPoint("LEFT",row.icon,"RIGHT",5,0)
			row.label:SetPoint("RIGHT",row.rank,"LEFT",-4,0)
			row.label:SetJustifyH("LEFT")
			row.label:SetTextColor(1,0.82,0)

			row:SetScript("OnEnter",function(self)
				if not self.spellID then return end
				GameTooltip:SetOwner(self,"ANCHOR_RIGHT")
				pcall(GameTooltip.SetSpellByID,GameTooltip,self.spellID)
				GameTooltip:Show()
			end)
			row:SetScript("OnLeave",function() GameTooltip:Hide() end)
			row:Hide()

			tree.rows[index]=row
		end

		tree.heading:Hide()
		page.trees[column]=tree
	end

	-- What the grid could not be filled in from. Said out loud, because a blank
	-- cell otherwise reads as a talent nobody can take.
	page.gaps=page:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
	-- Anchored to the page rather than to the last row, so its clearance is
	-- expressed from the same origin the grid uses.
	page.gaps:SetPoint("TOPLEFT",page,"TOPLEFT",46,TOP-4-TALENT_TIERS*cellHeight)
	page.gaps:SetWidth(WIDTH-56)
	page.gaps:SetJustifyH("LEFT")
	page.gaps:SetTextColor(0.45,0.45,0.45)

	page.glyphHeading=page:CreateFontString(nil,"OVERLAY","GameFontNormal")
	page.glyphHeading:SetPoint("TOPLEFT",page.gaps,"BOTTOMLEFT",0,-10)
	page.glyphHeading:SetText(L.INSPECT_GLYPHS)

	-- Glyphs in the same three columns as the talents above them.
	page.glyphs={}
	for index=1,6 do
		local row=CreateFrame("Button",nil,page)
		row:EnableMouse(true)
		local column=(index-1)%TALENT_COLUMNS
		local line=math.floor((index-1)/TALENT_COLUMNS)
		row:SetSize(cellWidth-8,20)
		row:SetPoint("TOPLEFT",page.glyphHeading,"BOTTOMLEFT",column*cellWidth,-6-line*22)

		row.icon=row:CreateTexture(nil,"ARTWORK")
		row.icon:SetSize(18,18)
		row.icon:SetPoint("LEFT",row,"LEFT",0,0)
		row.icon:SetTexCoord(0.07,0.93,0.07,0.93)

		row.label=row:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
		row.label:SetPoint("LEFT",row.icon,"RIGHT",5,0)
		row.label:SetPoint("RIGHT",row,"RIGHT",0,0)
		row.label:SetJustifyH("LEFT")
		row.label:SetTextColor(0.62,0.78,1)

		-- What a glyph does, on hover.
		--
		-- Blizzard's profile hands back a glyph's name and its glyph id -- 700
		-- for Glyph of Deep Freeze -- and nothing else: no item, no spell. That
		-- id is not something a tooltip can be built from directly, so this
		-- tries the ways the client might know the glyph and settles for the
		-- name when none of them do.
		--
		-- Each attempt is wrapped, because a hyperlink the client does not
		-- understand throws rather than returning false, and a tooltip that
		-- errors on hover would be worse than one that only names the glyph.
		row:SetScript("OnEnter",function(self)
			if not self.glyphName then return end

			-- Written here rather than asked of the game.
			--
			-- The obvious way is the glyph hyperlink the client uses for its own
			-- sockets, and it cannot be made to tell the truth: hovering a
			-- mage's minor Rapid Teleportation produced a tooltip headed "Major
			-- Glyph", and it still did when the link was handed the real type
			-- instead of a zero. Whatever that first field means, it is not
			-- something to build a claim on.
			--
			-- So the three lines come from three places that are each known
			-- good: the name from Blizzard's profile, the type from the game's
			-- own GlyphProperties table, and the words from the spell the glyph
			-- casts -- the client writes those, in the reader's own language.
			GameTooltip:SetOwner(self,"ANCHOR_RIGHT")
			GameTooltip:SetText(self.glyphName,1,1,1)

			if self.glyphKind==1 then
				GameTooltip:AddLine(L.INSPECT_GLYPH_MAJOR,0.4,0.6,1)
			elseif self.glyphKind==2 then
				GameTooltip:AddLine(L.INSPECT_GLYPH_MINOR,0.4,0.6,1)
			end

			local spellID=ns.GLYPH_SPELL and ns.GLYPH_SPELL[self.glyphID]
			local says=spellID and GetSpellDescription and GetSpellDescription(spellID)
			if says and says~="" then
				GameTooltip:AddLine(says,1,0.82,0,true)
			end

			GameTooltip:Show()
		end)
		row:SetScript("OnLeave",function() GameTooltip:Hide() end)

		page.glyphs[index]=row
	end

	return page
end

-- Blizzard's own PvP panel, as closely as this can manage.
--
-- Theirs groups the arena brackets under one heading and rated battlegrounds
-- under another, and gives each bracket a boxed row: the bracket named large on
-- the left, then won/lost, rank and current rating, each under a small caption.
-- Copying that layout means anyone who has looked at their own PvP frame can
-- read somebody else's without learning a second one.
--
-- The captions repeat on every row rather than sitting once at the top. That is
-- Blizzard's choice and it is the right one here too: the rows are boxed and
-- separated, so a single header row would be reading across a gap.
local PVP_GROUPS = {
	{ heading = "arena",  brackets = { 1, 2, 3 } },
	{ heading = "rbg",    brackets = { 4 } },
}

local PVP_ROW_HEIGHT = 46
local PVP_GROUP_GAP  = 30

local function BuildPvPRow(page,index)
	local row=CreateFrame("Frame",nil,page)
	row:SetHeight(PVP_ROW_HEIGHT)

	-- The inset each bracket sits in. Blizzard's rows are sunk into the panel;
	-- a dark fill inside a lighter edge is the same idea without needing their
	-- nine-slice art, which is drawn for a lighter frame than this one.
	row.edge=row:CreateTexture(nil,"BACKGROUND",nil,-7)
	row.edge:SetAllPoints()
	row.edge:SetColorTexture(0.30,0.30,0.34,0.55)

	row.fill=row:CreateTexture(nil,"BACKGROUND",nil,-6)
	row.fill:SetPoint("TOPLEFT",1,-1)
	row.fill:SetPoint("BOTTOMRIGHT",-1,1)
	row.fill:SetColorTexture(0.06,0.06,0.08,0.9)

	row.bracket=row:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
	row.bracket:SetPoint("LEFT",row,"LEFT",16,0)
	row.bracket:SetText(BRACKET_NAMES[index])

	-- Three columns, each a caption with its value under it.
	local function Column(x,caption)
		local head=row:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
		head:SetPoint("TOPLEFT",row,"TOPLEFT",x,-8)
		head:SetText(caption)
		head:SetTextColor(0.65,0.65,0.65)

		local value=row:CreateFontString(nil,"OVERLAY","GameFontHighlight")
		value:SetPoint("TOPLEFT",head,"BOTTOMLEFT",0,-4)
		return value
	end

	row.record = Column(120,L.INSPECT_PVP_WL)
	row.rank   = Column(250,L.INSPECT_PVP_RANK)
	row.rating = Column(380,L.INSPECT_PVP_CURRENT)

	return row
end

local function BuildPvPPage(parent)
	local page=CreateFrame("Frame",nil,parent)
	page:SetPoint("TOPLEFT",0,0)
	page:SetPoint("BOTTOMRIGHT",0,0)
	page:Hide()

	page.rows={}

	local y=TOP
	for _,group in ipairs(PVP_GROUPS) do
		local heading=page:CreateFontString(nil,"OVERLAY","GameFontNormal")
		heading:SetPoint("TOPLEFT",page,"TOPLEFT",24,y)
		heading:SetText(group.heading=="arena" and L.INSPECT_PVP_ARENA or L.INSPECT_PVP_RBG)
		heading:SetTextColor(1,0.82,0)

		y=y-22

		for _,index in ipairs(group.brackets) do
			local row=BuildPvPRow(page,index)
			row:SetPoint("TOPLEFT",page,"TOPLEFT",24,y)
			row:SetPoint("RIGHT",page,"RIGHT",-24,0)
			page.rows[index]=row

			y=y-PVP_ROW_HEIGHT-4
		end

		y=y-PVP_GROUP_GAP
	end

	return page
end

-- ---------------------------------------------------------------- sockets

-- What they gemmed and enchanted, as a shopping list.
--
-- The paper doll already shows this, one socket at a time, spread around the
-- edge of a model -- fine for "what is in their gloves", useless for "what do I
-- need to buy". Counted and named instead: four Delicate Primordial Rubies is a
-- thing you can take to the auction house.

local SOCKET_ROWS = 14

local function BuildSocketsPage(parent)
	local page=CreateFrame("Frame",nil,parent)
	page:SetPoint("TOPLEFT",14,TOP)
	page:SetPoint("BOTTOMRIGHT",-14,44)
	page:Hide()

	-- Three columns across the full width, each as wide as what it holds: the
	-- enchant lines carry a slot name in front of them and run longest, the
	-- glyph names run shortest.
	local function Column(x, width, title)
		local head=page:CreateFontString(nil,"OVERLAY","GameFontNormal")
		head:SetPoint("TOPLEFT",x,-4)
		head:SetText(title)

		local rows={}
		for index=1,SOCKET_ROWS do
			local row=CreateFrame("Button",nil,page)
			row:SetSize(width,18)
			if index==1 then
				row:SetPoint("TOPLEFT",head,"BOTTOMLEFT",0,-6)
			else
				row:SetPoint("TOPLEFT",rows[index-1],"BOTTOMLEFT",0,-2)
			end

			-- Lit under the cursor, because a row that responds to a click has
			-- to look like one. Without this the list read as static text and
			-- nobody would think to click it.
			local glow=row:CreateTexture(nil,"HIGHLIGHT")
			glow:SetAllPoints()
			glow:SetColorTexture(1,1,1,0.10)
			row:SetHighlightTexture(glow)

			row.icon=row:CreateTexture(nil,"ARTWORK")
			row.icon:SetSize(16,16)
			row.icon:SetPoint("LEFT")
			row.icon:SetTexCoord(0.07,0.93,0.07,0.93)

			row.text=row:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
			row.text:SetPoint("LEFT",row.icon,"RIGHT",6,0)
			row.text:SetPoint("RIGHT")
			row.text:SetJustifyH("LEFT")

			row:Hide()
			rows[index]=row
		end
		return rows
	end

	page.gems=Column(0,190,L.INSPECT_GEMS)
	page.enchants=Column(198,250,L.INSPECT_ENCHANTS)
	page.glyphs=Column(456,176,L.INSPECT_GLYPHS)

	page.hint=page:CreateFontString(nil,"OVERLAY","GameFontDisableSmall")
	page.hint:SetPoint("BOTTOMLEFT",0,4)
	page.hint:SetText(L.INSPECT_AH_HINT)

	return page
end

-- Search the auction house for one item, and for as many as they are wearing.
--
-- Through Auctionator when it is there, and by hand when it is not.
--
-- Auctionator first because it replaces the auction house's own search: typing
-- into BrowseName and pressing its button did nothing visible with Auctionator
-- installed, which is what "clicking the gem does not search" turned out to be.
-- Its API also takes a quantity, so four sockets of the same gem can ask for
-- four rather than for one.
--
-- The callerID is required and is only used to label the temporary shopping
-- list and to attribute errors, so it names this addon.
local AUCTIONATOR_ID = "ArenaPlus"

local function AuctionHouseIsOpen()
	if AuctionHouseFrame and AuctionHouseFrame:IsShown() then return true end
	if AuctionFrame and AuctionFrame:IsShown() then return true end
	return false
end

-- The gem that was worn, and only that gem.
--
-- The plain cut used to be searched alongside the perfect one, on the reasoning
-- that "Perfect Delicate Pandarian Garnet" and "Delicate Pandarian Garnet" are
-- the same purchase to somebody copying a build.
--
-- They are not. The perfect cut is +160 Agility and the plain is +120 -- a
-- third less, on every socket, for a build being copied precisely because of
-- what its owner reached with it. Putting the two side by side and calling the
-- cheaper one an option is advice, and the wrong advice: the point of this
-- panel is what the player at rank 19 is actually wearing.
--
-- So one term, and it is theirs.

-- Whether there is anything here that can search.
--
-- The fallback below types into Blizzard's own browse box, which does not exist
-- on this client: the modern auction house replaced BrowseName, so without
-- Auctionator a click has nowhere to go and silently does nothing. Saying so
-- beats looking broken.
local function HaveAuctionator()
	local api=Auctionator and Auctionator.API and Auctionator.API.v1
	return (api and (api.MultiSearchAdvanced or api.MultiSearch or api.MultiSearchExact)) and true or false
end

-- Why a click did nothing, in the order the reasons actually apply.
local function ExplainNoSearch(name)
	if not AuctionHouseIsOpen() then
		ns.Print(L.INSPECT_AH_CLOSED,name)
	elseif not HaveAuctionator() then
		ns.Print(L.INSPECT_AH_NEEDS_AUCTIONATOR,name)
	else
		ns.Print(L.INSPECT_AH_CLOSED,name)
	end
end

local function SearchAuctionHouse(name,howMany,loose)
	if not (name and name~="") then return false end
	if not AuctionHouseIsOpen() then return false end

	-- A quoted name is Auctionator's own syntax for an exact search, and it
	-- refuses a term that arrives already wrapped in quotes -- so the name goes
	-- in bare and isExact says what to do with it.
	local api=Auctionator and Auctionator.API and Auctionator.API.v1

	if api and api.MultiSearchAdvanced then
		local term={ searchString=name, isExact=not loose }

		-- Only when there is more than one to buy. A quantity of one is what it
		-- would do anyway, and leaving the field empty keeps the search simple.
		if howMany and howMany>1 then term.quantity=howMany end

		if pcall(api.MultiSearchAdvanced,AUCTIONATOR_ID,{ term }) then return true end
	end

	if loose and api and api.MultiSearch then
		if pcall(api.MultiSearch,AUCTIONATOR_ID,{ name }) then return true end
	end

	if not loose and api and api.MultiSearchExact then
		if pcall(api.MultiSearchExact,AUCTIONATOR_ID,{ name }) then return true end
	end

	-- No Auctionator: the auction house's own browse tab, filled in and
	-- searched the way a person would.
	if AuctionFrameTab1 and AuctionFrameTab1.Click then pcall(AuctionFrameTab1.Click,AuctionFrameTab1) end

	local box=_G.BrowseName
	if not box then return false end

	-- The name as worn, and nothing widened.
	--
	-- This used to type the plain form on purpose: Blizzard's browse matches on
	-- a substring, so "Delicate Pandarian Garnet" finds the perfect cut as well
	-- as itself. That was the same mistake as the twin search above wearing a
	-- different hat -- a wider net that returns a weaker gem beside the right
	-- one and leaves the choosing to somebody who came here to be told.
	box:SetText(name)
	box:SetFocus()
	box:HighlightText(0,0)

	if _G.BrowseSearchButton and _G.BrowseSearchButton.Click then
		pcall(_G.BrowseSearchButton.Click,_G.BrowseSearchButton)
	end

	return true
end

-- An item the client may not have heard of yet.
--
-- GetItemInfo answers nil for anything not in the local cache and quietly asks
-- the server for it, so the first look at a character shows "item 76884" where
-- the name should be. Asking is therefore only half the job: the answer arrives
-- later, as an event, and the list has to be built again when it does.
local QUESTION="Interface/Icons/INV_Misc_QuestionMark"

-- Whether a belt has had a buckle put on it.
--
-- The extra gem is the evidence. A belt carrying more gems than the item
-- itself has sockets can only have been buckled -- Blizzard records the gem
-- and says nothing whatever about the thing that made the socket, so there is
-- nothing else to go on.
--
-- Silent where the client has never seen the belt. GetItemStats answers
-- nothing then, and these are other people's belts, so almost none of them are
-- cached -- which was the whole of why this never fired. Requesting the item
-- is enough: both the paper doll and the socket page already repaint when item
-- data arrives, which is the same reason the slot borders start grey.
function HasBuckle(record)
	if not (record and record[1] and GetItemStats) then return false end

	local worn=0
	for index=3,#record do
		local gem=tonumber(record[index])
		if gem and gem>0 then worn=worn+1 end
	end
	if worn<1 then return false end

	local stats=GetItemStats("item:"..tostring(record[1]))
	if not stats then
		if C_Item and C_Item.RequestLoadItemDataByID then
			pcall(C_Item.RequestLoadItemDataByID,record[1])
		end
		return false
	end

	local sockets=0
	for key,value in pairs(stats) do
		if key:find("EMPTY_SOCKET") then sockets=sockets+(value or 0) end
	end

	return worn>sockets
end

local function AskForItem(id)
	if not id or id<=0 then return end
	if C_Item and C_Item.RequestLoadItemDataByID then
		pcall(C_Item.RequestLoadItemDataByID,id)
	end
end

-- Every slot the paper doll draws, in the order it draws them, so the lists
-- below read top to bottom the way the doll does.
local EVERY_SLOT={}
for _,list in ipairs({ LEFT_SLOTS, RIGHT_SLOTS, BOTTOM_SLOTS }) do
	for _,slotKey in ipairs(list) do EVERY_SLOT[#EVERY_SLOT+1]=slotKey end
end

-- "finger_1" as "Finger 1". The keys come from Blizzard's own slot names, so
-- tidying them beats keeping a translation table in step with them.
local function SlotLabel(slotKey)
	local text=(slotKey or ""):gsub("_"," ")
	return (text:gsub("^%l",string.upper))
end

-- Enchants nobody can buy, and enchants sold under another name.
--
-- The list is a shopping list, so an enchant you cannot go and buy does not
-- belong on it. Blizzard's data does not mark them: Lightweave Embroidery and
-- a leg spellthread both arrive as a PERMANENT enchant with no source item,
-- and one is tailoring-only while the other is on the auction house right now.
-- So the two cases are told apart by what they are rather than by what is
-- missing:
--
--   embroidery is tailoring's own cloak enchant, self-only, all three of them;
--   a ring enchant is enchanting's own, and this expansion has no other way to
--   put one on.
--
-- Engineering's tinkers never reach here -- they are kept in their own field
-- rather than in the slot's enchant -- so they need no rule.
-- "feral-combat" -> "Feral Combat". Slugs are how the ladder stores a class
-- and a spec; this is how a person reads one.
local function Titled(slug)
	if not slug or slug=="" then return nil end
	local words={}
	for word in tostring(slug):gmatch("[^%-]+") do
		words[#words+1]=word:sub(1,1):upper()..word:sub(2)
	end
	return table.concat(words," ")
end

local function IsProfessionOnly(slotKey,applied,name,effect)
	local text=((name or "").." "..(effect or "")):lower()

	if text:find("embroidery",1,true) then return true end

	-- The id, not the name: a name that has not finished loading is not the
	-- same thing as an enchant with nothing behind it.
	if (slotKey=="finger_1" or slotKey=="finger_2") and not applied then return true end

	return false
end

-- Enchants whose name on the item is not the name in the shop.
--
-- A PvP weapon renames the enchant it carries: the scroll is Jade Spirit and
-- the weapon says Spirit of Conquest, the scroll is Dancing Steel and the
-- weapon says Bloody Dancing Steel. Searching the auction house for the name
-- the weapon shows finds nothing, which is the whole point of the list.
local ENCHANT_ALIAS={
	["spirit of conquest"]="Enchant Weapon - Jade Spirit",
	["bloody dancing steel"]="Enchant Weapon - Dancing Steel",
	["glorious tyranny"]="Enchant Weapon - Tyranny",
}

local function AliasFor(text)
	if not text then return nil end
	local lower=text:lower()
	for from,to in pairs(ENCHANT_ALIAS) do
		if lower:find(from,1,true) then return to end
	end
	return nil
end

-- Gem item ids and enchant ids out of a gear table, counted.
--
-- A slot is { itemID, enchantID, gem, gem, gem }: everything from the third
-- entry on is a gem, and the same gem in four sockets is one line saying four.
local function SocketTally(gear)
	local gemOrder,gemCount={},{}
	local enchants={}

	-- The belt buckle, which is not an enchant and so was never counted.
	--
	-- Everything else on a piece of gear is either an enchant id or a gem id,
	-- and a buckle is neither: it adds a socket. Blizzard records the gem that
	-- goes in that socket and says nothing whatever about the thing that made
	-- the socket exist -- so a belt with a buckle and a belt without look
	-- identical apart from one extra gem, and the shopping list quietly left
	-- out an item every geared player is wearing.
	--
	-- The extra gem is the evidence. A belt carrying more gems than the item
	-- itself has sockets can only have been buckled.
	--
	-- Silent where the client has not cached the item: GetItemStats answers
	-- nothing then, and guessing from nothing would put a buckle on every belt
	-- until the cache caught up.

	for _,slotKey in ipairs(EVERY_SLOT) do
		local piece=gear and gear[slotKey]
		if type(piece)=="table" then
			for index=3,#piece do
				local gem=tonumber(piece[index])
				if gem and gem>0 then
					if not gemCount[gem] then
						gemCount[gem]=0
						gemOrder[#gemOrder+1]=gem
					end
					gemCount[gem]=gemCount[gem]+1
				end
			end

			local enchant=tonumber(piece[2])
			if enchant and enchant>0 then
				local applied=ns.ENCHANT_ITEM and ns.ENCHANT_ITEM[enchant]
				local shopName=applied and GetItemInfo(applied)
				local effect=ns.ENCHANT_TEXT and ns.ENCHANT_TEXT[enchant]

				if not IsProfessionOnly(slotKey,applied,shopName,effect) then
					enchants[#enchants+1]={ slot=slotKey, id=enchant, item=tonumber(piece[1]) }
				end
			end

			-- Carried as an ordinary enchant row from here on, because that is
			-- what it is to somebody copying the build: a thing to buy and put
			-- on the belt. It names its own item rather than being looked up
			-- by enchant id, since it has no enchant id to be looked up by.
			if slotKey=="waist" and HasBuckle(piece) then
				enchants[#enchants+1]={
					slot=slotKey, id=0, buckle=true,
					item=tonumber(piece[1]),
				}
			end
		end
	end

	return gemOrder,gemCount,enchants
end

-- The gear the tab is currently showing, so it can be built again when the
-- names it was missing arrive.
--
-- The paper doll needs the same treatment for a different reason: a slot's
-- quality colour comes from GetItemInfo, which answers nil until the client has
-- the item, so the borders start grey and have to be painted again once it
-- does.
local socketGear
local socketGlyphs
local socketClass
local socketTinkers
local socketWatcher

local function FillSockets(gear,glyphs,class)
	local page=frame and frame.pages and frame.pages.sockets
	if not page then return end

	socketGear=gear
	socketGlyphs=glyphs
	socketClass=class

	-- Set here rather than when the page was built: Auctionator can be
	-- disabled between sessions, and a line promising a search that cannot
	-- happen is worse than no line.
	page.hint:SetText(HaveAuctionator() and L.INSPECT_AH_HINT or L.INSPECT_AH_HINT_NO_AUCTIONATOR)

	local gemOrder,gemCount,enchants=SocketTally(gear)

	for index,row in ipairs(page.gems) do
		local gem=gemOrder[index]
		if not gem then
			row:Hide()
		else
			local name,link,quality,_,_,_,_,_,_,icon=GetItemInfo(gem)

			if not name then
				-- Not cached yet. Asked for, and the list rebuilds itself when
				-- the answer lands.
				AskForItem(gem)
			end

			row.icon:SetTexture(icon or QUESTION)
			row.text:SetText(L.INSPECT_GEM_COUNT:format(gemCount[gem],name or L.INSPECT_LOADING))

			-- Coloured by quality, the way the game colours item names
			-- everywhere else. Rare gems read blue, the common ones green.
			if quality and GetItemQualityColor then
				local r,g,b=GetItemQualityColor(quality)
				row.text:SetTextColor(r,g,b)
			else
				row.text:SetTextColor(0.7,0.7,0.7)
			end

			row.gemName=name
			row.gemLink=link
			row.gemCount=gemCount[gem]
			row:SetScript("OnEnter",function(self)
				GameTooltip:SetOwner(self,"ANCHOR_RIGHT")
				if self.gemLink then
					GameTooltip:SetHyperlink(self.gemLink)
				else
					GameTooltip:SetText(L.INSPECT_LOADING)
				end
				GameTooltip:Show()
			end)
			row:SetScript("OnLeave",function() GameTooltip:Hide() end)
			row:SetScript("OnClick",function(self)
				if not self.gemName then return end
				-- However many of them are worn: four sockets of one gem is a
				-- search for four, not for one.
				if SearchAuctionHouse(self.gemName,self.gemCount) then
					ns.Print(L.INSPECT_AH_SEARCHED_COUNT,self.gemCount or 1,self.gemName)
				else
					-- Said out loud rather than silently doing nothing, which
					-- is indistinguishable from a broken button.
					ExplainNoSearch(self.gemName)
				end
			end)
			row:Show()
		end
	end

	-- More distinct gems than there are rows is possible in principle and has
	-- not happened; the count is still honest about what is not shown.
	if #gemOrder==0 and page.gems[1] then
		page.gems[1].icon:SetTexture(nil)
		page.gems[1].text:SetText(L.INSPECT_NO_GEMS)
		page.gems[1]:SetScript("OnEnter",nil)
		page.gems[1]:SetScript("OnClick",nil)
		page.gems[1]:Show()
	end

	for index,row in ipairs(page.enchants) do
		local entry=enchants[index]
		if not entry then
			row:Hide()
		else
			-- The enchant by name, not by effect.
			--
			-- "Greater Crane Wing Inscription" is the thing you go and buy;
			-- "+200 Intellect and +100 Critical Strike" is what it does, which
			-- the paper doll already says beside the shoulder. Blizzard hands
			-- back the item that applied the enchant, so the name, the icon,
			-- the quality colour and the auction house search all come from
			-- the same place they do for gems.
			local applied=ns.ENCHANT_ITEM and ns.ENCHANT_ITEM[entry.id]
			local effect=ns.ENCHANT_TEXT and ns.ENCHANT_TEXT[entry.id]

			local name,link,quality,icon
			if entry.buckle then
				-- Named outright. Everything else about it -- the icon, the
				-- quality colour, the link for the tooltip -- is a bonus that
				-- arrives if the client happens to know the item.
				name,link,quality,icon=BuckleItem()
				name=name or BELT_BUCKLE_NAME

			elseif applied then
				name,link,quality=GetItemInfo(applied)
				icon=select(10,GetItemInfo(applied))
				if not name then
					AskForItem(applied)
				end
			end

			-- Sold under a different name than the weapon shows.
			local alias=AliasFor(name) or AliasFor(effect)

			row.icon:SetTexture(icon or QUESTION)

			-- Falling back through what we have: the shop's name for it, else
			-- the item's, else what it does, else its number. Never nothing.
			local label=alias or name or effect or (L.INSPECT_ENCHANT_ID):format(entry.id)
			row.text:SetText(("|cffffd100%s|r  %s"):format(SlotLabel(entry.slot),label))

			if name and quality and GetItemQualityColor then
				local r,g,b=GetItemQualityColor(quality)
				row.text:SetTextColor(r,g,b)
			else
				-- No name to colour: green, the way enchant text reads in game.
				row.text:SetTextColor(0.1,1,0.1)
			end

			-- Searched for by the name it is sold under. An aliased one is
			-- searched loosely, since the scroll is "Enchant Weapon - Jade
			-- Spirit" and the alias is the half of that worth matching.
			row.gemName=alias or name
			row.gemLoose=(alias~=nil)
			row.gemLink=link
			row.gemCount=1
			row:SetScript("OnEnter",function(self)
				GameTooltip:SetOwner(self,"ANCHOR_RIGHT")
				if self.gemLink then
					GameTooltip:SetHyperlink(self.gemLink)
					if effect then GameTooltip:AddLine(effect,0.1,1,0.1) end
				else
					GameTooltip:SetText(effect or L.INSPECT_LOADING)
				end
				GameTooltip:Show()
			end)
			row:SetScript("OnLeave",function() GameTooltip:Hide() end)
			row:SetScript("OnClick",function(self)
				if not self.gemName then return end
				if SearchAuctionHouse(self.gemName,1,self.gemLoose) then
					ns.Print(L.INSPECT_AH_SEARCHED,self.gemName)
				else
					ExplainNoSearch(self.gemName)
				end
			end)
			row:Show()
		end
	end

	if #enchants==0 and page.enchants[1] then
		page.enchants[1].icon:SetTexture(nil)
		page.enchants[1].text:SetText(L.INSPECT_NO_ENCHANTS)
		page.enchants[1]:SetScript("OnEnter",nil)
		page.enchants[1]:Show()
	end

	-- Glyphs, because a shopping list that stops at gems and enchants is not
	-- the whole bill. Six more things to buy, from the same window, in the same
	-- two clicks.
	--
	-- A glyph is sold under its own name -- the item that teaches Glyph of Deep
	-- Freeze is called Glyph of Deep Freeze -- so the name is both the label and
	-- the search term, and no glyph-to-item table is needed to shop for one.
	--
	-- The icon does not need one either: in this expansion every major glyph of
	-- a class shares one piece of art and every minor another, and that is the
	-- item's own icon. The quality colour is the one thing that would, so it is
	-- asked for on the chance the client has the item cached -- browsing the
	-- auction house caches them, and this page only exists at an auction house
	-- -- and simply left white when it does not.
	local glyphArt=GLYPH_ICON_CLASS[class or ""]
	local majorIcon=glyphArt and ("Interface/Icons/INV_Glyph_Major"..glyphArt)
	local minorIcon=glyphArt and ("Interface/Icons/INV_Glyph_Minor"..glyphArt)

	local worn=GlyphList(glyphs)

	for index,row in ipairs(page.glyphs) do
		local glyph=worn[index]
		if not glyph then
			row:Hide()
		else
			local _,link,quality,_,_,_,_,_,_,icon=GetItemInfo(glyph.name)

			row.icon:SetTexture(icon
				or (glyph.kind==1 and majorIcon)
				or (glyph.kind==2 and minorIcon)
				or QUESTION)
			row.text:SetText(glyph.name)

			if quality and GetItemQualityColor then
				local r,g,b=GetItemQualityColor(quality)
				row.text:SetTextColor(r,g,b)
			else
				row.text:SetTextColor(1,1,1)
			end

			row.glyphName=glyph.name
			row.glyphID=glyph.id
			row.glyphKind=glyph.kind
			row.gemLink=link

			-- Searchable only under a name we actually have. A glyph whose name
			-- never reached us reads as "Glyph 700", and sending that to the
			-- auction house would find nothing and look broken doing it.
			row.gemName=ns.GLYPH_NAMES and ns.GLYPH_NAMES[glyph.id]
			row.gemCount=1

			row:SetScript("OnEnter",function(self)
				if not self.glyphName then return end

				-- Built here rather than from the client's glyph hyperlink,
				-- which insists everything is a major glyph -- see the same
				-- tooltip on the talents page.
				GameTooltip:SetOwner(self,"ANCHOR_RIGHT")
				GameTooltip:SetText(self.glyphName,1,1,1)

				if self.glyphKind==1 then
					GameTooltip:AddLine(L.INSPECT_GLYPH_MAJOR,0.4,0.6,1)
				elseif self.glyphKind==2 then
					GameTooltip:AddLine(L.INSPECT_GLYPH_MINOR,0.4,0.6,1)
				end

				local spellID=ns.GLYPH_SPELL and ns.GLYPH_SPELL[self.glyphID]
				local says=spellID and GetSpellDescription and GetSpellDescription(spellID)
				if says and says~="" then
					GameTooltip:AddLine(says,1,0.82,0,true)
				end

				GameTooltip:Show()
			end)
			row:SetScript("OnLeave",function() GameTooltip:Hide() end)
			row:SetScript("OnClick",function(self)
				if not self.gemName then return end
				if SearchAuctionHouse(self.gemName,1) then
					ns.Print(L.INSPECT_AH_SEARCHED,self.gemName)
				else
					ExplainNoSearch(self.gemName)
				end
			end)
			row:Show()
		end
	end

	if #worn==0 and page.glyphs[1] then
		page.glyphs[1].icon:SetTexture(nil)
		page.glyphs[1].text:SetText(L.INSPECT_NO_GLYPHS)
		page.glyphs[1].text:SetTextColor(0.7,0.7,0.7)
		page.glyphs[1]:SetScript("OnEnter",nil)
		page.glyphs[1]:SetScript("OnClick",nil)
		page.glyphs[1]:Show()
	end

	-- Something is still on its way, always: gem names here, and over on the
	-- paper doll the item qualities that colour the slot borders. Registered
	-- while the window is open rather than only when this tab noticed a gap --
	-- the tab that needs the answer is not always the tab that asked.
	--
	-- Unregistered when the window closes, since nothing outside it cares.
	do
		if not socketWatcher then
			socketWatcher=CreateFrame("Frame")
			socketWatcher:SetScript("OnEvent",function()
				if not socketGear then return end

				FillSockets(socketGear,socketGlyphs,socketClass)

				-- And the slots, whose borders were grey while the item was
				-- still on its way.
				if frame and frame.pages and frame.pages.character then
					for slotKey,button in pairs(frame.pages.character.slots) do
						FillSlot(button,socketGear[slotKey],(socketTinkers or {})[slotKey],slotKey)
					end
				end
			end)
		end
		socketWatcher:RegisterEvent("GET_ITEM_INFO_RECEIVED")
	end
end

-- ---------------------------------------------------------------- stats

-- What they are actually running.
--
-- The gear cannot answer this. Every equipped item Blizzard returns carries the
-- stats it had on the vendor's shelf -- measured across 402 items on 24
-- gladiators, 243 distinct base items, not one point of deviation -- so
-- reforging, gems and enchants, which are most of what separates geared from
-- played, are all invisible there.
--
-- These totals are the played character instead. Not a sum of the gear, and
-- worth being precise about what they are: Blizzard reports a percentage and a
-- rating side by side, and the rating is derived from the percentage at a fixed
-- rate -- 600 per 1% crit, 425 per 1% haste, exactly, on every character
-- checked. So anything at all that moves the percentage is in the number,
-- passives included, not only what is bolted to the gear.
--
-- That makes them the right answer to "what does the best of my spec actually
-- run" and the wrong answer to "what did they reforge". Attribution to a piece
-- was tried and abandoned -- with gems, enchants and socket bonuses all
-- accounted for, 17 of 20 characters had no consistent assignment at all,
-- because the two sides of that equation are not made of the same thing.

-- The v block, in the order the scanner writes it.
local V_CRIT, V_HASTE, V_MASTERY, V_SPIRIT       = 1, 2, 3, 4
local V_STRENGTH, V_AGILITY, V_INTELLECT         = 5, 6, 7
local V_STAMINA, V_HEALTH                        = 8, 9
local V_SPELL_POWER, V_ATTACK_POWER              = 10, 11

local STAT_ROWS = 6

local function Grouped(value)
	value=math.floor(tonumber(value) or 0)
	if BreakUpLargeNumbers then
		local ok,text=pcall(BreakUpLargeNumbers,value)
		if ok and text then return text end
	end

	-- Health runs to six figures, and six figures unbroken is a number nobody
	-- reads at a glance.
	local text,done=tostring(value),nil
	repeat
		text,done=text:gsub("^(-?%d+)(%d%d%d)","%1,%2")
	until done==0
	return text
end

local function BuildStatsPage(parent)
	local page=CreateFrame("Frame",nil,parent)
	page:SetPoint("TOPLEFT",14,TOP)
	page:SetPoint("BOTTOMRIGHT",-14,44)
	page:Hide()

	local function Group(x,width,title)
		local head=page:CreateFontString(nil,"OVERLAY","GameFontNormal")
		head:SetPoint("TOPLEFT",x,-4)
		head:SetText(title)

		local rows={}
		for index=1,STAT_ROWS do
			local row=CreateFrame("Frame",nil,page)
			row:SetSize(width,22)
			if index==1 then
				row:SetPoint("TOPLEFT",head,"BOTTOMLEFT",0,-10)
			else
				row:SetPoint("TOPLEFT",rows[index-1],"BOTTOMLEFT",0,-3)
			end

			-- Striped like the ladder, so the eye carries across the gap from
			-- the name on the left to the number on the right.
			if index%2==0 then
				local stripe=row:CreateTexture(nil,"BACKGROUND")
				stripe:SetAllPoints()
				stripe:SetColorTexture(1,1,1,0.03)
			end

			row.label=row:CreateFontString(nil,"OVERLAY","GameFontHighlight")
			row.label:SetPoint("LEFT",8,0)
			row.label:SetJustifyH("LEFT")

			row.value=row:CreateFontString(nil,"OVERLAY","GameFontNormal")
			row.value:SetPoint("RIGHT",-8,0)
			row.value:SetJustifyH("RIGHT")

			row:Hide()
			rows[index]=row
		end
		return rows
	end

	page.attributes=Group(0,290,L.INSPECT_STATS_ATTRIBUTES)
	page.secondary=Group(330,290,L.INSPECT_STATS_SECONDARY)

	page.empty=page:CreateFontString(nil,"OVERLAY","GameFontDisableLarge")
	page.empty:SetPoint("CENTER",0,20)
	page.empty:SetText(L.INSPECT_STATS_NONE)
	page.empty:Hide()

	return page
end

local function FillStats(v)
	local page=frame and frame.pages and frame.pages.stats
	if not page then return end

	local function Draw(rows,list)
		for index,row in ipairs(rows) do
			local entry=list and list[index]
			if not entry then
				row:Hide()
			else
				row.label:SetText(entry[1])
				row.value:SetText(Grouped(entry[2]))
				row:Show()
			end
		end
	end

	-- Recorded from the run that read this character, and a character read
	-- before this pass existed simply has none. Blank rather than a column of
	-- zeroes, which would read as a character with no stats.
	if type(v)~="table" or #v==0 then
		Draw(page.attributes,nil)
		Draw(page.secondary,nil)
		page.empty:Show()
		return
	end
	page.empty:Hide()

	-- Which primary is theirs, decided by which one is big rather than from a
	-- class table. Every character has all three and two of them sit at their
	-- unbuffed base, so the gear picks the winner without being asked.
	local primaryName,primaryValue=L.INSPECT_STAT_STRENGTH,v[V_STRENGTH] or 0
	if (v[V_AGILITY] or 0)>primaryValue then
		primaryName,primaryValue=L.INSPECT_STAT_AGILITY,v[V_AGILITY]
	end
	if (v[V_INTELLECT] or 0)>primaryValue then
		primaryName,primaryValue=L.INSPECT_STAT_INTELLECT,v[V_INTELLECT]
	end

	-- And the same for whichever power they actually use: a healer's attack
	-- power and a rogue's spell power are both noise.
	local powerName,powerValue=L.INSPECT_STAT_ATTACK_POWER,v[V_ATTACK_POWER] or 0
	if (v[V_SPELL_POWER] or 0)>powerValue then
		powerName,powerValue=L.INSPECT_STAT_SPELL_POWER,v[V_SPELL_POWER]
	end

	Draw(page.attributes,{
		{ primaryName, primaryValue },
		{ L.INSPECT_STAT_STAMINA, v[V_STAMINA] },
		{ L.INSPECT_STAT_HEALTH,  v[V_HEALTH] },
		{ powerName, powerValue },
	})

	Draw(page.secondary,{
		{ L.INSPECT_STAT_CRIT,    v[V_CRIT] },
		{ L.INSPECT_STAT_HASTE,   v[V_HASTE] },
		{ L.INSPECT_STAT_MASTERY, v[V_MASTERY] },
		{ L.INSPECT_STAT_SPIRIT,  v[V_SPIRIT] },
	})
end

-- ---------------------------------------------------------------- window

local function ShowPage(which)
	if not frame then return end
	for name,page in pairs(frame.pages) do
		page:SetShown(name==which and frame.hasData)
	end
	frame.page=which

	for name,tab in pairs(frame.tabs) do
		-- The selected tab reads brighter, the way Blizzard's do.
		tab:SetAlpha(name==which and 1 or 0.6)
	end
end

-- The shopping list is a tab only where it can be used.
--
-- Every line on it searches the auction house, so away from one the page is a
-- list of things you cannot do anything about -- and a fifth tab that is inert
-- most of the time is worse than a window that grows one when it matters. It
-- appears when the auction house is open, which is also the only way the
-- auction house panel reaches this window in the first place.
--
-- Last in the tab row, so its coming and going leaves no gap in the middle.
local function ShowShoppingTab()
	local tab=frame and frame.tabs and frame.tabs.sockets
	if not tab then return end

	local shopping=AuctionHouseIsOpen()
	tab:SetShown((shopping and frame.hasData) and true or false)

	-- Walking away from the auctioneer with the list open: back to the paper
	-- doll, rather than leaving a page up whose every row has stopped working.
	if not shopping and frame.page=="sockets" then ShowPage("character") end
end

local function BuildWindow()
	if frame then return frame end

	frame=CreateFrame("Frame","ArenaPlus_Inspect",UIParent,"BackdropTemplate")
	frame:Hide()
	frame:SetSize(WIDTH,HEIGHT)
	-- The tallest window here, and the only one that never had a scale at
	-- all: at 660x560 it runs off the bottom of a small screen, taking the
	-- tab row with it.
	if ns.FitScale then frame:SetScale(ns.FitScale(WIDTH,HEIGHT,1)) end
	frame:SetPoint("CENTER")
	-- Above the ladder, which is also DIALOG and was drawing straight over the
	-- top of this -- the panel looked transparent when it was simply behind.
	frame:SetFrameStrata("FULLSCREEN_DIALOG")
	frame:SetToplevel(true)
	frame:EnableMouse(true)
	-- Movable, except when it is hanging off the auction house.
	--
	-- Opened from the ladder it is a window in its own right and drags like
	-- one. Opened from the auction house it is the third panel in a row --
	-- house, top players, their gems -- and a row you can pull one piece out of
	-- is a row that ends up wrong.
	frame:SetMovable(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart",function(self)
		if self.attached then return end
		self:StartMoving()
	end)
	frame:SetScript("OnDragStop",frame.StopMovingOrSizing)
	ns.StyleAsPanel(frame)

	-- Its own opaque layer on top of the shared styling. The panel was letting
	-- the ladder show through even once it was in a higher strata, which means
	-- the trouble was transparency rather than order. Rather than chase which
	-- of the shared backdrop's layers is see-through, this puts a solid one
	-- underneath everything and above nothing.
	local solid=frame:CreateTexture(nil,"BACKGROUND",nil,-7)
	solid:SetPoint("TOPLEFT",frame,"TOPLEFT",11,-12)
	solid:SetPoint("BOTTOMRIGHT",frame,"BOTTOMRIGHT",-12,11)
	solid:SetColorTexture(0.04,0.04,0.05,1)

	tinsert(UISpecialFrames,"ArenaPlus_Inspect")

	-- Nothing outside this window cares what items have finished loading.
	frame:SetScript("OnHide",function()
		if socketWatcher then socketWatcher:UnregisterEvent("GET_ITEM_INFO_RECEIVED") end
	end)

	-- The same band across the top as the ladder window, so the two read as
	-- parts of one addon rather than two.
	local band=frame:CreateTexture(nil,"BORDER")
	band:SetPoint("TOPLEFT",frame,"TOPLEFT",11,-BAND_INSET)
	band:SetPoint("TOPRIGHT",frame,"TOPRIGHT",-12,-BAND_INSET)
	band:SetHeight(BAND_HEIGHT)
	band:SetColorTexture(1,1,1,1)

	local shaded=false
	if band.SetGradient and CreateColor then
		shaded=pcall(band.SetGradient,band,"VERTICAL",
			CreateColor(0.06,0.07,0.10,1),CreateColor(0.14,0.16,0.22,1))
	end
	if not shaded and band.SetGradientAlpha then
		shaded=pcall(band.SetGradientAlpha,band,"VERTICAL",
			0.06,0.07,0.10,1,0.14,0.16,0.22,1)
	end
	if not shaded then band:SetColorTexture(0.10,0.11,0.15,1) end

	local underline=frame:CreateTexture(nil,"ARTWORK")
	underline:SetPoint("TOPLEFT",band,"BOTTOMLEFT",0,0)
	underline:SetPoint("TOPRIGHT",band,"BOTTOMRIGHT",0,0)
	underline:SetHeight(1)
	underline:SetColorTexture(1,0.82,0,0.35)

	frame.title=frame:CreateFontString(nil,"OVERLAY","GameFontHighlightLarge")
	frame.title:SetPoint("TOPLEFT",16,-14)

	-- "Subtlety Rogue", across the top in the class's colour.
	--
	-- Centred rather than beside the name: the name is what you looked them up
	-- by, this is what they ARE, and on TBC it is not otherwise on screen at
	-- all -- the tree list below says 41 points in Subtlety but never says the
	-- word rogue.
	frame.specLine=frame:CreateFontString(nil,"OVERLAY","GameFontHighlightLarge")
	frame.specLine:SetPoint("TOP",frame,"TOP",0,-18)
	frame.specLine:SetJustifyH("CENTER")

	frame.subtitle=frame:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
	frame.subtitle:SetPoint("TOPLEFT",frame.title,"BOTTOMLEFT",0,-4)
	frame.subtitle:SetTextColor(0.55,0.55,0.55)

	local close=CreateFrame("Button",nil,frame,"UIPanelCloseButton")
	close:SetPoint("TOPRIGHT",frame,"TOPRIGHT",0,0)

	-- Professions, up beside the name rather than down among the gear: it is a
	-- fact about the character, not about any one slot. No skill level, because
	-- the gear proves the profession and says nothing about the number.
	frame.professions={}
	for index=1,4 do
		local mark=CreateFrame("Button",nil,frame)
		mark:SetSize(22,22)
		if index==1 then
			mark:SetPoint("TOPRIGHT",frame,"TOPRIGHT",-36,-16)
		else
			mark:SetPoint("RIGHT",frame.professions[index-1],"LEFT",-4,0)
		end

		mark.icon=mark:CreateTexture(nil,"ARTWORK")
		mark.icon:SetAllPoints()
		mark.icon:SetTexCoord(0.07,0.93,0.07,0.93)

		mark:SetScript("OnEnter",function(self)
			if not self.label then return end
			GameTooltip:SetOwner(self,"ANCHOR_LEFT")
			GameTooltip:SetText(self.label)
			GameTooltip:AddLine(L.INSPECT_PROFESSION_NOTE,0.6,0.6,0.6,true)
			GameTooltip:Show()
		end)
		mark:SetScript("OnLeave",function() GameTooltip:Hide() end)
		mark:Hide()

		frame.professions[index]=mark
	end

	frame.pages={
		character = BuildCharacterPage(frame),
		pvp       = BuildPvPPage(frame),
		talents   = BuildTalentsPage(frame),
		stats     = BuildStatsPage(frame),
		sockets   = BuildSocketsPage(frame),
	}

	-- Tabs along the foot, in Blizzard's order. Their own template if this
	-- build has it, so they look like the tabs on the window this copies; a
	-- plain button if not, because a missing template must not take the panel
	-- down with it.
	frame.tabs={}
	--
	-- Stats sits next to the paper doll because it answers the other half of the
	-- same question, and the shopping list stays last so that its coming and
	-- going leaves no hole in the middle of the row.
	local order={ { "character", L.INSPECT_TAB_CHARACTER }, { "stats", L.INSPECT_TAB_STATS },
		{ "pvp", L.INSPECT_TAB_PVP }, { "talents", L.INSPECT_TAB_TALENTS },
		{ "sockets", L.INSPECT_TAB_SOCKETS } }
	local previous
	for index,pair in ipairs(order) do
		local key,label=pair[1],pair[2]

		-- Named, and that is not decoration. Blizzard's tab template builds the
		-- names of its own textures out of self:GetName() in its OnEnter, so a
		-- tab created with a nil name throws "attempt to concatenate a nil
		-- value" the first time the cursor crosses it -- not when it is made,
		-- which is why it looked fine until somebody hovered.
		local tabName="ArenaPlus_InspectTab"..index

		local ok,tab=pcall(CreateFrame,"Button",tabName,frame,"CharacterFrameTabButtonTemplate")
		if not (ok and tab) then
			ok,tab=pcall(CreateFrame,"Button",tabName,frame,"UIPanelButtonTemplate")
			if ok and tab then tab:SetSize(96,24) end
		end
		if not (ok and tab) then break end

		tab:SetText(label)
		-- The same template reads this for its hover tip.
		tab.tooltip=label
		if tab.SetFrameLevel then tab:SetFrameLevel(frame:GetFrameLevel()+8) end

		-- Blizzard tabs are drawn from three pieces and size themselves to the
		-- text; without this they keep the template's own width and the labels
		-- run over the edges.
		if PanelTemplates_TabResize then pcall(PanelTemplates_TabResize,tab,0) end

		if previous then
			tab:SetPoint("LEFT",previous,"RIGHT",4,0)
		else
			tab:SetPoint("BOTTOMLEFT",frame,"BOTTOMLEFT",14,10)
		end

		tab:SetScript("OnClick",function() ShowPage(key) end)
		frame.tabs[key]=tab
		previous=tab
	end

	-- The set line, reapplied until the client stops rebuilding the tooltip.
	--
	-- Hovering a tier piece, the corrected count kept reverting to Blizzard's
	-- own -- which counts how many of that set *you* are wearing, so it reads
	-- 0/5 on somebody else's tier. Changing tab and hovering again fixed it,
	-- which made it look like a caching problem. It is not.
	--
	-- Measured with /arena settip. At the moment of hovering, the tooltip had
	-- 35 lines and its set header read "Gladiator's Refuge (0/0)" -- zero of
	-- zero, because the set's *other* pieces had not loaded yet. A third of a
	-- second later it had 40 lines and the header had moved down one and read
	-- "(0/5)". So the item under the cursor being cached is not the point: the
	-- client rebuilds this block once per member item as each arrives, and
	-- every rebuild throws our line away.
	--
	-- A one-shot repair cannot win that -- there is no way to know how many
	-- rebuilds are left. So it is reapplied while the tooltip is up, which
	-- costs a line count per frame and stops mattering the moment the client
	-- settles.
	--
	-- On this frame rather than a hook on GameTooltip: it only runs while the
	-- inspect window is open, which is the only time one of these slots can be
	-- under the cursor.
	local REDRAW_LIMIT = 40
	local CHECK_EVERY  = 0.1
	local lastOwner,lastLines,redraws,since=nil,nil,nil,0

	-- Whether the set line currently disagrees with us.
	--
	-- The line count is not enough on its own to notice a redraw: "(0/0)"
	-- becoming "(0/5)" is the same number of lines, and that is exactly the
	-- transition the probe caught while the set's members were still loading.
	local function SetLineWrong(owner)
		local setID=ns.SET_OF_ITEM and ns.SET_OF_ITEM[owner.itemID]
		local worn=setID and frame.setCounts and frame.setCounts[setID]
		if not worn then return false end

		for index=1,GameTooltip:NumLines() do
			local line=_G["GameTooltipTextLeft"..index]
			local text=line and line:GetText()
			-- Two captures, so the guard cannot be an `and`.
			--
			-- An `and` expression yields one value, so `of` was nil every time --
			-- which made the comparison below `nil ~= worn[2]`, always true, and
			-- this always answered that the line needed correcting.
			local has,of
			if text then has,of=text:match("%((%d+)/(%d+)%)") end
			if has then
				-- The first such line is the set header, the same one the
				-- correction rewrites.
				return tonumber(has)~=worn[1] or tonumber(of)~=worn[2]
			end
		end

		return false
	end

	frame:SetScript("OnUpdate",function(_,elapsed)
		since=since+(elapsed or 0)
		if since<CHECK_EVERY then return end
		since=0

		local owner=GameTooltip:IsShown() and GameTooltip:GetOwner()

		if not (owner and owner.isGearSlot) then
			lastOwner,lastLines,redraws=nil,nil,nil
			return
		end

		local lines=GameTooltip:NumLines()

		if owner~=lastOwner then
			lastOwner,lastLines,redraws=owner,lines,0
			return
		end

		-- Our own repair moves the line count too, so the count recorded after
		-- it is the one *including* our line -- otherwise this would rewrite
		-- every tick for ever.
		if lines==lastLines and not SetLineWrong(owner) then return end

		redraws=(redraws or 0)+1
		if redraws>REDRAW_LIMIT then
			lastLines=lines
			return
		end

		SlotTooltip(owner)
		lastLines=GameTooltip:NumLines()
	end)

	-- The auction house opening or closing underneath an open window.
	local shop=CreateFrame("Frame",nil,frame)
	shop:RegisterEvent("AUCTION_HOUSE_SHOW")
	shop:RegisterEvent("AUCTION_HOUSE_CLOSED")
	shop:SetScript("OnEvent",function()
		if frame:IsShown() then ShowShoppingTab() end
	end)

	return frame
end

-- ---------------------------------------------------------------- show

local function FillPvP(entry,region)
	local page=frame.pages.pvp

	for index,row in ipairs(page.rows) do
		local found=ns.LadderEntry and ns.LadderEntry(index,
			entry.realm and entry.realm~="" and (entry.name.."-"..entry.realm) or entry.name,region)

		if found then
			-- Each row knows its own bracket, which is its index, so every one
			-- is coloured against its own cutoffs.
			local hex=ns.TierHex and found.rating and ns.TierHex(index,found.rating)

			row.rating:SetText(hex
				and ("|cff%s%d|r"):format(hex,found.rating)
				or tostring(found.rating or ""))
			row.rank:SetText(hex
				and ("|cff%s%s|r"):format(hex,L.INSPECT_RANK:format(found.rank or 0))
				or L.INSPECT_RANK:format(found.rank or 0))

			-- Won in green and lost in red, as Blizzard's own panel writes it.
			row.record:SetText(L.HISTORY_RECORD:format(found.won or 0,found.lost or 0))

			row.bracket:SetTextColor(1,0.82,0)
			row.fill:SetColorTexture(0.06,0.06,0.08,0.9)
		else
			-- Dimmed rather than removed. A bracket somebody never queued is
			-- worth seeing as empty: it says they are a 2v2 player.
			row.rating:SetText(L.INSPECT_PVP_DASH)
			row.rank:SetText(L.INSPECT_PVP_DASH)
			row.record:SetText(L.INSPECT_PVP_DASH)

			row.bracket:SetTextColor(0.4,0.4,0.4)
			row.fill:SetColorTexture(0.04,0.04,0.05,0.9)
		end
	end
end

-- One person, named the same way every time, so two clicks on one row produce
-- the same string and two clicks on two rows do not.
local function WhoKey(entry,region)
	if type(entry)~="table" or not entry.name then return nil end

	local realm=entry.realm or ""
	local plain=ns.PlainName or function(text) return (text or ""):lower() end

	return plain(entry.name).."-"..plain(realm).."|"..(region or "")
end

function ns.ShowInspect(entry,region,bracket)
	if type(entry)~="table" or not entry.name then return end

	BuildWindow()
	region=region or ns.PlayerRegion() or "us"

	local data=InspectData(entry.name,entry.realm,region)

	local who=entry.name
	if entry.realm and entry.realm~="" then who=who.."-"..entry.realm end

	-- Nobody to look at, so nothing to open.
	--
	-- An empty window that explains itself was worse than no window: it closed
	-- whatever was already being read, and it took a click to dismiss something
	-- that had nothing in it. The reason goes to chat instead, where it can be
	-- read without costing anything.
	if not data then
		ns.Print("%s -- %s",who,entry.hidden and L.INSPECT_HIDDEN or L.INSPECT_NOT_COVERED)
		return
	end

	frame.showing=WhoKey(entry,region)
	frame.title:SetText(who)

	-- The spec, then the class.
	--
	-- On TBC it comes off the tree list, whose first entry is the deepest --
	-- the scraper sorts them that way, so the spec is simply the front of it.
	-- On Mists the ladder row already carries a spec slug.
	local specName
	if type(data.d)=="table" and data.d[1] then
		specName=tostring(data.d[1])
	elseif entry.spec and entry.spec~="" and entry.spec~="null" then
		specName=Titled(entry.spec)
	end

	local classToken=entry.class and entry.class~="" and entry.class~="null"
		and (entry.class:upper():gsub("%-","")) or nil
	local className=classToken
		and ((LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[classToken])
			or Titled(entry.class))
		or nil

	if specName and className then
		local colour=classToken and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classToken]
		local text=specName.." "..className
		-- colorStr is the game's own "ffRRGGBB" for the class. Preferred to
		-- formatting r/g/b: those are floats, and %x on a float is a thing Lua
		-- 5.1 handles by truncating rather than by refusing, which is the kind
		-- of nearly-right that shows up as an off-by-one colour.
		if colour and colour.colorStr then
			frame.specLine:SetText(("|c%s%s|r"):format(colour.colorStr,text))
		elseif colour then
			frame.specLine:SetText(("|cff%02x%02x%02x%s|r"):format(
				math.floor(colour.r*255+0.5),math.floor(colour.g*255+0.5),
				math.floor(colour.b*255+0.5),text))
		else
			frame.specLine:SetText(text)
		end
	else
		-- A hidden profile publishes neither, and half of "Rogue" on its own
		-- says less than nothing.
		frame.specLine:SetText("")
	end

	-- Coloured by the cutoffs, the same as on the ladder, so a gladiator rating
	-- reads as one here too. Only when the caller said which bracket these
	-- numbers came from: the same 2200 is a different colour in 2v2 and in
	-- rated battlegrounds, and colouring it against the wrong one would be
	-- worse than leaving it white.
	local hex=bracket and ns.TierHex and entry.rating and ns.TierHex(bracket,entry.rating)

	local bits={}
	if entry.rating then
		local text=L.INSPECT_RATING:format(entry.rating)
		bits[#bits+1]=hex and ("|cff%s%s|r"):format(hex,text) or text
	end
	if entry.rank then
		local text=L.INSPECT_RANK:format(entry.rank)
		bits[#bits+1]=hex and ("|cff%s%s|r"):format(hex,text) or text
	end
	bits[#bits+1]=(ns.RegionFlagMarkup and ns.RegionFlagMarkup(region,11))
		or (ns.RegionShort and ns.RegionShort(region))
		or region:upper()
	frame.subtitle:SetText(table.concat(bits,"   "))

	-- Always true by the time we are here: the no-data case turned back at the
	-- top. Kept as a field because ShowPage reads it to decide whether a page
	-- has anything to draw.
	frame.hasData=true
	for _,tab in pairs(frame.tabs) do tab:Show() end
	ShowShoppingTab()

	-- Where the slot tooltips can reach them, keyed by set.
	frame.setCounts={}
	for _,record in ipairs(data.s or {}) do
		-- Two numbers, worn and total. A fourth used to follow -- a bitmask of
		-- which pieces -- and files written before it was dropped still carry
		-- it; reading three fields ignores it either way.
		frame.setCounts[record[1]]={record[2] or 0,record[3] or 0}
	end

	local gear=data.g or {}

	-- And which of this character's items belong to each set, so the tooltip can
	-- name what they are wearing rather than counting lines.
	frame.setItems={}
	for _,piece in pairs(gear) do
		local itemID=type(piece)=="table" and tonumber(piece[1])
		local ofSet=itemID and ns.SET_OF_ITEM and ns.SET_OF_ITEM[itemID]
		if ofSet then
			frame.setItems[ofSet]=frame.setItems[ofSet] or {}
			table.insert(frame.setItems[ofSet],itemID)
		end
	end
	local tinkers=data.k or {}
	socketTinkers=tinkers
	for slotKey,button in pairs(frame.pages.character.slots) do
		FillSlot(button,gear[slotKey],tinkers[slotKey],slotKey)
	end

	-- Which of the three in each tier they took.
	local chosen={}
	for _,spellID in ipairs(data.t or {}) do chosen[spellID]=true end

	local grid=ns.TALENT_GRID and ns.TALENT_GRID[entry.class or ""]
	local page=frame.pages.talents
	local missing=0

	-- A tree block means a Burning Crusade build, whichever client is asking.
	local trees=data.d
	local onTrees=(type(trees)=="table" and #trees>0)

	for column=1,TALENT_COLUMNS do
		local tree=page.trees[column]
		tree.heading:SetShown(onTrees)
		for _,row in ipairs(tree.rows) do row:Hide() end
	end

	if onTrees then
		-- The grid describes nothing here, so it goes away entirely rather than
		-- sitting behind the trees with Mists talents in it.
		for tier=1,TALENT_TIERS do
			for column=1,TALENT_COLUMNS do page.cells[tier][column]:Hide() end
			if page.levels and page.levels[tier] then page.levels[tier]:Hide() end
		end

		local ranks=data.q or {}
		local taken=0   -- how far into the flat talent list we have read

		-- d={name,points,count, name,points,count, ...} -- the count is what
		-- splits the flat t={} list back into its trees. Deepest first, as
		-- written, so the spec reads off the top.
		for index=1,math.min(#trees/3,TALENT_COLUMNS) do
			local tree=page.trees[index]
			local name=trees[(index-1)*3+1]
			local points=trees[(index-1)*3+2] or 0
			local count=trees[(index-1)*3+3] or 0

			tree.heading:SetText(("%s |cffffd100%d|r"):format(tostring(name),points))

			for slot=1,count do
				local row=tree.rows[slot]
				local spellID=(data.t or {})[taken+slot]
				if row and spellID then
					row.spellID=spellID

					-- The name ships with the data: these are TBC rank spells and
					-- a Mists client, asked about them, answers nothing.
					local shipped=ns.TALENT_NAMES and ns.TALENT_NAMES[spellID]
					local fromClient,_,icon=GetSpellInfo(spellID)
					row.label:SetText(shipped or fromClient or ("spell "..spellID))
					row.icon:SetTexture(icon or "Interface/Icons/INV_Misc_QuestionMark")

					-- "3/5": the rank taken, and the ceiling harvested across every
					-- build read. Just the rank when the ceiling is not known yet.
					local rank=ranks[taken+slot]
					local talentID=ns.TALENT_OF_SPELL and ns.TALENT_OF_SPELL[spellID]
					local max=talentID and ns.TALENT_MAX_RANK and ns.TALENT_MAX_RANK[talentID]
					if rank and max then
						row.rank:SetText(("%d/%d"):format(rank,max))
					elseif rank then
						row.rank:SetText(tostring(rank))
					else
						row.rank:SetText("")
					end

					row:Show()
				end
			end

			taken=taken+count
		end

		-- Trees the character spent nothing in are omitted by the API, so any
		-- column left over is blanked rather than showing the last one twice.
		for index=math.floor(#trees/3)+1,TALENT_COLUMNS do
			page.trees[index].heading:SetText("")
		end
	end

	for tier=1,TALENT_TIERS do
		if not onTrees and page.levels and page.levels[tier] then
			page.levels[tier]:Show()
		end

		local row=(grid and grid[tier]) or {}
		for column=1,TALENT_COLUMNS do
			local cell=page.cells[tier][column]
			local spellID=row[column]

			cell.spellID=spellID
			if spellID then
				local name,_,icon=GetSpellInfo(spellID)
				cell.icon:SetTexture(icon or "Interface/Icons/INV_Misc_QuestionMark")
				cell.label:SetText(name or ("spell "..spellID))

				if chosen[spellID] then
					-- Taken: lit, and the row behind it picked out in gold the
					-- way the talent frame does it.
					cell.icon:SetDesaturated(false)
					cell.label:SetTextColor(1,0.82,0)
					cell.bg:SetColorTexture(1,0.82,0,0.16)
				else
					cell.icon:SetDesaturated(true)
					cell.label:SetTextColor(0.45,0.45,0.45)
					cell.bg:SetColorTexture(1,1,1,0.03)
				end
				cell:Show()
			else
				-- Nothing known for this cell: the grid is harvested from what
				-- players were seen taking, so a talent nobody on the ladder
				-- picked is not in it yet.
				missing=missing+1
				cell:Hide()
			end

			if onTrees then cell:Hide() end
		end
	end

	-- The gap count belongs to the Mists grid; there are no gaps in a tree
	-- list, which shows what was taken and nothing else.
	page.gaps:SetText((not onTrees) and missing>0 and L.INSPECT_TALENT_GAPS:format(missing) or "")

	local names={}

	-- A glyph of a class nobody has run /arena glyphs on has no type, and is
	-- drawn without one rather than guessed at: the grid gets three majors on
	-- the first line and three minors on the second exactly when it knows, and
	-- says nothing when it does not.
	local order=GlyphList(data.y)

	local glyphIDs,glyphKinds={},{}
	for index,row in ipairs(order) do
		names[index]=row.name
		glyphIDs[index]=row.id
		glyphKinds[index]=row.kind
	end
	-- The class's own major and minor glyph art. The major icon used to be
	-- drawn against all six, which said something untrue about half of them.
	local glyphArt=GLYPH_ICON_CLASS[entry.class or ""]
	local majorIcon=glyphArt and ("Interface/Icons/INV_Glyph_Major"..glyphArt)
	local minorIcon=glyphArt and ("Interface/Icons/INV_Glyph_Minor"..glyphArt)

	-- TBC has no glyphs, so the heading and its rows are hidden outright
	-- rather than left saying "None glyphed" -- which reads as a character
	-- who could have them and did not, when the expansion has none at all.
	local noGlyphs=(ns.ClientVersion and ns.ClientVersion())=="tbc"
	if page.glyphHeading then page.glyphHeading:SetShown(not noGlyphs) end

	for index,row in ipairs(page.glyphs) do
		if noGlyphs then row:Hide() end
		row.label:SetText(names[index] or "")

		-- Kept on the row, so the hover reads what is there now rather than
		-- what was there for the last character looked at.
		row.glyphName=names[index]
		row.glyphID=glyphIDs[index]
		row.glyphKind=glyphKinds[index]

		-- No icon at all for a glyph whose type nobody has recorded: an icon
		-- here is a claim about which half it belongs to.
		local kind=glyphKinds[index]
		local icon=(kind==1 and majorIcon) or (kind==2 and minorIcon) or nil

		if names[index] and icon then
			row.icon:SetTexture(icon)
			row.icon:Show()
		else
			row.icon:Hide()
		end
	end
	if #names==0 and not noGlyphs then page.glyphs[1].label:SetText(L.INSPECT_GLYPH_NONE) end

	-- Not on a Burning Crusade character.
	--
	-- These are inferred from the gear -- a tinker, a ring only an enchanter
	-- can wear -- against a table of MISTS professions and their art, which
	-- does not describe TBC. Rather than show a profession that is wrong, the
	-- row is left out; the gear it was read from is on screen either way.
	--
	-- Keyed on the character's own data, not the client, so a TBC character
	-- looked at from Mists is treated the same.
	local shown=0
	for _,key in ipairs((not onTrees) and (data.p or {}) or {}) do
		local icon=PROFESSION_ICONS[key]
		if icon then
			shown=shown+1
			local mark=frame.professions[shown]
			if mark then
				mark.icon:SetTexture(icon)
				mark.label=L["INSPECT_PROFESSION_"..key:upper()] or key
				mark:Show()
			end
		end
	end
	for index=shown+1,#frame.professions do frame.professions[index]:Hide() end

	FillPvP(entry,region)

	-- Always opens on the paper doll, whatever tab was left showing last time:
	-- the row that was clicked is a person, and the gear is what "look at them"
	-- means.
	-- Where it opens depends on what opened it, and this is the only place that
	-- decides. Against the auction house's panel when that panel is up -- the
	-- third in a row of three -- and a free window in the middle otherwise.
	--
	-- Only detaches if it was attached, so a window dragged somewhere while
	-- reading the ladder stays where it was put.
	local shelf=_G.ArenaPlus_AuctionPvP
	if shelf and shelf:IsShown() then
		if ns.InspectAttachToAuction then ns.InspectAttachToAuction() end
	elseif frame.attached and ns.InspectDetachFromAuction then
		ns.InspectDetachFromAuction()
	end

	ShowPage("character")
	frame:Show()

	FillSockets(gear,data.y,entry.class)
	FillStats(data.v)

	-- After Show, never before: see DressWhenReady.
	local look={ race=data.r or 0, gender=data.x or 0 }
	frame.pages.character.hint:SetText(L.INSPECT_HINT_OWN_RACE)
	DressWhenReady(gear,look)
end

-- Third in the row, against the auction house's PvP panel.
--
-- The chain is the auction house, then the list of top players, then the gems
-- belonging to whoever was clicked -- so this hangs off that middle panel
-- rather than off the house, and moves with it.
--
-- Anchored, not merely placed: the panel is itself anchored to the house, so
-- following it keeps all three lined up whatever the user's UI Scale is.
function ns.InspectAttachToAuction()
	local shelf=_G.ArenaPlus_AuctionPvP
	if not (frame and shelf) then return false end

	frame.attached=true
	frame:ClearAllPoints()
	-- The same eleven as everywhere else: our opaque layer starts that far in,
	-- so butting the frames together at zero leaves the width of two borders
	-- between them.
	frame:SetPoint("TOPLEFT",shelf,"TOPRIGHT",-11,0)
	return true
end

-- Follow the panel when it moves, but only if we were already following it.
--
-- Called when the auction house panel re-anchors itself. Without the guard this
-- would drag a window opened from the ladder across the screen the moment
-- somebody opened the auction house.
function ns.InspectReanchor()
	if frame and frame.attached then ns.InspectAttachToAuction() end
end

-- Back to being a window of its own.
function ns.InspectDetachFromAuction()
	if not frame then return end
	frame.attached=nil
	frame:ClearAllPoints()
	frame:SetPoint("CENTER")
end

-- Open on a particular tab.
--
-- The auction house shortcut wants the gems, not the paper doll: somebody who
-- came from there is shopping, not admiring the transmog.
function ns.InspectShowPage(which)
	if frame and frame:IsShown() then ShowPage(which) end
end

function ns.ToggleInspect(entry,region,bracket)
	-- Only the same person again closes it. Clicking a different row while the
	-- panel is open means "show me them instead", which closing and reopening
	-- would technically achieve and would look like a flicker.
	if frame and frame:IsShown() and frame.showing and frame.showing==WhoKey(entry,region) then
		frame:Hide()
		return
	end
	ns.ShowInspect(entry,region,bracket)
end

-- ---------------------------------------------------------------- glyphs

-- Which glyphs are major and which are minor.
--
-- Blizzard's profile does not say. A character's glyphs arrive as a name and a
-- glyph id, in no useful order -- a hunter came back as Stampede, Black Ice,
-- Cheetah, Animal Bond, Revive Pet, Solace, which is three of each shuffled
-- together -- and one name, Glyph of Stampede, exists as both a major and a
-- minor, so nothing can be keyed on the name either.
--
-- The client knows, for the class being played, and says so twice:
--
--   GetGlyphInfo(i)       name, type, known, icon, glyphID, link, spec
--   GetGlyphSocketInfo(s) enabled, type, group, spell, icon, glyphID
--
-- where type is 1 for major and 2 for minor, and a row whose first value is
-- "header" opens a section rather than describing a glyph. The list is the
-- better source of the two: it covers every glyph of the class, known or not,
-- while the sockets only cover the six a character has on.
--
-- Read positionally against that, having learned the hard way not to guess:
-- an earlier version took the first number it found as the id and recorded the
-- type instead, collapsing twelve rows into two entries numbered 1 and 2.
--
-- Only ever one class at a time, so this adds to what it already knows rather
-- than replacing it. Run it on a character of each class to fill the table in.
--
--   /arena glyphs
ns.SlashCommands["glyphs"]=function()
	if not (GetGlyphInfo and GetNumGlyphs) then
		ns.Print("This client will not list glyphs.")
		return
	end

	ArenaPlus_SavedVars=ArenaPlus_SavedVars or {}
	ArenaPlus_SavedVars.glyphTypes=ArenaPlus_SavedVars.glyphTypes or {}
	local store=ArenaPlus_SavedVars.glyphTypes

	local mine=select(2,UnitClass("player"))
	mine=mine and mine:lower() or "?"

	local total=GetNumGlyphs()
	local added,seen=0,0

	for index=1,total do
		local name,glyphType,_,_,glyphID=GetGlyphInfo(index)

		-- A header names the section below it and describes no glyph.
		if name~="header" and type(glyphID)=="number" and glyphID>0
			and (glyphType==1 or glyphType==2) then

			seen=seen+1
			if store[glyphID]==nil then added=added+1 end
			store[glyphID]=glyphType
		end
	end

	local known=0
	for _ in pairs(store) do known=known+1 end

	ns.Print("%s: %d of %d rows carried a glyph, %d new. %d known in all.",
		mine,seen,total,added,known)
	ns.Print("  /reload to write it to disk. Run it on one character of each class.")
end

-- ---------------------------------------------------------------- talents

-- Does this client know the talent layout of classes other than yours?
--
-- The grid the panel draws is currently inferred: a solver reads thousands of
-- players' builds and works out which talents cannot share a tier. It is
-- guesswork, and it shows -- coverage moves between 184 and 189 of 198 from one
-- run to the next, and monk, which has the fewest builds to learn from, put the
-- same talent in two different tiers on consecutive runs.
--
-- The game itself holds the real table. The only question is whether it will
-- tell an addon about classes the player is not. GetTalentInfoByID takes a
-- talent id rather than a class, so it may answer for all of them.
--
-- What it cannot tell us is which class a talent belongs to -- that is not in
-- the return. It does not need to: the spell ids we already collect from real
-- players carry the class with them, so the client supplies the half that is
-- hard to infer (which tier) and the data we have supplies the half that is
-- easy (which class).
--
-- Where to look.
--
-- The first attempt walked ids 1 to 400 and found nothing, because talent ids
-- in this expansion are nothing like that: the API hands back 16011 for
-- Presence of Mind, 16019 for Ring of Frost, 19300 for Living Bomb. So the
-- sweep covers the range those actually live in, with room either side.
local PROBE_FROM, PROBE_TO = 15000, 20500

ns.SlashCommands["talents"]=function(argument)
	if not GetTalentInfoByID then
		ns.Print("This client has no GetTalentInfoByID.")
		return
	end

	-- A range can be given, since the right one was a guess: /arena talents 1 30000
	-- Both captures, which an `and` would throw the second of away: the range
	-- was read as its first number and the second silently ignored.
	local from,to
	if argument then from,to=argument:match("^%s*(%d+)%s+(%d+)") end
	from=tonumber(from) or PROBE_FROM
	to=tonumber(to) or PROBE_TO

	local mine=select(2,UnitClass("player"))
	mine=mine and mine:lower() or "?"

	-- Written to saved variables rather than to chat. Two hundred lines in a
	-- chat frame is a scrollback problem; on disk it is a table we can read.
	ArenaPlus_SavedVars=ArenaPlus_SavedVars or {}
	local found={}

	local rows=0
	local lowest,highest

	for id=from,to do
		-- Returns: id, name, texture, selected, available, spellID, unknown,
		-- row, column, known, grantedByAura.
		local ok,_,name,_,_,_,spellID,_,row,column=pcall(GetTalentInfoByID,id,1)

		if ok and name and row and column and spellID then
			rows=rows+1
			lowest=lowest or id
			highest=id
			found[#found+1]={id=id,tier=row,column=column,spell=spellID,name=name}
		end
	end

	ArenaPlus_SavedVars.talentProbe={
		client=(GetBuildInfo and select(1,GetBuildInfo())) or "?",
		asked=(to-from+1),
		answered=rows,
		playerClass=mine,
		rows=found,
	}

	ns.Print("GetTalentInfoByID answered for %d of %d ids in %d-%d (%s to %s). You are a %s.",
		rows,(to-from+1),from,to,tostring(lowest),tostring(highest),mine)

	if rows==0 then
		ns.Print("  Nothing came back, so the table has to come from elsewhere.")
		return
	end

	-- 198 is the whole game: eleven classes, six tiers, three talents each.
	-- Eighteen is one class and nobody else's.
	if rows>=150 then
		ns.Print("  That is most of the game, so it knows every class.")
	elseif rows<=24 then
		ns.Print("  That is about one class's worth, so it only knows yours.")
	else
		ns.Print("  Somewhere in between -- worth looking at what came back.")
	end

	for index=1,math.min(rows,3) do
		local it=found[index]
		ns.Print("    id %d  tier %d col %d  spell %d  %s",it.id,it.tier,it.column,it.spell,it.name)
	end

	ns.Print("  Saved. Log out or /reload to write it to disk, then tell me.")
end

-- ---------------------------------------------------------------- probe

-- What the set line did on the last slot hovered.
--
--   hover a set piece, then: /arena settip
ns.SlashCommands["settip"]=function()
	if not setProbe then
		ns.Print("Nothing hovered yet. Open somebody's gear, hover a set piece, then run this.")
		return
	end

	local p=setProbe
	ns.Print("item %s   cached: %s", tostring(p.itemID), p.cached and "yes" or "NO")
	ns.Print("  set %s (%s)   our count: %s/%s",
		tostring(p.setID), tostring(p.name), tostring(p.worn), tostring(p.total))

	if not p.worn then
		ns.Print("  |cffff4040no count on file for that set|r -- so nothing was corrected.")
	elseif p.matched then
		ns.Print("  matched line %d of %d", p.matched, p.lines)
		ns.Print("    was:   %s", tostring(p.before))
		ns.Print("    wrote: %s", tostring(p.wrote))
	else
		ns.Print("  |cffff4040no line matched (n/n)|r in %d lines -- a line was appended instead.", p.lines)
	end

	if p.later then
		ns.Print("  0.35s later: tooltip shown %s, %d lines", tostring(p.laterShown), p.laterLines or 0)
		if #p.later==0 then
			ns.Print("    no (n/n) line at all any more.")
		end
		for _,text in ipairs(p.later) do ns.Print("    %s", text) end
	else
		ns.Print("  no later sample -- the tooltip closed before it ran.")
	end
end
