local ADDON_NAME, ns = ...
local L = ns.L

-- Recent matches: a short list against the side of the PvP panel while the
-- Rated page is up, and the whole lot in a window of its own behind the icon
-- next to the panel's close button.
--
-- One row each: what the rating did, your comp against theirs, and whether it
-- was a win. Hovering a class icon gives that player's name and what they did.
--
-- Nothing else records this. The rating change comes from the results tweak, which
-- works it out once and announces it; the comps and the scoreboard have to be
-- caught while the match is still running, since the arena units are gone by
-- the time it ends.
local module = ns.RegisterModule("history",{
	title       = L.HISTORY_TITLE,
	enableLabel = L.HISTORY_ENABLE,
	desc        = L.HISTORY_DESC,
	group       = "arena",
	defaults    = { enabled=true },
})

-- Kept per bracket.
--
-- Was 100, which is not a lot of arena: a fortnight of 2v2 filled it, and
-- from then on every match recorded silently deleted the oldest one. That is
-- how three games played on 2026-08-30 arrived and three from 08-16 left
-- without anything being said -- the count stayed at 100 and looked stable.
--
-- 500 rather than no limit at all. A match stores every player's damage,
-- healing, crowd control and death order, which measures at roughly 1.5 KB;
-- uncapped, a heavy season across four brackets would put tens of megabytes
-- into SavedVariables, and that file is read synchronously at load. 500 a
-- bracket is five pages of the window and about 3 MB at worst.
--
-- Raise it if that turns out to be the wrong trade. What must not come back
-- is a limit small enough to hit in normal play.
local KEEP_MAX     = 500  -- kept per bracket
local PANEL_ROWS   = 10   -- shown beside the PvP panel
local ROW_HEIGHT   = 20
local ICON_SIZE    = 16
local PANEL_WIDTH  = 300
-- Room at the top of the panel for the season line.
local HEADER_HEIGHT = 26
-- The cutoffs box below the panel. Its own frame, so it reads as its own thing:
-- the seam between the two is the point rather than a fault. Counted from the
-- tier list rather than written out, so the two cannot disagree -- the core
-- loads before any module, so the list is already there.
-- The gap under the last row, and the tallest the box ever gets. The height is
-- recomputed as it is filled -- see the end of the fill loop -- so this is only
-- what it starts at, before a bracket has been chosen.
local CUTOFF_PAD    = 18
local CUTOFF_HEIGHT = 30+#(ns.TIERS or {})*18+16

-- How far the panel sits from the PvP frame, and how far the cutoffs sit under
-- the list. Both frames carry a border with a twelve pixel inset, so anchoring
-- them flush still leaves that much daylight -- these pull the visible edges
-- together. One number each if either needs nudging.
local PANEL_GAP  = -2
local CUTOFF_LIFT = 3
-- The slots sit in a column of their own on the right, so the ratings line up
-- above each other rather than each starting wherever the line before it ended.
local CUTOFF_SPOTS_WIDTH = 66
-- A shade larger than the rest of the interface.
--
-- Scaled rather than rebuilt: every offset, font and icon in here is tuned
-- against the others, and nudging thirty numbers to make the text bigger is
-- thirty chances to knock a column out of line. One scale moves the lot and
-- keeps the proportions that already work.
local SCALE = 1.15

local RATING_WIDTH = 76

-- Where the map and length columns sit on a collapsed row, clear of the widest
-- pair of comps -- five icons a side plus the "vs" between them.
local MAP_X       = 420
local MAP_WIDTH   = 170
local DATE_WIDTH   = 104
local DETAIL_ROW   = 22   -- a player's line inside an expanded match
local DETAIL_ICON  = 20
local TOGGLE_SIZE  = 14   -- the plus/minus at the head of each row

-- Column starts inside an expanded match, from the block's left edge.
local ROLE_ICON   = 16
local SPEC_ICON   = 18
local COL_NAME    = ROLE_ICON+4+DETAIL_ICON+2+SPEC_ICON+6
-- The name, its ladder place, its rating and what the match paid used to share
-- one field, and the name won: "Bannelion-Immerseus #4087..." cut off with the
-- rating gone entirely, while "Nekk-Galakras #4087 1517" fitted. Which of the
-- four you got depended on how long somebody's name happened to be.
--
-- Three fields now. The name takes what is left and truncates if it must -- a
-- clipped name is still recognisable from its start, where a missing rating is
-- just absent -- while the place, the rating and the change are right-aligned
-- in widths that always fit them.
--
-- The extra fifty pixels come off the three wide stat columns, which had them
-- to spare: "1.3m (4.0k)" does not need a hundred and sixteen. That also pulls
-- the last column back inside the frame, which it overflowed by eighteen pixels
-- before anybody counted.
local COL_KD      = COL_NAME+250
-- "#4087 1517" at its widest, and "-142" with the sign at its.
local RANK_WIDTH  = 76
local DELTA_WIDTH = 34
local COL_DAMAGE  = COL_KD+52
local COL_HEALING = COL_DAMAGE+100
-- Two columns rather than one. "78s x27 / 8s x6" in a single cell made the
-- reader work out which half was which every time; given a heading each, both
-- are read at a glance.
local COL_TAKEN   = COL_HEALING+100
local COL_CC      = COL_TAKEN+100

-- What counts towards being the most valuable player, each measured against
-- your opposite number on the other team.
--
-- Primary is the job you turned up to do: healing if you are a healer, damage
-- if you are not. The other one is a side job -- a rogue's off-healing is not
-- worth what a healer's healing is worth, and neither is a healer's damage --
-- so it scores a quarter. Both roles are weighted the same way round, which
-- keeps their totals comparable: give healers full credit for damage while
-- damage dealers earn a quarter for healing and a healer wins every match.
--
-- Hard crowd control sits below either, being the setup rather than the
-- result, and every death takes a bite out of whatever else you did.
local MVP_WEIGHT_PRIMARY   = 1.0
local MVP_WEIGHT_SECONDARY = 0.25
local MVP_WEIGHT_CC        = 0.6
-- Roots and disarms. Work, but not the same work: a root stops you walking, not
-- playing, so it is worth well under a fear.
local MVP_WEIGHT_SOFT_CC   = 0.25
-- Damage taken, which is a good thing when you live through it: soaking a
-- match's pressure is work, and the death penalty below is what stops it
-- rewarding somebody who simply fed. Tried at 0.3, which made the biggest soak
-- of a match worth about a fifth of a point; back at 0.5 it is worth a third.
local MVP_WEIGHT_TAKEN     = 0.5
-- A kill that broke the tie, flat rather than shared: there is usually one in a
-- match, and whoever landed it decided the game.
local MVP_WEIGHT_DECISIVE  = 0.5
local MVP_PENALTY_DEATH    = 0.3

local PLUS_TEXTURE  = "Interface\\Buttons\\UI-PlusButton-UP"
local MINUS_TEXTURE = "Interface\\Buttons\\UI-MinusButton-UP"

local CLASS_ICONS = "Interface\\TargetingFrame\\UI-Classes-Circles"
local HISTORY_ICON = "Interface\\Icons\\achievement_featsofstrength_gladiator_01"

local BRACKET_NAMES = ns.BRACKET_NAMES

-- Bumped when the seed file changes, or when an import went wrong and needs
-- doing again. A plain "done" flag could not tell the difference between an
-- import that worked and one that filed everything under the wrong key.
local SEED_VERSION = 8

local current   -- what is being gathered from the arena in progress

-- The last gathered match, kept for a short while after leaving the arena.
--
-- The result is announced by the rating watcher, and when you walk out early --
-- /afk, or a leave -- the rating lands after you have already zoned. `current`
-- was thrown away on the way out, so the row was written with nobody in it.
--
-- Holds { match=..., at=<when it was parked> }.
local pending

-- How long a parked match stays usable.
--
-- Deliberately the same 300 seconds as ARENA_WINDOW in the MMR tweak, which is
-- how long after an arena a rating change is still credited to one. Past that
-- no result can arrive to claim this anyway, so a longer life here would only
-- keep a match around to be attached to the wrong game. Entering a fresh arena
-- clears it regardless of age.
local PENDING_KEEP = 300
local panel, window, button

-- The header row, shared by both windows so they look like one addon.
--
-- HEADER_TOP hangs the 20 point tall controls; HEADER_MID is where their middle
-- falls, and is what the text is levelled against. Anchoring the text by its
-- top instead left every label sitting a couple of points high of the buttons
-- beside it, which reads as sloppy rather than as a mistake.
--
-- BRACKET_X is the same in both windows on purpose: the picker sits in the same
-- place whichever window you opened.
local HEADER_TOP = -12
local HEADER_MID = -22

-- The band across the top, and the list underneath it.
--
-- Shorter than the ladder's and the inspect panel's, because this window's
-- header is one line rather than two: the title, the bracket picker and the
-- record all sit on the same row, and a 52 point band would reach down over the
-- first match.
--
-- Derived, like theirs, so the list cannot end up under the band again if the
-- header ever changes height.
local BAND_INSET  = 12
local BAND_HEIGHT = 32
local LIST_TOP    = -(BAND_INSET+BAND_HEIGHT+8)
local EMPTY_TOP   = LIST_TOP-2
-- Not the ladder's number any more, and deliberately so.
--
-- What has to match between the two windows is where the *brackets* sit, since
-- those are the buttons you look for when you swap. The ladder leads its row
-- with two buttons and this one with a single wider one, so the two rows can
-- only start in the same place at the cost of the brackets landing 10 apart.
-- 260 here and 208 there put 2v2 at 352 in both.
local BRACKET_X  = 260

-- Wider than the ladder's, because "Leaderboard" is a longer word than
-- "History".
local SWAP_W     = 88
-- The same gap the brackets use, so the row is evenly spaced end to end.
local SWAP_GAP   = 4
local rows={}
local fullRows={}
local selectedAt   -- the match expanded in the full window

----------------------------------------------------------------
-- Storage, per character
----------------------------------------------------------------

-- One character's matches. Another character's are no use here: different
-- rating, different comps, different bracket entirely.
local function Store()
	module.db.chars=module.db.chars or {}
	ns.MigrateCharStore(module.db.chars)

	local key=ns.CharKey()
	local store=module.db.chars[key] or {}
	module.db.chars[key]=store
	return store
end

-- Everybody this account has actually watched play, and what they played.
--
-- GetArenaOpponentSpec answers for the character standing in front of you, so
-- these cannot be guessed or stale. The shipped spec file can be both.
--
-- Every character on the account, not only the one logged in: an alt's matches
-- are evidence about the same opponents.
local observed

function ns.ForgetObservedSpecs() observed=nil end

function ns.ObservedSpecs()
	if observed then return observed end

	observed={}
	local at={}

	for _,store in pairs((module.db and module.db.chars) or {}) do
		for _,list in pairs(store.matches or {}) do
			for _,match in ipairs(list) do
				local when=match.at or 0
				for _,side in ipairs({ match.mine, match.theirs }) do
					for _,player in ipairs(side or {}) do
						local spec=tonumber(player.spec)
						-- Character names cannot contain a hyphen, so the
						-- first one separates the realm -- which can.
						local name,realm=(player.n or ""):match("^([^-]+)-(.+)$")
						local key=spec and name and ns.SpecKey and ns.SpecKey(name,realm)

						-- The most recent sighting wins, so somebody who
						-- respecced reads as what they are now.
						if key and when>=(at[key] or -1) then
							observed[key]=spec
							at[key]=when
						end
					end
				end
			end
		end
	end

	return observed
end

local function History(bracket)
	local store=Store()
	store.matches=store.matches or {}
	local list=store.matches[bracket] or {}
	store.matches[bracket]=list
	return list
end

-- The season record is the authority on how many matches exist. Holding more
-- than that means the character was deleted and restored -- the rating and the
-- record start again, and the older rows describe a life that no longer counts.
local function Played(bracket)
	if not GetPersonalRatedInfo then return nil end
	local played=select(4,GetPersonalRatedInfo(bracket))
	return tonumber(played)
end

local function Trimmed(bracket)
	local list=History(bracket)

	local played=Played(bracket)
	if played then
		while #list>played do table.remove(list,1) end
	end

	return list
end

