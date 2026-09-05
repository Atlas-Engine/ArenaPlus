# Class and spec for everybody on the ladder, one character at a time.
#
# Separate from UpdateFromBlizzard.ps1 because the two change at wildly
# different rates. A rating moves hourly; a character's spec almost never. So
# the ladder is refreshed constantly and this rarely -- and this one is
# incremental, asking only about characters it has not seen before.
#
# The leaderboard endpoint carries neither field. The character profile does:
#   /profile/wow/character/{realm}/{name}?namespace=profile-classic-{region}
# One request each, which is why this is not run hourly.
#
# Stored as an index into a shared list of spec slugs rather than two strings
# per character: about a quarter of the size, and this file ships to everybody.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File "<path>\UpdateSpecs.ps1"
#   powershell -ExecutionPolicy Bypass -File "<path>\UpdateSpecs.ps1" -Region eu -Force

param(
    [string]$Region = "us",

    # "mop" or "tbc" -- see the same parameter on UpdateFromBlizzard.ps1.
    # $Region is re-keyed below so every file this writes is version-qualified.
    [ValidateSet("mop","tbc")]
    [string]$Version = "mop",
    # Re-ask about characters already known. The normal run skips them.
    [switch]$Force,
    # A ceiling per run, so a first pass can be done in stages.
    [int]$Limit = 0,

    # How many requests to keep in the air at once.
    #
    # Replaces a 50ms sleep between sequential requests. That was fine while a
    # big pass was a weekly event; it cost about sixteen minutes for five
    # thousand characters, nearly all of it waiting for round trips.
    [int]$Concurrency = 48,

    # Just under Blizzard's hundred a second. Measured on the ladder pass: at
    # ninety, twenty-nine of 5,891 requests came back refused, because the limit
    # is enforced on bursts finer than a whole second.
    [int]$RatePerSecond = 80,
    # How often to re-ask about everybody, rather than only about names not
    # seen before. Without this a player who changes spec keeps the old one for
    # ever, because an incremental run never asks about them again. 0 disables.
    # How long the roster takes to come round, in days.
    #
    # Was -FullEveryDays: one day in seven it re-asked about all five thousand,
    # which took a quarter of an hour sequentially. That was affordable while
    # this had its own hourly task and became a problem the moment it rode a
    # task that fires every fifteen minutes.
    #
    # Same coverage, spread out: every run re-asks the oldest slice, sized from
    # how long it has been since the last run, so the whole roster is refreshed
    # in this many days no matter what cadence it is called at.
    #
    # A day, not the week it was. Blizzard writes a character's profile when
    # they log out, so active_spec is whatever they happened to be sitting in
    # then -- a resto druid who logged out in balance is recorded as balance.
    # That is a true answer to a question nobody asked, and at seven days it
    # stuck around for a week. Daily is what the source can actually support.
    #
    # It is nearly free at this cadence: five and a half thousand characters
    # over ninety-six runs is about sixty a run, against an hourly budget of
    # thirty-six thousand that currently sees four and a half.
    [int]$RefreshDays = 1
)

$ErrorActionPreference = "Stop"

$apiRegion = $Region
if ($Version -ne "mop") { $Region = $Version + "-" + $Region }

# How many requests one character actually costs.
#
# TBC needs a second call for the talent trees, because active_spec comes
# back empty there. The rate window below paces work ITEMS, so charging it
# one apiece ran TBC at twice the configured rate -- over Blizzard's ceiling,
# which does not answer with an error but by refusing requests. Measured
# before this was here: 1,635 of 4,000 characters came back "missing" while
# the very same names answered fine one at a time.
$perItem = if ($Version -eq "tbc") { 2 } else { 1 }

# Lower case the way Lua does, which is A-Z and nothing else.
#
# PowerShell's ToLower() is Unicode-aware and folds accented capitals, so
# "Asitopera" with acutes became a key beginning with a lower-case accented A.
# The addon builds the same key with Lua's :lower(), which leaves that letter
# untouched, and so could never find it -- forty-one characters silently lost
# their spec icon. The file is written for that reader, so it lowers the same
# way. The request URL below still uses ToLower(), because that one is written
# for Blizzard.
function ConvertTo-LuaLower([string]$text) {
    $sb = New-Object System.Text.StringBuilder
    foreach ($c in $text.ToCharArray()) {
        if ($c -ge 'A' -and $c -le 'Z') { $null = $sb.Append([char]([int]$c + 32)) }
        else                            { $null = $sb.Append($c) }
    }
    return $sb.ToString()
}

