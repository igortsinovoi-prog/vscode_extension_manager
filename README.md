# vscode_extension_manager

JXA (JavaScript for Automation) scripts for managing VS Code extension state
on macOS, deployable as Glow Action Scripts.

Each script follows the same split: a pure, dependency-free **policy**
module (the decision logic - what should happen, given inputs) and a
**runner** module (the OS-interaction glue - actually running `code`,
resolving the target user, filesystem safety checks). The policy half is
unit tested directly under Node with real coverage; the runner half is
tested via mocked `osascript` tests, since it depends on ObjC/NSTask and
can't run under Node. `build.sh` concatenates each pair into a single
deployable file, because `osascript -l JavaScript` has no `require()` /
`import` - a JXA script must be one file.

## Directory contents

| File | Purpose |
|---|---|
| `js_scripts/lib/set-vscode-extension-version-policy.js` | Pure decision logic: validates extension ids/version strings, parses `code --list-extensions --show-versions` output, decides no-op vs. install vs. upgrade vs. downgrade. |
| `js_scripts/lib/set-vscode-extension-version-runner.js` | OS-interaction glue: RTR contract (base64 in / JSON envelope out), runs the `code` CLI as the target user (resolved from the extension's install path), path-safety checks, diagnostics. |
| `js_scripts/build.sh` | Concatenates each `lib/*-policy.js` + `*-runner.js` pair into `js_scripts/dist/<name>.js`. Removes any existing `dist/` first. Run this after editing `lib/`, not `dist/` directly - it's generated. |
| `js_scripts/run_js_tests.sh` | Runs every test in `js_scripts/tests/`: policy modules under Node (`node --experimental-test-coverage`), runner modules via `osascript -l JavaScript` with `_runCommand` mocked - no real process is ever spawned. Safe to run anywhere. |
| `js_scripts/tests/test_vscode_extension_version_policy.js` | Node test suite for the policy module. |
| `js_scripts/tests/test_vscode_extension_version_runner.osascript.js` | Mocked JXA test suite for the runner module. |
| `js_scripts/tests/real_world_check_set_vscode_extension_version.sh` | Opt-in, manual, self-cleaning end-to-end check against a real extension (`njpwerner.autodocstring`) on this machine, running the actual built `dist/set-vscode-extension-version.js` via `osascript` - not mocked. Captures the extension's original install state up front and restores it on exit regardless of pass/fail. Requires `sudo` (see script header for the full scenario list). |

## Usage

```bash
# Build the deployable JXA script(s) into js_scripts/dist/
js_scripts/build.sh

# Run the mocked test suite (safe anywhere, no real installs/uninstalls)
js_scripts/run_js_tests.sh

# Run the real end-to-end check against njpwerner.autodocstring (opt-in, needs sudo)
sudo js_scripts/tests/real_world_check_set_vscode_extension_version.sh
```

`set-vscode-extension-version.js` never installs an extension fresh - if the
extension isn't already present, it no-ops. Given a version, it upgrades or
downgrades to exactly that version; given no version, it upgrades to
latest.
