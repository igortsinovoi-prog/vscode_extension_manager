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
    # Real, confirmed failure mode on a fresh Windows box (never seen an
    # interactive winget session before): its source index has "Updated:
    # never" and every winget operation - install, `source update`, even
    # with --disable-interactivity or after `source reset` - fails with
    # "Failed when opening source(s)" / "Cancelled", regardless of which
    # source (winget or msstore) is targeted. Not a network problem (the
    # CDN itself is reachable) and not fixable by any winget flag found -
    # fall back to installing the MSI directly from the GitHub release
    # instead of depending on winget's source machinery at all.
    Write-Output "winget install failed (exit $LASTEXITCODE) - falling back to a direct MSI install from GitHub."
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/PowerShell/PowerShell/releases/latest"
    $asset = $release.assets | Where-Object { $_.name -like "*win-x64.msi" } | Select-Object -First 1
    $msiPath = "$env:TEMP\PowerShell-win-x64.msi"
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $msiPath
    $proc = Start-Process msiexec.exe -ArgumentList "/i", $msiPath, "/quiet", "/norestart", `
      "ADD_EXPLORER_CONTEXT_MENU_OPENPOWERSHELL=0", "ADD_FILE_CONTEXT_MENU_RUNPOWERSHELL=0", `
      "ENABLE_PSREMOTING=0", "REGISTER_MANIFEST=0" -Wait -PassThru
    Remove-Item $msiPath -Force -ErrorAction SilentlyContinue
    if ($proc.ExitCode -ne 0) {
      throw "PowerShell 7 MSI install failed with exit code $($proc.ExitCode) (after winget install also failed with $LASTEXITCODE)"
    }
  }
  Write-Output "PowerShell 7 installed."
}

Write-Output "Bootstrap complete."
