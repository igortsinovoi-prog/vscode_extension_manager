# GENERATED FILE - DO NOT EDIT.
# Built by ps_scripts/build.sh from:
#   lib/Set-VSCodeExtensionVersion.Policy.ps1 (decision logic, unit tested under Pester)
#   lib/Set-VSCodeExtensionVersion.Runner.ps1 (OS-interaction glue, tested via mocked Pester tests)
# Edit those source files and re-run ps_scripts/build.sh (or build.ps1), not this file.

# =====================================================================
# VS Code extension version-pin decision logic (pure, no filesystem/process
# I/O) - Windows/PowerShell port of set-vscode-extension-version-policy.js.
#
# Dot-sourced standalone under Pester (see
# ps_scripts/tests/Set-VSCodeExtensionVersion.Policy.Tests.ps1) AND
# concatenated into the deployed single-file script
# dist/Set-VSCodeExtensionVersion.ps1 via ps_scripts/build.ps1. Unlike the
# JXA original, PowerShell doesn't strictly require single-file scripts, but
# the build step keeps deployment (a single script uploaded to RTR) and
# directory layout consistent with the macOS side.
# =====================================================================

# VS Code extension ids are "<publisher>.<name>", each segment alphanumeric
# plus hyphens (e.g. "ms-python.python", "GitHub.copilot"). Same on every OS
# - this is a marketplace id format, not a filesystem concept.
$Script:ExtIdRegex = [regex]'^[A-Za-z0-9][A-Za-z0-9-]*\.[A-Za-z0-9][A-Za-z0-9-]*$'

# Standard semver, optional pre-release/build suffix.
$Script:VersionRegex = [regex]'^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$'

