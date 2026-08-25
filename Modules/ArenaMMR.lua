local ADDON_NAME, ns = ...
local L = ns.L

-- What each arena did to your rating, said once, when the numbers settle.
--
-- This used to estimate MMR as well, and that is deleted rather than disabled
-- -- about 490 lines of it. The arithmetic was sound and the premise was not.
-- It read the expectancy out of the ratio of a win to a loss:
--
--     expected = 1 / (1 + 10 ^ ((mmr - rating) / 400))
--
-- which treats every rating change as driven by the gap between your rating
-- and your own MMR. That only holds while the matchmaker pairs you against
-- teams at your MMR, and there is no way to see the enemy team to check: their
-- MMR is not on the scoreboard, GetBattlefieldTeamInfo returns 0, and C_PvP has
-- no MMR field at all. So whenever a thin queue paired you off -- normal at
-- high rating on this realm pool -- the estimate quietly absorbed the
-- opponents' strength as if it were your own gap, and nothing in it could tell
-- that had happened. Blizzard's own "Matchmaking Value" line reads 0 and
-- ArenaAnalytics prints "-"; neither is being coy.
--
-- What is left is measurement rather than inference: the rating, what the match
-- paid, your ladder rank, your season record, how long it took. Every one of
-- those is a number the client actually hands over.
--
-- Nothing here watches for the end of a match. Arena end detection needs the
-- player to still be standing in the arena when the winner is announced, which
-- an early /afk out, a disconnect or a quick Leave all break. Instead the
-- rating and the games played count are watched per bracket: when they move
-- and then settle, that is a match, whoever was watching. It also means the
-- result still arrives if the server takes its time, since the trigger is the
-- number changing rather than a moment in the match.
local module = ns.RegisterModule("mmr",{
	title       = L.MMR_TITLE,
	enableLabel = L.MMR_ENABLE,
	desc        = L.MMR_DESC,
	group       = "arena",
	-- Sits on the history's page: the two describe the same matches, one as
	-- they finish and one as a list afterwards.
	parent      = "history",
	defaults    = { enabled=true },
})

-- What an even match pays at each rating, measured over the recorded matches:
-- Watching: ask the server for rated info every few seconds for a while after
-- anything that might have changed it, and treat the numbers as final once
-- they have stopped moving for SETTLE seconds. Rating and games played do not
-- always update in the same message.
local REQUEST_INTERVAL = 3
local WATCH_SECONDS    = 180
local SETTLE           = 4

-- Only an arena gets talked about. A rating that turns out to have moved for
-- any other reason -- logging in on a character last played weeks ago, or on
-- another account with its own saved variables -- is filed quietly instead, so
-- the next real match still measures correctly.
local ARENA_WINDOW = 300

-- Placements do not change the arithmetic, but the swings are wilder while
-- they run, so they are worth a word when they are still going.
local PLACEMENT_GAMES = 10

local BRACKET_NAME = { [1]="2v2", [2]="3v3", [3]="5v5" }

-- Bumping this throws away everything gathered under the old shape.
local DATA_VERSION = 3

-- Tier colours come from the core, so this and the rated page agree.
local ticker
local watchUntil=0
local settleAt
local lastSignature
local lastArenaAt

----------------------------------------------------------------
-- Reading
----------------------------------------------------------------

local function InArena()
	if not (IsActiveBattlefieldArena and IsActiveBattlefieldArena()) then return false end
	if C_PvP and C_PvP.IsInBrawl and C_PvP.IsInBrawl() then return false end
	return true
end

-- Remembered rather than asked at reporting time: the rating often lands after
-- the arena has been left, which is exactly the case this has to allow for,
-- and the group may well have broken up by then.
local function NoteArena()
	if not InArena() then return end
	lastArenaAt=GetTime()
end

local function ArenaRecently()
	return lastArenaAt~=nil and (GetTime()-lastArenaAt)<=ARENA_WINDOW
end

-- Rating, and the number of games played this season in that bracket.
local function RatedInfo(bracket)
	if not (bracket and GetPersonalRatedInfo) then return nil end
	local rating,_,_,played=GetPersonalRatedInfo(bracket)
	return tonumber(rating),tonumber(played)
end

-- Ladder position. The eleventh return of GetPersonalRatedInfo, which the
-- generated API docs call "ranking" -- confirmed against ArenaRanks showing
-- the same 5685 and 371 for the same character's two brackets.
local function Ranking(bracket)
	if not (bracket and GetPersonalRatedInfo) then return nil end
	-- Assigned before converting: select returns everything from the eleventh
	-- value on, and tonumber would take the twelfth as a number base.
	local ranking=select(11,GetPersonalRatedInfo(bracket))
	ranking=tonumber(ranking)

	if not ranking or ranking<=0 then return nil end
	return ranking
