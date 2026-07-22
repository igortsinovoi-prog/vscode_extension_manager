# Watches for trigger files and launches/kills VS Code accordingly.
#
# Meant to run inside a REAL interactive Windows session - started
# manually from the VM's own console (e.g. its UTM window), NOT over SSH.
# SSH sessions land in the non-interactive Session 0, where Electron apps
# like VS Code can start a process but never actually render a window or
# run their full background services (extension host, background
# extension-update checks, etc.) - confirmed by launching Code.exe over
# SSH and finding it left behind only a stub cli.log, no main/renderer/
# exthost logs, before silently disappearing. This script is how
# real_world_check_set_vscode_extension_version.sh's scenario 15 gets a
# real, rendering VS Code session to observe despite driving everything
# else here over SSH: leave this running in the real session once, then
# trigger it remotely by creating a file.
#
# Usage - run this from a PowerShell window opened directly in the VM's
# own console (not over SSH), and leave it running:
#   .\watch_and_launch_vscode.ps1
#
# From another session (e.g. over SSH), make it launch or kill VS Code,
# or trigger its "Check for Extension Updates" command in an already-
# running window (the same update-check-and-install code path the
# passive startup sync uses, invoked on demand - lets scenario 15 test
# this without quitting/relaunching a session that might be in active
# use):
#   New-Item -ItemType File -Path "$env:USERPROFILE\vscode_launch_trigger" -Force
#   New-Item -ItemType File -Path "$env:USERPROFILE\vscode_kill_trigger" -Force
#   New-Item -ItemType File -Path "$env:USERPROFILE\vscode_checkupdates_trigger" -Force
#
# Self-cleaning: each trigger file is deleted immediately after being
# acted on, so it can be triggered again later without manual cleanup.
# Ctrl+C to stop.
param(
  [string]$LaunchTriggerFile = "$env:USERPROFILE\vscode_launch_trigger",
  [string]$KillTriggerFile = "$env:USERPROFILE\vscode_kill_trigger",
  [string]$CheckUpdatesTriggerFile = "$env:USERPROFILE\vscode_checkupdates_trigger",
  [string]$CodeExePath = "$env:LOCALAPPDATA\Programs\Microsoft VS Code\Code.exe"
)

if (-not (Test-Path $CodeExePath)) {
  Write-Output "Error: Code.exe not found at $CodeExePath"
  exit 1
}

Add-Type -AssemblyName Microsoft.VisualBasic
Add-Type -AssemblyName System.Windows.Forms

Write-Output "Watching for:"
Write-Output "  launch        -> $LaunchTriggerFile"
Write-Output "  kill          -> $KillTriggerFile"
Write-Output "  check-updates -> $CheckUpdatesTriggerFile"
Write-Output "This window must stay open, running inside a real interactive session. Ctrl+C to stop."

while ($true) {
  if (Test-Path $LaunchTriggerFile) {
    Write-Output "[$(Get-Date -Format o)] Launch trigger detected - launching VS Code..."
    Remove-Item -Path $LaunchTriggerFile -Force -ErrorAction SilentlyContinue
    Start-Process -FilePath $CodeExePath
  }
  if (Test-Path $KillTriggerFile) {
    Write-Output "[$(Get-Date -Format o)] Kill trigger detected - stopping VS Code..."
    Remove-Item -Path $KillTriggerFile -Force -ErrorAction SilentlyContinue
    Stop-Process -Name Code -Force -ErrorAction SilentlyContinue
  }
  if (Test-Path $CheckUpdatesTriggerFile) {
    Write-Output "[$(Get-Date -Format o)] Check-updates trigger detected - driving the Command Palette..."
    Remove-Item -Path $CheckUpdatesTriggerFile -Force -ErrorAction SilentlyContinue
    [Microsoft.VisualBasic.Interaction]::AppActivate("Visual Studio Code")
    Start-Sleep -Milliseconds 500
    [System.Windows.Forms.SendKeys]::SendWait("^+p")
    Start-Sleep -Milliseconds 500
    [System.Windows.Forms.SendKeys]::SendWait("Check for Extension Updates")
    Start-Sleep -Milliseconds 500
    [System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
  }
  Start-Sleep -Seconds 1
}
