# Gear, enchants, gems, talents and glyphs for the top of each ladder.
#
# Separate from UpdateSpecs.ps1 because the two answer different questions and
# cost very differently. A spec is one word and is wanted for every one of the
# five thousand rows, so that file covers the whole ladder. A talent build is
# only interesting for the players people actually open the ladder to study, and
# it changes per matchup rather than per season.
#
# So this covers the best -PerSpec of every spec in every bracket and nobody
# else -- the sample somebody comparing their own spec would want. Measured at
# 555 bytes a character for gear as well; talents and glyphs alone are about
# eighty, which is what makes this worth shipping at all.
#
# Endpoints:
#   /profile/wow/character/{realm}/{name}/specializations
#   /profile/wow/character/{realm}/{name}/equipment
#   /profile/wow/character/{realm}/{name}/statistics
#
# Talents and glyphs come out of two different arrays in that response, and
# reading the wrong one returns an empty list rather than an error -- see the
# extraction below.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File "<path>\UpdateInspect.ps1"
#   powershell -ExecutionPolicy Bypass -File "<path>\UpdateInspect.ps1" -Region eu -PerSpec 5

param(
    [string]$Region = "us",
    # How many of each spec, in each bracket.
    #
    # Was "the top 100 of each bracket", which sounds like the same thing and is
    # not. What people look up is how the best of their own spec is playing, and
    # a flat cut off the top answers that only for whatever specs happen to be
    # winning: the rest were absent at any depth short of thousands.
    #
    # Measured 2026-08-22 at five apiece: 372 characters US, 370 EU, against 343
    # and 295 for the old rule. So this is not cheaper -- slightly dearer, and
    # much better spread.
    [int]$PerSpec = 5,
    [int]$DelayMs = 50,
    # Skip entirely if the file was written more recently than this.
    #
    # Unlike the specs pass this has no incremental mode -- a talent build is
    # exactly the thing that changes, so every run re-asks about everybody. That
    # makes frequency cost real money, unlike there. Riding along with the
    # hourly task and doing nothing 23 times out of 24 keeps one schedule to
    # reason about while paying for one run a day.
    [int]$MinHours = 12,
    # Ignore MinHours and run now. Not the same as re-reading everybody: the
    # scheduled task passes this on every run, so tying anything else to it
    # would mean that thing always happening.
    [switch]$Force,

    # Re-read every character, including ones who have not played since they
    # were last read. For when the recorded data itself is suspect rather than
    # out of date.
    [switch]$Everybody
)

$ErrorActionPreference = "Stop"

$root       = Split-Path $PSScriptRoot -Parent
# Everything the passes write lives under Data\, so the addon root stays
# readable. Built once here: nine separate literals is nine chances for one
# to keep pointing at the old place, and a pass that writes where nothing
# reads fails silently.
# The data is its own addon now, a sibling of this one, so it can be
# published without republishing the code.
$data       = Join-Path (Split-Path $root -Parent) "ArenaPlus_Data"
$ladderFile = Join-Path $data ("Leaderboard-" + $Region + ".lua")
$outFile    = Join-Path $data ("Inspect-" + $Region + ".lua")
$logFile    = Join-Path $PSScriptRoot "UpdateInspect.log"
$credFile   = Join-Path $PSScriptRoot "blizzard-credentials.txt"

$TimeFormat = 'yyyy-MM-dd hh:mm tt'

function Write-Log([string]$message) {
    Add-Content -Path $logFile -Value ("{0}  {1}" -f (Get-Date -Format $TimeFormat), $message) -Encoding utf8
    Write-Host $message
}

# Lower case the way Lua does, which is A-Z and nothing else. See UpdateSpecs.ps1
# for what happens when this is left to PowerShell.
function ConvertTo-LuaLower([string]$text) {
    $sb = New-Object System.Text.StringBuilder
    foreach ($c in $text.ToCharArray()) {
        if ($c -ge 'A' -and $c -le 'Z') { $null = $sb.Append([char]([int]$c + 32)) }
        else                            { $null = $sb.Append($c) }
    }
    return $sb.ToString()
}

if (-not (Test-Path $ladderFile)) { Write-Log "No ladder file - run UpdateFromBlizzard.ps1 first."; return }

if (-not $Force -and $MinHours -gt 0 -and (Test-Path $outFile)) {
    $age = (Get-Date) - (Get-Item $outFile).LastWriteTime
    if ($age.TotalHours -lt $MinHours) {
        # Deliberately not logged: this is the normal outcome of most runs, and
        # a log line every hour saying nothing happened would bury the ones that
        # matter -- and would be counted as a run by the dashboard.
        Write-Host ("Skipping {0}: written {1:N1} hours ago, minimum is {2}." -f $Region.ToUpper(), $age.TotalHours, $MinHours)
        return
    }
}
if (-not (Test-Path $credFile))   { Write-Log "No blizzard-credentials.txt."; return }

$clientId = $null
$clientSecret = $null
foreach ($line in Get-Content $credFile) {
    if ($line -match '^\s*ClientId\s*=\s*(.+?)\s*$')     { $clientId = $Matches[1] }
    if ($line -match '^\s*ClientSecret\s*=\s*(.+?)\s*$') { $clientSecret = $Matches[1] }
}

$pair  = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$clientId`:$clientSecret"))
$token = (Invoke-RestMethod -Method Post -Uri "https://oauth.battle.net/token" `
            -Headers @{ Authorization = "Basic $pair" } -Body @{ grant_type = 'client_credentials' }).access_token
if (-not $token) { Write-Log "No access token."; return }

$headers   = @{ Authorization = "Bearer $token" }
$profileNs = "profile-classic-$Region"
$apiRoot   = "https://$Region.api.blizzard.com"

# ---------------------------------------------------------------- who

