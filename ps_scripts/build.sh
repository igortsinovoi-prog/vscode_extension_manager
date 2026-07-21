#!/bin/bash
# Builds ps_scripts/dist/Set-VSCodeExtensionVersion.ps1 from
# lib/Set-VSCodeExtensionVersion.{Policy,Runner}.ps1 - a bash equivalent of
# ps_scripts/build.ps1 producing the same output, for machines without pwsh
# (e.g. building on a Mac to deploy onto a remote Windows box - see
# ../real_world_check_set_vscode_extension_version.sh --platform
# windows-remote, which calls this). The build step itself is plain text
# concatenation, no PowerShell-specific behavior, so it doesn't need pwsh
# at all. Prefer ps_scripts/build.ps1 when running natively on
# Windows/pwsh; this exists purely so the build step also works without it.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$DIR/lib"
DIST_DIR="$DIR/dist"
BASE="Set-VSCodeExtensionVersion"

POLICY_FILE="$LIB_DIR/$BASE.Policy.ps1"
RUNNER_FILE="$LIB_DIR/$BASE.Runner.ps1"

if [[ ! -f "$POLICY_FILE" ]]; then
  echo "Error: $POLICY_FILE not found" >&2
  exit 1
fi
if [[ ! -f "$RUNNER_FILE" ]]; then
  echo "Error: found $POLICY_FILE but no matching $RUNNER_FILE" >&2
  exit 1
fi

if [[ -e "$DIST_DIR" ]]; then
  rm -rf "$DIST_DIR"
fi
mkdir -p "$DIST_DIR"

OUTPUT="$DIST_DIR/$BASE.ps1"
{
  printf '# GENERATED FILE - DO NOT EDIT.\r\n'
  printf '# Built by ps_scripts/build.sh from:\r\n'
  printf '#   lib/%s.Policy.ps1 (decision logic, unit tested under Pester)\r\n' "$BASE"
  printf '#   lib/%s.Runner.ps1 (OS-interaction glue, tested via mocked Pester tests)\r\n' "$BASE"
  printf '# Edit those source files and re-run ps_scripts/build.sh (or build.ps1), not this file.\r\n'
  printf '\r\n'
  cat "$POLICY_FILE"
  printf '\r\n'
  cat "$RUNNER_FILE"
} > "$OUTPUT"

echo "Built $OUTPUT"
