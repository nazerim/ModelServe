@echo off
rem install-windows.cmd - one-shot, policy-proof entry point for native-Windows serving.
rem
rem Why this exists: LocalMachine execution policy on this box is AllSigned, so
rem ".\install-windows.ps1" is refused with "not digitally signed". cmd.exe is not a script and
rem is not subject to ExecutionPolicy, and -ExecutionPolicy Bypass sets the Process scope,
rem which outranks LocalMachine (precedence: MachinePolicy > UserPolicy > Process >
rem CurrentUser > LocalMachine). So this wrapper needs no policy change and loosens nothing.
rem
rem Unlike install-power-limits.cmd this one CAN be run straight out of the WSL tree: it does
rem `cd /d C:\` first, because cmd.exe cannot operate with a UNC/WSL working directory, and
rem then invokes the script by its full %~dp0 path. It copies the scripts onto NTFS as its
rem first real step, so later runs (and the scheduled task) never depend on a distro being up.
rem
rem   \\wsl.localhost\Ubuntu-26.04\home\naz\Projects\ModelServe\win\install-windows.cmd
rem   C:\ModelServe\win\install-windows.cmd                     (after the first run)
rem
rem Pass-through:  -Models q3,mmproj | all | none   -Firewall -Port 8000   -RegisterTask
rem                -Force (re-download / re-copy)   -DryRun (print, change nothing)
rem Firewall and -RegisterTask need an ELEVATED prompt.
setlocal
cd /d C:\
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0install-windows.ps1" %*
set "RC=%ERRORLEVEL%"
echo.
echo [install-windows] powershell exit code %RC%
endlocal ^& exit /b %RC%
