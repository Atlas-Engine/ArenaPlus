# Which PvP titles each character on the ladder has actually earned.
#
# The ladder says what somebody's rating is today. It cannot say that they were
# a Gladiator two seasons ago, and that is often the more interesting fact --
# a 2100 player with Gladiator behind them is not the same player as a 2100 who
# has never been there.
#
# Read from the character achievements endpoint, which is the only place this
# exists. Verified 2026-09-11 rather than assumed, by tools\ProbePvPExtras.ps1:
#
#   profile-classic-us     .../achievements    200, 692 entries
#   profile-classicann-eu  .../achievements    404
#   .../titles             404 on both, though the character document links to it
#   .../collections/mounts 404 on both
#
# So this is MISTS ONLY and says so below rather than logging fifteen thousand
# failures on Anniversary. There are no reward mounts to be had either: the
# collections endpoint is not served for Classic at all, so the Cloud Serpent
# and its kin cannot be read at any price.
#
# ---------------------------------------------------------------- the cost
#
# One request per character, and the response is 288 KB -- the endpoint returns
# every achievement the character has, 692 of them, with no way to ask for a
# subset. Measured, not estimated.
#
# Two things make that affordable:
#
#   gzip. Asked for explicitly, because PowerShell does not send
#   Accept-Encoding on its own. Blizzard honours it and PowerShell inflates the
#   body transparently -- measured, the JSON still parses -- which takes a cold
#   pass over one region from about 1.4 GB to something nearer 150 MB.
#
#   -Limit. A cold pass is five thousand characters; this does fifteen hundred
#   of them a run and is therefore warm after four. Steady state is close to
#   nothing, because a title already earned does not need asking about again.
#
# ---------------------------------------------------------------- what changes
#
# A character is asked again only when they could have earned something new:
#
#   never asked before, or
#   their rating has reached a milestone they do not already hold, or
#   the answer is older than -RefreshDays.
#
# The middle rule is what keeps this cheap. "Three's Company: 2400" is earned
# at 2400 in 3v3, so a character sitting at 2100 cannot have earned anything
# they do not already have, however many games they play. The thresholds are
# read off the achievement NAMES rather than written down here -- see below.
#
# The last rule is the safety net for the titles rating cannot predict:
# Challenger, Rival, Duelist and Gladiator are awarded on a percentile at the
# end of a season, so somebody can earn one without their rating moving at all.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File "<path>\UpdateTitles.ps1" -Region us
#   ... -Force            ask about everybody, ignoring the cache
#   ... -Limit 0          no cap, for a deliberate cold pass

param(
    [string]$Region = "us",

    # "mop" or "tbc" -- see the same parameter on UpdateFromBlizzard.ps1.
    # Anniversary does not serve achievements; the guard below turns back.
    [string]$Version = "mop",

    [switch]$Force,

    # How many characters one run will ask about. Zero means all of them.
    #
    # Not a performance limit -- a bandwidth one. See the note above.
    [int]$Limit = 1500,

    # How long an answer stands before it is asked again, for the titles that
    # are awarded by percentile rather than by rating.
    [int]$RefreshDays = 14,

    [int]$Concurrency = 24,

    # Lower than the ladder pass on purpose. These responses are 288 KB each
    # where a pvp-bracket document is under 2 KB, so the same request rate is
    # forty times the bytes; the ceiling here is the pipe, not Blizzard.
    [int]$RatePerSecond = 24,

    [int]$ShellTimeoutMs = 45000
)

$ErrorActionPreference = "Stop"

# Dot-sourced for Write-DataFile and Copy-ToOtherClients.
. (Join-Path $PSScriptRoot "DataClients.ps1")

$apiRegion = $Region
if ($Version -ne "mop") { $Region = $Version + "-" + $Region }

$logFile = Join-Path $PSScriptRoot "UpdateTitles.log"

$TimeFormat = 'yyyy-MM-dd hh:mm tt'

function Write-Log([string]$message) {
    Add-Content -Path $logFile -Value ("{0}  {1}" -f (Get-Date -Format $TimeFormat), $message) -Encoding utf8
    Write-Host $message
}

