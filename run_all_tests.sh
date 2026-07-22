#!/bin/bash
# Single entry point for the whole repo's test surface: both platforms'
# mocked suites (js_scripts/run_all_tests.sh, ps_scripts/run_all_tests.sh
# --target windows-remote), then both platforms' real, end-to-end checks
# (real_world_check_set_vscode_extension_version.sh --platform mac /
# --platform windows-remote). This script is just an orchestrator - see
# each invoked script's own header for what it actually covers.
#
# windows-remote is used for the ps_scripts mocked suite (not --target
# local) because pwsh isn't installable on this repo's actual dev machine
# (Tier-3/macOS-12, confirmed unsupported) - the same Windows VM already
# needed for the real-world checks covers it too.
#
# Every stage runs regardless of an earlier stage's failure, so one
# broken suite doesn't hide problems in the others; see the summary
# printed at the end for a full pass/fail rundown, and the exit code
# reflects whether ALL stages passed.
#
# The mac real-world check only gets full coverage (scenario 5b's
# root-fallback identity) when run as root - run this whole script under
# sudo for that; everything else behaves the same either way.
#
# Usage:
#   ./run_all_tests.sh --host <windows-ip> --user <windows-user> (--key <path> | --password <pw>)
#
# Each stage's full output (stdout+stderr) is both shown live and saved to
# its own log file under test_logs/<timestamp>/, so a failure can be
# diagnosed from the log afterward without having to re-run anything -
# test_logs/latest always points at the most recent run.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$ROOT_DIR/test_logs/$(date +%Y%m%d_%H%M%S)"
mkdir -p "$LOG_DIR"
ln -sfn "$LOG_DIR" "$ROOT_DIR/test_logs/latest"
echo "Logging each stage to $LOG_DIR (also test_logs/latest)"

REMOTE_HOST=""
REMOTE_USER=""
REMOTE_KEY="$HOME/.ssh/utm_windows_vm"
REMOTE_PASSWORD=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) REMOTE_HOST="$2"; shift 2 ;;
    --user) REMOTE_USER="$2"; shift 2 ;;
    --key) REMOTE_KEY="$2"; shift 2 ;;
    --password) REMOTE_PASSWORD="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 --host <windows-ip> --user <windows-user> (--key <path> | --password <pw>)"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$REMOTE_HOST" || -z "$REMOTE_USER" ]]; then
  echo "Error: --host and --user are required (the Windows VM used for the windows-remote stages)" >&2
  exit 1
fi

if [[ -n "$REMOTE_PASSWORD" ]]; then
  WIN_AUTH_ARGS=(--password "$REMOTE_PASSWORD")
else
  WIN_AUTH_ARGS=(--key "$REMOTE_KEY")
fi

STAGE_NAMES=()
STAGE_RESULTS=()
STAGE_LOGS=()

run_stage() {
  # $1 = stage name, $2 = log filename slug, remaining args = command to
  # run. Deliberately not run under `set -e`: a stage's nonzero exit is
  # recorded, not fatal, so every later stage still gets a chance to run.
  local name="$1" slug="$2"; shift 2
  local log_file="$LOG_DIR/$slug.log"
  echo
  echo "############################################################"
  echo "### $name"
  echo "### (log: $log_file)"
  echo "############################################################"
  # PIPESTATUS[0] (not $?, which after a pipe reflects tee) is the actual
  # command's exit status.
  "$@" 2>&1 | tee "$log_file"
  local status=${PIPESTATUS[0]}
  if [[ "$status" -eq 0 ]]; then
    STAGE_RESULTS+=("PASS")
  else
    STAGE_RESULTS+=("FAIL")
  fi
  STAGE_NAMES+=("$name")
  STAGE_LOGS+=("$log_file")
}

run_stage "mac mocked suite (js_scripts)" "mac_mocked" \
  "$ROOT_DIR/js_scripts/run_all_tests.sh"

run_stage "windows mocked suite (ps_scripts, windows-remote)" "windows_mocked" \
  "$ROOT_DIR/ps_scripts/run_all_tests.sh" --target windows-remote \
    --host "$REMOTE_HOST" --user "$REMOTE_USER" "${WIN_AUTH_ARGS[@]}"

run_stage "mac real-world check" "mac_real_world" \
  "$ROOT_DIR/real_world_check_set_vscode_extension_version.sh" --platform mac

run_stage "windows real-world check (windows-remote)" "windows_real_world" \
  "$ROOT_DIR/real_world_check_set_vscode_extension_version.sh" --platform windows-remote \
    --host "$REMOTE_HOST" --user "$REMOTE_USER" "${WIN_AUTH_ARGS[@]}"

echo
echo "############################################################"
echo "### Summary"
echo "############################################################"
overall_status=0
for i in "${!STAGE_NAMES[@]}"; do
  printf '  %-4s %-45s %s\n' "${STAGE_RESULTS[$i]}" "${STAGE_NAMES[$i]}" "${STAGE_LOGS[$i]}"
  [[ "${STAGE_RESULTS[$i]}" == "FAIL" ]] && overall_status=1
done
exit "$overall_status"
