# =====================================================================
# Glow Action Script - Set VS Code Extension Version (Windows, PowerShell) -
# runner half.
#
# This file is the OS-interaction glue only: RTR contract (base64 in / JSON
# envelope out), running the `code` CLI against the target user's extensions
# folder, filesystem-level path safety checks, diagnostics. Every actual
# DECISION (is this extension installed, does its version already match,
# what should happen, which user does the given path belong to) lives in
# Set-VSCodeExtensionVersion.Policy.ps1, which this file assumes is already
# dot-sourced into scope - see ps_scripts/build.ps1, which concatenates that
# file first, then this one, into the deployed
# dist/Set-VSCodeExtensionVersion.ps1. Windows/PowerShell port of
# set-vscode-extension-version-runner.js (macOS/JXA) - see that file for the
# original design rationale this mirrors.
#
# Sets an installed VS Code extension to a specific version (upgrading or
# downgrading as needed), or to the latest available version if no version
# is given. Per spec: if the extension is NOT currently installed, this
# script does nothing - it never installs an extension fresh.
#
#   - Not installed                       -> no-op.
#   - Installed, no version given         -> `code --install-extension <id> --force`
#     (no @version resolves and installs latest; `--upgrade-extension` is NOT
#     a real flag on this CLI, same as the macOS side - see
#     Invoke-VSCodeUpgradeToLatest).
#   - Installed, version given, differs   -> `code --install-extension <id>@<version> --force`
#     (this one command handles both upgrade and downgrade - it just forces
#     the exact requested version, whichever direction that is from current).
#   - Installed, version given, matches   -> no-op.
#
# Target user resolution: NOT "whoever is logged in" - the caller supplies
# extension_path (the path to the extension's installed directory, or a file
# within it, e.g. from a file watch on
# <drive>:\Users\<user>\.vscode\extensions\<id>-<version>), and the target
# user is extracted from that path. This is NEVER a hard failure:
# Resolve-VSCodeTargetUser cannot abort the run. Whenever it can't
# confidently resolve a real profile for the path (path missing/malformed,
# doesn't match extension_id, fails the filesystem safety check, or names a
# user with no such profile directory), it falls back to SYSTEM's own
# (normally empty) extensions directory instead - and keeps whatever
# username it DID manage to parse (if any) around in the envelope purely for
# diagnostics, never as a reason to stop.
#
# Unlike the macOS side (which impersonates the target user via `launchctl
# asuser` so `code` naturally reads/writes that user's ~/.vscode/extensions),
# this script never impersonates anyone. VS Code's CLI supports
# `--extensions-dir <dir>` to operate against an arbitrary extensions
# folder directly - so instead of running `code` AS the target user, this
# always runs it as whatever identity launched this script (typically
# SYSTEM, under RTR), pointed explicitly at the resolved user's extensions
# directory. This sidesteps Windows token-impersonation entirely, at the
# cost of never actually running IN that user's session (fine here - the
# CLI's extension install/list operations are pure filesystem + network, no
# GUI/session dependency).
#
# RTR contract:
#   - Input  : single base64-encoded JSON passed as the script's first
#              positional argument.
#   - Output : one compact JSON object on stdout (the ActionResult envelope).
#   - Stderr : SILENT. All errors are reported inside the JSON envelope.
#   - Diag   : file-only at C:\Windows\Temp\glow\rtr.txt. Never stderr.
#
# Local testing (no args uses safe defaults: dry_run=true):
#   $json = '{"params":{"extension_id":"ms-python.python","version":"2024.1.0","extension_path":"C:\\Users\\jdoe\\.vscode\\extensions\\ms-python.python-2024.5.0"},"dry_run":true}'
#   $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($json))
#   .\dist\Set-VSCodeExtensionVersion.ps1 $b64
# =====================================================================

# ===== Section 0: Constants =====

$Script:ScriptVersion = 1
$Script:OsFamily      = 'windows'
$Script:DiagFile      = 'C:\Windows\Temp\glow\rtr.txt'

$Script:DefaultCmdTimeoutSec = 20
# Installing/upgrading an extension downloads a VSIX over the network - give
# it much longer than a quick local command before we give up.
$Script:InstallCmdTimeoutSec = 120

# SYSTEM's own conventional profile-relative extensions path - the Windows
# analogue of the macOS side's HOME=/var/root root-fallback isolation.
# Normally empty (SYSTEM has no VS Code extensions of its own), which is
# exactly the isolation guarantee the fallback is meant to provide: whenever
# a real target user can't be confidently resolved, this script must never
# silently operate on some OTHER real user's actual extensions.
$Script:RootFallbackExtensionsDir = Join-Path $env:SystemRoot 'System32\config\systemprofile\.vscode\extensions'

# ===== Section 1: Small Helpers =====

