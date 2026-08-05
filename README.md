# vscode_extension_manager

Scripts for managing VS Code extension state on managed machines, deployable
as Glow Action Scripts: JXA (JavaScript for Automation) on macOS, PowerShell
on Windows.

Both platforms follow the same split: a pure, dependency-free **policy**
module (the decision logic - what should happen, given inputs) and a
**runner** module (the OS-interaction glue - actually running `code`,
resolving the target user, filesystem safety checks). The policy half is
unit tested directly (Node on macOS, Pester on Windows) with real coverage
where the tooling supports it; the runner half is tested via mocks, since it
depends on OS-specific process/filesystem APIs. Each platform's `build`
script concatenates its policy+runner pair into a single deployable file,
since both `osascript -l JavaScript` and (for consistency with how RTR
deploys a single uploaded script) the PowerShell side are treated as
single-file deployables.

Both scripts share the same RTR contract: a single base64-encoded JSON
object in, one compact JSON `ActionResult` envelope out on stdout, silent
stderr, file-only diagnostics. The envelope's field names and shapes are
identical field-for-field across both platforms (`os_family` differs -
`"mac"` vs `"windows"` - but everything else lines up), so a downstream
consumer of these results doesn't need per-OS parsing.

`set-vscode-extension-version` (both platforms) never installs an extension
fresh - if the extension isn't already present, it no-ops. Given a version,
it upgrades or downgrades to exactly that version; given no version, it
upgrades to latest.