# The best few of each spec, in each bracket, merged. Ordinal, because these
# keys are read by Lua, whose tables are case-sensitive while PowerShell's are
# not.
$wanted = New-Object System.Collections.Specialized.OrderedDictionary ([System.StringComparer]::Ordinal)

# Which spec each character plays.
#
# Read from the specs pass's own cache rather than from Specs-<region>.lua: the
# cache stores the slug itself, while the shipped file stores an index into a
# list that is rebuilt on every write. One of those is a fact and the other is
# a position.
$specOf = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([System.StringComparer]::Ordinal)
$specCache = Join-Path $PSScriptRoot ("SpecsSeen-" + $Region + ".txt")

if (Test-Path $specCache) {
    foreach ($line in Get-Content $specCache) {
        if ($line.StartsWith('#')) { continue }
        $bits = $line -split '\|'
        if ($bits.Count -ge 2 -and $bits[1] -ne '') {
            # Race and gender ride along: they are the whole reason this pass
            # used to make a third request per character.
            $specOf[$bits[0]] = @{
                Slug   = $bits[1]
                Race   = $(if ($bits.Count -ge 4) { [int]$bits[3] } else { 0 })
                Gender = $(if ($bits.Count -ge 5) { [int]$bits[4] } else { 0 })
            }
        }
    }
}

# The class out of a spec slug.
#
# "priest-shadow" splits at the hyphen and "death-knight-unholy" does not, so
# the class is found by asking which class the slug begins with rather than by
# counting hyphens.
$CLASS_SLUGS = @('death-knight','druid','hunter','mage','monk','paladin','priest','rogue','shaman','warlock','warrior')

function Get-ClassSlug([string]$specSlug) {
    foreach ($klass in $CLASS_SLUGS) {
        if ($specSlug -eq $klass -or $specSlug.StartsWith($klass + '-')) { return $klass }
    }
    return ''
}

if ($specOf.Count -eq 0) {
    Write-Log "No spec cache - run UpdateSpecs.ps1 first."
    return
}

# Rows arrive in rank order within a bracket, so the first few of a spec are the
# best few of it and no sorting is needed.
$filled = New-Object 'System.Collections.Generic.Dictionary[string,int]' ([System.StringComparer]::Ordinal)
$bracket = 0
$noSpec = 0

foreach ($line in Get-Content $ladderFile) {
    # Which bracket's block we are in. The rows themselves do not say.
    $section = [regex]::Match($line, '^\t\[(\d)\] = \{')
    if ($section.Success) {
        $bracket = [int]$section.Groups[1].Value
        continue
    }

    $m = [regex]::Match($line, 'rank=(\d+), name="([^"]+)", realm="([^"]*)", rating=(\d+), won=(\d+), lost=(\d+)')
    if (-not $m.Success -or $bracket -eq 0) { continue }

    $key = ConvertTo-LuaLower ($m.Groups[2].Value + '-' + $m.Groups[3].Value)

    # No spec on file, no bucket to put them in. They arrive next run, once the
    # specs pass has met them.
    if (-not $specOf.ContainsKey($key)) { $noSpec++; continue }

    $bucket = "{0}|{1}" -f $bracket, $specOf[$key].Slug
    $have = 0
    if ($filled.ContainsKey($bucket)) { $have = $filled[$bucket] }
    if ($have -ge $PerSpec) { continue }
    $filled[$bucket] = $have + 1

    if (-not $wanted.Contains($key)) {
        $wanted[$key] = @{ Name = $m.Groups[2].Value; Realm = $m.Groups[3].Value; Games = 0 }
    }

    # Summed across every bracket they are listed in, so playing 3v3 counts as
    # having played even if their 2v2 record has not moved.
    $wanted[$key].Games += [int]$m.Groups[5].Value + [int]$m.Groups[6].Value
}

Write-Host ("{0} distinct characters: the top {1} of each spec in each {2} bracket, {3} buckets filled." -f `
    $wanted.Count, $PerSpec, $Region.ToUpper(), $filled.Count)
if ($noSpec -gt 0) {
    Write-Host ("  {0} ladder rows skipped for having no spec on file yet." -f $noSpec)
}

# ---------------------------------------------------------------- fetch

# ---------------------------------------------------------------- one at a time

# One run per region, as in UpdateFromBlizzard.ps1: two writers on one file end
# with the loser's work discarded. The process id is checked rather than trusted
# so a run that died cannot lock the job out for ever.
$lockFile = Join-Path $PSScriptRoot ("UpdateInspect-" + $Region + ".lock")

# Created, not checked and then created.
#
# "Does it exist? No? Make it" is two steps with a gap in the middle, and two
# runs starting in the same instant both pass the check. CreateNew is one step:
# the filesystem hands the file to exactly one caller and throws for the other.
$held = $null
for ($try = 1; $try -le 2; $try++) {
    try {
        $held = [System.IO.File]::Open($lockFile, [System.IO.FileMode]::CreateNew,
                                       [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
        break
    } catch {
        # Somebody has it. Whether that somebody still exists is the question.
        $owner = 0
        try { $owner = [int](Get-Content $lockFile -TotalCount 1 -ErrorAction Stop) } catch { }

        if ($owner -gt 0 -and (Get-Process -Id $owner -ErrorAction SilentlyContinue)) {
            Write-Host ("Already running as process {0}. Nothing to do." -f $owner)
            return
        }

        if ($try -eq 1) {
            # The owner is gone, so this is a leftover from a run that died.
            Write-Host "Clearing a lock left by a run that did not finish."
            try { Remove-Item $lockFile -Force -ErrorAction Stop } catch { }
        } else {
            # Two runs racing to clear the same dead lock; the other won.
            Write-Host "Another run claimed the lock first. Nothing to do."
            return
        }
    }
}

# The id goes in so a later run can ask whether this process still exists, and
# the handle stays open so the file cannot be deleted while it is held.
$writer = New-Object System.IO.StreamWriter($held)
$writer.WriteLine($PID)
$writer.Flush()

$progressFile = Join-Path $PSScriptRoot ("UpdateInspect-" + $Region + ".progress")
$startedAt = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

function Write-Progress-File([int]$done,[int]$total) {
    Set-Content -Path $progressFile -Encoding utf8 -Value `
        ("inspect|{0}|{1}|{2}|{3}" -f $Region, $done, $total, $startedAt)
}

