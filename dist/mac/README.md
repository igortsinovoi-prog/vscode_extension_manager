# set-vscode-extension-version (macOS)

Pins a VS Code extension to an exact version - upgrading or downgrading as
needed - or to latest if no version is given. **Never installs an
extension fresh**: if it isn't already present on the target machine, this
is a deliberate no-op.

`set-vscode-extension-version.js` (JXA, run via `osascript -l JavaScript`)
is a single, self-contained file - the only thing you need to copy onto a
target Mac or upload as an RTR/Glow Action Script. Regenerate it with
`./build.sh` from the repo root after pulling a new version; don't
hand-edit anything under `dist/` - it's generated from `js_scripts/lib/`
and gets overwritten on the next build. See the sibling `windows/`
directory (and its own `README.md`) for the Windows/PowerShell port of
this same script.

## Design

- **Input**: a single base64-encoded JSON object, the script's only
  argument - `{"params":{"extension_id":"...","version":"...",
  "extension_path":"..."},"dry_run":true|false}`. `version` is optional
  (omit it to mean "upgrade to latest"). `extension_path` is the path to
  the extension's installed directory (or a file within it) - the target
  user is resolved from this path.
- **Output**: one compact JSON object on stdout (the `ActionResult`
  envelope) - `status` (`success`/`skipped`/`failure`), `action`,
  `changed`, `installed_version_before`/`_after`, `target_user`,
  `ran_as_root` (true whenever user resolution fell back and this
  actually ran as root instead of the resolved target user - see
  `user_resolution_note` for why), `vscode_restarted`, and (on failure) a
  structured `error`. Stderr is always silent; every error is reported
  inside the envelope. Set `dry_run:true` to see what it *would* do
  without touching anything. A failure envelope reports this same full
  field list too, populated with whatever was already figured out before
  the failure occurred (safe `null`/`false` defaults for whatever wasn't
  reached yet) - never a smaller, differently-shaped object.

```bash
INPUT=$(printf '%s' '{"params":{"extension_id":"ms-python.python","version":"2024.1.0","extension_path":"/Users/jdoe/.vscode/extensions/ms-python.python-2024.5.0"},"dry_run":true}' | base64)
sudo osascript -l JavaScript set-vscode-extension-version.js "$INPUT"
```

- **A changed version only takes effect once VS Code is reloaded/restarted**
  - it does not hot-swap an active extension host's code on disk changing
  out from under it, and a managed tool can't rely on a user noticing a
  "reload required" prompt on their own. So after a real, successful,
  *changed* version update, this script checks whether the target user's
  VS Code is currently running and, if so, fully quits and relaunches it
  (the envelope's `vscode_restarted` field reports whether this
  succeeded). Never launched if it wasn't already running; never
  restarted for a no-op or dry-run action.
