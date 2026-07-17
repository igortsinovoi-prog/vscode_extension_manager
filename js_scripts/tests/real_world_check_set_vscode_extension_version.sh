#!/bin/bash
# Real end-to-end check against a real, small, well-known VS Code extension
# (njpwerner.autodocstring - "Python Docstring Generator") on this machine,
# running the actual built dist/set-vscode-extension-version.js via
# osascript - not a mock. Not part of run_js_tests.sh (that's mocked and
# safe to run anywhere); this one really installs/uninstalls a real
# extension, so it's opt-in, manual, and self-cleaning: the extension's
# original install state (present at some version, or absent) is captured
# up front and restored on exit, regardless of pass/fail.
#
# Scenario 1: extension removed -> must no-op (never installs it fresh).
# Scenario 2: extension present, requested version 0.4.0 -> must downgrade
#             to exactly 0.4.0 from whatever "latest" is.
# Scenario 3: extension at 0.4.0, no version requested -> must upgrade to
#             latest.
# Scenario 4: extension at 0.4.0, requested version 0.4.0 (same) -> no-op
#             (already_correct_version), no CLI action taken.
# Scenario 5: extension_path user resolution, both branches for real (not
#             mocked): (a) a path naming the real current user resolves and
#             runs as that user; (b) a path naming a nonexistent user falls
#             back to running as root, WITHOUT touching the real user's
#             actual extension state.
# Scenario 6: dry_run:true on a real pending change -> envelope says
#             skipped/not changed AND the real installed version is
#             independently confirmed unchanged afterward.
# Scenario 7: invalid extension_id -> real INVALID_PARAMS failure envelope.
# Scenario 8: invalid version string -> real INVALID_PARAMS failure envelope.
# Scenario 9: well-formed but nonexistent version -> real `code
#             --install-extension` failure, captured as
#             EXTENSION_VERSION_CHANGE_FAILED with real stderr, installed
#             version left unchanged.
# Scenario 10: extension_path omitted entirely -> MISSING_EXTENSION_PATH,
#              run still proceeds (never aborts).
# Scenario 11: malformed extension_path -> INVALID_EXTENSION_PATH.
# Scenario 12: extension_path naming a different extension's directory ->
#              EXTENSION_PATH_ID_MISMATCH.
# Scenario 13: extension_id passed in a different case than how VS Code's
#              own --list-extensions reports it -> still resolves/matches
#              correctly against the real installed-extensions list.
# Scenario 14: extension_path is a real symlink escaping
#              ~/.vscode/extensions -> EXTENSION_PATH_UNSAFE.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"  # js_scripts/
EXT_ID="njpwerner.autodocstring"
CODE_BIN="/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
DIST_SCRIPT="$DIR/dist/set-vscode-extension-version.js"
# Under sudo, $(whoami) reports "root" (the effective user), not the account
# whose ~/.vscode/extensions this check actually operates on - use
# $SUDO_USER (the invoking account) when running under sudo.
REAL_USER="${SUDO_USER:-$(whoami)}"
if [[ "$EUID" -eq 0 ]]; then
  IS_ROOT=true
else
  IS_ROOT=false
fi
USER_EXTENSION_PATH="$HOME/.vscode/extensions/${EXT_ID}-0.0.0"  # shape only; leaf need not exist
NO_SUCH_USER_PATH="/Users/glow_test_no_such_user/.vscode/extensions/${EXT_ID}-0.0.0"
MISMATCHED_ID_PATH="$HOME/.vscode/extensions/some-other.extension-0.0.0"
SYMLINK_TARGET="/tmp/glow_test_evil_target"
SYMLINK_PATH="$HOME/.vscode/extensions/${EXT_ID}-9.9.9-symlinktest"

if [[ ! -x "$CODE_BIN" ]]; then
  echo "Error: VS Code CLI not found at $CODE_BIN" >&2
  exit 1
fi

get_installed_version() {
  "$CODE_BIN" --list-extensions --show-versions 2>/dev/null \
    | grep -i "^${EXT_ID}@" | sed -E "s/^[^@]+@//" || true
}

