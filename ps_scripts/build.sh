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
  # Comment-based help, recognized by Get-Help since only blank lines and
  # `#` comments (the GENERATED FILE banner above) precede it - lets
  # whoever's deployed this run `Get-Help .\Set-VSCodeExtensionVersion.ps1
  # -Full` on the actual uploaded file to see its own contract, without
  # needing this repo checked out. Must stay byte-identical to
  # build.ps1's own copy of this same block - see that file's own
  # comment on why no formal top-level `param()` block exists either.
  printf '<#\r\n'
  printf '.SYNOPSIS\r\n'
  printf 'Pins an installed VS Code extension to a specific version (or upgrades it to latest), for CrowdStrike Falcon RTR deployment.\r\n'
  printf '\r\n'
  printf '.DESCRIPTION\r\n'
  printf 'Sets an installed VS Code extension to a specific version (upgrading or\r\n'
  printf 'downgrading as needed), or to the latest available version if no version is\r\n'
  printf 'given. Per spec: if the extension is NOT currently installed, this script\r\n'
  printf 'does nothing - it never installs an extension fresh.\r\n'
  printf '\r\n'
  printf 'Never impersonates the target user - unlike the macOS side (which uses\r\n'
  printf '`launchctl asuser`), this always runs `code --extensions-dir <dir>\r\n'
  printf '%s\r\n' '--user-data-dir <dir>` as whatever identity launched the script (typically'
  printf "SYSTEM, under RTR), pointed explicitly at the resolved target user's own\r\n"
  printf 'profile instead.\r\n'
  printf '\r\n'
  printf '.PARAMETER EncodedInput\r\n'
  printf "Base64-encoded JSON, passed as this script's first (and only) positional\r\n"
  printf '%s\r\n' 'argument: {"params":{"extension_id":"<publisher>.<name>","version":"<optional'
  printf "%s\r\n" "semver>\",\"extension_path\":\"<path to the extension's installed directory>\"},"
  printf '%s\r\n' '"dry_run":true|false}. version is optional (omit it to mean "upgrade to'
  printf 'latest"). extension_path is used to resolve the target user - never a hard\r\n'
  printf 'requirement, see Resolve-VSCodeTargetUser in the source for the full fallback\r\n'
  printf 'behavior.\r\n'
  printf '\r\n'
  printf '.OUTPUTS\r\n'
  printf 'One compact JSON object on stdout (the ActionResult envelope) - status,\r\n'
  printf 'action, changed, target_user, vscode_restarted, and (on failure) a\r\n'
  printf 'structured error, among other fields. Stderr is always silent; every error\r\n'
  printf 'is reported inside the envelope, never thrown to the caller. Diagnostics\r\n'
  printf 'are file-only, at C:\\Windows\\Temp\\glow\\rtr.txt.\r\n'
  printf '\r\n'
  printf '.EXAMPLE\r\n'
  printf '%s\r\n' '$json = '"'"'{"params":{"extension_id":"ms-python.python","version":"2024.1.0",'
  printf '%s\r\n' '"extension_path":"C:\Users\jdoe\.vscode\extensions\ms-python.python-2024.5.0"},'
  printf '%s\r\n' '"dry_run":true}'"'"''
  printf '$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($json))\r\n'
  printf '.\\%s.ps1 $b64\r\n' "$BASE"
  printf '\r\n'
  printf '.NOTES\r\n'
  printf "See this repo's own README.md and dist/windows/README.md for full\r\n"
  printf 'architecture details and known platform-specific behavior/limitations.\r\n'
  printf '#>\r\n'
  printf '\r\n'
  cat "$POLICY_FILE"
  printf '\r\n'
  cat "$RUNNER_FILE"
} > "$OUTPUT"

echo "Built $OUTPUT"
