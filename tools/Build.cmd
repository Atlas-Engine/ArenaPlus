@echo off
REM Builds ArenaPlusDashboard.exe from ArenaPlusDashboard.cs.
REM
REM Uses the C# compiler that ships with the .NET Framework, which is on every
REM Windows machine -- nothing to install, nothing downloaded. Run this after
REM editing the .cs; the .exe is what you double click.

set CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe
if not exist "%CSC%" set CSC=%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe

"%CSC%" /nologo /target:winexe /optimize+ /out:"%~dp0ArenaPlusDashboard.exe" ^
  /r:System.dll /r:System.Core.dll /r:System.Drawing.dll /r:System.Windows.Forms.dll /r:Microsoft.CSharp.dll ^
  "%~dp0ArenaPlusDashboard.cs"

if errorlevel 1 ( echo BUILD FAILED & pause ) else ( echo Built ArenaPlusDashboard.exe )
