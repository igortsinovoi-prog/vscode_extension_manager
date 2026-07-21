# Idempotent Windows-side setup: ensures PowerShell 7 (pwsh) is present.
# Deliberately does NOT also handle Pester here - see run_all_tests.sh,
# which ensures Pester via a separate, TOP-LEVEL `pwsh -NoProfile
# -Command -` SSH call once pwsh is confirmed installed. Nesting that
# inside this already-stdin-fed script (piping a second script into a
# child pwsh process from within it) was tried first and doesn't reliably
# work - the child's output/exit-code handling gets lost somewhere in the
# double indirection, even though the exact same command works fine as a
# top-level SSH call. Simpler to keep this script doing exactly one thing.
#
# No git, no repo clone - the actual files needed (either the built dist/
# script, or lib/+tests/+run_all_tests.ps1) are copied in separately by
# whichever caller piped this in.
#
# Piped over SSH into `powershell -NoProfile -Command -` - never run
# directly by a person, though nothing stops you.
#
# Must stay compatible with Windows PowerShell 5.1 syntax: that's what
# ships by default on a stock Windows install, and pwsh itself may not
# exist yet the first time this runs - that's exactly what it installs.
$ErrorActionPreference = 'Stop'

if (Get-Command pwsh -ErrorAction SilentlyContinue) {
  Write-Output "pwsh already present, skipping."
} else {
  Write-Output "Installing PowerShell 7 via winget..."
  winget install --id Microsoft.PowerShell -e --silent --accept-package-agreements --accept-source-agreements
  if ($LASTEXITCODE -ne 0) {
    throw "winget install Microsoft.PowerShell failed with exit code $LASTEXITCODE"
  }
  Write-Output "PowerShell 7 installed."
}

Write-Output "Bootstrap complete."