- **The restart is genuinely graceful**, not a force-kill: a real quit
  AppleEvent via `launchctl asuser`, polled for up to 10s, with
  force-kill only as an actual last resort if VS Code doesn't exit on its
  own in time. This is the one place macOS and Windows behave
  differently - see `windows/README.md` for why Windows can't offer the
  same guarantee.
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
  "Signature verification failed: NotSigned". Handled automatically and
  transparently: `extensions.verifySignature` is temporarily set to
  `false` in the target user's own `settings.json` for the duration of
  each CLI call only, then the file is restored to its exact original
  content immediately after (or deleted, if it didn't exist before) -
  never left changed. A real on-disk backup is written before touching
  anything and restored from that file, not memory, so a process killed
  mid-write can't lose the original content for good.
- **Every file this script writes ends up owned by the real target
  user**, even when the script itself was invoked as root (the normal
  case for a real MDM/RTR deployment) - it impersonates that user via
  `launchctl asuser` layered with a real credential drop (`sudo -H -u
  '#<uid>'`), not just the Mach bootstrap namespace `launchctl asuser`
  alone provides. See the build log below for why that layering is
  necessary.

## Test coverage

- **Mocked unit tests** (safe to run anywhere, no real VS Code install or
  target account needed): 84 tests (45 runner + 39 policy). The policy
  module (pure decision logic - upgrade vs. downgrade vs. no-op) is
  tested directly under Node; the runner module (the OS interaction
  glue) is tested with the single process-invocation seam mocked, except
  two tests that deliberately run for real against the actual
  process-invocation primitive rather than the mock (see the "timeout"
  and "inherited cwd" entries in the build log below) - no real process
  is otherwise ever spawned.
- **Real-world end-to-end check**: 18 scenarios, shared verbatim with the
  Windows side where the underlying behavior is shared (only *how* each
  step runs differs), that really install/upgrade/downgrade a real, small
  extension and assert on the real result - not mocked. Covers the basic
  no-op/upgrade/downgrade matrix, dry-run safety, malformed/unsafe/missing
  `extension_path` handling, root-fallback identity isolation, resilience
  to VS Code's own passive extension-update sync (with a control
  extension proving the sync genuinely ran), real signature-verification
  enforcement, the restart-after-change behavior (independently confirmed
  by polling for VS Code's process to actually cycle to a new pid, not
  just trusting the envelope's own claim), and a real hung-`code`-CLI
  detection/kill/report scenario (the real binary swapped for a stub that
  hangs, run through the actual deployed contract). See this repo's own
  `test_logs/` for exact current pass/fail counts from the most recent
  full run.
- **Verified on real hardware**, not just mocked: a real Mac, invoked
  both directly (as the interactive user) and over a real CrowdStrike
  Falcon RTR session (`--platform mac-rtr`) - the real production
  deployment channel this script actually ships through: real put-file
  upload, a real session against a real sensor-enrolled device, real
  `runscript` invocation and polling. This RTR path is what surfaced two
  of the bugs below (an inherited working directory the target user
  can't access, and a spawned command's timeout that could never
  actually fire) - neither was reachable by invoking the same script
  locally as the interactive user.

## Build log

Real hardware found things careful review alone didn't catch:

- **`launchctl asuser` does not drop process credentials** - per `man
  launchctl`, it "does not modify the process' credentials (UID, GID,
  etc.)", only the Mach bootstrap namespace/session. Every real
  root-invoked deployment was silently leaving files (the installed
  extension's own folder, `settings.json` during the signature bypass)
  owned by root in the target user's home directory, despite the
  envelope correctly reporting `target_user`. Fixed by layering `sudo -H
  -u '#<uid>'` inside the already-`asuser`-attached context for every
  actual file-writing call, so the real Unix ownership matches the
  identity the envelope already claimed.
- **The passive extension-update sync and the explicit `--update-extensions`
  CLI command behave differently** (see "Design" above) - found by
  testing both directly, not assumed from documentation.
- **Old/non-latest versions need the signature-verification bypass
  described above** - first found on Windows, then confirmed to affect
  macOS too once the same scenario was added here.
- **A fixed sleep isn't long enough to observe a real marketplace
  install** - the passive-sync scenario's control-extension check
  originally used a fixed 15s sleep, long enough for an instant "already
  pinned, skip" decision but not reliably long enough for a real
  download-and-install; replaced with a poll (up to 90s).
- **The test VM/machine's network to the marketplace is occasionally
  flaky** (real `ETIMEDOUT`s, not a script bug) - mitigated with retries
  around real-network install calls and a persistent local side-cache of
  this suite's fixed pinned test versions, restored into VS Code's live
  cache before each install that needs one, so repeat test runs don't
  depend on that network being healthy every single time.
- **A spawned command's timeout was dead code whenever it actually
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
  as a permanent regression test (real-world check scenario 18).
- **An inherited working directory the target user can't access crashes
  `code`'s own CLI** - a real RTR session `cd`s into its own staging
  directory (created by root, mode `0700`) before invoking this script;
  once credentials are dropped to the real target user for the actual
  `code` CLI call, that user cannot even call `getcwd()` from inside a
  directory it has zero permission on. This is what the timeout fix
  above actually surfaced: instead of hanging, the next real run
  returned a real `EACCES: process.cwd failed` error - and every command
  this script spawns is now defensively pinned to `/tmp` (`1777`,
  traversable by any user) rather than trusting whatever directory the
  calling environment happened to be sitting in.
- **A process killed mid-write could lose settings.json's original
  content for good** - the signature-verification bypass used to keep
  the original raw content only in this process' own memory while
  temporarily disabling `extensions.verifySignature`; a process killed
  before its own restore step ran (a real RTR timeout, session
  termination, ...) left that setting stuck `false` with no way back.
  Now also writes a real on-disk backup before touching anything, and
  restores from that file, not memory.
- **`vscode_restarted` could report `true` even when the relaunch itself
  silently failed** - the final `open -a 'Visual Studio Code'` relaunch's
  own exit code was never actually checked, so a real failure (e.g. a
  missing/renamed app bundle) was indistinguishable in the envelope from
  a genuine successful relaunch. Fixed by only reporting success once
  `open`'s own exit code confirms it.
- **A failure envelope used to be a much smaller object than a success
  envelope** - it only ever carried `status`/`error`/`dry_run`/
  timestamps/`metadata`, missing every other field a success envelope
  always has (`extension_id`, `target_user`, `ran_as_root`,
  `cli_result`, ...). A caller had to special-case a failure response's
  shape instead of reading the same fields either way. Fixed by having
  every failure path report the full field list, populated with
  whatever was already figured out before the failure occurred, so a
  failure envelope is always the same shape a success envelope has,
  never a different one.

See the repo root's own `README.md` for full architecture details, and
`real_world_check_set_vscode_extension_version.sh --help` for every
option the real-world check itself supports (including `--scenario N` to
run just one scenario in isolation while debugging).
