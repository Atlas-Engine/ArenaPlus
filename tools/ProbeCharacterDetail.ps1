# Does the classic profile API carry gear, enchants, gems, talents and glyphs?
#
# The question behind it: the leaderboard gives name, realm and rating, and the
# character profile gives class and spec. If equipment and talents are there
# too, the ladder could show what the site shows. If they are not, or are
# retail-shaped and empty for classic, nothing else is worth designing.
#
# Nothing is written. This only asks and reports.
#
# Usage:  powershell -ExecutionPolicy Bypass -File "<path>\ProbeCharacterDetail.ps1"

param(
    [string]$Region = "us",
    [string]$Realm  = "raden",
    [string]$Name   = "acx"
)

$ErrorActionPreference = "Stop"

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
$ns      = "profile-classic-$Region"

$base = "/profile/wow/character/$Realm/$Name"

$paths = @(
    $base,
    "$base/equipment",
    "$base/specializations",
    "$base/statistics",
    "$base/appearance",
    "$base/character-media",
    "$base/pvp-summary",
    "$base/achievements"
)

"Probing $Name-$Realm ($($Region.ToUpper()))"
""

foreach ($path in $paths) {
    $uri = "$apiRoot$path" + "?namespace=$ns&locale=en_US"
    try {
        $r = Invoke-RestMethod -Uri $uri -Headers $headers -ErrorAction Stop
        $json = $r | ConvertTo-Json -Depth 12 -Compress
        $fields = ($r.PSObject.Properties.Name | Where-Object { $_ -notlike '_*' }) -join ', '
        "{0,-22} OK    {1,7} bytes" -f $path.Replace($base,'(base)'), $json.Length
        "                       fields: $fields"
    } catch {
        $code = $_.Exception.Response.StatusCode.value__
        "{0,-22} {1}" -f $path.Replace($base,'(base)'), $(if ($code) { "HTTP $code" } else { $_.Exception.Message })
    }
    Start-Sleep -Milliseconds 100
}

# If equipment answered, look at what one item actually carries -- the whole
# question is whether enchants and gems are in there, not just item ids.
""
"---- one equipped item in full ----"
try {
    $eq = Invoke-RestMethod -Uri "$apiRoot$base/equipment?namespace=$ns&locale=en_US" -Headers $headers -ErrorAction Stop
    "items returned: $($eq.equipped_items.Count)"
    $first = $eq.equipped_items | Select-Object -First 1
    $first | ConvertTo-Json -Depth 8
} catch {
    "equipment not available: $($_.Exception.Message)"
}

""
"---- talents and glyphs ----"
try {
    $sp = Invoke-RestMethod -Uri "$apiRoot$base/specializations?namespace=$ns&locale=en_US" -Headers $headers -ErrorAction Stop
    $sp | ConvertTo-Json -Depth 8
} catch {
    "specializations not available: $($_.Exception.Message)"
}
