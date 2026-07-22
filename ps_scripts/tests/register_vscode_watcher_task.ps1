# Registers watch_and_launch_vscode.ps1 as a Scheduled Task that starts
# automatically whenever the target user logs on (including at every
# future boot) - configured with LogonType Interactive so it actually
# runs INSIDE that user's real interactive session, not the non-interactive
# Session 0 a script started this way would otherwise land in (see
# watch_and_launch_vscode.ps1's header for why that distinction matters -
# it's the same Session 0 vs. real-desktop problem this whole task exists
# to work around).
#
# Run this once, as Administrator (SSH is fine for running THIS script -
# it's only the task it registers that needs to run interactively, not
# this registration step itself):
#   .\register_vscode_watcher_task.ps1
#
# Also starts the task immediately, since the target user may already be
# logged in (an AtLogOn trigger alone wouldn't fire again until their next
# login).
param(
  [string]$TaskName = "WatchAndLaunchVSCode",
  [string]$TargetUser = $env:USERNAME,
  [string]$ScriptPath = "$env:USERPROFILE\watch_and_launch_vscode.ps1"
)

if (-not (Test-Path $ScriptPath)) {
  Write-Output "Error: $ScriptPath not found - copy watch_and_launch_vscode.ps1 there first."
  exit 1
}

$action = New-ScheduledTaskAction -Execute "powershell.exe" `
  -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $TargetUser
$principal = New-ScheduledTaskPrincipal -UserId $TargetUser -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
  -Description "Watches for a trigger file and launches/kills VS Code in a real interactive session, for real_world_check_set_vscode_extension_version.sh scenario 15." | Out-Null

Write-Output "Registered scheduled task '$TaskName' (runs at logon for $TargetUser, interactive)."

Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 2
Write-Output "Task state: $((Get-ScheduledTask -TaskName $TaskName).State)"
