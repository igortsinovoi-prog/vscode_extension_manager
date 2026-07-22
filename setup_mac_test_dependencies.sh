#!/bin/bash
# Idempotent setup for everything this Mac needs to run the cross-platform
# test tooling in this repo (real_world_check_set_vscode_extension_version.sh
# --platform windows-remote, ps_scripts/run_all_tests.sh --target
# windows-remote, and RDP-based interactive-session testing) - safe to
# re-run any time, skips whatever's already present.
#
# Deliberately does NOT install pwsh on the Mac: ps_scripts/build.sh exists
# specifically so building the deployable Windows script never needs pwsh
# locally (see that file's header) - only the remote Windows box needs it,
# and that's handled separately by ps_scripts/bootstrap_remote_windows.ps1.
set -euo pipefail

if ! command -v brew >/dev/null 2>&1; then
  echo "Error: Homebrew not found. Install it first: https://brew.sh" >&2
  exit 1
fi

install_if_missing() {
  # $1 = brew formula/cask name, $2 = command to check for on PATH,
  # $3 = "--cask" or "" (formula)
  local pkg="$1" cmd="$2" cask_flag="$3"
  if command -v "$cmd" >/dev/null 2>&1; then
    echo "OK: $cmd already present (via $pkg), skipping."
    return
  fi
  echo "Installing $pkg..."
  # shellcheck disable=SC2086
  brew install $cask_flag "$pkg"
}

# sshpass - lets real_world_check_set_vscode_extension_version.sh and
# ps_scripts/run_all_tests.sh authenticate to the Windows VM with --password
# instead of an SSH key.
install_if_missing sshpass sshpass ""

# freerdp - gives us `xfreerdp`, a real scriptable CLI for RDP (unlike the
# GUI-only Microsoft Remote Desktop.app), needed for tests that require a
# genuine interactive Windows session (e.g. observing VS Code's background
# extension auto-update, which never runs in an SSH session - SSH lands in
# the non-interactive Session 0, not the real user's desktop session).
install_if_missing freerdp xfreerdp3 ""

# SSH keypair dedicated to the Windows test VM (key-auth alternative to
# --password). Harmless to keep even if you always use --password instead.
SSH_KEY="$HOME/.ssh/utm_windows_vm"
if [[ -f "$SSH_KEY" ]]; then
  echo "OK: SSH key already exists at $SSH_KEY, skipping."
else
  echo "Generating SSH key at $SSH_KEY..."
  ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -C "claude-code@utm-windows-vm"
  echo "Public key (add this to the Windows VM's authorized_keys, see README):"
  cat "$SSH_KEY.pub"
fi

echo
echo "All test dependencies present."
