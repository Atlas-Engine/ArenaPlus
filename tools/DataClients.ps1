# The generated data belongs in every installed client, not just the one the
# scripts happen to live in.
#
# The update passes write beside themselves: $PSScriptRoot sits inside one
# client's AddOns folder, and $data is worked out from it. While there was one
# client that was the same thing as "the data folder". Anniversary made it two,
# and the passes went on feeding whichever one they were installed in -- so the
# Mists client refreshed every fifteen minutes while Anniversary sat on whatever
# CurseForge last published, an hour or more behind, with nothing anywhere
# saying so. It looked like the scheduled tasks were broken; they were writing
# to one address the whole time.
#
# Found from the folder layout rather than from a list of clients, so a third
# install is something you install rather than something you edit in here.
#
# Only the files a pass actually wrote, never the folder. Live is permanently
# ahead of Dev on generated data and the two clients hold different halves of it
# at different moments -- a folder copy would roll one of them back, which is
# the same rule CLAUDE.md states for Dev and live.

# Write a shipped table so no reader can ever see half of it.
#
# Set-Content truncates the file and then writes it, which leaves a window --
# tens of milliseconds for a 2 MB leaderboard -- where the file on disk is
# empty or half a table. Two things read these files while the passes run:
# the game client, and Publish-Data.ps1 on its own 30-minute timer. A game
# that loads a truncated table throws; a publish that copies one ships it to
# everybody.
#
# A temp file in the same folder, then a move. A move within one volume is a
# rename: the directory entry is repointed in one step, so a reader either
# gets all of the old file or all of the new one and never a mixture.
#
# Same folder deliberately -- a temp in %TEMP% would be a different volume,
# and a cross-volume move is a copy plus a delete, which is the very thing
# this exists to avoid.
function Write-DataFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value
    )

    $temp = $Path + ".tmp"
    Set-Content -Path $temp -Value $Value -Encoding utf8
    Move-Item -Path $temp -Destination $Path -Force
}

function Copy-ToOtherClients {
    param(
        [Parameter(Mandatory = $true)][string]$Primary,
        [Parameter(Mandatory = $true)][string[]]$Files,
        [scriptblock]$Say
    )

    if (-not $Primary) { return }

    # ...\<client>\Interface\AddOns\ArenaPlus_Data  ->  ...\World of Warcraft
    $addons = Split-Path $Primary -Parent
    $interface = Split-Path $addons -Parent
    $client = Split-Path $interface -Parent
    $wow = Split-Path $client -Parent
    if (-not $wow -or -not (Test-Path $wow)) { return }

    $primaryKey = $Primary.TrimEnd('\')

    foreach ($dir in (Get-ChildItem -Path $wow -Directory -ErrorAction SilentlyContinue)) {
        $other = Join-Path $dir.FullName "Interface\AddOns\ArenaPlus_Data"
        if (-not (Test-Path $other)) { continue }
        if ($other.TrimEnd('\') -ieq $primaryKey) { continue }

        $copied = 0
        foreach ($file in $Files) {
            if (-not $file -or -not (Test-Path $file)) { continue }

            # Never fatal. A client mid-update, a file open in an editor or a
            # scanner holding a handle is a reason to skip one copy, not a
            # reason to fail a pass that has already done its real work.
            try {
                Copy-Item -Path $file -Destination $other -Force -ErrorAction Stop
                $copied++
            } catch {
                if ($Say) {
                    & $Say ("  could not copy {0} to {1}: {2}" -f (Split-Path $file -Leaf), $dir.Name, $_.Exception.Message)
                }
            }
        }

        if ($copied -gt 0 -and $Say) {
            & $Say ("  copied {0} file(s) to {1}" -f $copied, $dir.Name)
        }
    }
}
