@echo off
REM Builds ArenaPlusDashboard.exe from ArenaPlusDashboard.cs.
REM
REM Uses the C# compiler that ships with the .NET Framework, which is on every
REM Windows machine -- nothing to install, nothing downloaded. Run this after
REM editing the .cs; the .exe is what you double click.
REM
REM The icon is the gladiator helmet the minimap button wears, so the taskbar
REM and the minimap agree about what this is. It is committed as a file rather
REM than fetched, because the game keeps its art inside CASC archives where a
REM build cannot reach it -- and because a build that downloads something is a
REM build that fails when the site does.

set CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe
if not exist "%CSC%" set CSC=%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe

"%CSC%" /nologo /target:winexe /optimize+ /win32icon:"%~dp0ArenaPlusDashboard.ico" /out:"%~dp0ArenaPlusDashboard.exe" ^
  /r:System.dll /r:System.Core.dll /r:System.Drawing.dll /r:System.Windows.Forms.dll /r:Microsoft.CSharp.dll ^
  "%~dp0ArenaPlusDashboard.cs"

if errorlevel 1 ( echo BUILD FAILED & pause ) else ( echo Built ArenaPlusDashboard.exe )
