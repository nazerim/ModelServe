@echo off
rem start.cmd - policy-proof entry point for starting the native server detached.
rem
rem LocalMachine execution policy on this box is AllSigned, so a bare ".\start.ps1" is refused
rem with "is not digitally signed". cmd.exe is not a script and is not subject to ExecutionPolicy,
rem and -ExecutionPolicy Bypass sets the Process scope, which outranks LocalMachine (precedence:
rem MachinePolicy > UserPolicy > Process > CurrentUser > LocalMachine). No policy is changed and
rem nothing is loosened beyond this one process. Full reasoning: install-windows.cmd.
rem
rem   C:\ModelServe\win\start.cmd                        (q3, the default profile)
rem   C:\ModelServe\win\start.cmd -Tier large          (163,840 ctx, most headroom)
rem   C:\ModelServe\win\start.cmd -P q4 -Tier medium
rem   C:\ModelServe\win\start.cmd -Bind lan              (LAN adapter's IPv4; key + firewall rule)
rem   C:\ModelServe\win\start.cmd -Bind all              (0.0.0.0: LAN + WSL + local; key + rule)
rem   C:\ModelServe\win\start.cmd -WhatIf                (print the resolved command, launch nothing)
setlocal
cd /d C:\
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0start.ps1" %*
set "RC=%ERRORLEVEL%"
endlocal & exit /b %RC%
