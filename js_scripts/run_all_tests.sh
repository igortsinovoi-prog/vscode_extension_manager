#!/bin/bash
# Runs every JS test in js_scripts/tests/:
#   - Pure policy modules (*-policy.js) under Node, with a real coverage
#     report (node --experimental-test-coverage).
#   - JXA runner modules (*.osascript.js) via `osascript -l JavaScript`,
#     which mock the one seam all OS interaction goes through
#     (_runCommand) - no real process is ever spawned. These can't run
#     under Node (they use ObjC/NSTask), so there's no numeric coverage
#     report for them, only deliberate, comprehensive test design.
#
# Pass --with-real-world-test to also run
# ../real_world_check_set_vscode_extension_version.sh --platform mac (shared
# with the Windows/ps_scripts side), which really installs/downgrades/
# upgrades njpwerner.autodocstring on this machine (self-cleaning: restores
# whatever state it found on exit). It rebuilds dist/ itself, so no separate
# build.sh step is needed first. It's opt-in since it touches real machine
# state; run it with sudo for full coverage of the root-fallback scenarios
# (it still runs without sudo, just skips those).
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR/.."

WITH_REAL_WORLD_TEST=false
for arg in "$@"; do
  case "$arg" in
    --with-real-world-test) WITH_REAL_WORLD_TEST=true ;;
    -h|--help)
      echo "Usage: $0 [--with-real-world-test]"
      exit 1
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      exit 1
      ;;
  esac
done

NODE_BIN="$(command -v node || true)"
if [[ -z "$NODE_BIN" ]]; then
  echo "Error: node not found on PATH." >&2
  exit 1
fi

shopt -s nullglob
node_tests=(js_scripts/tests/*.js)
osascript_tests=(js_scripts/tests/*.osascript.js)
shopt -u nullglob

# *.osascript.js also matches the *.js glob above - exclude it from the Node run.
plain_node_tests=()
for f in "${node_tests[@]}"; do
  case "$f" in
    *.osascript.js) ;;
    *) plain_node_tests+=("$f") ;;
  esac
done

if [[ ${#plain_node_tests[@]} -eq 0 ]]; then
  echo "No Node test files found under js_scripts/tests/." >&2
  exit 1
fi

echo "=== Node tests (pure policy modules, with coverage) ==="
"$NODE_BIN" --test --experimental-test-coverage "${plain_node_tests[@]}"

if [[ ${#osascript_tests[@]} -eq 0 ]]; then
  echo "No osascript test files found under js_scripts/tests/." >&2
  exit 1
fi

for f in "${osascript_tests[@]}"; do
  echo
  echo "=== JXA tests (mocked OS interaction): $f ==="
  osascript -l JavaScript "$f"
done

if [[ "$WITH_REAL_WORLD_TEST" == true ]]; then
  echo
  echo "=== Real-world check: set-vscode-extension-version.js against njpwerner.autodocstring ==="
  "$DIR/../real_world_check_set_vscode_extension_version.sh" --platform mac
fi

echo
echo "All tests passed."