set_installed_version() {
  # $1 = exact version to force-install
  "$CODE_BIN" --install-extension "${EXT_ID}@${1}" --force >/dev/null 2>&1
}

run_script() {
  # $1 = version ("" for none), $2 = dry_run ("true"/"false"), $3 = extension_path
  local version="$1" dry_run="$2" ext_path="$3"
  local payload
  payload="$(python3 - "$EXT_ID" "$version" "$ext_path" "$dry_run" <<'PY'
import base64, json, sys
ext_id, version, ext_path, dry_run = sys.argv[1:5]
params = {"extension_id": ext_id, "extension_path": ext_path}
if version:
    params["version"] = version
payload = {"params": params, "dry_run": dry_run == "true"}
print(base64.b64encode(json.dumps(payload).encode()).decode())
PY
  )"
  osascript -l JavaScript "$DIST_SCRIPT" "$payload"
}

run_script_raw() {
  # $1 = extension_id ("" to omit), $2 = version ("" for none), $3 = extension_path
  # ("" to omit), $4 = dry_run ("true"/"false"). Unlike run_script, every param
  # is independently omittable - needed to exercise the invalid/missing-param
  # real failure paths, not just the happy path fixed on $EXT_ID.
  local ext_id="$1" version="$2" ext_path="$3" dry_run="$4"
  local payload
  payload="$(python3 - "$ext_id" "$version" "$ext_path" "$dry_run" <<'PY'
import base64, json, sys
ext_id, version, ext_path, dry_run = sys.argv[1:5]
params = {}
if ext_id:
    params["extension_id"] = ext_id
if ext_path:
    params["extension_path"] = ext_path
if version:
    params["version"] = version
payload = {"params": params, "dry_run": dry_run == "true"}
print(base64.b64encode(json.dumps(payload).encode()).decode())
PY
  )"
  osascript -l JavaScript "$DIST_SCRIPT" "$payload"
}

field() {
  # $1 = JSON envelope, $2 = field name -> prints its value as a Python repr-ish string
  python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get(sys.argv[2]))' "$1" "$2"
}

nested_field() {
  # $1 = JSON envelope, $2 = outer field, $3 = inner field, e.g. "error" "code"
  python3 -c '
import json, sys
env, outer, inner = sys.argv[1], sys.argv[2], sys.argv[3]
v = json.loads(env).get(outer) or {}
print(v.get(inner))
' "$1" "$2" "$3"
}

PASS=0
FAIL=0

check() {
  # $1 = description, $2 = actual, $3 = expected
  if [[ "$2" == "$3" ]]; then
    echo "  OK: $1"
    PASS=$((PASS + 1))
  else
    echo "  FAILED: $1 (expected '$3', got '$2')"
    FAIL=$((FAIL + 1))
  fi
}

skip() {
  # $1 = description, $2 = reason. Not counted as pass or fail.
  echo "  SKIPPED: $1 ($2)"
}

echo "==> Building latest dist/set-vscode-extension-version.js"
"$DIR/build.sh"

echo "==> Capturing original state of $EXT_ID"
ORIGINAL_VERSION="$(get_installed_version)"
if [[ -n "$ORIGINAL_VERSION" ]]; then
  echo "    Currently installed at $ORIGINAL_VERSION"
else
  echo "    Currently not installed"
fi

restore_original_state() {
  echo
  echo "==> Cleaning up test artifacts"
  rm -f "$SYMLINK_PATH"
  rmdir "$SYMLINK_TARGET" 2>/dev/null || true

  echo "==> Restoring original state of $EXT_ID"
  if [[ -n "$ORIGINAL_VERSION" ]]; then
    "$CODE_BIN" --install-extension "${EXT_ID}@${ORIGINAL_VERSION}" --force >/dev/null 2>&1 || \
      echo "    WARNING: failed to restore ${EXT_ID}@${ORIGINAL_VERSION}"
  else
    "$CODE_BIN" --uninstall-extension "$EXT_ID" >/dev/null 2>&1 || true
  fi
  local final
  final="$(get_installed_version)"
  echo "    Now: ${final:-not installed}"
}
trap restore_original_state EXIT

