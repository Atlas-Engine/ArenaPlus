' Launches one of the update scripts with no window at all.
'
' Which one is given as the first argument -- RunHidden.vbs UpdateLeaderboard.ps1
' -- and with no argument it runs the cutoffs script, so the task action that
' predates this keeps working untouched.
'
' powershell.exe -WindowStyle Hidden still creates a console host for an
' instant before hiding it, which is the flash you see over a fullscreen game.
' wscript creates no console in the first place, so there is nothing to flash.
'
' The scheduled task points at this file rather than at powershell.exe.

Option Explicit

Dim fso, shell, here, script, command

Set fso   = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")

' Alongside this file, wherever the addon happens to be installed.
here = fso.GetParentFolderName(WScript.ScriptFullName)

Dim extra, i

If WScript.Arguments.Count > 0 Then
	script = here & "\" & WScript.Arguments(0)
Else
	script = here & "\UpdateCutoffs.ps1"
End If

' Anything after the script name is passed straight through, so a region can be
' named: RunHidden.vbs UpdateCutoffs.ps1 -Region eu
extra = ""
For i = 1 To WScript.Arguments.Count - 1
	extra = extra & " " & WScript.Arguments(i)
Next

command = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File """ & script & """" & extra

' 0 = no window, True = wait for it to finish.
'
' Waiting matters for two reasons. The task runs several of these in a row, and
' without waiting they all start at once: four scripts hitting the site together
' makes the one-second delay inside each of them meaningless. And the leaderboard
' script reads its depth from Cutoffs-<region>.lua, so started alongside the
' cutoffs script it reads the previous run's numbers instead of this run's.
shell.Run command, 0, True