# Names have to ship: there is no client API turning a glyph id into its name,
# unlike talents, whose spell ids GetSpellInfo resolves locally. Shared across
# every character rather than repeated per row -- a few hundred entries covers
# every class.
$glyphNames = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::Ordinal)

# Enchants need their text shipped for the same reason glyphs need their names:
# an enchantment id resolves to nothing in the client. Gems do not -- the API
# hands back the gem's own source_item, which is a real item the client can draw
# an icon and a tooltip for. So the two are told apart here rather than in the
# addon, and only the enchant text has to travel.
$enchantText = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::Ordinal)

# Set names, shared the same way. "4 of 5 Gladiator's Vestments" is the thing
# people actually check on a top player, and the client cannot work it out for
# somebody it has never seen: a set bonus line is computed from what the
# inspected unit has on, and here there is no unit.
$setNames = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::Ordinal)

# Which set each item belongs to, shared across everybody.
#
# Needed so hovering any one piece can say "5/5" the way the game's own tooltip
# does. The count itself is per character, but the item-to-set mapping is a fact
# about the item, so it is stored once: about fifty sets of five, against
# repeating it on every character who wears one.
$setOfItem = @{}

# The item that applied each enchant.
#
# Blizzard returns it beside the enchantment: shoulder enchant 4806 carries
# source_item "Greater Crane Wing Inscription", id 87559. That is the name
# somebody copying a build actually wants -- "+200 Intellect and +100 Critical
# Strike" is what it does, not what to go and buy -- and shipping the id rather
# than the name lets the client supply the name, the icon and the quality
# colour, the same way it does for gems.
$enchantItem = @{}

# The spell behind a tinker, so the client can say what it does.
#
# Blizzard hands one back for every ON_USE_SPELL enchantment -- Synapse Springs
# is spell 126734 -- along with the description. The id is what gets shipped
# rather than the words: the client already knows the spell and will write the
# description itself, in the reader's own language, for six bytes instead of a
# hundred.
$enchantSpell = @{}

# And what the spell does, in Blizzard's own words.
#
# The client can describe a spell from its id, and does -- but it writes the
# bare effect, "Increases your Intellect... for 10 sec", while the item tooltip
# in the game says "Use: Increases your Intellect... (1 Min Cooldown)". The
# second is what somebody reading a glove expects to see, and it is what this
# endpoint already returns, so it is shipped rather than reconstructed.
#
# There are only a dozen or so tinkers, so the words cost very little.
$enchantUse = @{}

# Which slot each enchant was seen on. Only used to keep the borrowing below
# honest: two enchants may read the same and belong on different pieces.
$enchantOnSlot = @{}

# The whole talent grid, harvested rather than fetched.
#
# Blizzard publishes no talent tree for classic -- /data/wow/talent/index 404s
# under every namespace -- so the only way to know what a class could have taken
# is to watch what its players did take. Keyed "class|tier|talentId" so the same
# talent seen a hundred times is one entry.
#
# Sorting a character's talents by talent.id puts them in tier order, checked
# against three classes by hand: it is the only ordering the API offers, and the
# array itself arrives shuffled.
#
# Both spec groups are read, not just the active one. The off-spec build is free
# -- it is in the same response -- and doubles what each character teaches us.
$builds = @{}
$rankVotes = @{}
$talentIdOf = @{}
$talentNames = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::Ordinal)

$records = New-Object System.Collections.Generic.List[string]

# ---------------------------------------------------------------- carry over

# What the last run learned, so a character who has not played since is not
# asked about again.
#
# Gear, talents and glyphs only change when somebody plays -- and most of the
# people in this selection are not playing on any given day. The ladder file
# already carries everyone's win and loss totals, so "have they played" is
# answerable for nothing, without a request.
#
# Skipping a fetch means keeping what was learned last time, and that is more
# than the character's own record: the glyph, enchant and set names they need,
# and their talent build, all live in tables shared by the whole file. Those are
# read back out of the previous file and seeded here, so nothing that was known
# yesterday goes missing today.
$prevRecord = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::Ordinal)

if (Test-Path $outFile) {
    $prevText = Get-Content $outFile -Raw

    foreach ($m in [regex]::Matches($prevText, '(?m)^\t\["([^"]+)"\]=(\{.*\}),$')) {
        $prevRecord[$m.Groups[1].Value] = $m.Groups[2].Value
    }

    # The shared tables, seeded rather than rebuilt. A name only arrives with
    # the character who wears it, so dropping the ones we did not re-fetch
    # would leave their own records pointing at nothing.
    #
    # Read a block at a time rather than by pattern across the whole file: all
    # three name tables are written as [id]="text", and nothing in the line
    # itself says which table it belongs to.
    function Get-Block([string]$text, [string]$tableName) {
        $m = [regex]::Match($text, "ns\.$tableName = ns\.$tableName or \{\}\s*\r?\n\s*\r?\nfor [^\n]*\r?\n(.*?)\r?\n\}\)", 'Singleline')
        if ($m.Success) { return $m.Groups[1].Value }
        return ''
    }

    foreach ($pair in @(
        @{ Table = 'GLYPH_NAMES';  Into = $glyphNames },
        @{ Table = 'ENCHANT_TEXT'; Into = $enchantText },
        @{ Table = 'ENCHANT_USE';  Into = $enchantUse },
        @{ Table = 'SET_NAMES';    Into = $setNames }
    )) {
        $body = Get-Block $prevText $pair.Table
        foreach ($m in [regex]::Matches($body, '\[(\d+)\]="((?:[^"\\]|\\.)*)"')) {
            $pair.Into[$m.Groups[1].Value] = ($m.Groups[2].Value -replace '\\"', '"')
        }
    }

    foreach ($carried in @(
        @{ Table = 'SET_OF_ITEM';   Into = $setOfItem },
        @{ Table = 'ENCHANT_ITEM';  Into = $enchantItem },
        @{ Table = 'ENCHANT_SPELL'; Into = $enchantSpell }
    )) {
        $body = Get-Block $prevText $carried.Table
        foreach ($m in [regex]::Matches($body, '\[(\d+)\]=(\d+)')) {
            $carried.Into[$m.Groups[1].Value] = $m.Groups[2].Value
        }
    }

    Write-Host ("{0} characters on file from the last run." -f $prevRecord.Count)
}

