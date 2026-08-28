# Push the freshly generated data and tag it, which is what makes CurseForge
# build a new file.
#
# The passes write into the live AddOns folder, because that is where the game
# reads them from. This copies that output into the ArenaPlus_Data repository,
# commits it, and tags it -- and a tag appearing is the whole trigger. CurseForge
# builds the moment it sees one; nothing here talks to CurseForge and no API key
# is involved.
#
# Deliberately not modelled on socialplus's release workflow. That one exists to
# attach readable notes to a tag before CurseForge reads it, because its
# changelog is worth reading. This addon's changelog would say "the ladder
# moved" every time, so there is nothing to attach and no reason for the
# machinery.
#
# Does nothing when the data has not changed: an empty commit would still be a
# tag, and a tag is a CurseForge build and a download for everybody who has the
# addon.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File "<path>\Publish-Data.ps1"
#   ... -WhatIf     to see what it would do and push nothing

param(
    [string]$Repo = "G:\My Drive\Dev\Atlas\ArenaPlus_Data",
    [string]$Live = "C:\Program Files (x86)\World of Warcraft\_classic_\Interface\AddOns\ArenaPlus_Data",
    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"

# The scheduled run goes through RunHidden.vbs, which creates no console at all
# -- so everything written to the host goes nowhere, and a failure looks exactly
# like a success. The task reports wscript's exit code, which is 0 whatever
# PowerShell did inside it.
#
# That is how four hours of publishes were lost in silence: the data passes kept
# writing into the live folder, this never copied any of it, and nothing said
# so. Same convention as the update passes -- a log beside the script.
$logFile = Join-Path $PSScriptRoot "Publish-Data.log"

function Say($text) {
    Write-Host $text
    Add-Content -Path $logFile -Value ("{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $text) -Encoding utf8
}

# Logs the throw before it dies, which is the whole point. Without this the
# guards below fail into nothing.
trap {
    Say ("FAILED: " + $_.Exception.Message)
    if ($_.InvocationInfo) { Say ("  " + $_.InvocationInfo.PositionMessage.Trim()) }
    break
}

Say "--- run starting ---"

if (-not (Test-Path $Repo))  { throw "No repository at $Repo" }
if (-not (Test-Path $Live))  { throw "No generated data at $Live" }
if (-not (Test-Path (Join-Path $Repo ".git"))) {
    throw "$Repo is not a git repository yet -- see the README in _brain for the two account-level steps."
}

# ---------------------------------------------------------------- copy
#
# Only the .lua tables. The .toc, .pkgmeta and README belong to the repository
# and are not regenerated -- copying the live folder wholesale would drag the
# packaged copy of them back over the source.
$copied = 0
foreach ($file in (Get-ChildItem -Path $Live -Filter *.lua -File)) {
    $target = Join-Path $Repo $file.Name
    $same = (Test-Path $target) -and
            ((Get-FileHash $file.FullName -Algorithm MD5).Hash -eq (Get-FileHash $target -Algorithm MD5).Hash)
    if (-not $same) {
        if (-not $WhatIf) { Copy-Item $file.FullName $target -Force }
        $copied++
    }
}

Push-Location $Repo
try {
    # Anything actually different, including a file the copy above skipped
    # because it was already in place but never committed.
    # -WhatIf deliberately copies nothing, so git has nothing to notice. Asking
    # git anyway is how -WhatIf came to answer "unchanged" however much had
    # actually changed -- which makes the one switch meant for checking this
    # script the one thing that cannot. The copy pass above is what knows.
    $dirty = git status --porcelain
    $changed = if ($WhatIf) { ($copied -gt 0) -or $dirty } else { $dirty }

    if (-not $changed) {
        Say "Data unchanged -- nothing to publish."
        return
    }

    if ($WhatIf) {
        Say "$copied file(s) would be refreshed."
    } else {
        Say "$copied file(s) refreshed:"
        $dirty -split "`n" | Where-Object { $_ } | ForEach-Object { Say "   $_" }
    }

    # Sortable, unique, and readable as a timestamp at a glance. A data release
    # has no semantic version to bump -- there are no features in it.
    $version = (Get-Date).ToString("yyyy.MM.dd.HHmm")

    # The TOC's version is what the game shows in the AddOns list, so it should
    # say the same thing as the tag.
    $tocPath = Join-Path $Repo "ArenaPlus_Data.toc"
    $toc = Get-Content $tocPath -Raw
    $toc = [regex]::Replace($toc, '(?m)^## Version:.*$', "## Version: $version")
    if (-not $WhatIf) { Set-Content -Path $tocPath -Value $toc -Encoding utf8 -NoNewline }

    if ($WhatIf) {
        Say ""
        Say "Would commit and tag $version, then push. Nothing done (-WhatIf)."
        return
    }

    git add -A
    git commit -q -m "Data $version"
    git tag $version
    git push -q origin HEAD --tags

    Say ""
    Say "Published $version. CurseForge builds from the tag on its own."

    # Keep the newest few tags and let the rest go.
    #
    # A tag here names a snapshot of a file that is rewritten every quarter of
    # an hour, so its worth decays fast: the newest is the only one anybody
    # would ever check out, and a year of them is thousands of refs standing
    # for nothing. Deleting a tag does not touch the commit it pointed at --
    # the history stays whole, only the names go.
    #
    # Matched on the timestamp shape rather than "every tag", so a hand-made
    # tag of any other form is left alone.
    #
    # In its own try: the publish above has already succeeded and been pushed,
    # and failing to tidy up afterwards is not a reason to report that as a
    # failure.
    try {
        $keep = 10
        $mine = @(git tag --list |
            Where-Object { $_ -match '^\d{4}\.\d{2}\.\d{2}\.\d{4}$' } |
            Sort-Object -Descending)

        if ($mine.Count -gt $keep) {
            $drop = @($mine | Select-Object -Skip $keep)

            # One push carrying every deletion, rather than one push each.
            $refs = $drop | ForEach-Object { ":refs/tags/$_" }
            git push -q origin @refs
            foreach ($tag in $drop) { git tag -d $tag | Out-Null }

            Say ("Pruned {0} old tag(s); the newest {1} remain." -f $drop.Count, $keep)
        }
    } catch {
        Say ("Could not prune old tags: " + $_.Exception.Message)
    }
} finally {
    Pop-Location
}
