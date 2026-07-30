#!/bin/bash
# Single entry point for the whole repo's test surface: both platforms'
# mocked suites (js_scripts/run_all_tests.sh, ps_scripts/run_all_tests.sh
# --target windows), then both platforms' real, end-to-end checks
# (real_world_check_set_vscode_extension_version.sh --platform mac /
# --platform windows). This script is just an orchestrator - see
# each invoked script's own header for what it actually covers.
#
# Windows targets are named and declared in .env.local (WIN_TARGETS, plus
# a <NAME>_HOST/_USER/_PORT/_PASSWORD|_KEY/_DEVICE_AID block per name) -
# not hardcoded here. Add a third Windows box later by adding one line to
# WIN_TARGETS and one block, no script changes. --targets selects which
# of mac / the configured Windows names to actually run this invocation
# (default: all of them). This is also why the windows mocked suite runs
# per target here (not --target local): pwsh isn't installable on this
# repo's actual dev machine (Tier-3/macOS-12, confirmed unsupported), so
# each configured Windows box covers its own mocked-suite run too.
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
# nor the mocked suites ever could (see dist/mac/README.md's "Build log").
# Opt-in and additive, not a replacement - the direct-invocation stages
# still run every time, --rtr or not. Per selected target: if --rtr is
# passed but that target has no DEVICE_AID configured, its -rtr stage is
# SKIPPED with a note (not a hard error) - so `--rtr --targets all` still
# runs fine when only some targets have a sensor enrolled yet.
#
# Usage:
#   ./run_all_tests.sh [--targets mac,win10,win11,...|all] [--rtr]
#
#   --targets   Comma-separated, case-insensitive: "mac", any name from
#               .env.local's WIN_TARGETS, or "all" (default).
#   --rtr       Also run each selected target's -rtr stage (mac-rtr /
#               <name>-rtr), where a device AID is configured for it.
#
# Each stage's full output (stdout+stderr) is both shown live and saved to
# its own log file under test_logs/<timestamp>/, so a failure can be
# diagnosed from the log afterward without having to re-run anything -
# test_logs/latest always points at the most recent run.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Local-only device AIDs / per-target connection details / Falcon API
# credentials - see .env.local's own header and .gitignore. set -a so
# everything (FALCON_CLIENT_ID/SECRET, WIN_TARGETS, WIN10_HOST, ...) is
# actually exported for the real_world_check/ps_scripts child processes
# below to see, not just set in this shell.
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

TARGETS_ARG="all"
RUN_RTR=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --targets) TARGETS_ARG="$2"; shift 2 ;;
    --rtr) RUN_RTR=true; shift ;;
    -h|--help)
      cat <<EOF
Usage: $0 [--targets mac,win10,win11,...|all] [--rtr]

  --targets   Comma-separated, case-insensitive: "mac", any name from
              .env.local's WIN_TARGETS, or "all" (default = mac + every
              configured Windows target).
  --rtr       Also run real-world checks over an actual CrowdStrike
              Falcon RTR session (mac-rtr / <name>-rtr) for each selected
              target that has a device AID configured (MAC_DEVICE_AID /
              <NAME>_DEVICE_AID in .env.local) - skipped with a note,
              not an error, for any selected target that doesn't.
EOF
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

# Normalize to lowercase for matching (portable - this repo's dev
# machine's default /bin/bash is 3.2, so ${var,,} isn't available).
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }

TARGETS_ARG_LOWER="$(lower "$TARGETS_ARG")"
WIN_TARGETS_LOWER="$(lower "${WIN_TARGETS:-}")"

target_selected() {
  # $1 = "mac" or a lowercase win target name
  [[ "$TARGETS_ARG_LOWER" == "all" ]] && return 0
  [[ ",$TARGETS_ARG_LOWER," == *",$1,"* ]]
}

if [[ -z "$WIN_TARGETS_LOWER" && "$TARGETS_ARG_LOWER" != "mac" ]]; then
  echo "Note: no WIN_TARGETS configured in .env.local - only mac stages will run." >&2
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

skip_stage() {
  # $1 = stage name, $2 = reason - recorded in the summary as SKIP, not
  # counted against the overall exit status.
  local name="$1" reason="$2"
  echo
  echo "############################################################"
  echo "### $name: SKIPPED ($reason)"
  echo "############################################################"
  STAGE_NAMES+=("$name")
  STAGE_RESULTS+=("SKIP")
  STAGE_LOGS+=("-")
}

