#!/bin/bash
# Builds both platforms' deployable scripts and collects them into a single
# dist/ directory at the repo root, alongside a product-info README for
# whoever is about to actually deploy/run them (not a developer doc - see
# the root README.md and each platform's own directory for that).
#
# This is a thin orchestrator: the real build logic lives in
# js_scripts/build.sh and ps_scripts/build.sh (each already produces its
# own <platform>_scripts/dist/ - see those files for why each is built the
# way it is). This script just runs both, then copies their single output
# file each into dist/mac/ and dist/windows/ here. Uses ps_scripts/build.sh
# (not build.ps1) deliberately - plain-text concatenation, no pwsh
# required, so this works on a machine with neither pwsh nor a Windows box
# available at all.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="$DIR/dist"

echo "==> Building macOS script"
"$DIR/js_scripts/build.sh"

echo "==> Building Windows script"
"$DIR/ps_scripts/build.sh"

if [[ -e "$DIST_DIR" ]]; then
  rm -rf "$DIST_DIR"
fi
mkdir -p "$DIST_DIR/mac" "$DIST_DIR/windows"

cp "$DIR/js_scripts/dist/set-vscode-extension-version.js" "$DIST_DIR/mac/"
cp "$DIR/ps_scripts/dist/Set-VSCodeExtensionVersion.ps1" "$DIST_DIR/windows/"

cat > "$DIST_DIR/README.md" <<'EOF'
# set-vscode-extension-version

Pins a VS Code extension to an exact version - upgrading or downgrading as
needed - or to latest if no version is given. **Never installs an
extension fresh**: if it isn't already present on the target machine, this
is a deliberate no-op, on both platforms.

This directory is the deployable output: `mac/set-vscode-extension-version.js`
(JXA, run via `osascript -l JavaScript`) and
`windows/Set-VSCodeExtensionVersion.ps1` (PowerShell). Each is a single,
self-contained file - the only thing you need to copy onto a target
machine or upload as an RTR/Glow Action Script. Regenerate both with
`./build.sh` from the repo root after pulling a new version; don't hand-edit
anything under `dist/` - it's generated from `js_scripts/lib/` and
`ps_scripts/lib/` and gets overwritten on the next build.

## Contract

Both platforms take the same input and produce the same output shape, so a
downstream caller doesn't need per-OS parsing:

- **Input**: a single base64-encoded JSON object, the script's only
  argument - `{"params":{"extension_id":"...","version":"...",
  "extension_path":"..."},"dry_run":true|false}`. `version` is optional
  (omit it to mean "upgrade to latest"). `extension_path` is the path to
  the extension's installed directory (or a file within it) - the target
  user is resolved from this path, on both platforms.
- **Output**: one compact JSON object on stdout (the `ActionResult`
  envelope) - `status` (`success`/`skipped`/`failure`), `action`,
  `changed`, `installed_version_before`/`_after`, `target_user`,
  `ran_as_root`, `vscode_restarted`, and (on failure) a structured `error`.
  Stderr is always silent; every error is reported inside the envelope.
  Set `dry_run:true` to see what it *would* do without touching anything.

```bash
# macOS
INPUT=$(printf '%s' '{"params":{"extension_id":"ms-python.python","version":"2024.1.0","extension_path":"/Users/jdoe/.vscode/extensions/ms-python.python-2024.5.0"},"dry_run":true}' | base64)
sudo osascript -l JavaScript mac/set-vscode-extension-version.js "$INPUT"
```

```powershell
# Windows
$json = '{"params":{"extension_id":"ms-python.python","version":"2024.1.0","extension_path":"C:\\Users\\jdoe\\.vscode\\extensions\\ms-python.python-2024.5.0"},"dry_run":true}'
$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($json))
.\windows\Set-VSCodeExtensionVersion.ps1 $b64
```

## Behavior worth knowing before you deploy this

