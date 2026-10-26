-- Totals survive leaving before the scoreboard is available, without Details.
-- Run through the real combat handler and the zone-out/result sequence.
local ROOT,CLIENT=arg[1] or ".",arg[2] or "mop"
local h=dofile((arg[0]:gsub("history_totals_test.lua$","")).."history_harness.lua")
local log,raw=h.log,h.rawlog
local passes,fails=0,0
local function check(ok,label)
	if ok then passes=passes+1 else fails=fails+1;print("FAIL  "..label) end
end
local function finish(left)
	if left then
		IsActiveBattlefieldArena=function() return false end
		h.event("PLAYER_ENTERING_WORLD")
	end
	h.handlers.ARENA_RESULT({bracket=1,rating=1800,delta=0,won=false})
	local store=h.module.db.chars["Me-Realm"]
	local list=store.matches and store.matches[1] or store[1]
	local match=list[#list]
	local by={}
	for _,side in ipairs({match.mine,match.theirs}) do for _,p in ipairs(side) do by[p.guid]=p end end
	return match,by
end
local function enter()
	IsActiveBattlefieldArena=function() return true end
	GetBattlefieldInstanceRunTime=function() return 0 end
	GetBattlefieldWinner=function() return nil end
	GetNumBattlefieldScores=function() return 0 end
	h.event("PLAYER_ENTERING_WORLD")
end

log("SPELL_DAMAGE","P-ME","E-MAGE",585,"Smite",1000,-1)
log("SPELL_PERIODIC_DAMAGE","E-LOCK","P-ME",172,"Corruption",200,-1)
raw("SWING_DAMAGE","P-MATE","E-LOCK",400,50)
log("SPELL_DAMAGE","PET-FEL","P-MATE",3110,"Firebolt",150,-1)
log("SPELL_DAMAGE","P-ME","PET-FEL",585,"Smite",80,-1)
log("SPELL_DAMAGE","P-ME","P-ME",32409,"Backlash",30,-1)
log("SPELL_HEAL","P-ME","P-MATE",2061,"Flash Heal",800,300)
log("SPELL_PERIODIC_HEAL","P-ME","P-ME",139,"Renew",300,50)
log("SPELL_HEAL","P-ME","P-ME",2061,"Flash Heal",100,200)
log("SPELL_SUMMON","E-LOCK","GUARD-1",111897,"Grimoire: Felhunter")
log("SPELL_DAMAGE","GUARD-1","P-ME",3110,"Firebolt",70,-1)
-- Spell and melee variants: credit absorption to the shield caster.
raw("SPELL_ABSORBED","E-LOCK","P-MATE",3110,"Firebolt",4,"P-ME","Me",0,0,17,"Shield",2,120)
raw("SPELL_ABSORBED","P-MATE","E-MAGE","E-LOCK","Locky",0,0,6229,"Shadow Ward",32,90)
local match,by=finish(true)
check(match.left==true,"the undecided match is left early")
check(by["P-ME"].dmg==1080,"direct and pet-target damage, excluding self damage")
check(by["P-MATE"].dmg==350,"swing damage excludes overkill")
check(by["E-LOCK"].dmg==420,"pet and summoned guardian damage belongs to its player")
check(by["P-ME"].heal==870,"effective direct/periodic healing and consumed shield")
check(by["E-LOCK"].heal==90,"melee absorb credited to shield caster")
check(by["P-ME"].taken==300,"existing damage-taken accounting survives")
check(by["P-ME"].k==nil,"damage fallback does not invent a killing blow")
log("SPELL_DAMAGE","P-ME","E-MAGE",585,"Smite",9999,-1)
check(by["P-ME"].dmg==1080,"events after zoning out do not change the saved match")

enter()
local blank,empty=finish(true)
check((empty["P-ME"].dmg or 0)==0 and (empty["P-ME"].heal or 0)==0,"next match never inherits prior totals")

enter()
log("SPELL_DAMAGE","P-ME","E-MAGE",585,"Smite",2000,-1)
log("SPELL_HEAL","P-ME","P-ME",2061,"Flash Heal",2000,0)
GetBattlefieldWinner=function() return 0 end
GetNumBattlefieldScores=function() return 1 end
GetBattlefieldScore=function() return "Me",1,nil,0,nil,nil,nil,nil,nil,nil,900,800,0 end
h.event("UPDATE_BATTLEFIELD_SCORE")
local complete,scored=finish(false)
check(not complete.left,"decided match remains complete")
check(scored["P-ME"].dmg==900 and scored["P-ME"].heal==800,"nonzero completed scoreboard totals stay authoritative")

enter()
log("SPELL_DAMAGE","P-ME","E-MAGE",585,"Smite",600,-1)
log("SPELL_HEAL","P-ME","P-ME",2061,"Flash Heal",500,100)
log("UNIT_DIED",nil,"E-MAGE")
GetNumBattlefieldScores=function() return 1 end
GetBattlefieldScore=function() return "Me",0,nil,0,nil,nil,nil,nil,nil,nil,100,50,0 end
h.event("UPDATE_BATTLEFIELD_SCORE")
local partial,part=finish(true)
check(part["P-ME"].dmg==600 and part["P-ME"].heal==400,"early leave uses observed totals over an older partial scoreboard without adding both")

enter()
raw("SPELL_DAMAGE","P-ME","E-MAGE",585,"Smite",2,100,-1,2,0,0,60)
raw("SWING_DAMAGE","P-MATE","E-LOCK",100,-1,1,0,0,40)
raw("SPELL_MISSED","P-ME","E-MAGE",585,"Smite",2,"ABSORB",false,80)
raw("SWING_MISSED","P-MATE","E-LOCK","ABSORB",false,50)
raw("SPELL_MISSED","P-ME","E-MAGE",585,"Smite",2,"DODGE",false,999)
log("SPELL_DAMAGE","P-ME","P-MATE",585,"Smite",999,-1)
log("SPELL_DAMAGE","P-ME","UNKNOWN",585,"Smite",999,-1)
log("SPELL_HEAL","P-ME","E-MAGE",2061,"Flash Heal",999,0)
log("SPELL_HEAL","PET-FEL","E-LOCK",2061,"Flash Heal",60,10)
GetBattlefieldWinner=function() return 0 end
h.event("UPDATE_BATTLEFIELD_SCORE")
local missing,fallback=finish(false)
check(not missing.left,"a decided match with no scoreboard is still complete")
check(fallback["P-ME"].dmg==240,"spell damage includes partial and full absorption, excludes friendly and unknown targets")
check(fallback["P-MATE"].dmg==190,"melee damage includes partial and full absorption")
check(fallback["E-MAGE"].taken==100 and fallback["E-LOCK"].taken==100,"absorbed hits do not inflate damage taken")
check((fallback["P-ME"].heal or 0)==0 and fallback["E-LOCK"].heal==50,"healing follows pet ownership and team membership")

print(CLIENT..": totals passed "..passes..", failed "..fails)
os.exit(fails==0 and 0 or 1)
