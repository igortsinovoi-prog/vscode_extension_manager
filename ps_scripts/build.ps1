# Concatenates each ps_scripts/lib/*.Policy.ps1 + *.Runner.ps1 pair into a
# single deployable script under ps_scripts/dist/.
#
# PowerShell doesn't strictly require single-file scripts the way JXA does,
# but RTR (and similar remote-scripting tooling) deploys a single uploaded
# script - so the source stays split for testability (Policy is pure logic,
# unit tested directly under Pester; Runner is OS-interaction glue, tested
# via mocked Pester tests) and gets concatenated here into one deployable
# file, mirroring js_scripts/build.sh's approach for the macOS/JXA side.
$ErrorActionPreference = 'Stop'

$Dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LibDir = Join-Path $Dir 'lib'
$DistDir = Join-Path $Dir 'dist'

if (Test-Path -LiteralPath $DistDir) {
  Remove-Item -LiteralPath $DistDir -Recurse -Force
}
New-Item -ItemType Directory -Path $DistDir -Force | Out-Null

$builtAny = $false
Get-ChildItem -Path $LibDir -Filter '*.Policy.ps1' | ForEach-Object {
  $policyFile = $_.FullName
  $base = $_.Name -replace '\.Policy\.ps1$', ''
  $runnerFile = Join-Path $LibDir "$base.Runner.ps1"
  if (-not (Test-Path -LiteralPath $runnerFile)) {
    Write-Error "found $policyFile but no matching $runnerFile"
  }

  $output = Join-Path $DistDir "$base.ps1"
  $header = @(
    '# GENERATED FILE - DO NOT EDIT.'
    '# Built by ps_scripts/build.ps1 from:'
    "#   lib/$base.Policy.ps1 (decision logic, unit tested under Pester)"
    "#   lib/$base.Runner.ps1 (OS-interaction glue, tested via mocked Pester tests)"
    '# Edit those source files and re-run ps_scripts/build.ps1, not this file.'
    ''
  ) -join "`r`n"

  # Comment-based help, recognized by Get-Help since only blank lines and
  # `#` comments (the GENERATED FILE banner above) precede it - lets
  # whoever's deployed this run `Get-Help .\$base.ps1 -Full` on the
  # actual uploaded file to see its own contract, without needing this
  # repo checked out. No formal top-level `param()` block exists (the
  # script reads its single positional argument via $args[0] at the
  # bottom of the Runner half, since it also has to work dot-sourced
  # with no arguments at all under Pester) - .PARAMETER below documents
  # that argument as plain help text rather than a bound/validated one.
  $help = @(
    '<#'
    '.SYNOPSIS'
    "Pins an installed VS Code extension to a specific version (or upgrades it to latest), for CrowdStrike Falcon RTR deployment."
    ''
    '.DESCRIPTION'
    'Sets an installed VS Code extension to a specific version (upgrading or'
    'downgrading as needed), or to the latest available version if no version is'
    'given. Per spec: if the extension is NOT currently installed, this script'
    'does nothing - it never installs an extension fresh.'
    ''
    'Never impersonates the target user - unlike the macOS side (which uses'
    '`launchctl asuser`), this always runs `code --extensions-dir <dir>'
    '--user-data-dir <dir>` as whatever identity launched the script (typically'
    'SYSTEM, under RTR), pointed explicitly at the resolved target user''s own'
    'profile instead.'
    ''
    '.PARAMETER EncodedInput'
    'Base64-encoded JSON, passed as this script''s first (and only) positional'
    'argument: {"params":{"extension_id":"<publisher>.<name>","version":"<optional'
    'semver>","extension_path":"<path to the extension''s installed directory>"},'
    '"dry_run":true|false}. version is optional (omit it to mean "upgrade to'
    'latest"). extension_path is used to resolve the target user - never a hard'
    'requirement, see Resolve-VSCodeTargetUser in the source for the full fallback'
    'behavior.'
    ''
    '.OUTPUTS'
    'One compact JSON object on stdout (the ActionResult envelope) - status,'
    'action, changed, target_user, vscode_restarted, and (on failure) a'
    'structured error, among other fields. Stderr is always silent; every error'
    'is reported inside the envelope, never thrown to the caller. Diagnostics'
    'are file-only, at C:\Windows\Temp\glow\rtr.txt.'
    ''
    '.EXAMPLE'
    '$json = ''{"params":{"extension_id":"ms-python.python","version":"2024.1.0",'
    '"extension_path":"C:\Users\jdoe\.vscode\extensions\ms-python.python-2024.5.0"},'
    '"dry_run":true}'''
    '$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($json))'
    ".\$base.ps1 `$b64"
    ''
    '.NOTES'
    'See this repo''s own README.md and dist/windows/README.md for full'
    'architecture details and known platform-specific behavior/limitations.'
    '#>'
    ''
  ) -join "`r`n"

  $content = $header + $help + (Get-Content -LiteralPath $policyFile -Raw) + "`r`n" + (Get-Content -LiteralPath $runnerFile -Raw)
  Set-Content -LiteralPath $output -Value $content -NoNewline -Encoding utf8
  Write-Output "Built $output"
  $builtAny = $true
}

if (-not $builtAny) {
  Write-Error "no lib/*.Policy.ps1 + *.Runner.ps1 pairs found under $LibDir."
}
