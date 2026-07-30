#!/bin/bash
# Runs the ps_scripts Pester suite (Policy.Tests.ps1 + Runner.Tests.ps1),
# either locally (if pwsh is on this machine's PATH) or remotely over SSH
# against a real Windows box - it's the same run_all_tests.ps1 either way,
# this script only decides where it executes. Mirrors
# ../real_world_check_set_vscode_extension_version.sh's --platform
# dispatch and remote-command plumbing.
#
# For --target windows, only lib/, tests/, and run_all_tests.ps1
# are copied (not the whole repo, no git required on the remote box) into
# a scratch directory under the remote user's %TEMP%, deleted again once
# the run finishes, success or failure.
#
# Usage:
#   ps_scripts/run_all_tests.sh --target local
#   ps_scripts/run_all_tests.sh --target windows --host <ip> --user <user> (--key <path> | --password <pw>)
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"  # ps_scripts/

TARGET=""
REMOTE_HOST=""
REMOTE_USER=""
REMOTE_KEY="$HOME/.ssh/utm_windows_vm"
REMOTE_PASSWORD=""
REMOTE_PORT="22"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    --host) REMOTE_HOST="$2"; shift 2 ;;
    --user) REMOTE_USER="$2"; shift 2 ;;
    --key) REMOTE_KEY="$2"; shift 2 ;;
    --password) REMOTE_PASSWORD="$2"; shift 2 ;;
    --port) REMOTE_PORT="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 --target local|windows [--host H --user U (--key K | --password P) --port P]"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ "$TARGET" == "local" ]]; then
  if ! command -v pwsh >/dev/null 2>&1; then
    echo "Error: pwsh not found on PATH. Install PowerShell 7 to run locally." >&2
    exit 1
  fi
  exec pwsh -NoProfile -File "$DIR/run_all_tests.ps1"
fi

if [[ "$TARGET" != "windows" ]]; then
  echo "Error: --target must be 'local' or 'windows'" >&2
  exit 1
fi
if [[ -z "$REMOTE_HOST" || -z "$REMOTE_USER" ]]; then
  echo "Error: --target windows requires --host and --user" >&2
  exit 1
fi

# Password auth (via sshpass) if --password was given, otherwise key auth -
# see real_world_check_set_vscode_extension_version.sh for the same pattern.
if [[ -n "$REMOTE_PASSWORD" ]]; then
  if ! command -v sshpass >/dev/null 2>&1; then
    echo "Error: --password requires sshpass (brew install sshpass)" >&2
    exit 1
  fi
  # -o Port=, not -p/-P - see real_world_check_set_vscode_extension_version.sh's
  # own comment on this same pattern: ssh and scp use different flag
  # letters for the same thing, but both accept -o for arbitrary
  # ssh_config options.
  SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o PreferredAuthentications=password -o PubkeyAuthentication=no -o "Port=$REMOTE_PORT")
  # -e (password via the SSHPASS env var), not -p - see
  # real_world_check_set_vscode_extension_version.sh's own comment on this
  # same pattern: -p crashed outright (SIGSEGV in sshpass's own
  # hide_password()) partway through a real run on this machine.
  export SSHPASS="$REMOTE_PASSWORD"
  # -eSSHPASS, not a bare -e - see
  # real_world_check_set_vscode_extension_version.sh's own comment on
  # this same pattern: the optional env-var-name argument must be
  # directly attached, or it misparses the next word (the actual command
  # to run) as the env var name instead.
  SSH_PREFIX=(sshpass -eSSHPASS ssh)
  SCP_PREFIX=(sshpass -eSSHPASS scp)
else
  SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o BatchMode=yes -i "$REMOTE_KEY" -o "Port=$REMOTE_PORT")
  SSH_PREFIX=(ssh)
  SCP_PREFIX=(scp)
fi
REMOTE="$REMOTE_USER@$REMOTE_HOST"