# How many games each character had played when we last fetched them.
$lastGames = New-Object 'System.Collections.Generic.Dictionary[string,int]' ([System.StringComparer]::Ordinal)
$gamesFile = Join-Path $PSScriptRoot ("InspectSeen-" + $Region + ".txt")

if (Test-Path $gamesFile) {
    foreach ($line in Get-Content $gamesFile) {
        if ($line.StartsWith('#')) { continue }
        $bits = $line -split '\|'
        if ($bits.Count -ge 2) {
            $n = 0
            if ([int]::TryParse($bits[1], [ref]$n)) { $lastGames[$bits[0]] = $n }
        }
    }
}

$carried = 0
# Counted, not worked out afterwards.
#
# This was logged as "asked * 3 + 1", which was true while every character cost
# three requests and quietly wrong the moment one of them was removed: the pass
# went to two apiece and carried on reporting three. The dashboard reads this
# number to forecast the hourly spend, so a stale assumption here becomes a
# wrong figure on screen.
$requests = 0

$asked = 0
$found = 0
$missing = 0

Write-Progress-File 0 $wanted.Count

foreach ($key in $wanted.Keys) {
    $who = $wanted[$key]

    # Not played since we last looked, so there is nothing new to read.
    #
    # Gear, talents and glyphs change when somebody plays. The ladder file
    # carries their win and loss totals, so this costs nothing to know, and
    # most of this selection has not played today.
    if (-not $Everybody -and $prevRecord.ContainsKey($key) -and
        $lastGames.ContainsKey($key) -and $lastGames[$key] -eq $who.Games) {

        $null = $records.Add("`t[`"$key`"]=" + $prevRecord[$key] + ",")
        $carried++

        # Their build still counts towards the talent grid, which is pooled
        # across everybody: dropping it because we did not re-fetch them would
        # make the grid worse every run until it knew nothing.
        $carriedBuild = [regex]::Match($prevRecord[$key], ',t=\{([\d,]*)\},')
        $carriedClass = [regex]::Match($prevRecord[$key], ',c="([a-z-]+)"\}$')

        if ($carriedBuild.Success -and $carriedClass.Success) {
            $spells = @($carriedBuild.Groups[1].Value -split ',' | Where-Object { $_ -ne '' })
            if ($spells.Count -eq 6) {
                $klassOf = $carriedClass.Groups[1].Value
                if (-not $builds.ContainsKey($klassOf)) {
                    $builds[$klassOf] = New-Object System.Collections.Generic.List[object]
                }
                $asList = New-Object System.Collections.Generic.List[int]
                foreach ($spell in $spells) { $null = $asList.Add([int]$spell) }
                $null = $builds[$klassOf].Add($asList)
            }
        }

        continue
    }

    $asked++

    $name = [uri]::EscapeDataString($who.Name.ToLower())
    $uri  = "$apiRoot/profile/wow/character/$($who.Realm)/$name/specializations" + "?namespace=$profileNs&locale=en_US"

    $eqUri   = "$apiRoot/profile/wow/character/$($who.Realm)/$name/equipment" + "?namespace=$profileNs&locale=en_US"
    $stUri   = "$apiRoot/profile/wow/character/$($who.Realm)/$name/statistics" + "?namespace=$profileNs&locale=en_US"

    # Class, race and gender, from the specs pass rather than from a third
    # request.
    #
    # There used to be one: race and gender so the model is the character rather
    # than a stand-in wearing their kit, and class because neither of the other
    # two responses carries it. All three are already on file -- the specs pass
    # reads them out of the same profile endpoint for every name on the ladder,
    # and nothing here is selected without a spec on file. That made a third of
    # this pass's requests re-fetches of what we had.
    $known = $specOf[$key]
    $klass = Get-ClassSlug $known.Slug
    $raceId = [int]$known.Race
    $genderId = [int]$known.Gender

    try {
        $requests++
        $sp = Invoke-RestMethod -Uri $uri -Headers $headers -ErrorAction Stop
        $requests++
        $eq = Invoke-RestMethod -Uri $eqUri -Headers $headers -ErrorAction Stop
    } catch {
        # A hidden profile, or a character since renamed or transferred. Left
        # out entirely: unlike the specs file there is no ladder row depending
        # on a value being present, so absence is simply "nothing to show".
        $missing++
        if ($asked % 50 -eq 0) { Write-Progress-File $asked $wanted.Count }
        if ($DelayMs -gt 0) { Start-Sleep -Milliseconds $DelayMs }
        continue
    }

    # What they are actually running, as opposed to what the gear says.
    #
    # Reforging is nowhere in the equipment endpoint. No key on an equipped item
    # mentions it, and every worn item's stats match the vendor item to the
    # point -- measured across 402 items on 24 gladiators, 243 distinct base
    # items, zero deviation. The API hands back the item as it leaves the
    # vendor, the same reason its sockets come back empty.
    #
    # The statistics endpoint is the played character instead, and what it hands
    # back is worth being precise about. It reports a percentage and a rating
    # together, and the rating is derived from the percentage at a fixed rate --
    # 600 per 1% crit, 425 per 1% haste, exactly, on every character checked. So
    # it is not a sum of gear: everything that moves the percentage is in it,
    # passives included.
    #
    # Which makes it the right number for "what does the best of my spec run"
    # and the wrong number for anything per-item. Working a reforge back out of
    # it was tried and abandoned: with gems, enchants and socket bonuses all
    # accounted for, 17 of 20 characters admitted no consistent assignment at
    # all, the two sides of the equation not being made of the same thing.
    #
    # rating_normalized rather than the percentage, because the percentage comes
    # in melee and spell flavours and picking between them per class is a
    # judgement this has no business making.
    #
    # Hit and expertise are not in the document at any depth. The panel says so
    # rather than leaving a reader to assume the gap is a zero.
    #
    # Its own try, and no $missing on failure: a character whose statistics will
    # not load still has gear and talents worth keeping, so a failure here drops
    # the numbers rather than the person.
    $vBlock = ""
    try {
        $requests++
        $stats = Invoke-RestMethod -Uri $stUri -Headers $headers -ErrorAction Stop
        $vBlock = ",v={" + (@(
            [int]$stats.melee_crit.rating_normalized,
            [int]$stats.melee_haste.rating_normalized,
            [int]$stats.mastery.rating_normalized,
            [int]$stats.spirit.effective,
            [int]$stats.strength.effective,
            [int]$stats.agility.effective,
            [int]$stats.intellect.effective,
            [int]$stats.stamina.effective,
            [int]$stats.health,
            [int]$stats.spell_power,
            [int]$stats.attack_power
        ) -join ",") + "}"
    } catch { }

    # Talents hang off "specializations", one entry per spec, picked by matching
    # active_specialization. Glyphs hang off "specialization_groups", a separate
    # array whose entries carry is_active and no talents at all. Reading the
    # obvious single path returns empty lists and no error, which is how this
    # first went in reporting zero talents for everybody.
    $talents = New-Object System.Collections.Generic.List[string]
    $glyphs  = New-Object System.Collections.Generic.List[string]

    $activeId = $sp.active_specialization.id
    $mine = $sp.specializations | Where-Object { $_.specialization.id -eq $activeId } | Select-Object -First 1
    if (-not $mine) { $mine = $sp.specializations | Select-Object -First 1 }
    if ($mine) {
        # In tier order, which is talent.id order. The array as it arrives is in
        # no order at all, so the first version showed tier five in the tier one
        # row and labelled it "level 15".
        foreach ($t in ($mine.talents | Sort-Object { [int]$_.talent.id })) {
            $id = $t.spell_tooltip.spell.id
            if ($id) { $null = $talents.Add([string]$id) }
        }
    }

    # Glyphs live on specialization_groups, which carries is_active and no
    # talents at all -- a different array from the one above, which is why this
    # is its own block rather than another loop inside that one.
    $group = $sp.specialization_groups | Where-Object { $_.is_active } | Select-Object -First 1
    if (-not $group) { $group = $sp.specialization_groups | Select-Object -First 1 }
    if ($group) {
        foreach ($g in $group.glyphs) {
            if (-not $g.id) { continue }
            $null = $glyphs.Add([string]$g.id)
            # The name has to ship: a glyph id resolves to nothing in the client.
            if ($g.name -and -not $glyphNames.ContainsKey([string]$g.id)) {
                $glyphNames[[string]$g.id] = $g.name
            }
        }
    }

    # Everything this character teaches us about the grid, from both builds.
    #
    # The builds are kept whole and worked into tiers at the end, rather than
    # each one being filed as it arrives. Tiers cannot be read off a single
    # build: sorting its talents by talent.id looks like tier order and is not,
    # because a talent changed in a later patch carries a much higher id than
    # its neighbours -- Soul of the Forest is 19677 where the rest of its tier
    # sit near 18580, so it sorted last and was filed as tier six.
    #
    # What is always true is that two talents of the same tier can never be
    # taken together. That is what the grouping at the end uses.
    if ($klass) {
        foreach ($group in $sp.specializations) {
            if (@($group.talents).Count -ne 6) { continue }

            # Each talent's position once the build is sorted by talent id.
            #
            # That position is the tier for all but the odd talent reissued in a
            # patch with a much higher id, which sorts to the end and shifts
            # everything after it up one. Recorded per build rather than trusted
            # per build: across hundreds of them the true position is the one
            # seen most often, and the minority of builds carrying the odd
            # talent cannot outvote it.
            $rank = 0
            $build = New-Object System.Collections.Generic.List[int]
            foreach ($t in ($group.talents | Sort-Object { [int]$_.talent.id })) {
                $spellId = $t.spell_tooltip.spell.id
                $talentId = $t.talent.id
                if (-not ($spellId -and $talentId)) { continue }

                $rank++
                $null = $build.Add([int]$spellId)

                $rankKey = "$klass|$spellId|$rank"
                if ($rankVotes.ContainsKey($rankKey)) { $rankVotes[$rankKey]++ } else { $rankVotes[$rankKey] = 1 }

                $idKey = "$klass|$spellId"
                if (-not $talentIdOf.ContainsKey($idKey) -or [int]$talentId -lt [int]$talentIdOf[$idKey]) {
                    $talentIdOf[$idKey] = [int]$talentId
                }
                if ($t.talent.name -and -not $talentNames.ContainsKey([string]$spellId)) {
                    $talentNames[[string]$spellId] = $t.talent.name
                }
            }

            if ($build.Count -eq 6) {
                if (-not $builds.ContainsKey($klass)) {
                    $builds[$klass] = New-Object System.Collections.Generic.List[object]
                }
                $null = $builds[$klass].Add($build)
            }
        }
    }

    # One slot as { itemID, enchantID, gem, gem, gem }, with 0 for no enchant.
    #
    # enchantment_slot.type is what tells these apart, and ignoring it put three
    # different things in the wrong places at once: the permanent enchant
    # carries a source_item like a gem does, so it was stored as one; belt
    # buckles and blacksmith sockets are reported as enchantments too, so they
    # were stored as gems and pushed the real ones out of their sockets; and the
    # untyped socket-bonus line was taken for the enchant.
    #
    #   PERMANENT      the enchant
    #   (blank) + src  a gem, in the socket its slot id names
    #   (blank) no src the socket bonus, which the client works out itself
    #   BONUS_SOCKETS  a belt buckle, or a blacksmith's extra socket
    #   ON_USE_SPELL   a tinker, which only an engineer can fit
    $gear = New-Object System.Collections.Generic.List[string]
    $tinkers = New-Object System.Collections.Generic.List[string]
    $professions = @{}

    foreach ($item in $eq.equipped_items) {
        if (-not $item.item.id) { continue }

        $enchant = 0
        $enchantSays = ""
        $tinker = 0
        $bonusSocket = $false
        $gemsBySlot = @{}

        foreach ($e in $item.enchantments) {
            $type = [string]$e.enchantment_slot.type

            if ($type -eq 'PERMANENT') {
                $enchant = $e.enchantment_id
                $enchantSays = [string]$e.display_string
                if ($e.source_item.id) { $enchantItem[[string]$enchant] = [int]$e.source_item.id }
                $enchantOnSlot[[string]$enchant] = [string]$item.slot.type
                if ($e.display_string -and -not $enchantText.ContainsKey([string]$enchant)) {
                    # "Enchanted: +170 Mastery" -- the prefix is Blizzard's and is
                    # dropped, since the panel already says what this is.
                    $enchantText[[string]$enchant] = ($e.display_string -replace '^Enchanted:\s*','')
                }
            } elseif ($type -eq 'ON_USE_SPELL') {
                # A tinker sits alongside the permanent enchant rather than
                # replacing it -- gloves carry both "+170 Mastery" and Synapse
                # Springs -- and an item link has only one enchant field, so it
                # cannot ride in the link and is kept beside the slot instead.
                $tinker = $e.enchantment_id
                if ($e.source_item.id) { $enchantItem[[string]$tinker] = [int]$e.source_item.id }
                if ($e.spell.spell.id) { $enchantSpell[[string]$tinker] = [int]$e.spell.spell.id }

                if ($e.spell.description) {
                    # Broken where Blizzard breaks it.
                    #
                    # These arrive as one long run with carriage returns and
                    # doubled spaces in them. Collapsing all of that to single
                    # spaces made one very wide line -- "...for 10 sec. Your
                    # highest stat is always chosen. (1 Min Cooldown)" stretched
                    # the tooltip across the screen.
                    #
                    # The doubled space is not noise: it is where Blizzard ends
                    # a sentence, and the game's own tooltip breaks there. So a
                    # run of two or more spaces becomes a line break and single
                    # spaces are left alone.
                    $says = [string]$e.spell.description
                    $says = $says -replace '(\r?\n)+', '|n'
                    $says = $says -replace '  +', '|n'
                    $says = $says -replace '[ \t]+', ' '
                    $says = $says -replace '\|n +', '|n'
                    $enchantUse[[string]$tinker] = $says.Trim()
                }
                if ($e.display_string -and -not $enchantText.ContainsKey([string]$tinker)) {
                    $enchantText[[string]$tinker] = $e.display_string
                }
            } elseif ($type -eq 'BONUS_SOCKETS') {
                $bonusSocket = $true
            } elseif ($e.source_item.id) {
                $gemsBySlot[[int]$e.enchantment_slot.id] = $e.source_item.id
            }
        }

        # In socket order, which is what an item link expects.
        $gems = New-Object System.Collections.Generic.List[string]
        foreach ($slotId in ($gemsBySlot.Keys | Sort-Object)) {
            $null = $gems.Add([string]$gemsBySlot[$slotId])
        }

        # Professions, read off the gear because the API has no professions
        # endpoint for classic -- it 404s. Only what the gear proves:
        #   a tinker            only an engineer can fit one
        #   an enchanted ring   only an enchanter can enchant their own
        #   an extra socket on
        #   wrist or hands      a blacksmith's, unlike a belt buckle, which
        #                       anybody can use and so proves nothing
        #   an embroidered
        #   cloak               a tailor's, and the embroideries name themselves
        #                       in the display string
        $slotName = ($item.slot.type -replace '[^A-Za-z0-9_]','').ToLower()
        if ($tinker -gt 0) { $professions['engineering'] = $true }
        if ($enchant -gt 0 -and $slotName -like 'finger_*') { $professions['enchanting'] = $true }
        if ($bonusSocket -and ($slotName -eq 'wrist' -or $slotName -eq 'hands')) { $professions['blacksmithing'] = $true }
        if ($slotName -eq 'back' -and $enchantSays -match 'Embroidery') { $professions['tailoring'] = $true }

        $bits = New-Object System.Collections.Generic.List[string]
        $null = $bits.Add([string]$item.item.id)
        $null = $bits.Add([string]$enchant)
        foreach ($g in $gems) { $null = $bits.Add($g) }

        if ($slotName) {
            $null = $gear.Add($slotName + "={" + ($bits -join ",") + "}")
            if ($tinker -gt 0) { $null = $tinkers.Add($slotName + "=" + $tinker) }
        }
    }

    # How much of each set is on, as { setID, equipped, total }. The first entry
    # the API returns is routinely an empty object, so anything without an id is
    # skipped rather than counted as a set with no name.
    #
    # There used to be a fourth number: a bitmask of which pieces were worn, for
    # picking the right lines out of the set list on a tooltip. That was replaced
    # by matching the line's name suffix -- position-based matching highlighted
    # the wrong piece -- and the mask has been written and never read since,
    # about 11 KB a region in a file everyone downloads. Old files still carry
    # it; the reader simply stops at the third field.
    $sets = New-Object System.Collections.Generic.List[string]
    foreach ($set in $eq.equipped_item_sets) {
        if (-not $set.item_set.id) { continue }

        $worn = 0
        $total = 0
        foreach ($piece in $set.items) {
            if ($piece.is_equipped) { $worn++ }
            $total++
        }
        if ($total -eq 0) { continue }

        $setID = [string]$set.item_set.id
        if ($set.item_set.name -and -not $setNames.ContainsKey($setID)) {
            $setNames[$setID] = $set.item_set.name
        }
        foreach ($piece in $set.items) {
            if ($piece.item.id) { $setOfItem[[string]$piece.item.id] = $setID }
        }
        $null = $sets.Add("{" + $setID + "," + $worn + "," + $total + "}")
    }

    if ($talents.Count -gt 0 -or $glyphs.Count -gt 0 -or $gear.Count -gt 0) {
        $null = $records.Add("`t[`"$key`"]={g={" + ($gear -join ",") + "},t={" + ($talents -join ",") + "},y={" + ($glyphs -join ",") + "},s={" + ($sets -join ",") + "},p={" + (($professions.Keys | Sort-Object | ForEach-Object { '"' + $_ + '"' }) -join ",") + "},k={" + ($tinkers -join ",") + "}" + $vBlock + ",r=" + $raceId + ",x=" + $genderId + ",c=`"" + $klass + "`"},")
        $found++
    } else {
        $missing++
    }

    if ($asked % 50 -eq 0) {
        Write-Progress-File $asked $wanted.Count
        Write-Host ("  {0} asked, {1} found, {2} missing" -f $asked, $found, $missing)
    }
    if ($DelayMs -gt 0) { Start-Sleep -Milliseconds $DelayMs }
}

if (Test-Path $progressFile) { Remove-Item $progressFile -Force }
if ($writer) { $writer.Dispose() }
if (Test-Path $lockFile) { Remove-Item $lockFile -Force }

# ---------------------------------------------------------------- write

$now = Get-Date -Format $TimeFormat

$glyphBody = (($glyphNames.Keys | Sort-Object { [int]$_ }) | ForEach-Object {
    "`t[" + $_ + "]=`"" + ($glyphNames[$_] -replace '"','\"') + "`","
}) -join "`n"

# Enchants Blizzard gave no source item for, filled in from one that reads the
# same.
#
# The same enchant turns up under more than one id -- 4825 and 4895 are both
# "+285 Intellect and +165 Critical Strike" on legs -- and Blizzard names the
# item that applied it for one and not the other. Since the two are the same
# enchant, the item that applies one applies the other, and a leg enchant stops
# being a line you cannot click.
#
# Matched on the slot as well as the words, because "+80 All Stats" on a chest
# and on something else would otherwise trade scrolls.
$itemByEffect = @{}
foreach ($id in $enchantItem.Keys) {
    $effect = $enchantText[$id]
    if (-not $effect) { continue }
    $key = ($enchantOnSlot[$id]) + "|" + $effect
    if (-not $itemByEffect.ContainsKey($key)) { $itemByEffect[$key] = $enchantItem[$id] }
}

$borrowed = 0
foreach ($id in @($enchantText.Keys)) {
    if ($enchantItem.ContainsKey($id)) { continue }

    $effect = $enchantText[$id]
    if (-not $effect) { continue }

    $key = ($enchantOnSlot[$id]) + "|" + $effect
    if ($itemByEffect.ContainsKey($key)) {
        $enchantItem[$id] = $itemByEffect[$key]
        $borrowed++
    }
}
if ($borrowed -gt 0) {
    Write-Host ("{0} enchants took their name from an identical one." -f $borrowed)
}

$enchantUseBody = (($enchantUse.Keys | Sort-Object { [int]$_ }) | ForEach-Object {
    "`t[" + $_ + "]=`"" + ($enchantUse[$_] -replace '"','\"') + "`","
}) -join "`n"

$enchantSpellBody = (($enchantSpell.Keys | Sort-Object { [int]$_ }) | ForEach-Object {
    "`t[" + $_ + "]=" + $enchantSpell[$_] + ","
}) -join "`n"

$enchantItemBody = (($enchantItem.Keys | Sort-Object { [int]$_ }) | ForEach-Object {
    "`t[" + $_ + "]=" + $enchantItem[$_] + ","
}) -join "`n"

$enchantBody = (($enchantText.Keys | Sort-Object { [int]$_ }) | ForEach-Object {
    "`t[" + $_ + "]=`"" + ($enchantText[$_] -replace '"','\"') + "`","
}) -join "`n"

$setBody = (($setNames.Keys | Sort-Object { [int]$_ }) | ForEach-Object {
    "`t[" + $_ + "]=`"" + ($setNames[$_] -replace '"','\"') + "`","
}) -join "`n"

# Six groups of three, solved rather than guessed.
#
# The talent grid used to be worked out here.
#
# A constraint solver read every build this pass fetched and inferred which
# talents could not share a tier. It was wrong in ways that showed -- Halo in
# tier 3 rather than tier 6, holes wherever a class had few builds, one monk
# talent in two tiers at once -- and its coverage moved between 184 and 189 of
# 198 between runs with no change to the code.
#
# The client knows the real answer and will say so: see /arena talents and
# TalentGrid.lua, which is 198 of 198 and describes the game rather than the
# ladder. Nothing here needs to guess at it any more.

$itemSetBody = (($setOfItem.Keys | Sort-Object { [int]$_ }) | ForEach-Object {
    "`t[" + $_ + "]=" + $setOfItem[$_] + ","
}) -join "`n"

$recordBody = ($records -join "`n")

$out = @"
-- Shipped as its own addon so the ladder can be republished without reshipping
-- the code: this file was half of every ArenaPlus release.
--
-- Two addons cannot see each other's namespace, so the tables go on a global
-- and ArenaPlus copies them across as it loads. Same reason ArenaPlusAPI is a
-- global -- see the note above it in ArenaPlus\Core.lua.
--
-- The local keeps its name so the generated body below needs no changes.
ArenaPlusData = ArenaPlusData or {}
local ns = ArenaPlusData

-- Gear, enchants, gems, talents and glyphs for the top $PerSpec of every spec
-- in every bracket, written by tools\UpdateInspect.ps1 from Blizzard's
-- character profile API.
--
-- Not the whole ladder. A talent build is worth seeing for the players people
-- study; carrying it for five thousand rows would add megabytes to an addon
-- everybody downloads, for rows nobody opens.
--
-- Per spec rather than off the top, because the question this answers is "how
-- is the best of my spec playing", and the top of a bracket is whatever specs
-- are winning this season rather than a sample of all of them.
--
-- Item ids and talent spell ids resolve locally, through GetItemInfo and
-- GetSpellInfo, so neither needs a name shipped. Glyph ids resolve to nothing
-- in the client, so their names ride along once in a shared table rather than
-- being repeated on every character.
--
-- v is the character as they last logged out, in this order:
--
--   crit, haste, mastery, spirit, strength, agility, intellect, stamina,
--   health, spell power, attack power
--
-- These are the played character, not a sum of the gear: every equipped item
-- reports its vendor stats, so gems, enchants and reforges are all absent
-- there and all present here. Blizzard derives the rating from the character's
-- percentage at a fixed rate, so passives are in it too. Hit and expertise are
-- not in their data at any depth.
--
-- Each slot is { itemID, enchantID, gem, gem, gem }, with 0 for no enchant.
-- The API reports gems as enchantments too, but hands back each gem's own
-- source_item, so gems are stored as real item ids the client can draw and only
-- the enchant text has to ship.
--
-- Region $Region, $($records.Count) characters, $($glyphNames.Count) glyph names, read $now.
ns.GLYPH_NAMES = ns.GLYPH_NAMES or {}

for id, name in pairs({
$glyphBody
}) do ns.GLYPH_NAMES[id] = name end

ns.ENCHANT_TEXT = ns.ENCHANT_TEXT or {}

for id, text in pairs({
$enchantBody
}) do ns.ENCHANT_TEXT[id] = text end

-- The item that applies each enchant, so the panel can name it the way you
-- would buy it rather than by what it does.
ns.ENCHANT_ITEM = ns.ENCHANT_ITEM or {}

for enchantID, itemID in pairs({
$enchantItemBody
}) do ns.ENCHANT_ITEM[enchantID] = itemID end

-- The spell a tinker casts, so its tooltip can say what it does rather than
-- only naming it.
ns.ENCHANT_SPELL = ns.ENCHANT_SPELL or {}

for enchantID, spellID in pairs({
$enchantSpellBody
}) do ns.ENCHANT_SPELL[enchantID] = spellID end

-- What a tinker does, worded as the game words it on the item itself.
ns.ENCHANT_USE = ns.ENCHANT_USE or {}

for enchantID, says in pairs({
$enchantUseBody
}) do ns.ENCHANT_USE[enchantID] = says end

ns.SET_OF_ITEM = ns.SET_OF_ITEM or {}

for itemID, setID in pairs({
$itemSetBody
}) do ns.SET_OF_ITEM[itemID] = setID end

ns.SET_NAMES = ns.SET_NAMES or {}

for id, name in pairs({
$setBody
}) do ns.SET_NAMES[id] = name end

ns.INSPECT_BY_REGION = ns.INSPECT_BY_REGION or {}

ns.INSPECT_BY_REGION["$Region"] = {
$recordBody
}
"@

# Nothing shipped empty without saying so.
#
# Twice now an edit has removed the block that filled one of these while leaving
# everything that reads it intact, and the run reported success both times: the
# gems lost their item-to-set map, so every set read 0/5, and the glyphs came
# out as "none glyphed" for the whole ladder. A table that should never be empty
# is worth one line to check.
foreach ($table in @(
    @{ Name = 'characters';      Count = $records.Count },
    @{ Name = 'glyph names';     Count = $glyphNames.Count },
    @{ Name = 'enchant strings'; Count = $enchantText.Count },
    @{ Name = 'set names';       Count = $setNames.Count },
    @{ Name = 'item to set';     Count = $setOfItem.Count }
)) {
    if ($table.Count -eq 0) { Write-Host ("  WARNING: {0} came out empty" -f $table.Name) }
}

Set-Content -Path $outFile -Value $out -Encoding utf8

# What everybody had played this run, so the next one can tell who moved.
# Written for the whole selection, fetched or carried, so a character who is
# skipped repeatedly is still measured against the run that actually read them.
$keep = New-Object System.Collections.Generic.List[string]
$null = $keep.Add("# Games played when each character was last read, so the next run can skip")
$null = $keep.Add("# anyone who has not played. Not shipped; deleting it costs one full pass.")
foreach ($key in ($wanted.Keys | Sort-Object)) {
    $null = $keep.Add(("{0}|{1}" -f $key, $wanted[$key].Games))
}
Set-Content -Path $gamesFile -Value ($keep -join "`n") -Encoding utf8

$size = [math]::Round((Get-Item $outFile).Length / 1KB)
Write-Log ("{0}: asked {1}, carried {2}, found {3}, missing {4}. {5} KB. requests={6}" -f `
    $Region.ToUpper(), $asked, $carried, $found, $missing, $size, $requests)
if ($wrong -gt 0) { Write-Host ("  {0} tiers did not come out clean." -f $wrong) }
