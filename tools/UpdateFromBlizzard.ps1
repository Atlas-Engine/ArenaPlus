# Cutoffs and ladder for ArenaPlus, read from Blizzard's own API.
#
# Replaces the third-party scrape this used to do. Everything taken from it is
# published first-party, and measured against the scrape on 2026-08-18 every one
# of the nineteen cutoff values matched exactly -- because the site was relaying
# these same numbers.
#
#   ratings, ranks, played, faction   pvp-leaderboard/{bracket}
#   title cutoffs                     pvp-reward/index
#   slot counts                       counted from the ladder, not published
#   class and spec                    NOT here -- the leaderboard has neither
#
# The game cannot do any of this itself: addons have no network access, so the
# fetching happens out here and is handed over as a file.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File "<path>\UpdateFromBlizzard.ps1"
#   powershell -ExecutionPolicy Bypass -File "<path>\UpdateFromBlizzard.ps1" -Region eu

param(
    [string]$Region = "us",
    # How deep to keep. "challenger" is the last real title: below it the API
    # publishes people on 96 rating who played one game and lost.
    [string]$Depth = "challenger",
    # Ask each character for their own rating rather than trusting the one in
    # the leaderboard snapshot.
    #
    # The snapshot is rebuilt on Blizzard's own clock and was measured three
    # hours behind. A character's pvp-bracket endpoint is written when they log
    # out and published within about five minutes of it -- not live, but hours
    # fresher, and it is what the third-party sites read. One request per ladder
    # row, roughly 5,900 a region.
    [switch]$Live,
    # Conditional requests: a character who has not logged out since the last
    # pass answers 304 with no body, which is the cheap majority of the ladder.
    # Off only for measuring what a cold pass costs.
    [switch]$NoConditional,
    # How many requests are in flight at once. Measured sequentially at 7.3 a
    # second against a published ceiling of 100, so the API was never the limit.
    [int]$Concurrency = 48,

    # Just under Blizzard's hundred a second. This pass is nothing but round
    # trips, so this -- not the processor, not the parsing -- is what decides
    # how long it takes.
    [int]$RatePerSecond = 80,

    # Only ask characters who have played lately.
    #
    # The live pass exists because Blizzard's leaderboard runs hours behind: a
    # character's own endpoint knew Lsdd was 1894 while the snapshot still said
    # 1871. Asking all 5,900 of them costs 5,900 requests, and measured on
    # 2026-08-23 only about 17% had touched their profile in the last two days.
    # The rest hit a rating and stopped playing; asking them again learns
    # nothing.
    #
    # So: anyone whose profile was written within this many days is asked every
    # run. 0 asks everybody, which is what the pass used to do.
    [int]$ActiveDays = 2,

    # Which game this pass is scraping.
    #
    # "mop" is the Classic progression realms, "tbc" the Anniversary ones. They
    # are different namespaces holding different ladders, and a character can
    # exist on both, so everything downstream has to keep them apart.
    #
    # The separation is done by re-keying $Region below rather than by threading
    # a version through forty call sites: $Region already names every output
    # file, every lock and progress file, every log label and -- the part that
    # matters -- the BY_REGION table keys the addon reads. Making it "tbc-eu"
    # gives all of that at once, and leaves MoP writing exactly what it always
    # wrote, so nothing on disk needs migrating.
    [ValidateSet("mop","tbc")]
    [string]$Version = "mop"
)

$ErrorActionPreference = "Stop"

# Dot-sourced here rather than beside Copy-ToOtherClients at the foot of
# the file, because Write-DataFile is needed long before that -- every
# shipped table goes through it.
. (Join-Path $PSScriptRoot "DataClients.ps1")

# The region as Blizzard addresses it -- the API host and the namespace suffix
# are always the bare "us"/"eu", whichever game this is.
$apiRegion = $Region

# ...and the region as everything of ours is keyed by. MoP keeps the bare name
# it has always used; anything else is qualified, so Leaderboard-eu.lua and
# Leaderboard-tbc-eu.lua sit side by side and neither overwrites the other.
if ($Version -ne "mop") { $Region = $Version + "-" + $Region }

$root       = Split-Path $PSScriptRoot -Parent
# Everything the passes write lives under Data\, so the addon root stays
# readable. Built once here: nine separate literals is nine chances for one
# to keep pointing at the old place, and a pass that writes where nothing
# reads fails silently.
# The data is its own addon now, a sibling of this one, so it can be
# published without republishing the code.
$data       = Join-Path (Split-Path $root -Parent) "ArenaPlus_Data"
$cutoffFile = Join-Path $data ("Cutoffs-" + $Region + ".lua")
$ladderFile = Join-Path $data ("Leaderboard-" + $Region + ".lua")
$logFile    = Join-Path $PSScriptRoot "UpdateFromBlizzard.log"
$credFile   = Join-Path $PSScriptRoot "blizzard-credentials.txt"

$TimeFormat = 'yyyy-MM-dd hh:mm tt'

function Write-Log([string]$message) {
    Add-Content -Path $logFile -Value ("{0}  {1}" -f (Get-Date -Format $TimeFormat), $message) -Encoding utf8
    Write-Host $message
}

function Escape-Lua([string]$text) {
    if ($null -eq $text) { return "" }
    $text = $text -replace '\\', '\\'
    $text = $text -replace '"', '\"'
    return $text.Trim()
}

# ---------------------------------------------------------------- auth

if (-not (Test-Path $credFile)) {
    Write-Log "No blizzard-credentials.txt - see blizzard-credentials.example.txt."
    return
}

$clientId = $null; $clientSecret = $null
foreach ($line in Get-Content $credFile) {
    if ($line -match '^\s*ClientId\s*=\s*(.+?)\s*$')     { $clientId = $Matches[1] }
    if ($line -match '^\s*ClientSecret\s*=\s*(.+?)\s*$') { $clientSecret = $Matches[1] }
}
if (-not $clientId -or -not $clientSecret) { Write-Log "Credentials file is incomplete."; return }

$pair  = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$clientId`:$clientSecret"))
$token = (Invoke-RestMethod -Method Post -Uri "https://oauth.battle.net/token" `
            -Headers @{ Authorization = "Basic $pair" } -Body @{ grant_type = "client_credentials" }).access_token
if (-not $token) { Write-Log "No access token."; return }

# TBC Anniversary lives in its own namespace pair. "classicann" is not a
# pattern anyone guesses -- classic2x, anniversary, classic-tbc and a dozen
# other shapes all 403. See _brain/LESSONS.md.
$namespace = if ($Version -eq "tbc") { "dynamic-classicann-$apiRegion" }
             else                    { "dynamic-classic-$apiRegion" }

# Characters live under a different namespace from game data, and this script
# had never needed one until the live pass was added. Left undefined it becomes
# an empty string, every URL asks for "namespace=", and all 5,915 requests fail
# -- which the counter dutifully reported as "unreadable" without anyone
# noticing that "all of them" is not a plausible number.
$profileNs = if ($Version -eq "tbc") { "profile-classicann-$apiRegion" }
             else                    { "profile-classic-$apiRegion" }
$apiRoot   = "https://$apiRegion.api.blizzard.com"
$headers   = @{ Authorization = "Bearer $token" }

