# Who has actually been playing, out of the activity log the ladder pass keeps.
#
# Costs no requests at all. Every number here was already paid for: the ladder
# pass writes one row per character per poll whose win or loss count moved, and
# this reads those rows back off disk. Nothing is asked of Blizzard, so this can
# run as often as is useful without touching the request budget.
#
# What it produces is three windows -- the last hour, day and week -- of games
# played and rating moved, per character per bracket. The shipped leaderboard is
# a photograph of where everybody stands; this is the only thing in the addon
# that says who is at the keyboard.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File "<path>\UpdateActivity.ps1" -Region us
#   ... -Region tbc-eu      the Anniversary ladders, same as every other pass
param(
    # The full data key, not the bare region: "us", "eu", "tbc-us", "tbc-eu".
    # Named to match the files -- Activity-tbc-us-2026-09.tsv beside
    # Leaderboard-tbc-us.lua -- so there is nothing to assemble here and
    # nothing to get wrong.
    [string]$Region = "us",

    # The windows, in hours, narrowest first.
    #
    # These are the stops on the addon's slider and there is no point shipping a
    # window it cannot ask for. Changing them changes both ends, so they are
    # written into the table itself rather than assumed separately in each.
    #
    # One hour to a day. A week was shipped first and dropped: it was four
    # fifths of the file on its own -- everybody who played at all in seven days
    # is in it -- and it answers "who grinds", where this view is for "who is
    # playing".
    [int[]]$Windows = @(1, 3, 6, 12, 24)
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "DataClients.ps1")

$logFile = Join-Path $PSScriptRoot "UpdateActivity.log"
$TimeFormat = "yyyy-MM-dd hh:mm tt"

function Write-Log([string]$message) {
    Write-Host $message
    Add-Content -Path $logFile -Value ("{0}  {1}" -f (Get-Date -Format $TimeFormat), $message) -Encoding utf8
}