# ---------------------------------------------------------------- not there
#
# Before anything is set up, so a scheduled Anniversary run costs one line in a
# log rather than a token exchange and fifteen thousand 404s.
if ($Version -eq "tbc") {
    Write-Log "TBC-$($apiRegion.ToUpper()): Anniversary does not serve character achievements. Nothing to do."
    return
}

# Lower case the way Lua does, which is A-Z and nothing else. Copied from
# UpdateSpecs.ps1 for the same reason it exists there: PowerShell's ToLower is
# Unicode-aware and folds accented capitals, the addon's :lower() does not, and
# a key that disagrees is a character the addon can never find.
function ConvertTo-LuaLower([string]$text) {
    $sb = New-Object System.Text.StringBuilder
    foreach ($c in $text.ToCharArray()) {
        if ($c -ge 'A' -and $c -le 'Z') { $null = $sb.Append([char]([int]$c + 32)) }
        else                            { $null = $sb.Append($c) }
    }
    return $sb.ToString()
}

function Escape-Lua([string]$text) {
    if ($null -eq $text) { return "" }
    return $text.Replace('\', '\\').Replace('"', '\"')
}

$root       = Split-Path $PSScriptRoot -Parent
$data       = Join-Path (Split-Path $root -Parent) "ArenaPlus_Data"
$ladderFile = Join-Path $data ("Leaderboard-" + $Region + ".lua")
$titleFile  = Join-Path $data ("Titles-" + $Region + ".lua")
$cacheFile  = Join-Path $PSScriptRoot ("TitlesSeen-" + $Region + ".txt")
$credFile   = Join-Path $PSScriptRoot "blizzard-credentials.txt"

if (-not (Test-Path $ladderFile)) { Write-Log "No ladder file -- run UpdateFromBlizzard.ps1 first."; return }
if (-not (Test-Path $credFile))   { Write-Log "No blizzard-credentials.txt."; return }

$clientId = $null
$clientSecret = $null
foreach ($line in Get-Content $credFile) {
    if ($line -match '^\s*ClientId\s*=\s*(.+?)\s*$')     { $clientId = $Matches[1] }
    if ($line -match '^\s*ClientSecret\s*=\s*(.+?)\s*$') { $clientSecret = $Matches[1] }
}

$pair  = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$clientId`:$clientSecret"))
$token = (Invoke-RestMethod -Method Post -Uri "https://oauth.battle.net/token" -Headers @{ Authorization = "Basic $pair" } -Body @{ grant_type = 'client_credentials' }).access_token
if (-not $token) { Write-Log "No access token."; return }

$requests  = 1
$auth      = "Bearer $token"
$profileNs = "profile-classic-$apiRegion"
$staticNs  = "static-classic-$apiRegion"
$apiRoot   = "https://$apiRegion.api.blizzard.com"

[System.Net.ServicePointManager]::DefaultConnectionLimit = [Math]::Max($Concurrency + 4, 16)

# ---------------------------------------------------------------- the titles
#
# Which achievements count as a PvP title, and what to call them.
#
# Asked rather than written down, which is the whole point of doing it this way.
# Blizzard's Classic achievement ids are NOT the retail ones -- 2090 is
# Challenger here -- so a hand-kept table would be a list of guesses that looked
# like data. One request a run reads the Arena category and the names come back
# with it.
#
# Category 165 is Arena, verified against static-classic-us: 27 achievements,
# among them 2091 Gladiator, 2092 Duelist, 2093 Rival, 2090 Challenger and the
# rating milestones. There is no Undisputed Gladiator and no expansion-specific
# Gladiator in it; those are later titles and asking for them would invent them.
$requests++
$category = Invoke-RestMethod -Uri "$apiRoot/data/wow/achievement-category/165?namespace=$staticNs&locale=en_US" `
                              -Headers @{ Authorization = $auth } -TimeoutSec 30

# The ones worth keeping, out of the 27.
#
# Most of the category is participation: Step Into The Arena is one game,
# Mercilessly Dedicated is a hundred of them, Hot Streak is ten in a row.
# Everybody near the top of a ladder has all of those, so keeping them made
# every row two hundred bytes long and buried the one line anybody cares
# about. Kept if it is a title you can wear, or a rating you had to reach.
#
# The milestones identify themselves -- the threshold is in the name, and the
# regex below finds it. The four season titles do not: Blizzard publishes no
# "this is a title" flag anywhere in the achievement document, so the ids are
# named here. Five ids and a comment, not per-character logic -- and checked
# against the category rather than trusted, so a renumbering says so instead
# of quietly producing a file with no titles in it.
$TitleIds = @{
    2090 = $true    # Challenger
    2093 = $true    # Rival
    2092 = $true    # Duelist
    2091 = $true    # Gladiator
    1174 = $true    # The Arena Master
}

$titleName = New-Object 'System.Collections.Generic.Dictionary[int,string]'
$everything = New-Object 'System.Collections.Generic.Dictionary[int,string]'
foreach ($a in @($category.achievements)) {
    if (-not ($a.id -and $a.name)) { continue }

    $id = [int]$a.id
    $everything[$id] = [string]$a.name

    # A rating in the name, or one of the five named above.
    if ($TitleIds[$id] -or [regex]::IsMatch([string]$a.name, ':\s*\d{3,4}\s*$')) {
        $titleName[$id] = [string]$a.name
    }
}

if ($everything.Count -eq 0) { Write-Log "The Arena achievement category came back empty. Nothing to map."; return }

# Said out loud, because a silently missing title is the failure that looks
# like a working file.
foreach ($id in $TitleIds.Keys) {
    if (-not $everything.ContainsKey([int]$id)) {
        Write-Log ("Achievement {0} is no longer in the Arena category -- the id list needs re-reading." -f $id)
    }
}

# What rating each milestone needs, read off its own name.
#
# "Just the Two of Us: 2200" and "Three's Company: 2700" carry the threshold in
# the text, so the number is taken from there rather than from a table here.
# One less thing to keep in step, and it covers a milestone Blizzard adds later
# without an edit.
#
# An achievement with no number in its name -- Gladiator, The Arena Master --
# is not a milestone and gets no threshold; those are the ones -RefreshDays
# exists for.
$threshold = New-Object 'System.Collections.Generic.Dictionary[int,int]'
foreach ($id in $titleName.Keys) {
    $m = [regex]::Match($titleName[$id], ':\s*(\d{3,4})\s*$')
    if ($m.Success) { $threshold[$id] = [int]$m.Groups[1].Value }
}

# Which bracket family a milestone belongs to, taken from the name in front
# of the colon: "Just the Two of Us" is 2v2, "Three's Company" 3v3, "High
# Five" 5v5. Used to keep only the best of each per character -- see the
# write section.
#
# Derived rather than listed, so a fourth family arrives without an edit.
$family = New-Object 'System.Collections.Generic.Dictionary[int,string]'
foreach ($id in $threshold.Keys) {
    $m = [regex]::Match($titleName[$id], '^(.*?):\s*\d{3,4}\s*$')
    if ($m.Success) { $family[$id] = $m.Groups[1].Value }
}

Write-Host ("{0} arena achievements kept, {1} of them rating milestones across {2} bracket(s)." -f `
    $titleName.Count, $threshold.Count, (($family.Values | Sort-Object -Unique).Count))

# ---------------------------------------------------------------- who
#
# Out of the ladder file, which was written minutes ago.
#
# Keyed by character, NOT by character and bracket the way the live pass is:
# achievements belong to the character, so somebody on three ladders is one
# request rather than three. On the Mists ladders that is about 5,970 rows
# collapsing to some 5,000 characters.
#
# The rating kept against each is the best of their rows, because the milestone
# test below asks "could this person have earned anything new" and the answer
# comes from their strongest bracket. mr= is read too where the ladder pass has
# written one -- a peak from earlier in the season counts.
$wanted = New-Object System.Collections.Specialized.OrderedDictionary ([System.StringComparer]::Ordinal)
foreach ($line in Get-Content $ladderFile) {
    $m = [regex]::Match($line, 'name="([^"]+)", realm="([^"]*)", rating=(\d+)')
    if (-not $m.Success) { continue }

    $rating = [int]$m.Groups[3].Value

    $peak = [regex]::Match($line, 'mr=(\d+)')
    if ($peak.Success -and [int]$peak.Groups[1].Value -gt $rating) { $rating = [int]$peak.Groups[1].Value }

    $key = ConvertTo-LuaLower ($m.Groups[1].Value + '-' + $m.Groups[2].Value)

    if ($wanted.Contains($key)) {
        if ($rating -gt $wanted[$key].Rating) { $wanted[$key].Rating = $rating }
    } else {
        $wanted[$key] = @{ Name = $m.Groups[1].Value; Realm = $m.Groups[2].Value; Rating = $rating }
    }
}

Write-Host ("{0} distinct characters on the {1} ladder." -f $wanted.Count, $Region.ToUpper())

# ---------------------------------------------------------------- known
#
# What has been asked, and what came back.
#
# Beside this script rather than in the shipped file, the same as SpecsSeen: the
# .lua holds only characters currently on the ladder, and people oscillate
# across the cutoff all day. Reading the .lua as the memory would mean asking
# about the same forty people every time they came back.
#
# Four fields: when it was asked, what their rating was then, and the ids. The
# rating is stored so a re-ask can be decided without re-reading the ladder
# history, and an empty id list is a real answer -- a character with no titles
# is remembered as having none rather than asked about for ever.
$seen = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([System.StringComparer]::Ordinal)

if ((Test-Path $cacheFile) -and -not $Force) {
    foreach ($line in Get-Content $cacheFile) {
        if ($line.StartsWith("#")) { continue }
        $bits = $line -split "`t"
        if ($bits.Count -lt 3) { continue }

        $ids = New-Object 'System.Collections.Generic.List[int]'
        if ($bits.Count -ge 4 -and $bits[3]) {
            foreach ($part in ($bits[3] -split ',')) {
                $n = 0
                if ([int]::TryParse($part, [ref]$n) -and $n -gt 0) { $null = $ids.Add($n) }
            }
        }

        $when = [datetime]::MinValue
        $null = [datetime]::TryParse($bits[1], [ref]$when)

        $seen[$bits[0]] = @{ When = $when; Rating = [int]$bits[2]; Ids = $ids }
    }
}