$script:requests = 1   # the token exchange itself

# The response, and when Blizzard last built what is in it.
#
# Last-Modified is the only honest measure of how fresh the ladder is. Measured
# 2026-08-21: the leaderboards were rebuilt at 20:19 GMT and read at 22:12, so
# what we fetched was nearly two hours old, and a rating that had moved since
# was not in it at any price. Running the task again cannot help -- there is
# nothing newer to fetch, and the character profile endpoint is worse still, at
# eleven hours.
#
# So the file records both: when Blizzard built it, and when we read it. The
# stamp that used to be shown was ours, which overstated freshness.
$script:snapshot = ""

function Get-Api([string]$path) {
    $script:requests++
    $sep = if ($path.Contains("?")) { "&" } else { "?" }
    $uri = "{0}{1}{2}namespace={3}&locale=en_US" -f $apiRoot,$path,$sep,$namespace

    $response = Invoke-WebRequest -Uri $uri -Headers $headers -UseBasicParsing

    $stamp = $response.Headers['Last-Modified']
    if ($stamp) {
        # The newest of them, though all four brackets have always shared one.
        $when = [datetime]::MinValue
        if ([datetime]::TryParse($stamp, [ref]$when)) {
            $asText = $when.ToUniversalTime().ToString('yyyy-MM-dd HH:mm')
            if ($asText -gt $script:snapshot) { $script:snapshot = $asText }
        }
    }

    return $response.Content | ConvertFrom-Json
}

# ---------------------------------------------------------------- plumbing

# How many connections .NET will open to one host at a time.
#
# The default is two. Measured 2026-08-22 on a pass asking for sixteen at once:
# two established connections and fourteen runspaces queued behind them. The
# pool was never the limit; this was. Raised to the concurrency actually asked
# for, with headroom for the token endpoint.
[System.Net.ServicePointManager]::DefaultConnectionLimit = [Math]::Max($Concurrency + 4, 16)

# A handshake round trip saved on every request. Nothing here posts a body big
# enough for the negotiation to earn its cost.
[System.Net.ServicePointManager]::Expect100Continue = $false

# ---------------------------------------------------------------- progress

# Same file the specs pass writes, so the dashboard has one thing to read and
# one format to parse. This run is a dozen requests rather than five thousand,
# but it is still the difference between "working" and "hung" to anyone
# watching -- and it is the only way a run started outside the app is visible.
# ---------------------------------------------------------------- one at a time

# One run per region, and no more.
#
# Two of these writing the same files at once will not merge: the last one to
# finish wins, and whatever the other had done is gone. It nearly happened on
# 2026-08-23, when a pass started by hand and the scheduled one landed on EU
# within the same minute -- the file survived only because both were doing
# almost identical work.
#
# The scheduler will not overlap a task with itself, so this is about the cases
# it cannot see: a run started by hand, by the dashboard's button, or by another
# task that shares the script.
#
# The owner's process id rather than a bare flag, so a run that died without
# tidying up cannot lock the job out for ever: if the process named here is
# gone, the lock is a leftover and this run takes it.
# One lock for every pass, not one per pass per region.
#
# Each pass paces itself to $RatePerSecond and knows nothing of the others,
# so two running together ask for twice that -- past what Blizzard answers,
# which it handles by refusing rather than by complaining. A refused
# character is indistinguishable from one that does not exist, so the cost
# lands as silently wrong data rather than as an error.
#
# Eight scheduled passes across two games made that a matter of time, so
# they take turns instead: whoever is second says so and leaves. Nothing is
# lost by waiting -- specs and inspect are incremental, and the ladder pass
# runs again in fifteen minutes.
$lockFile = Join-Path $PSScriptRoot "ArenaPlus-fetch.lock"
$passLabel = "ladder $Region"

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
            # Line two names the pass, so the log says what to wait for
            # rather than only that something is in the way.
            $busy = ""
            try { $busy = (Get-Content $lockFile -TotalCount 2)[1] } catch { }
            if ($busy) { Write-Host ("Waiting: {0} is running (process {1})." -f $busy, $owner) }
            else       { Write-Host ("Waiting: another pass is running (process {0})." -f $owner) }
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
$writer.WriteLine($passLabel)
$writer.Flush()

$progressFile = Join-Path $PSScriptRoot ("UpdateFromBlizzard-" + $Region + ".progress")
$startedAt = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$script:step = 0

# Season, a cutoff and a ladder for each bracket, then the write.
$totalSteps = 10

function Step-Progress {
    $script:step++
    Set-Content -Path $progressFile -Encoding utf8 -Value `
        ("ladder|{0}|{1}|{2}|{3}|steps" -f $Region, $script:step, $totalSteps, $startedAt)
}

# The live pass is the long part -- thousands of requests after the ten steps
# are done -- and it reported nothing, so the bar sat at 9 of 10 for eight
# minutes and read as stuck. It counts characters, not steps, and says so.
function Live-Progress([int]$done,[int]$total) {
    Set-Content -Path $progressFile -Encoding utf8 -Value `
        ("ladder|{0}|{1}|{2}|{3}|characters" -f $Region, $done, $total, $startedAt)
}

# ---------------------------------------------------------------- season

$season = (Get-Api "/data/wow/pvp-season/index").current_season.id
if (-not $season) { Write-Log "No current season."; return }

# The addon indexes brackets 1-4; the API names them, and calls rated
# battlegrounds BATTLEGROUNDS in rewards but rbg in leaderboards.
$brackets = @(
    @{ Index = 1; Api = "2v2"; Reward = "ARENA_2v2" },
    @{ Index = 2; Api = "3v3"; Reward = "ARENA_3v3" },
    @{ Index = 3; Api = "5v5"; Reward = "ARENA_5v5" },
    @{ Index = 4; Api = "rbg"; Reward = "BATTLEGROUNDS" }
)

# Rated battlegrounds arrived in Cataclysm, so TBC has three brackets and not
# four. Dropped here rather than tolerated as an empty fourth: asking for a
# leaderboard that cannot exist spends a request to be told 404, once a run,
# and writes a bracket the addon would then have to know was always empty.
if ($Version -eq "tbc") { $brackets = $brackets | Where-Object { $_.Api -ne "rbg" } }

# ---------------------------------------------------------------- cutoffs

# Which achievement names which title. Rank one is the seasonal Gladiator title
# -- "Grievous Gladiator: Season 14" -- so it is matched before the plain
# Gladiator line, which would otherwise swallow it. Rated battlegrounds have no
# Gladiator at all; their top award is Hero of the Faction.
Step-Progress
$rewards = (Get-Api "/data/wow/pvp-season/$season/pvp-reward/index").rewards
$cutoffs = @{}