echo
echo "=== Scenario 1: extension removed -> must no-op ==="
"$CODE_BIN" --uninstall-extension "$EXT_ID" >/dev/null 2>&1 || true
check "extension is not installed before the run" "$(get_installed_version)" ""

result="$(run_script "0.4.0" "false" "$USER_EXTENSION_PATH")"
echo "  envelope: $result"
check "action is not_installed" "$(field "$result" action)" "not_installed"
check "status is skipped" "$(field "$result" status)" "skipped"
check "changed is false" "$(field "$result" changed)" "False"
check "extension is still not installed after the run" "$(get_installed_version)" ""

echo
echo "=== Scenario 2: extension present, requested version 0.4.0 -> must set to 0.4.0 ==="
"$CODE_BIN" --install-extension "$EXT_ID" >/dev/null 2>&1
before_version="$(get_installed_version)"
echo "  Installed latest: $before_version"
LATEST_VERSION="$before_version"
if [[ "$before_version" == "0.4.0" ]]; then
  echo "  NOTE: latest happens to already be 0.4.0 - the 'downgrade' below is actually a no-op."
fi

result="$(run_script "0.4.0" "false" "$USER_EXTENSION_PATH")"
echo "  envelope: $result"
check "status is success or skipped (already-correct edge case)" \
  "$(python3 -c "print('$(field "$result" status)' in ('success','skipped'))")" "True"
check "envelope reports installed_version_after == 0.4.0" "$(field "$result" installed_version_after)" "0.4.0"
check "code --list-extensions independently confirms version 0.4.0" "$(get_installed_version)" "0.4.0"

echo
echo "=== Scenario 3: extension at 0.4.0, no version requested -> must upgrade to latest ($LATEST_VERSION) ==="
set_installed_version "0.4.0"
check "extension is at 0.4.0 before the run" "$(get_installed_version)" "0.4.0"

result="$(run_script "" "false" "$USER_EXTENSION_PATH")"
echo "  envelope: $result"
check "action is upgrade_to_latest" "$(field "$result" action)" "upgrade_to_latest"
check "status is success" "$(field "$result" status)" "success"
check "changed is true" "$(field "$result" changed)" "True"
check "envelope reports installed_version_after == $LATEST_VERSION" "$(field "$result" installed_version_after)" "$LATEST_VERSION"
check "code --list-extensions independently confirms version $LATEST_VERSION" "$(get_installed_version)" "$LATEST_VERSION"

echo
echo "=== Scenario 4: extension at 0.4.0, requested version 0.4.0 (same) -> must no-op ==="
set_installed_version "0.4.0"
check "extension is at 0.4.0 before the run" "$(get_installed_version)" "0.4.0"

result="$(run_script "0.4.0" "false" "$USER_EXTENSION_PATH")"
echo "  envelope: $result"
check "action is already_correct_version" "$(field "$result" action)" "already_correct_version"
check "status is skipped" "$(field "$result" status)" "skipped"
check "changed is false" "$(field "$result" changed)" "False"
check "cli_result is null (no CLI action taken)" "$(field "$result" cli_result)" "None"
check "extension is still at 0.4.0 after the run" "$(get_installed_version)" "0.4.0"

echo
echo "=== Scenario 5a: extension_path names the real current user -> resolves and runs as that user ==="
set_installed_version "0.4.0"
result="$(run_script "" "false" "$USER_EXTENSION_PATH")"
echo "  envelope: $result"
check "target_user is $REAL_USER" "$(field "$result" target_user)" "$REAL_USER"
check "ran_as_root is false" "$(field "$result" ran_as_root)" "False"
check "user_resolution_note is null" "$(field "$result" user_resolution_note)" "None"
check "code --list-extensions independently confirms version $LATEST_VERSION" "$(get_installed_version)" "$LATEST_VERSION"

echo
echo "=== Scenario 5b: extension_path names a nonexistent user -> falls back to root ==="
if [[ "$IS_ROOT" != true ]]; then
  echo "  NOTE: not running as root (re-run with 'sudo ${BASH_SOURCE[0]}' for the full check)."
  echo "        ran_as_root:true only means the script skips 'launchctl asuser' -"
  echo "        the process still runs as whichever user invoked osascript. Without"
  echo "        sudo, that's $REAL_USER, so the CLI call below legitimately lands"
  echo "        back in $REAL_USER's own ~/.vscode/extensions - it is NOT a bug."
