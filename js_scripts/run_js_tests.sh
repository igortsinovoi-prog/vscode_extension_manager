#!/bin/bash
# Runs every JS test in js_scripts/tests/:
#   - Pure policy modules (*-policy.js) under Node, with a real coverage
#     report (node --experimental-test-coverage).
#   - JXA runner modules (*.osascript.js) via `osascript -l JavaScript`,
#     which mock the one seam all OS interaction goes through
#     (_runCommand) - no real process is ever spawned. These can't run
#     under Node (they use ObjC/NSTask), so there's no numeric coverage
#     report for them, only deliberate, comprehensive test design.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR/.."

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
