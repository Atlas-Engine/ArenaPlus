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

    # Never fatal, which it was.
    #
    # ErrorActionPreference is Stop and the trap below turns any throw into an
    # abandoned run, so something else holding this file for a moment -- the
    # dashboard reading it, a scanner, the previous run's handle -- took the
    # whole publish down with it. It cost the 07:05 publish on 09-03 and again
    # on 09-05, and each one left players two hours behind instead of one. A
    # line of text is not worth a missed publish, so it is tried a few times and
    # then given up on.
    $line = "{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $text
    for ($try = 1; $try -le 5; $try++) {
        try {
            Add-Content -Path $logFile -Value $line -Encoding utf8 -ErrorAction Stop
            return
        } catch {
            Start-Sleep -Milliseconds 200
        }
    }
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

# ---------------------------------------------------------------- in flight
#
# Not while a pass is writing.
#
# This runs on its own 30-minute task and the update passes run on theirs,
# so nothing has ever stopped the two landing in the same second. What this
# publishes is whatever is in the live folder at the moment it looks, and a
# pass rewrites a whole table -- so the file it copies can be the previous
# ladder, or the new one, or the join between them.
#
# The passes have taken turns among themselves since 2026-08-23 through
# ArenaPlus-fetch.lock. This was never taught about it, which left the one
# reader that publishes to CurseForge as the only thing in the system still
# racing the writers.
#
# Writes are atomic now as well -- see Write-DataFile in DataClients.ps1 --
# so a single file can no longer be caught half-written. This covers the
# other half of it: the four tables are written minutes apart, and a copy
# taken between them ships a leaderboard whose specs and gear belong to the
# run before. Both are needed; neither alone is enough.
#
# Declines rather than waits. A pass can run for fourteen minutes, holding
# this task open that long would overlap its own next run, and there is
# nothing to gain by waiting: the data is published on the next tick, half
# an hour later at worst, and the tick after a pass is exactly when there is
# something new to publish.
$lockFile = Join-Path $PSScriptRoot "ArenaPlus-fetch.lock"

# The owner id, the same way the passes read each other: a lock whose
# process is gone is a leftover from a run that died, and treating it as
# live would stop publishing for ever. The passes clear those; this only
# needs to not be fooled by one.
if (Test-Path $lockFile) {
    $owner = 0
    try { $owner = [int](Get-Content $lockFile -TotalCount 1 -ErrorAction Stop) } catch { }

    if ($owner -gt 0 -and (Get-Process -Id $owner -ErrorAction SilentlyContinue)) {
        $busy = ""
        try { $busy = (Get-Content $lockFile -TotalCount 2)[1] } catch { }
        if ($busy) { Say ("Waiting: {0} is still fetching (process {1}). Nothing published." -f $busy, $owner) }
        else       { Say ("Waiting: a pass is still fetching (process {0}). Nothing published." -f $owner) }
        return
    }

    # Removed, not just ignored. CreateNew below fails on a file that is
    # still there, so "ignore it" would have meant never publishing again
    # until somebody deleted it by hand -- and the run that leaves one
    # behind is by definition a run that crashed, which is exactly when
    # nobody is watching.
    Say "Clearing a fetch lock left by a run that did not finish."
    try { Remove-Item $lockFile -Force -ErrorAction Stop } catch { }
}