# ---------------------------------------------------------------- to ask
#
# The three rules from the header, in one place.
$cutoff = (Get-Date).AddDays(-$RefreshDays)

$work = New-Object System.Collections.Generic.List[object]
$skippedKnown = 0

foreach ($key in $wanted.Keys) {
    $who = $wanted[$key]
    $known = if ($Force) { $null } else { $seen[$key] }

    $ask = $true
    if ($known) {
        $ask = $false

        # Stale enough that a percentile title could have landed unseen.
        if ($known.When -lt $cutoff) { $ask = $true }

        # Or they have CROSSED a milestone line since we last looked.
        #
        # Against the rating at the time of the ask, not against the
        # threshold alone. The first version tested "is there an unheld
        # milestone at or below your rating", which re-asked the same people
        # every run for ever: milestones are per bracket and the rating here
        # is the best of all of them, so a 2v2 specialist at 2400 always has
        # an unearned "Three's Company: 2400" sitting under their rating and
        # can never earn it. Measured -- 60 characters asked, 15 remembered,
        # the rest queued straight back up.
        #
        # A crossing is a real event and happens once, so this converges. It
        # costs one wasted request when somebody crosses a line in a bracket
        # they do not play, which is the right price for not needing a
        # bracket-to-achievement-family table that Blizzard does not publish.
        if (-not $ask -and $who.Rating -gt $known.Rating) {
            $have = @{}
            foreach ($id in $known.Ids) { $have[$id] = $true }

            foreach ($id in $threshold.Keys) {
                $line = $threshold[$id]
                if (-not $have[$id] -and $line -gt $known.Rating -and $line -le $who.Rating) {
                    $ask = $true
                    break
                }
            }
        }
    }

    if (-not $ask) { $skippedKnown++; continue }

    $name = [uri]::EscapeDataString($who.Name.ToLower())
    $work.Add([pscustomobject]@{
        Key = $key
        Uri = "$apiRoot/profile/wow/character/$($who.Realm)/$name/achievements?namespace=$profileNs&locale=en_US"
    })
}

