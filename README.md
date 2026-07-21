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

## Real-world check (shared, both platforms)

`real_world_check_set_vscode_extension_version.sh` (repo root) is one
opt-in, self-cleaning end-to-end check, shared between both platforms: it
really installs/downgrades/upgrades a real, small, well-known extension
(`njpwerner.autodocstring`) and asserts on the real result - not mocked,
not part of either platform's regular test suite. The 14 scenarios and
their assertions are identical regardless of platform; only how each
individual command actually runs (invoking the real `code` CLI, invoking
the deployed script under test) differs, selected via `--platform`. It
always runs as bash on the Mac - for `--platform windows-remote` it drives
a real Windows box over SSH rather than requiring bash on Windows.

```bash
./real_world_check_set_vscode_extension_version.sh --platform mac
sudo ./real_world_check_set_vscode_extension_version.sh --platform mac   # + root-fallback scenarios

./real_world_check_set_vscode_extension_version.sh --platform windows-remote \
  --host <ip> --user <admin-user> --key ~/.ssh/id_ed25519   # key auth
./real_world_check_set_vscode_extension_version.sh --platform windows-remote \
  --host <ip> --user <admin-user> --password <pw>           # or password auth (needs sshpass)
```

It captures the extension's original install state up front and restores
it on exit regardless of pass/fail - each cleanup step is guarded
independently, so one step erroring (e.g. a transient SSH hiccup) can
never block the far more important step of restoring the extension's
original install state.

`--platform windows-remote` drives everything from the Mac side over SSH
to an admin account on the Windows box: `bootstrap_remote_windows.ps1`
(piped over SSH) installs `pwsh` there if missing, `ps_scripts/build.sh`
builds the deployable script locally (no `pwsh` needed on the Mac), `scp`
copies just that one file over, and it's deleted again when the run
finishes. Also reachable via `js_scripts/run_all_tests.sh
--with-real-world-test` (see below), which runs it with `--platform mac`
after the mocked suite.

## macOS (js_scripts/)