$root       = Split-Path $PSScriptRoot -Parent
# Everything the passes write lives under Data\, so the addon root stays
# readable. Built once here: nine separate literals is nine chances for one
# to keep pointing at the old place, and a pass that writes where nothing
# reads fails silently.
# The data is its own addon now, a sibling of this one, so it can be
# published without republishing the code.
$data       = Join-Path (Split-Path $root -Parent) "ArenaPlus_Data"
$ladderFile = Join-Path $data ("Leaderboard-" + $Region + ".lua")
$specFile   = Join-Path $data ("Specs-" + $Region + ".lua")
$logFile    = Join-Path $PSScriptRoot "UpdateSpecs.log"
$credFile   = Join-Path $PSScriptRoot "blizzard-credentials.txt"

$TimeFormat = 'yyyy-MM-dd hh:mm tt'

function Write-Log([string]$message) {
    Add-Content -Path $logFile -Value ("{0}  {1}" -f (Get-Date -Format $TimeFormat), $message) -Encoding utf8
    Write-Host $message
}

if (-not (Test-Path $ladderFile)) { Write-Log "No ladder file - run UpdateFromBlizzard.ps1 first."; return }
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

$headers   = @{ Authorization = "Bearer $token" }
$profileNs = if ($Version -eq "tbc") { "profile-classicann-$apiRegion" }
             else                    { "profile-classic-$apiRegion" }
$apiRoot   = "https://$apiRegion.api.blizzard.com"

# ---------------------------------------------------------------- who

# Read out of the ladder file rather than fetched again: it was written minutes
# ago, and asking twice would double the traffic for nothing.
# Ordinal, because PowerShell's own tables are case-insensitive and Lua's are
# not.
#
# This is what defeated the accented-capital fix the first time. The script
# computed the correct key, wrote it into the table -- and the table matched it
# case-insensitively against the folded key already there, updated the value,
# and kept the OLD spelling. Forty US characters stayed unreachable by the addon
# with no sign anything had gone wrong. EU was clean only because it had no
# earlier file to inherit from.
$wanted = New-Object System.Collections.Specialized.OrderedDictionary ([System.StringComparer]::Ordinal)
foreach ($line in Get-Content $ladderFile) {
    $m = [regex]::Match($line, 'name="([^"]+)", realm="([^"]*)"')
    if ($m.Success) {
        $key = ConvertTo-LuaLower ($m.Groups[1].Value + '-' + $m.Groups[2].Value)
        if (-not $wanted.Contains($key)) {
            $wanted[$key] = @{ Name = $m.Groups[1].Value; Realm = $m.Groups[2].Value }
        }
    }
}
Write-Host ("{0} distinct characters on the {1} ladder." -f $wanted.Count, $Region.ToUpper())

# ---------------------------------------------------------------- known

# The shipped file holds only characters currently on the ladder, so it cannot
# be the memory of what has been asked: measured over three and a half hours,
# about forty characters a region drop off and forty arrive, largely the same
# people oscillating around the cutoff. Reading only the .lua meant asking about
# every one of them again each time they came back.
#
# So what has been asked lives in a cache beside this script, which is not
# shipped and may grow, while the .lua stays lean at about 118 KB.
#
# The cache stores the spec *slug*, not the index into SPEC_SLUGS. Indices are
# positions in a list rebuilt from the .lua each run; if that file were ever
# deleted the list would come back in a different order and every cached index
# would quietly point at the wrong spec.
$cacheFile = Join-Path $PSScriptRoot ("SpecsSeen-" + $Region + ".txt")

$specList = New-Object System.Collections.Generic.List[string]

# The list exactly as the shipped file carries it, junk and all, positions
# intact. The seeding branch further down resolves that file's own indices
# against it, so it has to mirror the file rather than the cleaned-up list --
# resolving old indices against a filtered list would hand every character
# somebody else's spec, silently.
$fileList = New-Object System.Collections.Generic.List[string]
$seen = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([System.StringComparer]::Ordinal)
$lastFull = [datetime]::MinValue

