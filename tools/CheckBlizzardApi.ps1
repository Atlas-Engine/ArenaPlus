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
    [string]$Name    = ""
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

$namespace = "dynamic-classic-$Region"
$root      = "https://$Region.api.blizzard.com"

function Get-Api([string]$path) {
    $sep = if ($path.Contains("?")) { "&" } else { "?" }
    return Invoke-RestMethod -Uri ("{0}{1}{2}namespace={3}&locale=en_US" -f $root,$path,$sep,$namespace) `
        -Headers @{ Authorization = "Bearer $token" }
}

# ---------------------------------------------------------------- discover

# Classic has a pvp-region segment retail does not, so the ids have to be asked
# for rather than guessed.
$regions = Get-Api "/data/wow/pvp-region/index"
$regionIds = @($regions.pvp_regions | ForEach-Object { ($_.href -split '/pvp-region/')[1] -replace '\?.*$','' })
Write-Host ("pvp-region ids: {0}" -f ($regionIds -join ", "))

foreach ($regionId in $regionIds) {
    $seasons = Get-Api "/data/wow/pvp-region/$regionId/pvp-season/index"
    $ids = @($seasons.seasons | ForEach-Object { [int](($_.href -split '/pvp-season/')[1] -replace '\?.*$','') })
    if (-not $ids) { continue }

    $current = ($ids | Measure-Object -Maximum).Maximum
    Write-Host ("region {0}: seasons {1}  (current {2})" -f $regionId, ($ids -join ","), $current)

    try {
        $board = Get-Api "/data/wow/pvp-region/$regionId/pvp-season/$current/pvp-leaderboard/$Bracket"
    } catch {
        Write-Host ("  {0}: no leaderboard ({1})" -f $Bracket, $_.Exception.Message)
        continue
    }

    $entries = @($board.entries)
    Write-Host ("  {0}: {1} entries" -f $Bracket, $entries.Count)

    if ($entries.Count -gt 0) {
        $top = $entries[0]
        Write-Host ("  top: #{0} {1} rating {2} ({3}-{4})" -f `
            $top.rank, $top.character.name, $top.rating, $top.season_match_statistics.won, $top.season_match_statistics.lost)
    }

    if ($Name -ne "") {
        $mine = $entries | Where-Object { $_.character.name -eq $Name }
        if ($mine) {
            Write-Host ("  {0}: #{1} rating {2} ({3}-{4}) on {5}" -f `
                $Name, $mine.rank, $mine.rating, $mine.season_match_statistics.won,
                $mine.season_match_statistics.lost, $mine.character.realm.slug)
            Write-Host "  ^ compare that rating against what the game shows you right now."
        } else {
            Write-Host ("  {0}: not in this leaderboard" -f $Name)
        }
    }
}
