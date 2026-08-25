local ADDON_NAME, ns = ...
local L = ns.L

-- Rated PvP on the tooltip of any player you point at.
--
-- The one place this data reaches that no window does: a name in the open
-- world, or an opponent in an arena, without typing anything anywhere.
--
-- Most hovers show nothing, and that is correct. The ladder stops at the Rival
-- cutoff, so the majority of players are simply not in it -- and a section that
-- only ever says "no data" is worse than no section.
local module = ns.RegisterModule("unittip",{
	title       = L.UNITTIP_TITLE,
	enableLabel = L.UNITTIP_ENABLE,
	desc        = L.UNITTIP_DESC,
	group       = "arena",
	-- Which brackets a tooltip lists.
	--
	-- Rated battlegrounds off to begin with: it is the bracket fewest people
	-- play, so for most players it would be a line that never appears, and for
	-- the rest it is one more line on a tooltip that already has three.
	defaults    = { enabled=true, brackets={ [1]=true,[2]=true,[3]=true } },
})

local BRACKETS = ns.BRACKET_NAMES

----------------------------------------------------------------
-- What to say about a name
----------------------------------------------------------------

-- Their own region is the only one that can apply: these are people you are
-- standing next to.
local function Lines(full)
	if not (full and full~="" and ns.LadderEntry) then return nil end

	local wanted=module.db.brackets or {}

	local out
	for bracket=1,4 do
		local entry=wanted[bracket] and ns.LadderEntry(bracket,full)
		if entry then
			out=out or {}
			out[#out+1]={ bracket=bracket, entry=entry }
		end
	end

	return out
end

local function Describe(unit)
	if not (unit and UnitIsPlayer and UnitIsPlayer(unit)) then return nil end

	-- Cross-realm units answer with a realm, same-realm ones with nothing --
	-- and the lookup wants the realm attached wherever it exists, since a bare
	-- name only answers while it is unambiguous on that ladder.
	local name,realm=UnitName(unit)
	if not (name and name~="") then return nil end

	-- No realm means your realm. UnitName only names one for a character from
	-- somewhere else, so an empty answer is information rather than a gap --
	-- and naming it outright beats falling back to the bare-name index, which
	-- deliberately refuses to answer when two realms share a name.
	if not (realm and realm~="") then
		realm=GetRealmName and GetRealmName() or nil
	end

	local full=name
	if realm and realm~="" then full=name.."-"..realm end

	return Lines(full)
end

----------------------------------------------------------------
-- Drawing it
----------------------------------------------------------------

-- Counted so the diagnostic can tell "never called" from "called and found
-- nothing" -- two failures that look identical on screen.
local calls,hits,how=0,0,"not hooked"

-- Both hooks are registered, so the same rebuild can arrive twice. GetTime is
-- fixed for the whole frame, so "same unit, same frame" is exactly the repeat
-- worth dropping -- while a genuine redraw on a later frame still gets its
-- lines, because the tooltip was cleared in between.
local lastGUID,lastAt

local function Append(tooltip)
	calls=calls+1
	if not module.db.enabled then return end
	if not (tooltip and tooltip.GetUnit and tooltip.AddLine) then return end

	local _,unit=tooltip:GetUnit()
	if not unit then return end

	local guid=UnitGUID and UnitGUID(unit)
	local now=GetTime and GetTime() or 0
	if guid and guid==lastGUID and now==lastAt then return end
	lastGUID,lastAt=guid,now

	local found=Describe(unit)
	if not found then return end
	hits=hits+1

	tooltip:AddLine(" ")
	tooltip:AddLine(L.UNITTIP_HEADER,1,0.82,0)

	for _,row in ipairs(found) do
		-- The same tier colour the ladder and the cutoffs box use, so a rating
		-- means the same thing wherever it is read.
		local hex=(ns.RankHex and ns.RankHex(row.bracket,row.entry)) or "ffffff"

		tooltip:AddLine(L.UNITTIP_LINE:format(
			BRACKETS[row.bracket] or "?",hex,row.entry.rating or 0,row.entry.rank or 0),
			0.8,0.8,0.8)
	end

	tooltip:Show()
end

-- Four small ticks under this tweak's own, in the settings window.
--
-- The window was rebuilt on the promise of one tick per tweak and no
-- sub-options, and this is the exception -- knowingly. It was removed before
-- because *every* tweak had a page and none of them earned it; one tweak with
-- four ticks is a different thing from that. If a second one wants sub-options,
-- that is the moment to think again rather than to add a third.
--
-- Returns the height it used, so the row after it knows where to sit.
function module:BuildExtra(frame,anchor)
	local names=ns.BRACKET_NAMES
	local previous,used=nil,0

	for bracket=1,4 do
		local check=CreateFrame("CheckButton",nil,frame,"UICheckButtonTemplate")
		check:SetSize(20,20)
		check.bracket=bracket

		if previous then
			check:SetPoint("LEFT",previous,"RIGHT",34,0)
		else
			check:SetPoint("TOPLEFT",anchor,"BOTTOMLEFT",22,-2)
			used=24
		end

		local label=check:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
		label:SetPoint("LEFT",check,"RIGHT",2,0)
		label:SetText(names[bracket])

		check:SetChecked(module.db.brackets and module.db.brackets[bracket])
		check:SetScript("OnClick",function(self)
			module.db.brackets=module.db.brackets or {}
			module.db.brackets[self.bracket]=self:GetChecked() and true or nil
		end)

		previous=check
	end

	return used
end

function module:OnEnable()
	-- Two ways to hang something off a unit tooltip, and which one exists
	-- depends on the build. The newer path is tried first because on a client
	-- that has it, the old script hook is never called for unit data.
	-- Both, not one or the other.
	--
	-- This client answers yes to TooltipDataProcessor and gives
	-- Enum.TooltipDataType.Unit as 2, so registering there looks like success --
	-- and the callback then never fires once, because unit tooltips here still
	-- go through the old script path. Measured, not assumed: the probe below
	-- reported "hooked via TooltipDataProcessor" beside "called 0 times".
	--
	-- Picking one and trusting the API to be present-means-used is what cost
	-- the first attempt. Registering both costs a duplicate, and a duplicate is
	-- cheap to drop.
	local hooks={}

	if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall
		and Enum and Enum.TooltipDataType and Enum.TooltipDataType.Unit then
		TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit,Append)
		hooks[#hooks+1]="TooltipDataProcessor"
	end

	if GameTooltip and GameTooltip.HookScript then
		GameTooltip:HookScript("OnTooltipSetUnit",Append)
		hooks[#hooks+1]="OnTooltipSetUnit"
	end

	how=(#hooks>0) and table.concat(hooks," + ") or "not hooked"
end

-- Which way it hooked, whether that hook ever fires, and what a name resolves
-- to. Three failures look identical on screen -- never hooked, hooked but never
-- called, called but found nobody -- and only the last is about the data.
--
--   hover a player, then: /arena tip Cmw
ns.SlashCommands["tip"]=function(argument)
	ns.Print("hooked via: %s",how)
	ns.Print("TooltipDataProcessor: %s   AddTooltipPostCall: %s   Enum.TooltipDataType.Unit: %s",
		TooltipDataProcessor and "yes" or "no",
		(TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall) and "yes" or "no",
		tostring(Enum and Enum.TooltipDataType and Enum.TooltipDataType.Unit))
	ns.Print("called %d time(s), of which %d found somebody.",calls,hits)

	local name=(argument or ""):match("^%s*(.-)%s*$")
	if name=="" then return end

	local realm=GetRealmName and GetRealmName() or "?"
	ns.Print("looking up %s (assuming realm %s):",name,realm)

	for _,full in ipairs({ name, name.."-"..realm }) do
		local said=false
		for bracket=1,4 do
			local entry=ns.LadderEntry and ns.LadderEntry(bracket,full)
			if entry then
				said=true
				ns.Print("  \"%s\" %s: #%d rating %d",full,BRACKETS[bracket],entry.rank or 0,entry.rating or 0)
			end
		end
		if not said then ns.Print("  \"%s\": nothing",full) end
	end
end
