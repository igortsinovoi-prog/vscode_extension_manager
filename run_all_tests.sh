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
# --rtr adds real-world checks over an actual CrowdStrike Falcon RTR
# session, on top of the direct-invocation ones above - a genuinely
# different code path (real put-file upload, a real session against a
# real sensor-enrolled device), not a re-run of the same thing: this is
# what actually surfaced two real macOS bugs neither direct invocation
# nor the mocked suites ever could (see dist/README.md's "Bugs found").
# Opt-in and additive, not a replacement - the direct-invocation stages
# still run every time, --rtr or not.
#   --platform mac-rtr: implemented, needs --device-aid and
#     FALCON_CLIENT_ID/FALCON_CLIENT_SECRET in the environment (never as a
#     flag - see real_world_check's own rtr_token() for why: argv is
#     visible in shell history and to any other process via `ps`).
#   --platform windows-rtr: NOT YET IMPLEMENTED (to be built and tested
#     next) - --rtr prints a note and skips it rather than pretending to
#     run something that doesn't exist yet.
#
# Usage:
#   ./run_all_tests.sh --host <windows-ip> --user <windows-user> (--key <path> | --password <pw>)
#   ./run_all_tests.sh --host <ip> --user <user> --key <path> \
#     --rtr --device-aid <mac-device-aid>   # + real-RTR stages (FALCON_CLIENT_ID/SECRET in env)
#
# Each stage's full output (stdout+stderr) is both shown live and saved to
# its own log file under test_logs/<timestamp>/, so a failure can be
# diagnosed from the log afterward without having to re-run anything -
# test_logs/latest always points at the most recent run.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Local-only device AIDs / Falcon API credentials for --rtr - see
# .env.local's own header and .gitignore. set -a so FALCON_CLIENT_ID/
# FALCON_CLIENT_SECRET are actually exported for the real_world_check
# child process below to see, not just set in this shell.
if [[ -f "$ROOT_DIR/.env.local" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$ROOT_DIR/.env.local"
  set +a
fi

LOG_DIR="$ROOT_DIR/test_logs/$(date +%Y%m%d_%H%M%S)"
mkdir -p "$LOG_DIR"
ln -sfn "$LOG_DIR" "$ROOT_DIR/test_logs/latest"
echo "Logging each stage to $LOG_DIR (also test_logs/latest)"

REMOTE_HOST=""
REMOTE_USER=""
REMOTE_KEY="$HOME/.ssh/utm_windows_vm"
REMOTE_PASSWORD=""
RUN_RTR=false
DEVICE_AID="${MAC_DEVICE_AID:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) REMOTE_HOST="$2"; shift 2 ;;
    --user) REMOTE_USER="$2"; shift 2 ;;
    --key) REMOTE_KEY="$2"; shift 2 ;;
    --password) REMOTE_PASSWORD="$2"; shift 2 ;;
    --rtr) RUN_RTR=true; shift ;;
    --device-aid) DEVICE_AID="$2"; shift 2 ;;
    -h|--help)
      cat <<EOF
Usage: $0 --host <windows-ip> --user <windows-user> (--key <path> | --password <pw>)
       $0 ... --rtr --device-aid <mac-device-aid>

  --rtr           Also run real-world checks over an actual CrowdStrike
                   Falcon RTR session (mac-rtr; windows-rtr not yet
                   implemented). Needs FALCON_CLIENT_ID/FALCON_CLIENT_SECRET
                   in the environment - never pass these as flags.
  --device-aid    Target device AID for the mac-rtr stage. Required with --rtr.
EOF
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

if [[ "$RUN_RTR" == true ]]; then
  if [[ -z "$DEVICE_AID" ]]; then
    echo "Error: --rtr requires --device-aid (or MAC_DEVICE_AID in .env.local) - the mac-rtr stage's target device" >&2
    exit 1
  fi
  if [[ -z "${FALCON_CLIENT_ID:-}" || -z "${FALCON_CLIENT_SECRET:-}" ]]; then
    echo "Error: --rtr requires FALCON_CLIENT_ID and FALCON_CLIENT_SECRET (in the environment, or in .env.local)" >&2
    exit 1
  fi
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

if [[ "$RUN_RTR" == true ]]; then
  run_stage "mac real-world check (mac-rtr)" "mac_rtr_real_world" \
    "$ROOT_DIR/real_world_check_set_vscode_extension_version.sh" --platform mac-rtr \
      --device-aid "$DEVICE_AID"

  echo
  echo "############################################################"
  echo "### windows-rtr real-world check: SKIPPED (not yet implemented)"
  echo "############################################################"
fi

# The mocked suites above test lib/ directly (concatenation doesn't change
# behavior, so that's real coverage) - but js_scripts/dist/ and
# ps_scripts/dist/ are only actually exercised end-to-end by the two
# real-world-check stages just above, each of which rebuilds its own dist/
# from current lib/ sources via its own build_dist step before running.
# This stage runs last, deliberately after both of those, and does no
# rebuilding of its own - it just confirms the checked-in top-level
# dist/mac/ and dist/windows/ (what actually ships) are byte-identical to
# whatever js_scripts/dist/ and ps_scripts/dist/ were left holding by the
# stages above (what was actually just built and tested) - catching a
# shipped dist/ that's silently drifted from what real-world testing
# verified, e.g. someone ran ./build.sh, edited lib/ again, and forgot to
# rebuild+recommit.
check_dist_matches_tested() {
  local status=0
  if diff -q "$ROOT_DIR/js_scripts/dist/set-vscode-extension-version.js" \
             "$ROOT_DIR/dist/mac/set-vscode-extension-version.js" >/dev/null 2>&1; then
    echo "OK: dist/mac/set-vscode-extension-version.js matches js_scripts/dist/ (the one the mac real-world check just tested)"
  else
    echo "FAILED: dist/mac/set-vscode-extension-version.js does not match js_scripts/dist/set-vscode-extension-version.js (the one the mac real-world check just tested) - run ./build.sh and commit the result." >&2
    diff "$ROOT_DIR/js_scripts/dist/set-vscode-extension-version.js" "$ROOT_DIR/dist/mac/set-vscode-extension-version.js" >&2
    status=1
  fi
  if diff -q "$ROOT_DIR/ps_scripts/dist/Set-VSCodeExtensionVersion.ps1" \
             "$ROOT_DIR/dist/windows/Set-VSCodeExtensionVersion.ps1" >/dev/null 2>&1; then
    echo "OK: dist/windows/Set-VSCodeExtensionVersion.ps1 matches ps_scripts/dist/ (the one the windows real-world check just tested)"
  else
    echo "FAILED: dist/windows/Set-VSCodeExtensionVersion.ps1 does not match ps_scripts/dist/Set-VSCodeExtensionVersion.ps1 (the one the windows real-world check just tested) - run ./build.sh and commit the result." >&2
    diff "$ROOT_DIR/ps_scripts/dist/Set-VSCodeExtensionVersion.ps1" "$ROOT_DIR/dist/windows/Set-VSCodeExtensionVersion.ps1" >&2
    status=1
  fi
  return "$status"
}
run_stage "dist/ matches what was just built and tested" "dist_matches_tested" \
  check_dist_matches_tested

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
