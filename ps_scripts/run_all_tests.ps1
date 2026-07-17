# Runs the Pester test suite for the Windows/PowerShell VS Code extension
# version manager (ps_scripts/tests/*.Tests.ps1) - the Windows analogue of
# js_scripts/run_all_tests.sh.
#
# Requires Pester 5+ (bundled with PowerShell 5.1+ on Windows; elsewhere:
# Install-Module Pester -Scope CurrentUser -MinimumVersion 5.0.0).
#
# Unlike the macOS side, there is no --with-real-world-test flag here yet -
# a real end-to-end check against a real Windows VS Code install has to be
# written and run on an actual Windows machine, which this script's author
# did not have access to. Only the mocked suite (no real process spawned,
# no real filesystem/profile state touched) is covered so far.
$ErrorActionPreference = 'Stop'

$Dir = Split-Path -Parent $MyInvocation.MyCommand.Path

$pester = Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version -ge [Version]'5.0.0' } | Select-Object -First 1
if (-not $pester) {
  Write-Error 'Pester 5+ is required. Install it with: Install-Module Pester -Scope CurrentUser -MinimumVersion 5.0.0'
}

$config = New-PesterConfiguration
$config.Run.Path = Join-Path $Dir 'tests'
$config.Run.Exit = $true
$config.Output.Verbosity = 'Detailed'

Invoke-Pester -Configuration $config