foreach ($bracket in $brackets) {
    Step-Progress
    $values = [ordered]@{}
    foreach ($reward in $rewards) {
        if ($reward.bracket.type -ne $bracket.Reward) { continue }
        $name = $reward.achievement.name

        $tier = $null
        if     ($name -match 'Hero of the Faction') { $tier = 'r1' }
        elseif ($name -match '^\w+ Gladiator:')       { $tier = 'r1' }
        # TBC names its rank-one title without a season suffix -- "Vengeful
        # Gladiator", not "Vengeful Gladiator: Season 3" -- so the pattern above
        # slides straight past it and the season would ship with no r1 cutoff.
        # Anchored at both ends so it cannot swallow the plain "Gladiator:" line.
        elseif ($name -match '^\w+ Gladiator$')      { $tier = 'r1' }
        elseif ($name -match '^Gladiator:')         { $tier = 'gladiator' }
        elseif ($name -match '^Duelist:')           { $tier = 'duelist' }
        elseif ($name -match '^Rival:')             { $tier = 'rival' }
        elseif ($name -match '^Challenger:')        { $tier = 'challenger' }

        if ($tier) { $values[$tier] = [int]$reward.rating_cutoff }
    }
    $cutoffs[$bracket.Index] = $values
}

# ---------------------------------------------------------------- ladder

$fetched = @{}
$slots   = @{}
$total   = 0