function Get-VSCodeNowIso {
  return [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
}

function Write-VSCodeDiag {
  param([string]$Message)
  try {
    $dir = Split-Path -Path $Script:DiagFile -Parent
    if (-not (Test-Path -LiteralPath $dir)) {
      New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $line = "[$(Get-VSCodeNowIso)] $Message`r`n"
    Add-Content -LiteralPath $Script:DiagFile -Value $line -Encoding utf8 -ErrorAction Stop
  } catch {
    # never throw from diagnostics
  }
}

function Get-VSCodeSerialNumber {
  try {
    $sn = (Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop).SerialNumber
    if ($sn) { return $sn }
  } catch {}
  return ''
}

function Get-VSCodeOSMajorVersion {
  try {
    $v = [System.Environment]::OSVersion.Version
    # Windows 10 and 11 both report major version 10 - Microsoft
    # distinguishes them by build number (11 starts at 22000+).
    if ($v.Major -eq 10 -and $v.Build -ge 22000) { return 11 }
    if ($v.Major -gt 0) { return $v.Major }
  } catch {}
  Write-VSCodeDiag 'WARN: could not determine Windows version'
  return 0
}

# ===== Section 2: Filesystem Helpers (single seams, mockable in tests) =====

function Test-VSCodeFileExists {
  param([string]$Path)
  if (-not $Path) { return $false }
  return Test-Path -LiteralPath $Path -PathType Leaf
}

function Test-VSCodeDirectoryExists {
  param([string]$Path)
  if (-not $Path) { return $false }
  return Test-Path -LiteralPath $Path -PathType Container
}

function New-VSCodeDirectoryIfMissing {
  param([string]$Path)
  if (-not (Test-VSCodeDirectoryExists $Path)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
}

function Get-VSCodeFileContent {
  param([string]$Path)
  if (-not (Test-VSCodeFileExists $Path)) { return $null }
  return Get-Content -LiteralPath $Path -Raw
}

function Set-VSCodeFileContent {
  param([string]$Path, [string]$Content)
  Set-Content -LiteralPath $Path -Value $Content -Encoding utf8
}

function Remove-VSCodeFileIfExists {
  param([string]$Path)
  if (Test-VSCodeFileExists $Path) {
    Remove-Item -LiteralPath $Path -Force
  }
}

# Resolves symlink/junction reparse points and standardizes the path, then
# lets the caller re-parse the result and compare against the original
# string-level parse - the same two-step defense as the macOS side's
# resolveSafe: string-level parsing alone can be fooled by a symlinked path
# component claiming to belong to one user while actually resolving
# elsewhere on disk. Best-effort only: resolves the leaf's own reparse
# point, not every ancestor directory in the chain (same caveat the macOS
# original carries, just via a different OS API).
function Resolve-VSCodeSafePath {
  param([string]$Path)
  if (-not $Path) { return $null }
  if ($Path -match '[\x00-\x1f]') { return $null }
  if ($Path.IndexOf('..') -ne -1) { return $null }
  try {
    $resolved = [System.IO.Path]::GetFullPath($Path)
  } catch { return $null }
  try {
    $item = Get-Item -LiteralPath $resolved -Force -ErrorAction Stop
    if ($item.LinkType -and $item.Target) {
      $target = $item.Target | Select-Object -First 1
      if (-not [System.IO.Path]::IsPathRooted($target)) {
        $target = Join-Path (Split-Path $resolved -Parent) $target
      }
      $resolved = [System.IO.Path]::GetFullPath($target)
    }
  } catch {
    # Path doesn't exist on disk (e.g. deleted between detection and this
    # run) - fine, there's no live reparse point to be fooled by; fall
    # through using the string-normalized path.
  }
  return $resolved
}

# ===== Section 3: Process Helper =====

# Runs a command with a timeout, combining stdout+stderr into one string
# (like shell's 2>&1) - same rationale as the macOS side's single-NSPipe
# approach: simpler, and sidesteps any risk of a full stderr buffer
# deadlocking a caller that's only draining stdout.
# Win32/CommandLineToArgvW-compatible argument quoting (the same algorithm
# .NET's own ProcessStartInfo.ArgumentList uses internally to build the
# actual native command line) - needed because ArgumentList itself is
# unavailable here (see Invoke-VSCodeNativeCommand's own comment on why).
# Only quotes an argument that actually needs it (contains whitespace or a
# literal quote); backslashes are only special immediately before a quote
# (a literal trailing backslash in a path, e.g. "C:\Program Files\", is
# NOT doubled unless what follows is a quote).
function ConvertTo-VSCodeQuotedArgument {
  param([string]$Argument)
  if ($Argument.Length -gt 0 -and $Argument -notmatch '[\s"]') {
    return $Argument
  }
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append('"')
  for ($i = 0; $i -lt $Argument.Length; $i++) {
    $backslashCount = 0
    while ($i -lt $Argument.Length -and $Argument[$i] -eq '\') {
      $backslashCount++
      $i++
    }
    if ($i -eq $Argument.Length) {
      [void]$sb.Append('\' * ($backslashCount * 2))
      break
    } elseif ($Argument[$i] -eq '"') {
      [void]$sb.Append('\' * ($backslashCount * 2 + 1))
      [void]$sb.Append('"')
    } else {
      [void]$sb.Append('\' * $backslashCount)
      [void]$sb.Append($Argument[$i])
    }
  }
  [void]$sb.Append('"')
  return $sb.ToString()
}

function ConvertTo-VSCodeArgumentString {
  param([string[]]$Arguments)
  return (($Arguments | ForEach-Object { ConvertTo-VSCodeQuotedArgument $_ }) -join ' ')
}

function Invoke-VSCodeNativeCommand {
  param(
    [Parameter(Mandatory)][string]$FilePath,
    [string[]]$ArgumentList = @(),
    [int]$TimeoutSec = $Script:DefaultCmdTimeoutSec
  )
  try {
    $launchPath = $FilePath
    $launchArgs = $ArgumentList
    # Process.Start with UseShellExecute=false (required below for
    # stdout/stderr redirection) does NOT consult the registry file
    # association that lets ShellExecute run .cmd/.bat files directly -
    # CreateProcess needs an actual executable. code.cmd (VS Code's CLI
    # entry point on Windows) is a batch file, so it must be launched via
    # cmd.exe /c, never passed as FileName directly.
    if ($FilePath -match '\.(cmd|bat)$') {
      $launchPath = Join-Path $env:SystemRoot 'System32\cmd.exe'
      # /d skips any registry AutoRun commands - mild hardening for a
      # script that may run as SYSTEM.
      $launchArgs = @('/d', '/c', $FilePath) + $ArgumentList
    }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $launchPath
    # .Arguments (a single pre-quoted string), not .ArgumentList.Add() -
    # real bug found via a live windows-rtr run: .ArgumentList is $null
    # under this box's Windows PowerShell 5.1 (real production RTR
    # deployments run under plain `powershell.exe`, i.e. 5.1, not `pwsh` -
    # this had gone uncaught because the windows-remote/SSH test path only
    # ever exercised it under a bootstrapped pwsh 7, which a real target
    # machine has no reason to have), throwing "You cannot call a method
    # on a null-valued expression." on literally the first CLI call of any
    # real deployment. ConvertTo-VSCodeArgumentString reproduces the same
    # quoting ArgumentList would have applied, so this is not a behavior
    # change on hosts where ArgumentList did work.
    $psi.Arguments = ConvertTo-VSCodeArgumentString $launchArgs
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true

    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi

    $outText = New-Object System.Text.StringBuilder
    Register-ObjectEvent -InputObject $proc -EventName OutputDataReceived -Action {
      if ($null -ne $EventArgs.Data) { $Event.MessageData.AppendLine($EventArgs.Data) | Out-Null }
    } -MessageData $outText | Out-Null
    Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived -Action {
      if ($null -ne $EventArgs.Data) { $Event.MessageData.AppendLine($EventArgs.Data) | Out-Null }
    } -MessageData $outText | Out-Null

    $proc.Start() | Out-Null
    $proc.BeginOutputReadLine()
    $proc.BeginErrorReadLine()

    $exited = $proc.WaitForExit($TimeoutSec * 1000)
    if (-not $exited) {
      # Process.Kill($true) (kills the entire child-process tree) is a
      # .NET Core/.NET 5+-only overload - it does not exist under real
      # RTR's actual runtime (powershell.exe 5.1, .NET Framework), where
      # calling it throws a MethodException that the bare catch below
      # used to silently swallow - meaning a timed-out process was NEVER
      # actually killed on real RTR, just left running forever.
      #
      # The correct fallback is NOT a plain single-process Kill() - code.cmd
      # is always launched via cmd.exe /d /c (see $launchPath above), so
      # $proc here is that cmd.exe wrapper, not the real work. Confirmed
      # directly: killing just the wrapper leaves its own children (the
      # console host AND the actual long-running process, e.g. a real
      # hung `code` invocation) still running indefinitely - an orphan,
      # not a fix. taskkill /T /F recursively kills the whole tree by pid
      # and is available on every Windows PowerShell version since it
      # shells out to a separate, always-present executable rather than
      # relying on any particular Process API surface.
      try {
        $proc.Kill($true)
      } catch {
        try {
          Start-Process -FilePath 'taskkill.exe' -ArgumentList @('/PID', $proc.Id, '/T', '/F') `
            -Wait -WindowStyle Hidden -ErrorAction Stop
        } catch {
          try { $proc.Kill() } catch {}
        }
      }
    }
    # Per .NET's own guidance for redirected-stream processes: call the
    # parameterless overload after the timed one so the async output pump
    # is guaranteed to finish flushing before Stdout/Stderr are read below -
    # otherwise the last chunk of output can race the read.
    $proc.WaitForExit()
    Get-EventSubscriber | Where-Object { $_.SourceObject -eq $proc } | Unregister-Event

    $combined = $outText.ToString()
    return [PSCustomObject]@{ ExitCode = $proc.ExitCode; Stdout = $combined; Stderr = $combined }
  } catch {
    return [PSCustomObject]@{ ExitCode = -1; Stdout = ''; Stderr = [string]$_ }
  }
}

# ===== Section 4: Target User Resolution (never aborts) =====

# Combines the pure path-format validation (Get-VSCodeExtensionPathUser)
# with a real filesystem safety check and a profile-directory existence
# check, then decides the effective extensions directory to operate
# against.
#
# This function ALWAYS returns something usable - it never signals "abort
# the run". Whenever a real, resolvable profile can't be confidently
# determined (path missing/malformed, doesn't match extension_id, fails the
# safety check, or names a user with no such profile directory),
# ExtensionsDir comes back pointed at SYSTEM's own isolated directory
# instead. User reflects whatever username WAS parsed from the path, if any
# - kept for diagnostics regardless of whether that profile actually exists.
#
# Returns @{ User = string|$null; ExtensionsDir = string; ResolutionNote = string|$null }.
function Resolve-VSCodeTargetUser {
  param([string]$ExtensionPath, [string]$ExtId)

  $parsed = Get-VSCodeExtensionPathUser $ExtensionPath $ExtId
  if (-not $parsed.Ok) {
    return [PSCustomObject]@{ User = $null; ExtensionsDir = $Script:RootFallbackExtensionsDir; ResolutionNote = $parsed.Error }
  }

  $safePath = Resolve-VSCodeSafePath $ExtensionPath
  $reparsed = if ($safePath) { Get-VSCodeExtensionPathUser $safePath $ExtId } else { $null }
  if (-not $safePath -or -not $reparsed.Ok -or $reparsed.User -ne $parsed.User) {
    Write-VSCodeDiag "WARN: extension_path failed filesystem safety check - falling back to SYSTEM's own extensions dir: $ExtensionPath"
    return [PSCustomObject]@{ User = $parsed.User; ExtensionsDir = $Script:RootFallbackExtensionsDir; ResolutionNote = 'EXTENSION_PATH_UNSAFE' }
  }

  $userProfileDir = "C:\Users\$($parsed.User)"
  if (-not (Test-VSCodeDirectoryExists $userProfileDir)) {
    Write-VSCodeDiag "WARN: extension_path names user `"$($parsed.User)`" but no such profile directory exists - falling back to SYSTEM's own extensions dir"
    return [PSCustomObject]@{ User = $parsed.User; ExtensionsDir = $Script:RootFallbackExtensionsDir; ResolutionNote = 'EXTENSION_PATH_USER_NOT_FOUND' }
  }

  $extensionsDir = Join-Path $userProfileDir '.vscode\extensions'
  return [PSCustomObject]@{ User = $parsed.User; ExtensionsDir = $extensionsDir; ResolutionNote = $null }
}

# Locates code.cmd. Unlike the single fixed path on macOS, VS Code on
# Windows can be installed system-wide (Program Files) or per-user
# (LocalAppData) - checked in that order, since a system-wide install can
# manage ANY user's --extensions-dir regardless of who's logged in, while a
# per-user install only exists at all under that specific person's profile.
# $TargetUser (if resolved) is checked last, as the fallback for a
# machine where VS Code was only ever installed per-user by that person.
function Find-VSCodeCli {
  param([string]$TargetUser)

  $candidates = New-Object System.Collections.Generic.List[string]
  if ($env:ProgramFiles) {
    $candidates.Add((Join-Path $env:ProgramFiles 'Microsoft VS Code\bin\code.cmd'))
  }
  $programFilesX86 = ${env:ProgramFiles(x86)}
  if ($programFilesX86) {
    $candidates.Add((Join-Path $programFilesX86 'Microsoft VS Code\bin\code.cmd'))
  }
  if ($env:LOCALAPPDATA) {
    $candidates.Add((Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\bin\code.cmd'))
  }
  if ($TargetUser) {
    $candidates.Add("C:\Users\$TargetUser\AppData\Local\Programs\Microsoft VS Code\bin\code.cmd")
  }

  foreach ($candidate in $candidates) {
    if (Test-VSCodeFileExists $candidate) { return $candidate }
  }
  return $null
}

# ===== Section 5: Extension Version Actions =====

# Derives the VS Code user-data-dir from $ExtensionsDir rather than taking
# it as a separate parameter: extensions_dir always ends in
# "...\.vscode\extensions" (see Resolve-VSCodeTargetUser and the SYSTEM
# fallback constant above), so its grandparent is that same identity's own
# profile root (a real user's C:\Users\<user>, or SYSTEM's own profile for
# the isolated fallback) - user-data-dir is that profile's own
# AppData\Roaming\Code, VS Code's real default location. Deriving it this
# way means the temporary settings change below always lands in the SAME
# identity's own space extensions_dir already targets, never a different
# or unrelated location. Throws if $ExtensionsDir doesn't have the
# expected shape, rather than guessing.
function Get-VSCodeUserDataDir {
  param([string]$ExtensionsDir)
  $leaf = Split-Path $ExtensionsDir -Leaf
  $vscodeDir = Split-Path $ExtensionsDir -Parent
  $vscodeLeaf = Split-Path $vscodeDir -Leaf
  if ($leaf -ne 'extensions' -or $vscodeLeaf -ne '.vscode') {
    throw "Cannot derive user-data-dir: '$ExtensionsDir' does not end in \.vscode\extensions"
  }
  $profileRoot = Split-Path $vscodeDir -Parent
  return Join-Path $profileRoot 'AppData\Roaming\Code'
}

# Real-world finding: as of VS Code 1.129, the marketplace only serves a
# signature for an extension's current latest version - installing or
# pinning ANY older version (the entire point of this script's --version
# support: upgrade OR downgrade to an exact pinned version) fails with
# "Signature verification failed: NotSigned" otherwise. Temporarily
# setting extensions.verifySignature: false in the target identity's own
# settings.json around each CLI call - never a different user's, and
# reverted immediately after (see Restore-VSCodeSignatureVerification) -
# makes this tool's own already-trusted, RTR-driven installs work
# regardless of marketplace signing status, without leaving that setting
# changed afterward or affecting the user's own interactive VS Code
# session beyond the brief window of a single CLI invocation.
#
# Restoration writes back the exact original raw file text, not a
# reparsed/reserialized version - settings.json commonly has jsonc
# comments a parse+rewrite round-trip would silently destroy; only the
# brief window during the CLI call itself goes through a parsed form.
function Enable-VSCodeSignatureVerificationBypass {
  param([string]$UserDataDir)
  $settingsDir = Join-Path $UserDataDir 'User'
  $settingsPath = Join-Path $settingsDir 'settings.json'
  $fileExisted = Test-VSCodeFileExists $settingsPath
  $originalRaw = if ($fileExisted) { Get-VSCodeFileContent $settingsPath } else { $null }

  New-VSCodeDirectoryIfMissing $settingsDir

  $settings = [ordered]@{}
  if ($originalRaw -and $originalRaw.Trim()) {
    try {
      # -AsHashtable is PowerShell 6.0+ only and does not exist in Windows
      # PowerShell 5.1, which is what RTR's runscript actually invokes -
      # ConvertFrom-Json without it returns a PSCustomObject on both 5.1 and
      # 7+, so walk .PSObject.Properties instead.
      $parsed = $originalRaw | ConvertFrom-Json
      foreach ($property in $parsed.PSObject.Properties) { $settings[$property.Name] = $property.Value }
    } catch {
      Write-VSCodeDiag "WARN: could not parse existing settings.json at ${settingsPath}: $_ - leaving it untouched, signature bypass not applied for this call"
      return [PSCustomObject]@{ Applied = $false }
    }
  }
  $settings['extensions.verifySignature'] = $false
  Set-VSCodeFileContent $settingsPath ($settings | ConvertTo-Json -Depth 10)

  return [PSCustomObject]@{
    Applied      = $true
    SettingsPath = $settingsPath
    FileExisted  = $fileExisted
    OriginalRaw  = $originalRaw
  }
}

function Restore-VSCodeSignatureVerification {
  param($State)
  if (-not $State -or -not $State.Applied) { return }
  try {
    if ($State.FileExisted) {
      Set-VSCodeFileContent $State.SettingsPath $State.OriginalRaw
    } else {
      Remove-VSCodeFileIfExists $State.SettingsPath
    }
  } catch {
    Write-VSCodeDiag "WARN: could not restore settings.json at $($State.SettingsPath): $_"
  }
}

# Runs `code` pointed at $ExtensionsDir via --extensions-dir - this is the
# one thing every CLI invocation in this script goes through, the Windows
# analogue of the macOS side's runCode dispatch (launchctl asuser / root
# fallback), just without ever changing process identity. Brackets the
# call with the signature-verification bypass above, enabled only for
# this one invocation and always restored afterward, success or failure.
function Invoke-VSCodeCli {
  param([string]$CodePath, [string]$ExtensionsDir, [string[]]$Arguments, [int]$TimeoutSec)
  $userDataDir = Get-VSCodeUserDataDir $ExtensionsDir
  $bypassState = Enable-VSCodeSignatureVerificationBypass $userDataDir
  try {
    $fullArgs = @('--extensions-dir', $ExtensionsDir, '--user-data-dir', $userDataDir) + $Arguments
    return Invoke-VSCodeNativeCommand -FilePath $CodePath -ArgumentList $fullArgs -TimeoutSec $TimeoutSec
  } finally {
    Restore-VSCodeSignatureVerification $bypassState
  }
}

# A changed extension version only takes effect for a window's already-
# running extension host once that window is reloaded/restarted - VS
# Code does not hot-swap an active extension's code on disk changing out
# from under it. A managed version-pinning tool can't rely on the user
# noticing a "reload required" prompt (or one even appearing) on their
# own, so if the target user has VS Code running, it's fully restarted
# after a real, successful, changed version update. Unlike the macOS
# side (which impersonates the target user via launchctl asuser, so it
# can just quit/relaunch directly as them), this script never
# impersonates anyone (see this file's own header) - relaunching a GUI
# process INTO an arbitrary other user's session from a SYSTEM-context
# script needs a different mechanism than starting a new process: a
# one-shot Scheduled Task with -LogonType Interactive, registered,
# triggered, and unregistered again immediately - the supported way to
# start a process in another user's real interactive session without
# token impersonation/duplication. Best-effort: never affects the run's
# overall success/failure, only logged to diagnostics.
# Single seam wrapping the two chained CIM calls (Get-CimInstance +
# each process's own GetOwner method) - a custom function, not the raw
# cmdlets, mirrors Invoke-VSCodeNativeCommand's own rationale: mocking
# two real cmdlets directly through Pester proved unreliable here (both
# silently returned nothing under mock, with the calling code's own
# try/catch masking why), where mocking one custom function is simple
# and reliable. Returns every running Code.exe process as
# @{ ProcessId; User }, regardless of owner - Get-VSCodeRunningPidsForUser
# does the actual filtering.
function Get-VSCodeProcessOwners {
  param([string]$ProcessName)
  $result = @()
  try {
    $procs = Get-CimInstance -ClassName Win32_Process -Filter "Name = '$ProcessName'"
  } catch {
    return $result
  }
  foreach ($p in $procs) {
    try {
      $owner = Invoke-CimMethod -InputObject $p -MethodName GetOwner
      $result += [PSCustomObject]@{ ProcessId = $p.ProcessId; User = $owner.User }
    } catch {
      # can't determine this process's owner - skip rather than guess
    }
  }
  return $result
}

function Get-VSCodeRunningPidsForUser {
  param([string]$TargetUser)
  if (-not $TargetUser) { return @() }
  $owners = Get-VSCodeProcessOwners 'Code.exe'
  return $owners | Where-Object { $_.User -eq $TargetUser } | ForEach-Object { $_.ProcessId }
}

# Derives the real GUI Code.exe from the resolved code.cmd CLI path
# (Find-VSCodeCli) rather than a separate lookup - same install, one
# directory up: code.cmd lives in "...\Microsoft VS Code\bin\code.cmd",
# Code.exe in "...\Microsoft VS Code\Code.exe".
function Get-VSCodeGuiExePath {
  param([string]$CodePath)
  $binDir = Split-Path $CodePath -Parent
  $installDir = Split-Path $binDir -Parent
  return Join-Path $installDir 'Code.exe'
}

function Restart-VSCodeIfRunning {
  param([string]$TargetUser, [string]$CodePath)
  if (-not $TargetUser) { return $false }
  $pids = Get-VSCodeRunningPidsForUser $TargetUser
  if ($pids.Count -eq 0) { return $false }

  foreach ($procId in $pids) {
    try { Stop-Process -Id $procId -Force -ErrorAction Stop } catch {}
  }

  $guiExePath = Get-VSCodeGuiExePath $CodePath
  $taskName = "GlowVSCodeRestart_$([Guid]::NewGuid().ToString('N'))"
  try {
    $action = New-ScheduledTaskAction -Execute $guiExePath
    $principal = New-ScheduledTaskPrincipal -UserId $TargetUser -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Force -ErrorAction Stop | Out-Null
    Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
  } catch {
    Write-VSCodeDiag "WARN: failed to relaunch VS Code for ${TargetUser}: $_"
  } finally {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
  }
  return $true
}

function Get-VSCodeInstalledExtensionsRaw {
  param([string]$CodePath, [string]$ExtensionsDir)
  return Invoke-VSCodeCli -CodePath $CodePath -ExtensionsDir $ExtensionsDir `
    -Arguments @('--list-extensions', '--show-versions') -TimeoutSec $Script:DefaultCmdTimeoutSec
}

function Invoke-VSCodeUpgradeToLatest {
  param([string]$CodePath, [string]$ExtensionsDir, [string]$ExtId, [bool]$DryRun)
  if ($DryRun) { return [PSCustomObject]@{ Attempted = $false; DryRun = $true; Ok = $false; Stderr = '' } }
  # `code --upgrade-extension <id>` is NOT a real flag on this CLI (same as
  # the macOS side - verified against the same cross-platform Node CLI code)
  # - installing by id with no @version and --force correctly resolves and
  # installs latest instead.
  $r = Invoke-VSCodeCli -CodePath $CodePath -ExtensionsDir $ExtensionsDir `
    -Arguments @('--install-extension', $ExtId, '--force') -TimeoutSec $Script:InstallCmdTimeoutSec
  return [PSCustomObject]@{
    Attempted = $true
    ExitCode  = $r.ExitCode
    Ok        = ($r.ExitCode -eq 0)
    Stdout    = if ($r.Stdout) { $r.Stdout.Trim() } else { '' }
    Stderr    = if ($r.Stderr) { $r.Stderr.Trim() } else { '' }
  }
}

function Invoke-VSCodeSetExactVersion {
  param([string]$CodePath, [string]$ExtensionsDir, [string]$ExtId, [string]$Version, [bool]$DryRun)
  if ($DryRun) { return [PSCustomObject]@{ Attempted = $false; DryRun = $true; Ok = $false; Stderr = '' } }
  $r = Invoke-VSCodeCli -CodePath $CodePath -ExtensionsDir $ExtensionsDir `
    -Arguments @('--install-extension', "$ExtId@$Version", '--force') -TimeoutSec $Script:InstallCmdTimeoutSec
  return [PSCustomObject]@{
    Attempted = $true
    ExitCode  = $r.ExitCode
    Ok        = ($r.ExitCode -eq 0)
    Stdout    = if ($r.Stdout) { $r.Stdout.Trim() } else { '' }
    Stderr    = if ($r.Stderr) { $r.Stderr.Trim() } else { '' }
  }
}

# ===== Section 6: Input Decode & Main =====

function Get-VSCodeProp {
  param($Obj, [string]$Name, $Default)
  if ($null -eq $Obj) { return $Default }
  $prop = $Obj.PSObject.Properties[$Name]
  if ($null -eq $prop -or $null -eq $prop.Value) { return $Default }
  return $prop.Value
}

function ConvertTo-VSCodeBool {
  param($Value, [bool]$Default)
  if ($Value -is [bool]) { return $Value }
  if ($Value -is [string]) { return $Value -eq 'true' }
  return $Default
}

# Internal PowerShell objects use idiomatic PascalCase properties
# (Attempted, ExitCode, Ok, Stderr...), but the RTR envelope's JSON schema
# must match the macOS side's exact lowercase/snake_case field names
# (attempted, exit_code, ok, stderr...) - ConvertTo-Json serializes
# whatever case a property was constructed with, and PowerShell's
# case-insensitive member access doesn't change that. This is the one
# explicit translation point between internal convention and the wire
# contract, rather than scattering snake_case names through internal
# helpers.
function ConvertTo-VSCodeCliResultJson {
  param($ActionResult)
  if (-not $ActionResult) { return $null }
  if (-not $ActionResult.Attempted) {
    return [PSCustomObject]@{ attempted = $false; dry_run = $true }
  }
  return [PSCustomObject]@{
    attempted = $true
    exit_code = $ActionResult.ExitCode
    ok        = $ActionResult.Ok
    stdout    = $ActionResult.Stdout
    stderr    = $ActionResult.Stderr
  }
}

function ConvertTo-VSCodeErrorJson {
  param($ErrorResult)
  if (-not $ErrorResult) { return $null }
  return [PSCustomObject]@{
    code    = $ErrorResult.Code
    message = $ErrorResult.Message
    stderr  = $ErrorResult.Stderr
  }
}

function New-VSCodeFailureEnvelope {
  param([string]$StartTime, [bool]$DryRun, [string]$Code, [string]$Message)
  Write-VSCodeDiag "ERROR: ${Code}: $Message"
  $envelope = [PSCustomObject]@{
    os_family      = $Script:OsFamily
    script_version = $Script:ScriptVersion
    status         = 'failure'
    changed        = $false
    error          = [PSCustomObject]@{ code = $Code; message = $Message; stderr = '' }
    dry_run        = $DryRun
    start_time     = $StartTime
    end_time       = (Get-VSCodeNowIso)
    metadata       = [PSCustomObject]@{ hostname = $env:COMPUTERNAME; serial_number = '' }
  }
  return ($envelope | ConvertTo-Json -Compress -Depth 6)
}

function Invoke-SetVSCodeExtensionVersion {
  param([string]$EncodedInput)

  $startTime = Get-VSCodeNowIso
  $dryRun = $true # safe default for bare local invocation

  try {
    $inputObj = $null
    if ($EncodedInput) {
      $bytes      = [Convert]::FromBase64String($EncodedInput)
      $decodedRaw = [System.Text.Encoding]::UTF8.GetString($bytes)
      $inputObj   = $decodedRaw | ConvertFrom-Json -ErrorAction Stop
      $dryRun     = ConvertTo-VSCodeBool (Get-VSCodeProp $inputObj 'dry_run' $false) $false
    }
    $params = Get-VSCodeProp $inputObj 'params' ([PSCustomObject]@{})

    $extId = Get-VSCodeProp $params 'extension_id' $null
    $extId = if ($null -eq $extId) { '' } else { [string]$extId }
    if (-not (Test-VSCodeExtensionId $extId)) {
      return New-VSCodeFailureEnvelope $startTime $dryRun 'INVALID_PARAMS' 'invalid or missing extension_id (expected "<publisher>.<name>")'
    }

    $targetVersion = Get-VSCodeProp $params 'version' $null
    if ($null -ne $targetVersion) { $targetVersion = [string]$targetVersion }
    if (-not (Test-VSCodeExtensionVersion $targetVersion)) {
      return New-VSCodeFailureEnvelope $startTime $dryRun 'INVALID_PARAMS' "invalid version: $targetVersion"
    }

    $extensionPath = Get-VSCodeProp $params 'extension_path' $null
    $targetUser = Resolve-VSCodeTargetUser $extensionPath $extId # never aborts

    $codePath = Find-VSCodeCli -TargetUser $targetUser.User
    if (-not $codePath) {
      return New-VSCodeFailureEnvelope $startTime $dryRun 'VSCODE_NOT_INSTALLED' 'code.cmd was not found in any known install location'
    }

    $osMajor = Get-VSCodeOSMajorVersion

    $listResult = Get-VSCodeInstalledExtensionsRaw $codePath $targetUser.ExtensionsDir
    if ($listResult.ExitCode -ne 0) {
      $rawMsg = if ($listResult.Stderr) { $listResult.Stderr } elseif ($listResult.Stdout) { $listResult.Stdout } else { '' }
      return New-VSCodeFailureEnvelope $startTime $dryRun 'LIST_EXTENSIONS_FAILED' "code --list-extensions failed: $($rawMsg.Trim())"
    }
    $installedBefore = ConvertFrom-VSCodeInstalledExtensionsList $listResult.Stdout
    $decision = Get-VSCodeVersionAction $installedBefore $extId $targetVersion

    $action = $null
    $installedVersionAfter = $decision.InstalledVersion

    switch ($decision.Action) {
      'not_installed'           { } # per spec: never install fresh
      'already_correct_version' { } # idempotent no-op
      'set_version'              { $action = Invoke-VSCodeSetExactVersion $codePath $targetUser.ExtensionsDir $extId $targetVersion $dryRun }
      'upgrade_to_latest'        { $action = Invoke-VSCodeUpgradeToLatest $codePath $targetUser.ExtensionsDir $extId $dryRun }
    }

    if ($action -and $action.Attempted -and $action.Ok) {
      # Re-list to find out what version we actually ended up at, and
      # whether anything really changed (relevant for upgrade_to_latest,
      # where we couldn't know the target version in advance).
      $listAfter = Get-VSCodeInstalledExtensionsRaw $codePath $targetUser.ExtensionsDir
      if ($listAfter.ExitCode -eq 0) {
        $installedAfter = ConvertFrom-VSCodeInstalledExtensionsList $listAfter.Stdout
        $key = $extId.ToLowerInvariant()
        $installedVersionAfter = if ($installedAfter.ContainsKey($key)) { $installedAfter[$key] } else { $null }
      }
    }

    $outcome = Get-VSCodeRunOutcome $decision $action $installedVersionAfter $dryRun

    $vscodeRestarted = $false
    if ($outcome.Status -eq 'success' -and $outcome.Changed -and -not $dryRun) {
      try {
        $vscodeRestarted = Restart-VSCodeIfRunning $targetUser.User $codePath
      } catch {
        Write-VSCodeDiag "WARN: failed to restart VS Code after version change: $_"
      }
    }

    $envelope = [PSCustomObject]@{
      os_family                = $Script:OsFamily
      script_version           = $Script:ScriptVersion
      status                   = $outcome.Status
      changed                  = $outcome.Changed
      error                    = (ConvertTo-VSCodeErrorJson $outcome.Error)
      dry_run                  = $dryRun
      start_time                = $startTime
      end_time                  = (Get-VSCodeNowIso)
      metadata                  = [PSCustomObject]@{ hostname = $env:COMPUTERNAME; serial_number = (Get-VSCodeSerialNumber) }
      extension_id               = $extId
      target_version             = $targetVersion
      extension_path             = $extensionPath
      action                     = $decision.Action
      installed_version_before   = $decision.InstalledVersion
      installed_version_after    = $installedVersionAfter
      target_user                = $targetUser.User
      ran_as_root                = ($null -ne $targetUser.ResolutionNote)
      user_resolution_note       = $targetUser.ResolutionNote
      os_major_version           = $osMajor
      cli_result                 = (ConvertTo-VSCodeCliResultJson $action)
      vscode_restarted            = $vscodeRestarted
    }

    $json = $envelope | ConvertTo-Json -Compress -Depth 6
    Write-VSCodeDiag "RESULT: $json"
    return $json
  } catch {
    return New-VSCodeFailureEnvelope $startTime $dryRun 'UNHANDLED_ERROR' $_.Exception.Message
  }
}

# When run directly (not dot-sourced by Pester or concatenated into the
# dist script's own invocation block), print the envelope to stdout - the
# only thing this script ever writes there.
if ($MyInvocation.InvocationName -ne '.') {
  Invoke-SetVSCodeExtensionVersion -EncodedInput $args[0]
}