if target_selected "mac"; then
  run_stage "mac mocked suite (js_scripts)" "mac_mocked" \
    "$ROOT_DIR/js_scripts/run_all_tests.sh"

  run_stage "mac real-world check" "mac_real_world" \
    "$ROOT_DIR/real_world_check_set_vscode_extension_version.sh" --platform mac

  if [[ "$RUN_RTR" == true ]]; then
    if [[ -n "${MAC_DEVICE_AID:-}" && -n "${FALCON_CLIENT_ID:-}" && -n "${FALCON_CLIENT_SECRET:-}" ]]; then
      run_stage "mac real-world check (mac-rtr)" "mac_rtr_real_world" \
        "$ROOT_DIR/real_world_check_set_vscode_extension_version.sh" --platform mac-rtr \
          --device-aid "$MAC_DEVICE_AID"
    else
      skip_stage "mac real-world check (mac-rtr)" "MAC_DEVICE_AID and/or FALCON_CLIENT_ID/FALCON_CLIENT_SECRET not set in .env.local"
    fi
  fi
fi

for name in $WIN_TARGETS_LOWER; do
  target_selected "$name" || continue

  prefix="$(upper "$name")"
  host_var="${prefix}_HOST"; user_var="${prefix}_USER"
  port_var="${prefix}_PORT"; password_var="${prefix}_PASSWORD"
  key_var="${prefix}_KEY"; aid_var="${prefix}_DEVICE_AID"
  host="${!host_var:-}"; user="${!user_var:-}"
  port="${!port_var:-22}"; password="${!password_var:-}"
  key="${!key_var:-}"; aid="${!aid_var:-}"

  if [[ -z "$host" || -z "$user" ]]; then
    echo "Error: target '$name' is missing ${host_var}/${user_var} in .env.local" >&2
    exit 1
  fi
  if [[ -z "$password" && -z "$key" ]]; then
    echo "Error: target '$name' needs either ${password_var} or ${key_var} in .env.local" >&2
    exit 1
  fi

  if [[ -n "$password" ]]; then
    auth_args=(--password "$password")
  else
    auth_args=(--key "$key")
  fi

  run_stage "windows mocked suite ($name, windows)" "${name}_mocked" \
    "$ROOT_DIR/ps_scripts/run_all_tests.sh" --target windows \
      --host "$host" --user "$user" --port "$port" "${auth_args[@]}"

  run_stage "windows real-world check ($name, windows)" "${name}_real_world" \
    "$ROOT_DIR/real_world_check_set_vscode_extension_version.sh" --platform windows \
      --host "$host" --user "$user" --port "$port" "${auth_args[@]}"

  if [[ "$RUN_RTR" == true ]]; then
    if [[ -n "$aid" && -n "${FALCON_CLIENT_ID:-}" && -n "${FALCON_CLIENT_SECRET:-}" ]]; then
      run_stage "windows real-world check ($name, windows-rtr)" "${name}_rtr_real_world" \
        "$ROOT_DIR/real_world_check_set_vscode_extension_version.sh" --platform windows-rtr \
          --host "$host" --user "$user" --port "$port" "${auth_args[@]}" --device-aid "$aid"
    else
      skip_stage "windows real-world check ($name, windows-rtr)" "${aid_var} and/or FALCON_CLIENT_ID/FALCON_CLIENT_SECRET not set in .env.local"
    fi
  fi
done

# The mocked suites above test lib/ directly (concatenation doesn't change
# behavior, so that's real coverage) - but js_scripts/dist/ and
# ps_scripts/dist/ are only actually exercised end-to-end by the real-
# world-check stages above, each of which rebuilds its own dist/ from
# current lib/ sources via its own build_dist step before running. This
# stage runs last, deliberately after all of those, and does no
# rebuilding of its own - it just confirms the checked-in top-level
# dist/mac/ and dist/windows/ (what actually ships) are byte-identical to
# whatever js_scripts/dist/ and ps_scripts/dist/ were left holding by the
# stages above (what was actually just built and tested) - catching a
# shipped dist/ that's silently drifted from what real-world testing
# verified, e.g. someone ran ./build.sh, edited lib/ again, and forgot to
# rebuild+recommit. Only meaningful if at least one mac/windows real-world
# stage actually ran this invocation.
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
    echo "OK: dist/windows/Set-VSCodeExtensionVersion.ps1 matches ps_scripts/dist/ (the one the windows real-world check(s) just tested)"
  else
    echo "FAILED: dist/windows/Set-VSCodeExtensionVersion.ps1 does not match ps_scripts/dist/Set-VSCodeExtensionVersion.ps1 (the one the windows real-world check(s) just tested) - run ./build.sh and commit the result." >&2
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
