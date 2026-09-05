# Does Blizzard's own API serve a live MoP Classic PvP leaderboard?
#
# The question behind it: if it does, the ladder can be read from Blizzard
# directly rather than scraped from a third party -- no load on somebody else's
# site, and nothing to ask permission about before publishing. It does, and
# UpdateFromBlizzard.ps1 is the result; this stays as the probe to re-run
# whenever an endpoint starts looking wrong.
#
# Worth measuring rather than assuming, because both stories are on record: the
# Classic namespace exposes the endpoint, and there is an unanswered report of
# it returning data unchanged since the second day of a season.
#
# Reads credentials from blizzard-credentials.txt beside this file. See
# blizzard-credentials.example.txt for how to get them.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File "<path>\CheckBlizzardApi.ps1"
#   powershell -ExecutionPolicy Bypass -File "<path>\CheckBlizzardApi.ps1" -Name Somebody -Bracket 3v3

param(
    [string]$Region  = "us",
    [string]$Bracket = "2v2",
    # A character to look for, so "is it live" can be answered against a rating
    # you already know rather than against a stranger's.
    [string]$Name    = "",
    # Which game-data namespace to ask. Empty means the current Classic
    # progression, which is what this script was written against. Naming
    # another lets the same probe answer "does THIS version serve a
    # leaderboard at all" -- e.g. dynamic-classic1x-us.
    #
    # PowerShell variable names are case-INSENSITIVE, so $Namespace and the
    # $namespace used below are one and the same variable. That is why the
    # default is applied with an if rather than a plain assignment: an
    # unconditional one would silently overwrite whatever was passed in.
    [string]$Namespace = ""
)

$ErrorActionPreference = "Stop"

$credFile = Join-Path $PSScriptRoot "blizzard-credentials.txt"
if (-not (Test-Path $credFile)) {
    Write-Host "No credentials file. Copy blizzard-credentials.example.txt to blizzard-credentials.txt and fill it in."
    return
}

$clientId = $null
$clientSecret = $null
foreach ($line in Get-Content $credFile) {
    if ($line -match '^\s*ClientId\s*=\s*(.+?)\s*$')     { $clientId = $Matches[1] }
    if ($line -match '^\s*ClientSecret\s*=\s*(.+?)\s*$') { $clientSecret = $Matches[1] }
}

if (-not $clientId -or -not $clientSecret) {
    Write-Host "blizzard-credentials.txt is missing ClientId or ClientSecret."
    return
}

# ---------------------------------------------------------------- token

# Client-credentials grant: the id and secret are exchanged once for a token
# that lasts about a day. Sent as Basic auth, which is what Blizzard expects.
$pair = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$clientId`:$clientSecret"))
$token = (Invoke-RestMethod -Method Post -Uri "https://oauth.battle.net/token" `
    -Headers @{ Authorization = "Basic $pair" } `
    -Body @{ grant_type = "client_credentials" }).access_token

if (-not $token) { Write-Host "No access token came back - check the credentials."; return }
Write-Host "Token acquired."

if (-not $Namespace) { $Namespace = "dynamic-classic-$Region" }
Write-Host ("namespace: {0}" -f $Namespace)
$root      = "https://$Region.api.blizzard.com"

function Get-Api([string]$path) {
    $sep = if ($path.Contains("?")) { "&" } else { "?" }
    return Invoke-RestMethod -Uri ("{0}{1}{2}namespace={3}&locale=en_US" -f $root,$path,$sep,$namespace) `
        -Headers @{ Authorization = "Bearer $token" }
}

# ---------------------------------------------------------------- discover

# Same shape as UpdateFromBlizzard.ps1, which is the pass that actually runs:
# the season index answers which season is current, and the leaderboard hangs
# straight off it. An earlier version of this probe went through a
# /data/wow/pvp-region/ segment, which 404s -- it never matched the working
# scraper, so a failure here used to look like "this version has no ladder"
# when it only meant the probe was asking the wrong URL.
try {
    $season = (Get-Api "/data/wow/pvp-season/index").current_season.id
} catch {
    # A namespace that does not exist fails here, on the very first call.
    # Reported rather than thrown so a sweep over candidates keeps going.
    Write-Host ("  no pvp-season index ({0})" -f $_.Exception.Message)
    return
}
Write-Host ("current season: {0}" -f $season)

try {
    $board = Get-Api "/data/wow/pvp-season/$season/pvp-leaderboard/$Bracket"
} catch {
    Write-Host ("  {0}: no leaderboard ({1})" -f $Bracket, $_.Exception.Message)
    return
}

$entries = @($board.entries)
Write-Host ("  {0}: {1} entries" -f $Bracket, $entries.Count)

if ($entries.Count -gt 0) {
    $top = $entries[0]
    Write-Host ("  top: #{0} {1}-{2} rating {3} ({4}-{5})" -f `
        $top.rank, $top.character.name, $top.character.realm.slug, $top.rating,
        $top.season_match_statistics.won, $top.season_match_statistics.lost)
    $last = $entries[$entries.Count - 1]
    Write-Host ("  last: #{0} rating {1}" -f $last.rank, $last.rating)
    $realms = @($entries | ForEach-Object { $_.character.realm.slug } | Sort-Object -Unique)
    Write-Host ("  realms represented: {0}" -f ($realms -join ", "))
}

if ($Name -ne "") {
    $mine = $entries | Where-Object { $_.character.name -eq $Name }
    if ($mine) {
        Write-Host ("  {0}: #{1} rating {2} ({3}-{4}) on {5}" -f `
            $Name, $mine.rank, $mine.rating, $mine.season_match_statistics.won,
            $mine.season_match_statistics.lost, $mine.character.realm.slug)
    } else {
        Write-Host ("  {0}: not in this leaderboard" -f $Name)
    }
}