| File | Purpose |
|---|---|
| `js_scripts/lib/set-vscode-extension-version-policy.js` | Pure decision logic: validates extension ids/version strings, parses `code --list-extensions --show-versions` output, decides no-op vs. install vs. upgrade vs. downgrade. |
| `js_scripts/lib/set-vscode-extension-version-runner.js` | OS-interaction glue: RTR contract (base64 in / JSON envelope out), runs the `code` CLI as the target user via `launchctl asuser` (resolved from the extension's install path; falls back to root's own isolated `HOME=/var/root` identity when no user can be confidently resolved), path-safety checks, diagnostics. |
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
INPUT=$(printf '%s' '{"params":{"extension_id":"ms-python.python","version":"2024.1.0","extension_path":"/Users/jdoe/.vscode/extensions/ms-python.python-2024.5.0"},"dry_run":true}' | base64)
sudo osascript -l JavaScript js_scripts/dist/set-vscode-extension-version.js "$INPUT"
```

Drop `"dry_run":true` (or set it to `false`) to actually perform the
install/upgrade/downgrade; leave it `true` to see what the script *would*
do without touching anything.

## Windows (ps_scripts/)

| File | Purpose |
|---|---|
| `ps_scripts/lib/Set-VSCodeExtensionVersion.Policy.ps1` | Same pure decision logic as the macOS policy module, ported 1:1 (extension id/version validation, installed-list parsing, the version-action decision, the outcome computation) - just a Windows path shape (`<drive>:\Users\<user>\.vscode\extensions\<leaf>`) for the extension-path parser. |
| `ps_scripts/lib/Set-VSCodeExtensionVersion.Runner.ps1` | OS-interaction glue - RTR contract, `code.cmd` discovery, path-safety checks, diagnostics. **Differs from macOS in two deliberate ways.** (1) Instead of impersonating the target user (there's no lightweight Windows equivalent of `launchctl asuser` short of token-duplication tricks), it runs `code.cmd` as whatever identity launched the script (typically SYSTEM under RTR) and passes the target user's extensions folder explicitly via VS Code CLI's own `--extensions-dir` flag. The fallback-when-unresolvable case points at SYSTEM's own (normally empty) extensions dir under `%SystemRoot%\System32\config\systemprofile`, the Windows analogue of the macOS side's `HOME=/var/root` isolation fix. (2) It also passes `--user-data-dir`, derived from `--extensions-dir` (never a separate parameter, never a different identity's profile) - real-world finding: the marketplace only serves a signature for an extension's *current latest* version, so pinning any older version (the entire point of this script's `--version` support) fails with "Signature verification failed: NotSigned" otherwise. `extensions.verifySignature` is temporarily set to `false` in that identity's own `settings.json` for the duration of each CLI call only, then the exact original raw file content is restored immediately after (or the file deleted if it didn't exist before) - never left changed, never touching a different user's settings. |
| `ps_scripts/build.ps1` | Concatenates each `lib/*.Policy.ps1` + `*.Runner.ps1` pair into `ps_scripts/dist/<name>.ps1`. |
| `ps_scripts/build.sh` | Same output as `build.ps1` (plain text concatenation, byte-for-byte), for building on a machine without `pwsh` - e.g. building on the Mac to deploy just the resulting single file onto a remote Windows box. Used by `real_world_check_set_vscode_extension_version.sh --platform windows-remote`. |
| `ps_scripts/run_all_tests.ps1` | Runs the Pester suite under `ps_scripts/tests/` natively. Requires Pester 5+ (`Install-Module Pester -Scope CurrentUser -MinimumVersion 5.0.0`). |
| `ps_scripts/run_all_tests.sh` | Runs that same suite either locally (if `pwsh` is on this machine's PATH: `--target local`) or remotely over SSH against a real Windows box (`--target windows-remote --host <ip> --user <user> (--key <path> \| --password <pw>)`) - mirrors the real-world check's remote plumbing; copies only `lib/`, `tests/`, and `run_all_tests.ps1` (no git needed on the remote box), bootstraps `pwsh` + Pester there if missing, and cleans up the scratch directory afterward. |
| `ps_scripts/bootstrap_remote_windows.ps1` | Idempotent: ensures `pwsh` is present on a remote Windows box. Piped over SSH by both `run_all_tests.sh` and the real-world check's `--platform windows-remote`. Must stay Windows-PowerShell-5.1-compatible, since `pwsh` may not exist yet the first time it runs. |
| `ps_scripts/tests/Set-VSCodeExtensionVersion.Policy.Tests.ps1` | Pester suite for the policy module - mirrors the macOS policy test suite's coverage scenario-for-scenario. |
| `ps_scripts/tests/Set-VSCodeExtensionVersion.Runner.Tests.ps1` | Mocked Pester suite for the runner module (mocks the single process-invocation seam plus the small filesystem seams) - mirrors the macOS runner test suite's coverage, plus dedicated tests pinning the JSON envelope's exact field casing and the signature-verification bypass's enable/restore behavior. |

```powershell
.\ps_scripts\build.ps1
.\ps_scripts\run_all_tests.ps1
```

```bash
ps_scripts/run_all_tests.sh --target local
ps_scripts/run_all_tests.sh --target windows-remote --host <ip> --user <admin-user> --password <pw>
```

Running the deployed script directly against a real machine:

```powershell
$json = '{"params":{"extension_id":"ms-python.python","version":"2024.1.0","extension_path":"C:\\Users\\jdoe\\.vscode\\extensions\\ms-python.python-2024.5.0"},"dry_run":true}'
$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($json))
.\ps_scripts\dist\Set-VSCodeExtensionVersion.ps1 $b64
```

Drop `"dry_run":true` (or set it to `false`) to actually perform the
install/upgrade/downgrade; leave it `true` to see what the script *would*
do without touching anything.

**Verified on real Windows/PowerShell** (a UTM VM, Windows 11 ARM64, driven
over SSH from the Mac - see the two scripts' `--platform`/`--target
windows-remote`): 77/77 Pester tests and 69/69 real-world scenarios pass.
This side was originally written and reviewed line-by-line on a Mac with
no Windows machine available, which did catch several real bugs before
ever running anything (PowerShell's `-and`/`-or` not short-circuiting the
way JS/C#'s `&&`/`||` do, `Process.Start` requiring `cmd.exe /c` to launch
`.cmd` files with `UseShellExecute=false`, .NET's documented
double-`WaitForExit()` requirement when redirecting streams, and a JSON
casing mismatch between PowerShell's idiomatic PascalCase and the required
snake_case wire schema) - but actually running it on real hardware found
several more that review alone couldn't have: Pester 6 dropping support
for `BeforeEach` declared directly at a container's root (only `BeforeAll`
is still allowed there - see `Runner.Tests.ps1`'s structure), `pwsh
-NoProfile -Command -` silently producing no output at all for multi-line
control-flow blocks (`if`/`else`, `try`/`catch`) fed over stdin via SSH -
no error, no bad exit code, just nothing (Windows PowerShell 5.1's
`-Command -` handles the identical pattern fine; see
`bootstrap_remote_windows.ps1`'s and `run_all_tests.sh`'s comments), and
the marketplace signature-verification behavior described above. Moral:
careful review narrows the bug surface, but isn't a substitute for
actually running the thing.
