# Tag ArenaPlus and push, which is what makes CurseForge build a new file.
#
# The sibling of Publish-Data.ps1, and deliberately not the same shape. That one
# owns everything it touches: the passes generate the files, so it copies, stages
# whatever changed and commits without asking. Nothing it overwrites was written
# by a person.
#
# This one publishes hand-written code, so it commits nothing of yours. A dirty
# working tree stops it. The commit message on a release of real changes is worth
# writing, and a button cannot write one -- so the rule is commit first, publish
# second, and the only commit this makes is the one-line version bump.
#
# What it does do is the part that is mechanical and easy to get wrong: put the
# version in the .toc so the AddOns list agrees with the tag, tag it, and push
# both. CurseForge builds from the tag on its own; nothing here talks to it and
# no API key is involved.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File "<path>\Publish-Addon.ps1" -Version 1.0b
#   ... -WhatIf     to see what it would do and push nothing

param(
    [string]$Repo    = "G:\My Drive\Dev\Atlas\ArenaPlus",
    [string]$Toc     = "ArenaPlus.toc",
    [Parameter(Mandatory = $true)]
    [string]$Version,
    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"

# Same reasoning as the data publisher: run from a button or a hidden task there
# is no console, so a failure would look exactly like a success. The log is the
# only record.
$logFile = Join-Path $PSScriptRoot "Publish-Addon.log"

function Say($text) {
    Write-Host $text
    Add-Content -Path $logFile -Value ("{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $text) -Encoding utf8
}

trap {
    Say ("FAILED: " + $_.Exception.Message)
    if ($_.InvocationInfo) { Say ("  " + $_.InvocationInfo.PositionMessage.Trim()) }
    break
}

Say "--- run starting ---"

# The shape the tags use: 1.0b, 1.13c, 1.10a. Checked here rather than trusted
# from the caller, because a tag is the one thing that cannot be taken back
# quietly once CurseForge has built from it.
if ($Version -notmatch '^\d+\.\d+[a-z]$') {
    throw "'$Version' is not a version of the form 1.0b."
}

if (-not (Test-Path $Repo)) { throw "No repository at $Repo" }
if (-not (Test-Path (Join-Path $Repo ".git"))) { throw "$Repo is not a git repository." }

$tocPath = Join-Path $Repo $Toc
if (-not (Test-Path $tocPath)) { throw "No $Toc in $Repo" }

Push-Location $Repo
try {
    # Nothing of yours gets committed, so anything uncommitted means the tag
    # would name a commit that is not what you are looking at.
    $dirty = git status --porcelain
    if ($dirty) {
        Say "Uncommitted changes:"
        $dirty -split "`n" | Where-Object { $_ } | ForEach-Object { Say ("   " + $_) }
        throw "Commit or stash these first -- a release should tag a commit you meant to make."
    }

    if (git tag --list $Version) {
        throw "Tag $Version already exists. Pick the next one."
    }

    # The .toc's version is what the game shows in the AddOns list, so it should
    # say the same thing as the tag.
    $toc = Get-Content $tocPath -Raw
    if ($toc -notmatch '(?m)^## Version:') { throw "No '## Version:' line in $Toc" }
    $toc = [regex]::Replace($toc, '(?m)^## Version:.*$', "## Version: $Version")

    if ($WhatIf) {
        Say "Would set $Toc to $Version, commit, tag and push. Nothing done (-WhatIf)."
        return
    }

    # -NoNewline, and the encoding kept, so the only line that changes is the
    # version one. Rewriting the whole file's endings would put the entire .toc
    # in the diff of every release.
    Set-Content -Path $tocPath -Value $toc -Encoding utf8 -NoNewline

    git add -- $Toc
    git commit -q -m "Version $Version"
    git tag $Version
    git push -q origin HEAD --tags

    Say ""
    Say "Published $Version. CurseForge builds from the tag on its own."
} finally {
    Pop-Location
}