-- The bracket of the most recent match on this character.
--
-- What the windows open on when nothing else has said otherwise. Reading the
-- PvP page instead gave 2v2 every time, because that field answers 2v2 for a
-- page that was never opened -- so opening the history from the minimap always
-- landed on a bracket you might not have played in weeks.
--
-- Only the newest row of each list is looked at, since they are kept in order.
function ns.LastPlayedBracket()
	local best,newest=nil,0

	for bracket=1,4 do
		local list=History(bracket)
		local last=list[#list]
		local at=last and tonumber(last.at) or 0

		if at>newest then best,newest=bracket,at end
	end

	return best
end

-- The matches themselves, for anything that wants to reason about them rather
-- than draw them -- the MMR estimate reads these instead of keeping a second,
-- smaller list of its own.
function ns.ArenaMatches(bracket)
	return Trimmed(bracket)
end

----------------------------------------------------------------
-- Watching the match
----------------------------------------------------------------

local function InArena()
	if not (IsActiveBattlefieldArena and IsActiveBattlefieldArena()) then return false end
	if C_PvP and C_PvP.IsInBrawl and C_PvP.IsInBrawl() then return false end
	return true
end

local function FullName(unit)
	local name,realm=UnitName(unit)
	if not name then return nil end
	if realm and realm~="" then return name.."-"..realm end
	return name
end

-- Sampled repeatedly rather than read once: the arena units fill in over the
-- opening seconds, and a teammate can be missing on the first look.
-- A teammate's spec is not handed over the way an opponent's is: only the
-- inspect API knows it, and that is a request and an answer rather than a
-- reading. So it is asked for while the match runs and filled in whenever the
-- reply lands -- which is how ArenaAnalytics knew them too.
local inspecting

local function AskForSpec(unit,player)
	if player.spec or not (NotifyInspect and CanInspect) then return end
	if not CanInspect(unit) then return end
	-- One outstanding request at a time: the client answers the last one asked.
	if inspecting and GetTime()-inspecting.at<3 then return end

	inspecting={ guid=UnitGUID(unit), unit=unit, at=GetTime() }
	NotifyInspect(unit)
end

-- Our own spec id.
--
-- GetSpecialization() with no arguments answers nil on this client. It takes a
-- spec group, and Mists has two of them -- dual spec -- so without being told
-- which is active it has nothing to answer about. Everything downstream was
-- fine; it simply never had an index to work from.
--
-- GetInspectSpecialization("player") answers 0 here, so it is no help either.
local function ActiveGroup()
	if GetActiveSpecGroup then return GetActiveSpecGroup() end
	if C_SpecializationInfo and C_SpecializationInfo.GetActiveSpecGroup then
		return C_SpecializationInfo.GetActiveSpecGroup()
	end
	return 1
end

local function SpecIndex()
	local group=ActiveGroup()

	if C_SpecializationInfo and C_SpecializationInfo.GetSpecialization then
		local index=C_SpecializationInfo.GetSpecialization(false,false,group)
		if index then return index end
	end

	if GetSpecialization then
		local index=GetSpecialization(false,false,group)
		if index then return index end

		index=GetSpecialization()
		if index then return index end
	end

	return nil
end

ns.SpecIndex=SpecIndex

local function OwnSpecID(index)
	index=index or SpecIndex()

	if index then
		if C_SpecializationInfo and C_SpecializationInfo.GetSpecializationInfo then
			local id=C_SpecializationInfo.GetSpecializationInfo(index)
			if id and id>0 then return id end
		end

		if GetSpecializationInfo then
			local id=GetSpecializationInfo(index)
			if id and id>0 then return id end
		end
	end

	if GetInspectSpecialization then
		local id=GetInspectSpecialization("player")
		if id and id>0 then return id end
	end

	return nil
end

ns.OwnSpecID=OwnSpecID

local function Sample()
	if not InArena() then return end
	current=current or { mine={}, theirs={} }

	local function gather(into,units)
		for index,unit in ipairs(units) do
			if UnitExists(unit) then
				local name=FullName(unit)
				local _,class=UnitClass(unit)
				if name and class then
					local guid=UnitGUID(unit)
					local player=into[name]

					-- The same character, filed twice under two spellings.
					--
					-- UnitName answers with no realm until the unit is fully
					-- known, so an early sample files "Faex" and a later one
					-- files "Faex-Arugal(AU)". Both then sit in the roster: a
					-- 2v2 comes out with three opponents, one of them an empty
					-- shell with no damage, and the match is condemned as two
					-- games stitched together.
					--
					-- The guid is the same through all of it, so it decides who
					-- is who. The fuller name wins the key, since that is the
					-- one the scoreboard and the ladder will match on.
					if not player and guid then
						for key,had in pairs(into) do
							if had.guid==guid then
								player=had
								into[key]=nil
								break
							end
						end
					end

					player=player or {}
					into[name]=player
					player.c=class
					player.n=name
					-- The guid is how a death in the combat log is matched back
					-- to a player: names there can be ambiguous, guids cannot.
					player.guid=guid
					if unit:match("^arena") and GetArenaOpponentSpec then
						player.spec=GetArenaOpponentSpec(index) or player.spec
					elseif unit:match("^party") then
						AskForSpec(unit,player)
					elseif unit=="player" then
						local spec=SpecIndex()
						if spec and GetSpecializationRole then
							player.role=GetSpecializationRole(spec) or player.role
						end
						player.spec=OwnSpecID(spec) or player.spec
					elseif UnitGroupRolesAssigned then
						-- Teammates rarely have one assigned in arena, but when
						-- they do it beats reading it out of the damage meter.
						local role=UnitGroupRolesAssigned(unit)
						if role and role~="NONE" then player.role=role end
					end
				end
			end
		end
	end

	gather(current.mine,{"player","party1","party2","party3","party4"})
	gather(current.theirs,{"arena1","arena2","arena3","arena4","arena5"})

	if not current.map and GetInstanceInfo then
		current.map=GetInstanceInfo()
	end

	-- Whether this match ever reached a decision.
	--
	-- GetBattlefieldWinner answers nil while a match is running and a side once
	-- it is over, so seeing anything here means the game finished -- whatever
	-- happened afterwards. Recorded rather than asked later, because by the time
	-- the result is announced we may already have zoned out and the answer is
	-- gone.
	--
	-- This is what separates walking out of a match from simply leaving the
	-- arena promptly once it was won: both zone out before the rating settles,
	-- and without this both were labelled "left early". A won match marked as
	-- abandoned is a plain contradiction.
	if not current.decided and GetBattlefieldWinner and GetBattlefieldWinner()~=nil then
		current.decided=true
	end

	-- Read as the match runs, not only when it ends.
	--
	-- Waiting for the winner meant a match you walked out of early recorded
	-- nothing but zeroes: the scoreboard is gone the moment you leave, and the
	-- crowd control was the only column with anything in it, since that is
	-- built from the combat log instead. Sampled every couple of seconds, a
	-- match left early keeps everything up to the moment you left.
	if GetBattlefieldInstanceRunTime then
		local ms=GetBattlefieldInstanceRunTime()
		if ms and ms>0 then current.dur=math.floor(ms/1000+0.5) end
	end

	-- Nothing to read until somebody has died. Before the first death the
	-- scoreboard is a page of zeroes, and asking the server for it every couple
	-- of seconds through the gates and the opener is traffic spent on nothing.
	--
	-- Nothing is lost by waiting: these are running totals, so the first read
	-- after a death already carries everything done before it.
	if (current.deaths or 0)==0 then return end

	-- The numbers only arrive after being asked for.
	if RequestBattlefieldScoreData then RequestBattlefieldScoreData() end

	if GetNumBattlefieldScores and GetBattlefieldScore then
		for index=1,(GetNumBattlefieldScores() or 0) do
			-- The thirteenth return is what the match was worth to that player.
			--
			-- Read off the scoreboard rather than assumed absent: the Rating
			-- Change column has a number for everybody, and this is it --
			-- checked against the client, where your own +14 lined up with the
			-- rating the MMR tweak announced.
			local name,kills,_,deaths,_,_,_,_,_,_,damage,healing,change=GetBattlefieldScore(index)
			if name then
				-- Scoreboard names carry the realm for anyone from elsewhere,
				-- so match on the bare name as well.
				local bare=name:match("^([^-]+)")
				local entry=current.mine[name] or current.theirs[name]
				if not entry then
					for _,side in ipairs({current.mine,current.theirs}) do
						for key,player in pairs(side) do
							if key==bare or key:match("^([^-]+)")==bare then entry=player end
						end
					end
				end

				if entry then
					-- Never downwards. These only climb during a match, so a
					-- later read of zero is the scoreboard emptying as the
					-- match closes rather than the damage being undone.
					local function Best(was,now)
						was,now=tonumber(was) or 0,tonumber(now) or 0
						return (now>was) and now or was
					end

					entry.k    = Best(entry.k,kills)
					entry.x    = Best(entry.x,deaths)
					entry.dmg  = Best(entry.dmg,damage)
					entry.heal = Best(entry.heal,healing)

					-- Not Best: this one is signed, and keeping the larger of
					-- the two would turn every defeat into a zero.
					--
					-- Nor "ignore zero", which was the first attempt: a loss
					-- against somebody far below your MMR really does cost
					-- nothing, and skipping zeroes left those players with a
					-- blank line rather than a +0.
					--
					-- So: recorded even at zero, but a number once found is
					-- never replaced by a zero. The scoreboard reads zero for
					-- everybody until the match is decided, and empties again
					-- as it closes.
					local delta=tonumber(change)
					if delta and (entry.rc==nil or delta~=0) then entry.rc=delta end
				end
			end
		end
	end
end

-- Deaths in the order they happened. The scoreboard only counts them, and
-- which one decided the match is the interesting part: the first death on a
-- win, the last on a loss.
-- A hunter playing dead reports UNIT_DIED like anybody else, which is how a
-- five minute arena ends up recording three deaths for one player. The aura is
-- watched so the death that comes with it can be ignored.
local FEIGN_DEATH = 5384

-- Whoever a guid belongs to, either side.
local function PlayerByGUID(guid)
	if not (current and guid) then return nil end
	for _,side in ipairs({current.mine,current.theirs}) do
		for _,player in pairs(side) do
			if player.guid==guid then return player end
		end
	end
	return nil
end

local function OnInspectReady(guid)
	if not (current and inspecting and GetInspectSpecialization) then return end
	if guid and inspecting.guid and guid~=inspecting.guid then return end

	local unit=inspecting.unit
	inspecting=nil
	if not (unit and UnitExists(unit)) then return end

	local spec=GetInspectSpecialization(unit)
	if not (spec and spec>0) then return end

	local target=PlayerByGUID(UnitGUID(unit))
	if target then target.spec=spec end
	if ClearInspectPlayer then ClearInspectPlayer() end
end

-- A killing blow counts when it breaks the tie.
--
-- The opening kill of a match is the one that decides it, and after a trade the
-- next kill is the one that puts a team back ahead. A kill that merely levels
-- the score has not won anybody anything yet, so it scores nothing.
--
-- Which is why the killer has to be named at all: the total on the scoreboard
-- cannot say which of somebody's kills mattered.
local function CreditKill(victimSide,victimGUID)
	if not current then return end

	current.kills=current.kills or { mine=0, theirs=0 }
	local scorer=(victimSide==current.mine) and "theirs" or "mine"
	local other=(scorer=="mine") and "theirs" or "mine"

	local level=(current.kills[scorer]==current.kills[other])
	current.kills[scorer]=current.kills[scorer]+1
	if not level then return end

	local killer=PlayerByGUID(current.lastHit and current.lastHit[victimGUID])
	if killer then killer.decisive=(killer.decisive or 0)+1 end
end

local function NoteDeath(guid)
	if not (current and guid) then return end

	for _,side in ipairs({current.mine,current.theirs}) do
		for _,player in pairs(side) do
			if player.guid==guid then
				-- Playing dead is not dying.
				if player.feigning then return end

				-- Counted separately from the order: an arena scoreboard reports
				-- no deaths at all, so this is the only place they exist.
				player.dead=(player.dead or 0)+1
				if not player.died then
					current.deaths=(current.deaths or 0)+1
					player.died=current.deaths
				end

				CreditKill(side,guid)
				return
			end
		end
	end
end

local function NoteFeign(destGUID,feigning)
	local target=PlayerByGUID(destGUID)
	if target then target.feigning=feigning or nil end
end

-- Hard crowd control, counted both ways: what a player landed and what they
-- sat in. Time matters more than count -- a four second stun is not a nine
-- second fear -- so applications are paired with their removal.
-- Close an open spell of crowd control and credit the seconds it ran for, to
-- the one who sat in it and the one who landed it.
local function Bank(key,target)
	local started=current and current.ccOpen and current.ccOpen[key]
	if not started then return end
	current.ccOpen[key]=nil

	local seconds=math.min(GetTime()-started,ns.HARD_CC_MAX_SECONDS or 12)
	if seconds<=0 then return end

	-- Roots and disarms are kept in their own pair of totals, so the hard
	-- number stays the hard number.
	local soft=current.ccSoft and current.ccSoft[key]
	local source=PlayerByGUID(current.ccBy and current.ccBy[key])

	if soft then
		target.softTaken=(target.softTaken or 0)+seconds
		if source then source.soft=(source.soft or 0)+seconds end
		return
	end

	target.ccTaken=(target.ccTaken or 0)+seconds
	if source then source.cc=(source.cc or 0)+seconds end
end

local function NoteCC(sourceGUID,destGUID,spellID,spellName,applied)
	if not (current and ns.HARD_CC) then return end

	local hard=ns.HARD_CC[spellID]
		or (spellName and ns.HARD_CC_NAMES and ns.HARD_CC_NAMES[spellName])
	local soft=(not hard) and (ns.SOFT_CC and ns.SOFT_CC[spellID]
		or (spellName and ns.SOFT_CC_NAMES and ns.SOFT_CC_NAMES[spellName]))

	if not (hard or soft) then return end

	local target=PlayerByGUID(destGUID)
	if not target then return end

	current.ccOpen=current.ccOpen or {}
	local key=destGUID.."|"..spellID

	if applied then
		-- A refresh lands on an aura that is already open. Bank what it has run
		-- for before restarting the clock, or that time is simply lost.
		if current.ccOpen[key] then Bank(key,target) end

		current.ccOpen[key]=GetTime()
		current.ccSoft=current.ccSoft or {}
		current.ccSoft[key]=soft and true or nil

		-- The count lands on application; the seconds land when it ends.
		target.ccTakenCount=(target.ccTakenCount or 0)+1
		local source=PlayerByGUID(sourceGUID)
		if source then source.ccCount=(source.ccCount or 0)+1 end
		current.ccBy=current.ccBy or {}
		current.ccBy[key]=sourceGUID
		return
	end

	Bank(key,target)
end

-- A match can end with someone still sat in a fear, and their removal event
-- never arrives. Those seconds happened, so anything still open at the whistle
-- is closed against the clock rather than thrown away.
local function CloseOpenCC()
	if not (current and current.ccOpen) then return end

	for key in pairs(current.ccOpen) do
		local destGUID,spellID=key:match("^(.+)|(%d+)$")
		NoteCC(current.ccBy and current.ccBy[key],destGUID,tonumber(spellID),nil,false)
	end

	current.ccOpen,current.ccBy=nil,nil
end

-- Damage taken, which the arena scoreboard does not report at all: it lists
-- damage done and healing done and nothing about what landed on you. Summed
-- here instead, so soaking a match's pressure and living through it can count
-- for something.
local function NoteDamage(destGUID,amount)
	amount=tonumber(amount) or 0
	if amount<=0 then return end

	local target=PlayerByGUID(destGUID)
	if not target then return end

	target.taken=(target.taken or 0)+amount

	-- UNIT_DIED says who died and nothing about who did it, so the last hand
	-- on them is remembered and credited when they go down.
	current.lastHit=current.lastHit or {}
	current.lastHit[destGUID]=sourceGUID
end

-- A spec read off something only that spec can cast.
--
-- The table lookup comes before working out who cast it, and that order is the
-- whole performance story: the combat log fires constantly, almost nothing in
-- it is a signature spell, and a miss costs one hash lookup. Finding the player
-- only happens on the rare hit.
--
-- Never overwrites. An answer from the arena unit or an inspect is the client's
-- own and outranks anything inferred here.
local function NoteSpec(guid,spellID,spellName)
	if not guid then return end

	local spec=spellID and ns.SPEC_SPELLS[spellID]
	if spec==nil and spellName then spec=ns.SPEC_SPELL_NAMES[spellName] end
	-- false is a spell two specs share, which answers nothing.
	if not spec then return end

	local player=PlayerByGUID(guid)
	if player and not player.spec then player.spec=spec end
end

local function OnCombatLog()
	if not (current and InArena()) then return end
	if not CombatLogGetCurrentEventInfo then return end

	local _,event,_,sourceGUID,_,_,_,destGUID,_,_,_,spellID,spellName=CombatLogGetCurrentEventInfo()

	-- Ahead of the damage handling below, which returns early.
	NoteSpec(sourceGUID,spellID,spellName)

	if event=="SWING_DAMAGE" then
		-- A swing carries its amount where a spell carries its id, so the two
		-- are read from different places in the same list.
		return NoteDamage(destGUID,select(12,CombatLogGetCurrentEventInfo()))
	end

	if event=="SPELL_DAMAGE" or event=="SPELL_PERIODIC_DAMAGE"
		or event=="RANGE_DAMAGE" or event=="SPELL_BUILDING_DAMAGE" then
		return NoteDamage(destGUID,select(15,CombatLogGetCurrentEventInfo()))
	end

	-- The cast, before the death it causes.
	--
	-- A hunter feigning emits UNIT_DIED, and the aura that says it was a feign
	-- arrives *after* it -- so a check that only watched the aura was always one
	-- event too late, and every feign was recorded as a death. The cast lands
	-- first, which is early enough.
	--
	-- Kept alongside the aura rather than replacing it: the aura is what clears
	-- the flag again, and a feign that somehow applies without a cast we saw is
	-- still worth catching.
	if event=="SPELL_CAST_SUCCESS" and spellID==FEIGN_DEATH then
		NoteFeign(sourceGUID,true)
	end

	if event=="UNIT_DIED" then
		NoteDeath(destGUID)
	elseif event=="SPELL_AURA_APPLIED" or event=="SPELL_AURA_REFRESH" then
		if spellID==FEIGN_DEATH then NoteFeign(destGUID,true) end
		NoteCC(sourceGUID,destGUID,spellID,spellName,true)
	elseif event=="SPELL_AURA_REMOVED" or event=="SPELL_AURA_BROKEN"
		or event=="SPELL_AURA_BROKEN_SPELL" then
		if spellID==FEIGN_DEATH then NoteFeign(destGUID,false) end
		-- Breaking on damage is how most fears end, and the log reports that
		-- differently from an aura running out. Missing it left the fear open
		-- until the whistle, where it was banked at the twelve second cap.
		NoteCC(sourceGUID,destGUID,spellID,spellName,false)
	end
end

-- Keyed by name while gathering so the scoreboard can find them; the stored
-- match wants plain lists.
-- Recorded as a list, with anyone appearing twice folded into one.
--
-- The merge while sampling should mean this never fires. It is here because it
-- costs nothing and the failure it guards against -- one player counted twice,
-- inflating the roster past the bracket size -- gets the whole match written
-- off as "rosters mixed", which is a worse outcome than the duplicate itself.
-- Where everybody stood, as at this match.
--
-- The ladder place used to be looked up when the row was drawn, which meant a
-- match got a different answer every time the ladder moved: fight a rank 12 and
-- read the row a week later, and it says whatever they are today. A record of a
-- past evening should not keep changing.
--
-- So it is stamped once, here, when the match is committed -- `lr` for the
-- place and `lv` for the rating the ladder then had. Rows written before this
-- carry neither and fall back to a live lookup, which is what they always did.
--
-- Honest about what it is: the ladder in memory is only as fresh as the file
-- loaded at the last reload, so this is where they stood when we last heard,
-- not to the minute. It is still a fixed point, which the old behaviour was
-- not.
local function StampLadder(byName,bracket)
	if not (byName and bracket and ns.LadderEntry) then return end

	for _,player in pairs(byName) do
		if player.n and player.lr==nil then
			local entry=ns.LadderEntry(bracket,player.n)
			if entry then
				player.lr=entry.rank
				player.lv=entry.rating
			end
		end
	end
end

local function AsList(byName)
	local list,seen={},{}

	for _,player in pairs(byName or {}) do
		local guid=player.guid

		if guid and seen[guid] then
			-- Keep whichever copy actually saw the match: an early duplicate is
			-- the one with nothing in it.
			local had=list[seen[guid]]
			if (tonumber(player.dmg) or 0)>(tonumber(had.dmg) or 0) then
				list[seen[guid]]=player
			end
		else
			list[#list+1]=player
			if guid then seen[guid]=#list end
		end
	end

	return list
end

----------------------------------------------------------------
-- Drawing
----------------------------------------------------------------

-- The tier colours arrive as the six hex digits a chat colour code wants, and
-- a FontString wants three numbers, so one turns into the other here.
local function HexToRGB(hex)
	if type(hex)~="string" or #hex<6 then return 1,1,1 end

	return tonumber(hex:sub(1,2),16)/255,
	       tonumber(hex:sub(3,4),16)/255,
	       tonumber(hex:sub(5,6),16)/255
end

local function Fill(texture,r,g,b,a)
	if texture.SetColorTexture then
		texture:SetColorTexture(r,g,b,a)
	else
		texture:SetTexture(r,g,b,a)
	end
end

-- The death that decided the match: the first one on a win, the last on a
-- loss. Only matches recorded here have the full order -- imported ones know
-- which death came first and nothing more -- so a loss is left unmarked rather
-- than marked wrongly.
local function DecisiveDeath(match)
	if not match then return nil end

	local wantLast=(match.w==false)
	if wantLast and not match.live then return nil end

	local decisive,order
	for _,side in ipairs({match.mine,match.theirs}) do
		for _,player in ipairs(side or {}) do
			local died=tonumber(player.died)
			if died then
				if not order or (wantLast and died>order) or (not wantLast and died<order) then
					decisive,order=player,died
				end
			end
		end
	end

	return decisive
end

-- The scoreboard's count where there is one -- imported matches have it -- and
-- otherwise the combat log's, since an arena scoreboard leaves deaths at zero
-- however many times somebody hit the floor.
local function Deaths(player)
	local scored=tonumber(player.x) or 0
	if scored>0 then return scored end

	local counted=tonumber(player.dead) or 0
	if counted>0 then return counted end

	-- Matches recorded before deaths were counted, and every imported one, kept
	-- only the marker saying this player went down. That is still one death.
	return player.died and 1 or 0
end

local function Number(value)
	value=tonumber(value) or 0
	if value>=1000000 then return ("%.1fm"):format(value/1000000) end
	if value>=1000 then return ("%.1fk"):format(value/1000) end
	return tostring(math.floor(value))
end

local function ShowPlayerTooltip(slot)
	local player,duration=slot.player,slot.duration
	if not player then return end

	GameTooltip:SetOwner(slot,"ANCHOR_RIGHT")

	local colour=RAID_CLASS_COLORS and RAID_CLASS_COLORS[player.c]
	GameTooltip:SetText(player.n or "?",
		colour and colour.r or 1,colour and colour.g or 1,colour and colour.b or 1)

	GameTooltip:AddLine(L.HISTORY_TIP_KILLS:format(player.k or 0,Deaths(player)),1,1,1)
	if (tonumber(player.taken) or 0)>0 then
		GameTooltip:AddLine(L.HISTORY_TIP_TAKEN:format(Number(player.taken)),1,1,1)
	end
	if (tonumber(player.decisive) or 0)>0 then
		GameTooltip:AddLine(L.HISTORY_TIP_DECISIVE:format(player.decisive),1,0.82,0)
	end

	-- Rates only where the match length was recorded; an average over an
	-- unknown number of seconds is not worth showing.
	if duration and duration>0 then
		GameTooltip:AddLine(L.HISTORY_TIP_DAMAGE:format(Number(player.dmg),Number((player.dmg or 0)/duration)),1,1,1)
		GameTooltip:AddLine(L.HISTORY_TIP_HEALING:format(Number(player.heal),Number((player.heal or 0)/duration)),1,1,1)
	else
		GameTooltip:AddLine(L.HISTORY_TIP_DAMAGE_ONLY:format(Number(player.dmg)),1,1,1)
		GameTooltip:AddLine(L.HISTORY_TIP_HEALING_ONLY:format(Number(player.heal)),1,1,1)
	end

	GameTooltip:Show()
end

local function CreateSlot(row)
	local slot=CreateFrame("Frame",nil,row)
	slot:SetSize(ICON_SIZE,ICON_SIZE)
	slot:EnableMouse(true)
	slot:Hide()

	slot.icon=slot:CreateTexture(nil,"ARTWORK")
	slot.icon:SetAllPoints()

	slot.skull=slot:CreateTexture(nil,"OVERLAY")
	slot.skull:SetTexture(SKULL_ICON)
	slot.skull:SetSize(10,10)
	slot.skull:SetPoint("BOTTOMRIGHT",slot,"BOTTOMRIGHT",3,-3)
	slot.skull:Hide()

	slot:SetScript("OnEnter",ShowPlayerTooltip)
	slot:SetScript("OnLeave",function() GameTooltip:Hide() end)

	-- The icons cover most of the row, and a click on one is still a click on
	-- the match.
	slot:SetScript("OnMouseUp",function(self)
		local owner=self:GetParent()
		if owner and owner:GetScript("OnClick") then owner:GetScript("OnClick")(owner) end
	end)

	return slot
end

local function SetSlot(slot,player,duration,x,row,decisive)
	if not player then return slot:Hide() end

	slot.skull:SetShown(decisive~=nil and player==decisive)

	slot.player,slot.duration=player,duration
	slot.icon:SetTexture(CLASS_ICONS)

	local coords=CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[player.c]
	if coords then slot.icon:SetTexCoord(unpack(coords)) end

	-- Anyone who died is tinted red, the same as in an expanded match, so a
	-- glance at the short list already says who fell.
	if Deaths(player)>0 then
		slot.icon:SetVertexColor(1,0.3,0.3)
	else
		slot.icon:SetVertexColor(1,1,1)
	end

	slot:ClearAllPoints()
	slot:SetPoint("LEFT",row,"LEFT",x,0)
	slot:Show()
end

-- Which row of the Rated page is selected, so the list follows it.
--
-- Up here rather than down with the list code, because the match rows want it
-- too: a ladder place is looked up per bracket, and the rows are drawn well
-- before any of that.
local function SelectedBracket()
	local frame=ConquestQueueFrame
	local button=frame and frame.selectedButton
	return (button and button.id) or 1
end

-- Shared, so the ladder window lists whichever bracket the page is on rather
-- than growing a set of tabs that would only ever disagree with this one.
ns.SelectedBracket=SelectedBracket

-- Whether a recorded name is you.
--
-- The ladder window has its own version of this and it is a local there, so
-- borrowing the name resolved to nothing and threw on every row. Bare names
-- either side: your own matches record you without a realm, opponents with one.
local function IsMe(name)
	local me=UnitName and UnitName("player")
	if not (name and me) then return false end

	local bare=name:match("^([^%-]+)") or name
	if ns.PlainName then return ns.PlainName(bare)==ns.PlainName(me) end
	return bare:lower()==me:lower()
end

-- Your own row, which can be exact where an opponent's cannot.
--
-- The result carries the rating this match finished at -- not the ladder's idea
-- of it, the real one -- and the client knows the place that goes with it. So
-- your line says what you actually ended on, while everyone else's says where
-- the ladder last had them.
--
-- It also reaches people the ladder does not: it stops at 1108 in 2v2, and most
-- characters are below that.
local function StampMe(byName,info)
	if not (byName and info) then return end

	local rank=GetPersonalRatedInfo and tonumber(select(11,GetPersonalRatedInfo(info.bracket)))

	for _,player in pairs(byName) do
		if player.n and IsMe(player.n) then
			if info.rating then player.lv=info.rating end
			if rank and rank>0 then player.lr=rank end
		end
	end
end

-- How many players a side holds in each bracket.
local TEAM_SIZE = { [1]=2, [2]=3, [3]=5, [4]=10 }

-- Whether a match holds more players than its bracket allows.
--
-- That only happens one way: a match that never reported a result left its
-- players behind, and the next arena gathered into the same table. A 2v2 with
-- four opponents is two games stacked on each other, and there is no telling
-- which half is which.
local function Mixed(match,bracket)
	local size=TEAM_SIZE[bracket or 0]
	if not (match and size) then return false end

	return #(match.mine or {})>size or #(match.theirs or {})>size
end

-- The same question, asked of a match still being gathered.
--
-- Mixed above reads a recorded row, where the sides are lists. While a match is
-- in progress they are tables keyed by name, so they have no length -- counting
-- has to be done the long way.
local function Counted(side)
	local total=0
	for _ in pairs(side or {}) do total=total+1 end
	return total
end

-- Whether anything was actually seen. One side empty means the arena was never
-- watched, and parking that is no better than parking nothing.
local function Gathered(match)
	return match~=nil and Counted(match.theirs)>0
end

-- Whether a gathered match could belong to the bracket a result names.
--
-- The guard against a parked match attaching itself to the wrong game: a 2v2
-- result cannot be carrying three opponents.
local function FitsBracket(match,bracket)
	local size=TEAM_SIZE[bracket or 0]
	if not (match and size) then return false end
	return Counted(match.mine)<=size and Counted(match.theirs)<=size
end

-- Whether this match captured rating changes at all.
--
-- Worth asking because of how the first version behaved: it recorded a change
-- only when it was non-zero, so a player who lost nothing -- which happens when
-- their rating sits far below their MMR -- came out with no number rather than
-- a zero.
--
-- So in a match where anybody has one, anybody without one had zero. That is
-- not a guess about the game, it is the exact inverse of what the recording
-- did. In a match where nobody has one, the match predates any of this and
-- nothing can be said.
local function HasDeltas(match)
	if not match then return false end

	for _,side in ipairs({ match.mine, match.theirs }) do
		for _,player in ipairs(side or {}) do
			if tonumber(player.rc) then return true end
		end
	end

	return false
end

-- Whether a match was watched at all.
--
-- The opposing team is read from the arena units, which only exist while you
-- are standing in the arena -- so a disconnect or an early leave records the
-- rating change and nothing on the other side. One player and no opponents is
-- that, every time.
--
-- Up here because both the row and its expanded detail ask, and the row is
-- drawn first.
local function Incomplete(match)
	if not match then return false end
	return #(match.theirs or {})==0
end

local function ShowMatch(row,match,expanded)
	row.match=match
	if not match then return row:Hide() end

	local delta=match.d or 0

	if row.date then
		row.date:SetText(match.at and date("%d/%m %H:%M",match.at) or "")
	end

	-- The rating line follows the points: nothing lost, nothing to colour red.
	local colour=(delta>0 and "|cff1eff00") or (delta<0 and "|cffff2020") or "|cffb3b3b3"
	row.rating:SetText(("%s%d %+d|r"):format(colour,match.r or 0,delta))

	-- A match nobody watched is dimmed, so it reads as incomplete before it is
	-- opened rather than after. Faded rather than hidden: it happened, it cost
	-- rating, and the season counts it.
	row:SetAlpha(Incomplete(match) and 0.55 or 1)

	-- The comps are spelled out in full underneath while a match is open, so
	-- the little ones would only be sitting in the middle of it.
	if expanded then
		for index=1,5 do
			row.mine[index]:Hide()
			row.theirs[index]:Hide()
		end
		row.vs:Hide()
	else
		local x=(row.date and DATE_WIDTH or 0)+RATING_WIDTH
		local decisive=DecisiveDeath(match)

		for index=1,5 do
			SetSlot(row.mine[index],match.mine and match.mine[index],match.dur,x,row,decisive)
			if match.mine and match.mine[index] then x=x+ICON_SIZE+1 end
		end

		row.vs:ClearAllPoints()
		row.vs:SetPoint("TOPLEFT",row,"TOPLEFT",x+3,-2)
		row.vs:Show()
		x=x+18

		for index=1,5 do
			SetSlot(row.theirs[index],match.theirs and match.theirs[index],match.dur,x,row,decisive)
			if match.theirs and match.theirs[index] then x=x+ICON_SIZE+1 end
		end
	end

	if row.map then
		row.map:SetText((not expanded) and match.map or "")
	end

	if row.length then
		-- Hidden while a match is open: the block underneath says it in full.
		local seconds=(not expanded) and tonumber(match.dur) or nil
		if seconds and seconds>0 then
			row.length:SetText(L.HISTORY_SUMMARY_LENGTH:format(math.floor(seconds/60),seconds%60))
		else
			row.length:SetText("")
		end
	end

	-- The square follows the result. A loss can cost nothing while still being
	-- a loss, so the recorded outcome is used where there is one and the points
	-- only stand in for it where there is not.
	local won=match.w
	if won==nil then
		if delta>0 then won=true elseif delta<0 then won=false end
	end

	if won==true then
		Fill(row.dot,0.12,1,0,1)
	elseif won==false then
		Fill(row.dot,1,0.13,0.13,1)
	else
		Fill(row.dot,0.7,0.7,0.7,1)
	end

	row:Show()
end

-- The players of one match, spelled out under it: bigger icons, names, and the
-- numbers that are otherwise only in a tooltip.
-- The group finder's role circles. These coordinates belong to PORTRAITROLES
-- specifically -- the plain ROLES sheet is a four-across strip and the same
-- numbers cut a sliver out of the middle of it.
local ROLE_TEXTURE = "Interface\\LFGFrame\\UI-LFG-ICON-PORTRAITROLES"

-- The raid target markers, used here as small badges on a portrait.
--
-- SKULL_ICON was referenced in two places and defined in none, so it was a nil
-- global: SetTexture(nil) clears a texture rather than complaining, which is why
-- the decisive-kill marker has never appeared and nothing ever said so.
local SKULL_ICON = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_8"
-- Bigger than a badge would be, because it now stands beside the name rather
-- than on top of a portrait.
local SKULL_SIZE = 14
local ROLE_COORDS  = {
	TANK    = {   0, 19/64, 22/64, 41/64 },
	HEALER  = { 20/64, 39/64,  1/64, 20/64 },
	DAMAGER = { 20/64, 39/64, 22/64, 41/64 },
}

local function RoleCoords(role)
	if GetTexCoordsForRoleSmallCircle then
		return GetTexCoordsForRoleSmallCircle(role)
	end

	local coords=ROLE_COORDS[role] or ROLE_COORDS.DAMAGER
	return coords[1],coords[2],coords[3],coords[4]
end

-- The spec's own icon, where the client knew the spec. Nothing knows a
-- teammate's spec in this client and imported matches know nobody's, so this
-- is often nothing and the row has to read fine without it.
local function SpecIcon(player)
	local spec=tonumber(player.spec)
	if not spec then return nil end

	if ns.SPEC_ICON and ns.SPEC_ICON[spec] then return ns.SPEC_ICON[spec] end
	if not GetSpecializationInfoByID then return nil end

	local _,_,_,icon=GetSpecializationInfoByID(spec)
	return icon
end

local function DetailLine(detail,index)
	local line=detail.lines[index]
	if line then return line end

	line=CreateFrame("Frame",nil,detail)
	line:SetHeight(DETAIL_ROW)
	line:SetPoint("TOPLEFT",detail,"TOPLEFT",0,-(index-1)*DETAIL_ROW)
	line:SetPoint("RIGHT",detail,"RIGHT",0,0)

	line.role=line:CreateTexture(nil,"ARTWORK")
	line.role:SetTexture(ROLE_TEXTURE)
	line.role:SetSize(ROLE_ICON,ROLE_ICON)
	line.role:SetPoint("LEFT",line,"LEFT",0,0)

	line.icon=line:CreateTexture(nil,"ARTWORK")
	line.icon:SetSize(DETAIL_ICON,DETAIL_ICON)
	line.icon:SetPoint("LEFT",line,"LEFT",ROLE_ICON+4,0)

	line.spec=line:CreateTexture(nil,"ARTWORK")
	line.spec:SetSize(SPEC_ICON,SPEC_ICON)
	line.spec:SetPoint("LEFT",line.icon,"RIGHT",2,0)
	-- Icons come with a border baked in that the class circles do not have.
	line.spec:SetTexCoord(0.07,0.93,0.07,0.93)

	-- After the name, not on the portrait.
	--
	-- On the class icon it simply covered it -- a badge over a twenty pixel
	-- portrait leaves nothing of the portrait worth seeing, and the first
	-- attempt at a corner offset put it on the spec icon next door instead.
	-- Beside the name it has room to be read.
	--
	-- Placed when the row is drawn rather than here: where the name ends
	-- depends on the name.
	line.skull=line:CreateTexture(nil,"OVERLAY")
	line.skull:SetTexture(SKULL_ICON)
	line.skull:SetSize(SKULL_SIZE,SKULL_SIZE)
	line.skull:Hide()

	local function column(x,width,justify)
		local text=line:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
		text:SetPoint("LEFT",line,"LEFT",x,0)
		if width then text:SetWidth(width) end
		text:SetJustifyH(justify or "LEFT")
		text:SetWordWrap(false)
		return text
	end

	-- Widths from the gaps between the columns rather than written out, so
	-- moving a column cannot leave a field overlapping the next one. The stat
	-- columns gave up eight pixels each to widen the names and their old fixed
	-- widths would have run straight over the top.
	line.nameWidth=COL_KD-COL_NAME-8-DELTA_WIDTH-RANK_WIDTH-12
	line.name    = column(COL_NAME,line.nameWidth)

	-- Right-clicking the name offers it to be copied.
	--
	-- Its own button over the name column, the same way the rank below has one:
	-- a FontString cannot be clicked, and mouse-enabling the whole line would
	-- swallow clicks meant for anything else on it.
	--
	-- Lit on hover, the same as the rank beside it.
	--
	-- It was left unlit at first, reasoning that a left click does nothing here
	-- so a glow would promise something it does not do. That had it backwards:
	-- the name does respond, to the right button, and nothing else on the row
	-- says so. Without the glow the only way to find it is to be told.
	line.nameHit=CreateFrame("Button",nil,line)
	line.nameHit:SetPoint("LEFT",line,"LEFT",COL_NAME,0)
	line.nameHit:SetSize(line.nameWidth,DETAIL_ROW)
	line.nameHit:RegisterForClicks("RightButtonUp")

	local nameGlow=line.nameHit:CreateTexture(nil,"HIGHLIGHT")
	nameGlow:SetAllPoints()
	nameGlow:SetColorTexture(1,1,1,0.10)
	line.nameHit:SetHighlightTexture(nameGlow)
	line.nameHit:SetScript("OnEnter",function(self)
		if not self.copyName then return end
		GameTooltip:SetOwner(self,"ANCHOR_RIGHT")
		-- Six arguments: SetText is (text, r, g, b, alpha, wrap), so a bare
		-- `true` in fifth place lands in alpha and throws.
		GameTooltip:SetText(L.COPY_HINT,1,1,1,1,true)
		GameTooltip:Show()
	end)
	line.nameHit:SetScript("OnLeave",function() GameTooltip:Hide() end)

	line.nameHit:SetScript("OnClick",function(self)
		-- Anchored to the window, not to this line's parent: that is the detail
		-- area inside the window, so the box would still land on top of it.
		if ns.CopyName then ns.CopyName(self.copyName,window or panel) end
	end)

	-- The ladder place is a button, not just text: clicking it opens the ladder
	-- on this bracket with the name already searched for, which is what anybody
	-- reading a rank wants next.
	--
	-- Its own frame because a FontString cannot be clicked, and the highlight
	-- because a thing that responds to a click has to look like one -- the gems
	-- list read as static text until it got the same treatment.
	line.rankHit=CreateFrame("Button",nil,line)
	line.rankHit:SetPoint("LEFT",line,"LEFT",COL_KD-8-DELTA_WIDTH-6-RANK_WIDTH,0)
	line.rankHit:SetSize(RANK_WIDTH,DETAIL_ROW)

	local glow=line.rankHit:CreateTexture(nil,"HIGHLIGHT")
	glow:SetAllPoints()
	glow:SetColorTexture(1,1,1,0.10)
	line.rankHit:SetHighlightTexture(glow)

	line.rank=line.rankHit:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
	line.rank:SetPoint("LEFT",line.rankHit,"LEFT",0,0)
	line.rank:SetWidth(RANK_WIDTH)
	line.rank:SetJustifyH("RIGHT")
	line.rank:SetWordWrap(false)

	line.rankHit:SetScript("OnEnter",function(self)
		if not self.ladderName then return end
		GameTooltip:SetOwner(self,"ANCHOR_RIGHT")
		-- Six arguments, not five: SetText is (text, r, g, b, alpha, wrap),
		-- so a bare `true` after the colour lands in alpha and throws. AddLine
		-- has no alpha and does take wrap fifth, which is why the same shape is
		-- right there and wrong here.
		GameTooltip:SetText(L.HISTORY_LADDER_CLICK,1,1,1,1,true)
		GameTooltip:Show()
	end)
	line.rankHit:SetScript("OnLeave",function() GameTooltip:Hide() end)
	line.rankHit:SetScript("OnClick",function(self)
		if not (self.ladderName and ns.ShowLadderFor) then return end
		ns.ShowLadderFor(self.ladderBracket,self.ladderName)
	end)
	line.delta   = column(COL_KD-8-DELTA_WIDTH,DELTA_WIDTH,"RIGHT")
	line.kd      = column(COL_KD,COL_DAMAGE-COL_KD-6)
	line.damage  = column(COL_DAMAGE,COL_HEALING-COL_DAMAGE-4)
	line.healing = column(COL_HEALING,COL_TAKEN-COL_HEALING-4)
	line.taken   = column(COL_TAKEN,COL_CC-COL_TAKEN-4)
	line.cc      = column(COL_CC,96)

	detail.lines[index]=line
	return line
end

-- The best game on the winning side. Nobody is the most valuable player of a
-- match their team lost.
--
-- Every number is scored against the player doing the same job on the other
-- team, because that is the contest actually being fought: your healer against
-- their healer, your damage against theirs. Comparing a healer's healing to a
-- rogue's tells you nothing, and comparing raw totals lets a long match and a
-- short one score differently for the same performance.
--
-- Each comparison lands between 0 and 1, where 0.5 is dead even, so a healer's
-- score and a damage dealer's remain comparable on the same team.

-- No healing specialization exists for these, so a large healing number from
-- one of them is self-healing and nothing else.
local NEVER_HEALS = {
	DEATHKNIGHT=true, HUNTER=true, MAGE=true, ROGUE=true, WARLOCK=true, WARRIOR=true,
}

-- A healer out-heals their own damage several times over. Enhancement shamans
-- and feral druids can edge past their own damage while playing damage, so
-- edging past it is not enough to be called a healer.
local HEALER_RATIO = 2

-- The role as the client gave it, where it did. Older matches have neither a
-- role nor a spec, so there the numbers have to answer it.
local function RoleOf(player)
	if player.role then return player.role end

	local spec=tonumber(player.spec)
	if spec then
		if ns.SPEC_ROLE and ns.SPEC_ROLE[spec] then return ns.SPEC_ROLE[spec] end
		if GetSpecializationRoleByID then
			local role=GetSpecializationRoleByID(spec)
			if role then return role end
		end
	end

	if NEVER_HEALS[player.c] then return "DAMAGER" end
	if (tonumber(player.heal) or 0)>(tonumber(player.dmg) or 0)*HEALER_RATIO then return "HEALER" end
	return "DAMAGER"
end

local function IsHealer(player)
	return RoleOf(player)=="HEALER"
end

local function MostValuable(match)
	local side=(match.w==false) and match.theirs or match.mine
	if not side then return nil end
	local other=(side==match.mine) and match.theirs or match.mine

	-- The best of one stat among the other team's players doing that same job.
	local function opposite(healer,key)
		local matching,anyone=0,0
		for _,player in ipairs(other or {}) do
			local value=tonumber(player[key]) or 0
			if value>anyone then anyone=value end
			if IsHealer(player)==healer and value>matching then matching=value end
		end

		-- No opposite number at all -- they brought two damage dealers against
		-- a healer -- so the whole enemy team stands in for one.
		return (matching>0) and matching or anyone
	end

	-- Damage taken is the one stat not measured against your opposite number.
	-- Soaking is a contest with whoever the other side actually focused, and
	-- that is rarely the person doing your job -- a healer's soak measured
	-- against the enemy healer's flatters both of them.
	-- Taking a beating is worth what it bought, and dying is not buying much.
	-- The rule exists because soaking pressure and living through it is work,
	-- so a soak that ended in the graveyard keeps half of it.
	local function SoakValue(player,share)
		if Deaths(player)>0 then return share*0.5 end
		return share
	end

	local function heaviest(key)
		local top=0
		for _,player in ipairs(other or {}) do
			top=math.max(top,tonumber(player[key]) or 0)
		end
		return top
	end

	local function against(mine,theirs)
		local total=mine+theirs
		-- Nobody did any: nobody earns anything. This used to pay out half a
		-- share to both sides, which meant two healers who landed no crowd
		-- control between them each banked a third of a point for it.
		if total<=0 then return 0 end
		return mine/total
	end

	local best,bestScore
	for _,player in ipairs(side) do
		local healer=IsHealer(player)
		local damageWeight =healer and MVP_WEIGHT_SECONDARY or MVP_WEIGHT_PRIMARY
		local healingWeight=healer and MVP_WEIGHT_PRIMARY or MVP_WEIGHT_SECONDARY

		local score=
			damageWeight     *against(tonumber(player.dmg) or 0,opposite(healer,"dmg"))+
			healingWeight    *against(tonumber(player.heal) or 0,opposite(healer,"heal"))+
			MVP_WEIGHT_CC    *against(tonumber(player.cc) or 0,opposite(healer,"cc"))+
			MVP_WEIGHT_SOFT_CC*against(tonumber(player.soft) or 0,opposite(healer,"soft"))+
			MVP_WEIGHT_TAKEN *SoakValue(player,against(tonumber(player.taken) or 0,heaviest("taken")))+
			MVP_WEIGHT_DECISIVE*(tonumber(player.decisive) or 0)-
			MVP_PENALTY_DEATH*Deaths(player)

		if not bestScore or score>bestScore then best,bestScore=player,score end
	end

	return best
end

local function ShowDetail(row,match)
	if not row.detail then
		local detail=CreateFrame("Frame",nil,row)
		detail:SetPoint("TOPLEFT",row,"TOPLEFT",16,-ROW_HEIGHT-4)
		detail:SetPoint("RIGHT",row,"RIGHT",-8,0)
		detail.lines={}

		-- Sunk slightly so an open match reads as part of its row rather than
		-- as more rows.
		detail.backdrop=detail:CreateTexture(nil,"BACKGROUND")
		detail.backdrop:SetPoint("TOPLEFT",detail,"TOPLEFT",-6,4)
		detail.backdrop:SetPoint("BOTTOMRIGHT",detail,"BOTTOMRIGHT",6,-4)
		Fill(detail.backdrop,0,0,0,0.35)

		-- One label per column, at that column's offset.
		local function header(x,text,width,justify)
			local label=detail:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
			label:SetPoint("BOTTOMLEFT",detail,"TOPLEFT",x,2)
			label:SetTextColor(0.5,0.5,0.5)
			-- Right-aligned over a right-aligned column, so the heading sits
			-- above its own numbers rather than off to their left.
			if width then label:SetWidth(width) end
			label:SetJustifyH(justify or "LEFT")
			label:SetText(text)
			return label
		end

		header(COL_NAME,L.HISTORY_HEAD_PLAYER)
		header(COL_KD-8-DELTA_WIDTH-6-RANK_WIDTH,L.HISTORY_HEAD_RATING,RANK_WIDTH,"RIGHT")
		header(COL_KD,L.HISTORY_HEAD_KD)
		header(COL_DAMAGE,L.HISTORY_HEAD_DAMAGE)
		header(COL_HEALING,L.HISTORY_HEAD_HEALING)
		header(COL_TAKEN,L.HISTORY_HEAD_TAKEN)
		header(COL_CC,L.HISTORY_HEAD_CC)

		-- Between your side and theirs.
		detail.divider=detail:CreateTexture(nil,"ARTWORK")
		detail.divider:SetHeight(1)
		Fill(detail.divider,1,1,1,0.12)

		-- What the match was, under what everyone did in it.
		detail.summary=detail:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
		detail.summary:SetPoint("TOPLEFT",detail,"TOPLEFT",0,0)
		detail.summary:SetTextColor(0.6,0.6,0.6)

		row.detail=detail
	end

	local detail=row.detail
	local decisive=DecisiveDeath(match)
	local mvp=MostValuable(match)
	local index=0

	-- Your side first, then theirs, so the reading order matches the row above.
	for side,team in ipairs({match.mine,match.theirs}) do
		for _,player in ipairs(team or {}) do
			index=index+1
			local line=DetailLine(detail,index)

			line.icon:SetTexture(CLASS_ICONS)
			local coords=CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[player.c]
			if coords then line.icon:SetTexCoord(unpack(coords)) end

			-- Anyone who died is marked in red, icon and name both.
			local died=Deaths(player)>0
			local colour=RAID_CLASS_COLORS and RAID_CLASS_COLORS[player.c]

			if died then
				line.icon:SetVertexColor(1,0.3,0.3)
				line.name:SetTextColor(1,0.3,0.3)
			else
				line.icon:SetVertexColor(1,1,1)
				line.name:SetTextColor(colour and colour.r or 1,colour and colour.g or 1,colour and colour.b or 1)
			end

			local hasSkull=decisive~=nil and player==decisive
			line.skull:SetShown(hasSkull)

			line.role:SetTexCoord(RoleCoords(RoleOf(player)))
			local specIcon=SpecIcon(player)
			line.spec:SetTexture(specIcon)
			line.spec:SetShown(specIcon~=nil)
			-- A ladder place after the name where there is one. Losing to a rank
			-- forty team is a different thing from losing, and the rating alone
			-- does not say which happened.
			local label=(player==mvp) and L.HISTORY_MVP:format(player.n or "?") or (player.n or "?")
			local bracket=ns.ViewBracket()

			-- What was recorded at the time, in preference to what is true now.
			-- Only rows written before matches carried a stamp fall through to
			-- a live lookup.
			local ladder
			if player.lr then
				ladder={ rank=player.lr, rating=player.lv }
			else
				ladder=ns.LadderEntry and ns.LadderEntry(bracket,player.n)
			end

			-- Your own place comes from the game rather than the scrape.
			--
			-- The ladder file stops at Rival, so anybody below it -- which in
			-- 2v2 means everybody under 1787, usually including you -- is
			-- simply not in there to look up. For yourself there is no need to:
			-- GetPersonalRatedInfo knows your rating and your rank outright.
			if not ladder and IsMe(player.n) and GetPersonalRatedInfo then
				local rating=GetPersonalRatedInfo(bracket)
				local rank=tonumber(select(11,GetPersonalRatedInfo(bracket)))
				rating=tonumber(rating)

				if rating and rating>0 and rank and rank>0 then
					ladder={ rank=rank, rating=rating }
				end
			end

			local standing=""
			if ladder then
				-- Coloured by the title the place is worth, the same way the
				-- ladder window and the cutoffs box colour it.
				local hex=(ns.RankHex and ns.RankHex(bracket,ladder)) or "ff8000"
				standing=L.HISTORY_LADDER:format(hex,ladder.rank or 0)

				-- And what they are rated, which is the thing the place is a
				-- consequence of. A rank on its own says where somebody stands
				-- among the people above the cutoff; the rating says what
				-- beating them was worth.
				--
				-- Their rating now, not their rating during this match: the
				-- ladder holds one figure per character and nothing records
				-- where they stood on a given evening.
				if ladder.rating then
					standing=standing..L.HISTORY_LADDER_RATING:format(ladder.rating)
				end
			end
			-- A dash, not a blank. Most people in most matches are below where
			-- the published ladder stops -- 1108 in 2v2, 864 in 3v3 -- so an
			-- empty cell here is the common case, and an empty cell reads as
			-- something that failed rather than something that was answered.
			line.rank:SetText(standing~="" and standing or L.HISTORY_LADDER_NONE)

			-- Only somebody who is on it can be found on it.
			line.rankHit.ladderName=ladder and player.n or nil
			line.rankHit.ladderBracket=bracket

			-- What the row is about, for the copy box. The recorded name
			-- carries its realm already.
			line.nameHit.copyName=player.n
			line.rankHit:EnableMouse(ladder~=nil)

			-- What the match cost or paid that player.
			--
			-- Everyone's, not only yours: the arena scoreboard carries a rating
			-- change per player and the recording now reads it. Your own falls
			-- back to the rating watcher's number for matches recorded before
			-- that, so old rows keep the one line they always had.
			local delta=tonumber(player.rc)
			if not delta and IsMe(player.n) then delta=match.d end

			-- Nothing recorded, but the others in this match have numbers: the
			-- old rule dropped zeroes, so that is what this was.
			if not delta and HasDeltas(match) then delta=0 end

			if delta then
				local hex=(delta>0 and "1eff00") or (delta<0 and "ff2020") or "b3b3b3"
				line.delta:SetText(L.HISTORY_DELTA:format(hex,delta))
			else
				line.delta:SetText("")
			end

			-- The name gives up the skull's width when there is one, so the
			-- skull always has somewhere to stand: without this a long name
			-- fills the field and the skull lands on the ladder column.
			local room=line.nameWidth-(hasSkull and (SKULL_SIZE+4) or 0)
			line.name:SetWidth(room)
			line.name:SetText(label)

			if hasSkull then
				-- GetStringWidth measures the whole string, clipped or not, so
				-- it is capped at what the field actually shows.
				local used=math.min(line.name:GetStringWidth(),room)
				line.skull:ClearAllPoints()
				line.skull:SetPoint("LEFT",line.name,"LEFT",used+4,0)
			end
			line.kd:SetText(L.HISTORY_DETAIL_KD:format(player.k or 0,Deaths(player)))

			local duration=match.dur
			if duration and duration>0 then
				line.damage:SetText(L.HISTORY_DETAIL_RATE:format(Number(player.dmg),Number((player.dmg or 0)/duration)))
				line.healing:SetText(L.HISTORY_DETAIL_RATE:format(Number(player.heal),Number((player.heal or 0)/duration)))
			else
				line.damage:SetText(Number(player.dmg))
				line.healing:SetText(Number(player.heal))
			end

			-- Seconds of hard crowd control landed, and taken. Only matches
			-- recorded here have it: nothing was tracking it before.
			-- Seconds, then how many landed. A high count against few seconds is
			-- crowd control that kept being broken early, which is worth seeing.
			-- Damage taken, from the combat log rather than the scoreboard.
			local hurt=tonumber(player.taken) or 0
			if hurt>0 then
				if duration and duration>0 then
					line.taken:SetText(L.HISTORY_DETAIL_RATE:format(Number(hurt),Number(hurt/duration)))
				else
					line.taken:SetText(Number(hurt))
				end
			else
				line.taken:SetText(L.RATED_NONE)
			end

			-- Seconds landed and seconds sat in, one column again. The counts
			-- are still recorded; they are simply not worth the width.
			if player.cc or player.ccTaken then
				line.cc:SetText(L.HISTORY_DETAIL_CC:format(
					math.floor((player.cc or 0)+0.5),math.floor((player.ccTaken or 0)+0.5)))
			else
				line.cc:SetText(L.RATED_NONE)
			end

			line:Show()

			if side==1 then detail.lastMine=index end
		end
	end

	for extra=index+1,#detail.lines do
		detail.lines[extra]:Hide()
	end

	-- The divider sits under the last of your own.
	if detail.lastMine and detail.lastMine<index then
		detail.divider:ClearAllPoints()
		detail.divider:SetPoint("TOPLEFT",detail,"TOPLEFT",0,-detail.lastMine*DETAIL_ROW)
		detail.divider:SetPoint("RIGHT",detail,"RIGHT",0,0)
		detail.divider:Show()
	else
		detail.divider:Hide()
	end

	-- Length, arena, and who carried it -- the things about the match rather
	-- than about one player in it.
	local parts={}
	if match.dur and match.dur>0 then
		parts[#parts+1]=L.HISTORY_SUMMARY_LENGTH:format(math.floor(match.dur/60),match.dur%60)
	end
	if match.map then parts[#parts+1]=match.map end

	-- A match with nobody on the other side was never watched: the arena units
	-- can only be read from inside the arena, so a disconnect leaves your own
	-- name and nothing else. The rating change is still real, which is why the
	-- match is kept -- said plainly, so a row of zeroes reads as absence rather
	-- than as a tracker that lost them.
	if Incomplete(match) then
		parts[#parts+1]=L.HISTORY_SUMMARY_INCOMPLETE
	elseif match.left then
		-- Everything up to the moment you walked out is real; what is missing is
		-- whatever happened after. Worth saying, because the rating changes on
		-- the other players read zero -- the scoreboard only fills those in once
		-- the match is decided, and by then you were not there to read it.
		parts[#parts+1]=L.HISTORY_SUMMARY_LEFT
	end

	if Mixed(match,ns.ViewBracket()) then
		parts[#parts+1]=L.HISTORY_SUMMARY_MIXED
	end

	detail.summary:ClearAllPoints()
	detail.summary:SetPoint("TOPLEFT",detail,"TOPLEFT",0,-index*DETAIL_ROW-2)
	detail.summary:SetText(table.concat(parts,"   |cff808080-|r   "))
	detail.summary:SetShown(#parts>0)

	local summaryHeight=(#parts>0) and DETAIL_ROW or 0
	detail:SetHeight(math.max(1,index*DETAIL_ROW+summaryHeight))
	detail:Show()

	-- Row height: the line itself, the header above the block, the players and
	-- the summary under them.
	return ROW_HEIGHT+14+index*DETAIL_ROW+summaryHeight+6
end

local function CreateRow(parent,index,withDate)
	local row=CreateFrame("Button",nil,parent)
	row:SetHeight(ROW_HEIGHT)
	row:SetPoint("TOPLEFT",parent,"TOPLEFT",0,-(index-1)*ROW_HEIGHT)
	row:SetPoint("RIGHT",parent,"RIGHT",0,0)
	row:Hide()

	if withDate then
		row.toggle=row:CreateTexture(nil,"ARTWORK")
		row.toggle:SetSize(TOGGLE_SIZE,TOGGLE_SIZE)
		row.toggle:SetPoint("TOPLEFT",row,"TOPLEFT",2,-3)
		row.toggle:SetTexture(PLUS_TEXTURE)

		row.date=row:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
		row.date:SetPoint("TOPLEFT",row,"TOPLEFT",TOGGLE_SIZE+6,-2)
		row.date:SetWidth(DATE_WIDTH-TOGGLE_SIZE-10)
		row.date:SetJustifyH("LEFT")
		row.date:SetTextColor(0.7,0.7,0.7)
	end

	row.rating=row:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
	row.rating:SetPoint("TOPLEFT",row,"TOPLEFT",(withDate and DATE_WIDTH or 0)+2,-2)
	row.rating:SetWidth(RATING_WIDTH-4)
	row.rating:SetJustifyH("LEFT")

	row.vs=row:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
	row.vs:SetText(L.HISTORY_VS)
	row.vs:SetTextColor(0.5,0.5,0.5)

	row.mine,row.theirs={},{}
	for slot=1,5 do
		row.mine[slot]=CreateSlot(row)
		row.theirs[slot]=CreateSlot(row)
	end

	-- Map and length, in the space the comps leave behind. Only in the full
	-- window: the list beside the Rated page is three hundred wide, and a column
	-- at four hundred would hang out past its edge.
	--
	-- Both were recorded already and only visible once a match was opened, so
	-- half the width of this window was carrying nothing while the answer to
	-- "which map, how long" sat one click away on every row.
	--
	-- Fixed offsets rather than trailing the comps: a 2v2 leaves the icons far
	-- shorter than a 5v5, and columns that slide about with the bracket are
	-- harder to read down than columns that stay put.
	if withDate then
		row.map=row:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
		row.map:SetPoint("TOPLEFT",row,"TOPLEFT",MAP_X,-2)
		row.map:SetWidth(MAP_WIDTH)
		row.map:SetJustifyH("LEFT")
		row.map:SetWordWrap(false)
		row.map:SetTextColor(0.62,0.62,0.62)

		row.length=row:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
		row.length:SetPoint("TOPLEFT",row,"TOPLEFT",MAP_X+MAP_WIDTH+14,-2)
		row.length:SetWidth(110)
		row.length:SetJustifyH("LEFT")
		row.length:SetTextColor(0.52,0.52,0.52)
	end

	row.dot=row:CreateTexture(nil,"ARTWORK")
	row.dot:SetSize(8,8)
	row.dot:SetPoint("TOPRIGHT",row,"TOPRIGHT",-2,-6)

	-- Every other row a shade lighter, so the eye can hold a line across the
	-- width of the window. The same reasoning as the ladder, and the same very
	-- low alpha: felt rather than seen.
	--
	-- Below both the hover highlight and the selection tint, so a striped row
	-- that is also the open one still reads as open.
	row.stripe=row:CreateTexture(nil,"BACKGROUND",nil,-8)
	row.stripe:SetAllPoints()
	Fill(row.stripe,1,1,1,0.025)
	row.stripe:Hide()

	local highlight=row:CreateTexture(nil,"HIGHLIGHT")
	highlight:SetAllPoints()
	Fill(highlight,1,1,1,0.08)

	-- Only the short list marks its selection, where that mark is the only sign
	-- of what the other window is showing. In the full window the match is
	-- already unmistakable -- it is the open one -- so a tint on top of that is
	-- just noise.
	if not withDate then
		row.selected=row:CreateTexture(nil,"BACKGROUND")
		row.selected:SetAllPoints()
		Fill(row.selected,1,1,0,0.25)
		row.selected:Hide()
	end

	return row
end

----------------------------------------------------------------
-- The list beside the panel
----------------------------------------------------------------

-- How the glow behind your current title is sized. Settled by eye against a
-- four digit rating on an eighteen pixel line: tight enough to read as a halo
-- on the number rather than a band across the row, and clear of the lines above
-- and below.
--
-- The lift is there because the art sits low inside its own bounds -- centred
-- honestly, it looks like an underline.
-- The PvP panel's atlas fades left and right but ends flat top and bottom.
-- Unnoticeable at forty-six pixels, and on an eighteen pixel line that edge
-- lands under the digits and looks sliced off however it is sized -- taller
-- only made it a bigger slice.
--
-- So the cutoffs box uses the action button glow instead, which is soft on all
-- four sides, added rather than blended so it lights the number rather than
-- washing it out.
-- The width follows the number itself -- measured each redraw and padded --
-- so a four figure rating gets a wider glow than a three figure one without
-- anything being told about it.
--
-- x and y are a fixed nudge for the art rather than the text: this texture is
-- drawn to surround a button and does not sit centred inside its own bounds.
-- The quest title highlight, which is the one shape that survives being made
-- wide and short.
--
-- The PvP panel's atlas fades sideways but ends flat top and bottom, so on an
-- eighteen pixel line that edge lands under the digits and looks sliced off at
-- every size. The action button border is worse: it is drawn for a square
-- button, so squashing it flat distorts its corners into notches. This one is
-- made to sit behind a line of text and has no corner detail to ruin.
--
-- Faint on purpose. At forty-five per cent it reads as the row being lit; much
-- above that and it is a green bar sitting on top of the number.
local GLOW = {
	texture = "Interface\\QuestFrame\\UI-QuestTitleHighlight",
	height  = 18,
	pad     = 7,
	x       = 0,
	y       = 0,
	alpha   = 0.45,
}

-- Won and lost across a run of matches, newest first, read the way the row
-- squares are: the recorded outcome where there is one, and the points only
-- standing in where there is not. A loss can cost nothing and still be a loss,
-- and half the rows on the panel are worth nothing.
--
-- No limit means everything recorded, which is what the full window wants.
local function Record(list,limit)
	local won,lost=0,0
	local count=limit and math.min(limit,#list) or #list

	for index=1,count do
		local match=list[#list-index+1]
		if match then
			local result=match.w
			if result==nil then
				local delta=match.d or 0
				if delta>0 then result=true elseif delta<0 then result=false end
			end

			if result==true then won=won+1 elseif result==false then lost=lost+1 end
		end
	end

	return won,lost
end

-- Shared so the ladder's region buttons can redraw the cutoffs box beside it:
-- the two read the same region and must not be left disagreeing.
local Refresh

-- Wrapped rather than handed over directly: Refresh is only filled in below,
-- and a handle taken now would capture the nil.
function ns.RefreshRatedPanel()
	if Refresh then Refresh() end
end

function Refresh()
	if not panel then return end

	local bracket=SelectedBracket()
	panel.title:SetText(L.HISTORY_WINDOW_TITLE:format(PANEL_ROWS,BRACKET_NAMES[bracket] or "?"))

	if panel.season then
		local seasonBest,seasonPlayed
		if GetPersonalRatedInfo then
			local _,best,_,played=GetPersonalRatedInfo(bracket)
			seasonBest,seasonPlayed=tonumber(best) or 0,tonumber(played) or 0
		end

		if (seasonBest or 0)>0 or (seasonPlayed or 0)>0 then
			panel.season.value:SetText(L.HISTORY_BEST_VALUE:format(
				ns.ColouredRating(bracket,seasonBest),seasonPlayed))
		else
			panel.season.value:SetText(L.RATED_NONE)
		end
	end

	if panel.cutoffs then
		-- Whichever region the ladder is showing, so the two never disagree.
		-- Back to yours on its own whenever the bracket changes.
		local byRegion=ns.ViewCutoffs and ns.ViewCutoffs() or ns.CUTOFFS
		local slotsByRegion=ns.ViewCutoffSlots and ns.ViewCutoffSlots() or ns.CUTOFF_SLOTS

		local cutoffs=byRegion and byRegion[bracket]
		panel.cutoffs.title:SetText(L.CUTOFF_TITLE:format(BRACKET_NAMES[bracket] or "?")
			..L.REGION_TAG:format((ns.RegionFlagMarkup and ns.RegionFlagMarkup(ns.ViewRegion(),11))
				or ns.RegionShort()))

		local slots=slotsByRegion and slotsByRegion[bracket]

		local y=-28
		for _,row in ipairs(panel.cutoffs.rows) do
			local rating=cutoffs and cutoffs[row.tier.key]
			local places=slots and slots[row.tier.key]

			-- Gladiator does not exist in rated battlegrounds, so the row is
			-- taken out rather than shown empty -- and the rows below it move
			-- up to close the gap, which is why the position is set here rather
			-- than once when they were made.
			if not ns.TierApplies(row.tier,bracket) then
				row.label:Hide()
				row.value:Hide()
				row.spots:Hide()
			else
				row.label:Show()
				row.value:Show()
				row.spots:Show()

				row.label:SetPoint("TOPLEFT",panel.cutoffs.frame,"TOPLEFT",14,y)
				row.value:SetPoint("TOPRIGHT",panel.cutoffs.frame,"TOPRIGHT",-14-CUTOFF_SPOTS_WIDTH,y)
				row.spots:SetPoint("TOPRIGHT",panel.cutoffs.frame,"TOPRIGHT",-14,y)
				y=y-18

				-- Hero of the Alliance or the Horde where the arena says rank
				-- one.
				row.label:SetText(ns.TierName(row.tier,bracket))
			end

			if rating and rating>0 then
				row.value:SetText(L.CUTOFF_VALUE:format(row.tier.hex,rating))
			else
				-- Rated battlegrounds have no Gladiator, and a bracket nobody
				-- has played has no ladder to cut.
				row.value:SetText(L.RATED_NONE)
			end

			-- Only where the title is a fixed number of places. Duelist and
			-- below are a share of the ladder, so there is nothing to count.
			if rating and rating>0 and places and places>0 then
				row.spots:SetText(L.CUTOFF_SPOTS:format(places))
			else
				row.spots:SetText("")
			end
		end

		-- Sized to the rows that were actually drawn, so rated battlegrounds --
		-- which have no Gladiator -- do not leave a row's worth of empty box
		-- under Challenger.
		--
		-- From the same y the rows were placed with rather than by counting
		-- them again: one number decides both, so the box cannot end up
		-- disagreeing with its own contents.
		panel.cutoffs.frame:SetHeight(-y+CUTOFF_PAD)

		-- The nearest title still above you, and what it costs.
		--
		-- Only against your own region: your rating measured against another
		-- region's cutoffs is a sentence that reads like fact and is not one.
		-- The tier list runs highest first, so it is walked backwards to find
		-- the cheapest one you have not already got.
		-- Everything below this line measures *you* against these numbers --
		-- the title you hold, the one you are climbing towards, the glow on the
		-- row. None of that means anything against another region's ladder, so
		-- on a region that is not yours your rating counts as absent and all of
		-- it falls away together.
		local mine=(ns.ViewingOwnRegion==nil) or ns.ViewingOwnRegion()

		local rating=RatedInfo and select(1,RatedInfo(bracket))
		if not rating and GetPersonalRatedInfo then rating=GetPersonalRatedInfo(bracket) end
		rating=mine and (tonumber(rating) or 0) or 0

		local wanted,needed
		if cutoffs then
			for index=#(ns.TIERS or {}),1,-1 do
				local tier=ns.TIERS[index]
				local cutoff=ns.TierApplies(tier,bracket) and cutoffs[tier.key]
				if cutoff and cutoff>rating then
					wanted,needed=tier,cutoff-rating
					break
				end
			end
		end

		-- The title you currently hold, lit the way the PvP panel lights your
		-- rank: the highest one your rating has actually reached.
		--
		-- One glow serves the whole box rather than one per row, because only
		-- ever one line is yours -- and the texture is keyed on the frame that
		-- owns it, so asking for it on a different row moves it rather than
		-- leaving the old one behind.
		local held
		if cutoffs and rating>0 then
			for _,tier in ipairs(ns.TIERS or {}) do
				local cutoff=ns.TierApplies(tier,bracket) and cutoffs[tier.key]
				if cutoff and cutoff>0 and rating>=cutoff then
					held=tier
					break
				end
			end
		end

		local lit
		for _,row in ipairs(panel.cutoffs.rows) do
			if held and row.tier==held then lit=row.value end
		end

		-- Sized to the number rather than to the row: a cutoff is four digits
		-- wide and a glow only as wide as the line is tall reads as a smudge
		-- under it rather than a halo around it.
		--
		-- Lifted a little because the art sits low inside its own bounds, and
		-- drawn in ARTWORK because this box has a background of its own that
		-- would otherwise cover it.
		if ns.SetGlow then
			local width=lit and lit.GetStringWidth and lit:GetStringWidth() or 0
			ns.SetGlow(panel.cutoffs.frame,lit,held and held.hex or nil,{
				texture  = GLOW.texture,
				alpha    = GLOW.alpha,
				x        = GLOW.x,
				height   = GLOW.height,
				-- The floor is only there to stop a missing string width
				-- collapsing the glow to nothing. It used to be 46, which is
				-- wider than a four digit rating plus a sensible margin -- so
				-- every padding below about sixteen came out identical and the
				-- setting looked broken.
				width    = math.max(20,width+GLOW.pad),
				y        = GLOW.y,
				layer    = "ARTWORK",
				sublevel = -1,
			})
		end

		if not mine then
			-- Blank while looking at somebody else's ladder. "You need 43 more"
			-- against another region's cutoff is a statement of fact that is
			-- not one, and it is the line most likely to be believed.
			panel.cutoffs.next:SetText("")
		elseif wanted then
			-- Named through the same helper as the rows, or climbing towards
			-- the top of a rated battleground ladder would read "+180 to Rank
			-- one" against a row that says Hero of the Faction.
			panel.cutoffs.next:SetText(L.CUTOFF_NEXT:format(wanted.hex,needed,
				ns.TierName(wanted,bracket)))
		elseif rating>0 and cutoffs then
			-- Above every cutoff there is.
			panel.cutoffs.next:SetText(L.CUTOFF_NEXT_TOP)
		else
			panel.cutoffs.next:SetText("")
		end

		if panel.cutoffs.source then
			-- When a cutoff last moved, not when the scraper last looked.
			--
			-- The two were the other way round while this was David's own copy,
			-- refreshed twice a day: "checked" was the honest answer to "is this
			-- current". Published, it is not -- everyone else has whatever came
			-- with the last release, and there is no release unless a number
			-- changed. So the change date is both the more useful fact and the
			-- only one that is true for them.
			local read=byRegion and (byRegion.updated or byRegion.checked)
			panel.cutoffs.source:SetText(L.CUTOFF_SOURCE:format(read or "?"))
		end
	end

	local list=Trimmed(bracket)
	local shown=0

	-- Across exactly the matches listed below, since that is what the heading
	-- promises.
	if panel.record then
		panel.record:SetText(L.HISTORY_RECORD:format(Record(list,PANEL_ROWS)))
	end

	for index=1,PANEL_ROWS do
		-- Newest at the top.
		local match=list[#list-index+1]
		local row=rows[index]
		ShowMatch(row,match)

		if row.stripe then row.stripe:SetShown(index%2==0) end

		-- The match being looked at in the full window is marked here too, so
		-- the two lists agree about which one that is.
		if row.selected then
			row.selected:SetShown(match~=nil and selectedAt~=nil and match.at==selectedAt)
		end
		if match then shown=shown+1 end
	end

	panel.empty:SetShown(shown==0)

	-- The ladder follows the bracket this list is on, so switching rows on the
	-- Rated page changes what it is showing rather than leaving it on whatever
	-- was selected when it was opened.
	if ns.RefreshLadder then ns.RefreshLadder() end
end

----------------------------------------------------------------
-- The whole lot, in a window
----------------------------------------------------------------

-- Midnight this morning, as the clock the timestamps were written by.
--
-- Built from the calendar day rather than by rounding the epoch: seconds since
-- 1970 divide evenly into days only at UTC midnight, which is the middle of the
-- afternoon here and would have called the last few hours "yesterday".
local function StartOfToday()
	local now=date("*t")
	return time({ year=now.year, month=now.month, day=now.day, hour=0, min=0, sec=0 })
end

-- What today has done to you: won, lost, and the rating across all of it.
--
-- A session is the thing you actually want to know about after an evening of
-- games, and the stamp on each match already says which day it belongs to, so
-- nothing has to be tracked as you play.
local function Today(list)
	local since=StartOfToday()
	local won,lost,delta,games=0,0,0,0

	for index=#list,1,-1 do
		local match=list[index]
		-- Newest first, so the first one older than this morning ends it.
		if not match or (match.at or 0)<since then break end

		games=games+1
		delta=delta+(match.d or 0)

		local result=match.w
		if result==nil then
			local moved=match.d or 0
			if moved>0 then result=true elseif moved<0 then result=false end
		end
		if result==true then won=won+1 elseif result==false then lost=lost+1 end
	end

	return games,won,lost,delta
end

-- Set only when the window is being opened *at* a particular match, from the
-- side list. Expanding a row inside the window is not that, and jumping the
-- list under the cursor when you click something already in front of you is
-- disorienting -- the row you clicked leaves the spot you clicked it in.
local scrollToSelection=false

local function RefreshFull()
	if not window then return end

	local bracket=ns.ViewBracket()
	window.title:SetText(L.HISTORY_FULL_TITLE:format(BRACKET_NAMES[bracket] or "?"))

	local list=Trimmed(bracket)
	local content=window.content

	if window.record then
		window.record:SetText(L.HISTORY_RECORD:format(Record(list)))
	end
	if window.total then
		window.total:SetText(L.HISTORY_TOTAL:format(#list))
	end

	if window.UpdateBrackets then window.UpdateBrackets() end

	if window.today then
		-- Hidden on a day with no games rather than shown as "today 0/0",
		-- which is a line that says nothing and still takes up the room.
		local games,won,lost,delta=Today(list)
		if games>0 then
			local hex=(delta>0 and "1eff00") or (delta<0 and "ff2020") or "b3b3b3"
			window.today:SetText(L.HISTORY_TODAY:format(won,lost,
				("|cff%s%+d|r"):format(hex,delta)))
			window.today:Show()
		else
			window.today:Hide()
		end
	end

	-- Stacked rather than placed at fixed multiples of the row height: an
	-- expanded match is as tall as the number of players it had.
	local y,focused=0,nil

	for index=1,#list do
		local match=list[#list-index+1]   -- newest first
		local row=fullRows[index]
		if not row then
			row=CreateRow(content,index,true)
			row:SetScript("OnClick",function(self)
				if not self.match then return end
				-- Clicking the open one closes it again. Written out rather
				-- than as "a and nil or b", which in Lua always yields b and
				-- so could never close anything.
				if selectedAt==self.match.at then
					selectedAt=nil
				else
					selectedAt=self.match.at
				end
				RefreshFull()
				Refresh()
			end)
			fullRows[index]=row
		end

		local open=(selectedAt~=nil and match.at==selectedAt)
		ShowMatch(row,match,open)

		-- Counted by position on screen, not by the match's place in the
		-- season, so the banding stays still while the list is scrolled.
		--
		-- Never on the open one: that row grows to hold the detail below it and
		-- the stripe grows with it, tinting the whole expanded block instead of
		-- a single line.
		if row.stripe then row.stripe:SetShown(index%2==0 and not open) end

		row:ClearAllPoints()
		row:SetPoint("TOPLEFT",content,"TOPLEFT",0,-y)
		row:SetPoint("RIGHT",content,"RIGHT",0,0)

		local height=ROW_HEIGHT
		if open then
			height=ShowDetail(row,match)
			focused=y
		elseif row.detail then
			row.detail:Hide()
		end

		if row.toggle then
			row.toggle:SetTexture(open and MINUS_TEXTURE or PLUS_TEXTURE)
		end

		row:SetHeight(height)
		if row.selected then row.selected:SetShown(open) end
		y=y+height
	end

	for index=#list+1,#fullRows do
		fullRows[index]:Hide()
	end

	content:SetHeight(math.max(1,y))
	window.empty:SetShown(#list==0)

	-- Only when asked, and once.
	if focused and scrollToSelection then
		local range=window.scroll:GetVerticalScrollRange() or 0
		window.scroll:SetVerticalScroll(math.min(focused,range))
	end
	scrollToSelection=false
end

local function CreateWindow()
	if window then return window end

	-- No test for the side list any more. It used to refuse to build without
	-- one, which was right while this hung off it -- but from the minimap the
	-- list may never have been created, so the window silently failed to open
	-- and the click looked dead.
	--
	-- On UIParent and re-homed when it opens, for the same reason the ladder is:
	-- a child of the panel is a child of the PvP frame, and opened from the
	-- minimap with that closed it would be shown inside something hidden.
	local frame=CreateFrame("Frame","ArenaPlus_ArenaHistoryFull",UIParent,"BackdropTemplate")
	-- 850x460 at 1.15 wants 978x529, which does not fit a 1280x720 screen
	-- or a high UI Scale. Scaled down only as far as it has to be.
	frame:SetScale(ns.FitScale and ns.FitScale(850,460,SCALE) or SCALE)
	window=frame
	frame:Hide()
	-- Wide enough for the columns an expanded match needs: the healing one
	-- ends around 500 in from the block's left edge.
	frame:SetSize(850,460)
	-- Placed by AnchorFull every time it opens, not here. This used to dock to
	-- the panel at creation, which meant the window was parented to a frame that
	-- can be hidden before anything had decided where it should go.
	ns.PlaceFullWindow(frame)
	frame:SetFrameStrata("DIALOG")
	frame:SetToplevel(true)
	frame:EnableMouse(true)
	ns.StyleAsPanel(frame)

	-- The same dark band the other two windows wear, so all three read as one
	-- addon. Blizzard's header atlases were tried on the ladder and thrown out:
	-- they are painted for a light frame.
	local band=frame:CreateTexture(nil,"BORDER")
	band:SetPoint("TOPLEFT",frame,"TOPLEFT",11,-BAND_INSET)
	band:SetPoint("TOPRIGHT",frame,"TOPRIGHT",-12,-BAND_INSET)
	band:SetHeight(BAND_HEIGHT)
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

	local underline=frame:CreateTexture(nil,"ARTWORK")
	underline:SetPoint("TOPLEFT",band,"BOTTOMLEFT",0,0)
	underline:SetPoint("TOPRIGHT",band,"BOTTOMRIGHT",0,0)
	underline:SetHeight(1)
	underline:SetColorTexture(1,0.82,0,0.35)

	tinsert(UISpecialFrames,"ArenaPlus_ArenaHistoryFull")

	-- Closed is closed: it opens on the top of the list with nothing expanded.
	--
	-- On OnHide rather than in the toggle, because there are four ways out --
	-- the toggle, the close button, Escape, and the other window taking its
	-- place -- and only one of them went through code that knew to tidy up.
	frame:SetScript("OnHide",function(self)
		selectedAt=nil
		if self.scroll then self.scroll:SetVerticalScroll(0) end
		if ns.ClearViewBracket then ns.ClearViewBracket() end
	end)

	frame.title=frame:CreateFontString(nil,"OVERLAY","GameFontHighlightLarge")
	frame.title:SetPoint("LEFT",frame,"TOPLEFT",16,HEADER_MID)

	-- Won and lost over everything recorded, not only the ten on the panel.
	-- Same two colours, so the small number and the big one read the same way.
	frame.record=frame:CreateFontString(nil,"OVERLAY","GameFontNormal")
	-- After the bracket row, wherever that now ends. Written out rather than
	-- guessed at a fixed offset, which is what put this under the tabs when the
	-- row moved along to make room for the swap button.
	frame.record:SetPoint("LEFT",frame,"TOPLEFT",
		BRACKET_X+SWAP_W+SWAP_GAP+(ns.BRACKET_PICKER_WIDTH or 190)+20,HEADER_MID)
	frame.record:SetJustifyH("LEFT")

	-- How many are listed below, which is not always the season's own count:
	-- only a hundred are kept per bracket, and a match recorded before the
	-- outcome could be read counts here without counting as a win or a loss.
	frame.total=frame:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
	frame.total:SetPoint("LEFT",frame.record,"RIGHT",10,0)
	frame.total:SetJustifyH("LEFT")
	frame.total:SetTextColor(0.55,0.55,0.55)

	-- On the right of this one: its heading already carries the record, the
	-- count and today's games, and there is no room left after them.
	frame.UpdateBrackets=ns.BuildBracketPicker(frame,"TOPLEFT",BRACKET_X+SWAP_W+SWAP_GAP,HEADER_TOP)

	-- Today's games, beside the season's. The stamp on each match is what
	-- decides the day, so this needs nothing kept between sessions.
	frame.today=frame:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
	frame.today:SetPoint("LEFT",frame.total,"RIGHT",14,0)
	frame.today:SetJustifyH("LEFT")
	frame.today:SetTextColor(0.75,0.75,0.75)
	frame.today:Hide()

	local close=CreateFrame("Button",nil,frame,"UIPanelCloseButton")
	close:SetPoint("TOPRIGHT",frame,"TOPRIGHT",0,0)

	-- To the ladder, keeping the bracket. The mirror of the button on the other
	-- window, and for the same reason: both windows clear the shared bracket as
	-- they hide, so it is read before the swap and put back after.
	frame.swapButton=CreateFrame("Button",nil,frame,"UIPanelButtonTemplate")
	frame.swapButton:SetSize(SWAP_W,20)
	frame.swapButton:SetText(L.HISTORY_SWAP)
	frame.swapButton:SetPoint("TOPLEFT",frame,"TOPLEFT",BRACKET_X,HEADER_TOP)
	frame.swapButton:SetScript("OnClick",function()
		local bracket=ns.ViewBracket and ns.ViewBracket()

		if ns.ToggleLadder then ns.ToggleLadder() end

		if bracket and ns.SetViewBracket then
			ns.SetViewBracket(bracket)
			if ns.RefreshLadder then ns.RefreshLadder() end
		end
	end)

	frame.empty=frame:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
	frame.empty:SetPoint("TOPLEFT",frame,"TOPLEFT",18,EMPTY_TOP)
	frame.empty:SetTextColor(0.55,0.55,0.55)
	frame.empty:SetText(L.HISTORY_EMPTY)

	local scroll=CreateFrame("ScrollFrame","ArenaPlus_ArenaHistoryScroll",frame,"UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT",frame,"TOPLEFT",16,LIST_TOP)
	-- The 28 the list gave up for the swap button, returned: that button is
	-- in the bracket row now and the foot is empty again.
	scroll:SetPoint("BOTTOMRIGHT",frame,"BOTTOMRIGHT",-36,16)

	local content=CreateFrame("Frame",nil,scroll)
	content:SetSize(790,10)
	scroll:SetScrollChild(content)
	frame.content=content
	frame.scroll=scroll

	frame:SetScript("OnShow",RefreshFull)
	return frame
end

-- The ladder window hangs in the same place as this one and the two take turns,
-- so each needs to be able to put the other away. The panel is what they both
-- anchor to.
function ns.HistoryPanel()
	return panel
end

-- Beside the panel where there is one, centred on the screen where there is not.
local function AnchorFull(frame)
	-- The same spot the ladder uses, through the same helper.
	--
	-- These two are alternatives -- opening one closes the other -- so they
	-- belong in one place rather than two, and putting them there through a
	-- shared function is what keeps them agreeing.
	--
	-- It docked to the panel before, which moved it whenever the Rated page came
	-- or went, and required parenting to a frame that could be hidden.
	ns.PlaceFullWindow(frame)
	return false
end

-- The whole history, from the minimap button rather than from a match row.
--
-- No match is selected: opened this way it is the list that is wanted, not one
-- game expanded, and the rows can still be clicked once it is up.
function ns.ToggleArenaHistory()
	if window and window:IsShown() then
		selectedAt=nil
		window:Hide()
		Refresh()
		return
	end

	local frame=CreateWindow()
	if not frame then return end

	if ns.CloseLadder then ns.CloseLadder() end

	AnchorFull(frame)
	frame:Show()
	RefreshFull()
end

ns.RefreshArenaHistory=function()
	if window and window:IsShown() then RefreshFull() end
end

function ns.CloseArenaHistory()
	if window and window:IsShown() then
		selectedAt=nil
		window:Hide()
		Refresh()
	end
end

----------------------------------------------------------------
-- The panel, and the button beside it
----------------------------------------------------------------

local function CreatePanel()
	if panel then return panel end
	if not PVEFrame then return nil end

	panel=CreateFrame("Frame","ArenaPlus_ArenaHistory",PVEFrame,"BackdropTemplate")
	panel:SetSize(PANEL_WIDTH,36+PANEL_ROWS*ROW_HEIGHT+10+HEADER_HEIGHT)
	-- Flush against the right edge and below the title bar, so it clears both
	-- the frame's border art and its close button.
	-- Top of the frame, so the whole stack -- season best, the list, the cutoffs
	-- underneath -- hangs from the same line the window itself starts on.
	-- Hanging it off the first bracket row instead pushed everything too far
	-- down the screen.
	panel:SetPoint("TOPLEFT",PVEFrame,"TOPRIGHT",PANEL_GAP,0)
	panel:Hide()
	ns.StyleAsPanel(panel)

	panel.title=panel:CreateFontString(nil,"OVERLAY","GameFontNormal")
	panel.title:SetPoint("TOPLEFT",panel,"TOPLEFT",14,-14-HEADER_HEIGHT)

	panel.title:SetTextColor(1,0.82,0)

	-- Won and lost across the same ten, straight after the bracket it belongs
	-- to. The squares down the right already say it match by match; this says it
	-- at a glance, and the two colours mean it needs no label.
	panel.record=panel:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
	panel.record:SetPoint("LEFT",panel.title,"RIGHT",14,0)
	panel.record:SetJustifyH("LEFT")


	-- The second reading sits beside the first rather than replacing it. Two
	-- numbers worked out different ways, and their agreeing is itself the
	-- reason to believe either.
	-- What the row's own tooltip used to say, in the panel that covers it up:
	-- the season's best rating and how many games it took. Straight out of
	-- GetPersonalRatedInfo, so nothing is worked out here.
	local function HeaderLine(y)
		local label=panel:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
		label:SetPoint("TOPLEFT",panel,"TOPLEFT",14,y)
		label:SetTextColor(0.55,0.55,0.55)

		local value=panel:CreateFontString(nil,"OVERLAY","GameFontNormal")
		value:SetPoint("TOPRIGHT",panel,"TOPRIGHT",-14,y+1)
		value:SetJustifyH("RIGHT")

		return { label=label, value=value }
	end

	panel.season=HeaderLine(-11)
	panel.season.label:SetText(L.HISTORY_BEST_SEASON)

	-- Between the header and the list, so the two read as separate things.
	panel.divider=panel:CreateTexture(nil,"ARTWORK")
	panel.divider:SetPoint("TOPLEFT",panel,"TOPLEFT",10,-HEADER_HEIGHT-2)
	panel.divider:SetPoint("TOPRIGHT",panel,"TOPRIGHT",-10,-HEADER_HEIGHT-2)
	panel.divider:SetHeight(1)
	Fill(panel.divider,1,1,1,0.10)

	-- The season's title cutoffs for whichever bracket is selected, in a box of
	-- its own directly under the list. The numbers come from the companion
	-- script that reads Blizzard's API, so they are the live ladder rather than
	-- anything worked out here.
	local cutoffs=CreateFrame("Frame",nil,panel,"BackdropTemplate")
	cutoffs:SetPoint("TOPLEFT",panel,"BOTTOMLEFT",0,CUTOFF_LIFT)
	cutoffs:SetPoint("TOPRIGHT",panel,"BOTTOMRIGHT",0,CUTOFF_LIFT)
	cutoffs:SetHeight(CUTOFF_HEIGHT)
	ns.StyleAsPanel(cutoffs)

	panel.cutoffs={ frame=cutoffs }
	panel.cutoffs.title=cutoffs:CreateFontString(nil,"OVERLAY","GameFontNormal")
	panel.cutoffs.title:SetPoint("TOPLEFT",cutoffs,"TOPLEFT",14,-10)
	panel.cutoffs.title:SetTextColor(1,0.82,0)

	-- What the next title costs from where you are, on the same line as the
	-- heading: the whole reason for reading a cutoff list is working out how
	-- far off you are.
	panel.cutoffs.next=cutoffs:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
	panel.cutoffs.next:SetPoint("TOPRIGHT",cutoffs,"TOPRIGHT",-14,-12)
	panel.cutoffs.next:SetJustifyH("RIGHT")

	panel.cutoffs.rows={}
	for index,tier in ipairs(ns.TIERS or {}) do
		local row={}
		local y=-28-(index-1)*18

		row.label=cutoffs:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
		row.label:SetPoint("TOPLEFT",cutoffs,"TOPLEFT",14,y)
		row.label:SetText(L["CUTOFF_"..string.upper(tier.key)] or tier.key)
		-- The title's own colour, the same one its rating carries: the name and
		-- the number belong to each other, and grey made the name look like a
		-- caption for the number rather than half of the same thing.
		row.label:SetTextColor(HexToRGB(tier.hex))

		row.value=cutoffs:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
		row.value:SetPoint("TOPRIGHT",cutoffs,"TOPRIGHT",-14-CUTOFF_SPOTS_WIDTH,y)
		row.value:SetJustifyH("RIGHT")

		row.spots=cutoffs:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
		row.spots:SetPoint("TOPRIGHT",cutoffs,"TOPRIGHT",-14,y)
		row.spots:SetJustifyH("RIGHT")
		row.spots:SetTextColor(0.5,0.5,0.5)

		row.tier=tier
		panel.cutoffs.rows[index]=row
	end

	-- Where the numbers came from and when, since they are somebody else's
	-- reading of the ladder rather than the game's own.
	panel.cutoffs.source=cutoffs:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
	panel.cutoffs.source:SetPoint("BOTTOMLEFT",cutoffs,"BOTTOMLEFT",14,10)
	panel.cutoffs.source:SetPoint("BOTTOMRIGHT",cutoffs,"BOTTOMRIGHT",-14,10)
	panel.cutoffs.source:SetJustifyH("LEFT")
	panel.cutoffs.source:SetTextColor(0.42,0.42,0.42)

	panel.empty=panel:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
	panel.empty:SetPoint("TOPLEFT",panel,"TOPLEFT",14,-38-HEADER_HEIGHT)
	panel.empty:SetTextColor(0.55,0.55,0.55)
	panel.empty:SetText(L.HISTORY_EMPTY)

	local body=CreateFrame("Frame",nil,panel)
	body:SetPoint("TOPLEFT",panel,"TOPLEFT",12,-36-HEADER_HEIGHT)
	body:SetPoint("BOTTOMRIGHT",panel,"BOTTOMRIGHT",-12,10)

	for index=1,PANEL_ROWS do
		local row=CreateRow(body,index,false)
		row:SetScript("OnClick",function(self)
			if not self.match then return end

			-- Clicking the match that is already open closes the window again,
			-- so the same click both opens and puts away. This is the only way
			-- in or out of it, which is what freed the corner button up for the
			-- ladder.
			if window and window:IsShown() and selectedAt==self.match.at then
				selectedAt=nil
				window:Hide()
				return Refresh()
			end

			selectedAt=self.match.at
			scrollToSelection=true

			-- They share a place, so only one of them can be in it.
			if ns.CloseLadder then ns.CloseLadder() end

			local frame=CreateWindow()
			if not frame then return end
			AnchorFull(frame)
			frame:Show()
			RefreshFull()

			-- And this list itself, or its mark stays on whatever was selected
			-- last time something else redrew it.
			Refresh()
		end)
		rows[index]=row
	end

	return panel
end

local function CreateButton()
	if button then return button end
	if not panel then return nil end

	button=CreateFrame("Button",nil,panel)
	button:SetSize(20,20)
	-- Top right of the list it belongs to, below the header: the season best
	-- number has that corner now, and the two were sitting on top of each other.
	button:SetPoint("TOPRIGHT",panel,"TOPRIGHT",-12,-10-HEADER_HEIGHT)
	button:SetNormalTexture(HISTORY_ICON)
	button:GetNormalTexture():SetAlpha(0.7)
	button:SetHighlightTexture(HISTORY_ICON)

	-- It used to open the history window, which nothing needs it for any more:
	-- clicking a match opens that anyway. So it opens the ladder instead, which
	-- has no other way in.
	button:SetScript("OnEnter",function(self)
		self:GetNormalTexture():SetAlpha(1)
		GameTooltip:SetOwner(self,"ANCHOR_LEFT")
		GameTooltip:SetText(L.LADDER_BUTTON,1,1,1)
		GameTooltip:AddLine(L.LADDER_BUTTON_TOOLTIP,nil,nil,nil,true)
		GameTooltip:Show()
	end)
	button:SetScript("OnLeave",function(self)
		self:GetNormalTexture():SetAlpha(0.7)
		GameTooltip:Hide()
	end)
	button:SetScript("OnClick",function()
		if ns.ToggleLadder then ns.ToggleLadder() end
	end)

	return button
end

-- Long enough to outlast a tab that is only passing through. The PvP tab is
-- what the group finder window restores when it was the last one open, so it
-- can be visible for a frame or two on its way to somewhere else -- and this
-- panel flying out and back is far more noticeable than the tab itself.
local SETTLE_SECONDS = 0.1
local settleAt

-- Both full windows anchor themselves once, at the moment they open: beside
-- the panel where there is one, centred on the screen where there is not.
-- Neither noticed the panel turning up afterwards, so opening the Rated page
-- underneath an open window laid the panel over the top of it.
--
-- The other direction matters just as much, and is what makes this a pair
-- rather than a single call on the way out. A window anchored to the panel is
-- parented to it, and a child of a hidden frame is hidden -- so a window left
-- attached when the page closes would vanish with it instead of returning to
-- the middle of the screen.
local function ReanchorWindows()
	if window and window:IsShown() then AnchorFull(window) end
	if ns.ReanchorLadder then ns.ReanchorLadder() end
end

local function UpdateVisibility()
	local rated=ConquestQueueFrame and ConquestQueueFrame:IsVisible()
	local wanted=(module.db.enabled and rated) and true or false

	if not wanted then
		settleAt=nil
		if panel then panel:Hide() end
		if button then button:Hide() end
		-- After the hide, so anything still attached reads the panel as gone
		-- and goes back to the middle rather than hiding with it.
		ReanchorWindows()
		return
	end

	-- Already out: no need to wait again on every update.
	if not (panel and panel:IsShown()) then
		local now=GetTime()
		settleAt=settleAt or now

		if now-settleAt<SETTLE_SECONDS then
			C_Timer.After(SETTLE_SECONDS,UpdateVisibility)
			return
		end
	end

	if not CreatePanel() then return end
	CreateButton()

	Refresh()
	if window and window:IsShown() then RefreshFull() end

	panel:Show()
	if button then button:Show() end

	-- After the show, so a window that opened while there was nothing to sit
	-- beside now finds there is.
	ReanchorWindows()
end

----------------------------------------------------------------
-- The seed
----------------------------------------------------------------

-- Matched loosely on purpose: the seed was written from folder names, and a
-- realm can be spelled with a hyphen or an apostrophe that the game reports
-- differently from how it stores it.
local function Simplify(text)
	return (text or ""):gsub("[^%a%d]",""):lower()
end

local function SeedForThisCharacter()
	if not ns.HISTORY_SEED then return nil end

	local name=UnitName("player")
	if not name then return nil end

	local wanted=Simplify(name..(GetRealmName() or ""))
	for key,data in pairs(ns.HISTORY_SEED) do
		if Simplify(key)==wanted then return data end
	end
	return nil
end

-- Specs filled in by hand, for matches recorded before a teammate's spec could
-- be asked for. Runs over everything stored, since the same players turn up
-- across brackets and the ones already carrying a spec are left alone.
local function ApplySpecFixups()
	if not (ns.SPEC_FIXUPS and UnitName("player")) then return end

	local store=Store()
	if store.specFixups==ns.SPEC_FIXUP_VERSION then return end
	store.specFixups=ns.SPEC_FIXUP_VERSION

	local filled=0
	for _,list in pairs(store.matches or {}) do
		for _,match in ipairs(list) do
			for _,side in ipairs({match.mine,match.theirs}) do
				for _,player in ipairs(side or {}) do
					local bare=player.n and player.n:match("^([^-]+)")
					if not player.spec and bare and ns.SPEC_FIXUPS[bare] then
						player.spec=ns.SPEC_FIXUPS[bare]
						filled=filled+1
					end
				end
			end
		end
	end

	if filled>0 then ns.Print(L.HISTORY_SPECS_FILLED:format(filled)) end
end

-- Counts written before the crowd control table was complete, and the ones
-- pulled out of Details on top of them, are a mix of two different lists -- one
-- of which counts roots. Neither describes what this addon means by hard crowd
-- control, and dividing our seconds by their count means nothing at all, so
-- they go. The seconds stay: those are ours, and only ever undercounted.
local CC_COUNT_RESET = 1

local function ClearMixedCCCounts()
	if not UnitName("player") then return end

	local store=Store()
	if store.ccCountReset==CC_COUNT_RESET then return end
	store.ccCountReset=CC_COUNT_RESET

	for _,list in pairs(store.matches or {}) do
		for _,match in ipairs(list) do
			for _,side in ipairs({match.mine,match.theirs}) do
				for _,player in ipairs(side or {}) do
					player.ccCount,player.ccTakenCount=nil,nil
				end
			end
		end
	end
end

local function ImportSeed()
	-- Before the player is known there is nothing to file anything under, and
	-- marking it done would strand the import for good.
	if not UnitName("player") then return end

	local store=Store()
	if store.seedVersion==SEED_VERSION then return end
	store.seedVersion=SEED_VERSION
	store.seeded=nil

	local seed=SeedForThisCharacter()
	if not seed then return end

	local imported=0
	for bracket,list in pairs(seed) do
		local target=History(bracket)

		-- Merged on when the match happened rather than on any flag of ours: an
		-- earlier import left rows behind untagged, and matching by tag added a
		-- second copy of every one of them.
		local byTime={}
		for _,match in ipairs(target) do
			byTime[match.at or 0]=match
		end
		for _,match in ipairs(list) do
			byTime[match.at or 0]=match
			imported=imported+1
		end

		wipe(target)
		for _,match in pairs(byTime) do
			target[#target+1]=match
		end
		table.sort(target,function(a,b) return (a.at or 0)<(b.at or 0) end)
		while #target>KEEP_MAX do table.remove(target,1) end
	end

	-- Said once per character, because rows appearing that you never watched
	-- being recorded deserve an explanation.
	if imported>0 then ns.Print(L.HISTORY_IMPORTED,imported) end
end

----------------------------------------------------------------
-- Load
----------------------------------------------------------------

local hooked=false

local function HookPvPUI()
	if hooked or not ConquestQueueFrame then return end
	hooked=true

	ConquestQueueFrame:HookScript("OnShow",UpdateVisibility)
	ConquestQueueFrame:HookScript("OnHide",UpdateVisibility)

	-- Following the selected row is the whole point of keeping the brackets
	-- apart, so both lists move when the selection does.
	if type(ConquestQueueFrame_SelectButton)=="function" then
		hooksecurefunc("ConquestQueueFrame_SelectButton",function()
			if panel and panel:IsShown() then Refresh() end
			if window and window:IsShown() then RefreshFull() end
		end)
	end

	UpdateVisibility()
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

	if event=="COMBAT_LOG_EVENT_UNFILTERED" then
		return OnCombatLog()
	end

	if event=="INSPECT_READY" then
		return OnInspectReady(name)
	end

	-- A match in progress is only ever cleared when a result is announced, and
	-- a result is not always announced -- leaving early, a match that ends in a
	-- way the rating watcher misses, a reload. The players stayed behind, the
	-- next arena gathered into the same table, and a 2v2 came out with four
	-- opponents drawn from two different games.
	--
	-- So zoning clears it. On the way out it is parked first, though: walking
	-- out of a match means the rating -- and with it the result -- arrives after
	-- you have already left, and dropping the gathering there was what wrote
	-- those rows with nobody in them. Past the first half minute in an arena it
	-- is left alone, so reloading mid-match does not throw away the match you
	-- are standing in.
	local running=GetBattlefieldInstanceRunTime and GetBattlefieldInstanceRunTime() or 0

	if not InArena() then
		if Gathered(current) then
			pending={ match=current, at=time() }
		end
		current=nil
	elseif running<30000 then
		-- A fresh arena. Whatever was parked belongs to a match that is over
		-- and cannot be claimed by this one -- which is the rule that stopped
		-- two games being recorded as one.
		current=nil
		pending=nil
	end

	-- The character is only known once the world is up, so the import waits for
	-- that rather than running at load.
	if ns.BuildHardCCNames then ns.BuildHardCCNames() end
	ImportSeed()
	ApplySpecFixups()
	ClearMixedCCCounts()
	Sample()
end)

function module:OnEnable()
	if ns.IsAddOnLoaded("Blizzard_PVPUI") then
		HookPvPUI()
	else
		watcher:RegisterEvent("ADDON_LOADED")
	end

	watcher:RegisterEvent("PLAYER_ENTERING_WORLD")
	pcall(watcher.RegisterEvent,watcher,"ARENA_OPPONENT_UPDATE")
	watcher:RegisterEvent("UPDATE_BATTLEFIELD_SCORE")
	watcher:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
	pcall(watcher.RegisterEvent,watcher,"INSPECT_READY")

	-- The units appear over the first seconds of a match, so it is watched
	-- rather than read once.
	C_Timer.NewTicker(2,Sample)

	-- The MMR tweak owns working out what a match did to the rating.
	ns.On("ARENA_RESULT",function(info)
		if not module.db.enabled or not info then return end

		CloseOpenCC()

		-- Several games at once: played with this switched off, on another
		-- machine, or through a stretch where the watcher missed its wake. The
		-- rating moved by a known amount but there is no telling which match
		-- did what, and the players gathered belong to whichever one was last.
		--
		-- So nothing is written and the gathering is dropped. Keeping it was
		-- how one arena's opponents ended up in the next one's record.
		if (info.games or 1)>1 then
			current=nil
			pending=nil
			return
		end

		-- Normally the result lands while you are still standing in the arena,
		-- and `current` is right there. A match you walked out of announces
		-- itself once you are already gone, and the parked copy is all there is.
		local gathered,left=current,false
		if not gathered and pending and (time()-pending.at)<=PENDING_KEEP
			and FitsBracket(pending.match,info.bracket) then
			gathered=pending.match

			-- Parked, but not necessarily abandoned. Only a match that never
			-- reached a decision was actually walked out of.
			left=not gathered.decided
		end

		-- Stamped before the lists are built, so both sides carry where they
		-- stood at the time rather than wherever they end up later.
		if gathered then
			StampLadder(gathered.mine,info.bracket)
			StampLadder(gathered.theirs,info.bracket)
			-- Last, so the exact figures win over the ladder's.
			StampMe(gathered.mine,info)
		end

		local list=History(info.bracket)
		-- A new match is new evidence about who plays what.
		if ns.ForgetObservedSpecs then ns.ForgetObservedSpecs() end
		list[#list+1]={
			at     = time(),
			r      = info.rating,
			d      = info.delta,
			w      = info.won,
			dur    = gathered and gathered.dur,
			map    = gathered and gathered.map,
			-- Recorded here rather than imported, so the death order is whole.
			live   = true,
			-- Gathered up to the moment you left rather than to the end, so the
			-- row says so rather than quietly reading like a full record.
			left   = left or nil,
			mine   = AsList(gathered and gathered.mine),
			theirs = AsList(gathered and gathered.theirs),
		}
		while #list>KEEP_MAX do table.remove(list,1) end

		current=nil
		pending=nil
		if panel and panel:IsShown() then Refresh() end
		if window and window:IsShown() then RefreshFull() end
	end)
end

function module:OnToggle(enabled)
	UpdateVisibility()
	if not enabled and window then window:Hide() end
end

-- Throw away matches whose rosters were stitched together from two games.
--
-- Deliberately a command rather than something that happens on its own: it
-- deletes recorded matches, and a match cannot be recovered once gone. Only
-- rows that could not possibly be real go -- more players on a side than the
-- bracket has room for -- and it says what it took.
ns.SlashCommands["prune"]=function()
	local removed=0

	for bracket=1,4 do
		local list=History(bracket)

		for index=#list,1,-1 do
			if Mixed(list[index],bracket) then
				ns.Print("  %s %s -- %d against %d, removed.",
					BRACKET_NAMES[bracket] or "?",
					list[index].at and date("%d/%m %H:%M",list[index].at) or "?",
					#(list[index].mine or {}),#(list[index].theirs or {}))

				table.remove(list,index)
				removed=removed+1
			end
		end
	end

	ns.Print(removed>0 and L.HISTORY_PRUNED:format(removed) or L.HISTORY_PRUNE_NONE)

	if panel and panel:IsShown() then Refresh() end
	if window and window:IsShown() then RefreshFull() end
end

-- Every return of GetBattlefieldScore, numbered.
--
-- The arena scoreboard has a Rating Change column with a number per player, so
-- the client does know what each match was worth to everybody -- I had said it
-- did not. This finds which return carries it, rather than trusting a position
-- remembered from some other version of the game.
--
-- Run it while the scoreboard is up, before leaving.
ns.SlashCommands["score"]=function()
	if RequestBattlefieldScoreData then RequestBattlefieldScoreData() end

	local count=GetNumBattlefieldScores and GetNumBattlefieldScores() or 0
	ns.Print("%d row(s) on the scoreboard.",count)

	-- Enough for a 3v3 or a 5v5, not just the four of a 2v2.
	for index=1,math.min(count,10) do
		local packed={}
		local values={ GetBattlefieldScore(index) }

		for slot=1,#values do
			packed[#packed+1]=("%d=%s"):format(slot,tostring(values[slot]))
		end

		ns.Print("row %d: %s",index,table.concat(packed,"  "))
	end
end

-- What the client will say about the two sides' ratings.
--
-- Run this while the arena scoreboard is still up, before leaving. A rating
-- change per *player* is not reported to addons, but MoP shows one per team on
-- that scoreboard -- and in 2v2 and 3v3 that is the number worth having. If
-- GetBattlefieldTeamInfo answers here, both sides' points are recordable and I
-- have been wrong to say they are not.
ns.SlashCommands["teams"]=function()
	ns.Print("GetBattlefieldTeamInfo: %s",
		type(GetBattlefieldTeamInfo)=="function" and "present" or "MISSING")
	ns.Print("GetNumBattlefieldTeams: %s",
		type(GetNumBattlefieldTeams)=="function" and "present" or "MISSING")
	ns.Print("In an arena: %s.  Teams reported: %s.",
		tostring(IsActiveBattlefieldArena and IsActiveBattlefieldArena() or false),
		tostring(GetNumBattlefieldTeams and GetNumBattlefieldTeams() or "no api"))

	if type(GetBattlefieldTeamInfo)~="function" then return end

	for index=0,2 do
		local ok,a,b,c,d,e,f=pcall(GetBattlefieldTeamInfo,index)
		local packed={}
		if ok then
			for _,value in ipairs({ a,b,c,d,e,f }) do packed[#packed+1]=tostring(value) end
		end
		ns.Print("  team %d: %s",index,#packed>0 and table.concat(packed,", ") or "nothing")
	end
end