$queued = $work.Count
if ($Limit -gt 0 -and $work.Count -gt $Limit) {
    $work = $work.GetRange(0, $Limit)
}

Write-Host ("{0} to ask about ({1} already known), doing {2} this run." -f $queued, $skippedKnown, $work.Count)

# ---------------------------------------------------------------- one at a time
#
# The shared lock, so this pass takes its turn with the others rather than
# adding its rate to theirs. See the long note in UpdateFromBlizzard.ps1.
$lockFile = Join-Path $PSScriptRoot "ArenaPlus-fetch.lock"
$passLabel = "titles $Region"

$held = $null
for ($try = 1; $try -le 2; $try++) {
    try {
        $held = [System.IO.File]::Open($lockFile, [System.IO.FileMode]::CreateNew,
                                       [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
        break
    } catch {
        $owner = 0
        try { $owner = [int](Get-Content $lockFile -TotalCount 1 -ErrorAction Stop) } catch { }

        if ($owner -gt 0 -and (Get-Process -Id $owner -ErrorAction SilentlyContinue)) {
            $busy = ""
            try { $busy = (Get-Content $lockFile -TotalCount 2)[1] } catch { }
            if ($busy) { Write-Host ("Waiting: {0} is running (process {1})." -f $busy, $owner) }
            else       { Write-Host ("Waiting: another pass is running (process {0})." -f $owner) }
            return
        }

        if ($try -eq 1) {
            Write-Host "Clearing a lock left by a run that did not finish."
            try { Remove-Item $lockFile -Force -ErrorAction Stop } catch { }
        } else {
            Write-Host "Another run claimed the lock first. Nothing to do."
            return
        }
    }
}

$writer = New-Object System.IO.StreamWriter($held)
$writer.WriteLine($PID)
$writer.WriteLine($passLabel)
$writer.Flush()

$asked = 0
$found = 0
$none = 0
$gone = 0
$failed = 0
$askedOn = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

try {
    if ($work.Count -gt 0) {

        # One request, in its own runspace. Self-contained: a runspace inherits
        # nothing, so the authorization and the ids worth keeping both arrive as
        # arguments.
        #
        # Only the wanted ids come back, not the 692 the response carries. The
        # filtering happens here rather than in the collecting loop so the big
        # object is dropped inside the runspace and never crosses back.
        $one = {
            param($uri, $auth, $keepIds)

            for ($attempt = 1; $attempt -le 2; $attempt++) {
                try {
                    # Accept-Encoding by hand: PowerShell does not ask for
                    # compression on its own, and these bodies are 288 KB of
                    # JSON that gzips to a fraction of it. It inflates the
                    # answer transparently once the server sends it.
                    $body = Invoke-RestMethod -Uri $uri -TimeoutSec 30 -ErrorAction Stop `
                        -Headers @{ Authorization = $auth; 'Accept-Encoding' = 'gzip' }

                    $mine = New-Object System.Collections.Generic.List[int]
                    foreach ($a in $body.achievements) {
                        $id = [int]$a.id
                        if ($keepIds.Contains($id)) { $null = $mine.Add($id) }
                    }

                    return [pscustomobject]@{ Status = 'ok'; Ids = $mine }
                } catch {
                    $code = 0
                    try { $code = [int]$_.Exception.Response.StatusCode } catch { }

                    # A character who has been renamed, transferred or deleted.
                    # Remembered as having nothing so later runs stop asking:
                    # the ladder row can name somebody whose profile is gone,
                    # measured on Wealthycat-raden 2026-09-11.
                    if ($code -eq 404) { return [pscustomobject]@{ Status = 'gone'; Ids = $null } }

                    # Too fast, or a blip. Worth one more go.
                    if ($code -eq 429 -or $code -eq 0) { Start-Sleep -Milliseconds (250 * $attempt); continue }

                    return [pscustomobject]@{ Status = 'error'; Ids = $null; Code = $code }
                }
            }

            return [pscustomobject]@{ Status = 'error'; Ids = $null; Code = 429 }
        }

        # A HashSet, so the runspace's Contains is a lookup rather than a walk
        # over 27 entries 692 times per character.
        $keepIds = New-Object 'System.Collections.Generic.HashSet[int]'
        foreach ($id in $titleName.Keys) { $null = $keepIds.Add($id) }

        $pool = [runspacefactory]::CreateRunspacePool(1, $Concurrency)
        $pool.Open()

        try {
            $inFlight = New-Object System.Collections.Generic.List[object]
            $next = 0
            $lastSaid = 0
            $windowStart = [datetime]::UtcNow
            $windowCount = 0

            while ($next -lt $work.Count -or $inFlight.Count -gt 0) {

                while ($inFlight.Count -lt $Concurrency -and $next -lt $work.Count) {
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
                    $null = $shell.AddScript($one).AddArgument($item.Uri).AddArgument($auth).AddArgument($keepIds)

                    $inFlight.Add([pscustomobject]@{
                        Shell   = $shell
                        Handle  = $shell.BeginInvoke()
                        Item    = $item
                        Started = [datetime]::UtcNow
                    })
                    $windowCount++
                    $requests++
                }

                for ($i = $inFlight.Count - 1; $i -ge 0; $i--) {
                    $job = $inFlight[$i]
                    $overdue = (([datetime]::UtcNow - $job.Started).TotalMilliseconds -gt $ShellTimeoutMs)

                    if (-not $job.Handle.IsCompleted -and -not $overdue) { continue }

                    $answer = $null
                    if ($job.Handle.IsCompleted) {
                        try { $answer = $job.Shell.EndInvoke($job.Handle) | Select-Object -First 1 } catch { }
                        $job.Shell.Dispose()
                    } else {
                        # Abandoned rather than waited on: Stop and Dispose both
                        # block on the thread that is refusing to finish.
                        try { $null = $job.Shell.BeginStop($null, $null) } catch { }
                    }

                    $inFlight.RemoveAt($i)
                    $asked++

                    $key = $job.Item.Key
                    $rating = $wanted[$key].Rating

                    if ($answer -and $answer.Status -eq 'ok') {
                        $ids = New-Object 'System.Collections.Generic.List[int]'
                        foreach ($id in $answer.Ids) { $null = $ids.Add([int]$id) }

                        $seen[$key] = @{ When = (Get-Date); Rating = $rating; Ids = $ids }
                        if ($ids.Count -gt 0) { $found++ } else { $none++ }
                    } elseif ($answer -and $answer.Status -eq 'gone') {
                        $seen[$key] = @{ When = (Get-Date); Rating = $rating; Ids = (New-Object 'System.Collections.Generic.List[int]') }
                        $gone++
                    } else {
                        # Nothing was learned, so nothing is remembered and the
                        # next run tries again.
                        $failed++
                    }
                }

                if ($asked - $lastSaid -ge 250) {
                    $lastSaid = $asked
                    Write-Host ("  {0} of {1}: {2} with titles, {3} without, {4} gone, {5} unreadable" -f `
                        $asked, $work.Count, $found, $none, $gone, $failed)
                }

                if ($inFlight.Count -ge $Concurrency) { Start-Sleep -Milliseconds 25 }
            }
        } finally {
            $pool.Close()
            $pool.Dispose()
        }
    }
} finally {
    $writer.Dispose()
    $held.Dispose()
    if (Test-Path $lockFile) { Remove-Item $lockFile -Force -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------- write
#
# Only characters currently on the ladder, and only those with something to
# show. The cache keeps the rest.
$out = New-Object System.Collections.Generic.List[string]
$null = $out.Add("-- Shipped as its own addon so the ladder can be republished without reshipping")
$null = $out.Add("-- the code: this file was half of every ArenaPlus release.")
$null = $out.Add("--")
$null = $out.Add("-- Two addons cannot see each other's namespace, so the tables go on a global")
$null = $out.Add("-- and ArenaPlus copies them across as it loads.")
$null = $out.Add("ArenaPlusData = ArenaPlusData or {}")
$null = $out.Add("local ns = ArenaPlusData")
$null = $out.Add("")
$null = $out.Add("-- PvP titles earned, written by tools\UpdateTitles.ps1 from Blizzard's")
$null = $out.Add("-- character achievements API. Do not edit by hand.")
$null = $out.Add("--")
$null = $out.Add("-- Mists only. The Anniversary profile namespace does not serve achievements,")
$null = $out.Add("-- so there is no Titles-tbc-*.lua and there cannot be one.")
$null = $out.Add("--")
$null = $out.Add("-- Ids rather than names on each character, with one table of names below:")
$null = $out.Add("-- a name repeated across five thousand rows is most of the file.")
$null = $out.Add("")

# The lookup table, guarded so four region files can each carry it and the
# first one loaded wins. They are identical -- it is static data -- and 27
# lines is not worth a fifth file and another entry in the TOC.
$null = $out.Add("ns.PVP_TITLE_NAMES = ns.PVP_TITLE_NAMES or {")
foreach ($id in ($titleName.Keys | Sort-Object)) {
    $null = $out.Add(("`t[{0}] = ""{1}""," -f $id, (Escape-Lua $titleName[$id])))
}
$null = $out.Add("}")
$null = $out.Add("")

$null = $out.Add("ns.TITLES_BY_REGION = ns.TITLES_BY_REGION or {}")
$null = $out.Add("")
$null = $out.Add(("ns.TITLES_BY_REGION[""{0}""] = {{" -f $Region))

# The best milestone in each bracket, and every title.
#
# A character holding Three's Company: 2700 necessarily holds 2400, 2200,
# 2000, 1750 and 1550 as well, and shipping all six says one thing six
# times. Nineteen ids a row became five or six, which matters: this file
# goes to every user on every publish.
#
# The cache keeps all of them. The re-ask rule asks "is there a milestone
# they do not hold that their rating now reaches", and against a pruned
# list every lower milestone would look unearned and every character would
# be asked about for ever.
$written = 0
foreach ($key in $wanted.Keys) {
    $known = $seen[$key]
    if (-not $known -or $known.Ids.Count -eq 0) { continue }

    $bestOf = @{}
    $keep = New-Object System.Collections.Generic.List[int]

    foreach ($id in $known.Ids) {
        $fam = $family[[int]$id]
        if (-not $fam) { $null = $keep.Add([int]$id); continue }

        $have = $bestOf[$fam]
        if (-not $have -or $threshold[[int]$id] -gt $threshold[[int]$have]) { $bestOf[$fam] = [int]$id }
    }

    foreach ($fam in $bestOf.Keys) { $null = $keep.Add([int]$bestOf[$fam]) }

    if ($keep.Count -eq 0) { continue }

    $written++
    $null = $out.Add(("`t[""{0}""] = ""{1}""," -f (Escape-Lua $key), (($keep | Sort-Object) -join ",")))
}

$null = $out.Add("}")
$null = $out.Add("")

Write-DataFile -Path $titleFile -Value ($out -join "`n")

# ---------------------------------------------------------------- cache
$cacheLines = New-Object System.Collections.Generic.List[string]
$null = $cacheLines.Add("# What each character's achievements said, and when. Not shipped.")
$null = $cacheLines.Add("# Safe to delete, at the cost of one cold pass -- which is not cheap here.")
foreach ($key in ($seen.Keys | Sort-Object)) {
    $it = $seen[$key]
    $null = $cacheLines.Add(("{0}`t{1}`t{2}`t{3}" -f `
        $key,
        $it.When.ToString('yyyy-MM-dd HH:mm:ss'),
        $it.Rating,
        (($it.Ids | Sort-Object) -join ",")))
}
Set-Content -Path $cacheFile -Value ($cacheLines -join "`n") -Encoding utf8

Write-Log ("{0}: asked {1} of {2} queued, {3} with titles, {4} without, {5} gone, {6} unreadable. {7} characters written. requests={8}" -f `
    $Region.ToUpper(), $asked, $queued, $found, $none, $gone, $failed, $written, $requests)

# Every other installed client gets the same file.
Copy-ToOtherClients -Primary $data -Files @($titleFile) -Say ${function:Write-Log}