function Escape-Lua([string]$text) {
    if ($null -eq $text) { return "" }
    return $text.Replace('\', '\\').Replace('"', '\"')
}

$root = Split-Path $PSScriptRoot -Parent
$data = Join-Path (Split-Path $root -Parent) "ArenaPlus_Data"

$ladderFile   = Join-Path $data ("Leaderboard-" + $Region + ".lua")
$activityFile = Join-Path $data ("Activity-" + $Region + ".lua")

if (-not (Test-Path $ladderFile)) {
    Write-Log "No ladder file for $Region -- run UpdateFromBlizzard.ps1 first."
    return
}

# ---------------------------------------------------------------- the log
#
# This month and last. The widest window is a day, so it crosses the first of
# the month only on the 1st itself -- but reading one file would report a day
# that began at midnight on that day, and it costs nothing to read both.

# Character for character what UpdateFromBlizzard.ps1 uses to stamp the rows
# this reads, and that is the point: every comparison below is between the two,
# so they have to be wrong in the same direction if they are wrong at all.
#
# [datetime]'1970-01-01' is deliberate and is NOT interchangeable with
# Get-Date "1970-01-01Z". The literal has Kind=Unspecified and subtracts as
# plain ticks; the parsed one is converted to local time first, so the
# subtraction comes out short by the machine's UTC offset. That put every
# timestamp five hours in the future here and left the one-hour window empty
# while the day and week ones looked perfectly healthy.
$now = [int][math]::Floor(((Get-Date).ToUniversalTime() - [datetime]'1970-01-01').TotalSeconds)

$tsvFiles = @()
foreach ($back in 0, 1) {
    $stamp = (Get-Date).AddMonths(-$back).ToString('yyyy-MM')
    $path = Join-Path $PSScriptRoot ("Activity-" + $Region + "-" + $stamp + ".tsv")
    if (Test-Path $path) { $tsvFiles += $path }
}

if ($tsvFiles.Count -eq 0) {
    Write-Log "No activity log for $Region yet -- the ladder pass writes it, so this is expected on a fresh install."
    return
}

# ---------------------------------------------------------------- the ladder
#
# Read for one reason: the display name.
#
# The log stores names lowered by .NET, which folds accented capitals -- so
# "AEzys" with the ligature is stored folded. The addon's own :lower() is ASCII
# only and would leave that name exactly as it found it, so a key built from
# the log can never be found by a client working from the ladder. Measured
# across the four ladders: 872 characters would silently show no activity, 626
# of them on Mists EU alone.
#
# So the join happens here, where .NET does both halves and agrees with itself,
# and what is written out is the display name exactly as the ladder carries it.
# The addon then matches byte for byte and lowercases nothing.
#
# Keyed by bracket as well as by character: the log counts 2v2 games and 3v3
# games separately, and so does the ladder.
$display = New-KeyTable
$bracket = 0
foreach ($line in Get-Content $ladderFile -Encoding UTF8) {
    $head = [regex]::Match($line, '^\s*\[(\d+)\]\s*=\s*\{\s*--')
    if ($head.Success) { $bracket = [int]$head.Groups[1].Value; continue }

    $m = [regex]::Match($line, 'name="([^"]+)", realm="([^"]*)"')
    if (-not $m.Success) { continue }

    $name = $m.Groups[1].Value
    $realm = $m.Groups[2].Value
    $display[("{0}|{1}|{2}" -f $bracket, $name.ToLower(), $realm)] = ($name + "|" + $realm)
}

if ($display.Count -eq 0) {
    Write-Log "The $Region ladder file parsed to no rows -- not overwriting the activity table with an empty one."
    return
}

# ---------------------------------------------------------------- totals
#
# One pass over the log covering every window at once rather than one pass
# each. The windows nest -- a row inside the hour is inside the day and the
# week too -- so re-reading a 22,000-row file three times to discover that
# would be waste.
$totals = @{}
foreach ($w in $Windows) { $totals[$w] = @{} }

$read = 0
$matched = 0
$orphans = 0
$phantom = 0

# The last row seen for each character+bracket, to spot the repeat above.
# Ordinal, for exactly the reason the repeat exists in the first place.
$lastSig = New-KeyTable
$widest = ($Windows | Measure-Object -Maximum).Maximum
$oldest = $now - ($widest * 3600)

foreach ($path in $tsvFiles) {
    foreach ($line in Get-Content $path -Encoding UTF8) {
        if (-not $line) { continue }

        # Seven columns until 2026-09-11 and eight after it, the eighth being a
        # diagnostic for an unrelated bug. Read by index from the left so both
        # widths work, which is exactly why that column went on the end.
        $bit = $line -split "`t"
        if ($bit.Count -lt 7) { continue }

        # A byte-order mark rides on the first line of each file and would make
        # that one epoch unparseable. Dropped here rather than guarded against
        # at every later use.
        $stamp = $bit[0].TrimStart([char]0xFEFF)
        $when = 0
        if (-not [int]::TryParse($stamp, [ref]$when)) { continue }

        $read++

        # A row identical to that character's previous one, at the same
        # rating, is not a second session -- it is the same session
        # counted twice.
        #
        # Until 2026-09-12 the passes kept their per-character tables in a
        # PowerShell @{}, whose comparer is culture-aware: the ae-ligature
        # equals the letters "ae", so two real characters on Spineshatter
        # shared one slot in the baseline and one of them diffed against
        # the other's win count on every run. It emitted the same non-zero
        # delta for ever while its rating never moved -- 105 rows for one
        # of them in four days, which read as the busiest player on the
        # ladder.
        #
        # The cause is fixed in DataClients.ps1 (New-KeyTable), but the
        # rows already written stay in the log, so they are filtered here
        # on the way out. Kept rather than deleted: the log is the one
        # thing in this project that cannot be re-fetched, and a bug is
        # evidence too.
        #
        # Measured across 53,670 rows: 165 of them, 0.3%, and 144 of those
        # 165 are the two characters above. A real pair of sessions moves
        # the rating or varies the count; identical at the very next poll
        # is the fingerprint and nothing else produces it.
        $sig = "{0}|{1}|{2}" -f $bit[3], $bit[5], $bit[6]
        if ($lastSig[$bit[2]] -eq $sig) { $phantom++; continue }
        $lastSig[$bit[2]] = $sig

        if ($when -lt $oldest) { continue }

        $row = $display[$bit[2]]
        if (-not $row) { $orphans++; continue }
        $matched++

        # The bracket out of the key rather than out of column 2. Both say the
        # same thing, but the key's copy is the one the ladder was just indexed
        # by, so using it means one spelling can never disagree with the other.
        $index = ($bit[2] -split '\|')[0]

        $moved = [int]$bit[4]
        $won   = [int]$bit[5]
        $lost  = [int]$bit[6]

        foreach ($w in $Windows) {
            if ($when -lt ($now - ($w * 3600))) { continue }

            $per = $totals[$w]
            if (-not $per.ContainsKey($index)) { $per[$index] = New-KeyTable }

            $at = $per[$index]
            if ($at.ContainsKey($row)) {
                $at[$row].Won   += $won
                $at[$row].Lost  += $lost
                $at[$row].Moved += $moved
                if ($when -gt $at[$row].Last) { $at[$row].Last = $when }
            } else {
                $at[$row] = [pscustomobject]@{ Won = $won; Lost = $lost; Moved = $moved; Last = $when }
            }
        }
    }
}

# ---------------------------------------------------------------- write
$out = New-Object System.Text.StringBuilder
foreach ($line in @(
    '-- Who has been playing, written by tools\UpdateActivity.ps1. Do not edit by hand.',
    '--',
    '-- Built from the activity log the ladder pass keeps, which records a row each',
    '-- time a character''s win or loss count moves between two polls. It costs no',
    '-- requests: every figure here was already paid for by that pass.',
    '--',
    '-- Keyed by the display name exactly as the leaderboard carries it, joined to',
    '-- the log on the generator''s side. Do NOT lowercase a name to look it up:',
    '-- Lua''s :lower() folds only A-Z and would miss every accented character.',
    '--',
    '-- [hours][bracket]["Name|realm"] = { won, lost, rating moved, minutes ago }',
    '--',
    '-- "Minutes ago" counts back from `built` below, not from now, and it is when',
    '-- the character was last SEEN to have played rather than when they played.',
    '-- The ladder is polled on a timer, so a game is noticed at the next poll --',
    '-- accurate to fifteen minutes on Mists and to the hour on Anniversary.',
    'ArenaPlusData = ArenaPlusData or {}',
    'local ns = ArenaPlusData',
    '',
    'ns.ACTIVITY_BY_REGION = ns.ACTIVITY_BY_REGION or {}',
    ''
)) { $null = $out.AppendLine($line) }

$null = $out.AppendLine(('ns.ACTIVITY_BY_REGION["{0}"] = {{' -f $Region))
$null = $out.AppendLine(("`tbuilt = {0}," -f $now))
$null = $out.AppendLine(("`tbuiltText = ""{0}""," -f (Get-Date -Format $TimeFormat)))
$null = $out.AppendLine(("`twindows = {{ {0} }}," -f ($Windows -join ", ")))

$written = 0
foreach ($w in $Windows) {
    $null = $out.AppendLine(("`t[{0}] = {{  -- the last {0} hour(s)" -f $w))

    foreach ($index in ($totals[$w].Keys | Sort-Object { [int]$_ })) {
        $null = $out.AppendLine(("`t`t[{0}] = {{" -f $index))

        # Busiest first. The view sorts for itself and does not rely on this,
        # but a file whose rows are already in the order somebody would want is
        # far easier to read when something looks wrong.
        $at = $totals[$w][$index]
        foreach ($row in ($at.Keys | Sort-Object { -($at[$_].Won + $at[$_].Lost) }, { $_ })) {
            $it = $at[$row]
            if (($it.Won + $it.Lost) -le 0) { continue }

            # Minutes before this file was built, not an absolute time.
            #
            # Two reasons. It is three or four digits where an epoch is ten, and
            # there are 25,000 of these across the four regions. And the addon
            # has `built` at the top of the table already, so it can turn this
            # back into a real time and go on ageing it while the window stays
            # open -- which an absolute stamp would let it do too, at four times
            # the size, for no gain.
            #
            # Floored at zero. A clock that moves backwards between the ladder
            # pass and this one -- an NTP correction, the hour changing -- would
            # otherwise write a negative and read as "in the future".
            $ago = [int][math]::Round(($now - $it.Last) / 60)
            if ($ago -lt 0) { $ago = 0 }

            $null = $out.AppendLine(("`t`t`t[""{0}""] = {{ {1}, {2}, {3}, {4} }}," -f `
                (Escape-Lua $row), $it.Won, $it.Lost, $it.Moved, $ago))
            $written++
        }

        $null = $out.AppendLine("`t`t},")
    }

    $null = $out.AppendLine("`t},")
}

$null = $out.AppendLine("}")

Write-DataFile -Path $activityFile -Value $out.ToString()

$size = [math]::Round((Get-Item $activityFile).Length / 1KB)
Write-Log ("{0}: {1} log row(s) read, {2} on the ladder, {3} off it, {4} repeated. {5} entries across {6} window(s), {7} KB." -f `
    $Region.ToUpper(), $read, $matched, $orphans, $phantom, $written, $Windows.Count, $size)

Copy-ToOtherClients -Primary $data -Files @($activityFile) -Say ${function:Write-Log}
