@echo off
rem stop.cmd - policy-proof entry point for stopping the native server. See start.cmd for why a
rem .cmd wrapper is needed at all (LocalMachine = AllSigned; a bare .\stop.ps1 is refused).
rem
rem   C:\ModelServe\win\stop.cmd              stop the tree, then SHOW the VRAM coming back
rem   C:\ModelServe\win\stop.cmd -VerifyOnly  report what holds GPU memory, change nothing
setlocal
cd /d C:\
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0stop.ps1" %*
set "RC=%ERRORLEVEL%"
endlocal & exit /b %RC%
