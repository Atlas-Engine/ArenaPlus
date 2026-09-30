local ADDON_NAME, ns = ...
local L = ns.L

-- A mark for ReplayPlus: a strip of seven 4x4-pixel cells in the top-left
-- corner of the screen while you are in an arena, and for half a minute after
-- you leave one. ReplayPlus reads it off the game's window to start recording
-- as the arena begins and stop as it ends -- live, which the combat log cannot
-- be: the game writes it in 48 KiB blocks, so an arena's entry reached the
-- file a minute or more late and its end not until the next block, often the
-- next arena's (measured 2026-09-30).
--
-- Each cell is one of eight colours, red, green and blue each fully on or off,
-- read as a number red 4 + green 2 + blue 1:
--
--   magenta | phase | map | bracket | sequence | check | green
--
--   phase     1 prep, 2 fighting (the gates seen), 3 fighting (the gates
--             inferred), 4 ended in a win, 5 in a loss, 6 ended with no winner
--             known, 7 out of the arena
--   map       the arena, an index into MAPS; 0 unknown
--   bracket   1-3 rated 2v2/3v3/5v5, 5-7 skirmish; 0 unknown
--   sequence  counts on every tick, so ReplayPlus can tell a frozen picture
--   check     7 - (phase ^ map ^ bracket ^ sequence)
--
-- Nothing else is ever drawn: no combat, no names. The frame has no parent, so
-- Alt+Z (which hides UIParent) leaves it, and it is scaled so one unit is one
-- physical pixel. Only frames and textures of its own: nothing protected, no
-- taint. Off by default: it draws on everybody's screen.
local module = ns.RegisterModule("replaysignal",{
	title       = L.REPLAYSIGNAL_TITLE,
	enableLabel = L.REPLAYSIGNAL_ENABLE,
	desc        = L.REPLAYSIGNAL_DESC,
	group       = "arena",
	defaults    = { enabled=false },
})

local CELL, CELLS = 4, 7
local MAGENTA, GREEN = 5, 2
local OUT_FOR = 30

-- The map cell's values: the arenas' instance ids, in ReplayPlus's order.
local MAPS = { [559]=1, [562]=2, [572]=3, [617]=4, [618]=5, [980]=6, [1134]=7 }

-- "The Arena battle has begun!", in English: the gates exactly. Other
-- clients' words are not known here, and there the gates are inferred -- the
-- first blow between the teams, or the minute in the starting room run out --
-- which only makes the site's times less exact, never the recording.
local BEGUN = {
	["The Arena battle has begun!"] = true,
}

local frame, cells
local tick = 0
local instance, gatesSeen, gatesInferred, wasInArena = nil, false, false, false
local leftAt = nil
local testUntil, testStart = nil, 0

local function InArena()
	if IsActiveBattlefieldArena and IsActiveBattlefieldArena() then return true end
	local _,kind=IsInInstance()
	return kind=="arena"
end

local function Build()
	if frame then return end
	frame=CreateFrame("Frame","ArenaPlusSignal")
	frame:SetFrameStrata("TOOLTIP")
	frame:SetFrameLevel(9000)
	frame:EnableMouse(false)
	cells={}
	for i=1,CELLS do
		local t=frame:CreateTexture(nil,"OVERLAY")
		t:SetBlendMode("DISABLE")
		if t.SetSnapToPixelGrid then t:SetSnapToPixelGrid(false) end
		if t.SetTexelSnappingBias then t:SetTexelSnappingBias(0) end
		t:SetSize(CELL,CELL)
		t:SetPoint("TOPLEFT",frame,"TOPLEFT",(i-1)*CELL,0)
		cells[i]=t
	end
	frame:Hide()
end

-- One unit one physical pixel: the screen is 768 units tall at scale 1, and a
-- frame with no parent is not touched by the UI scale.
local function Fit()
	if not frame then return end
	local _,height=GetPhysicalScreenSize()
	if not height or height<=0 then height=768 end
	frame:SetScale(768/height)
	frame:SetSize(CELL*CELLS,CELL)
	frame:ClearAllPoints()
	frame:SetPoint("TOPLEFT",WorldFrame,"TOPLEFT",0,0)
end

local function Colour(t,v)
	t:SetColorTexture(math.floor(v/4)%2,math.floor(v/2)%2,v%2,1)
end

local function Draw(phase,map,bracket)
	Build()
	local seq=tick%8
	local check=7-bit.bxor(bit.bxor(phase,map),bit.bxor(bracket,seq))
	local values={MAGENTA,phase,map,bracket,seq,check,GREEN}
	for i=1,CELLS do Colour(cells[i],values[i]) end
	if not frame:IsShown() then Fit() frame:Show() end
end

local function HideMark()
	if frame then frame:Hide() end
end

-- The arena's bracket from the battlefield entry that is active: its team
-- size, and whether it is rated.
local function Bracket()
	if not (GetMaxBattlefieldID and GetBattlefieldStatus) then return 0 end
	for index=1,(GetMaxBattlefieldID() or 0) do
		local ok,status,_,teamSize,rated=pcall(GetBattlefieldStatus,index)
		if ok and status=="active" then
			local size=({[2]=1,[3]=2,[5]=3})[teamSize or 0]
			if size then return rated and size or size+4 end
		end
	end
	return 0
end

