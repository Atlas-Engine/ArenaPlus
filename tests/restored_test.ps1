# A character deleted and restored, as UpdateFromBlizzard.ps1 sees it.
#
#   powershell -NoProfile -File tests\restored_test.ps1
#
# Exits 1 on the first failure. Only the helpers in tools\DataClients.ps1;
# nothing is fetched or written.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot "..\tools\DataClients.ps1")

$failed = 0
function Check($what, $ok) {
    if ($ok) { Write-Host "ok   $what" } else { Write-Host "FAIL $what"; $script:failed++ }
}

function Entry($name, $realm, $id, $won, $lost) {
    [pscustomobject]@{
        character = [pscustomobject]@{ name = $name; id = $id; realm = [pscustomobject]@{ slug = $realm } }
        season_match_statistics = [pscustomobject]@{ won = $won; lost = $lost }
    }
}

# Havitýx, Shek'zeer 2v2 on 2026-10-24: the board under the new id, the cache
# frozen from before the delete.
$board = Entry "Havitýx" "shekzeer" 101803930 26 5

Check "different ids are a restore" (Test-Restored @{ Won = 24; Lost = 22; Id = 99 } $board)
Check "a restore with fewer wins and fewer losses is caught by the id" (Test-Restored @{ Won = 40; Lost = 30; Id = 99 } $board)
Check "the same id is not, whatever the games" (-not (Test-Restored @{ Won = 40; Lost = 30; Id = 101803930 } $board))
Check "no id kept: ahead on one count and behind on the other is" (Test-Restored @{ Won = 24; Lost = 22; Id = 0 } $board)
Check "no id kept: behind on both is a board that lags, not a restore" (-not (Test-Restored @{ Won = 30; Lost = 9; Id = 0 } $board))
Check "no id kept: ahead on both is not either" (-not (Test-Restored @{ Won = 20; Lost = 4; Id = 0 } $board))

$rows = @(
    (Entry "Havitýx" "shekzeer" 7000 24 22),
    (Entry "Other" "shekzeer" 5 1 1),
    (Entry "Havitýx" "shekzeer" 101803930 26 5),
    (Entry "Havitýx" "mirage-raceway" 102385777 50 33)
)
$kept = @(Select-NewestCharacters $rows)
Check "one row a name and realm" ($kept.Count -eq 3)
Check "the higher id is kept" (@($kept | Where-Object { $_.character.realm.slug -eq "shekzeer" -and $_.character.name -eq "Havitýx" })[0].character.id -eq 101803930)
Check "the same name on another realm is another character" (@($kept | Where-Object { $_.character.realm.slug -eq "mirage-raceway" }).Count -eq 1)
Check "order is kept" ($kept[0].character.name -eq "Other")
Check "the dropped are counted" ($script:twice -eq 1)

$plain = @((Entry "A" "x" 1 1 1), (Entry "B" "x" 2 1 1))
Check "a board with no twice is returned as it is" (@(Select-NewestCharacters $plain).Count -eq 2 -and $script:twice -eq 0)

if ($failed) { exit 1 }
Write-Host "all passed"