# See real_world_check_set_vscode_extension_version.sh for why this feeds
# scripts via stdin rather than the ssh command line: Windows OpenSSH's
# default remote shell is cmd.exe, whose quoting rules differ completely
# from bash's, and this sidesteps that mismatch entirely.
remote_ps() {
  "${SSH_PREFIX[@]}" "${SSH_OPTS[@]}" "$REMOTE" "powershell -NoProfile -Command -"
}
# Same pattern targeting pwsh directly, as its own top-level SSH command -
# used for the Pester check/install specifically, since Pester must be
# installed FROM pwsh (Windows PowerShell and pwsh use separate default
# module paths) and that only works reliably as a top-level call, not
# nested inside bootstrap_remote_windows.ps1's own stdin-fed script (see
# that file's header for what went wrong when it was nested).
remote_pwsh() {
  "${SSH_PREFIX[@]}" "${SSH_OPTS[@]}" "$REMOTE" "pwsh -NoProfile -Command -"
}

echo "=== Resolving remote scratch directory on $REMOTE_HOST ==="
REMOTE_TEMP="$(remote_ps <<'PS' | tr -d '\r'
[System.Environment]::GetEnvironmentVariable('TEMP')
PS
)"
if [[ -z "$REMOTE_TEMP" ]]; then
  echo "Error: could not resolve %TEMP% on $REMOTE_HOST" >&2
  exit 1
fi
REMOTE_DIR="$REMOTE_TEMP\\vscode_extension_manager_ps_scripts_test"
echo "Remote scratch dir: $REMOTE_DIR"

cleanup() {
  echo "=== Cleaning up remote scratch directory ==="
  remote_ps <<PS >/dev/null 2>&1 || true
Remove-Item -Recurse -Force "$REMOTE_DIR" -ErrorAction SilentlyContinue
PS
}
trap cleanup EXIT

echo "=== Bootstrapping pwsh on $REMOTE_HOST (idempotent, skips if already present) ==="
"${SSH_PREFIX[@]}" "${SSH_OPTS[@]}" "$REMOTE" "powershell -NoProfile -Command -" < "$DIR/bootstrap_remote_windows.ps1"

echo "=== Ensuring Pester 5+ on $REMOTE_HOST (idempotent, skips if already present) ==="
# The if/else branching deliberately happens here in bash, not inside a
# single piped PowerShell script: pwsh -NoProfile -Command - (unlike
# powershell.exe/5.1's equivalent) silently produces NO output at all when
# fed a multi-line control-flow block (if/else, try/catch) over stdin via
# SSH - no error, no exit code, just nothing, which would make an install
# failure indistinguishable from "already present". Each pwsh call below
# is kept to one unconditional line specifically to avoid that.
PESTER_PRESENT="$(remote_pwsh <<'PS' | tr -d '\r'
Write-Output ([bool](Get-Module -ListAvailable Pester | Where-Object { $_.Version -ge [Version]"5.0.0" }))
PS
)"
if [[ "$PESTER_PRESENT" == "True" ]]; then
  echo "Pester 5+ already present, skipping."
else
  echo "Installing Pester 5+..."
  remote_pwsh <<'PS'
Install-Module -Name Pester -MinimumVersion 5.0.0 -Force -SkipPublisherCheck -Scope CurrentUser
PS
  echo "Pester 5+ installed."
fi

echo "=== Copying lib/, tests/, run_all_tests.ps1 to $REMOTE_HOST ==="
remote_ps <<PS
New-Item -ItemType Directory -Path "$REMOTE_DIR" -Force | Out-Null
PS
"${SCP_PREFIX[@]}" -r -q "${SSH_OPTS[@]}" "$DIR/lib" "$DIR/tests" "$DIR/run_all_tests.ps1" "$REMOTE:$REMOTE_DIR/"

echo "=== Running Pester suite on $REMOTE_HOST ==="
"${SSH_PREFIX[@]}" "${SSH_OPTS[@]}" "$REMOTE" "pwsh -NoProfile -File \"$REMOTE_DIR\\run_all_tests.ps1\""
