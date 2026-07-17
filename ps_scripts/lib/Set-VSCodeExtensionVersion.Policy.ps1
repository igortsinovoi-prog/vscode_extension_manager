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