fi
set_installed_version "0.4.0"
check "extension is at 0.4.0 before the run" "$(get_installed_version)" "0.4.0"

result="$(run_script "$LATEST_VERSION" "false" "$NO_SUCH_USER_PATH")"
echo "  envelope: $result"
check "target_user is glow_test_no_such_user" "$(field "$result" target_user)" "glow_test_no_such_user"
check "ran_as_root is true" "$(field "$result" ran_as_root)" "True"
check "user_resolution_note is EXTENSION_PATH_USER_NOT_FOUND" \
  "$(field "$result" user_resolution_note)" "EXTENSION_PATH_USER_NOT_FOUND"
if [[ "$IS_ROOT" == true ]]; then
  check "real user's installed version is untouched by the root-fallback run (only meaningful under sudo)" \
    "$(get_installed_version)" "0.4.0"
else
  skip "real user's installed version is untouched by the root-fallback run" \
    "only meaningful when this script itself runs as root; re-run with sudo to verify"
  set_installed_version "0.4.0" # undo the side effect this non-root run just caused, before restore
fi

echo
echo "=== Scenario 6: dry_run:true on a real pending change -> must not touch real state ==="
set_installed_version "$LATEST_VERSION"
check "extension is at latest ($LATEST_VERSION) before the run" "$(get_installed_version)" "$LATEST_VERSION"

result="$(run_script "0.4.0" "true" "$USER_EXTENSION_PATH")"
echo "  envelope: $result"
check "action is set_version" "$(field "$result" action)" "set_version"
check "status is skipped" "$(field "$result" status)" "skipped"
check "changed is false" "$(field "$result" changed)" "False"
check "dry_run is true" "$(field "$result" dry_run)" "True"
check "real installed version is still $LATEST_VERSION (dry run must not touch it)" \
  "$(get_installed_version)" "$LATEST_VERSION"

echo
echo "=== Scenario 7: invalid extension_id -> real INVALID_PARAMS failure ==="
result="$(run_script_raw "not-an-id" "" "$USER_EXTENSION_PATH" "false")"
echo "  envelope: $result"
check "status is failure" "$(field "$result" status)" "failure"
check "error.code is INVALID_PARAMS" "$(nested_field "$result" error code)" "INVALID_PARAMS"
check "real extension state is untouched (still $LATEST_VERSION)" "$(get_installed_version)" "$LATEST_VERSION"

echo
echo "=== Scenario 8: invalid version string -> real INVALID_PARAMS failure ==="
result="$(run_script_raw "$EXT_ID" "not-a-version" "$USER_EXTENSION_PATH" "false")"
echo "  envelope: $result"
check "status is failure" "$(field "$result" status)" "failure"
check "error.code is INVALID_PARAMS" "$(nested_field "$result" error code)" "INVALID_PARAMS"
check "real extension state is untouched (still $LATEST_VERSION)" "$(get_installed_version)" "$LATEST_VERSION"

echo
echo "=== Scenario 9: well-formed but nonexistent version -> real CLI failure ==="
set_installed_version "0.4.0"
check "extension is at 0.4.0 before the run" "$(get_installed_version)" "0.4.0"

result="$(run_script "99.99.99" "false" "$USER_EXTENSION_PATH")"
echo "  envelope: $result"
check "action is set_version" "$(field "$result" action)" "set_version"
check "status is failure" "$(field "$result" status)" "failure"
check "changed is false" "$(field "$result" changed)" "False"
check "error.code is EXTENSION_VERSION_CHANGE_FAILED" "$(nested_field "$result" error code)" "EXTENSION_VERSION_CHANGE_FAILED"
check "error.stderr is non-empty (real captured CLI failure output)" \
  "$(python3 -c 'import json,sys; print(bool((json.loads(sys.argv[1]).get("error") or {}).get("stderr")))' "$result")" "True"
check "real installed version is unchanged (still 0.4.0)" "$(get_installed_version)" "0.4.0"