local function Phase()
	local winner=GetBattlefieldWinner and GetBattlefieldWinner()
	if winner~=nil then
		local faction=GetBattlefieldArenaFaction and GetBattlefieldArenaFaction()
		if faction==nil or (winner~=0 and winner~=1) then return 6 end
		return winner==faction and 4 or 5
	end
	if gatesSeen then return 2 end
	local running=GetBattlefieldInstanceRunTime and GetBattlefieldInstanceRunTime() or 0
	if gatesInferred or running>=62000 then return 3 end
	return 1
end

local watcher=CreateFrame("Frame")

local function Update()
	tick=tick+1
	-- The test: phase 7, out of the arena, which ReplayPlus never records,
	-- with every map and bracket value in turn so each cell shows all eight
	-- colours. Ended by entering an arena.
	if testUntil then
		if GetTime()<testUntil and not InArena() then
			local step=math.floor((GetTime()-testStart)/2)
			Draw(7,step%8,(step+3)%8)
			return
		end
		testUntil=nil
	end
	if not (module.db and module.db.enabled) then
		-- Put away as if never in an arena: switched on again inside one, it
		-- is a new arena whose gates were not seen.
		watcher:UnregisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
		wasInArena=false
		instance,leftAt=nil,nil
		HideMark()
		return
	end
	if InArena() then
		local id=select(8,GetInstanceInfo())
		-- A new arena: entered from outside one. A /reload inside starts this
		-- file afresh, and the minute run out tells it the fight is on.
		if not wasInArena then
			instance=id
			gatesSeen,gatesInferred=false,false
		end
		wasInArena=true
		leftAt=nil
		local phase=Phase()
		if phase==1 then watcher:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED") else watcher:UnregisterEvent("COMBAT_LOG_EVENT_UNFILTERED") end
		Draw(phase,MAPS[id or 0] or 0,Bracket())
		return
	end
	watcher:UnregisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
	wasInArena=false
	if instance and leftAt and GetTime()-leftAt<OUT_FOR then
		Draw(7,0,0)
		return
	end
	instance=nil
	HideMark()
end

local HOSTILE=COMBATLOG_OBJECT_REACTION_HOSTILE or 0x40
local PLAYER=COMBATLOG_OBJECT_TYPE_PLAYER or 0x400

watcher:RegisterEvent("PLAYER_ENTERING_WORLD")
watcher:RegisterEvent("PLAYER_LEAVING_WORLD")
watcher:RegisterEvent("CHAT_MSG_BG_SYSTEM_NEUTRAL")
watcher:RegisterEvent("DISPLAY_SIZE_CHANGED")
watcher:RegisterEvent("UI_SCALE_CHANGED")
watcher:SetScript("OnEvent",function(_,event,message)
	if event=="PLAYER_LEAVING_WORLD" then
		-- The loading screen out: the last frame in the arena is this one.
		if InArena() then leftAt=GetTime() end
		HideMark()
	elseif event=="PLAYER_ENTERING_WORLD" then
		if not InArena() and instance then leftAt=leftAt or GetTime() end
		Fit()
		Update()
	elseif event=="CHAT_MSG_BG_SYSTEM_NEUTRAL" then
		if type(message)=="string" and InArena() then
			if BEGUN[message] then gatesSeen=true end
		end
	elseif event=="COMBAT_LOG_EVENT_UNFILTERED" then
		-- In the starting room only: the first blow between a player and a
		-- hostile player is the gates, when their words were not recognised.
		local _,sub,_,_,_,srcFlags,_,_,_,dstFlags=CombatLogGetCurrentEventInfo()
		if sub=="SWING_DAMAGE" or sub=="SPELL_DAMAGE" or sub=="RANGE_DAMAGE" then
			local hostileSrc=bit.band(srcFlags or 0,HOSTILE)~=0 and bit.band(srcFlags or 0,PLAYER)~=0
			local hostileDst=bit.band(dstFlags or 0,HOSTILE)~=0 and bit.band(dstFlags or 0,PLAYER)~=0
			if hostileSrc~=hostileDst then gatesInferred=true end
		end
	else
		Fit()
	end
end)

local ticker
function module:OnEnable()
	Build()
	Fit()
	if not ticker then ticker=C_Timer.NewTicker(0.25,Update) end
end

function module:OnToggle(enabled)
	if enabled and not ticker then self:OnEnable() end
	Update()
end

-- What it would draw now, since none of it is words.
--
--   /arena signal        the phase, map, bracket, winner and the pixel scale
--   /arena signal test   every map and bracket value in turn for 16 seconds,
--                        as if just out of an arena, for ReplayPlus's reader
--                        to be checked against without recording anything;
--                        refused in an arena, where it would end the recording
ns.SlashCommands["signal"]=function(arg)
	if type(arg)=="string" and arg:lower():match("^%s*test%s*$") then
		if InArena() then ns.Print(L.REPLAYSIGNAL_TEST_ARENA) return end
		Build()
		Fit()
		if not ticker then ticker=C_Timer.NewTicker(0.25,Update) end
		testStart=GetTime()
		testUntil=testStart+16
		ns.Print(L.REPLAYSIGNAL_TESTING)
		return
	end
	local _,height=GetPhysicalScreenSize()
	local id=select(8,GetInstanceInfo())
	ns.Print(L.REPLAYSIGNAL_STATUS:format(
		module.db and module.db.enabled and "yes" or "no",
		InArena() and tostring(Phase()) or "-",
		tostring(id or "-"),
		tostring(Bracket()),
		tostring(GetBattlefieldWinner and GetBattlefieldWinner() or "-"),
		tostring(GetBattlefieldArenaFaction and GetBattlefieldArenaFaction() or "-"),
		height and string.format("%.4f",768/height) or "-"))
end