foreach ($bracket in $brackets) {
    Step-Progress
    $floor = $cutoffs[$bracket.Index][$Depth]
    $board = Get-Api "/data/wow/pvp-season/$season/pvp-leaderboard/$($bracket.Api)"
    $all   = @($board.entries)

    # Everything at or above the depth. 2v2 is capped by Blizzard at about five
    # thousand places and stops short of Challenger, so this keeps all of it and
    # the file says so rather than implying the ladder ends there.
    $kept = if ($null -eq $floor) { $all } else { @($all | Where-Object { $_.rating -ge $floor }) }
    $lowest = if ($all.Count -gt 0) { ($all | Measure-Object rating -Minimum).Minimum } else { 0 }
    $capped = ($all.Count -gt 0 -and $null -ne $floor -and $lowest -gt $floor)

    $fetched[$bracket.Index] = @{ Rows = $kept; Capped = $capped; Floor = $floor }
    $total += $kept.Count

    # Not published anywhere: counted off the ladder itself.
    #
    # Every tier, not just the two fixed-count ones. Duelist, Rival and
    # Challenger are percentages of the field rather than a fixed number of
    # places, but the question a reader has is the same either way -- how
    # many people hold this title -- and the ladder can answer it.
    #
    # Only where the ladder actually reaches past the cutoff. Blizzard caps
    # what it publishes -- 2v2 stops around five thousand places, above the
    # Challenger line -- so counting a tier the list stops short of gives a
    # floor dressed up as a total. $lowest is the deepest rating returned;
    # if it does not get below the cutoff, the count is not knowable and the
    # tier is left out rather than under-reported.
    $counts = [ordered]@{}
    foreach ($tier in @('r1','gladiator','duelist','rival','challenger')) {
        $rating = $cutoffs[$bracket.Index][$tier]
        if ($rating -and $all.Count -gt 0 -and $lowest -le $rating) {
            $counts[$tier] = @($all | Where-Object { $_.rating -ge $rating }).Count
        }
    }
    $slots[$bracket.Index] = $counts

    Write-Host ("{0}: {1} of {2} kept, down to {3}{4}" -f `
        $bracket.Api, $kept.Count, $all.Count, $floor, $(if ($capped) { ' (API stops above the cutoff)' } else { '' }))
}

# ---------------------------------------------------------------- live

# Each character's own rating, which is usually fresher than the ladder's copy.
#
# Measured 2026-08-21: the leaderboard said 1799 for a character whose real
# rating was 1952. The character's own pvp-bracket endpoint said 1952, written
# five minutes after they logged out. The write is gated on logging out --
# tested by doing exactly that -- so this is "as of their last session", not
# live, and the addon says so rather than claiming more than it has.
#
# Which also means it is not always the fresher of the two: for somebody who has
# not played in a month, their own record is a month old while the snapshot has
# kept up. The guard in the write section below picks between them.
#
# Sent several at a time. Measured sequentially at 7.3 requests a second, which
# is 7% of what Blizzard allows, and it took fourteen minutes: the time was
# almost entirely waiting for round trips rather than doing anything.
#
# Conditional requests are kept even though they barely help the clock -- a warm
# pass measured 5,590 of 5,915 answering 304 and still took eleven minutes,
# because a 304 costs the same round trip. They save Blizzard the work and us
# the parsing, which is worth keeping even when it does not save time.
$liveRatings = @{}
$liveFile = Join-Path $PSScriptRoot ("LiveCache-" + $Region + ".txt")
$fresh = 0
$unchanged = 0
$gone = 0
$staleSeason = 0
$lastReason = ""

# Requests Blizzard turned away for coming too fast.
#
# The rate cap above is set from their published hundred a second, and a
# published limit is not the same as the one actually enforced. Counted every
# run so that if the cap is ever wrong it says so, rather than quietly losing
# a few hundred characters into the unreadable pile.
$throttled = 0

if ($Live) {
    # What the last pass learned, so unchanged characters cost a 304 rather than
    # a full response -- and so a 304 still has a rating to keep.
    $cache = @{}
    if (Test-Path $liveFile) {
        foreach ($line in Get-Content $liveFile) {
            # Tabs, not pipes: the key is "bracket|name|realm", and splitting on
            # the pipe fed the rating field a realm name.
            $bits = $line -split "`t"
            if ($bits.Count -ge 5) {
                $cache[$bits[0]] = @{ Rating = [int]$bits[1]; Won = [int]$bits[2]; Lost = [int]$bits[3]; Written = $bits[4] }
            }
        }
    }

    # Everything to ask about, flattened first so the work can be handed out.
    $work = New-Object System.Collections.Generic.List[object]
    foreach ($bracket in $brackets) {
        foreach ($entry in $fetched[$bracket.Index].Rows) {
            $realm = $entry.character.realm.slug
            $lower = $entry.character.name.ToLower()
            $key = "{0}|{1}|{2}" -f $bracket.Index, $lower, $realm
            $known = $cache[$key]

            $work.Add([pscustomobject]@{
                Key   = $key
                Uri   = "$apiRoot/profile/wow/character/$realm/$([uri]::EscapeDataString($lower))/pvp-bracket/$($bracket.Api)?namespace=$profileNs&locale=en_US"
                Since = $(if ($known) { $known.Written } else { $null })
            })
        }
    }

    # Everyone still playing, plus everyone we have never asked about.
    #
    # A character with no cache entry has to be asked once before there is
    # anything to judge them by, and a returning player is caught by that same
    # rule the moment their profile is written again -- until then the snapshot
    # covers them, which is exactly what it did before this pass existed.
    if ($ActiveDays -gt 0) {
        $cutoff = (Get-Date).ToUniversalTime().AddDays(-$ActiveDays)
        $hot = New-Object System.Collections.Generic.List[object]
        $cold = 0

        foreach ($item in $work) {
            $known = $cache[$item.Key]
            $keep = $true

            if ($known -and $known.Written) {
                $when = [datetime]::MinValue
                if ([datetime]::TryParse($known.Written, [ref]$when)) {
                    if ($when.ToUniversalTime() -lt $cutoff) { $keep = $false }
                }
            }

            if ($keep) { $hot.Add($item) } else { $cold++ }
        }

        # Logged, not just printed.
        #
        # This one line decides the size of the run -- everything else the
        # pass does costs six requests -- and it was Write-Host only, which
        # in a scheduled run means nowhere: RunHidden.vbs gives it no
        # console. So the log recorded a total with no way to see what drove
        # it, and an audit done from the log alone read the budget wrong by
        # a factor of three.
        Write-Host ("{0} of {1} characters played in the last {2} days; {3} skipped." -f `
            $hot.Count, $work.Count, $ActiveDays, $cold)
        Write-Log ("{0}: {1} of {2} characters hot within {3}d, {4} skipped." -f `
            $Region.ToUpper(), $hot.Count, $work.Count, $ActiveDays, $cold)

        # Whatever is skipped keeps the reading it already had, so the addon
        # still shows a live figure for them -- just an older one.
        foreach ($item in $work) {
            if ($cache.ContainsKey($item.Key) -and -not $liveRatings.ContainsKey($item.Key)) {
                $known = $cache[$item.Key]
                $liveRatings[$item.Key] = @{ Rating = $known.Rating; Won = $known.Won; Lost = $known.Lost; Written = $known.Written }
            }
        }

        $work = $hot
    }

    Write-Host ("Asking {0} characters for their own rating, {1} at a time." -f $work.Count, $Concurrency)
    Live-Progress 0 $work.Count

    # One request, in its own runspace. Self-contained on purpose: a runspace
    # inherits nothing from here, so everything it needs arrives as an argument.
    $one = {
        param($uri, $auth, $since)

        $ask = @{ Authorization = $auth }
        if ($since) { $ask['If-Modified-Since'] = $since }

        # Turned away for going too fast is worth one more go.
        #
        # Measured 2026-08-22: holding to ninety a second, under Blizzard's
        # published hundred, still had twenty-nine of 5,891 refused -- the limit
        # is enforced on bursts finer than a whole second, which no rate this
        # side of the wire can perfectly smooth. Cheaper to ask those few again
        # than to slow all six thousand down for them.
        for ($attempt = 1; $attempt -le 2; $attempt++) {
            try {
                # Timed out rather than trusted.
                #
                    # Without this the call waits forever on a connection that is
                # open and silent, and the loop below waits with it. Measured
                # 2026-08-22: a pass stopped dead at character 3,008 and was still
                # sitting there twelve hours later, holding two connections and
                # using no processor at all. One slow character costing a retry is
                # a far smaller loss than a pass that never ends.
                $response = Invoke-WebRequest -Uri $uri -Headers $ask -UseBasicParsing -ErrorAction Stop -TimeoutSec 30
                $body = $response.Content | ConvertFrom-Json
                [pscustomobject]@{
                    Status  = 'ok'
                    Season  = [int]$body.season.id
                    Rating  = [int]$body.rating
                    Won     = [int]$body.season_match_statistics.won
                    Lost    = [int]$body.season_match_statistics.lost
                    Written = $response.Headers['Last-Modified']
                }
            } catch {
                $code = $_.Exception.Response.StatusCode.value__

                # Backed off and tried again, once.
                if ($code -eq 429 -and $attempt -lt 2) {
                    Start-Sleep -Milliseconds 400
                    continue
                }

                [pscustomobject]@{
                    Status = $(if ($code -eq 304) { 'same' } else { 'fail' })
                    Reason = $(if ($code) { "HTTP $code" } else { $_.Exception.Message })
                }
            }

            break
        }
    }

    # Longer than the request timeout inside the runspace, so a request that
    # times out cleanly reports itself rather than being abandoned here.
    $ShellTimeoutMs = 45000

    $pool = [runspacefactory]::CreateRunspacePool(1, $Concurrency)
    $pool.Open()

    try {
        $done = 0
        $lastReport = 0
        $lastSaid = 0

        # A sliding window, not batches.
        #
        # Batches sent sixteen and waited for all sixteen, so every batch cost
        # as much as its slowest member while the other fifteen slots sat empty
        # waiting for it. Response times vary by an order of magnitude from one
        # character to the next, so that is not a rounding error: it is most of
        # the time.
        #
        # This keeps $Concurrency requests in the air continuously -- a slot
        # refills the instant its own answer lands, whatever the others are
        # doing.
        $inFlight = New-Object System.Collections.Generic.List[object]
        $next = 0

        # Blizzard allows a hundred requests a second. Left alone this loop
        # would go straight through that, and a 429 wastes the whole request,
        # so it is held just under the line rather than discovering where the
        # line is.
        $windowStart = [datetime]::UtcNow
        $windowCount = 0

        while ($next -lt $work.Count -or $inFlight.Count -gt 0) {

            # Fill every free slot.
            while ($inFlight.Count -lt $Concurrency -and $next -lt $work.Count) {

                # A second's worth already sent, so wait out the rest of it.
                if ($windowCount -ge $RatePerSecond) {
                    $spent = ([datetime]::UtcNow - $windowStart).TotalMilliseconds
                    if ($spent -lt 1000) { Start-Sleep -Milliseconds ([int](1000 - $spent)) }
                    $windowStart = [datetime]::UtcNow
                    $windowCount = 0
                } elseif (([datetime]::UtcNow - $windowStart).TotalMilliseconds -ge 1000) {
                    $windowStart = [datetime]::UtcNow
                    $windowCount = 0
                }

                $item = $work[$next]
                $next++

                $shell = [powershell]::Create()
                $shell.RunspacePool = $pool
                $null = $shell.AddScript($one).AddArgument($item.Uri).AddArgument($headers.Authorization).AddArgument($item.Since)

                $inFlight.Add([pscustomobject]@{
                    Shell   = $shell
                    Handle  = $shell.BeginInvoke()
                    Item    = $item
                    Started = [datetime]::UtcNow
                })
                $windowCount++
            }

            # Collect whatever has landed, in whatever order it landed.
            # Backwards, because finished ones are removed as they are read.
            $landed = 0
            for ($i = $inFlight.Count - 1; $i -ge 0; $i--) {
                $job = $inFlight[$i]
                $overdue = (([datetime]::UtcNow - $job.Started).TotalMilliseconds -gt $ShellTimeoutMs)

                if (-not $job.Handle.IsCompleted -and -not $overdue) { continue }

                $answer = $null

                # Belt as well as braces. The timeout above is inside the
                # runspace and covers the request; this covers the runspace
                # itself, so that whatever goes wrong in there -- a hang below
                # the timeout, a thread that never comes back -- costs this one
                # character rather than the pass.
                if ($job.Handle.IsCompleted) {
                    try { $answer = $job.Shell.EndInvoke($job.Handle) | Select-Object -First 1 } catch { }
                    $job.Shell.Dispose()
                } else {
                    # Abandoned, not waited on: Stop and Dispose would both
                    # block on the very thread that is refusing to finish.
                    try { $null = $job.Shell.BeginStop($null, $null) } catch { }
                    $lastReason = "runspace did not return in {0}s" -f [int]($ShellTimeoutMs / 1000)
                }

                $inFlight.RemoveAt($i)
                $landed++

                $script:requests++
                $done++
                $known = $cache[$job.Item.Key]

                # The season the character is talking about.
                #
                # This endpoint answers with their last ACTIVE season for the
                # bracket, not the current one. Kjx last played 3v3 seriously in
                # season 12 and their profile still says so -- rating 2960,
                # 573-355 -- while season 14 has them 16-0 at 1525. Taken at
                # face value it put a two-season-old peak at the top of the
                # ladder, ahead of the actual rank one on 2590.
                #
                # An exact test, where the games-played guard below is only an
                # inference: that one let Kjx through, because a stale season
                # has *more* games rather than fewer.
                if ($answer -and $answer.Status -eq 'ok' -and $answer.Season -ne $season) {
                    $staleSeason++
                    if ($known) { $liveRatings[$job.Item.Key] = @{ Rating = $known.Rating; Won = $known.Won; Lost = $known.Lost; Written = $known.Written } }
                } elseif ($answer -and $answer.Status -eq 'ok') {
                    $liveRatings[$job.Item.Key] = @{ Rating = $answer.Rating; Won = $answer.Won; Lost = $answer.Lost; Written = $answer.Written }
                    $fresh++
                } elseif ($answer -and $answer.Status -eq 'same' -and $known) {
                    # Nothing new since last time: keep what we had.
                    $liveRatings[$job.Item.Key] = @{ Rating = $known.Rating; Won = $known.Won; Lost = $known.Lost; Written = $known.Written }
                    $unchanged++
                } else {
                    # A hidden profile, or one that has moved. The last thing it
                    # said is still better than the snapshot's guess.
                    if ($known) {
                        $liveRatings[$job.Item.Key] = @{ Rating = $known.Rating; Won = $known.Won; Lost = $known.Lost; Written = $known.Written }
                    }
                    if ($answer -and $answer.Reason) {
                        $lastReason = $answer.Reason
                        if ($answer.Reason -eq "HTTP 429") { $throttled++ }
                    }
                    $gone++
                }
            }

            # Nothing landed this time round: everything in the air is still in
            # the air. A short wait here is the difference between waiting and
            # spinning a processor core to do it.
            if ($landed -eq 0) { Start-Sleep -Milliseconds 10 }

            # Written often, because this file is how the window tells a run
            # that is working from one that has stopped. Every hundred rather
            # than every five hundred: at the speed this now goes, five hundred
            # is several seconds of apparent silence.
            if ($done - $lastReport -ge 100) {
                $lastReport = $done
                Live-Progress $done $work.Count
            }

            if ($done - $lastSaid -ge 1000) {
                $lastSaid = $done
                Write-Host ("  {0} of {1}: {2} new, {3} unchanged, {4} unreadable" -f $done, $work.Count, $fresh, $unchanged, $gone)
            }
        }
    } finally {
        $pool.Close()
        $pool.Dispose()
    }

    # Kept for the next pass's conditional requests.
    $keep = New-Object System.Collections.Generic.List[string]
    $null = $keep.Add("# What each character last said about themselves, so the next pass can ask")
    $null = $keep.Add("# conditionally. Not shipped; safe to delete, at the cost of one cold pass.")
    foreach ($key in ($liveRatings.Keys | Sort-Object)) {
        $it = $liveRatings[$key]
        $null = $keep.Add(("{0}`t{1}`t{2}`t{3}`t{4}" -f $key, $it.Rating, $it.Won, $it.Lost, $it.Written))
    }
    Set-Content -Path $liveFile -Value ($keep -join "`n") -Encoding utf8

    Write-Host ("Live pass: {0} new, {1} unchanged, {2} unreadable, {3} answering about an older season." -f `
        $fresh, $unchanged, $gone, $staleSeason)

    # Loudly, because the fix is a smaller -RatePerSecond and there is no way to
    # guess that from a pass that merely looks a bit lossy.
    if ($throttled -gt 0) {
        Write-Host ("  {0} of those were refused for going too fast. Lower -RatePerSecond." -f $throttled)
        Write-Log ("{0}: {1} requests throttled at {2}/sec." -f $Region.ToUpper(), $throttled, $RatePerSecond)
    }

    # Some characters always fail -- hidden profiles, renames, transfers. All of
    # them failing is not that, and it means the pass achieved nothing while
    # spending the whole budget. Said loudly, with the reason attached.
    if ($fresh -eq 0 -and $unchanged -eq 0 -and $gone -gt 0) {
        Write-Log ("{0}: LIVE PASS FAILED -- every one of {1} characters was unreadable. Last reason: {2}" -f `
            $Region.ToUpper(), $gone, $lastReason)
    }
}


