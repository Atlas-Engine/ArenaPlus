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

function Say($text) { Write-Host $text }

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
    $dirty = git status --porcelain
    if (-not $dirty) {
        Say "Data unchanged -- nothing to publish."
        return
    }

    Say "$copied file(s) refreshed:"
    $dirty -split "`n" | Where-Object { $_ } | ForEach-Object { Say "   $_" }

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
} finally {
    Pop-Location
}