echo
echo "=== Scenario 10: extension_path omitted entirely -> must not abort ==="
set_installed_version "0.4.0"
result="$(run_script_raw "$EXT_ID" "0.4.0" "" "false")"
echo "  envelope: $result"
check "target_user is null" "$(field "$result" target_user)" "None"
check "ran_as_root is true" "$(field "$result" ran_as_root)" "True"
check "user_resolution_note is MISSING_EXTENSION_PATH" "$(field "$result" user_resolution_note)" "MISSING_EXTENSION_PATH"
# Root's own isolated identity (HOME=/var/root) has no VS Code extensions of
# its own, regardless of what $REAL_USER has installed - so this genuinely
# reports not_installed, not already_correct_version.
check "run still proceeds: action is not_installed (root's own identity has no extensions installed)" \
  "$(field "$result" action)" "not_installed"
check "run still proceeds: status is skipped (not failure)" "$(field "$result" status)" "skipped"

echo
echo "=== Scenario 11: malformed extension_path -> INVALID_EXTENSION_PATH ==="
result="$(run_script "0.4.0" "false" "/tmp/not/a/valid/vscode/path")"
echo "  envelope: $result"
check "user_resolution_note is INVALID_EXTENSION_PATH" "$(field "$result" user_resolution_note)" "INVALID_EXTENSION_PATH"
check "target_user is null" "$(field "$result" target_user)" "None"
check "ran_as_root is true" "$(field "$result" ran_as_root)" "True"
check "run still proceeds: status is skipped (not failure)" "$(field "$result" status)" "skipped"

echo
echo "=== Scenario 12: extension_path names a different extension's directory -> EXTENSION_PATH_ID_MISMATCH ==="
result="$(run_script "0.4.0" "false" "$MISMATCHED_ID_PATH")"
echo "  envelope: $result"
check "user_resolution_note is EXTENSION_PATH_ID_MISMATCH" "$(field "$result" user_resolution_note)" "EXTENSION_PATH_ID_MISMATCH"
check "target_user is null" "$(field "$result" target_user)" "None"
check "ran_as_root is true" "$(field "$result" ran_as_root)" "True"
check "run still proceeds: status is skipped (not failure)" "$(field "$result" status)" "skipped"

echo
echo "=== Scenario 13: extension_id in a different case than VS Code reports it -> still resolves ==="
set_installed_version "0.4.0"
check "extension is at 0.4.0 before the run" "$(get_installed_version)" "0.4.0"

EXT_ID_UPPER="$(echo "$EXT_ID" | tr '[:lower:]' '[:upper:]')"
result="$(run_script_raw "$EXT_ID_UPPER" "0.4.0" "$USER_EXTENSION_PATH" "false")"
echo "  envelope: $result"
check "action is already_correct_version (matched despite case difference)" "$(field "$result" action)" "already_correct_version"
check "status is skipped" "$(field "$result" status)" "skipped"
check "target_user is $REAL_USER (path parsing also case-insensitive)" "$(field "$result" target_user)" "$REAL_USER"
check "user_resolution_note is null" "$(field "$result" user_resolution_note)" "None"

echo
echo "=== Scenario 14: extension_path is a real symlink escaping ~/.vscode/extensions -> EXTENSION_PATH_UNSAFE ==="
mkdir -p "$SYMLINK_TARGET"
rm -f "$SYMLINK_PATH"
ln -s "$SYMLINK_TARGET" "$SYMLINK_PATH"

result="$(run_script "0.4.0" "false" "$SYMLINK_PATH")"
echo "  envelope: $result"
check "user_resolution_note is EXTENSION_PATH_UNSAFE" "$(field "$result" user_resolution_note)" "EXTENSION_PATH_UNSAFE"
check "target_user is $REAL_USER (parsed from path shape, kept for diagnostics)" "$(field "$result" target_user)" "$REAL_USER"
check "ran_as_root is true (unsafe path falls back to root, not the symlink target)" "$(field "$result" ran_as_root)" "True"
check "run still proceeds: status is skipped (not failure)" "$(field "$result" status)" "skipped"

rm -f "$SYMLINK_PATH"
rmdir "$SYMLINK_TARGET" 2>/dev/null || true

echo
echo "$PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