# Held for the copy, so a pass cannot start writing into the middle of it.
#
# CreateNew, not "test then create": two steps with a gap in the middle is
# the bug this is here to prevent. Whoever gets the file wins and the other
# is told.
#
# Only the copy needs it. The git work below reads the repository, which no
# pass touches, so the lock goes back as soon as the files are in place --
# a push can take a while and there is no reason to hold the fetchers off
# through it.
$held = $null
try {
    $held = [System.IO.File]::Open($lockFile, [System.IO.FileMode]::CreateNew,
                                   [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
} catch {
    Say "A pass claimed the fetch lock first. Nothing published."
    return
}

$writer = New-Object System.IO.StreamWriter($held)
$writer.WriteLine($PID)
$writer.WriteLine("publish")
$writer.Flush()

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

# The files are in the repository now; the fetchers can have their turn.
$writer.Dispose()
$held.Dispose()
Remove-Item $lockFile -Force -ErrorAction SilentlyContinue

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

    # Take whatever is on origin before tagging, rather than assuming
    # nothing put it there.
    #
    # This only ever pushed, and for a repository nothing else writes to
    # that held for a year. Then four commits were made through GitHub's
    # web interface on 2026-09-08 -- a workflow file added and removed,
    # twice -- and every run afterwards was a non-fast-forward and was
    # refused. Seventy-two of them, over three days, while the dashboard
    # said FAILED and the log said only "git refused".
    #
    # Merged, not rebased. The tags this script has already made point at
    # local commits; a rebase would move those commits out from under
    # them and leave ten tags naming a lineage on no branch. A merge
    # leaves every one of them valid.
    #
    # After the commit rather than before it: the working tree is full of
    # freshly copied tables at this point, and merging into a dirty tree
    # is refused the moment origin happens to touch the same file.
    #
    # A conflict cannot happen in the ordinary case -- the tables are
    # written by the passes and by nothing else -- so one means a person
    # edited data on GitHub, and choosing between the two versions is
    # their decision, not this script's.
    git fetch -q origin
    if ($LASTEXITCODE -ne 0) { throw "git could not reach origin to fetch." }

    $behind = [int](git rev-list --count "HEAD..origin/main")
    if ($behind -gt 0) {
        Say "origin has $behind commit(s) this copy does not; merging them in first."
        git merge -q --no-edit origin/main
        if ($LASTEXITCODE -ne 0) {
            git merge --abort
            throw "origin and this copy disagree about a file -- merge $Repo by hand."
        }
    }

    git tag $version

    # Which old tags go, worked out before the push rather than after it.
    #
    # A tag here names a snapshot of a file rewritten every quarter of an hour,
    # so its worth decays fast: the newest is the only one anybody would check
    # out, and a year of them is thousands of refs standing for nothing.
    # Deleting a tag does not touch the commit it pointed at -- the history
    # stays whole, only the names go.
    #
    # Matched on the timestamp shape rather than "every tag", so a hand-made tag
    # of any other form is left alone.
    #
    # Read from the REMOTE, not from "git tag --list". The local list is the one
    # this script has been shortening for days, so once the two sides drifted
    # apart every tag left on origin was invisible to the thing meant to remove
    # it. Steady state hid it perfectly: one added per run and one removed kept
    # the local count at ten and the log reading "the newest 10 remain" while 48
    # piled up on GitHub.
    $keep = 10
    $remote = @(git ls-remote --tags origin |
        ForEach-Object { ($_ -split "`t")[-1] } |
        Where-Object { $_ -and $_ -notmatch '\^\{\}$' } |
        ForEach-Object { $_ -replace '^refs/tags/', '' } |
        Where-Object { $_ -match '^\d{4}\.\d{2}\.\d{2}\.\d{4}$' })

    # What origin will hold once this run's tag lands, newest first. The new one
    # is by definition the newest, so it is never in the drop set.
    $after = @(@($remote) + $version | Sort-Object -Descending)
    $drop  = @($after | Select-Object -Skip $keep)
    $refs  = @($drop | ForEach-Object { ":refs/tags/$_" })

    # ONE push, carrying the commit, the new tag and every deletion.
    #
    # This used to be two -- the tag went up, and the prune followed in a second
    # push. Both are push events, and CurseForge packages the newest tag on
    # every push it is told about, so each run published the same tag twice and
    # every user downloaded it twice. It was invisible for as long as no webhook
    # existed, which is exactly how long nobody noticed.
    #
    # Explicit refspecs rather than --tags: this pushes the one tag just made,
    # not whatever else happens to be lying around locally.
    # Captured rather than let go to a console that does not exist.
    #
    # The scheduled run has no console, so git's own account of itself
    # went nowhere and the log recorded that the push was refused without
    # ever recording why. "fetch first" was sitting in that output for
    # three days.
    #
    # ErrorActionPreference is Stop, and in Windows PowerShell redirecting
    # a native program's stderr under Stop turns each line into a
    # terminating NativeCommandError -- a failed push would die here
    # instead of reaching the check below. Relaxed for the one call and
    # put straight back.
    $was = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $said = & git push -q origin HEAD "refs/tags/$version" @refs 2>&1
    $ErrorActionPreference = $was

    # Checked rather than assumed. -q means a failure here says nothing at all,
    # and saying nothing is how the prune bug lasted three days.
    #
    # All of it fails together now, which is the trade for publishing once: a
    # refused deletion takes the release with it instead of leaving a tag up
    # with the tidying undone. Acceptable because the deletions name tags
    # ls-remote confirmed a moment earlier, and nothing else pushes to this
    # repository.
    if ($LASTEXITCODE -ne 0) {
        foreach ($line in $said) {
            $text = "$line".Trim()
            if ($text) { Say "  git: $text" }
        }
        throw ("git refused the push of $version" +
               $(if ($drop.Count) { " and {0} tag deletion(s)" -f $drop.Count } else { "" }) + ".")
    }

    # Locally too, but only where it is still here: a tag origin still had may
    # be long gone from this machine, and "git tag -d" on a name that is not
    # here is an error rather than a no-op.
    $local = @(git tag --list)
    foreach ($tag in $drop) {
        if ($local -contains $tag) { git tag -d $tag | Out-Null }
    }

    Say ""
    Say "Published $version. CurseForge builds from the tag on its own."
    if ($drop.Count) {
        Say ("Pruned {0} old tag(s) from origin in the same push; the newest {1} remain." -f $drop.Count, $keep)
    }
} finally {
    Pop-Location
}