- **A changed version only takes effect once VS Code is reloaded/restarted**
  - it does not hot-swap an active extension host's code on disk changing
  out from under it, and a managed tool can't rely on a user noticing a
  "reload required" prompt on their own. So after a real, successful,
  *changed* version update, both platforms check whether the target user's
  VS Code is currently running and, if so, fully quit and relaunch it (the
  envelope's `vscode_restarted` field reports whether this happened). Never
  launched if it wasn't already running; never restarted for a no-op or
  dry-run action.
- **A version pin survives VS Code's own passive/startup extension-update
  check**, by design (that's the whole point) - but **does not** survive an
  explicit `code --update-extensions` invocation elsewhere on the same
  machine. That command was investigated directly and found to
  unconditionally override any pin, with no flag/setting/metadata trick
  able to exclude a specific extension from it. If a managed machine's own
  automation runs `--update-extensions` on its own, this script's pin will
  not survive it - that's an inherent VS Code CLI limitation, not something
  this script can work around.
- **Old, non-latest versions require a real signature-verification
  bypass to install at all** - as of recent VS Code releases, the
  marketplace only serves a signature for an extension's *current latest*
  version, so installing/pinning any older version otherwise fails with
  "Signature verification failed: NotSigned". Both platforms handle this
  automatically and transparently: `extensions.verifySignature` is
  temporarily set to `false` in the target identity's own `settings.json`
  for the duration of each CLI call only, then the file is restored to its
  exact original content immediately after (or deleted, if it didn't exist
  before) - never left changed, never touching a different user's
  settings.
- **File ownership differs by platform, deliberately.** On macOS, every
  file this script writes (the extension itself, `settings.json` during
  the signature bypass) ends up owned by the *real target user*, even when
  the script itself was invoked as root (the normal case for a real
  MDM/RTR deployment) - it impersonates that user via `launchctl asuser`
  layered with a real credential drop (see "Fixed" below for why this
  needs to be explicit). On Windows, there is no lightweight equivalent of
  `launchctl asuser` - the script instead runs `code.cmd` as whichever
  identity launched it (typically `SYSTEM` under RTR) and points
  `--extensions-dir`/`--user-data-dir` explicitly at the target user's own
  folders. This means files there are legitimately owned by `SYSTEM`/
  Administrators, not the target user - by design, not a bug - while NTFS
  ACL inheritance still grants that user normal access to what got
  installed.

## Test coverage

- **Mocked unit tests** (safe to run anywhere, no real VS Code install or
  target account needed): 81 on macOS (42 runner + 39 policy), 85 on
  Windows (46 runner + 39 policy). Each platform's policy module (pure
  decision logic - upgrade vs. downgrade vs. no-op) is tested directly
  under a real interpreter (Node / Pester); each runner module (the OS
  interaction glue) is tested with the single process-invocation seam
  mocked (two exceptions on macOS, deliberately run for real against the
  actual process-invocation primitive rather than the mock - see "Bugs
  found" below), so no real process is ever spawned.
- **Real-world end-to-end check**: 17 scenarios, shared verbatim between
  both platforms (only *how* each step runs differs), that really
  install/upgrade/downgrade a real, small extension and assert on the
  real result - not mocked. Covers the basic no-op/upgrade/downgrade
  matrix, dry-run safety, malformed/unsafe/missing `extension_path`
  handling, root-fallback identity isolation, resilience to VS Code's own
  passive extension-update sync (with a control extension proving the
  sync genuinely ran), real signature-verification enforcement, and the
  restart-after-change behavior (independently confirmed by polling for
  VS Code's process to actually cycle to a new pid, not just trusting the
  envelope's own claim).
- **Verified on real hardware**, not just mocked: a UTM VM (Windows 11
  ARM64, driven over SSH) and a real Mac. Last full clean run of all 17
  real-world scenarios: **87 passed, 0 failed on macOS**; **86 passed, 0
  failed on Windows** (the two totals aren't expected to match exactly -
  a handful of checks are platform-specific, e.g. root-fallback identity
  messaging - see the repo's own `test_logs/` for the exact numbers
  behind any given run).
- **Verified over a real CrowdStrike Falcon RTR session** (`--platform
  mac-rtr`), not just invoked locally as the interactive user - the real
  production deployment channel this script actually ships through:
  real put-file upload, a real session against a real sensor-enrolled
  device, real `runscript` invocation and polling. Last full clean run of
  all 17 scenarios this way: **86 passed, 0 failed**. This is also what
  surfaced both macOS bugs in the section below - neither was reachable
  by invoking the same script locally as the interactive user; both
  needed the real RTR/root execution path to appear at all.

## Bugs found and fixed via real-hardware verification

Real hardware found things careful review alone didn't catch. The ones
that actually affect this script's real-world behavior (as opposed to
purely internal test-harness plumbing):

- **macOS: `launchctl asuser` does not drop process credentials** - per
  `man launchctl`, it "does not modify the process' credentials (UID,
  GID, etc.)", only the Mach bootstrap namespace/session. Every real
  root-invoked deployment was silently leaving files (the installed
  extension's own folder, `settings.json` during the signature bypass)
  owned by root in the target user's home directory, despite the
  envelope correctly reporting `target_user`. Fixed by layering `sudo -H
  -u '#<uid>'` inside the already-`asuser`-attached context for every
  actual file-writing call, so the real Unix ownership matches the
  identity the envelope already claimed.
- **The passive extension-update sync and the explicit `--update-extensions`
  CLI command behave differently** (see "Behavior worth knowing" above) -
  found by testing both directly, not assumed from documentation.
- **Old/non-latest versions need the signature-verification bypass
  described above** - first found on Windows, then confirmed to affect
  macOS too once the same scenario was added there.
- **A fixed sleep isn't long enough to observe a real marketplace
  install** - the passive-sync scenario's control-extension check
  originally used a fixed 15s sleep, long enough for an instant "already
  pinned, skip" decision but not reliably long enough for a real
  download-and-install; replaced with a poll (up to 90s) on both
  platforms.
- **Windows' `pwsh -NoProfile -Command -` silently drops multi-line
  control-flow blocks** (`if`/`else`, `try`/`catch`) fed over stdin via
  SSH - no error, no bad exit code, just nothing executed. This had made
  the real-world check's own signature-enforcement setup a complete
  no-op for a time. Fixed by writing each remote PowerShell call to a
  real temp `.ps1` file and running it via `pwsh -File` instead of piping
  it over stdin.
- **This project's own test VM's network to the marketplace is
  occasionally flaky** (real `ETIMEDOUT`s, not a script bug) - mitigated
  with retries around real-network install calls and a persistent local
  side-cache of this suite's fixed pinned test versions, restored into VS
  Code's live cache before each install that needs one, so repeat test
  runs don't depend on that network being healthy every single time.
- **macOS: a spawned command's timeout was dead code whenever it actually
  hung** - `code --list-extensions` itself was found stuck (via a live
  process's own stack sample, main thread parked in Node's own startup)
  minutes past its configured 20s timeout, real RTR sessions eventually
  reporting only an opaque "Timed out waiting for script to exit" with no
  further information. Root cause: the timeout was an `NSTimer` scheduled
  around a blocking `readDataToEndOfFile` call - `NSTimer` callbacks only
  ever fire while the run loop is turning, and that blocking read does
  not pump it, so the timeout could never actually fire while a child
  stayed hung with its pipe open. Fixed by polling the task's running
  state against a real wall-clock deadline instead, which has no such
  dependency - confirmed to correctly kill a genuinely hung process
  within its configured timeout, both via a direct real-process test and
  as a permanent regression test.
- **macOS: an inherited working directory the target user can't access
  crashes `code`'s own CLI** - a real RTR session `cd`s into its own
  staging directory (created by root, mode `0700`) before invoking this
  script; once credentials are dropped to the real target user for the
  actual `code` CLI call, that user cannot even call `getcwd()` from
  inside a directory it has zero permission on. This is what the timeout
  fix above actually surfaced: instead of hanging, the next real run
  returned a real `EACCES: process.cwd failed` error - and every command
  this script spawns is now defensively pinned to `/tmp` (`1777`,
  traversable by any user) rather than trusting whatever directory the
  calling environment happened to be sitting in.

See the repo root's own `README.md` for full architecture details, and
`real_world_check_set_vscode_extension_version.sh --help` for every
option the real-world check itself supports (including `--scenario N` to
run just one scenario in isolation while debugging).
EOF

echo "Built dist/mac/set-vscode-extension-version.js"
echo "Built dist/windows/Set-VSCodeExtensionVersion.ps1"
echo "Built dist/README.md"