end

-- The season record, straight from the server. Shown, never fed to the
-- estimate: a win rate says where your skill sits against your opponents,
-- which is a different question from where your rating sits, and the two only
-- agree once the rating has caught up.
local function SeasonRecord(bracket)
	if not (bracket and GetPersonalRatedInfo) then return nil end

	local _,_,_,played,won=GetPersonalRatedInfo(bracket)
	played,won=tonumber(played),tonumber(won)
	if not played or not won or played<=0 then return nil end

	return won,math.max(0,played-won)
end

-- Ratings, results and marks all belong to one character: two characters
-- sharing them would measure each other's matches and average each other's
-- points. The on/off setting stays account wide, since that is a preference
-- rather than data.
local function Store()
	module.db.chars=module.db.chars or {}
	ns.MigrateCharStore(module.db.chars)

	local key=ns.CharKey()
	local store=module.db.chars[key] or {}
	module.db.chars[key]=store

	-- Left behind by the MMR estimate: up to twenty past results per bracket,
	-- per character, read by nothing now. Dropped here rather than by bumping
	-- DATA_VERSION, because that also clears `seen`, which the alt list needs
	-- and which cannot be rebuilt for a character that is not logged in.
	store.results=nil

	-- Who this character is, stamped every time the store is opened.
	--
	-- Cheap, and it means the alt list can draw a character the ladder has
	-- never heard of. An alt at 576 is a thousand points below where the
	-- leaderboard starts, so its class, race and realm are knowable only from
	-- the character itself -- and only while it is the one logged in.
	local class,classFile=UnitClass("player")
	store.who={
		class  = classFile and classFile:lower():gsub("%s",""),
		race   = select(3,UnitRace("player")),
		gender = (UnitSex("player")==3) and 1 or 0,
		spec   = GetSpecialization and GetSpecializationInfo and
		         (function()
		         	local index=GetSpecialization()
		         	return index and GetSpecializationInfo(index) or nil
		         end)() or nil,
		realm  = GetNormalizedRealmName and GetNormalizedRealmName() or nil,
	}

	return store
end

-- What was last accounted for, per bracket, kept across sessions.
local function Seen(bracket)
	local store=Store()
	store.seen=store.seen or {}
	return store.seen[bracket]
end

-- Every character of yours with a rating in this bracket, best first.
--
-- Read out of the same per-character store the estimate uses, which is saved
-- account-wide: each character records its rating and games played per bracket
-- as it logs in, so they are all known without asking Blizzard anything.
--
-- The ladder file cannot answer this on its own. It stops at the challenger
-- cutoff, so an alt sitting at 1400 is not in it -- and "not on the ladder" is
-- a different thing from "has never played the bracket", which is the
-- distinction this has to keep.
function ns.MyAlts(bracket)
	if not (module.db and module.db.chars) then return {} end

	local out={}
	for key,store in pairs(module.db.chars) do
		local seen=store.seen and store.seen[bracket]
		local rating=seen and tonumber(seen.rating) or 0

		if rating>0 then
			-- Split at the FIRST hyphen and keep the rest whole: a realm can
			-- have one of its own, which is how Ra-den turns into "Ra".
			local name,realm=key:match("^([^%-]+)%-(.+)$")
			out[#out+1]={
				name   = name or key,
				-- The slug form when the character recorded one, so it matches
				-- the ladder's spelling: the game says "Ra-den" where the
				-- leaderboard says "raden".
				realm  = (store.who and store.who.realm) or realm,
				rating = rating,
				played = seen and tonumber(seen.played) or 0,
				who    = store.who,
			}
		end
	end

	table.sort(out,function(a,b)
		if a.rating~=b.rating then return a.rating>b.rating end
		return (a.name or "")<(b.name or "")
	end)

	return out
end

local function SetSeen(bracket,rating,played)
	local store=Store()
	store.seen=store.seen or {}
	store.seen[bracket]={ rating=rating, played=played }
end

----------------------------------------------------------------
-- Saying it
----------------------------------------------------------------

local function Say(fmt,...)
	ns.Print((select("#",...)>0) and fmt:format(...) or fmt)
end

----------------------------------------------------------------
-- Accounting for what moved
----------------------------------------------------------------

