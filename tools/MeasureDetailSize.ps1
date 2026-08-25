# What would gear, talents and glyphs actually cost to ship?
#
# The API carries all of it (see ProbeCharacterDetail.ps1). What decides whether
# it is worth building is size: this file would ship to everybody who installs
# the addon, and the leaderboard alone is already 1.15 MB.
#
# So this fetches a handful of real characters, builds the most compact Lua
# record that still holds everything, and reports the average bytes. Multiply by
# the ladder to get the truth rather than an estimate.
#
# Usage:  powershell -ExecutionPolicy Bypass -File "<path>\MeasureDetailSize.ps1" -Sample 8

param(
    [string]$Region = "us",
    [int]$Sample = 8
)

$ErrorActionPreference = "Stop"

$root     = Split-Path $PSScriptRoot -Parent
$credFile = Join-Path $PSScriptRoot "blizzard-credentials.txt"

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

# Straight off the top of the ladder: the characters anyone would actually want
# to look at, and the ones with the most gear to record.
$who = @()
foreach ($line in Get-Content (Join-Path $root ("Leaderboard-$Region.lua"))) {
    $m = [regex]::Match($line, 'name="([^"]+)", realm="([^"]*)"')
    if ($m.Success) {
        $who += @{ Name = $m.Groups[1].Value; Realm = $m.Groups[2].Value }
        if ($who.Count -ge $Sample) { break }
    }
}

$records = New-Object System.Collections.Generic.List[string]
$requests = 1

foreach ($c in $who) {
    $name = [uri]::EscapeDataString($c.Name.ToLower())
    $base = "$apiRoot/profile/wow/character/$($c.Realm)/$name"

    try {
        $eq = Invoke-RestMethod -Uri "$base/equipment?namespace=$ns&locale=en_US" -Headers $headers -ErrorAction Stop
        $sp = Invoke-RestMethod -Uri "$base/specializations?namespace=$ns&locale=en_US" -Headers $headers -ErrorAction Stop
        $requests += 2
    } catch {
        Write-Host ("  {0}-{1}: {2}" -f $c.Name, $c.Realm, $_.Exception.Message)
        continue
    }

    # One item as: slot, item id, then every enchantment id on it. Gems arrive
    # as enchantments carrying a source_item, so this covers enchants and gems
    # in the same list without a second shape.
    $items = New-Object System.Collections.Generic.List[string]
    foreach ($item in $eq.equipped_items) {
        $bits = New-Object System.Collections.Generic.List[string]
        $null = $bits.Add([string]$item.item.id)
        foreach ($e in $item.enchantments) { $null = $bits.Add([string]$e.enchantment_id) }
        $null = $items.Add("[" + $item.slot.type.ToLower() + "]={" + ($bits -join ",") + "}")
    }

    # Talents and glyphs come from two different arrays, which is worth stating
    # because reading the obvious one returns an empty list rather than an
    # error. Talents hang off "specializations", one entry per spec, chosen by
    # matching active_specialization. Glyphs hang off "specialization_groups",
    # whose entries carry is_active and no talents at all.
    #
    # Only the active spec is recorded: the other is the off-spec, which nobody
    # opens a ladder to look at.
    $talents = New-Object System.Collections.Generic.List[string]
    $glyphs  = New-Object System.Collections.Generic.List[string]

    $activeId = $sp.active_specialization.id
    $mine = $sp.specializations | Where-Object { $_.specialization.id -eq $activeId } | Select-Object -First 1
    if (-not $mine) { $mine = $sp.specializations | Select-Object -First 1 }
    if ($mine) {
        foreach ($t in $mine.talents) { $null = $talents.Add([string]$t.spell_tooltip.spell.id) }
    }

    $group = $sp.specialization_groups | Where-Object { $_.is_active } | Select-Object -First 1
    if (-not $group) { $group = $sp.specialization_groups | Select-Object -First 1 }
    if ($group) {
        foreach ($g in $group.glyphs) { $null = $glyphs.Add([string]$g.id) }
    }

    $key = ($c.Name + '-' + $c.Realm).ToLower()
    $record = "[`"$key`"]={g={" + ($items -join ",") + "},t={" + ($talents -join ",") + "},y={" + ($glyphs -join ",") + "}},"
    $null = $records.Add($record)

    Write-Host ("  {0,-24} {1,3} items, {2} talents, {3} glyphs -> {4} bytes" -f `
        $key, $eq.equipped_items.Count, $talents.Count, $glyphs.Count, $record.Length)

    Start-Sleep -Milliseconds 100
}

""
if ($records.Count -eq 0) { "Nothing fetched."; return }

$total = 0
foreach ($r in $records) { $total += $r.Length }
$average = [math]::Round($total / $records.Count)

"Sampled           : {0} characters, {1} requests" -f $records.Count, $requests
"Average record    : {0} bytes" -f $average
""
"Shipped size if this covered:"
foreach ($n in @(100, 500, 1000, 5000, 10400)) {
    "  {0,6} characters : {1,8:N0} KB   ({2:N0} requests a pass)" -f $n, (($n * $average) / 1KB), ($n * 2)
}
""
"For scale: Leaderboard-us.lua is {0:N0} KB and Specs-us.lua is {1:N0} KB." -f `
    ((Get-Item (Join-Path $root "Leaderboard-$Region.lua")).Length / 1KB), `
    ((Get-Item (Join-Path $root "Specs-$Region.lua")).Length / 1KB)