# ---------------------------------------------------------------- write

Step-Progress
$now = Get-Date -Format $TimeFormat

# The same moment with no timezone to get wrong.
#
# $now is this machine's local time and carries no zone, and the addon read
# it back as the READER's local clock -- so everyone outside this timezone
# saw an age off by the whole offset between the two. Reported from an
# Australian realm as a fourteen hour old file minutes after it published,
# which is EDT to AEST to the hour.
$nowEpoch = [int][math]::Floor(((Get-Date).ToUniversalTime() - [datetime]'1970-01-01').TotalSeconds)

# "updated" only moves when a cutoff actually moved; "checked" moves every run.
$stamp = $now
if (Test-Path $cutoffFile) {
    $existing = Get-Content $cutoffFile -Raw
    $same = $true
    foreach ($bracket in $brackets) {
        foreach ($tier in $cutoffs[$bracket.Index].Keys) {
            $pattern = ('\[{0}\] = \{{[^}}]*{1}={2}\b' -f $bracket.Index,$tier,$cutoffs[$bracket.Index][$tier])
            if ($existing -notmatch $pattern) { $same = $false }
        }
    }
    if ($same) {
        $previous = [regex]::Match($existing,'updated\s*=\s*"([^"]+)"')
        if ($previous.Success) { $stamp = $previous.Groups[1].Value }
    }
}

$cutoffBody = ($brackets | ForEach-Object {
    $parts = ($cutoffs[$_.Index].GetEnumerator() | ForEach-Object { "{0}={1}" -f $_.Key,$_.Value }) -join ", "
    "`t[{0}] = {{ {1} }}, -- {2}" -f $_.Index,$parts,$_.Api
}) -join "`n"

$slotBody = ($brackets | ForEach-Object {
    $parts = ($slots[$_.Index].GetEnumerator() | ForEach-Object { "{0}={1}" -f $_.Key,$_.Value }) -join ", "
    "`t[{0}] = {{ {1} }}, -- {2}" -f $_.Index,$parts,$_.Api
}) -join "`n"

$cutoffOut = @"
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

-- Arena title cutoffs, written by tools\UpdateFromBlizzard.ps1 from Blizzard's
-- own API. Do not edit by hand: rerun the script to refresh.
--
-- Region $Region, season $season, cutoffs last changed $stamp, last checked $now.
ns.CUTOFFS_BY_REGION = ns.CUTOFFS_BY_REGION or {}

ns.CUTOFFS_BY_REGION["$Region"] = {
`tregion  = "$Region",
`tupdated = "$stamp",
`tchecked = "$now",
`tcheckedEpoch = $nowEpoch,

$cutoffBody
}

