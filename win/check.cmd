@echo off
rem check.cmd - policy-proof entry point for the read-only preflight. See start.cmd for why a .cmd
rem wrapper is needed at all (LocalMachine = AllSigned; a bare .\check.ps1 is refused).
rem
rem Run this after every reboot and before any benchmark day: device order, power caps, TDR,
rem sleep state, RAM/commit, model files, the WSL network path, key scope, and what is listening.
rem
rem   C:\ModelServe\win\check.cmd              (default port 8000)
rem   C:\ModelServe\win\check.cmd -Port 9000
setlocal
cd /d C:\
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0check.ps1" %*
set "RC=%ERRORLEVEL%"
endlocal & exit /b %RC%
