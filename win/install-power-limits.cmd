@echo off
rem install-power-limits.cmd - one-shot, policy-proof entry point.
rem
rem Why this exists: this machine has LocalMachine execution policy = AllSigned, so
rem ".\Register-NvidiaPowerTask.ps1" is refused with "not digitally signed". cmd.exe is not a
rem script and is not subject to ExecutionPolicy, and -ExecutionPolicy Bypass sets the Process
rem scope, which outranks LocalMachine (precedence: MachinePolicy > UserPolicy > Process >
rem CurrentUser > LocalMachine). So this wrapper needs no policy change and loosens nothing.
rem The scheduled task it registers also passes -ExecutionPolicy Bypass, so AllSigned does not
rem break the per-boot re-apply either.
rem
rem Run from an ELEVATED prompt (creating a SYSTEM task requires admin). Copy this whole
rem folder to a local disk first - cmd.exe cannot run with a UNC/WSL working directory:
rem     C:\ProgramData\ModelServe\win\install-power-limits.cmd
rem Pass-through options: -Watts3080 170 -Watts5070Ti 260   |   -Status   |   -Remove
rem
rem NOTE: kept deliberately branch-free. A multi-line if/else with parentheses and slashes in
rem the echo text made cmd try to execute tokens from the message.
setlocal
set "HERE=%~dp0"
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%HERE%Register-NvidiaPowerTask.ps1" %*
set "RC=%ERRORLEVEL%"
echo.
echo [install-power-limits] powershell exit code %RC%
endlocal & exit /b %RC%