-- How many places each fixed-count title is worth. Blizzard does not publish
-- these, so they are counted off the ladder: everybody at or above the cutoff.
ns.CUTOFF_SLOTS_BY_REGION = ns.CUTOFF_SLOTS_BY_REGION or {}

ns.CUTOFF_SLOTS_BY_REGION["$Region"] = {
$slotBody
}
"@

Write-DataFile -Path $cutoffFile -Value $cutoffOut

# Last week's standing, for the change columns.
#
# No extra requests: it is a copy of what was written a week ago, kept beside
# the script. Replaced once it is more than seven days old, so the comparison is
# always against roughly a week and never against this morning.
$baselineFile = Join-Path $PSScriptRoot ("Baseline-" + $Region + ".txt")
$baseline = @{}
$baselineDate = ""

if (Test-Path $baselineFile) {
    foreach ($line in Get-Content $baselineFile) {
        if ($line.StartsWith("# taken ")) { $baselineDate = $line.Substring(8); continue }
        if ($line.StartsWith("#")) { continue }
        # Split on a tab, not a pipe: the key is itself "bracket|name|realm",
        # so splitting on the pipe handed the rating field the character's name
        # and nothing ever matched. Every row silently had no change to show.
        $bits = $line -split "`t"
        if ($bits.Count -ge 3) { $baseline[$bits[0]] = @{ Rating = [int]$bits[1]; Rank = [int]$bits[2] } }
    }
}

$baselineAge = 999
if ($baselineDate) {
    $taken = [datetime]::MinValue
    if ([datetime]::TryParse($baselineDate, [ref]$taken)) { $baselineAge = ((Get-Date) - $taken).TotalDays }
}

$refused = 0
$rows = New-Object System.Collections.Generic.List[string]
# Which realms this region's ladder actually mentions, so the name table
# below carries those and not the fifty in Blizzard's index.
$usedRealms = @{}
$nextBaseline = New-Object System.Collections.Generic.List[string]
$null = $nextBaseline.Add("# Where everybody stood a week ago, for the change columns. Not shipped.")
$null = $nextBaseline.Add("# taken " + (Get-Date).ToString('yyyy-MM-dd HH:mm'))

# ---------------------------------------------------------------- activity

# Who actually played, each time this runs.
#
# The shipped files are a photograph: where everybody stands right now. Almost
# every interesting question is about the film instead -- who is queuing at this
# moment, what somebody's rating did over a week, whether a run of losses is a
# slump or a bad night, which characters are never online at the same time as
# each other. None of that can be recovered later: a poll not written down is
# gone, and no amount of asking Blizzard afterwards brings it back. So it is
# written down now and what to do with it is decided later.
#
# The diff is free. Every row is already in hand and already compared against
# the weekly baseline a few lines below; this compares against the LAST poll
# rather than against last week, and keeps only the rows that moved.
#
# Deliberately not alt-shaped. It records what happened -- character, when,
# rating, games -- and nothing inferred, so it can answer questions nobody has
# asked yet rather than only the one that prompted it.
#
# Not shipped, like Baseline-*.txt beside it. One file per month, because
# pruning history means deleting a file rather than rewriting a large one, and
# because anything reading it usually wants a recent window rather than all of
# it.
$activityFile = Join-Path $PSScriptRoot ("Activity-" + $Region + "-" + (Get-Date).ToString('yyyy-MM') + ".tsv")
$lastFile     = Join-Path $PSScriptRoot ("LastPoll-" + $Region + ".txt")

# key|bracket -> "rating won lost", as of the previous run.
$lastPoll = @{}
if (Test-Path $lastFile) {
    foreach ($line in Get-Content $lastFile) {
        if ($line.StartsWith("#")) { continue }
        $bit = $line -split "`t"
        if ($bit.Count -ge 4) {
            $lastPoll[$bit[0]] = [pscustomobject]@{
                Rating = [int]$bit[1]; Won = [int]$bit[2]; Lost = [int]$bit[3]
            }
        }
    }
}

$nextPoll = New-Object System.Collections.Generic.List[string]
$null = $nextPoll.Add("# Where everybody stood at the previous poll, to diff the next one against.")
$null = $nextPoll.Add("# Not shipped. Safe to delete: it costs one poll to rebuild, losing one window.")
$activity = New-Object System.Collections.Generic.List[string]
# Epoch by arithmetic, not by parsing. -UFormat %s hands back a string, and
# [double]::Parse reads it in the current culture -- on a machine whose
# decimal separator is a comma that either throws or silently misreads, and
# this runs unattended where nobody would see either.

# ---------------------------------------------------------------- best
#
# The highest rating we have ever seen each character at, this season.
#
# Blizzard does not publish one. Verified 2026-09-11 against
# profile-classic-us: the character pvp-bracket document carries `rating`,
# `season_match_statistics` and `weekly_match_statistics` and nothing
# season-best shaped. Its `tier` object looks promising and is not -- tier.id
# comes back 0 for a 2641-rated player and /data/wow/pvp-tier/{id} is 404 on
# every Classic namespace, so the field is present but unpopulated.
#
# So it is remembered rather than asked for: each run compares the rating it
# already has against the highest previously recorded. That costs no requests
# at all, which matters -- the alternative discussed was a second call per
# character, and there are six thousand of them.
#
# Its own file rather than a column in LiveCache-*.txt, for two reasons. That
# file says on its first line that it is safe to delete at the cost of one
# cold pass, and that has to stay true -- a season of history is not one cold
# pass. And it only holds characters the live pass asked about, while this
# needs every row on the ladder, including the four fifths that -ActiveDays
# skips.
#
# Keyed by season, and dropped wholesale when the season turns: a best from
# season 13 is not a fact about season 14, and carrying it over would show
# every returning player a peak they cannot match yet.
$bestFile = Join-Path $PSScriptRoot ("Best-" + $Region + ".txt")
$best = @{}
$bestSeason = 0

if (Test-Path $bestFile) {
    foreach ($line in Get-Content $bestFile) {
        if ($line.StartsWith("#")) {
            if ($line -match '^#\s*season\s*=\s*(\d+)') { $bestSeason = [int]$Matches[1] }
            continue
        }
        $bits = $line -split "`t"
        if ($bits.Count -ge 2) { $best[$bits[0]] = [int]$bits[1] }
    }
}

if ($bestSeason -ne $season) {
    if ($bestSeason -gt 0) {
        Write-Host ("Season {0} replaces {1}: starting the best-rating history again." -f $season, $bestSeason)
    }
    $best = @{}
}

