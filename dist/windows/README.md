# set-vscode-extension-version (Windows)

Pins a VS Code extension to an exact version - upgrading or downgrading as
needed - or to latest if no version is given. **Never installs an
extension fresh**: if it isn't already present on the target machine, this
is a deliberate no-op.

`Set-VSCodeExtensionVersion.ps1` (PowerShell) is a single, self-contained
file - the only thing you need to copy onto a target Windows machine or
upload as an RTR/Glow Action Script. Regenerate it with `./build.sh` (or
`ps_scripts/build.ps1` directly, if you have `pwsh`) from the repo root
after pulling a new version; don't hand-edit anything under `dist/` - it's
generated from `ps_scripts/lib/` and gets overwritten on the next build.
See the sibling `mac/` directory (and its own `README.md`) for the
macOS/JXA port of this same script.

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
  `used_system_fallback` (true whenever user resolution fell back to
  SYSTEM's own isolated extensions dir instead of a resolved user's own -
  RTR always runs under SYSTEM here regardless, unlike macOS's
  `ran_as_root`, since there's no Windows equivalent of impersonating the
  target user for the CLI call itself; see `user_resolution_note` for
  why), `vscode_restarted`, and (on failure) a structured `error`.
  Stderr is always silent; every error is reported inside the envelope.
  Set `dry_run:true` to see what it *would* do without touching
  anything. A failure envelope reports this same full field list too,
  populated with whatever was already figured out before the failure
  occurred (safe `null`/`false` defaults for whatever wasn't reached
  yet) - never a smaller, differently-shaped object.

```powershell
$json = '{"params":{"extension_id":"ms-python.python","version":"2024.1.0","extension_path":"C:\\Users\\jdoe\\.vscode\\extensions\\ms-python.python-2024.5.0"},"dry_run":true}'
$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($json))
.\Set-VSCodeExtensionVersion.ps1 $b64
```

This script also carries its own comment-based help - run
`Get-Help .\Set-VSCodeExtensionVersion.ps1 -Full` on the deployed file
itself for this same contract, no repo checkout required.

- **A changed version only takes effect once VS Code is reloaded/restarted**
  - it does not hot-swap an active extension host's code on disk changing
  out from under it, and a managed tool can't rely on a user noticing a
  "reload required" prompt on their own. So after a real, successful,
  *changed* version update, this script checks whether the target user's
  VS Code is currently running and, if so, fully quits and relaunches it
  (the envelope's `vscode_restarted` field reports whether this
  succeeded). Never launched if it wasn't already running; never
  restarted for a no-op or dry-run action.
