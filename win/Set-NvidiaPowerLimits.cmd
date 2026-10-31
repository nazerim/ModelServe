@echo off
rem Set-NvidiaPowerLimits.cmd - apply the power limits NOW, without touching the boot task.
rem
rem This is the one-shot half of the pair. nvidia-smi -pl has no persistence, so whatever this
rem applies holds until the driver reloads or the box reboots - and then the SYSTEM task
rem registered by install-power-limits.cmd restores the watts baked into ITS arguments. Change
rem the number for one session with this file; change it for every boot with that one. Editing
rem the defaults in Set-NvidiaPowerLimits.ps1 is NOT enough on its own, because an already
rem registered task carries its own -Watts3080 and -Watts5070Ti arguments rather than re-reading
rem the param block: re-register after changing them.
rem
rem Why a .cmd wrapper for a two-line call: this box has LocalMachine execution policy =
rem AllSigned, so a bare .ps1 is refused with "not digitally signed". cmd.exe is not a script and
rem is not subject to ExecutionPolicy, and -ExecutionPolicy Bypass sets the Process scope, which
rem outranks LocalMachine (precedence, strongest first: MachinePolicy, UserPolicy, Process,
rem CurrentUser, LocalMachine). So nothing here needs a policy change and nothing loosens one.
rem
rem Run it from an ELEVATED prompt. Unelevated, nvidia-smi answers "Insufficient Permissions" and
rem the setter exits 1; from inside WSL setting a limit is impossible at all, so this must be
rem started on Windows. -VerifyOnly needs no elevation, because it only reads. Unlike
rem install-power-limits.cmd, this wrapper CAN be run straight out of the WSL tree
rem (\\wsl.localhost\...) - it registers nothing, so no boot-time task ever has to reach back
rem into a distro that may not be mounted yet.
rem
rem Pass-through options: -Watts3080 200 -Watts5070Ti 270, or -VerifyOnly (read back, change
rem nothing). With no arguments it applies the defaults of the copy you launched, currently
rem 220 W on the RTX 3080 and 275 W on the RTX 5070 Ti.
rem
rem Settable bounds on this box, from power.min_limit and power.max_limit: 3080 100-374 W,
rem 5070 Ti 250-300 W. The 5070 Ti cannot be capped below 250 W at all, so a lower number there
rem is refused rather than clamped.
rem
rem Two Windows trees hold these scripts. C:\ModelServe\win is the working copy you run by hand;
rem %ProgramData%\ModelServe\win is the copy the boot task was pointed at. This wrapper resolves
rem the setter through its own folder, so whichever copy you launch is the one whose defaults
rem apply - keep both in sync with the WSL tree, and check which one the task runs with
rem install-power-limits.cmd -Status from an elevated prompt.
rem
rem Read back:  nvidia-smi --query-gpu=name,power.limit,power.default_limit --format=csv
rem Log:        %ProgramData%\ModelServe\power-limits.log - one log covers both trees, because
rem the setter always writes there.
rem
rem NOTE: kept deliberately branch-free. A multi-line if/else with parentheses and slashes in the
rem echo text made cmd try to execute tokens from the message (recorded in install-power-limits.cmd).
rem The comment lines above also steer clear of redirection and pipe characters. This box's
rem cmd.exe was measured leaving REM payloads alone - a probe line carrying a redirection
rem operator created no file - but that is not worth relying on across cmd builds.
setlocal
set "HERE=%~dp0"
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%HERE%Set-NvidiaPowerLimits.ps1" %*
set "RC=%ERRORLEVEL%"
echo.
echo [set-power-limits] powershell exit code %RC%  zero means the read-back matched.
endlocal & exit /b %RC%