foreach ($bracket in $brackets) {
    $info = $fetched[$bracket.Index]
    $note = if ($info.Capped) { ' -- the API stops here, short of the cutoff' } else { '' }
    $rows.Add(("`t[{0}] = {{  -- {1}, {2} places, down to rating {3}{4}" -f `
        $bracket.Index,$bracket.Api,$info.Rows.Count,$info.Floor,$note))

    # What each row actually says, once the character's own answer is preferred
    # over the snapshot's copy of it.
    $ordered = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $info.Rows) {
        $key = "{0}|{1}|{2}" -f $bracket.Index, $entry.character.name.ToLower(), $entry.character.realm.slug
        $mine = $liveRatings[$key]

        # Whichever of the two has seen more games, which is whichever is more
        # recent.
        #
        # The two sources are not "stale ladder, fresh character" -- that was the
        # first reading and it is wrong. A character's own record is written when
        # they log out, so it is hours ahead of the snapshot for somebody who
        # just played and a month behind for somebody who has not. Blizzard's
        # snapshot is a couple of hours old but covers everybody.
        #
        # Measured 2026-08-21, among the rows where they disagree: Affliktt last
        # wrote on 19 July, Eliztra on 8 August, while the ladder had both with
        # more games played. Taking the character's word there would have put
        # month-old numbers in place of current ones.
        #
        # Games played only ever goes up within a season, so it is the one field
        # that says which reading came later. About 2.7% of rows take this path,
        # every one of them somebody who has not logged out since the last
        # rebuild.
        $useMine = $false
        if ($mine) {
            $snapshotGames = [int]$entry.season_match_statistics.won + [int]$entry.season_match_statistics.lost
            $mineGames = $mine.Won + $mine.Lost
            $useMine = ($mineGames -ge $snapshotGames)
            if (-not $useMine) {
                $script:refused++

                # The first few in full, because "166 rows disagreed" is a
                # number and not an explanation. Whether these are reset records
                # or simply two readings of different ages is not something to
                # reason out from the count.
                if ($script:refused -le 8) {
                    Write-Host ("  refused: {0}-{1} bracket {2} -- ladder says {3} ({4}-{5}), character says {6} ({7}-{8}), character written {9}" -f `
                        $entry.character.name, $entry.character.realm.slug, $bracket.Index,
                        $entry.rating, $entry.season_match_statistics.won, $entry.season_match_statistics.lost,
                        $mine.Rating, $mine.Won, $mine.Lost, $mine.Written)
                }
            }
        }

        $ordered.Add([pscustomobject]@{
            Name    = $entry.character.name
            Realm   = $entry.character.realm.slug
            Faction = $entry.faction.type
            Rating  = if ($useMine) { $mine.Rating } else { [int]$entry.rating }
            Won     = if ($useMine) { $mine.Won } else { [int]$entry.season_match_statistics.won }
            Lost    = if ($useMine) { $mine.Lost } else { [int]$entry.season_match_statistics.lost }
            Rank    = [int]$entry.rank
            Key     = $key
        })
    }

    # Re-ranked only when the ratings were refreshed, because a rank is only
    # meaningful against the ratings it was worked out from. Ties share a rank
    # and the next one skips, which is what the API itself does.
    if ($Live) {
        $ordered = $ordered | Sort-Object -Property @{Expression="Rating";Descending=$true}, @{Expression="Name"}
        $place = 0
        $seen = 0
        $previous = $null
        foreach ($row in $ordered) {
            $seen++
            if ($previous -eq $null -or $row.Rating -ne $previous) { $place = $seen; $previous = $row.Rating }
            $row.Rank = $place
        }
    }

    foreach ($row in $ordered) {
        $null = $nextBaseline.Add(("{0}`t{1}`t{2}" -f $row.Key, $row.Rating, $row.Rank))

        # Bracket in the key: one character plays several, and 2v2 games are
        # not 3v3 games.
        $usedRealms[[string]$row.Realm] = $true
        $pollKey = $row.Key + "|" + $bracket.Api
        $null = $nextPoll.Add(("{0}`t{1}`t{2}`t{3}" -f $pollKey, $row.Rating, $row.Won, $row.Lost))

        # Only rows that moved, and only games -- a rating that drifts with
        # nothing played is a decay or a correction, not a session. The
        # first sighting of a character writes nothing: there is no previous
        # poll to have moved from, and treating their whole season as one
        # window would be a lie about when it happened.
        # Columns, since the file has no header: when, bracket, character,
        # rating now, rating change, games won since, games lost since, and
        # the WON THIS DIFFED AGAINST.
        #
        # That last one is an instrument, not data anybody wants.
        #
        # Measured 2026-09-11 across 46,644 rows: about 57 characters emit a
        # repeated row -- the identical delta written every poll while the
        # rating sits still. One had 94 of them and summed to +13,574 of
        # movement for a character who never left 2033.
        #
        # Two explanations were ruled out by the rows themselves. Blizzard
        # serving inconsistent snapshots would alternate the sign, and there
        # are 5 negatives in 46,644. A run dying between the activity append
        # and the baseline write below would leave exactly this trail, and the
        # log has no failed run in it at all.
        #
        # What is left has to explain all three of: the baseline file is
        # correct right now, the write and this diff use the same $row.Won one
        # line apart, and yet the deltas SHRINK over successive polls -- which
        # means the stored baseline is climbing while the row stands still.
        # Nothing accounts for all three from outside the run.
        #
        # So the baseline it read goes in the row. Next time it happens, the
        # file says whether the read was stale or $row.Won disagreed with what
        # was written, and those are the two candidates. $row.Won itself is not
        # stored because it is recoverable: won = dw + this column.
        #
        # Appended as an eighth column, so the seven-column rows already on
        # disk stay readable and anything reading them must tolerate both
        # widths.
        $before = $lastPoll[$pollKey]
        if ($Live -and $before) {
            $dw = $row.Won - $before.Won
            $dl = $row.Lost - $before.Lost
            if ($dw -ne 0 -or $dl -ne 0) {
                $null = $activity.Add(("{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}`t{7}" -f `
                    $nowEpoch, $bracket.Api, $row.Key, $row.Rating,
                    ($row.Rating - $before.Rating), $dw, $dl, $before.Won))
            }
        }

        # Raised here rather than where the live answers land, because this is
        # the merged figure -- whichever of the character's own record and the
        # snapshot came later. Raising it from either source alone would let a
        # month-old reading set a peak.
        #
        # Written on the row only when it beats what they are on now. Equal is
        # the common case by far -- anybody at their season high -- and "max
        # 2641" beside "2641" is a column of noise.
        $peak = $best[$row.Key]
        if (-not $peak -or $row.Rating -gt $peak) { $peak = $row.Rating }
        $best[$row.Key] = $peak

        $top = if ($peak -gt $row.Rating) { ", mr=$peak" } else { "" }

        # The week's movement, when there is a week to compare against.
        $change = ""
        $was = $baseline[$row.Key]
        if ($was) {
            # Both as "what changed", the way the sites read them: rating up is
            # positive, and a rank of 723 from 3485 is -2762 -- a smaller number
            # being the better one. The addon colours on meaning, not on sign.
            $change = ", dr={0}, dk={1}" -f ($row.Rating - $was.Rating), ($row.Rank - $was.Rank)
        }

        $rows.Add(("`t`t{{ rank={0}, name=""{1}"", realm=""{2}"", rating={3}, won={4}, lost={5}, faction=""{6}""{7}{8} }}," -f `
            $row.Rank,
            (Escape-Lua $row.Name),
            (Escape-Lua $row.Realm),
            $row.Rating,
            $row.Won,
            $row.Lost,
            (Escape-Lua $row.Faction),
            $top,
            $change))
    }
    $rows.Add("`t},")
}

# ---------------------------------------------------------------- realms

# What each realm is actually called.
#
# The ladder carries only a slug -- "raden", "lei-shen", "arugal-au" -- and a
# slug cannot be turned back into a name by any rule. Every plausible one is
# wrong somewhere:
#
#   raden                 -> Ra-den                 not Raden, not Ra-Den
#   lei-shen              -> Lei Shen               a space, not a hyphen
#   arugal-au             -> Arugal (AU)            brackets, and capitals
#   bloodsail-buccaneers  -> Bloodsail Buccaneers
#
# So it is asked rather than derived. One request per run for the whole realm
# index, which is nothing beside the ladder itself, and only the realms that
# appear on this region's ladder are written -- the index carries fifty, most of
# them internal ("US2 CWOW CSI 180") and none of them anybody's realm.
#
# Failure is not fatal: without this the addon falls back to the slug it has
# always shown, which is what it looked like before this existed.
$realmNames = @{}
try {
    $index = Get-Api "/data/wow/realm/index"
    foreach ($realm in $index.realms) {
        if ($realm.slug -and $realm.name) { $realmNames[[string]$realm.slug] = [string]$realm.name }
    }
} catch {
    Write-Log "  realm names unavailable, slugs will be shown as they are"
}

$realmRows = New-Object System.Collections.Generic.List[string]
foreach ($slug in ($usedRealms.Keys | Sort-Object)) {
    $name = $realmNames[$slug]
    if ($name -and $name -ne $slug) {
        $realmRows.Add(("`t[""{0}""]=""{1}""," -f (Escape-Lua $slug), (Escape-Lua $name)))
    }
}

$ladderOut = @"
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

-- Arena ladders, written by tools\UpdateFromBlizzard.ps1 from Blizzard's own
-- API. Do not edit by hand: rerun the script to refresh.
--
-- Down to the $Depth cutoff, which is the last real title -- below it the API
-- publishes people on 96 rating who played one game and lost.
--
-- No class or spec: the leaderboard endpoint carries neither.
--
-- Region $Region, season $season, read $now.
-- Realm display names, because the ladder only carries slugs and no rule
-- turns one back into the other: raden is Ra-den, lei-shen is Lei Shen and
-- arugal-au is Arugal (AU). Read from Blizzard's realm index; a slug with no
-- entry here is shown as it always was.
ns.REALM_NAMES = ns.REALM_NAMES or {}
for slug, name in pairs({
$($realmRows -join "`n")
}) do ns.REALM_NAMES[slug] = name end

ns.LEADERBOARD_BY_REGION = ns.LEADERBOARD_BY_REGION or {}

ns.LEADERBOARD_BY_REGION["$Region"] = {
`tregion  = "$Region",
`tchecked = "$now",
`tcheckedEpoch = $nowEpoch,
`tsnapshot = "$script:snapshot",

$($rows -join "`n")
}
"@

Write-DataFile -Path $ladderFile -Value $ladderOut

# The peaks, for the next run to compare against.
#
# After the ladder is written, not before: if this pass dies between the two,
# the worst case should be a best-rating file one run behind rather than one
# claiming a peak for a ladder nobody ever saw.
#
# Not shipped. It is the working memory behind the mr= field, and the field
# itself is in the ladder file.
$bestLines = New-Object System.Collections.Generic.List[string]
$null = $bestLines.Add("# The highest rating seen for each character this season, one per line.")
$null = $bestLines.Add("# Not shipped. Deleting it loses the history and starts again from today.")
$null = $bestLines.Add("# season = $season")
foreach ($key in ($best.Keys | Sort-Object)) {
    $null = $bestLines.Add(("{0}`t{1}" -f $key, $best[$key]))
}
Set-Content -Path $bestFile -Value ($bestLines -join "`n") -Encoding utf8

if ($refused -gt 0) {
    Write-Host ("Kept the ladder's own figure for {0} rows whose character reported fewer games than the ladder." -f $refused)
}

# A week old, or none at all: today's standings become the thing next week is
# measured against. Written after the file, so a run that fails partway leaves
# the old baseline intact rather than resetting everybody's change to zero.
if ($baselineAge -ge 7) {
    Set-Content -Path $baselineFile -Value ($nextBaseline -join "`n") -Encoding utf8
    Write-Host ("Baseline replaced: the change columns now measure from today.")
}

# Every run, NOT once a week.
#
# This first went inside the baseline block above, which rewrites itself only
# when the week is up -- so the activity log recorded one window in seven days
# and the snapshot it diffs against was a week stale. Caught by there being no
# files at all after a run that reported success.
#
# Appended, never rewritten: this is a log, and the whole point is that older
# windows stay exactly as they were recorded.
#
# The snapshot is written whatever happened, including a run that recorded no
# activity -- otherwise the next run would diff against a stale poll and
# report one long session covering both gaps.
if ($Live) {
    if ($activity.Count -gt 0) {
        Add-Content -Path $activityFile -Value ($activity -join "`n") -Encoding utf8
    }
    Set-Content -Path $lastFile -Value ($nextPoll -join "`n") -Encoding utf8
    Write-Log ("  activity: {0} character(s) played since the last poll" -f $activity.Count)
}

# Gone when the work is: its absence is what says "not running". Removed before
# the log line rather than after, so a dashboard that sees the new log entry
# never also sees a stale progress file.
# When Blizzard rebuilds, remembered across runs.
#
# One observation cannot schedule anything. This keeps every distinct snapshot
# time seen, so the cadence can be measured rather than guessed at -- the last
# adaptive schedule this project had went nine hours wrong by trusting a single
# newest sample, and the fix was to use the median of several.
#
# Only new snapshots are recorded: polling hourly against a snapshot that
# rebuilds every few hours would otherwise fill this with repeats of the same
# time and make the intervals look like an hour.
if ($script:snapshot) {
    $historyFile = Join-Path $PSScriptRoot "SnapshotHistory.txt"
    $seenBefore = $false

    if (Test-Path $historyFile) {
        foreach ($line in Get-Content $historyFile) {
            if ($line -like "$Region|$script:snapshot|*") { $seenBefore = $true; break }
        }
    }

    if (-not $seenBefore) {
        Add-Content -Path $historyFile -Encoding utf8 -Value `
            ("{0}|{1}|{2}" -f $Region, $script:snapshot, (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm'))
    }
}

if (Test-Path $progressFile) { Remove-Item $progressFile -Force }
if ($writer) { $writer.Dispose() }
if (Test-Path $lockFile) { Remove-Item $lockFile -Force }

# The region leads the line, the way the specs log already does it: without it
# the two regions' runs are indistinguishable afterwards, and the dashboard
# cannot say what one region costs.
$where = $Region.ToUpper()
if ($stamp -eq $now) {
    Write-Log "${where}: Cutoffs moved. Wrote $total ladder entries. Blizzard built it $script:snapshot UTC. requests=$script:requests"
} else {
    Write-Log "${where}: No cutoff change. Wrote $total ladder entries. Blizzard built it $script:snapshot UTC. requests=$script:requests"
}

# Every other installed client gets the same files, so Anniversary is as fresh
# as Mists instead of waiting on the next CurseForge publish.
Copy-ToOtherClients -Primary $data -Files @($ladderFile, $cutoffFile) -Say ${function:Write-Log}