if (Test-Path $specFile) {
    $text = Get-Content $specFile -Raw

    # The slug table's own body, and only real slugs out of it.
    #
    # This read the whole file for '"([a-z-]+)",' -- which also matched the word
    # inside the comment above the table, the one explaining the `X = X or {}`
    # idiom. So every run harvested one more "or" and put it at the front of the
    # list, and the table grew by one junk entry per run: 239 of them before
    # anybody looked, every one shipped to every user.
    #
    # It never displayed anything wrong, because the indices were computed
    # against the same polluted list the addon then read. That is exactly why it
    # survived so long -- the damage was unbounded growth, not wrong specs.
    #
    # Two guards, because either alone would have let it through: take the table
    # body rather than the file, and require the hyphen that separates class
    # from spec. The second is what flushes the junk already in the file.
    $block = [regex]::Match($text,
        '(?s)SPEC_SLUGS_BY_REGION\["' + $Region + '"\]\s*=\s*\{(.*?)\n\}')
    $body = if ($block.Success) { $block.Groups[1].Value } else { "" }

    foreach ($m in [regex]::Matches($body, '"([a-z-]+)",')) {
        $slug = $m.Groups[1].Value
        $null = $fileList.Add($slug)
        if ($slug -match '-') { $null = $specList.Add($slug) }
    }
}

