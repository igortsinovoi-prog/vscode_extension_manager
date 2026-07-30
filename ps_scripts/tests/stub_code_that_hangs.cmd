@echo off
REM Stand-in for a hung code.cmd invocation - scenario 18's own
REM reproduction (repro_timeout_kill.ps1) points Invoke-VSCodeNativeCommand
REM at this instead of the real code.cmd, so the test exercises the exact
REM same .cmd-detection/cmd.exe-wrapping code path a real invocation uses
REM (see that function's own \.(cmd|bat)$ check), without touching the
REM real VS Code install at all.
powershell -NoProfile -Command "Start-Sleep -Seconds 30"