local function Pending(bracket)
	local rating,played=RatedInfo(bracket)
	if not (rating and played) then return false end

	local seen=Seen(bracket)
	if not seen then
		-- First sight of this bracket: nothing to compare against, so this
		-- becomes the mark everything after is measured from.
		SetSeen(bracket,rating,played)
		return false
	end

	return played~=seen.played or rating~=seen.rating
end

local function ReportBracket(bracket)
	local rating,played=RatedInfo(bracket)
	local seen=Seen(bracket)
	if not (rating and played and seen) then return end

	local games=played-seen.played
	local delta=rating-seen.rating
	SetSeen(bracket,rating,played)

	if games<=0 and delta==0 then return end

	local name=BRACKET_NAME[bracket] or "?"
	-- More than one game at a time means a stretch played with this switched
	-- off, or on another machine. The rating change is still worth saying, but
	-- it cannot be pinned on a single match, and the line says so.
	local change=(games>1) and L.MMR_CHANGE_MULTI:format(delta,games) or ("%+d"):format(delta)
	-- Finished matches, worked out once. Anything else that wants to know --
	-- the history list -- hears about it here rather than measuring its own.
	--
	-- Announced whenever anything was played, not only for a clean single
	-- game. This used to fire on games==1 alone, which meant two games arriving
	-- together said nothing at all: the match went unrecorded *and* the history
	-- never learned to let go of the players it was gathering, so the next
	-- arena added to the same pile and produced a 2v2 with four opponents.
	--
	-- The count goes with it, so a listener can tell a match it can attribute
	-- from a stretch it cannot.
	if games>=1 then
		ns.Fire("ARENA_RESULT",{
			bracket = bracket,
			rating  = rating,
			delta   = delta,
			won     = delta>0,
			games   = games,
		})
	end

	-- Coloured by ladder tier, so the number means the same here as everywhere
	-- else in the addon.
	local shownRating=ns.ColouredRating(bracket,rating)

	if delta==0 then
		-- A rated match that moved nothing at all. Worth a word, because it
		-- looks like a bug otherwise.
		Say(L.MMR_MSG_NOCHANGE,name,shownRating)
	else
		Say(L.MMR_MSG_RESULT,name,shownRating,change)
	end

	-- The shared line carries pieces from other tweaks too, so it says which
	-- bracket the numbers on it belong to. The chat line says so already.
	ns.ScoreboardSay("bracket",L.MMR_BOARD_BRACKET:format(name),-1)

	-- Ladder position and season record, gathered onto one line under the
	-- result rather than a line each.
	local details={}

	local ranking=Ranking(bracket)
	if ranking then
		details[#details+1]=L.MMR_DETAIL_RANK:format(ns.TierHex(bracket,rating),ranking)
		ns.ScoreboardSay("rank",L.MMR_BOARD_RANK:format(ns.TierHex(bracket,rating),ranking),0)
	end

	local wins,losses=SeasonRecord(bracket)
	if wins then
		details[#details+1]=L.MMR_DETAIL_SEASON:format(wins,losses)
		ns.ScoreboardSay("season",L.MMR_BOARD_SEASON:format(wins,losses),2)
	end

	if #details>0 then
		ns.Print("  "..table.concat(details,", ")..".")
	end

	-- The swings are wilder while the placements run, which is worth saying
	-- rather than leaving the numbers to look erratic.
	if played<=PLACEMENT_GAMES then
		ns.Print(L.MMR_MSG_PLACEMENT,played,PLACEMENT_GAMES)
	end
end

----------------------------------------------------------------
-- Watching for it
----------------------------------------------------------------

local function Signature()
	local parts={}
	for bracket=1,3 do
		local rating,played=RatedInfo(bracket)
		parts[#parts+1]=tostring(rating).."/"..tostring(played)
	end
	return table.concat(parts,",")
end

local function AnythingPending()
	for bracket=1,3 do
		if Pending(bracket) then return true end
	end
	return false
end

local function StopWatching()
	if ticker then ticker:Cancel() ticker=nil end
end

local function Tick()
	if not module.db.enabled then return StopWatching() end

	NoteArena()

	local now=GetTime()
	local signature=Signature()

	-- Something moved since the last look: rating and games played can arrive
	-- in separate messages, so wait for them to stop moving before believing
	-- either.
	if signature~=lastSignature then
		lastSignature=signature
		settleAt=now+SETTLE
	end

	if settleAt and now>=settleAt then
		settleAt=nil
		local fromAnArena=ArenaRecently()
		for bracket=1,3 do
			if Pending(bracket) then
				if fromAnArena then
					ReportBracket(bracket)
				else
					-- Not from a match: move the mark up so the next real one
					-- measures from here, and say nothing.
					local rating,played=RatedInfo(bracket)
					if rating and played then SetSeen(bracket,rating,played) end
				end
			end
		end
	end

	if RequestRatedInfo then RequestRatedInfo() end

	if now>=watchUntil and not settleAt and not AnythingPending() then
		StopWatching()
	end
end

-- Called by anything that might have changed a rating. Extends the watch and
-- looks straight away.
local function Watch()
	if not module.db.enabled then return end
	watchUntil=GetTime()+WATCH_SECONDS
	if not ticker then ticker=C_Timer.NewTicker(REQUEST_INTERVAL,Tick) end
	Tick()
end

----------------------------------------------------------------
-- Load
----------------------------------------------------------------

-- Clearing the shared line on a zone change is the core's job now.
local watcher=CreateFrame("Frame")
watcher:SetScript("OnEvent",function()
	-- Noted on the event as well as on the tick, so stepping into an arena
	-- counts even if the ticker is not running yet.
	NoteArena()
	Watch()
end)

----------------------------------------------------------------
-- How long it took
----------------------------------------------------------------

-- Part of the same report rather than a tweak of its own. The length is only
-- ever wanted beside the rating change, and being able to switch one off
-- without the other was a choice nobody needed to make.
local startedAt
local lengthReported=false

-- The client's own clock for the instance is the one Blizzard's "Time Elapsed"
-- line reads, so the two agree. Timing it here is the fallback, for when that
-- comes back empty.
local function LengthSeconds()
	if GetBattlefieldInstanceRunTime then
		local milliseconds=GetBattlefieldInstanceRunTime()
		if milliseconds and milliseconds>0 then
			return math.floor(milliseconds/1000+0.5)
		end
	end

	if startedAt then return math.floor(GetTime()-startedAt+0.5) end
	return nil
end

local function SpokenLength(seconds)
	local minutes=math.floor(seconds/60)
	if minutes>0 then
		return L.LENGTH_MIN_SEC:format(minutes,seconds%60)
	end
	return L.LENGTH_SEC:format(seconds)
end

local function CheckLength()
	if not module.db.enabled then return end

	if not InArena() then
		startedAt=nil
		lengthReported=false
		return
	end

	if GetBattlefieldWinner()==nil then
		-- Still going. Noted in case the client's own clock has nothing to say
		-- when it ends.
		startedAt=startedAt or GetTime()
		lengthReported=false
		return
	end

	if lengthReported then return end
	lengthReported=true

	local seconds=LengthSeconds()
	if seconds and seconds>0 then
		local spoken=SpokenLength(seconds)
		ns.Print(L.LENGTH_MSG,spoken)
		-- Last on the shared line, after the ladder numbers.
		ns.ScoreboardSay("length",spoken,3)
	end
end

local lengthWatcher=CreateFrame("Frame")
lengthWatcher:SetScript("OnEvent",CheckLength)

function module:OnEnable()
	-- One-off clear-out. Everything gathered before this was account wide, so
	-- two characters' matches were averaged together and the marks were
	-- compared across them. It is a few matches to rebuild and worth nothing
	-- as it stands, so it goes.
	if self.db.dataVersion~=DATA_VERSION then
		self.db.chars=nil
		self.db.seen=nil
		self.db.results=nil
		self.db.lastMMR=nil
		self.db.dataVersion=DATA_VERSION
	end

	watcher:RegisterEvent("PLAYER_ENTERING_WORLD")
	watcher:RegisterEvent("UPDATE_BATTLEFIELD_SCORE")
	watcher:RegisterEvent("PVP_RATED_STATS_UPDATE")
	-- Registering an event this client does not have is an error, and
	-- PVP_MATCH_COMPLETE is a later addition: it is a bonus trigger here, not
	-- the one being relied on.
	pcall(watcher.RegisterEvent,watcher,"PVP_MATCH_COMPLETE")

	lengthWatcher:RegisterEvent("PLAYER_ENTERING_WORLD")
	lengthWatcher:RegisterEvent("UPDATE_BATTLEFIELD_SCORE")
	-- Registering an event this client does not have is an error, and
	-- PVP_MATCH_COMPLETE is a later addition: a bonus trigger, not the one
	-- being relied on.
	pcall(lengthWatcher.RegisterEvent,lengthWatcher,"PVP_MATCH_COMPLETE")
end
