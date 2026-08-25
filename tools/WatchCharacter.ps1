# Does a rating reach the API only after the character logs out?
#
# The question came from a real case: a rank moved from 60 to 34, a third-party
# site showed it within about twenty minutes, and Blizzard's leaderboard did not
# have it hours later. Measured since: our reads are current -- a request with a
# cache key nothing had ever seen returns the same Last-Modified -- so the delay
# is upstream. What is not yet known is whether the delay is Blizzard rebuilding
# the snapshot on a slow clock, or the character's own rating not being written
# until they disconnect.
#
# Those two look identical from a single reading and completely different over a
# timeline, so this records one. Each run appends a line saying what the
# leaderboard currently says about one character, which snapshot that came from,
# and when the character's own profile was last written.
#
# How to run the test:
#   1. Let this collect a few lines while you are logged in and playing.
#   2. Win or lose enough for the rating to move, and note the new figure.
#   3. Keep playing, or sit online, for at least one new snapshot.
#   4. Log out, and leave it collecting for another snapshot or two.
#
# Then read the log. If the new rating appears in a snapshot built while you
# were still online, logging out has nothing to do with it and the whole delay
# is Blizzard's rebuild cadence. If it only ever appears in the first snapshot
# built after you logged out, the write is gated on disconnect and no amount of
# polling will ever reach it sooner.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File "<path>\WatchCharacter.ps1" -Name Gcdsk -Realm raden

param(
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$true)][string]$Realm,
    [string]$Region = "us",
    # Written by hand when you know it, so the log can say what the game said at
    # the time rather than only what the API said.
    [string]$Note = ""
)

$ErrorActionPreference = "Stop"

$logFile  = Join-Path $PSScriptRoot "WatchCharacter.log"
$credFile = Join-Path $PSScriptRoot "blizzard-credentials.txt"

if (-not (Test-Path $credFile)) { "No blizzard-credentials.txt."; return }

$clientId = $null
$clientSecret = $null
foreach ($line in Get-Content $credFile) {
    if ($line -match '^\s*ClientId\s*=\s*(.+?)\s*$')     { $clientId = $Matches[1] }
    if ($line -match '^\s*ClientSecret\s*=\s*(.+?)\s*$') { $clientSecret = $Matches[1] }
}

$pair  = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$clientId`:$clientSecret"))
$token = (Invoke-RestMethod -Method Post -Uri "https://oauth.battle.net/token" `
            -Headers @{ Authorization = "Basic $pair" } -Body @{ grant_type = 'client_credentials' }).access_token

$headers = @{ Authorization = "Bearer $token" }
$apiRoot = "https://$Region.api.blizzard.com"
$dynamic = "dynamic-classic-$Region"
$profile = "profile-classic-$Region"

$season = (Invoke-RestMethod -Uri "$apiRoot/data/wow/pvp-season/index?namespace=$dynamic" -Headers $headers).current_season.id

# What the leaderboards say about this character right now, and which snapshot
# that answer came out of.
$found = @()
$snapshot = ""

foreach ($bracket in @("2v2","3v3","5v5","rbg")) {
    $uri = "$apiRoot/data/wow/pvp-season/$season/pvp-leaderboard/$bracket" + "?namespace=$dynamic&locale=en_US"

    # Invoke-WebRequest rather than Invoke-RestMethod: the header is the point.
    $response = Invoke-WebRequest -Uri $uri -Headers $headers -UseBasicParsing

    $stamp = $response.Headers['Last-Modified']
    if ($stamp) {
        $when = [datetime]::MinValue
        if ([datetime]::TryParse($stamp, [ref]$when)) {
            $asText = $when.ToUniversalTime().ToString('yyyy-MM-dd HH:mm')
            if ($asText -gt $snapshot) { $snapshot = $asText }
        }
    }

    foreach ($entry in ($response.Content | ConvertFrom-Json).entries) {
        if ($entry.character.name -ne $Name) { continue }
        if ($entry.character.realm.slug -ne $Realm) { continue }
        $found += ("{0} rank {1} rating {2}" -f $bracket, $entry.rank, $entry.rating)
    }
}

# When the character's own profile was last written, which is the other half of
# the question: it was eleven hours stale on a character being played daily,
# which is what a write gated on logout looks like.
$profileWritten = "?"
try {
    $me = Invoke-WebRequest -Uri ("$apiRoot/profile/wow/character/$Realm/" + [uri]::EscapeDataString($Name.ToLower()) + "?namespace=$profile&locale=en_US") `
            -Headers $headers -UseBasicParsing
    if ($me.Headers['Last-Modified']) {
        $when = [datetime]::MinValue
        if ([datetime]::TryParse($me.Headers['Last-Modified'], [ref]$when)) {
            $profileWritten = $when.ToUniversalTime().ToString('yyyy-MM-dd HH:mm')
        }
    }
} catch { $profileWritten = "unreadable" }

$line = "{0} UTC | snapshot {1} | profile written {2} | {3}{4}" -f `
    (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm'), `
    $(if ($snapshot) { $snapshot } else { "?" }), `
    $profileWritten, `
    $(if ($found.Count -gt 0) { $found -join " ; " } else { "not on any ladder" }), `
    $(if ($Note) { "  << $Note" } else { "" })

Add-Content -Path $logFile -Value $line -Encoding utf8
$line