if (Test-Path $cacheFile) {
    foreach ($line in Get-Content $cacheFile) {
        if ($line.StartsWith('# lastFull=')) {
            $parsed = [datetime]::MinValue
            if ([datetime]::TryParse($line.Substring(11), [ref]$parsed)) { $lastFull = $parsed }
            continue
        }
        $bits = $line -split '\|'
        if ($bits.Count -ge 3) {
            # Race and gender were added later, so a cache written before that
            # has three fields rather than five. Missing means "not known yet",
            # which is what 0 says here.
            $seen[$bits[0]] = @{
                Slug   = $bits[1]
                Seen   = $bits[2]
                Race   = if ($bits.Count -ge 4) { [int]$bits[3] } else { 0 }
                Gender = if ($bits.Count -ge 5) { [int]$bits[4] } else { 0 }
            }
        }
    }
    Write-Host ("{0} characters remembered, last full pass {1}." -f $seen.Count,
        $(if ($lastFull -eq [datetime]::MinValue) { "never" } else { $lastFull.ToString('yyyy-MM-dd') }))
}
elseif (Test-Path $specFile) {
    # First run after the cache was introduced: seed it from the shipped file so
    # the whole ladder is not asked about again.
    $today = Get-Date -Format 'yyyy-MM-dd'
    foreach ($m in [regex]::Matches($text, '\["([^"]+)"\]=(\d+)')) {
        $index = [int]$m.Groups[2].Value
        # $fileList, not $specList: these indices were written against the file
        # as it stands, so they have to be read against the same thing.
        $slug = if ($index -gt 0 -and $index -le $fileList.Count) { $fileList[$index - 1] } else { '' }
        $seen[$m.Groups[1].Value] = @{ Slug = $slug; Seen = $today }
    }
    # The shipped file was itself written by a full pass, so its timestamp is
    # when everybody was last asked about. Without this the first run after the
    # cache appeared would find no lastFull, decide one was overdue, and re-ask
    # about all five thousand characters an hour after the last pass did.
    $lastFull = (Get-Item $specFile).LastWriteTime
    Write-Host ("{0} seeded from the shipped file, treating {1} as the last full pass." -f `
        $seen.Count, $lastFull.ToString('yyyy-MM-dd HH:mm'))
}

# How many known characters to re-ask about this run.
#
# Sized from the clock rather than from a count of runs, because nothing here
# knows the cadence: at a quarter-hourly beat this is eight characters, hourly
# it is thirty, and a run after a long gap catches up in one go. Either way the
# oldest reading on file is never older than -RefreshDays.
$slice = 0
if ($RefreshDays -gt 0 -and $seen.Count -gt 0) {
    $sinceLast = ((Get-Date) - $lastFull).TotalMinutes
    if ($sinceLast -lt 0) { $sinceLast = 0 }

    # Clamped BEFORE the cast, not after.
    #
    # A cache that exists with no recorded full pass leaves $lastFull at
    # DateTime.MinValue, which makes $sinceLast about 739,000 days. Times a few
    # thousand known characters that is ~3.3e9, and [int] on it throws
    # "Value was either too large or too small for an Int32" -- so the run died
    # here rather than being clamped by the very line meant to bound it. Seen on
    # the first TBC US pass, whose cache had been written by a run that never
    # finished a full sweep.
    $want = [math]::Ceiling($seen.Count * $sinceLast / ($RefreshDays * 1440.0))

    # Never the whole roster in one run, whatever the gap: that is the spike
    # this exists to avoid. A month of downtime comes round over a week.
    if ($want -gt $seen.Count) { $want = $seen.Count }
    $slice = [int]$want
}

$full = [bool]$Force
if ($full) {
    Write-Host "Full pass: re-asking about everybody."
    $slice = 0
}

# The oldest readings first, which is what makes this a rotation rather than a
# random sample. Ordinal, to match the dictionary they came from.
$stale = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
if ($slice -gt 0) {
    foreach ($key in ($seen.Keys | Sort-Object { $seen[$_].Seen } | Select-Object -First $slice)) {
        $null = $stale.Add($key)
    }
    Write-Host ("{0} of {1} known characters due a refresh this run." -f $stale.Count, $seen.Count)
}

# ---------------------------------------------------------------- fetch

$asked = 0
$found = 0
$missing = 0
$askedOn = Get-Date -Format 'yyyy-MM-dd' 

# How many this run will actually ask about, so progress has a denominator.
$todo = 0
foreach ($key in $wanted.Keys) {
    if ($full -or -not $seen.ContainsKey($key) -or $stale.Contains($key)) { $todo++ }
}
if ($Limit -gt 0 -and $todo -gt $Limit) { $todo = $Limit }
Write-Host ("{0} to ask about this run." -f $todo)

# How many connections .NET will open to one host at a time. The default is
# two, which quietly caps any amount of concurrency at two.
[System.Net.ServicePointManager]::DefaultConnectionLimit = [Math]::Max($Concurrency + 4, 16)
[System.Net.ServicePointManager]::Expect100Continue = $false

# A progress file, for the dashboard to read. Its own start time is written
# into it rather than noted by whoever is watching: a run can be started by the
# scheduler, by the dashboard, or by hand, and only the run itself knows when it
# began. Without that the dashboard could show a bar but never a time remaining.
# ---------------------------------------------------------------- one at a time

# One run per region, as in UpdateFromBlizzard.ps1: two writers on one file end
# with the loser's work discarded. The process id is checked rather than trusted
# so a run that died cannot lock the job out for ever.
$lockFile = Join-Path $PSScriptRoot ("UpdateSpecs-" + $Region + ".lock")

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

$progressFile = Join-Path $PSScriptRoot ("UpdateSpecs-" + $Region + ".progress")
$startedAt = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

function Write-Progress-File([int]$done,[int]$total) {
    Set-Content -Path $progressFile -Encoding utf8 -Value `
        ("specs|{0}|{1}|{2}|{3}" -f $Region, $done, $total, $startedAt)
}

# Once up front, so the dashboard shows the run the moment it starts rather
# than fifty characters in.
Write-Progress-File 0 $todo

# Everything to ask about, settled before any of it is sent: the loop below
# hands work out rather than walking the list.
$work = New-Object System.Collections.Generic.List[object]
foreach ($key in $wanted.Keys) {
    if (-not $full -and $seen.ContainsKey($key) -and -not $stale.Contains($key)) { continue }
    if ($Limit -gt 0 -and $work.Count -ge $Limit) { break }

    $who = $wanted[$key]

    # The realm is already a slug; the name needs lower casing and escaping,
    # since accented names are common at the top of a ladder.
    $name = [uri]::EscapeDataString($who.Name.ToLower())

    $base = "$apiRoot/profile/wow/character/$($who.Realm)/$name"

    # TBC has no specs, so active_spec on the character comes back EMPTY and a
    # second request is the only way to learn what someone plays: the talent
    # trees, whose biggest pile of spent points is the spec. Costs one extra
    # request per character -- but only for characters never seen before, since
    # this pass is incremental, so it is paid once each rather than every run.
    $specUri = $null
    if ($Version -eq "tbc") { $specUri = "$base/specializations?namespace=$profileNs&locale=en_US" }

    $work.Add([pscustomobject]@{
        Key = $key
        Uri = $base + "?namespace=$profileNs&locale=en_US"
        SpecUri = $specUri
    })
}

# One request, in its own runspace. Self-contained on purpose: a runspace
# inherits nothing from here, so everything it needs arrives as an argument.
$one = {
    param($uri, $auth, $specUri)

    for ($attempt = 1; $attempt -le 2; $attempt++) {
        try {
            # Timed out rather than trusted: without this the call waits for
            # ever on a connection that is open and silent, and the loop
            # collecting answers waits with it.
            $c = Invoke-RestMethod -Uri $uri -Headers @{ Authorization = $auth } -ErrorAction Stop -TimeoutSec 30

            $genderId = 0
            if ($c.gender.type -eq 'FEMALE') { $genderId = 1 }

            # Empty on TBC, filled from the talent trees just below.
            $spec = $c.active_spec.name

            if ($specUri) {
                try {
                    $sp = Invoke-RestMethod -Uri $specUri -Headers @{ Authorization = $auth } -ErrorAction Stop -TimeoutSec 30

                    # The active group, not the first: TBC characters carry a
                    # second saved build, and reading whichever came back first
                    # would report the off-spec for anyone who has one.
                    $group = $sp.specialization_groups | Where-Object { $_.is_active } | Select-Object -First 1
                    if (-not $group) { $group = $sp.specialization_groups | Select-Object -First 1 }

                    $best = $group.specializations |
                            Sort-Object { [int]$_.spent_points } -Descending |
                            Select-Object -First 1
                    if ($best) { $spec = $best.specialization_name }
                } catch {
                    # Left as it was. A character whose trees cannot be read is
                    # worth keeping with a class and no spec, the same as one
                    # whose spec is genuinely blank -- not worth failing over.
                }
            }

            [pscustomobject]@{
                Status = 'ok'
                Class  = $c.character_class.name
                Spec   = $spec
                Race   = $(if ($c.race.id) { [int]$c.race.id } else { 0 })
                Gender = $genderId
            }
        } catch {
            $code = $_.Exception.Response.StatusCode.value__

            # Turned away for going too fast is worth one more go.
            if ($code -eq 429 -and $attempt -lt 2) {
                Start-Sleep -Milliseconds 400
                continue
            }

            # The code comes out with it. 404 means this character is gone --
            # renamed, transferred, deleted -- and is worth remembering as
            # unanswerable. Anything else is us being refused or timed out, and
            # remembering THAT would blank a live character for good.
            [pscustomobject]@{ Status = 'fail'; Code = $code }
        }

        break
    }
}

$ShellTimeoutMs = 45000
$pool = [runspacefactory]::CreateRunspacePool(1, $Concurrency)
$pool.Open()

try {
    # A sliding window: $Concurrency requests in the air at all times, each slot
    # refilling the instant its own answer lands.
    $inFlight = New-Object System.Collections.Generic.List[object]
    $next = 0
    $lastReport = 0
    $lastSaid = 0
    $windowStart = [datetime]::UtcNow
    $windowCount = 0

    while ($next -lt $work.Count -or $inFlight.Count -gt 0) {

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
            $null = $shell.AddScript($one).AddArgument($item.Uri).AddArgument($headers.Authorization).AddArgument($item.SpecUri)

            $inFlight.Add([pscustomobject]@{
                Shell   = $shell
                Handle  = $shell.BeginInvoke()
                Item    = $item
                Started = [datetime]::UtcNow
            })
            $windowCount += $perItem
        }

        # Collect whatever has landed. Backwards, because finished ones are
        # removed as they are read.
        $landed = 0
        for ($i = $inFlight.Count - 1; $i -ge 0; $i--) {
            $job = $inFlight[$i]
            $overdue = (([datetime]::UtcNow - $job.Started).TotalMilliseconds -gt $ShellTimeoutMs)

            if (-not $job.Handle.IsCompleted -and -not $overdue) { continue }

            $answer = $null
            if ($job.Handle.IsCompleted) {
                try { $answer = $job.Shell.EndInvoke($job.Handle) | Select-Object -First 1 } catch { }
                $job.Shell.Dispose()
            } else {
                # Abandoned, not waited on: Stop and Dispose would both block on
                # the very thread that is refusing to finish.
                try { $null = $job.Shell.BeginStop($null, $null) } catch { }
            }

            $inFlight.RemoveAt($i)
            $landed++
            $asked++

            $key = $job.Item.Key

            if ($answer -and $answer.Status -eq 'ok' -and $answer.Class -and $answer.Spec) {
                $slug = (($answer.Class + '-' + $answer.Spec).ToLower()) -replace ' ', '-'
                $seen[$key] = @{ Slug = $slug; Seen = $askedOn; Race = $answer.Race; Gender = $answer.Gender }
                $found++
            } elseif ($answer -and $answer.Status -eq 'ok') {
                # Answered, but not about a class and a spec.
                $seen[$key] = @{ Slug = ''; Seen = $askedOn; Race = $answer.Race; Gender = $answer.Gender }
                $missing++
            } elseif ($answer -and $answer.Code -eq 404) {
                # Gone for good: an empty slug is recorded so later runs stop
                # asking about a character that no longer exists.
                $seen[$key] = @{ Slug = ''; Seen = $askedOn; Race = 0; Gender = 0 }
                $missing++
            } else {
                # Refused, timed out, or no answer at all -- nothing was learned
                # about this character, so nothing is remembered and the next run
                # asks again. Recording it here is how a burst of 429s used to
                # blank 1,635 live characters permanently: they were cached as
                # 'asked, nothing there' and an incremental run never revisits.
                $missing++
            }
        }

        if ($landed -eq 0) { Start-Sleep -Milliseconds 10 }

        # The results are written only at the end -- thousands of small file
        # writes would cost more than the requests -- so this file is the only
        # thing standing between the dashboard and a bar that cannot say whether
        # it is working.
        if ($asked - $lastReport -ge 50) {
            $lastReport = $asked
            Write-Progress-File $asked $todo
        }

        if ($asked - $lastSaid -ge 250) {
            $lastSaid = $asked
            Write-Host ("  {0} asked, {1} found, {2} missing" -f $asked, $found, $missing)
        }
    }
} finally {
    $pool.Close()
    $pool.Dispose()
}

