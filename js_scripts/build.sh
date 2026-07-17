#!/bin/bash
# Concatenates each js_scripts/lib/*-policy.js + *-runner.js pair into a
# single deployable JXA script under js_scripts/dist/.
#
# osascript -l JavaScript has no require()/import - a JXA "script" must be
# one file. The source is kept split for testability: the *-policy.js half
# is plain, ObjC-free JS (unit tested directly under Node, with real
# coverage); the *-runner.js half is the OS-interaction glue (ObjC/NSTask),
# tested separately via mocked osascript tests. Concatenation order matters
# - the runner references the policy module's functions, so policy goes
# first. See js_scripts/run_js_tests.sh for how both halves are tested.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$DIR/lib"
DIST_DIR="$DIR/dist"

if [[ -e "$DIST_DIR" ]]; then
  rm -rf "$DIST_DIR"
fi
mkdir -p "$DIST_DIR"

built_any=false
for policy_file in "$LIB_DIR"/*-policy.js; do
  [[ -e "$policy_file" ]] || continue
  base="$(basename "$policy_file" -policy.js)"
  runner_file="$LIB_DIR/$base-runner.js"
  if [[ ! -f "$runner_file" ]]; then
    echo "Error: found $policy_file but no matching $runner_file" >&2
    exit 1
  fi

  output="$DIST_DIR/$base.js"
  {
    echo "// GENERATED FILE - DO NOT EDIT."
    echo "// Built by js_scripts/build.sh from:"
    echo "//   lib/$base-policy.js (decision logic, unit tested under Node)"
    echo "//   lib/$base-runner.js (OS-interaction glue, tested via mocked osascript tests)"
    echo "// Edit those source files and re-run js_scripts/build.sh, not this file."
    echo
    cat "$policy_file"
    echo
    cat "$runner_file"
  } > "$output"
  echo "Built $output"
  built_any=true
done

if [[ "$built_any" != true ]]; then
  echo "Error: no lib/*-policy.js + *-runner.js pairs found under $LIB_DIR." >&2
  exit 1
fi
