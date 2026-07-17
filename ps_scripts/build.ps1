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

  $content = $header + (Get-Content -LiteralPath $policyFile -Raw) + "`r`n" + (Get-Content -LiteralPath $runnerFile -Raw)
  Set-Content -LiteralPath $output -Value $content -NoNewline -Encoding utf8
  Write-Output "Built $output"
  $builtAny = $true
}

if (-not $builtAny) {
  Write-Error "no lib/*.Policy.ps1 + *.Runner.ps1 pairs found under $LibDir."
}