# Gone when the work is: its absence is what says "not running".
if (Test-Path $progressFile) { Remove-Item $progressFile -Force }
if ($writer) { $writer.Dispose() }
if (Test-Path $lockFile) { Remove-Item $lockFile -Force }

# ---------------------------------------------------------------- write

$now = Get-Date -Format $TimeFormat

# Everyone on the ladder now is on it today, whether or not they were asked
# about this run. That is what keeps a returning regular from ageing out of the
# cache and being asked about all over again.
foreach ($key in $wanted.Keys) {
    if ($seen.ContainsKey($key)) { $seen[$key].Seen = $askedOn }
}

# Misses are written as 0, not dropped.
#
# Two reasons, and the second is the expensive one. A row the addon cannot find
# is ambiguous -- not yet fetched, or genuinely hidden -- and only the second
# deserves to be labelled "(hidden)". And a miss that is not recorded looks
# unknown to the next run, so every future pass would ask about the same
# five per cent of characters again, forever.
#
# Only characters currently on the ladder are written. Without that the shipped
# file grows for ever: everybody who ever placed and then dropped off stays in
# it, and it ships to everybody. What was asked is remembered in the cache
# instead, which does not ship.
#
# Built before the slug list below, because resolving a cached slug can add to
# that list -- a spec nobody on this region played last run.
$rows = New-Object System.Collections.Generic.List[string]
$looks = New-Object System.Collections.Generic.List[string]
foreach ($key in ($seen.Keys | Sort-Object)) {
    if (-not $wanted.Contains($key)) { continue }

    $slug = $seen[$key].Slug
    if ([string]::IsNullOrEmpty($slug)) {
        $value = 0
    } else {
        $index = $specList.IndexOf($slug)
        if ($index -lt 0) { $null = $specList.Add($slug); $index = $specList.Count - 1 }
        $value = $index + 1
    }

    $null = $rows.Add("`t[" + '"' + $key + '"' + "]=" + $value + ",")

    # Race and gender as one number, race times ten plus gender, so a row costs
    # two or three digits rather than a table of its own. 0 means not known.
    $look = ([int]$seen[$key].Race * 10) + [int]$seen[$key].Gender
    if ($look -gt 0) { $null = $looks.Add("`t[" + '"' + $key + '"' + "]=" + $look + ",") }
}
$rowBody = ($rows -join "`n")
$lookBody = ($looks -join "`n")