A changed extension version only takes effect for a window's already-running
extension host once that window is reloaded/restarted - VS Code does not
hot-swap an active extension's code on disk changing out from under it, and
a managed version-pinning tool can't rely on a real end user noticing a
"reload required" prompt (or one even appearing) on their own. So after a
real, successful, changed version update, both platforms check whether the
target user has VS Code running and, if so, fully restart it (quit and
relaunch, not just a lighter reload - there's no CLI/API surface to trigger
a window reload externally in an already-running instance). The envelope's
`vscode_restarted` field reports whether this happened. Never launches VS
Code if it wasn't already running, and never restarts it for a no-op
(`already_correct_version`, `not_installed`) or dry-run action. Implemented
differently per platform because their target-user models already differ
(see each platform's section below): macOS impersonates the target user via
`launchctl asuser`, so it can just quit/relaunch directly as them
(`restartVSCodeIfRunning`); Windows never impersonates anyone, so relaunching
a GUI process into an arbitrary *other* user's session from a SYSTEM-context
script needs a one-shot Scheduled Task with `-LogonType Interactive`,
registered, triggered, and unregistered again immediately
(`Restart-VSCodeIfRunning`).

`Restart-VSCodeIfRunning` tries a graceful `WM_CLOSE` first (via
`Invoke-VSCodeCloseMainWindow`), polls up to 10s, and only force-kills what's
still running after that - matching the macOS side's own quit-AppleEvent-
then-poll-then-SIGKILL shape. **Confirmed this graceful attempt cannot
actually succeed in this script's real deployment context**, though:
`Process.MainWindowHandle` (what a graceful close needs) can't see a window
owned by a different login session, and RTR always runs non-interactively
(as SYSTEM) in a different session than whichever interactive session is
actually rendering VS Code's window - confirmed directly against a real
window under a real RTR-shaped session, every `Code.exe` process showed
`MainWindowHandle=0` from that vantage point. Kept anyway (a real no-op
safety margin, not reverted to an immediate force-kill) - see
`dist/windows/README.md` for the full writeup and what this means for a
real deployment: unsaved
work in the target user's VS Code window is lost when a real, changed
version update forces a restart while it's open. No such gap exists on
macOS, where `launchctl asuser` genuinely reaches the target session for a
real graceful quit.

## Running everything

`run_all_tests.sh` (repo root) is a single entry point that runs every
suite in this repo across any number of named machines: `mac` (this
machine) plus any number of Windows targets, each declared once in
`.env.local` and selectable by name. For each selected Windows target it
runs both the mocked suite (`ps_scripts/run_all_tests.sh --target
windows`) and the real-world check (`--platform windows` below);
`--target windows` is used for the mocked suite too (not `--target
local`) because `pwsh` isn't installable on this project's actual dev
machine (Tier-3/macOS-12, confirmed unsupported) - each configured
Windows box covers its own mocked-suite run instead. Every stage runs
regardless of an earlier stage's failure, so one broken suite doesn't
hide problems in the others - the exit code reflects whether *all*
stages passed. Each stage's full output is both shown live and saved to
its own log file under `test_logs/<timestamp>/` (also
`test_logs/latest/`), so a failure can be diagnosed from the log
afterward without re-running anything.

Windows targets are declared in `.env.local`, not passed as flags -
add a third Windows box later by adding one name and one block, no
script changes:

```bash
# .env.local
WIN_TARGETS="win10 win11"

WIN10_HOST=20.55.29.165
WIN10_USER=abuyam
WIN10_PORT=2222              # optional, defaults to 22
WIN10_PASSWORD=...           # or WIN10_KEY=~/.ssh/...
WIN10_DEVICE_AID=...         # optional - omit to skip this target's -rtr stage

WIN11_HOST=192.168.64.4
WIN11_USER=abuyam
WIN11_KEY=~/.ssh/utm_windows_vm
WIN11_DEVICE_AID=...
```

```bash
./run_all_tests.sh                          # mac + every configured Windows target
sudo ./run_all_tests.sh                      # + mac root-fallback coverage
./run_all_tests.sh --targets mac,win10       # just those two
./run_all_tests.sh --targets win11

# + real-RTR stages (see "Testing via real RTR" below):
./run_all_tests.sh --rtr
```

Pass `--rtr` to also run each selected target's real-world check over an
actual CrowdStrike Falcon RTR session (`mac-rtr` / `<name>-rtr`) -
additive, not a replacement: the direct-invocation real-world checks
above still run every time. See "Testing via real RTR" under
"Real-world check" below for what this needs and why it exists. A
selected target missing its device AID (`MAC_DEVICE_AID` /
`<NAME>_DEVICE_AID` in `.env.local`) has its `-rtr` stage skipped with a
note rather than erroring, so `--rtr` still works fine when only some
targets have a sensor enrolled yet.

## Real-world check (shared, both platforms)

`real_world_check_set_vscode_extension_version.sh` (repo root) is one
opt-in, self-cleaning end-to-end check, shared between both platforms: it
really installs/downgrades/upgrades a real, small, well-known extension
(`njpwerner.autodocstring`) and asserts on the real result - not mocked,
not part of either platform's regular test suite. The 17 scenarios and
their assertions are identical regardless of platform; only how each
individual command actually runs (invoking the real `code` CLI, invoking
the deployed script under test) differs, selected via `--platform`. It
always runs as bash on the Mac - for `--platform windows` it drives
a real Windows box over SSH rather than requiring bash on Windows.

```bash
./real_world_check_set_vscode_extension_version.sh --platform mac
sudo ./real_world_check_set_vscode_extension_version.sh --platform mac   # + root-fallback scenarios

./real_world_check_set_vscode_extension_version.sh --platform windows \
  --host <ip> --user <admin-user> --key ~/.ssh/id_ed25519   # key auth
./real_world_check_set_vscode_extension_version.sh --platform windows \
  --host <ip> --user <admin-user> --password <pw>           # or password auth (needs sshpass)
./real_world_check_set_vscode_extension_version.sh --platform windows \
  --host <ip> --user <admin-user> --password <pw> --port 2222   # non-default SSH port

./real_world_check_set_vscode_extension_version.sh --platform mac-rtr \
  --device-aid <aid>   # + FALCON_CLIENT_ID/SECRET in env or .env.local - see "Testing via real RTR" below
./real_world_check_set_vscode_extension_version.sh --platform windows-rtr \
  --host <ip> --user <admin-user> --password <pw> --port 2222 --device-aid <aid>
```

This script itself always targets exactly one machine per invocation
(host/user/port/auth/device-aid are plain flags, as above) - it has no
concept of named targets. `run_all_tests.sh` is what adds the
`.env.local`-driven `win10`/`win11`/... naming on top, by invoking this
script once per selected target (see "Running everything" above).

It captures the extension's original install state up front and restores
it on exit regardless of pass/fail - each cleanup step is guarded
independently, so one step erroring (e.g. a transient SSH hiccup) can
never block the far more important step of restoring the extension's
original install state.

### Testing via real RTR (`--platform mac-rtr` / `windows-rtr`)

The direct-invocation `--platform mac`/`windows` above run the
deployed script locally/over plain SSH, as the interactive/admin user -
a genuinely different code path from how this actually ships in
production (a CrowdStrike Falcon RTR `runscript` invocation, running as
root/SYSTEM against whatever session happens to be logged in).
`--platform mac-rtr`/`windows-rtr` drive that real path instead: real
put-file upload, a real RTR session against a real sensor-enrolled
device, real `runscript` invocation and polling. This is not redundant
with the direct-invocation platforms: on mac, it's what actually
surfaced two real bugs neither direct invocation nor the mocked suites
ever could (an inherited working directory the target user can't access,
and a spawned command's timeout that could never actually fire - see
`dist/mac/README.md`'s "Build log" for both); `windows-rtr` exercises the
SYSTEM-identity fallback path on Windows for real for the first time,
the same way `mac-rtr` already does on mac.

```bash
FALCON_CLIENT_ID=... FALCON_CLIENT_SECRET=... \
./real_world_check_set_vscode_extension_version.sh --platform mac-rtr \
  --device-aid <sensor-enrolled-device-aid>

FALCON_CLIENT_ID=... FALCON_CLIENT_SECRET=... \
./real_world_check_set_vscode_extension_version.sh --platform windows-rtr \
  --host <ip> --user <admin-user> --password <pw> --port 2222 \
  --device-aid <sensor-enrolled-device-aid>
```

Both need `--device-aid` (the target device) and `FALCON_CLIENT_ID`/
`FALCON_CLIENT_SECRET` in the environment - **never as flags**: argv is
visible in shell history and to any other process on the machine via
`ps` (see `rtr_token()`'s own comment). All of these can instead live in
a local, git-ignored `.env.local` at the repo root (`MAC_DEVICE_AID=...`,
`WIN10_DEVICE_AID=...`, `FALCON_CLIENT_ID=...`,
`FALCON_CLIENT_SECRET=...` - see "Running everything" above for the full
per-target schema) - auto-loaded by both this script and
`run_all_tests.sh --rtr` if present, so a real RTR run doesn't need any
of that re-entered by hand each time. Recover a device AID from the
Falcon console (Host Management) or the Falcon API's own
`devices-scroll` query filtered by hostname/serial number; recover the
API credentials from wherever your team keeps them - neither is
derivable from anything else in this repo, and `.env.local` is never
committed.

`--platform windows`/`windows-rtr` drive everything from the Mac
side over SSH to an admin account on the Windows box (or, for
`windows-rtr`, a mix of SSH for harness setup/assertions and a real RTR
session for the actual deployment under test - see
`rtr_run_dist_script_windows`'s own comment): `bootstrap_remote_windows.ps1`
(piped over SSH) installs `pwsh` there if missing, `ps_scripts/build.sh`
builds the deployable script locally (no `pwsh` needed on the Mac), and
either `scp` copies just that one file over (`windows`) or it's
uploaded as an RTR put-file (`windows-rtr`); either way it's cleaned up
again when the run finishes. Also reachable via
`js_scripts/run_all_tests.sh --with-real-world-test` (which runs it with
`--platform mac` after the mocked suite) or the repo-root
`run_all_tests.sh` (every configured target, plus every mocked suite -
see "Running everything" above).

**A non-default SSH port needs `--port`** (or `<NAME>_PORT` in
`.env.local` when going through `run_all_tests.sh`) - not every Windows
box answers SSH on 22. Confirmed real on the `win10` target: its NSG,
Windows Firewall, and `sshd` are all correctly configured for port 22,
but Azure appears to block inbound 22 specifically at the platform level
regardless (reproduced from three independent networks including Azure
Cloud Shell itself) - a second `sshd` listener on 2222 with an otherwise
identical setup works instantly. If a Windows target ever behaves this
way, check whether it's actually a listener/firewall/NSG problem first
(this repeatedly wasn't, here), and if everything checks out and it's
still unreachable, try a non-default port before assuming the box itself
is broken.

### Scenarios 15 and 16: VS Code's own background behavior

Two scenarios go further than "does our script work" and probe VS Code's
own background behavior, since a version pin is only meaningful if
something else isn't quietly undoing it:

- **Scenario 15** pins the extension to an old version via our own
  script (setting the `pinned` `extensions.json` metadata, a side effect
  of `--install-extension id@version`), then launches a *real* GUI VS
  Code window - the passive/startup extension-sync check never runs from
  a one-shot CLI invocation - and confirms the pin holds. Alongside it, a
  **control extension** (`usernamehw.errorlens`) is installed at an old
  version too but left explicitly *unpinned*, and must itself get updated
  by the same startup sync - without this, an unaffected pinned version
  proves nothing on its own: it's indistinguishable from the sync never
  having run at all. The control extension's update is polled for (up to
  90s), not a fixed sleep - unlike the pinned extension's check (an
  instant "already pinned, skip" decision, no network involved), the
  control extension's update is a real marketplace download-and-install,
  which can take meaningfully longer than a few seconds.

  This only covers VS Code's *passive* extension sync. The explicit
  `code --update-extensions` CLI command was also investigated and found
  to unconditionally override any pin - no flag, setting, or metadata
  trick excludes a specific extension from it (tried: the `pinned`
  metadata itself, `extensions.autoUpdate: false`, file-permission
  tricks - rejected as too aggressive). There's nothing to assert here,
  so it isn't tested: if a managed machine's own automation ever invokes
  `--update-extensions` directly, no version pin set by this script will
  survive it.

  A real GUI session is required for the passive sync to run at all,
  which needs platform-specific plumbing. On macOS, `open -a "Visual
  Studio Code"` / `osascript -e 'quit app ...'` is enough, since the test
  machine's own session is already a real interactive one. On Windows,
  SSH lands in the non-interactive Session 0, where a directly-launched
  `Code.exe` can start a process but never render a window or run its
  full background services (confirmed: only a stub `cli.log` ever
  appears, never a full `main.log`/`window1/renderer.log`/`exthost.log`
  set) - so `ps_scripts/tests/watch_and_launch_vscode.ps1`, registered
  via `ps_scripts/tests/register_vscode_watcher_task.ps1` as a Scheduled
  Task with `-LogonType Interactive`, runs *inside* a real logged-on
  session and launches/kills VS Code there in response to a trigger file
  this script creates/consumes over SSH. That task must already be
  registered and running on the Windows VM before this scenario can run
  there; it's skipped (not failed) otherwise.

- **Scenario 16** confirms our own script's install works even with
  `extensions.verifySignature: true` explicitly set in the real
  `settings.json` (restored to its exact original content afterward), and
  clears any locally cached VSIX for the test version first (VS Code's
  local VSIX cache otherwise silently masks a broken bypass, since a
  version downloaded once - even bypass-assisted - installs again without
  re-verification). Whether a manual `code --install-extension` for that
  version is actually *blocked* is only reported informationally, not
  asserted: the marketplace's signing policy for
  `njpwerner.autodocstring` (this project's test extension throughout)
  has changed since this scenario was originally written - both `0.4.0`
  and `0.5.0` were confirmed to no longer be signature-restricted at all,
  with or without this scenario's own `verifySignature: true`. That's an
  environmental fact outside this project's control, not a test failure;
  what's still asserted is that our own script's install keeps working
  regardless of which way that cuts (see each runner's
  signature-verification bypass, described below).

### Scenario 17: restarting VS Code after a real change

Verifies the `vscode_restarted` behavior described above actually happens,
not just that the envelope claims it does. Two cases:

- **17a** - with a real GUI session up (already running, or launched fresh
  if not, restored to its original not-running state afterward), a real
  version change reports `vscode_restarted: true`, independently confirmed
  by polling for VS Code's own process to actually cycle to a new pid - not
  just trusting the envelope's own claim.
- **17b** - with VS Code confirmed NOT running first, a real version change
  reports `vscode_restarted: false` and is confirmed to not have launched it
  as a side effect.

## macOS (js_scripts/)

| File | Purpose |
|---|---|
| `js_scripts/lib/set-vscode-extension-version-policy.js` | Pure decision logic: validates extension ids/version strings, parses `code --list-extensions --show-versions` output, decides no-op vs. install vs. upgrade vs. downgrade. |
| `js_scripts/lib/set-vscode-extension-version-runner.js` | OS-interaction glue: RTR contract (base64 in / JSON envelope out), runs the `code` CLI as the target user via `launchctl asuser` (resolved from the extension's install path; falls back to root's own isolated `HOME=/var/root` identity when no user can be confidently resolved), path-safety checks, diagnostics. Also brackets every CLI call with a temporary signature-verification bypass (`extensions.verifySignature: false` in that identity's own `settings.json`, restored to its exact original raw content - or deleted if it didn't previously exist - immediately after), for the same reason as the Windows runner below: the marketplace only signs an extension's *current latest* version, so pinning any older version otherwise fails with "Signature verification failed: NotSigned". After a real, successful, changed version update, `restartVSCodeIfRunning` also quits and relaunches the target user's VS Code if (and only if) it's currently running - see "restarting VS Code after a real change" above. |
| `js_scripts/build.sh` | Concatenates each `lib/*-policy.js` + `*-runner.js` pair into `js_scripts/dist/<name>.js`. Removes any existing `dist/` first. Run this after editing `lib/`, not `dist/` directly - it's generated. |
| `js_scripts/run_all_tests.sh` | Runs every test in `js_scripts/tests/`: policy modules under Node (`node --experimental-test-coverage`), runner modules via `osascript -l JavaScript` with `_runCommand` mocked - no real process is ever spawned. Safe to run anywhere. Pass `--with-real-world-test` to also run the real end-to-end check below (needs `sudo` for full coverage of the root-fallback scenarios). |
| `js_scripts/tests/test_vscode_extension_version_policy.js` | Node test suite for the policy module. |
| `js_scripts/tests/test_vscode_extension_version_runner.osascript.js` | Mocked JXA test suite for the runner module. |

```bash
js_scripts/build.sh              # build dist/set-vscode-extension-version.js
js_scripts/run_all_tests.sh      # mocked suite, safe anywhere
sudo js_scripts/run_all_tests.sh --with-real-world-test   # + real end-to-end check
```

Running the deployed script directly against a real machine (this is what
RTR does under the hood - one base64-encoded JSON payload as the only arg):

```bash
INPUT=$(printf '%s' '{"params":{"extension_id":"ms-python.python","desired_version":"2024.1.0","extension_path":"/Users/jdoe/.vscode/extensions/ms-python.python-2024.5.0"},"dry_run":true}' | base64)
sudo osascript -l JavaScript js_scripts/dist/set-vscode-extension-version.js "$INPUT"
```

Drop `"dry_run":true` (or set it to `false`) to actually perform the
install/upgrade/downgrade; leave it `true` to see what the script *would*
do without touching anything.

## Windows (ps_scripts/)

| File | Purpose |
|---|---|
| `ps_scripts/lib/Set-VSCodeExtensionVersion.Policy.ps1` | Same pure decision logic as the macOS policy module, ported 1:1 (extension id/version validation, installed-list parsing, the version-action decision, the outcome computation) - just a Windows path shape (`<drive>:\Users\<user>\.vscode\extensions\<leaf>`) for the extension-path parser. |
| `ps_scripts/lib/Set-VSCodeExtensionVersion.Runner.ps1` | OS-interaction glue - RTR contract, `code.cmd` discovery, path-safety checks, diagnostics. **Differs from macOS in three deliberate ways.** (1) Instead of impersonating the target user (there's no lightweight Windows equivalent of `launchctl asuser` short of token-duplication tricks), it runs `code.cmd` as whatever identity launched the script (typically SYSTEM under RTR) and passes the target user's extensions folder explicitly via VS Code CLI's own `--extensions-dir` flag. The fallback-when-unresolvable case points at SYSTEM's own (normally empty) extensions dir under `%SystemRoot%\System32\config\systemprofile`, the Windows analogue of the macOS side's `HOME=/var/root` isolation fix. (2) It also passes `--user-data-dir`, derived from `--extensions-dir` (never a separate parameter, never a different identity's profile) - real-world finding: the marketplace only serves a signature for an extension's *current latest* version, so pinning any older version (the entire point of this script's `--version` support) fails with "Signature verification failed: NotSigned" otherwise. `extensions.verifySignature` is temporarily set to `false` in that identity's own `settings.json` for the duration of each CLI call only, then the exact original raw file content is restored immediately after (or the file deleted if it didn't exist before) - never left changed, never touching a different user's settings. (3) `Restart-VSCodeIfRunning` - same "restart after a real, changed update" behavior as the macOS side, but since this script never impersonates anyone, relaunching a GUI process into an arbitrary *other* user's session needs a different mechanism than starting a new process: a one-shot Scheduled Task with `-LogonType Interactive`, registered, triggered, and unregistered again immediately (the supported way to start a process in another user's real interactive session without token impersonation/duplication). |
| `ps_scripts/build.ps1` | Concatenates each `lib/*.Policy.ps1` + `*.Runner.ps1` pair into `ps_scripts/dist/<name>.ps1`. |
| `ps_scripts/build.sh` | Same output as `build.ps1` (plain text concatenation, byte-for-byte), for building on a machine without `pwsh` - e.g. building on the Mac to deploy just the resulting single file onto a remote Windows box. Used by `real_world_check_set_vscode_extension_version.sh --platform windows`. |
| `ps_scripts/run_all_tests.ps1` | Runs the Pester suite under `ps_scripts/tests/` natively. Requires Pester 5+ (`Install-Module Pester -Scope CurrentUser -MinimumVersion 5.0.0`). |
| `ps_scripts/run_all_tests.sh` | Runs that same suite either locally (if `pwsh` is on this machine's PATH: `--target local`) or remotely over SSH against a real Windows box (`--target windows --host <ip> --user <user> (--key <path> \| --password <pw>)`) - mirrors the real-world check's remote plumbing; copies only `lib/`, `tests/`, and `run_all_tests.ps1` (no git needed on the remote box), bootstraps `pwsh` + Pester there if missing, and cleans up the scratch directory afterward. |
| `ps_scripts/bootstrap_remote_windows.ps1` | Idempotent: ensures `pwsh` is present on a remote Windows box. Piped over SSH by both `run_all_tests.sh` and the real-world check's `--platform windows`. Must stay Windows-PowerShell-5.1-compatible, since `pwsh` may not exist yet the first time it runs. |
| `ps_scripts/tests/Set-VSCodeExtensionVersion.Policy.Tests.ps1` | Pester suite for the policy module - mirrors the macOS policy test suite's coverage scenario-for-scenario. |
| `ps_scripts/tests/Set-VSCodeExtensionVersion.Runner.Tests.ps1` | Mocked Pester suite for the runner module (mocks the single process-invocation seam plus the small filesystem seams) - mirrors the macOS runner test suite's coverage, plus dedicated tests pinning the JSON envelope's exact field casing and the signature-verification bypass's enable/restore behavior. |
| `ps_scripts/tests/watch_and_launch_vscode.ps1` | Watches for trigger files and launches/kills a real VS Code GUI window in response - meant to run inside an actual interactive Windows session, not over SSH. Exists because SSH lands in the non-interactive Session 0, where a directly-launched `Code.exe` never renders a window; this is how the real-world check's scenario 15 gets a real, rendering VS Code session to observe despite driving everything else over SSH. Self-cleaning: each trigger file is deleted immediately after being acted on. |
| `ps_scripts/tests/register_vscode_watcher_task.ps1` | Registers the above as a Scheduled Task (`-LogonType Interactive`) that starts automatically at logon for a given user, and immediately (since that user may already be logged in). Run this once, as Administrator, on the Windows VM before scenario 15 can run there. |

```powershell
.\ps_scripts\build.ps1
.\ps_scripts\run_all_tests.ps1
```

```bash
ps_scripts/run_all_tests.sh --target local
ps_scripts/run_all_tests.sh --target windows --host <ip> --user <admin-user> --password <pw>
```

Running the deployed script directly against a real machine:

```powershell
$json = '{"params":{"extension_id":"ms-python.python","desired_version":"2024.1.0","extension_path":"C:\\Users\\jdoe\\.vscode\\extensions\\ms-python.python-2024.5.0"},"dry_run":true}'
$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($json))
.\ps_scripts\dist\Set-VSCodeExtensionVersion.ps1 $b64
```

Drop `"dry_run":true` (or set it to `false`) to actually perform the
install/upgrade/downgrade; leave it `true` to see what the script *would*
do without touching anything.

**Verified on real hardware** - a UTM VM (Windows 11 ARM64, driven over
SSH from the Mac; see the two scripts' `--platform`/`--target
windows`) and the Mac itself, not just the mocked suites.

The Windows side was originally written and reviewed line-by-line with no
Windows machine available yet, which did catch several real bugs before
ever running anything: PowerShell's `-and`/`-or` not short-circuiting the
way JS/C#'s `&&`/`||` do, `Process.Start` requiring `cmd.exe /c` to launch
`.cmd` files with `UseShellExecute=false`, .NET's documented
double-`WaitForExit()` requirement when redirecting streams, and a JSON
casing mismatch between PowerShell's idiomatic PascalCase and the required
snake_case wire schema.

Actually running it on real hardware found several more that review alone
couldn't have:

- Pester 6 dropping support for `BeforeEach` declared directly at a
  container's root (only `BeforeAll` is still allowed there - see
  `Runner.Tests.ps1`'s structure).
- `pwsh -NoProfile -Command -` silently producing no output at all for
  multi-line control-flow blocks (`if`/`else`, `try`/`catch`) fed over
  stdin via SSH - no error, no bad exit code, just nothing (Windows
  PowerShell 5.1's `-Command -` handles the identical pattern fine; see
  `bootstrap_remote_windows.ps1`'s and `run_all_tests.sh`'s comments).
- The marketplace signature-verification behavior described above -
  first found on Windows; the Mac runner didn't get the same bypass until
  scenario 16 was added there too and failed against it.
- The real-world check's own bash-level `code_cli()` helper (used only
  for test setup/teardown, not the deployed script under test) never
  dropped root privileges when the check itself was invoked via `sudo` -
  which it needs to be, for scenario 5b's root-fallback coverage. Every
  setup/teardown install ran as root against the real user's actual
  `~/.vscode/extensions`, silently leaving root-owned files there on
  every sudo'd run, until enough accumulated to cause a genuine `EACCES`
  failure. Fixed by having `code_cli()` drop to the real invoking user
  (`sudo -H -u`) whenever it's already root.
- Scenario 15's control-extension check used a fixed 15s sleep before
  checking whether the update landed - long enough for the *pinned*
  extension's check (an instant "already pinned, skip" decision, no
  network involved) but not reliably long enough for the *control*
  extension's real marketplace download-and-install, which failed
  identically on both mac and windows until replaced with a poll (up to
  90s).
- `kill_vscode_gui_session`'s (macOS) force-kill fallback pattern pointed
  at a path (`Contents/MacOS/Electron`) that has never existed - VS
  Code's real executable is `Contents/MacOS/Code` - so it silently never
  fired whenever the graceful `quit app` AppleEvent didn't land in time.
- `pgrep -f`/`pgrep -x`/`pkill -f` unreliably failed to match the real VS
  Code process at all on this machine, for reasons that resisted
  explanation (tried exact full-path matching, anchored regexes, plain
  substring search on its own `ucomm` value - none matched a process `ps`
  itself showed plainly). Replaced everywhere with `ps aux | grep -F` /
  killing by pid gathered that way instead, which did prove reliable.
- Pester's `[PSCustomObject]@{...}` does not support adding a *new*
  property via plain `$obj.NewProp = value` after construction (only
  setting an already-declared one) - threw "The property ... cannot be
  found on this object" the moment a test tried it; fixed by declaring
  the property in the original construction instead.
- Mocking `Get-CimInstance`/`Invoke-CimMethod` (real cmdlets with two
  chained calls) directly through Pester proved unreliable - calls
  silently failed with no visible error (masked by the calling code's own
  try/catch) rather than reaching the mock body. Fixed the same way
  `Invoke-VSCodeNativeCommand` already avoids the same class of problem
  for raw process invocation: wrap the two chained cmdlets in one custom
  function and mock that instead. Separately, `Register-ScheduledTask`'s
  real `-Action`/`-Principal` parameters expect actual typed CIM objects
  from `New-ScheduledTaskAction`/`New-ScheduledTaskPrincipal` - mocking
  those two (cheap, pure, side-effect-free constructors) to return plain
  `PSCustomObject` stand-ins broke parameter binding on the *next* call
  silently, for the same reason; fixed by not mocking them at all and
  only mocking the cmdlets with real external effects.

Moral, consistent throughout this project: careful review narrows the bug
surface, but isn't a substitute for actually running the thing.
