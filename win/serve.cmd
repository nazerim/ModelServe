@echo off
rem serve.cmd - policy-proof entry point for a FOREGROUND server (its own console, Ctrl-C stops
rem it). Prefer start.cmd for normal use; this is for watching the load trace live. See start.cmd
rem for why a .cmd wrapper is needed at all (LocalMachine = AllSigned).
rem
rem   C:\ModelServe\win\serve.cmd -DryRun                    print the resolved command, run nothing
rem   C:\ModelServe\win\serve.cmd -P q3l -Bind loopback      Windows-only, no key needed
rem   C:\ModelServe\win\serve.cmd -P q4s -Ctx 98304          (a Tier, or an explicit -Ctx)
setlocal
cd /d C:\
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0serve.ps1" %*
set "RC=%ERRORLEVEL%"
endlocal & exit /b %RC%