$listBody = ($specList | ForEach-Object { "`t" + '"' + $_ + '",' }) -join "`n"

# ---------------------------------------------------------------- cache

# Anyone not seen on the ladder for half a year is dropped: they are unlikely to
# come back, and if they do it is one request to find out. Without a cutoff this
# file is the one thing here that grows without bound.
$stale = (Get-Date).AddDays(-180).ToString('yyyy-MM-dd')

$cacheLines = New-Object System.Collections.Generic.List[string]
# Advanced whenever a slice was taken, because the slice is sized from the gap
# since this stamp. Left alone on a run that asked about nobody, so the time
# still counts towards the next slice rather than being forgotten.
$fullStamp = if ($full -or $slice -gt 0) { (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') } else { $lastFull.ToString('yyyy-MM-dd HH:mm:ss') }
$null = $cacheLines.Add("# What has been asked about, so returning characters are not asked about twice.")
$null = $cacheLines.Add("# Not shipped. Safe to delete: it costs one full pass to rebuild.")
$null = $cacheLines.Add("# lastFull=$fullStamp")

$dropped = 0
foreach ($key in ($seen.Keys | Sort-Object)) {
    if ($seen[$key].Seen -lt $stale) { $dropped++; continue }
    $null = $cacheLines.Add(("{0}|{1}|{2}|{3}|{4}" -f $key, $seen[$key].Slug, $seen[$key].Seen,
        $seen[$key].Race, $seen[$key].Gender))
}
Set-Content -Path $cacheFile -Value ($cacheLines -join "`n") -Encoding utf8

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

-- Class and spec for the characters on the ladder, written by
-- tools\UpdateSpecs.ps1 from Blizzard's character profile API.
--
-- Stored as an index into SPEC_SLUGS rather than as two strings each: the same
-- information at about a quarter of the size, and this file ships to everybody
-- who installs the addon.
--
-- A character the API would not answer for -- a hidden profile, or one renamed,
-- transferred or deleted -- is recorded as 0 rather than left out, so it is not
-- asked about again and the addon can tell hidden from not-yet-known.
--
-- Region $Region, $($rows.Count) characters, read $now.
-- Per region, and that is not tidiness.
--
-- Both regions build this list in the order they happen to meet each spec, so
-- the two orders differ. Shared as one table with "or", the first file loaded
-- won and the second region's indices were read against the wrong list: ninety
-- per cent of EU rows showed somebody else's spec, and the top of the EU ladder
-- called a warrior a mage. An index only means something beside the list it was
-- written against, so the list travels with it.
ns.SPEC_SLUGS_BY_REGION = ns.SPEC_SLUGS_BY_REGION or {}

ns.SPEC_SLUGS_BY_REGION["$Region"] = {
$listBody
}

-- Kept for anything still reading the old name; it is the same list this file
-- was written against.
ns.SPEC_SLUGS = ns.SPEC_SLUGS or ns.SPEC_SLUGS_BY_REGION["$Region"]

-- Race and gender, as race times ten plus gender (0 male, 1 female), so the
-- ladder can show who somebody is. Free: the same request that answers the spec
-- answers these.
ns.LOOKS_BY_REGION = ns.LOOKS_BY_REGION or {}

ns.LOOKS_BY_REGION["$Region"] = {
$lookBody
}

ns.SPECS_BY_REGION = ns.SPECS_BY_REGION or {}

ns.SPECS_BY_REGION["$Region"] = {
$rowBody
}
"@

Set-Content -Path $specFile -Value $out -Encoding utf8
$note = if ($full) { " full pass," } else { "" }
Write-Log ("{0}:{1} asked {2}, found {3}, missing {4}. {5} characters written, {6} remembered. requests={7}" -f `
    $Region.ToUpper(), $note, $asked, $found, $missing, $rows.Count, ($cacheLines.Count - 3), ($asked * $perItem + 1))
