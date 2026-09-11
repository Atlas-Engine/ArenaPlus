# Does the Classic profile API serve a season-best rating, titles or mounts?
#
# Three things were asked for on a character record -- a max rating, notable PvP
# titles, and reward mounts -- and all three depend on endpoints and fields this
# pipeline has never called. Guessing which exist would mean shipping columns
# that are null for everybody, so this asks.
#
# Prints the SHAPE of each response -- status, and the key names at the top
# level and one level down -- not the bodies, which run to hundreds of lines.
# The question is "is the field there", and a key list answers it.
#
# Reads credentials from blizzard-credentials.txt beside this file, the same way
# CheckBlizzardApi.ps1 does. Nothing is printed from that file.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File "<path>\ProbePvPExtras.ps1"
#   ... -Region eu -Realm raden -Name Wealthycat
#   ... -Version tbc -Realm spineshatter -Name Mirlol

param(
    [string]$Region  = "us",
    [string]$Version = "mop",
    [string]$Realm   = "raden",
    [string]$Name    = "Wealthycat",
    [string]$Bracket = "2v2"
)

$ErrorActionPreference = "Stop"

$credFile = Join-Path $PSScriptRoot "blizzard-credentials.txt"
if (-not (Test-Path $credFile)) { throw "No blizzard-credentials.txt beside this script." }

$clientId = $null
$clientSecret = $null
foreach ($line in Get-Content $credFile) {
    if ($line -match '^\s*ClientId\s*=\s*(.+?)\s*$')     { $clientId = $Matches[1] }
    if ($line -match '^\s*ClientSecret\s*=\s*(.+?)\s*$') { $clientSecret = $Matches[1] }
}
if (-not $clientId -or -not $clientSecret) { throw "Credentials file is missing ClientId or ClientSecret." }

$pair = [System.Text.Encoding]::UTF8.GetBytes("${clientId}:${clientSecret}")
$basic = [Convert]::ToBase64String($pair)

$token = (Invoke-RestMethod -Method Post -Uri "https://oauth.battle.net/token" `
    -Headers @{ Authorization = "Basic $basic" } `
    -Body @{ grant_type = "client_credentials" }).access_token

$apiRoot = "https://$Region.api.blizzard.com"
$profileNs = if ($Version -eq "tbc") { "profile-classicann-$Region" } else { "profile-classic-$Region" }
$staticNs  = if ($Version -eq "tbc") { "static-classicann-$Region" }  else { "static-classic-$Region" }
$headers = @{ Authorization = "Bearer $token" }

$slug = $Name.ToLower()

function Keys($object, [int]$depth = 0, [int]$limit = 40) {
    if ($null -eq $object) { return }
    $pad = "  " * ($depth + 2)
    $shown = 0
    foreach ($property in $object.PSObject.Properties) {
        if ($shown -ge $limit) { Write-Host ($pad + "...") ; break }
        $shown++

        $value = $property.Value
        $what =
            if ($null -eq $value)                 { "null" }
            elseif ($value -is [array])           { "array[{0}]" -f $value.Count }
            elseif ($value -is [string])          { "string" }
            elseif ($value -is [bool])            { "bool" }
            elseif ($value -is [int] -or $value -is [long] -or $value -is [double]) { "number = $value" }
            else                                  { "object" }

        Write-Host ("{0}{1}: {2}" -f $pad, $property.Name, $what)

        # One level down only, and only into objects: the interesting fields
        # (season_match_statistics, tier, weekly_match_statistics) are nested.
        if ($depth -lt 1 -and $what -eq "object") { Keys $value ($depth + 1) $limit }
    }
}

function Ask([string]$label, [string]$path, [string]$namespace) {
    Write-Host ""
    Write-Host ("=== {0}" -f $label)
    Write-Host ("    {0}" -f $path)

    $sep = if ($path.Contains("?")) { "&" } else { "?" }
    $uri = "{0}{1}{2}namespace={3}&locale=en_US" -f $apiRoot, $path, $sep, $namespace

    try {
        $response = Invoke-WebRequest -Uri $uri -Headers $headers -UseBasicParsing
        Write-Host ("    HTTP {0}" -f [int]$response.StatusCode)
        $body = $response.Content | ConvertFrom-Json
        Keys $body
        return $body
    } catch {
        # The status is the answer here: 404 means this namespace does not serve
        # it, which is exactly what needs knowing before any code depends on it.
        $code = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
        Write-Host ("    HTTP {0} -- {1}" -f $code, $_.Exception.Message)
        return $null
    }
}

Write-Host ("Probing {0} {1}, character {2}-{3}" -f $Version, $Region.ToUpper(), $Name, $Realm)
Write-Host ("profile namespace: {0}" -f $profileNs)

$who = "/profile/wow/character/$Realm/$([uri]::EscapeDataString($slug))"

# 1. What the pipeline already reads. Looking for anything season-best shaped.
Ask "pvp-bracket (already used)" "$who/pvp-bracket/$Bracket" $profileNs

# 2. The other PvP endpoint, which retail uses for honour and bracket summaries.
Ask "pvp-summary" "$who/pvp-summary" $profileNs

# 3. Titles, achievements, mounts -- none of these has ever been called here.
Ask "achievements" "$who/achievements" $profileNs
Ask "achievements/statistics" "$who/achievements/statistics" $profileNs
Ask "titles" "$who/titles" $profileNs
Ask "collections" "$who/collections" $profileNs
Ask "collections/mounts" "$who/collections/mounts" $profileNs

# 4. And the character document itself, which on retail carries active_title.
Ask "character profile" "$who" $profileNs

# 5. Static data, to know whether names can be resolved for a lookup table.
Ask "achievement 2090 (Gladiator, retail id)" "/data/wow/achievement/2090" $staticNs
Ask "mount index" "/data/wow/mount/index" $staticNs

Write-Host ""
Write-Host "--- done ---"