# Windows extension install path shape: <drive>:\Users\<username>\.vscode\extensions\<leaf>[\...]
# Case-insensitive (NTFS/ReFS are case-insensitive by default, unlike APFS on
# the macOS side). <username> restricted to the same conservative charset as
# the macOS version (alphanumeric, dot, underscore, hyphen) - real Windows
# profile directories CAN contain spaces (e.g. "C:\Users\John Doe"), so this
# is deliberately narrower than "anything NTFS allows"; a username with a
# space is rejected as INVALID_EXTENSION_PATH rather than trusted.
$Script:ExtensionPathRegex = [regex]::new(
  '^[A-Za-z]:\\Users\\([^\\]+)\\\.vscode\\extensions\\([^\\]+)(?:\\.*)?$',
  [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
)
$Script:UsernameCharsRegex = [regex]'^[A-Za-z0-9._-]+$'

function Test-VSCodeExtensionId {
  param($ExtId)
  # PowerShell's -and does NOT short-circuit (unlike JS/C#) - both operands
  # always evaluate, so IsMatch($ExtId) would run even when $ExtId is $null
  # and throw ArgumentNullException. Must type-check with an early return,
  # not a single -and expression.
  if ($ExtId -isnot [string]) { return $false }
  return $Script:ExtIdRegex.IsMatch($ExtId)
}

# $Version is OPTIONAL: $null means "no pin - upgrade to the latest version
# available", which is valid input, not an error.
function Test-VSCodeExtensionVersion {
  param($Version)
  if ($null -eq $Version) { return $true }
  if ($Version -isnot [string]) { return $false }
  return $Script:VersionRegex.IsMatch($Version)
}

# Parses `code --list-extensions --show-versions` output (one
# "<publisher>.<name>@<version>" per line) into a hashtable of
# lowercased-extension-id -> version. Blank lines and lines that don't match
# the expected shape are ignored rather than throwing, since stray warning
# lines on stdout are a known possibility for the code CLI.
function ConvertFrom-VSCodeInstalledExtensionsList {
  param($RawStdout)
  $installed = @{}
  if ($RawStdout -isnot [string]) { return $installed }
  $lines = $RawStdout -split "`r`n|`n"
  foreach ($rawLine in $lines) {
    $line = $rawLine.Trim()
    if (-not $line) { continue }
    $at = $line.LastIndexOf('@')
    if ($at -le 0) { continue }
    $id = $line.Substring(0, $at)
    $version = $line.Substring($at + 1)
    if (-not (Test-VSCodeExtensionId $id)) { continue }
    if (-not (Test-VSCodeExtensionVersion $version)) { continue }
    $installed[$id.ToLowerInvariant()] = $version
  }
  return $installed
}

# Parses and validates a VS Code extension installation path, extracting the
# Windows username it belongs to. This is how the target user is determined -
# NOT "whoever is logged into the console" - since the path (typically
# supplied by whatever detected/triggered the version drift, e.g. a file
# watch on the extension's own directory) identifies the actual affected user
# even if they aren't the one currently logged in.
#
# Expected shape: <drive>:\Users\<username>\.vscode\extensions\<leaf>[\...],
# where <leaf> is VS Code's own extension directory naming convention,
# "<publisher>.<name>-<version>[-<platform>]" - so <leaf> must start with
# "<extId>-" (case-insensitive) as a cross-check that the path actually
# corresponds to the claimed extension, not an unrelated or spoofed path.
#
# This performs STRING-LEVEL validation only (format, username charset, id
# prefix match) - it cannot check symlinks/junctions/traversal against the
# real filesystem (no I/O in this pure module). The runner additionally
# resolves the path safely against the filesystem before trusting it.
#
# Returns @{ Ok = $true; User = '<username>' } or @{ Ok = $false; Error = '<code>' }.
function Get-VSCodeExtensionPathUser {
  param($Path, $ExtId)

  if ($Path -isnot [string] -or -not $Path) {
    return [PSCustomObject]@{ Ok = $false; User = $null; Error = 'MISSING_EXTENSION_PATH' }
  }
  if ($Path.IndexOf('..') -ne -1 -or ($Path -match '[\x00-\x1f]')) {
    return [PSCustomObject]@{ Ok = $false; User = $null; Error = 'INVALID_EXTENSION_PATH' }
  }

  $m = $Script:ExtensionPathRegex.Match($Path)
  if (-not $m.Success) {
    return [PSCustomObject]@{ Ok = $false; User = $null; Error = 'INVALID_EXTENSION_PATH' }
  }
  $user = $m.Groups[1].Value
  $leaf = $m.Groups[2].Value
  if (-not $Script:UsernameCharsRegex.IsMatch($user)) {
    return [PSCustomObject]@{ Ok = $false; User = $null; Error = 'INVALID_EXTENSION_PATH' }
  }
  $idPrefix = "$($ExtId.ToString().ToLowerInvariant())-"
  if (-not $leaf.ToLowerInvariant().StartsWith($idPrefix)) {
    return [PSCustomObject]@{ Ok = $false; User = $null; Error = 'EXTENSION_PATH_ID_MISMATCH' }
  }
  return [PSCustomObject]@{ Ok = $true; User = $user; Error = $null }
}

# Pure decision function: given the currently-installed extensions map (from
# ConvertFrom-VSCodeInstalledExtensionsList), an already-validated extension
# id, and an already-validated (possibly $null) target version, decides what
# to do. Matching is case-insensitive on the extension id (VS Code ids are
# conventionally lowercase, but this is defensive either way).
#
# Returns exactly one of:
#   @{ Action = 'not_installed' }
#     - extension isn't installed at all: per spec, do nothing (never
#       installs it fresh), regardless of whether a target version was given.
#   @{ Action = 'already_correct_version'; InstalledVersion = <target> }
#     - installed and already pinned to the given target version: no-op.
#   @{ Action = 'set_version'; InstalledVersion = '<current>' }
#     - installed at a version other than the given target version: caller
#       should run `code --install-extension <id>@<targetVersion> --force`,
#       which upgrades or downgrades depending on the direction.
#   @{ Action = 'upgrade_to_latest'; InstalledVersion = '<current>' }
#     - no target version was given: caller should run
#       `code --install-extension <id> --force` (the code CLI resolves
#       "latest" against the marketplace itself - pure offline logic has no
#       way to know what that is) and compare the installed version
#       before/after to determine whether anything actually changed.
function Get-VSCodeVersionAction {
  param($InstalledExtensions, $ExtId, $TargetVersion)

  $installed = $InstalledExtensions
  if ($null -eq $installed) { $installed = @{} }
  $key = $ExtId.ToString().ToLowerInvariant()
  $current = $null
  $hasCurrent = $installed.ContainsKey($key)
  if ($hasCurrent) { $current = $installed[$key] }

  if (-not $hasCurrent) {
    return [PSCustomObject]@{ Action = 'not_installed'; InstalledVersion = $null }
  }
  if (-not $TargetVersion) {
    return [PSCustomObject]@{ Action = 'upgrade_to_latest'; InstalledVersion = $current }
  }
  if ($current -eq $TargetVersion) {
    return [PSCustomObject]@{ Action = 'already_correct_version'; InstalledVersion = $current }
  }
  return [PSCustomObject]@{ Action = 'set_version'; InstalledVersion = $current }
}

# Pure decision function: given the decision from Get-VSCodeVersionAction,
# the raw result of whatever CLI action was attempted (or $null if none was -
# i.e. Decision.Action was 'not_installed' or 'already_correct_version'), the
# installed version observed via a fresh listing AFTER that action (used for
# change-detection - relevant for 'upgrade_to_latest', where the actual
# resulting version can't be known in advance), and whether this was a dry
# run, computes the final status/changed/error fields for the RTR envelope.
# No I/O - $ActionResult is whatever the runner already collected.
#
# $ActionResult shape (or $null): @{ Attempted = bool; Ok = bool; Stderr = string }
#   Attempted is $false for a dry run (the runner skips the real CLI call).
function Get-VSCodeRunOutcome {
  param($Decision, $ActionResult, $InstalledVersionAfter, [bool]$DryRun)

  $actionFailed = $false
  if ($ActionResult -and $ActionResult.Attempted -and -not $ActionResult.Ok) {
    $actionFailed = $true
  }
  $changed = $false
  if ($ActionResult -and $ActionResult.Attempted -and $ActionResult.Ok) {
    $changed = ($InstalledVersionAfter -ne $Decision.InstalledVersion)
  }

  if ($actionFailed) {
    # Property access on an object that lacks this NoteProperty returns
    # $null (not an error) under PowerShell's default, non-strict mode.
    $stderr = $ActionResult.Stderr
    if (-not $stderr) { $stderr = '' }
    return [PSCustomObject]@{
      Status  = 'failure'
      Changed = $false
      Error   = [PSCustomObject]@{
        Code    = 'EXTENSION_VERSION_CHANGE_FAILED'
        Message = 'code --install-extension/--upgrade-extension failed'
        Stderr  = $stderr
      }
    }
  }
  if ($Decision.Action -eq 'not_installed' -or $Decision.Action -eq 'already_correct_version') {
    return [PSCustomObject]@{ Status = 'skipped'; Changed = $false; Error = $null }
  }
  if ($DryRun) {
    return [PSCustomObject]@{ Status = 'skipped'; Changed = $false; Error = $null }
  }
  return [PSCustomObject]@{ Status = 'success'; Changed = $changed; Error = $null }
}

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
    foreach ($a in $launchArgs) { $psi.ArgumentList.Add($a) }
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
      try { $proc.Kill($true) } catch {}
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
      $parsed = $originalRaw | ConvertFrom-Json -AsHashtable
      foreach ($key in $parsed.Keys) { $settings[$key] = $parsed[$key] }
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
