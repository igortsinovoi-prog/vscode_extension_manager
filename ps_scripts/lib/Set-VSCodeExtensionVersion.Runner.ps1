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
# The envelope is meant to stay compact (a pass/fail signal, not a log
# dump) - real code.cmd output can run to several KB (deprecation
# warnings, full marketplace install logs, ...). The FULL text always
# still goes to the diag file first (see ConvertTo-VSCodeTruncatedText's
# own callers); this only bounds what actually ends up in the JSON.
$Script:MaxCliOutputEnvelopeLen = 2000

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

# Test-Path's own bare boolean conflates "doesn't exist" with "access
# denied" (returns $false for both), which matters specifically for
# target-user resolution below: under real RTR (SYSTEM), a profile
# directory that genuinely exists but can't actually be used (unusual
# NTFS permissions, a locked-down profile, a network-redirected profile
# that's temporarily unreachable, ...) must never be silently reported
# the same way as "this account has no profile at all" - the first is a
# real access problem worth surfacing distinctly in the envelope; the
# second is this function's own normal, expected fallback case.
#
# A real write-and-delete probe, not Get-Item/Get-ChildItem - confirmed
# via a real "deny everyone full control" ACE on real hardware: neither
# reliably throws for an Administrator-group account (read/list-style
# checks apparently don't hit the same access check this actually cares
# about), while the REAL failure this exists to catch - a real write,
# deep inside enableSignatureBypass - unquestionably does. This probes
# the one thing that actually matters: can this identity really create/
# write something here, which is exactly what every real caller needs
# this profile directory for.
function Test-VSCodePathAccess {
  param([string]$Path)
  try {
    if (-not (Test-Path -LiteralPath $Path)) {
      return [PSCustomObject]@{ Exists = $false; AccessDenied = $false }
    }
    $probePath = Join-Path $Path ('.rwc_access_check_' + [System.IO.Path]::GetRandomFileName())
    New-Item -ItemType File -Path $probePath -ErrorAction Stop | Out-Null
    Remove-Item -LiteralPath $probePath -Force -ErrorAction SilentlyContinue
    return [PSCustomObject]@{ Exists = $true; AccessDenied = $false }
  } catch [System.UnauthorizedAccessException] {
    return [PSCustomObject]@{ Exists = $true; AccessDenied = $true }
  } catch [System.Management.Automation.ItemNotFoundException] {
    return [PSCustomObject]@{ Exists = $false; AccessDenied = $false }
  } catch {
    # Anything else unexpected (a broken reparse point, a transient I/O
    # error, ...) - treat as "doesn't exist" for safety, matching this
    # file's own "never aborts" philosophy elsewhere, but log it since
    # it's still worth knowing about.
    Write-VSCodeDiag "WARN: unexpected error checking path access for ${Path}: $_"
    return [PSCustomObject]@{ Exists = $false; AccessDenied = $false }
  }
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
  # Atomic write: write to a temp file in the SAME directory (same
  # volume, so the final move is a single filesystem rename, not a
  # copy+delete that could be interrupted partway) then move it over the
  # real path - a process killed mid-write (RTR's own script-execution
  # timeout, session termination, ...) can otherwise leave settings.json
  # truncated/corrupted (a half-written file) instead of either its old
  # or new content intact.
  $dir = Split-Path -Path $Path -Parent
  $tempPath = Join-Path $dir ([System.IO.Path]::GetRandomFileName())
  try {
    Set-Content -LiteralPath $tempPath -Value $Content -Encoding utf8
    Move-Item -LiteralPath $tempPath -Destination $Path -Force
  } finally {
    Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
  }
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

# Resolves a username to its REAL profile directory via Win32_UserProfile
# (translate the username to its SID, then look up that SID's own
# LocalPath) - not a hardcoded "C:\Users\<user>" guess, which silently
# breaks for a profile relocated to another drive/path, or a folder name
# that no longer matches the account's current username (Windows keeps
# the ORIGINAL profile folder name across a user rename; only the
# account's own login name changes). Wrapped as one function (not
# separate NTAccount.Translate()/Get-CimInstance calls inlined at each
# call site) specifically so it can be mocked as a single unit in tests -
# this project's own Runner.Tests.ps1 already documents mocking chained
# CIM calls directly as unreliable; wrapping the real system calls in one
# function and mocking that instead is the established fix. Never
# aborts: any failure (restricted CIM access, no matching profile, ...)
# falls back to the naive guess rather than throwing, matching every
# other function in this section.
function Resolve-VSCodeUserProfilePath {
  param([string]$UserName)
  $fallback = "C:\Users\$UserName"
  try {
    $sid = (New-Object System.Security.Principal.NTAccount($UserName)).Translate([System.Security.Principal.SecurityIdentifier]).Value
    $userProfile = Get-CimInstance -ClassName Win32_UserProfile -Filter "SID='$sid'" -ErrorAction Stop
    if ($userProfile -and $userProfile.LocalPath) {
      return $userProfile.LocalPath
    }
  } catch {
    Write-VSCodeDiag "WARN: could not resolve `"$UserName`"'s real profile path via Win32_UserProfile: $_ - falling back to $fallback"
  }
  return $fallback
}

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

  $userProfileDir = Resolve-VSCodeUserProfilePath $parsed.User
  $profileAccess = Test-VSCodePathAccess $userProfileDir
  if ($profileAccess.AccessDenied) {
    # Distinct from "no such profile" below - the account genuinely has
    # a profile here, we just couldn't read into it. Reported as its own
    # resolution note rather than folded into EXTENSION_PATH_USER_NOT_FOUND,
    # which would misleadingly suggest the account doesn't exist at all.
    Write-VSCodeDiag "WARN: extension_path names user `"$($parsed.User)`" whose profile directory exists but could not be accessed (permission denied) - falling back to SYSTEM's own extensions dir"
    return [PSCustomObject]@{ User = $parsed.User; ExtensionsDir = $Script:RootFallbackExtensionsDir; ResolutionNote = 'EXTENSION_PATH_USER_PROFILE_ACCESS_DENIED' }
  }
  if (-not $profileAccess.Exists) {
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
    $candidates.Add((Join-Path (Resolve-VSCodeUserProfilePath $TargetUser) 'AppData\Local\Programs\Microsoft VS Code\bin\code.cmd'))
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
  $backupPath = "$settingsPath.rwcbak"
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

  # A REAL on-disk backup, not just $originalRaw held in this process'
  # own memory - if this process is killed before
  # Restore-VSCodeSignatureVerification ever runs (RTR's own script-
  # execution timeout, session termination, ...), the original content
  # used to be gone for good, leaving verifySignature stuck false with
  # no recovery path. Only written when there's real original content to
  # protect; Set-VSCodeFileContent's own atomic write means this can't
  # itself leave a half-written backup either.
  if ($fileExisted) {
    Set-VSCodeFileContent $backupPath $originalRaw
  }

  $settings['extensions.verifySignature'] = $false
  Set-VSCodeFileContent $settingsPath ($settings | ConvertTo-Json -Depth 10)

  return [PSCustomObject]@{
    Applied      = $true
    SettingsPath = $settingsPath
    BackupPath   = $backupPath
    FileExisted  = $fileExisted
  }
}

function Restore-VSCodeSignatureVerification {
  param($State)
  if (-not $State -or -not $State.Applied) { return }
  try {
    if ($State.FileExisted) {
      # From the on-disk backup, not an in-memory variable - see
      # Enable-VSCodeSignatureVerificationBypass's own comment on why
      # that matters.
      $originalRaw = Get-VSCodeFileContent $State.BackupPath
      Set-VSCodeFileContent $State.SettingsPath $originalRaw
    } else {
      Remove-VSCodeFileIfExists $State.SettingsPath
    }
    Remove-VSCodeFileIfExists $State.BackupPath
  } catch {
    Write-VSCodeDiag "WARN: could not restore settings.json at $($State.SettingsPath) from backup $($State.BackupPath): $_"
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
  # @(...) documents the intent (always a collection, never a bare pid)
  # but does NOT by itself guarantee callers see an array - a function's
  # `return @(...)` still gets enumerated back into individual objects on
  # the way out through PowerShell's own pipeline/output-stream boundary,
  # so a caller doing plain `$x = Get-VSCodeRunningPidsForUser ...` sees
  # exactly what a bare `return $someCollection` would have given it:
  # $null for zero matches, a scalar (no .Count) for exactly one, and
  # only a real array for two or more. See Restart-VSCodeIfRunning's own
  # callers, which each wrap this call in `@(...)` themselves for exactly
  # that reason - this file's own PowerShell 7-bootstrapped test history
  # (see Invoke-VSCodeNativeCommand's own comment) had never caught this,
  # since PowerShell 7+ added a universal Count property to scalars that
  # masks it entirely; real RTR runs under Windows PowerShell 5.1, where
  # a bare scalar has no such property.
  return @($owners | Where-Object { $_.User -eq $TargetUser } | ForEach-Object { $_.ProcessId })
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

# Sends a graceful close request (WM_CLOSE) to a process' main window -
# the same signal a user clicking that window's own close button would
# send, giving VS Code a real chance to save state/exit cleanly before
# ever being force-killed.
#
# IMPORTANT, confirmed via a real RTR-shaped (non-interactive) session
# against a real VS Code window: this reliably does NOT work under this
# script's actual real deployment context. Process.MainWindowHandle (what
# CloseMainWindow needs) cannot see a window owned by a different login
# session, and RTR always runs non-interactively (as SYSTEM) in a
# different session than whatever interactive session is actually
# rendering VS Code's window - confirmed directly: every real Code.exe
# process showed MainWindowHandle=0 from this exact vantage point. This
# is the identical session-isolation boundary that scenario 15's own
# watcher-task infrastructure exists to cross for GUI automation - but
# that's opt-in test tooling, not part of this production code path.
# macOS has no equivalent problem: launchctl asuser genuinely lets a
# root process reach into the target session for real AppleEvents.
#
# Kept anyway (not reverted to an immediate force-kill) - gentlest-action-
# first is still the right instinct, this costs one bounded ~10s wait
# per real restart, and it's a real no-op if some future Windows/RTR
# change ever does let this reach the right session. Just don't expect
# it to actually save anyone's unsaved work in a real deployment today -
# see the shipped README's own "Behavior worth knowing" section.
#
# Wrapped as its own function (not Get-Process + .CloseMainWindow()
# inlined at the call site) specifically so it's mockable as a single
# unit in tests - a real Process object's own CloseMainWindow() is a
# .NET object method, not a PowerShell command, so Pester's Mock can't
# intercept it directly; this matches the same established pattern
# already used for Get-VSCodeProcessOwners, Resolve-VSCodeUserProfilePath,
# and Test-VSCodePathAccess.
function Invoke-VSCodeCloseMainWindow {
  param([int]$ProcessId)
  try {
    $proc = Get-Process -Id $ProcessId -ErrorAction Stop
    [void]$proc.CloseMainWindow()
  } catch {}
}

function Restart-VSCodeIfRunning {
  param([string]$TargetUser, [string]$CodePath)
  if (-not $TargetUser) { return $false }
  # @(...) here at the CALL site, not just inside
  # Get-VSCodeRunningPidsForUser's own return statement - a function's
  # `return @(...)` does not survive the trip through PowerShell's own
  # pipeline/output-stream boundary: the array gets enumerated back into
  # individual objects on the way out, so the caller sees exactly what a
  # bare `return $someCollection` would have given it - $null for zero
  # matches, a bare scalar (no .Count) for exactly one, and only an
  # actual array for two or more. Confirmed directly: the internal @()
  # wrap alone was NOT enough - this line's own `.Count` access still
  # threw PropertyNotFoundException under Set-StrictMode against a
  # single mocked pid until this call site was wrapped too.
  $pids = @(Get-VSCodeRunningPidsForUser $TargetUser)
  if ($pids.Count -eq 0) { return $false }

  # Gentlest action first, matching the mac side's own quit-AppleEvent-
  # then-poll-then-SIGKILL sequence (real_world_check's own
  # kill_vscode_gui_session) - a real, changed version only helps the
  # user once VS Code actually reloads it, but force-killing a window
  # that might have unsaved state is the LAST resort, not the first.
  foreach ($procId in $pids) {
    Invoke-VSCodeCloseMainWindow $procId
  }

  $waited = 0
  while (@(Get-VSCodeRunningPidsForUser $TargetUser).Count -gt 0 -and $waited -lt 10) {
    Start-Sleep -Seconds 1
    $waited++
  }

  # Last resort - anything still running after the graceful close had
  # its full chance. Logged either way (not just the force-kill branch)
  # so a real run's own diag file shows which path was actually taken -
  # useful given Invoke-VSCodeCloseMainWindow's own comment: confirmed
  # via real_world_check's own scenario 17 against a real RTR-shaped
  # session that this reliably falls through to here, every time, in
  # this script's actual real deployment context.
  $stillRunning = @(Get-VSCodeRunningPidsForUser $TargetUser)
  if ($stillRunning.Count -eq 0) {
    Write-VSCodeDiag "Restart-VSCodeIfRunning: graceful close succeeded within ${waited}s, no force-kill needed"
  } else {
    Write-VSCodeDiag "Restart-VSCodeIfRunning: still running after ${waited}s graceful-close window, force-killing: $($stillRunning -join ',')"
    foreach ($procId in $stillRunning) {
      try { Stop-Process -Id $procId -Force -ErrorAction Stop } catch {}
    }
  }

  $guiExePath = Get-VSCodeGuiExePath $CodePath
  $taskName = "GlowVSCodeRestart_$([Guid]::NewGuid().ToString('N'))"
  $relaunched = $false
  try {
    $action = New-ScheduledTaskAction -Execute $guiExePath
    $principal = New-ScheduledTaskPrincipal -UserId $TargetUser -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Force -ErrorAction Stop | Out-Null
    Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
    $relaunched = $true
  } catch {
    Write-VSCodeDiag "WARN: failed to relaunch VS Code for ${TargetUser}: $_"
  } finally {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
  }
  return $relaunched
}

function Get-VSCodeInstalledExtensionsRaw {
  param([string]$CodePath, [string]$ExtensionsDir)
  return Invoke-VSCodeCli -CodePath $CodePath -ExtensionsDir $ExtensionsDir `
    -Arguments @('--list-extensions', '--show-versions') -TimeoutSec $Script:DefaultCmdTimeoutSec
}

# Trims text for the envelope after logging the FULL, untruncated version
# to diag first - the envelope is meant to stay compact (a pass/fail
# signal, not a log dump), but nothing actually gets lost: the complete
# output is always still recoverable from the diag file.
function ConvertTo-VSCodeTruncatedText {
  param([string]$Text, [string]$Label)
  $Text = if ($Text) { $Text } else { '' }
  Write-VSCodeDiag "$Label (full, $($Text.Length) chars): $Text"
  if ($Text.Length -le $Script:MaxCliOutputEnvelopeLen) { return $Text }
  return $Text.Substring(0, $Script:MaxCliOutputEnvelopeLen) +
    "... [truncated, $($Text.Length) chars total - see diag for the full text]"
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
  $stdout = if ($r.Stdout) { $r.Stdout.Trim() } else { '' }
  $stderr = if ($r.Stderr) { $r.Stderr.Trim() } else { '' }
  return [PSCustomObject]@{
    Attempted = $true
    ExitCode  = $r.ExitCode
    Ok        = ($r.ExitCode -eq 0)
    Stdout    = ConvertTo-VSCodeTruncatedText $stdout 'Invoke-VSCodeUpgradeToLatest stdout'
    Stderr    = ConvertTo-VSCodeTruncatedText $stderr 'Invoke-VSCodeUpgradeToLatest stderr'
  }
}

function Invoke-VSCodeSetExactVersion {
  param([string]$CodePath, [string]$ExtensionsDir, [string]$ExtId, [string]$Version, [bool]$DryRun)
  if ($DryRun) { return [PSCustomObject]@{ Attempted = $false; DryRun = $true; Ok = $false; Stderr = '' } }
  $r = Invoke-VSCodeCli -CodePath $CodePath -ExtensionsDir $ExtensionsDir `
    -Arguments @('--install-extension', "$ExtId@$Version", '--force') -TimeoutSec $Script:InstallCmdTimeoutSec
  $stdout = if ($r.Stdout) { $r.Stdout.Trim() } else { '' }
  $stderr = if ($r.Stderr) { $r.Stderr.Trim() } else { '' }
  return [PSCustomObject]@{
    Attempted = $true
    ExitCode  = $r.ExitCode
    Ok        = ($r.ExitCode -eq 0)
    Stdout    = ConvertTo-VSCodeTruncatedText $stdout 'Invoke-VSCodeSetExactVersion stdout'
    Stderr    = ConvertTo-VSCodeTruncatedText $stderr 'Invoke-VSCodeSetExactVersion stderr'
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

# A real (non-sentinel) $TargetUser from Resolve-VSCodeTargetUser has
# ResolutionNote = $null in exactly one case: a real user was actually
# resolved, in which case User is always non-null too. Every fallback
# path sets ResolutionNote, regardless of whether User also happens to
# be kept around for diagnostics (e.g. EXTENSION_PATH_USER_NOT_FOUND).
# That leaves (User=$null, ResolutionNote=$null) as a combination a real
# call never produces - which is exactly the "not yet even attempted"
# sentinel default used before Resolve-VSCodeTargetUser has run (see the
# early failure-envelope call sites in Invoke-SetVSCodeExtensionVersion).
# Treating that combination as a fallback (like every other unresolved
# case) - rather than as a false "no fallback, real user resolved" -
# matches this codebase's own "assume the more restrictive/isolated
# case when unsure" default philosophy (same reasoning as $dryRun's own
# safe default of $true).
function Test-VSCodeUsedSystemFallback {
  param([PSCustomObject]$TargetUser)
  return -not (($null -ne $TargetUser.User) -and ($null -eq $TargetUser.ResolutionNote))
}

function New-VSCodeFailureEnvelope {
  param(
    [string]$StartTime,
    [bool]$DryRun,
    [string]$Code,
    [string]$Message,
    # Mirrors the success envelope's own full field list - whatever of
    # these the caller had already figured out before the failure is
    # passed through as-is; anything not yet reached is left at these
    # "not yet known" defaults instead of just being absent from a
    # differently-shaped object. See Invoke-SetVSCodeExtensionVersion's
    # own default-initialized variables at the top of its try block,
    # which is what makes "whatever was already figured out" available
    # at every one of this function's call sites, early or late.
    [string]$ExtId = $null,
    [string]$TargetVersion = $null,
    [string]$ExtensionPath = $null,
    [PSCustomObject]$TargetUser = [PSCustomObject]@{ User = $null; ExtensionsDir = $null; ResolutionNote = $null },
    $OsMajor = $null,
    [PSCustomObject]$Decision = [PSCustomObject]@{ Action = $null; InstalledVersion = $null },
    $Action = $null,
    [string]$InstalledVersionAfter = $null,
    [bool]$VscodeRestarted = $false
  )
  Write-VSCodeDiag "ERROR: ${Code}: $Message"
  $envelope = [PSCustomObject]@{
    os_family                = $Script:OsFamily
    script_version           = $Script:ScriptVersion
    status                   = 'failure'
    changed                  = $false
    error                    = [PSCustomObject]@{ code = $Code; message = $Message; stderr = '' }
    dry_run                  = $DryRun
    start_time                = $StartTime
    end_time                  = (Get-VSCodeNowIso)
    metadata                  = [PSCustomObject]@{ hostname = $env:COMPUTERNAME; serial_number = (Get-VSCodeSerialNumber) }
    extension_id               = $ExtId
    target_version             = $TargetVersion
    extension_path             = $ExtensionPath
    action                     = $Decision.Action
    installed_version_before   = $Decision.InstalledVersion
    installed_version_after    = $InstalledVersionAfter
    target_user                = $TargetUser.User
    used_system_fallback       = (Test-VSCodeUsedSystemFallback $TargetUser)
    user_resolution_note       = $TargetUser.ResolutionNote
    os_major_version           = $OsMajor
    cli_result                 = (ConvertTo-VSCodeCliResultJson $Action)
    vscode_restarted            = $VscodeRestarted
  }
  return ($envelope | ConvertTo-Json -Compress -Depth 6)
}

function Invoke-SetVSCodeExtensionVersion {
  param([string]$EncodedInput)

  $startTime = Get-VSCodeNowIso
  $dryRun = $true # safe default for bare local invocation

  # Initialized here (rather than at their first assignment inside the
  # try block below) so that if an exception escapes all the way to the
  # outer catch, that catch can still report whatever of these WAS
  # figured out before the failure - reassigning a variable already
  # declared in this scope, as the try block below does, does not
  # shadow it. See New-VSCodeFailureEnvelope's own comment.
  $extId = $null
  $targetVersion = $null
  $extensionPath = $null
  $targetUser = [PSCustomObject]@{ User = $null; ExtensionsDir = $null; ResolutionNote = $null }
  $osMajor = $null
  $decision = [PSCustomObject]@{ Action = $null; InstalledVersion = $null }
  $action = $null
  $installedVersionAfter = $null
  $vscodeRestarted = $false

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
      return New-VSCodeFailureEnvelope $startTime $dryRun 'INVALID_PARAMS' 'invalid or missing extension_id (expected "<publisher>.<name>")' -ExtId $extId
    }

    $targetVersion = Get-VSCodeProp $params 'version' $null
    if ($null -ne $targetVersion) { $targetVersion = [string]$targetVersion }
    if (-not (Test-VSCodeExtensionVersion $targetVersion)) {
      return New-VSCodeFailureEnvelope $startTime $dryRun 'INVALID_PARAMS' "invalid version: $targetVersion" -ExtId $extId -TargetVersion $targetVersion
    }

    $extensionPath = Get-VSCodeProp $params 'extension_path' $null
    $targetUser = Resolve-VSCodeTargetUser $extensionPath $extId # never aborts

    $codePath = Find-VSCodeCli -TargetUser $targetUser.User
    if (-not $codePath) {
      return New-VSCodeFailureEnvelope $startTime $dryRun 'VSCODE_NOT_INSTALLED' 'code.cmd was not found in any known install location' `
        -ExtId $extId -TargetVersion $targetVersion -ExtensionPath $extensionPath -TargetUser $targetUser
    }

    $osMajor = Get-VSCodeOSMajorVersion

    $listResult = Get-VSCodeInstalledExtensionsRaw $codePath $targetUser.ExtensionsDir
    if ($listResult.ExitCode -ne 0) {
      $rawMsg = if ($listResult.Stderr) { $listResult.Stderr } elseif ($listResult.Stdout) { $listResult.Stdout } else { '' }
      return New-VSCodeFailureEnvelope $startTime $dryRun 'LIST_EXTENSIONS_FAILED' "code --list-extensions failed: $($rawMsg.Trim())" `
        -ExtId $extId -TargetVersion $targetVersion -ExtensionPath $extensionPath -TargetUser $targetUser -OsMajor $osMajor
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
      # Named distinctly from the macOS side's own `ran_as_root` field -
      # Windows always runs under SYSTEM here (RTR has no equivalent of
      # mac's `launchctl asuser` impersonation), so "ran as root" was
      # never actually true; this is really "user resolution failed and
      # we fell back to SYSTEM's own isolated extensions dir instead of
      # a resolved user's profile" (see Resolve-VSCodeTargetUser).
      used_system_fallback       = (Test-VSCodeUsedSystemFallback $targetUser)
      user_resolution_note       = $targetUser.ResolutionNote
      os_major_version           = $osMajor
      cli_result                 = (ConvertTo-VSCodeCliResultJson $action)
      vscode_restarted            = $vscodeRestarted
    }

    $json = $envelope | ConvertTo-Json -Compress -Depth 6
    Write-VSCodeDiag "RESULT: $json"
    return $json
  } catch {
    return New-VSCodeFailureEnvelope $startTime $dryRun 'UNHANDLED_ERROR' $_.Exception.Message `
      -ExtId $extId -TargetVersion $targetVersion -ExtensionPath $extensionPath -TargetUser $targetUser `
      -OsMajor $osMajor -Decision $decision -Action $action -InstalledVersionAfter $installedVersionAfter `
      -VscodeRestarted $vscodeRestarted
  }
}

# When run directly (not dot-sourced by Pester or concatenated into the
# dist script's own invocation block), print the envelope to stdout - the
# only thing this script ever writes there.
if ($MyInvocation.InvocationName -ne '.') {
  Invoke-SetVSCodeExtensionVersion -EncodedInput $args[0]
}