- **That restart is a real force-kill, not a graceful close, despite
  attempting the latter first.** Before force-killing, the script does
  try a graceful `WM_CLOSE` request (the same signal a user clicking the
  window's own close button sends) and waits up to 10s for VS Code to
  exit on its own - but confirmed directly, against a real VS Code
  window, that this reliably never succeeds in this script's actual
  deployment context: `.NET`'s `Process.MainWindowHandle` (what a
  graceful close needs) cannot see a window owned by a different login
  session, and a real RTR/managed deployment always runs
  non-interactively (as `SYSTEM`), in a different session than whichever
  interactive session is actually rendering VS Code's window.
  **Unsaved work in the target user's VS Code window will be lost** when
  a real, changed version update happens while it's open - there is no
  Windows equivalent of macOS's `launchctl asuser` that would let this
  reach the right session for a real graceful close. The 10s attempt is
  kept anyway (harmless, and a real no-op if some future Windows/RTR
  change ever does let it reach the right session), but don't rely on it
  actually protecting anyone's unsaved changes today. This asymmetry
  with macOS (see `mac/README.md`, where the equivalent restart genuinely
  is graceful) is a real platform limitation, not an oversight.
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
  `false` in the target identity's own `settings.json` for the duration
  of each CLI call only, then the file is restored to its exact original
  content immediately after (or deleted, if it didn't exist before) -
  never left changed. A real on-disk backup is written atomically (temp
  file + rename on the same volume) before touching anything and
  restored from that file, not memory, so a process killed mid-write
  can't lose the original content for good.
- **Files this script writes are legitimately owned by `SYSTEM`/
  Administrators, not the target user, and this script does NOT correct
  that afterward** (e.g. via `icacls`) - by design, not a bug, but a real
  known tradeoff worth knowing before you rely on this. There is no
  lightweight Windows equivalent of macOS's `launchctl asuser`, so the
  script instead runs `code.cmd` as whichever identity launched it
  (typically `SYSTEM` under RTR) and points `--extensions-dir`/
  `--user-data-dir` explicitly at the target user's own folders, relying
  entirely on NTFS ACL inheritance from those folders to grant that user
  real access to what got installed. This is reliable in the normal case
  (VS Code itself originally created those folders as the real user, with
  standard inheritable ACLs) but **not guaranteed** - a profile or
  extensions folder with non-standard/broken inheritance could leave the
  target user unable to actually use what this script just installed, with
  no error surfaced anywhere in the envelope (the write itself still
  succeeds; only the target user's later access would be affected). If
  that turns out to matter for your deployment, an explicit `icacls`
  access grant after writing would close this gap - not implemented here.

## Test coverage

- **Mocked unit tests** (safe to run anywhere, no real VS Code install or
  target account needed): 95 tests (56 runner + 39 policy), run under
  Pester. The policy module (pure decision logic - upgrade vs. downgrade
  vs. no-op) is tested directly; the runner module (the OS interaction
  glue) is tested with the single process-invocation seam mocked, plus a
  couple of chained CIM/WMI/.NET-method calls wrapped in their own
  dedicated, individually-mocked functions (`Get-VSCodeProcessOwners`,
  `Resolve-VSCodeUserProfilePath`, `Test-VSCodePathAccess`,
  `Invoke-VSCodeCloseMainWindow`) rather than mocking the underlying
  primitives directly - no real process is ever spawned.
- **Real-world end-to-end check**: 18 scenarios, shared verbatim with the
  macOS side where the underlying behavior is shared (only *how* each
  step runs differs), that really install/upgrade/downgrade a real, small
  extension and assert on the real result - not mocked. Covers the basic
  no-op/upgrade/downgrade matrix, dry-run safety, malformed/unsafe/missing
  `extension_path` handling (including a real "profile exists but is
  access-denied" case via a real deny-ACE test directory), SYSTEM-fallback
  identity isolation, resilience to VS Code's own passive extension-update
  sync (with a control extension proving the sync genuinely ran), real
  signature-verification enforcement, the restart-after-change behavior
  (independently confirmed by polling for VS Code's process to actually
  cycle to a new pid, not just trusting the envelope's own claim), and a
  real hung-`code`-CLI detection/kill/report scenario (the real binary
  swapped for a stub that hangs, run through the actual deployed
  contract). See this repo's own `test_logs/` for exact current pass/fail
  counts from the most recent full run.
- **Verified on real hardware**, not just mocked: a real Windows box
  (both an Azure VM over SSH, and a local UTM VM), invoked both directly
  and (once a device is sensor-enrolled) over a real CrowdStrike Falcon
  RTR session (`--platform windows-rtr`) - the real production deployment
  channel this script actually ships through: real put-file upload, a
  real session against a real sensor-enrolled device, real `runscript`
  invocation and polling.

## Build log

Real hardware found things careful review alone didn't catch:

- **The passive extension-update sync and the explicit `--update-extensions`
  CLI command behave differently** (see "Design" above) - found by
  testing both directly, not assumed from documentation.
- **Old/non-latest versions need the signature-verification bypass
  described above** - found here first, then confirmed to affect macOS
  too once the same scenario was added there.
- **A fixed sleep isn't long enough to observe a real marketplace
  install** - the passive-sync scenario's control-extension check
  originally used a fixed 15s sleep, long enough for an instant "already
  pinned, skip" decision but not reliably long enough for a real
  download-and-install; replaced with a poll (up to 90s).
- **`pwsh -NoProfile -Command -` silently drops multi-line control-flow
  blocks** (`if`/`else`, `try`/`catch`) fed over stdin via SSH - no
  error, no bad exit code, just nothing executed. This is a real-world
  check test-harness finding (how the check drives a remote Windows box
  over SSH), not a bug in the deployed script itself, but it had made
  the real-world check's own signature-enforcement setup a complete
  no-op for a time. Fixed by writing each remote PowerShell call to a
  real temp `.ps1` file and running it via `pwsh -File` instead of
  piping it over stdin.
- **The test VM's network to the marketplace is occasionally flaky**
  (real `ETIMEDOUT`s, not a script bug) - mitigated with retries around
  real-network install calls and a persistent local side-cache of this
  suite's fixed pinned test versions, restored into VS Code's live cache
  before each install that needs one, so repeat test runs don't depend
  on that network being healthy every single time.
- **A graceful restart is not actually achievable from this script's
  real deployment context** - see "Design" above for the full
  explanation (`Process.MainWindowHandle` can't see a window owned by a
  different login session, and RTR always runs non-interactively).
  Confirmed directly against a real VS Code window under a real
  RTR-shaped session: every real `Code.exe` process showed
  `MainWindowHandle=0` from that vantage point, and the graceful attempt
  reliably burns its full ~10s wait before falling through to a
  force-kill, every time. Kept anyway as a real no-op safety margin
  rather than reverted to an immediate force-kill.
- **Three `.NET` surface assumptions were PowerShell 7-only, silently
  broken under real RTR's actual runtime** -
  `ProcessStartInfo.ArgumentList` is `$null` under Windows PowerShell 5.1
  (fixed: build the argument string manually, Win32/CommandLineToArgvW-
  compatible quoting); `Process.Kill($true)` (kill the entire child-
  process tree) is a .NET Core-only overload that throws under 5.1's
  .NET Framework, previously silently swallowed - and even the naive
  single-process `Kill()` fallback isn't enough, since `code.cmd` is
  always launched via a `cmd.exe` wrapper whose own children were left
  orphaned and running; fixed with `taskkill /T /F`, confirmed to
  actually kill the whole tree. `ConvertFrom-Json -AsHashtable` is
  PowerShell 6+-only; fixed by walking `.PSObject.Properties` instead,
  which works on both. This project's own mocked/SSH-driven testing
  never caught any of these - it always exercised a bootstrapped `pwsh`
  7, never real RTR's actual `powershell.exe` 5.1.
- **A process killed mid-write could lose settings.json's original
  content for good** - the signature-verification bypass used to keep
  the original raw content only in this process' own memory while
  temporarily disabling `extensions.verifySignature`; a process killed
  before its own restore step ran (a real RTR timeout, session
  termination, ...) left that setting stuck `false` with no way back.
  Now also writes a real on-disk backup before touching anything, and
  restores from that file, not memory - and the write itself is atomic
  (temp file + rename on the same volume), matching what the macOS
  side's own write already guaranteed.
- **`Test-Path`'s bare boolean can't tell "doesn't exist" from "access
  denied"** - a target user's profile that genuinely exists but can't
  actually be read/written (restrictive NTFS permissions, ...) was
  silently reported the same way as "this account has no profile at
  all". Confirmed directly with a real `deny everyone full control` ACE
  that neither `Get-Item` nor `Get-ChildItem` reliably detects it for an
  Administrator-group account (real reads/lists apparently don't hit the
  same access check this cares about) - only a real write-and-delete
  probe does, matching the actual failure this exists to catch.
- **`C:\Users\<user>` is not always where a user's profile actually
  lives** - a relocated profile (another drive) or a folder name that no
  longer matches the account's current login name (Windows keeps the
  original folder name across a rename) silently fell through the
  cracks. Fixed by resolving the real path via `Win32_UserProfile`
  (translate the username to its SID, look up that SID's own
  `LocalPath`), falling back to the naive guess only if that lookup
  itself fails.
- **`vscode_restarted` could report `true` even when the relaunch itself
  silently failed** - the Scheduled Task registration and
  `Start-ScheduledTask` call were wrapped in a `try/catch` that only
  logged the error to diag, while the function unconditionally returned
  `true` afterward regardless of what happened inside that block. A real
  failure (a rejected principal/logon type, no interactive session for
  the target user, ...) was indistinguishable in the envelope from a
  genuine successful relaunch. Fixed by tracking success with a flag set
  only immediately after `Start-ScheduledTask` itself succeeds, and
  returning that instead of a literal `true`.
- **A failure envelope used to be a much smaller object than a success
  envelope** - it only ever carried `status`/`error`/`dry_run`/
  timestamps/`metadata`, missing every other field a success envelope
  always has (`extension_id`, `target_user`, `used_system_fallback`,
  `cli_result`, ...). A caller had to special-case a failure response's
  shape instead of reading the same fields either way. Fixed by having
  every failure path report the full field list, populated with
  whatever was already figured out before the failure occurred, so a
  failure envelope is always the same shape a success envelope has,
  never a different one.
- **Exactly one VS Code process running for the target user broke the
  restart's own running-process checks** - `Restart-VSCodeIfRunning`
  reads `.Count` off whatever `Get-VSCodeRunningPidsForUser` returns, but
  a PowerShell function's `return @(...)` does not survive the trip
  through the pipeline/output-stream boundary back to its caller: zero
  matches comes back as `$null`, and - the case that actually bit here -
  exactly one match comes back as a bare scalar, not a one-element
  array. PowerShell 7+ silently masks this (it added a universal `Count`
  property to all scalars), which is exactly why this script's own
  earlier pwsh-7-bootstrapped test history never caught it; real RTR
  runs under Windows PowerShell 5.1, where a bare scalar has no such
  property. Under the default non-strict mode this silently miscomputed
  every comparison against it instead of erroring (`$null -gt 0` and
  `$null -eq 0` are both `$false`); enabling `Set-StrictMode -Version
  Latest` (see below) turned that into a loud, catchable
  `PropertyNotFoundException` instead - which is exactly how this was
  actually found. Fixed by wrapping every call site in `@(...)`, not
  just the function's own internal return value.
- **`Set-StrictMode -Version Latest` added to the deployed script** -
  turns silent `$null`s from missing-property access and
  uninitialized-variable references into loud, catchable errors instead
  of quietly computing the wrong thing. `Get-VSCodeRunOutcome` needed a
  defensive rewrite first (it used to read `$ActionResult.Stderr`/`.Ok`
  assuming PowerShell's default non-strict "missing property returns
  `$null`" behavior - see its own `Get-VSCodePolicyProp` helper), and
  this is also what surfaced the process-count bug directly above.
  Validated by re-running the full mocked Pester suite against a real
  Windows box with strict mode on, not just the one function that
  motivated it.

See the repo root's own `README.md` for full architecture details, and
`real_world_check_set_vscode_extension_version.sh --help` for every
option the real-world check itself supports (including `--scenario N` to
run just one scenario in isolation while debugging).
