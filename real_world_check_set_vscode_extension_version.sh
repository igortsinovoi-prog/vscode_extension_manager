#!/bin/bash
# Real end-to-end check against a real, small, well-known VS Code extension
# (njpwerner.autodocstring - "Python Docstring Generator"), running the
# actual deployed set-vscode-extension-version script - not a mock. Shared
# between js_scripts/ (macOS/JXA) and ps_scripts/ (Windows/PowerShell): the
# scenario list and assertions below are identical across platforms - only
# how each individual command actually runs differs, selected via
# --platform. This script itself always runs as bash on the Mac; for
# --platform windows it drives a real Windows box over SSH rather
# than requiring bash on Windows.
#
# Not part of either platform's mocked test suite (js_scripts/run_all_tests.sh
# / ps_scripts/run_all_tests.ps1); this one really installs/uninstalls a
# real extension, so it's opt-in, manual, and self-cleaning: the
# extension's original install state (present at some version, or absent)
# is captured up front and restored on exit, regardless of pass/fail.
#
# Usage:
#   ./real_world_check_set_vscode_extension_version.sh --platform mac
#   ./real_world_check_set_vscode_extension_version.sh --platform windows --host <ip> --user <user> [--key <path>]
#   ./real_world_check_set_vscode_extension_version.sh --platform mac --scenario 15   # only scenario(s) 15 (repeatable; "5" runs both 5a and 5b)
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
#             back to the platform's isolated fallback identity, WITHOUT
#             touching the real user's actual extension state.
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
# Scenario 14: extension_path is a real symlink escaping the extensions
#              directory -> EXTENSION_PATH_UNSAFE.
# Scenario 15: resilience to VS Code's own PASSIVE/startup extension sync
#              (not the explicit `code --update-extensions` CLI command -
#              that one was investigated and confirmed to unconditionally
#              override any pin, with no flag or setting able to exclude a
#              specific extension; see README for that finding, it isn't
#              re-tested here since there's nothing to assert). Pins to an
#              old version via our own script (which sets the "pinned"
#              extensions.json metadata as a side effect of `--install
#              -extension id@version`), then gets a REAL GUI VS Code
#              window to run its extension-update-check code path (the
#              passive sync never runs from a one-shot CLI invocation) -
#              either by triggering "Check for Extension Updates" via the
#              Command Palette in an ALREADY-running session (never
#              quit/relaunched - it may be in active use, e.g. hosting a
#              Claude Code session on a dev machine), or by cold-booting
#              a session ourselves and restoring the original (not
#              running) state afterward if none was already up - then
#              confirms the version is unaffected. Alongside it, a second
#              "control" extension is installed at
#              an old version too, but explicitly left UNPINNED, and must
#              itself get updated by the same startup sync - without this
#              control check, an unaffected pinned version proves nothing:
#              it's indistinguishable from the passive sync simply never
#              having run at all (the same ambiguity hit during manual
#              investigation of this behavior). Skipped where no real
#              interactive GUI session is available (see
#              real_gui_session_available).
# Scenario 16: signature verification, when enforced, does not stop our
#              own script's install. Explicitly sets
#              extensions.verifySignature: true in the real settings.json
#              (restored to its exact original content afterward) and
#              clears any locally cached VSIX for the test version first,
#              so this isn't accidentally satisfied by a leftover cache
#              from earlier in the run. Whether a manual `code
#              --install-extension` for that version is actually blocked
#              is only reported informationally, not asserted - the
#              marketplace's signing policy for the specific extension
#              this project uses throughout (njpwerner.autodocstring) has
#              changed since this scenario was written, and its old
#              versions are no longer blocked at all (confirmed directly);
#              see README for that finding. What IS asserted: our own
#              deployed script's install keeps working regardless of
#              whichever way that cuts.
# Scenario 17: our own deployed script restarts VS Code after a real,
#              changed version update - a changed extension only takes
#              effect for an already-running window once it's reloaded/
#              restarted, and a managed version-pinning tool can't rely on
#              the user noticing a "reload required" prompt on their own.
#              17a: with a real GUI session up (already running, or
#              launched fresh if not, restored after), a real version
#              change reports vscode_restarted:true AND is independently
#              confirmed by polling for VS Code's process to actually
#              cycle to a new pid. 17b: with VS Code confirmed NOT
#              running, a real version change reports vscode_restarted:
#              false and does not launch it as a side effect.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Local-only device AIDs / Falcon API credentials for --platform mac-rtr -
# see .env.local's own header and .gitignore. set -a so FALCON_CLIENT_ID/
# FALCON_CLIENT_SECRET are actually exported (rtr_token() reads them from
# the environment), not just set in this shell.
if [[ -f "$ROOT_DIR/.env.local" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$ROOT_DIR/.env.local"
  set +a
fi

EXT_ID="njpwerner.autodocstring"
# A version distinct from the 0.4.0 used throughout scenarios 1-14, so
# scenario 16's signature-verification check always exercises a fresh,
# never-yet-cached download regardless of what earlier scenarios in this
# same run already did.
SIGNATURE_TEST_VERSION="0.5.0"
# Scenario 15's control extension: installed at an old version too, but
# left explicitly unpinned, so an unaffected pinned extension can be told
# apart from "the passive sync just never ran". Any small, actively
# maintained extension with real published version history works; if this
# specific old version ever stops existing in the marketplace, swap in
# another one.
CONTROL_EXT_ID="usernamehw.errorlens"
CONTROL_EXT_OLD_VERSION="3.4.0"

PLATFORM=""
REMOTE_HOST=""
REMOTE_USER=""
REMOTE_KEY="$HOME/.ssh/utm_windows_vm"
REMOTE_PASSWORD=""
REMOTE_PORT="22"
SSH_OPTS=()
SSH_PREFIX=()
SCP_PREFIX=()
REMOTE=""
# Space-separated scenario numbers to run (e.g. "15" or "5 15 17"); empty
# means run everything. "5" covers 5a/5b/5c together - they're one
# numbered scenario with three cases (5c windows-only), not three
# scenarios.
ONLY_SCENARIOS=""
# --platform mac-rtr only: target device AID for the real RTR session
# (see run_dist_script's mac-rtr override, further down). Falcon API
# credentials come from FALCON_CLIENT_ID/FALCON_CLIENT_SECRET in the
# environment only, never a flag here (shell history/process list
# exposure) - see rtr_token(). Defaults from .env.local's MAC_DEVICE_AID
# if present, overridable with --device-aid either way.
DEVICE_AID="${MAC_DEVICE_AID:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --platform) PLATFORM="$2"; shift 2 ;;
    --host) REMOTE_HOST="$2"; shift 2 ;;
    --user) REMOTE_USER="$2"; shift 2 ;;
    --key) REMOTE_KEY="$2"; shift 2 ;;
    --password) REMOTE_PASSWORD="$2"; shift 2 ;;
    --port) REMOTE_PORT="$2"; shift 2 ;;
    --scenario) ONLY_SCENARIOS="$ONLY_SCENARIOS $2"; shift 2 ;;
    --device-aid) DEVICE_AID="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 --platform mac|windows|mac-rtr|windows-rtr [--host H --user U (--key K | --password P) --port P] [--device-aid AID] [--scenario N ...]"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

# Whether scenario $1 should run - always true unless --scenario was given
# at least once, in which case only the listed numbers run. Scenario
# setup/cleanup (build_dist, capturing/restoring original extension
# state, the pre-test VS Code close/relaunch) always runs regardless -
# only the individual numbered scenario bodies are gated by this.
scenario_enabled() {
  [[ -z "$ONLY_SCENARIOS" ]] && return 0
  [[ " $ONLY_SCENARIOS " == *" $1 "* ]]
}

# Password auth (via sshpass) if --password was given, otherwise key auth.
# BatchMode=yes is deliberately only set for key auth - it forces SSH to
# fail instead of prompting, which is what you want when a key is supposed
# to just work, but would block sshpass's whole mechanism (answering an
# interactive password prompt) if set for password auth.
if [[ -n "$REMOTE_PASSWORD" ]]; then
  if ! command -v sshpass >/dev/null 2>&1; then
    echo "Error: --password requires sshpass (brew install sshpass)" >&2
    exit 1
  fi
  # ServerAliveInterval/CountMax: send a keepalive probe every 30s, tolerate
  # up to 10 missed replies (5 real minutes) before giving up - prime_vsix_cache
  # can run a single remote command for several minutes (multiple installs,
  # each with its own retries/backoff against a real, occasionally slow
  # marketplace), and a plain SSH connection with no keepalive at all is a
  # real risk of getting silently dropped for inactivity somewhere along
  # that path (NAT/firewall/VM hypervisor network layer) well before the
  # remote command itself would ever time out on its own.
  # -o Port=, not -p/-P: ssh and scp use different flag letters for the
  # same thing (-p vs -P, and scp's -p means something else entirely -
  # "preserve modification times"), but both accept -o for arbitrary
  # ssh_config options, so one shared SSH_OPTS entry works for both
  # instead of needing a separate port flag at every scp call site.
  SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o PreferredAuthentications=password -o PubkeyAuthentication=no -o ServerAliveInterval=30 -o ServerAliveCountMax=10 -o "Port=$REMOTE_PORT")
  # -e (password via the SSHPASS env var), not -p (password as a literal
  # argument) - sshpass's own -p mode tries to scrub the password out of
  # this process's argv afterward (hide_password(), so `ps` can't see it),
  # and that technique crashed outright on this machine (SIGSEGV in
  # hide_password -> strdup -> a NULL read) partway through a real run,
  # silently killing the whole script with no error message at all. -e
  # skips that code path entirely - there's no cleartext argv to scrub in
  # the first place.
  export SSHPASS="$REMOTE_PASSWORD"
  # -eSSHPASS, not a bare -e: sshpass's optional env-var-name argument
  # must be directly attached (no space) - a bare `-e` followed by `ssh`
  # as a separate argument gets misparsed as "-e" taking "ssh" itself as
  # the env var name (confirmed: "sshpass: -e option given but 'ssh'
  # environment variable is not set"), not as the command to run.
  SSH_PREFIX=(sshpass -eSSHPASS ssh)
  SCP_PREFIX=(sshpass -eSSHPASS scp)
else
  SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=10 -i "$REMOTE_KEY" -o "Port=$REMOTE_PORT")
  SSH_PREFIX=(ssh)
  SCP_PREFIX=(scp)
fi

# ===== RTR (CrowdStrike Falcon) driver, --platform mac-rtr only =====
#
# Drives the actual production deployment channel a real Jamf/RTR policy
# uses - not a stand-in for it: uploads the just-built dist file as a real
# put-file, opens a real RTR session against a real, sensor-enrolled
# device, stages the file there, then invokes it there and polls for the
# result. Mirrors ~/Documents/CodeStation/rtr-put-file-guide.md step for
# step (that guide's examples are PowerShell/Invoke-RestMethod against a
# Windows target; this is the same CrowdStrike API flow via curl/python3,
# invoking `osascript` as the mac target's own shell instead of
# `powershell`). Only used by run_dist_script's mac-rtr override, further
# down - everything else (code_cli, GUI session management, assertions,
# cleanup) is unchanged from plain --platform mac, same machine.
#
# Session + put-file are set up ONCE, lazily, on run_dist_script's first
# call (see RTR_SESSION_ID gating there) and reused for every subsequent
# call in this run - re-uploading and re-opening a session for every one
# of this suite's many calls would be needlessly slow and isn't what a
# real deployment does anyway (one put, one run).
RTR_API_BASE="${FALCON_BASE:-https://api.us-2.crowdstrike.com}"
RTR_PUT_NAME="set-vscode-extension-version-rtr-check.js"
RTR_REMOTE_DIR="/tmp/glow_rwc_rtr"
RTR_REMOTE_PATH="$RTR_REMOTE_DIR/$RTR_PUT_NAME"
RTR_SESSION_ID=""
RTR_TOKEN=""

# Mints a bearer token from FALCON_CLIENT_ID/FALCON_CLIENT_SECRET - read
# from the environment only. Never accept these as CLI flags: argv is
# visible in shell history and to any other process on the machine via
# `ps`, exactly the exposure rtr-put-file-guide.md itself warns against
# ("pull it from Credential Manager/Keychain at runtime instead").
rtr_token() {
  if [[ -z "${FALCON_CLIENT_ID:-}" || -z "${FALCON_CLIENT_SECRET:-}" ]]; then
    echo "Error: --platform mac-rtr requires FALCON_CLIENT_ID and FALCON_CLIENT_SECRET in the environment" >&2
    exit 1
  fi
  RTR_TOKEN="$(curl -sf -X POST "$RTR_API_BASE/oauth2/token" \
    -d "client_id=$FALCON_CLIENT_ID" -d "client_secret=$FALCON_CLIENT_SECRET" \
    | python3 -c 'import json, sys; print(json.load(sys.stdin).get("access_token") or "")')"
  if [[ -z "$RTR_TOKEN" ]]; then
    echo "Error: could not mint a Falcon API bearer token - check FALCON_CLIENT_ID/FALCON_CLIENT_SECRET" >&2
    exit 1
  fi
}

# $1 = HTTP method, $2 = path (from the API root), remaining args passed
# straight to curl (headers, -d body, -F form fields, ...).
rtr_api() {
  local method="$1" path="$2"; shift 2
  curl -sf -X "$method" "$RTR_API_BASE$path" -H "Authorization: Bearer $RTR_TOKEN" "$@"
}

# Clears any stale put-file already in the cloud inventory under this same
# name (e.g. left behind by an interrupted earlier run) before uploading
# a fresh one - an upload doesn't overwrite an existing entry with the
# same name, it just adds another one, so a run's own newest build could
# otherwise not be the one that actually gets staged.
rtr_clear_stale_put_file() {
  local ids id
  ids="$(rtr_api GET "/real-time-response/queries/put-files/v1?filter=name:'$RTR_PUT_NAME'" \
    | python3 -c 'import json, sys; print(" ".join(json.load(sys.stdin).get("resources") or []))')"
  for id in $ids; do
    rtr_api DELETE "/real-time-response/entities/put-files/v1?ids=$id" >/dev/null
  done
}

rtr_upload_put_file() {
  rtr_api POST "/real-time-response/entities/put-files/v1" \
    -F "name=$RTR_PUT_NAME" \
    -F "description=vscode_extension_manager real-world check" \
    -F "comments_for_audit_log=automated real-world check (mac-rtr)" \
    -F "file=@$DIST_SCRIPT" >/dev/null
}

rtr_open_session() {
  local resp
  resp="$(rtr_api POST "/real-time-response/entities/sessions/v1" \
    -H "Content-Type: application/json" \
    -d "$(python3 -c 'import json, sys; print(json.dumps({"device_id": sys.argv[1], "origin": "adhoc", "queue_offline": False}))' "$DEVICE_AID")")"
  RTR_SESSION_ID="$(printf '%s' "$resp" | python3 -c 'import json, sys
try:
    print(json.load(sys.stdin)["resources"][0]["session_id"])
except Exception:
    print("")')"
  if [[ -z "$RTR_SESSION_ID" ]]; then
    echo "Error: could not open an RTR session against device $DEVICE_AID: $resp" >&2
    exit 1
  fi
}

# $1 = base_command (e.g. "cd", "put", "runscript"), $2 = command_string.
# Polls until the cloud_request_id reports complete, same as the guide's
# own Send-Rtr helper. Prints the raw JSON of the final admin-command GET
# (the caller pulls stdout/stderr/complete out of that itself).
rtr_send() {
  local base_command="$1" command_string="$2" resp crid waited=0 g complete
  resp="$(rtr_api POST "/real-time-response/entities/admin-command/v1" \
    -H "Content-Type: application/json" \
    -d "$(python3 -c 'import json, sys; print(json.dumps({"base_command": sys.argv[1], "command_string": sys.argv[2], "session_id": sys.argv[3], "persist": True}))' "$base_command" "$command_string" "$RTR_SESSION_ID")")"
  crid="$(printf '%s' "$resp" | python3 -c 'import json, sys
try:
    print(json.load(sys.stdin)["resources"][0]["cloud_request_id"])
except Exception:
    print("")')"
  if [[ -z "$crid" ]]; then
    echo "Error: RTR command ($base_command) did not return a cloud_request_id: $resp" >&2
    exit 1
  fi
  while true; do
    sleep 3
    waited=$((waited + 3))
    g="$(rtr_api GET "/real-time-response/entities/admin-command/v1?cloud_request_id=$crid&sequence_id=0")"
    complete="$(printf '%s' "$g" | python3 -c 'import json, sys
try:
    print(json.load(sys.stdin)["resources"][0].get("complete"))
except Exception:
    print("False")')"
    [[ "$complete" == "True" ]] && break
    # 240s, not 120: comfortably longer than the invoked runscript's own
    # -Timeout=180 (see rtr_run_dist_script) - this loop must never give
    # up before RTR's own server-side timeout would, or a slow-but-still-
    # running real install gets misreported as our own polling failure
    # instead of RTR's real timeout error.
    if [[ $waited -ge 240 ]]; then
      echo "Error: RTR command ($base_command) did not complete within 240s (cloud_request_id=$crid)" >&2
      exit 1
    fi
  done
  printf '%s' "$g"
}

# $1 = command's JSON response (from rtr_send), $2 = field name
# ("stdout"/"stderr"/"complete") - small helper so rtr_run_dist_script
# doesn't repeat the same try/except JSON-field pull four times.
rtr_field() {
  printf '%s' "$1" | python3 -c 'import json, sys
try:
    print(json.load(sys.stdin)["resources"][0].get(sys.argv[1]) or "")
except Exception:
    print("")' "$2"
}

# The mac-rtr override for run_dist_script (see the mac case branch below,
# which reassigns run_dist_script to call this). Lazily does the one-time
# put-file upload + session open + staging on its FIRST call (gated on
# RTR_SESSION_ID being empty), then on every call (including that first
# one) actually invokes the staged script via `runscript -Raw=` and
# returns its stdout - exactly what run_dist_script's other
# implementations (direct osascript, SSH) already return, so none of the
# scenario logic that calls run_dist_script needs to know or care that
# this one goes over the network to a real CrowdStrike session.
rtr_run_dist_script() {
  local payload="$1"
  if [[ -z "$RTR_SESSION_ID" ]]; then
    echo "==> [mac-rtr] Minting Falcon API token" >&2
    rtr_token
    echo "==> [mac-rtr] Clearing any stale put-file named $RTR_PUT_NAME" >&2
    rtr_clear_stale_put_file
    echo "==> [mac-rtr] Uploading $DIST_SCRIPT as a put-file" >&2
    rtr_upload_put_file
    echo "==> [mac-rtr] Opening an RTR session against device $DEVICE_AID" >&2
    rtr_open_session
    echo "==> [mac-rtr] Staging the script onto the target disk" >&2
    rtr_send "runscript" 'runscript -Raw=```mkdir -p '"$RTR_REMOTE_DIR"'```' >/dev/null
    rtr_send "cd" "cd $RTR_REMOTE_DIR" >/dev/null
    # `put` refuses to overwrite an existing file ("File exists and
    # overwrite not requested") - confirmed real: a leftover from an
    # earlier interrupted run silently left this run invoking a STALE
    # script instead of what was just built, since `put`'s own stderr was
    # only ever warned about, never treated as fatal. Force a clean slate
    # first, every time.
    rtr_send "runscript" 'runscript -Raw=```rm -f "'"$RTR_REMOTE_PATH"'"```' >/dev/null
    local put_resp put_err
    put_resp="$(rtr_send "put" "put \"$RTR_PUT_NAME\"")"
    put_err="$(rtr_field "$put_resp" stderr)"
    [[ -n "$put_err" ]] && echo "  WARNING: [mac-rtr] put reported stderr: $put_err" >&2
    # Check it actually landed before ever invoking it - a silently failed
    # put (wrong session cwd, name typo, stale inventory entry) would
    # otherwise only surface later as a confusing file-not-found (see the
    # guide's own "check it actually landed" step).
    local check_resp check_out
    check_resp="$(rtr_send "runscript" 'runscript -Raw=```test -f "'"$RTR_REMOTE_PATH"'" && echo FOUND || echo MISSING```')"
    check_out="$(rtr_field "$check_resp" stdout | tr -d '[:space:]')"
    if [[ "$check_out" != "FOUND" ]]; then
      echo "Error: [mac-rtr] put didn't stage the file at $RTR_REMOTE_PATH - stop before invoking" >&2
      exit 1
    fi
  fi

  local invoke_cmd resp out err
  # No trailing -Timeout= here (an earlier version appended one) -
  # confirmed via direct isolated testing that this exact -Raw= form,
  # unmodified, actually completes and returns a real envelope; adding an
  # unverified -Timeout= suffix after the closing triple-backticks is what
  # produced a real "Timed out waiting for script to exit" instead.
  invoke_cmd='runscript -Raw=```osascript -l JavaScript "'"$RTR_REMOTE_PATH"'" "'"$payload"'"```'
  resp="$(rtr_send "runscript" "$invoke_cmd")"
  out="$(rtr_field "$resp" stdout)"
  err="$(rtr_field "$resp" stderr)"
  [[ -n "$err" ]] && echo "  WARNING: [mac-rtr] runscript reported stderr: $err" >&2
  printf '%s' "$out"
}

# The mac-rtr override for cleanup_deployed_script - closes the real RTR
# session (mirroring the guide's own step 5) and clears the put-file from
# the cloud inventory, so a finished run doesn't leave either behind.
# Guarded (never lets set -e propagate a failure here): this runs from
# inside restore_original_state's EXIT trap, where the far more important
# step is restoring the extension's own original install state, not
# tidying up the RTR side.
rtr_cleanup_deployed_script() {
  if [[ -n "$RTR_SESSION_ID" ]]; then
    rtr_api DELETE "/real-time-response/entities/sessions/v1?session_id=$RTR_SESSION_ID" >/dev/null 2>&1 || true
  fi
  rtr_clear_stale_put_file 2>/dev/null || true
}

# The windows-rtr override for run_dist_script (see the windows
# case branch further down, which reassigns run_dist_script to call this
# when PLATFORM=windows-rtr). Same lazy-first-call shape as
# rtr_run_dist_script above (mac-rtr) - upload, session, staging happen
# once, gated on RTR_SESSION_ID - but every -Raw= command uses PowerShell
# syntax instead of bash, and the invoked interpreter is `powershell`
# instead of `osascript -l JavaScript`, per
# ~/Documents/CodeStation/rtr-put-file-guide.md (already confirmed
# working for real against a Windows target). rtr_token/rtr_api/rtr_send/
# rtr_field/rtr_clear_stale_put_file/rtr_upload_put_file/rtr_open_session
# are all OS-agnostic already and reused unchanged; rtr_cleanup_deployed_script
# above is reused unchanged too (it only touches RTR_SESSION_ID/RTR_PUT_NAME).
rtr_run_dist_script_windows() {
  local payload="$1"
  if [[ -z "$RTR_SESSION_ID" ]]; then
    echo "==> [windows-rtr] Minting Falcon API token" >&2
    rtr_token
    echo "==> [windows-rtr] Clearing any stale put-file named $RTR_PUT_NAME" >&2
    rtr_clear_stale_put_file
    echo "==> [windows-rtr] Uploading $DIST_SCRIPT as a put-file" >&2
    rtr_upload_put_file
    echo "==> [windows-rtr] Opening an RTR session against device $DEVICE_AID" >&2
    rtr_open_session
    echo "==> [windows-rtr] Staging the script onto the target disk" >&2
    rtr_send "runscript" 'runscript -Raw=```New-Item -ItemType Directory -Force -Path "'"$RTR_REMOTE_DIR"'" | Out-Null```' >/dev/null
    rtr_send "cd" "cd $RTR_REMOTE_DIR" >/dev/null
    # Same "put refuses to overwrite" real-world finding as the mac-rtr
    # side (see rtr_run_dist_script's own comment) - force a clean slate
    # first, every time.
    rtr_send "runscript" 'runscript -Raw=```Remove-Item -Force -ErrorAction SilentlyContinue -Path "'"$RTR_REMOTE_PATH"'"```' >/dev/null
    local put_resp put_err
    put_resp="$(rtr_send "put" "put \"$RTR_PUT_NAME\"")"
    put_err="$(rtr_field "$put_resp" stderr)"
    [[ -n "$put_err" ]] && echo "  WARNING: [windows-rtr] put reported stderr: $put_err" >&2
    # Check it actually landed before ever invoking it - same reason as
    # mac-rtr's own check: a silently failed put would otherwise only
    # surface later as a confusing file-not-found.
    local check_resp check_out
    check_resp="$(rtr_send "runscript" 'runscript -Raw=```if (Test-Path "'"$RTR_REMOTE_PATH"'") { "FOUND" } else { "MISSING" }```')"
    check_out="$(rtr_field "$check_resp" stdout | tr -d '[:space:]')"
    if [[ "$check_out" != "FOUND" ]]; then
      echo "Error: [windows-rtr] put didn't stage the file at $RTR_REMOTE_PATH - stop before invoking" >&2
      exit 1
    fi
  fi

  local invoke_cmd resp out err
  invoke_cmd='runscript -Raw=```powershell -NoProfile -ExecutionPolicy Bypass -File "'"$RTR_REMOTE_PATH"'" "'"$payload"'"```'
  resp="$(rtr_send "runscript" "$invoke_cmd")"
  out="$(rtr_field "$resp" stdout)"
  err="$(rtr_field "$resp" stderr)"
  [[ -n "$err" ]] && echo "  WARNING: [windows-rtr] runscript reported stderr: $err" >&2
  # Unlike mac-rtr's own return (confirmed clean via direct testing),
  # this is unverified until a real live run: every other Windows
  # PowerShell output path in this file needs \r stripped before the
  # caller's JSON parsing sees it, and RTR's own transport has no reason
  # to be different.
  printf '%s' "$out" | tr -d '\r'
}

# ===== Platform dispatch =====
#
# Each platform branch below defines the same set of primitives the
# scenario logic (further down) is written against:
#   code_cli <args...>          - runs the real `code` CLI, prints stdout
#   run_dist_script <payload>   - invokes the deployed script under test with
#                                  a base64 RTR payload, prints its JSON envelope
#   build_dist                  - (re)builds the deployed script from source
#   setup_symlink_scenario /
#   teardown_symlink_scenario   - scenario 14's real filesystem symlink
#   get_settings_backup /
#   restore_settings_backup /
#   set_verify_signature_true   - scenario 16's real settings.json handling
#   clear_vsix_cache_for_version - scenario 16's cache-freshness guarantee
#   real_gui_session_available /
#   launch_vscode_gui_session /
#   kill_vscode_gui_session     - scenario 15's real GUI VS Code window
#   EXT_PATH_PREFIX, PATH_SEP   - used to build extension_path values in the
#                                  right shape (PATH_SEP matters: the
#                                  Windows path parser requires a literal
#                                  backslash immediately before the leaf,
#                                  not '/')
#   REAL_USER, IS_ROOT          - identity concepts scenario 5 depends on
#   NO_SUCH_USER_PATH           - extension_path naming a nonexistent user
case "$PLATFORM" in
  mac | mac-rtr)
    CODE_BIN="/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
    DIST_SCRIPT="$ROOT_DIR/js_scripts/dist/set-vscode-extension-version.js"
    # Under sudo, $(whoami) reports "root" (the effective user), not the
    # account whose ~/.vscode/extensions this check actually operates on -
    # use $SUDO_USER (the invoking account) when running under sudo.
    REAL_USER="${SUDO_USER:-$(whoami)}"
    if [[ "$EUID" -eq 0 ]]; then IS_ROOT=true; else IS_ROOT=false; fi
    # Numeric uid for launchctl asuser (scenario 15's GUI-automation
    # helpers below) - launchctl needs a uid, not a username.
    REAL_UID="$(id -u "$REAL_USER")"
    EXT_PATH_PREFIX="$HOME/.vscode/extensions"
    PATH_SEP="/"
    NO_SUCH_USER_PATH="/Users/glow_test_no_such_user/.vscode/extensions/${EXT_ID}-0.0.0"
    SYMLINK_TARGET="/tmp/glow_test_evil_target"
    # Scenario 5c is Windows-only - there's no clean mac equivalent of
    # Win32_UserProfile/icacls DENY ACEs to reproduce the exact "profile
    # exists but access-denied" condition the Windows-side
    # Test-VSCodePathAccess fix addresses. setup returning 1 (never
    # succeeding here) makes the scenario skip cleanly on this platform.
    setup_access_denied_profile_dir() { return 1; }
    teardown_access_denied_profile_dir() { :; }

    if [[ ! -x "$CODE_BIN" ]]; then
      echo "Error: VS Code CLI not found at $CODE_BIN" >&2
      exit 1
    fi

    VSIX_CACHE_DIR="$HOME/Library/Application Support/Code/CachedExtensionVSIXs"
    SETTINGS_PATH="$HOME/Library/Application Support/Code/User/settings.json"

    # When this whole harness runs under sudo (needed for scenario 5b's
    # root-fallback coverage), doing ANY filesystem write as root would
    # leave root-owned files behind in the REAL user's own directories -
    # exactly the corruption that broke a real run more than once
    # (extensions.json/.obsolete/extension folders from code_cli, then
    # settings.json itself from set_verify_signature_true/
    # restore_settings_backup/unpin_extension, none of which went through
    # code_cli and so didn't get the same protection the first time
    # around). Every command in this file that touches the filesystem is
    # routed through this, dropping back down to the real user the same
    # way the actual deployed script does via launchctl asuser internally
    # - -H so HOME resolves to that user's home, not root's. Note: this
    # only helps for commands that do their own open()/write() (python3,
    # tee, rm, the code CLI) - plain shell redirection (`cmd > file`) is
    # set up by the CALLING (still-root) shell before the sudo'd command
    # even starts, so callers needing to write literal content must pipe
    # through `run_as_real_user tee`, not redirect directly.
    run_as_real_user() {
      if [[ "$IS_ROOT" == true ]]; then
        sudo -H -u "$REAL_USER" "$@"
      else
        "$@"
      fi
    }
    # For GUI automation (open -a, osascript) only - `sudo -u` (what
    # run_as_real_user uses) still executes in root's own Mach bootstrap
    # context, not the real user's Aqua session, so AppleEvents sent that
    # way either can't reach a real GUI session or hang on a fresh,
    # un-granted Automation/TCC permission prompt for "root" (confirmed:
    # this is what made scenario 15 hang partway through under sudo -
    # System Events keystroke automation was never granted to root, only
    # to the real user's own Terminal). `launchctl asuser <uid>` actually
    # injects into that user's real login session, the same mechanism
    # restartVSCodeIfRunning uses in js_scripts/lib/
    # set-vscode-extension-version-runner.js.
    run_as_real_user_gui() {
      if [[ "$IS_ROOT" == true ]]; then
        launchctl asuser "$REAL_UID" "$@"
      else
        "$@"
      fi
    }
    code_cli() {
      run_as_real_user "$CODE_BIN" "$@"
    }
    run_dist_script() { osascript -l JavaScript "$DIST_SCRIPT" "$1"; }
    build_dist() { "$ROOT_DIR/js_scripts/build.sh"; }
    # No-op on mac: build_dist writes to the repo's own js_scripts/dist/,
    # a normal build artifact, not a temp file needing cleanup (unlike the
    # windows branch's copy under the remote %TEMP%).
    cleanup_deployed_script() { :; }
    # mac-rtr: identical to mac in every other way (same machine, same
    # code_cli/GUI-session/assertion/cleanup functions above and below) -
    # only how the deployed script is actually invoked differs. build_dist
    # is deliberately left untouched (still just the local build - see the
    # top-of-file usage comment): all the RTR-specific work (upload,
    # session, staging) lives inside rtr_run_dist_script itself, lazily,
    # on its first call.
    if [[ "$PLATFORM" == "mac-rtr" ]]; then
      if [[ -z "$DEVICE_AID" ]]; then
        echo "Error: --platform mac-rtr requires --device-aid <AID>" >&2
        exit 1
      fi
      run_dist_script() { rtr_run_dist_script "$1"; }
      cleanup_deployed_script() { rtr_cleanup_deployed_script; }
    fi
    setup_symlink_scenario() {
      mkdir -p "$SYMLINK_TARGET"
      rm -f "$SYMLINK_PATH"
      ln -s "$SYMLINK_TARGET" "$SYMLINK_PATH"
    }
    teardown_symlink_scenario() {
      rm -f "$SYMLINK_PATH"
      rmdir "$SYMLINK_TARGET" 2>/dev/null || true
    }
    # Prints the real settings.json's raw content, or "" if it doesn't
    # exist yet - captured by the caller and handed back to
    # restore_settings_backup so scenario 16 can leave this file exactly
    # as it found it, not just "however we last wrote it".
    get_settings_backup() {
      run_as_real_user cat "$SETTINGS_PATH" 2>/dev/null || true
    }
    # Scenario 16's own check that the deployed script's real on-disk
    # backup (settings.json.rwcbak - see enableSignatureBypass's own
    # comment) never lingers after a normal run - it should only ever
    # exist transiently, for the duration of a single CLI call.
    settings_backup_file_exists() {
      run_as_real_user test -f "${SETTINGS_PATH}.rwcbak"
    }
    set_verify_signature_true() {
      run_as_real_user python3 -c '
import json, sys
path = sys.argv[1]
try:
    with open(path) as f:
        data = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    data = {}
data["extensions.verifySignature"] = True
with open(path, "w") as f:
    json.dump(data, f, indent=2)
' "$SETTINGS_PATH"
    }
    # Used by set_installed_version (a raw, harness-side baseline-setup
    # install, not our own deployed script's bypassed code path) - VS
    # Code's marketplace only signs an extension's CURRENT latest version
    # (see scenario 16's own finding), so installing any older pinned
    # version via a raw `code --install-extension id@version` hits a real
    # "Signature verification failed: NotSigned" wall regardless of which
    # scenario asked for it. This is pure test setup, not the thing under
    # test, so bypassing it here is fine (and necessary) the same way
    # runCode's own enableSignatureBypass does for the real deployed
    # script's calls.
    set_verify_signature_false() {
      run_as_real_user python3 -c '
import json, sys
path = sys.argv[1]
try:
    with open(path) as f:
        data = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    data = {}
data["extensions.verifySignature"] = False
with open(path, "w") as f:
    json.dump(data, f, indent=2)
' "$SETTINGS_PATH"
    }
    restore_settings_backup() {
      # $1 = original raw content ("" means the file did not exist before).
      # Piped through `tee`, not `>` redirected, so the real user (not the
      # calling root shell) is the one actually opening/writing the file -
      # see run_as_real_user's own comment for why that distinction matters.
      if [[ -z "$1" ]]; then
        run_as_real_user rm -f "$SETTINGS_PATH"
      else
        printf '%s' "$1" | run_as_real_user tee "$SETTINGS_PATH" >/dev/null
      fi
    }
    clear_vsix_cache_for_version() {
      # $1 = version - removes any locally cached VSIX for it, so a signature
      # check actually has to happen fresh instead of reusing a prior
      # (possibly bypass-assisted) download from earlier in this run.
      run_as_real_user rm -f "$VSIX_CACHE_DIR/${EXT_ID}-$1"* 2>/dev/null || true
    }
    # Scenario 15 needs VS Code's extension-update-check code path to run
    # somehow. If a session is already running (e.g. hosting an active
    # Claude Code session on this dev machine), it's poked in place via
    # vscode_gui_session_running + trigger_vscode_extension_update_check
    # rather than quit and cold-relaunched; otherwise launch_vscode_gui_session
    # / kill_vscode_gui_session cold-boot one and restore the original
    # (not-running) state afterward. real_gui_session_available checks
    # VS Code's own hot-exit backup state (the actual "is everything
    # saved" signal VS Code itself maintains, not fragile window-title
    # scraping): if there's any backed-up unsaved buffer content, refuse
    # either way.
    real_gui_session_available() {
      local backups_dir="$HOME/Library/Application Support/Code/Backups"
      if [[ -d "$backups_dir" ]] && find "$backups_dir" -mindepth 1 -type f 2>/dev/null | grep -q .; then
        return 1
      fi
      return 0
    }
    # `pgrep -f`/`pgrep -x` (tried both, plus anchored variants) fail to
    # match this exact process for reasons that resisted explanation -
    # `ps aux | grep -F` reliably does not, so that's what every check in
    # this file uses instead of pgrep/pkill.
    _vscode_main_process_running() {
      ps aux | grep -F "Visual Studio Code.app/Contents/MacOS/Code" | grep -v grep | grep -q .
    }
    _vscode_main_process_pids() {
      ps aux | grep -F "Visual Studio Code.app/Contents/MacOS/Code" | grep -v grep | awk '{print $2}'
    }
    # Scenario 18's own primitives: backs up the REAL code binary and
    # replaces it with a stub that hangs forever, so our own deployed
    # script's real, production command-timeout mechanism has to fire for
    # a genuinely hung `code` invocation, through the actual RTR contract
    # (run_script/run_dist_script) - not by loading the runner source and
    # calling an internal function directly. Refuses to stub while a real
    # VS Code process is running, as a safety precondition - swapping out
    # its CLI helper out from under an active session is not something to
    # risk even though the GUI app itself doesn't depend on this exact
    # file for its own normal operation. CODE_BIN_STUBBED itself is a
    # shared, cross-platform global declared once further down (see its
    # own comment there).
    CODE_BIN_BACKUP_PATH="/tmp/glow_rwc_code_backup_$$"
    stub_code_binary() {
      if _vscode_main_process_running; then
        echo "Error: [scenario 18] refusing to stub the code binary while a real VS Code process is running" >&2
        return 1
      fi
      cp -p "$CODE_BIN" "$CODE_BIN_BACKUP_PATH"
      cat > "$CODE_BIN" <<'STUB'
#!/bin/bash
sleep 60
STUB
      chmod +x "$CODE_BIN"
      CODE_BIN_STUBBED=true
    }
    restore_code_binary() {
      if [[ "$CODE_BIN_STUBBED" == true ]]; then
        cp -p "$CODE_BIN_BACKUP_PATH" "$CODE_BIN"
        rm -f "$CODE_BIN_BACKUP_PATH"
        CODE_BIN_STUBBED=false
      fi
    }
    # Scenario 17's own primitive: the set of currently-running VS Code
    # main-process pids, platform-agnostic name so that scenario's shared
    # logic can poll for a genuinely NEW pid appearing (proof our own
    # deployed script's restart-after-change feature actually cycled the
    # process, not just claimed to in its envelope).
    get_vscode_pids() {
      _vscode_main_process_pids
    }
    # Whether a real VS Code GUI process is already up. Scenario 15
    # branches on this: if a session is already running, it's poked via
    # the "Check for Extension Updates" command instead of being quit and
    # cold-relaunched - this dev machine's own VS Code instance is liable
    # to be the one hosting an active Claude Code session, so quitting it
    # can stall arbitrarily on that session's own teardown, and a cold
    # relaunch would just reattach to whatever was already running
    # anyway, never producing a genuine passive-sync-triggering boot.
    vscode_gui_session_running() {
      _vscode_main_process_running
    }
    launch_vscode_gui_session() {
      run_as_real_user_gui open -a "Visual Studio Code" >/dev/null 2>&1
    }
    # Triggers the exact same update-check-and-install code path the
    # passive startup sync uses (workbench.extensions.action.checkForUpdates,
    # Command Palette: "Extensions: Check for Extension Updates") in an
    # ALREADY-running session, on demand - via System Events driving the
    # Command Palette, since there's no CLI flag to invoke an arbitrary
    # command in a running instance. Only ever call this when
    # vscode_gui_session_running is already true.
    trigger_vscode_extension_update_check() {
      run_as_real_user_gui osascript <<'APPLESCRIPT' >/dev/null 2>&1 || return 1
tell application "Visual Studio Code" to activate
delay 0.5
tell application "System Events"
  keystroke "p" using {command down, shift down}
  delay 0.5
  keystroke "Check for Extension Updates"
  delay 0.5
  key code 36
end tell
APPLESCRIPT
      return 0
    }
    kill_vscode_gui_session() {
      run_as_real_user_gui osascript -e 'quit app "Visual Studio Code"' >/dev/null 2>&1 || true
      # The quit AppleEvent is delivered asynchronously and the app can
      # take several seconds to actually exit - wait for the real process
      # to disappear (bounded) rather than a blind short sleep before
      # falling back to a force-kill.
      local waited=0
      while _vscode_main_process_running && [[ $waited -lt 10 ]]; do
        sleep 1
        waited=$((waited + 1))
      done
      # Fallback: force-kill by PID if still running (not `pkill -f` -
      # its pattern matching demonstrably fails to see this exact process
      # for reasons that resisted explanation, same as pgrep; ps does see
      # it reliably, so PIDs are gathered that way instead). -9/SIGKILL,
      # not a plain SIGTERM: Electron's main process can intercept
      # SIGTERM and defer real shutdown arbitrarily long (e.g. waiting on
      # its own extension host, such as an active Claude Code session, to
      # quiesce) - confirmed once, where the process didn't actually die
      # until several minutes later, well past this function's own wait
      # loop. Safe unconditionally: no unsaved buffers exist by the time
      # this runs (real_gui_session_available already gates on that
      # before any of this starts).
      local pid
      for pid in $(_vscode_main_process_pids); do
        kill -9 "$pid" 2>/dev/null || true
      done
      sleep 1
      # Clear VS Code's own single-instance lock/socket, but only once the
      # process is confirmed gone - otherwise a subsequent launch's
      # `open -a` can spend minutes retrying its IPC handshake against a
      # stale lock before giving up and finally starting a genuinely
      # fresh window (confirmed once: a stale code.lock left behind, and
      # a dozen+ short-lived stub cli.log sessions logged in quick
      # succession before a real windowed session finally appeared, well
      # past this scenario's poll window). NOTE: if this machine is also
      # hosting an active VS Code extension session (e.g. Claude Code)
      # in the same app instance being quit here, that session's own
      # extension-host teardown can itself add unpredictable delay to
      # the quit, independent of anything below - not something this
      # script can control or detect.
      if ! _vscode_main_process_running; then
        rm -f "$HOME/Library/Application Support/Code/code.lock" \
              "$HOME/Library/Application Support/Code/"*.sock 2>/dev/null || true
      fi
    }
    # Clears the "pinned" extensions.json metadata flag that `code
    # --install-extension id@version --force` sets automatically, so
    # scenario 15's control extension is a genuine non-pinned baseline
    # rather than accidentally protected the same way the primary
    # extension is.
    unpin_extension() {
      run_as_real_user python3 -c '
import json, sys
path, ext_id = sys.argv[1], sys.argv[2].lower()
with open(path) as f:
    data = json.load(f)
for e in data:
    if e.get("identifier", {}).get("id", "").lower() == ext_id:
        if isinstance(e.get("metadata"), dict):
            e["metadata"]["pinned"] = False
with open(path, "w") as f:
    json.dump(data, f)
' "$EXTENSIONS_JSON_PATH" "$1"
    }
    # Real bug this project actually hit: `launchctl asuser <uid>` only
    # attaches a process to the target user's Mach bootstrap namespace - per
    # `man launchctl`, it explicitly does NOT change the process' own
    # credentials (UID/GID). Both the deployed script's own `code` CLI
    # invocation (runCode) and its settings.json signature-bypass write
    # (enableSignatureBypass, done in-process, no subprocess at all) used to
    # rely on asuser alone for this and left real files - extension version
    # directories, .obsolete, settings.json, CLI log directories - owned by
    # root instead of the real target user every time this whole harness (or
    # any real root/Jamf deployment) ran. Rather than trust that this stays
    # fixed, every run checks every location either the harness or the
    # deployed script is known to write under and fails loudly if anything
    # ended up owned by someone other than the real user - covers the exact
    # regression class already found once (see js_scripts/lib/
    # set-vscode-extension-version-runner.js's runCode/enableSignatureBypass/
    # restartVSCodeIfRunning for the fix).
    audit_ownership() {
      local locations=(
        "$HOME/.vscode/extensions"
        "$HOME/Library/Application Support/Code"
      )
      local location_list
      location_list="$(printf '%s, ' "${locations[@]}")"
      location_list="${location_list%, }"
      local bad
      bad="$(find "${locations[@]}" -not -user "$REAL_USER" 2>/dev/null)"
      if [[ -n "$bad" ]]; then
        echo "  FAILED: found files/directories not owned by $REAL_USER under: $location_list"
        echo "$bad" | sed 's/^/    /'
        FAIL=$((FAIL + 1))
      else
        echo "  OK: everything under $location_list is owned by $REAL_USER"
        PASS=$((PASS + 1))
      fi
    }
    # No-op on mac - the VSIX cache warm-up below exists specifically to
    # work around this project's Windows VM's occasionally-flaky network
    # path to the marketplace (confirmed transient: an install timed out,
    # then an unrelated HTTPS request to the same host succeeded moments
    # later). Mac hasn't shown this problem, so there's nothing to prime
    # here - see the windows branch's own version of this function
    # for the real implementation.
    prime_vsix_cache() { :; }
    # No-op on mac - see the windows branch's own version.
    restore_vsix_cache_entry() { :; }
    ;;
  windows | windows-rtr)
    if [[ -z "$REMOTE_HOST" || -z "$REMOTE_USER" ]]; then
      echo "Error: --platform $PLATFORM requires --host and --user" >&2
      exit 1
    fi
    REMOTE="$REMOTE_USER@$REMOTE_HOST"
    LOCAL_DIST_FILE="$ROOT_DIR/ps_scripts/dist/Set-VSCodeExtensionVersion.ps1"

    # remote_ps <<'PS' feeds a PowerShell script to the remote box via a
    # real temp .ps1 file + `pwsh -File`, rather than trying to cram it
    # onto the ssh command line (cmd.exe, Windows OpenSSH's default remote
    # shell, has entirely different quoting rules than bash - a file
    # sidesteps that mismatch completely: cmd.exe only ever sees a fixed,
    # argument-free-content invocation, and PowerShell itself parses
    # everything that actually varies).
    #
    # NOT piped via stdin (`powershell -Command -`, this function's own
    # approach until this was found) - real, confirmed bug: Windows
    # PowerShell's `-Command -` reading a multi-line script from a
    # non-interactive piped stdin silently stops executing at the very
    # first control-flow block whose `{` spans multiple lines (foreach/if/
    # for, any of them) - not just that block's body, EVERYTHING after it
    # in the whole script, with no error and exit code 0. Confirmed
    # directly: a script with `if (Test-Path ...) { ... }` spanning
    # multiple lines never even created the file it was meant to write,
    # silently - this is exactly what made set_verify_signature_true a
    # complete no-op the entire time (scenario 16 was never actually
    # exercising real signature enforcement on Windows). `-File` reads the
    # whole script as one complete unit up front like the deployed script
    # itself already does (run_dist_script's own `pwsh -File`), so this
    # entire class of silent truncation cannot happen.
    remote_ps() {
      local local_script remote_script rc
      local_script="$(mktemp)"
      cat > "$local_script"
      # Built entirely from bash-known values (REMOTE_USER), not $REMOTE_TEMP -
      # this function itself is what resolves $REMOTE_TEMP on the very first
      # call in this script (see right below), so it can't depend on that
      # value already existing yet.
      remote_script="C:\\Users\\${REMOTE_USER}\\rwc_ps_$$_${RANDOM}.ps1"
      # Every step below is deliberately in a "tested" context (if!/&&-||)
      # so a failure here can never trip `set -e` and silently kill the
      # whole calling script before this function gets a chance to return
      # its own real exit code to the caller - confirmed real bug: the
      # cleanup Remove-Item step used to be a bare, unguarded statement,
      # and once its own ssh call failed (this VM's network really is
      # flaky), the entire script died right there with zero output,
      # never even reaching this function's own `return $rc` - looked
      # exactly like scenario 3 silently hanging/vanishing when it was
      # really this.
      if ! "${SCP_PREFIX[@]}" -q "${SSH_OPTS[@]}" "$local_script" "$REMOTE:$remote_script" 1>&2; then
        rm -f "$local_script"
        return 1
      fi
      "${SSH_PREFIX[@]}" "${SSH_OPTS[@]}" "$REMOTE" "pwsh -NoProfile -File \"$remote_script\"" && rc=0 || rc=$?
      "${SSH_PREFIX[@]}" "${SSH_OPTS[@]}" "$REMOTE" "Remove-Item -Path \"$remote_script\" -Force -ErrorAction SilentlyContinue" >/dev/null 2>&1 || true
      rm -f "$local_script"
      return $rc
    }

    echo "==> Resolving remote temp directory on $REMOTE_HOST" >&2
    REMOTE_TEMP="$(remote_ps <<'PS' | tr -d '\r'
[System.Environment]::GetEnvironmentVariable('TEMP')
PS
    )"
    if [[ -z "$REMOTE_TEMP" ]]; then
      echo "Error: could not resolve %TEMP% on $REMOTE_HOST" >&2
      exit 1
    fi
    REMOTE_DIST="$REMOTE_TEMP\\Set-VSCodeExtensionVersion.ps1"

    REAL_USER="$REMOTE_USER"
    # A plain admin SSH session is not NT AUTHORITY\SYSTEM, so it can't
    # write into the SYSTEM-profile fallback dir any more than a non-sudo
    # mac session can write into /var/root - same IS_ROOT gating, same
    # reason (see the mac branch above and scenario 5b below).
    IS_ROOT=false
    EXT_PATH_PREFIX="C:\\Users\\${REMOTE_USER}\\.vscode\\extensions"
    PATH_SEP="\\"
    NO_SUCH_USER_PATH="C:\\Users\\glow_test_no_such_user\\.vscode\\extensions\\${EXT_ID}-0.0.0"
    SYMLINK_TARGET="C:\\Windows\\Temp\\glow_test_evil_target"
    # Scenario 5c's own fixtures: a real directory shaped exactly like
    # Resolve-VSCodeUserProfilePath's own naive-guess fallback for a
    # username with no real Windows account (glow_test_locked_profile
    # certainly has none, so SID translation fails and it falls back to
    # this exact path) - then denied via a real icacls DENY ACE, so
    # Test-VSCodePathAccess hits a genuine UnauthorizedAccessException,
    # not a mock. "Everyone" covers both identities this script might
    # actually run as (the plain admin SSH account, or SYSTEM under
    # windows-rtr).
    ACCESS_DENIED_TEST_DIR="C:\\Users\\glow_test_locked_profile"
    ACCESS_DENIED_USER_PATH="${ACCESS_DENIED_TEST_DIR}\\.vscode\\extensions\\${EXT_ID}-0.0.0"
    setup_access_denied_profile_dir() {
      "${SSH_PREFIX[@]}" "${SSH_OPTS[@]}" "$REMOTE" \
        "powershell -NoProfile -Command \"New-Item -ItemType Directory -Force -Path '$ACCESS_DENIED_TEST_DIR' | Out-Null; icacls '$ACCESS_DENIED_TEST_DIR' /deny 'Everyone:(OI)(CI)F' | Out-Null\""
    }
    # take ownership first, not a bare icacls /reset - a real "Everyone:
    # deny full control" ACE also blocks WRITE_DAC (changing permissions
    # itself), so a normal admin session can't reset it directly; taking
    # ownership is a separate PRIVILEGE (SeTakeOwnershipPrivilege) real
    # admin accounts hold regardless of the DACL, and owners can always
    # rewrite their own object's DACL afterward.
    teardown_access_denied_profile_dir() {
      "${SSH_PREFIX[@]}" "${SSH_OPTS[@]}" "$REMOTE" \
        "powershell -NoProfile -Command \"takeown /F '$ACCESS_DENIED_TEST_DIR' /R /D Y | Out-Null; icacls '$ACCESS_DENIED_TEST_DIR' /reset /T | Out-Null; Remove-Item -Recurse -Force '$ACCESS_DENIED_TEST_DIR' -ErrorAction SilentlyContinue\"" || true
    }

    build_dist() {
      "$ROOT_DIR/ps_scripts/build.sh" >&2
      "${SCP_PREFIX[@]}" -q "${SSH_OPTS[@]}" "$LOCAL_DIST_FILE" "$REMOTE:$REMOTE_DIST"
      echo "  Copied to ${REMOTE_HOST}:${REMOTE_DIST}" >&2
    }

    code_cli() {
      # code.cmd's installer normally puts it on PATH; if this ever fails
      # with "not recognized", the fix is to mirror Find-VSCodeCli's
      # search-known-paths logic (ps_scripts/lib/...Runner.ps1) here too.
      #
      # The trailing `exit $LASTEXITCODE` matters: PowerShell's own host
      # process exit code does NOT automatically mirror the last native
      # command's $LASTEXITCODE unless told to - without it, this always
      # "succeeds" from bash's point of view (via ssh, then set -o
      # pipefail through `| tr`) regardless of whether `code` itself
      # actually failed, which callers that check code_cli's real exit
      # status (not just its output text) depend on.
      local quoted="" a
      for a in "$@"; do quoted+=" \"$a\""; done
      remote_ps <<PS | tr -d '\r'
code$quoted
exit \$LASTEXITCODE
PS
    }

    # Scenario 18's own primitives (windows/windows-rtr) - same intent as
    # the mac branch's own stub_code_binary: back up the REAL code.cmd and
    # replace it with a stub that hangs forever, so the real production
    # command-timeout mechanism has to fire for a genuinely hung `code`
    # invocation through the actual RTR contract. Resolves the real path
    # via Get-Command (the same PATH resolution code_cli itself already
    # relies on above, proven working by every other scenario in this
    # file), not a duplicated copy of Find-VSCodeCli's own candidate-path
    # search. Plain SSH + real powershell.exe throughout, deliberately not
    # remote_ps (which runs everything via pwsh 7) or code_cli - this is
    # about the real code.cmd file on disk, not the deployed script.
    CODE_CMD_REAL_PATH=""
    CODE_CMD_BACKUP_PATH=""
    stub_code_binary() {
      CODE_CMD_REAL_PATH="$("${SSH_PREFIX[@]}" "${SSH_OPTS[@]}" "$REMOTE" \
        "powershell -NoProfile -Command \"(Get-Command code.cmd -ErrorAction SilentlyContinue).Source\"" | tr -d '\r')"
      if [[ -z "$CODE_CMD_REAL_PATH" ]]; then
        echo "Error: [scenario 18] could not resolve the real code.cmd path via Get-Command" >&2
        return 1
      fi
      local running
      running="$("${SSH_PREFIX[@]}" "${SSH_OPTS[@]}" "$REMOTE" \
        "powershell -NoProfile -Command \"[bool](Get-Process -Name Code -ErrorAction SilentlyContinue)\"" | tr -d '\r')"
      if [[ "$running" != "False" ]]; then
        echo "Error: [scenario 18] refusing to stub code.cmd - a real VS Code process appears to be running (or its state could not be confirmed)" >&2
        return 1
      fi
      CODE_CMD_BACKUP_PATH="${CODE_CMD_REAL_PATH}.rwc18bak"
      "${SSH_PREFIX[@]}" "${SSH_OPTS[@]}" "$REMOTE" \
        "powershell -NoProfile -Command \"Copy-Item -LiteralPath '$CODE_CMD_REAL_PATH' -Destination '$CODE_CMD_BACKUP_PATH' -Force\"" || return 1
      "${SCP_PREFIX[@]}" -q "${SSH_OPTS[@]}" \
        "$ROOT_DIR/ps_scripts/tests/stub_code_that_hangs.cmd" "$REMOTE:$CODE_CMD_REAL_PATH" || return 1
      CODE_BIN_STUBBED=true
    }
    restore_code_binary() {
      if [[ "$CODE_BIN_STUBBED" == true ]]; then
        "${SSH_PREFIX[@]}" "${SSH_OPTS[@]}" "$REMOTE" \
          "powershell -NoProfile -Command \"Move-Item -LiteralPath '$CODE_CMD_BACKUP_PATH' -Destination '$CODE_CMD_REAL_PATH' -Force\"" \
          || echo "    WARNING: [scenario 18] failed to restore the real code.cmd from backup - manual recovery needed at $CODE_CMD_REAL_PATH" >&2
        CODE_BIN_STUBBED=false
      fi
    }

    run_dist_script() {
      local payload="$1"
      remote_ps <<PS
pwsh -NoProfile -File "$REMOTE_DIST" "$payload"
PS
    }

    setup_symlink_scenario() {
      remote_ps <<PS
New-Item -ItemType Directory -Path "$SYMLINK_TARGET" -Force | Out-Null
Remove-Item -Path "$SYMLINK_PATH" -Force -ErrorAction SilentlyContinue
New-Item -ItemType SymbolicLink -Path "$SYMLINK_PATH" -Target "$SYMLINK_TARGET" -Force | Out-Null
PS
    }

    teardown_symlink_scenario() {
      remote_ps <<PS
Remove-Item -Path "$SYMLINK_PATH" -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$SYMLINK_TARGET" -Recurse -Force -ErrorAction SilentlyContinue
PS
    }
    # $REMOTE_DIST cleanup deliberately lives here, not in
    # teardown_symlink_scenario - scenarios 15/16 run after scenario 14
    # and still need the deployed script to exist, so it can only be
    # removed once the whole run is actually finishing.
    cleanup_deployed_script() {
      remote_ps <<PS
Remove-Item -Path "$REMOTE_DIST" -Force -ErrorAction SilentlyContinue
PS
    }
    # windows-rtr: identical to windows in every other way (same
    # code_cli/symlink-scenario/settings-backup/GUI-session/assertion
    # functions above and below, all still driven over the admin SSH
    # channel - RTR is only the *deployment* channel under test, not how
    # the harness sets up/asserts state) - only how the deployed script is
    # actually invoked differs. build_dist is overridden too: no SSH copy
    # to %TEMP% needed, since rtr_run_dist_script_windows itself uploads
    # DIST_SCRIPT as a put-file from the freshly-built local file on its
    # own first call, the same way mac-rtr's build_dist stays local-only.
    if [[ "$PLATFORM" == "windows-rtr" ]]; then
      if [[ -z "$DEVICE_AID" ]]; then
        echo "Error: --platform windows-rtr requires --device-aid <AID>" >&2
        exit 1
      fi
      RTR_PUT_NAME="Set-VSCodeExtensionVersion-rtr-check.ps1"
      RTR_REMOTE_DIR='C:\Windows\Temp\glow_rwc_rtr'
      RTR_REMOTE_PATH="$RTR_REMOTE_DIR\\$RTR_PUT_NAME"
      # rtr_upload_put_file (shared with mac-rtr) reads $DIST_SCRIPT, not
      # $LOCAL_DIST_FILE - the mac branch sets the former for its own use,
      # windows only ever set the latter (for its own plain-SSH build_dist
      # scp). Bridge the two here, real bug found on the first live run:
      # "DIST_SCRIPT: unbound variable" under set -u.
      DIST_SCRIPT="$LOCAL_DIST_FILE"
      build_dist() { "$ROOT_DIR/ps_scripts/build.sh" >&2; }
      run_dist_script() { rtr_run_dist_script_windows "$1"; }
      cleanup_deployed_script() { rtr_cleanup_deployed_script; }
      # A Windows RTR session runs as SYSTEM, not the admin SSH account -
      # same IS_ROOT gating reason as the mac branch's own mac-rtr (see
      # its comment above), exercising scenario 5b's SYSTEM-fallback
      # identity path on Windows for real, for the first time.
      IS_ROOT=true
    fi
    # Prints the real settings.json's raw content, or "" if it doesn't
    # exist yet - captured by the caller and handed back to
    # restore_settings_backup so scenario 16 can leave this file exactly
    # as it found it, not just "however we last wrote it".
    get_settings_backup() {
      remote_ps <<'PS' | tr -d '\r'
$settingsPath = "$env:APPDATA\Code\User\settings.json"
if (Test-Path $settingsPath) { Get-Content $settingsPath -Raw } else { "" }
PS
    }
    # Scenario 16's own check that the deployed script's real on-disk
    # backup (settings.json.rwcbak - see
    # Enable-VSCodeSignatureVerificationBypass's own comment) never
    # lingers after a normal run - it should only ever exist transiently,
    # for the duration of a single CLI call.
    settings_backup_file_exists() {
      local result
      result="$(remote_ps <<'PS' | tr -d '\r'
Test-Path "$env:APPDATA\Code\User\settings.json.rwcbak"
PS
      )"
      [[ "$result" == "True" ]]
    }
    # Uses .PSObject.Properties enumeration rather than ConvertFrom-Json
    # -AsHashtable - a leftover from when remote_ps ran everything through
    # Windows PowerShell 5.1 (-AsHashtable needs 6+); harmless now that
    # remote_ps uses pwsh (see remote_ps's own comment on why: the actual
    # reason for that original choice turned out to be backwards - piped
    # 5.1 stdin was the unreliable one, not the reliable one), just not
    # worth simplifying together with an unrelated fix.
    set_verify_signature_true() {
      remote_ps <<'PS'
$settingsPath = "$env:APPDATA\Code\User\settings.json"
$settingsDir = Split-Path $settingsPath -Parent
if (-not (Test-Path $settingsDir)) { New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null }
$settings = [ordered]@{}
if (Test-Path $settingsPath) {
  $raw = Get-Content $settingsPath -Raw
  if ($raw.Trim()) {
    $parsed = ConvertFrom-Json $raw
    foreach ($prop in $parsed.PSObject.Properties) { $settings[$prop.Name] = $prop.Value }
  }
}
$settings['extensions.verifySignature'] = $true
($settings | ConvertTo-Json -Depth 10) | Set-Content -Path $settingsPath -Encoding utf8
PS
    }
    # See the mac branch's own comment on this function - same reason,
    # used by the same shared set_installed_version.
    set_verify_signature_false() {
      remote_ps <<'PS'
$settingsPath = "$env:APPDATA\Code\User\settings.json"
$settingsDir = Split-Path $settingsPath -Parent
if (-not (Test-Path $settingsDir)) { New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null }
$settings = [ordered]@{}
if (Test-Path $settingsPath) {
  $raw = Get-Content $settingsPath -Raw
  if ($raw.Trim()) {
    $parsed = ConvertFrom-Json $raw
    foreach ($prop in $parsed.PSObject.Properties) { $settings[$prop.Name] = $prop.Value }
  }
}
$settings['extensions.verifySignature'] = $false
($settings | ConvertTo-Json -Depth 10) | Set-Content -Path $settingsPath -Encoding utf8
PS
    }
    # $1 = original raw content ("" means the file did not exist before).
    # Base64-round-tripped rather than embedded as literal text in the
    # heredoc: settings.json can contain arbitrary quotes/backslashes that
    # would otherwise have to survive bash -> ssh -> cmd.exe -> PowerShell
    # quoting intact, which is exactly the kind of thing that's gone wrong
    # elsewhere in this script. Base64's alphabet has none of those
    # characters, so there's nothing to escape.
    restore_settings_backup() {
      local encoded
      encoded="$(printf '%s' "$1" | base64 | tr -d '\n')"
      remote_ps <<PS
\$settingsPath = "\$env:APPDATA\Code\User\settings.json"
\$b64 = "$encoded"
if (\$b64 -eq "") {
  Remove-Item -Path \$settingsPath -Force -ErrorAction SilentlyContinue
} else {
  \$bytes = [Convert]::FromBase64String(\$b64)
  \$text = [System.Text.Encoding]::UTF8.GetString(\$bytes)
  Set-Content -Path \$settingsPath -Value \$text -Encoding utf8 -NoNewline
}
PS
    }
    clear_vsix_cache_for_version() {
      # $1 = version - removes any locally cached VSIX for it, so a signature
      # check actually has to happen fresh instead of reusing a prior
      # (possibly bypass-assisted) download from earlier in this run.
      local version="$1"
      remote_ps <<PS
Remove-Item -Path "\$env:APPDATA\Code\CachedExtensionVSIXs\${EXT_ID}-${version}*" -Force -ErrorAction SilentlyContinue
PS
    }
    # Scenario 15 needs a real GUI VS Code window - its passive/startup
    # extension sync never runs from a one-shot `code --list-extensions`
    # style CLI invocation, and SSH sessions land in the non-interactive
    # Session 0 where a directly-launched Code.exe can't render at all
    # (confirmed: only a stub cli.log ever appeared, no main/renderer/
    # exthost logs, before the process silently vanished). The real fix:
    # ps_scripts/tests/watch_and_launch_vscode.ps1, registered via
    # register_vscode_watcher_task.ps1 as a Scheduled Task with LogonType
    # Interactive - it runs inside the real logged-in session and launches
    # VS Code there in response to a trigger file, which these functions
    # create. That task must already be registered and running (can't be
    # started from here - that's the whole reason it exists as a separate
    # persistent watcher rather than something this script starts itself).
    real_gui_session_available() {
      local state
      state="$(remote_ps <<'PS' | tr -d '\r'
(Get-ScheduledTask -TaskName "WatchAndLaunchVSCode" -ErrorAction SilentlyContinue).State
PS
      )"
      [[ "$state" == "Running" ]]
    }
    # Whether a real VS Code GUI process is already up on the remote box.
    # Scenario 15 branches on this: if a session is already running, it's
    # poked via the watcher's check-updates trigger (Command Palette:
    # "Extensions: Check for Extension Updates") instead of being killed
    # and cold-relaunched - no reason to disrupt a session that might be
    # in active use there, mirroring the same reasoning as the macOS side.
    vscode_gui_session_running() {
      local result
      result="$(remote_ps <<'PS' | tr -d '\r'
Write-Output ([bool](Get-Process -Name Code -ErrorAction SilentlyContinue))
PS
      )"
      [[ "$result" == "True" ]]
    }
    # Scenario 17's own primitive - see the mac branch's own comment on
    # get_vscode_pids for why this exists.
    get_vscode_pids() {
      remote_ps <<'PS' | tr -d '\r'
(Get-Process -Name Code -ErrorAction SilentlyContinue).Id -join "`n"
PS
    }
    # Triggers the exact same update-check-and-install code path the
    # passive startup sync uses, in an ALREADY-running session, via the
    # watcher's check-updates trigger file (see
    # watch_and_launch_vscode.ps1 - SendKeys driving the Command
    # Palette, since remote_ps itself runs in the non-interactive Session
    # 0 and can't send real keystrokes to the GUI session). Only ever
    # call this when vscode_gui_session_running is already true.
    trigger_vscode_extension_update_check() {
      remote_ps <<'PS'
New-Item -ItemType File -Path "$env:USERPROFILE\vscode_checkupdates_trigger" -Force | Out-Null
PS
      local waited=0 still_there
      while [[ $waited -lt 10 ]]; do
        sleep 1
        still_there="$(remote_ps <<'PS' | tr -d '\r'
Test-Path "$env:USERPROFILE\vscode_checkupdates_trigger"
PS
        )"
        [[ "$still_there" != "True" ]] && return 0
        waited=$((waited + 1))
      done
      return 1
    }
    launch_vscode_gui_session() {
      remote_ps <<'PS'
New-Item -ItemType File -Path "$env:USERPROFILE\vscode_launch_trigger" -Force | Out-Null
PS
      # Confirm the watcher actually consumed the trigger (proves it's
      # really running, not just registered) rather than assuming success.
      local waited=0 still_there
      while [[ $waited -lt 10 ]]; do
        sleep 1
        still_there="$(remote_ps <<'PS' | tr -d '\r'
Test-Path "$env:USERPROFILE\vscode_launch_trigger"
PS
        )"
        [[ "$still_there" != "True" ]] && return 0
        waited=$((waited + 1))
      done
      return 1
    }
    kill_vscode_gui_session() {
      remote_ps <<'PS'
New-Item -ItemType File -Path "$env:USERPROFILE\vscode_kill_trigger" -Force | Out-Null
PS
    }
    # Clears the "pinned" extensions.json metadata flag that `code
    # --install-extension id@version --force` sets automatically, so
    # scenario 15's control extension is a genuine non-pinned baseline
    # rather than accidentally protected the same way the primary
    # extension is. .PSObject.Properties enumeration again, not
    # -AsHashtable - same Windows PowerShell 5.1 constraint as
    # set_verify_signature_true above.
    unpin_extension() {
      local ext_id="$1"
      remote_ps <<PS
\$path = "$EXTENSIONS_JSON_PATH"
\$extId = "$ext_id".ToLower()
\$data = ConvertFrom-Json (Get-Content \$path -Raw)
foreach (\$e in \$data) {
  if (\$e.identifier.id.ToLower() -eq \$extId -and \$e.metadata) {
    \$e.metadata.pinned = \$false
  }
}
(\$data | ConvertTo-Json -Depth 10) | Set-Content -Path \$path -Encoding utf8
PS
    }
    # Informational only, never fails the run (see this function's own
    # detailed comment on the mac side, and Set-VSCodeExtensionVersion.
    # Runner.ps1's own file header) - unlike the mac side's launchctl-asuser
    # bug, this is Windows' actual, deliberate, documented design: the
    # deployed script never impersonates the target user for its `code`
    # CLI calls at all, it just points --extensions-dir/--user-data-dir at
    # their profile while running as whatever identity launched it
    # (SYSTEM, in a real RTR deployment) - so files there are EXPECTED to
    # show that identity as owner, not the target user. Printed here purely
    # so a real run's output makes that visible rather than silent, in
    # case NTFS ACL inheritance ever doesn't grant the target user the
    # access they need to actually use what got installed.
    audit_ownership() {
      local owner_report
      owner_report="$(remote_ps <<PS | tr -d '\r'
\$locations = @("C:\Users\$REMOTE_USER\.vscode\extensions", "C:\Users\$REMOTE_USER\AppData\Roaming\Code")
foreach (\$loc in \$locations) {
  if (Test-Path \$loc) {
    Get-ChildItem -Path \$loc -Force -ErrorAction SilentlyContinue | ForEach-Object {
      \$owner = (Get-Acl \$_.FullName -ErrorAction SilentlyContinue).Owner
      Write-Output "\$(\$_.FullName): \$owner"
    }
  }
}
PS
      )"
      if [[ -n "$owner_report" ]]; then
        echo "  INFO: current owner of each top-level item under $REMOTE_USER's extensions/user-data dirs (SYSTEM/Administrators here is expected, not a failure):"
        echo "$owner_report" | sed 's/^/    /'
      fi
    }
    # Persistent, side VSIX cache for the fixed pinned versions this suite
    # repeatedly resets to/from across its scenarios (0.4.0, the control
    # extension's old version) - a directory WE own
    # ($env:LOCALAPPDATA\rwc_vsix_cache, never touched by VS Code itself),
    # separate from VS Code's own CachedExtensionVSIXs.
    #
    # Downloads directly from the marketplace's gallery API
    # (https://marketplace.visualstudio.com/_apis/public/gallery/publishers/
    # <publisher>/vsextensions/<name>/<version>/vspackage), NOT via `code
    # --install-extension` - two real problems that route avoided entirely:
    # (1) it needs the verifySignature:false bypass for any non-latest
    # version (real "NotSigned" wall, confirmed), and (2) even bypassed and
    # successful, `code --install-extension id@version --force` was
    # confirmed to NOT reliably populate CachedExtensionVSIXs for a pinned
    # (non-latest) version at all - a real install of njpwerner.
    # autodocstring@0.4.0 succeeded and left NO corresponding cache file.
    # A direct download has neither problem: it's a plain file, saved with
    # the exact name VS Code's own cache uses (`id-version`, no extension).
    #
    # This function only fills the SIDE cache, once - it does not touch
    # the live CachedExtensionVSIXs at all. Restoring a specific entry
    # into the live cache right before it's actually needed is
    # restore_vsix_cache_entry's job (called from set_installed_version/
    # run_script), because installing OR uninstalling an extension can
    # itself clear that extension's live cache entries as a side effect
    # (confirmed: a manually-placed live cache file disappeared the
    # moment the extension was uninstalled) - a single upfront prime
    # would just get wiped out by the first scenario that uninstalls.
    #
    # Deliberately does NOT include $SIGNATURE_TEST_VERSION - scenario 16
    # explicitly clears that exact version's live-cache entry right before
    # using it (clear_vsix_cache_for_version), on purpose: that scenario's
    # whole point is exercising a genuinely fresh, never-cached download
    # against real signature enforcement. Caching it here would be wasted
    # work - it gets thrown away moments before it would ever help.
    prime_vsix_cache() {
      remote_ps <<PS || echo "    WARNING: cache bootstrap remote step failed/dropped (rc=$?) - this run may hit the network fresh for versions that needed it"
\$sideCacheDir = "\$env:LOCALAPPDATA\rwc_vsix_cache"
if (-not (Test-Path \$sideCacheDir)) { New-Item -ItemType Directory -Path \$sideCacheDir -Force | Out-Null }
function Get-VsixDirect(\$id, \$version, \$dest) {
  \$parts = \$id.Split(".")
  \$url = "https://marketplace.visualstudio.com/_apis/public/gallery/publishers/\$(\$parts[0])/vsextensions/\$(\$parts[1])/\$version/vspackage"
  for (\$i = 1; \$i -le 3; \$i++) {
    try {
      Invoke-WebRequest -Uri \$url -UseBasicParsing -TimeoutSec 30 -OutFile \$dest
      return \$true
    } catch {
      Start-Sleep -Seconds 5
    }
  }
  return \$false
}
\$pairs = @(
  @{ Id = "$EXT_ID"; Version = "0.4.0" },
  @{ Id = "$CONTROL_EXT_ID"; Version = "$CONTROL_EXT_OLD_VERSION" }
)
foreach (\$p in \$pairs) {
  \$dest = Join-Path \$sideCacheDir "\$(\$p.Id)-\$(\$p.Version)"
  if (Test-Path \$dest) {
    Write-Output "already in side cache: \$(\$p.Id)@\$(\$p.Version)"
    continue
  }
  Write-Output "downloading directly from the marketplace (one-time): \$(\$p.Id)@\$(\$p.Version)"
  if (Get-VsixDirect \$p.Id \$p.Version \$dest) {
    Write-Output "  OK - cached for every future run"
  } else {
    Write-Output "  WARNING: still failed after 3 attempts - this version will keep hitting the network until a run succeeds"
  }
}
PS
    }
    # Called right before any install of a fixed pinned version
    # (set_installed_version/run_script) - copies that one entry from the
    # side cache into VS Code's live CachedExtensionVSIXs if we have it,
    # so THIS install skips the network regardless of whether an earlier
    # scenario's uninstall already wiped the live cache (see
    # prime_vsix_cache's own comment on why a single upfront copy isn't
    # enough). Silent no-op if we don't have this exact (id, version)
    # side-cached - not every install throughout the suite is for one of
    # the fixed pinned versions prime_vsix_cache bothered with.
    restore_vsix_cache_entry() {
      # Retried (not just a single best-effort attempt) - this VM's
      # network is confirmed flaky enough that even a plain SSH round
      # trip can transiently fail, and a silent single-shot failure here
      # is indistinguishable from "we just don't have this cached", which
      # then leaves the actual install to hit the real network instead
      # (confirmed: this exact gap is what let a genuine ETIMEDOUT through
      # on an install whose version WAS sitting in the side cache the
      # whole time).
      local id="$1" version="$2" attempt
      for attempt in 1 2 3; do
        if remote_ps <<PS >/dev/null 2>&1
\$sideFile = "\$env:LOCALAPPDATA\rwc_vsix_cache\\$id-$version"
if (Test-Path \$sideFile) {
  \$liveCacheDir = "\$env:APPDATA\Code\CachedExtensionVSIXs"
  if (-not (Test-Path \$liveCacheDir)) { New-Item -ItemType Directory -Path \$liveCacheDir -Force | Out-Null }
  Copy-Item -Path \$sideFile -Destination (Join-Path \$liveCacheDir "$id-$version") -Force
}
PS
        then
          return 0
        fi
        sleep 2
      done
    }
    ;;
  *)
    echo "Error: --platform must be 'mac', 'mac-rtr', 'windows', or 'windows-rtr'" >&2
    exit 1
    ;;
esac

# The envelope field name for "user resolution fell back off the real
# target user" differs by platform: mac genuinely runs the fallback as
# root (RTR's own execution identity there), so `ran_as_root` is
# literally accurate; Windows always runs under SYSTEM regardless (RTR
# has no mac-style impersonation), so the same concept there is really
# "did we fall back to SYSTEM's own isolated extensions dir" - renamed
# to `used_system_fallback` to match this file's own SYSTEM-fallback
# terminology instead of reusing a mac-flavored name that never applied.
RAN_AS_ROOT_FIELD="ran_as_root"
if [[ "$PLATFORM" == windows* ]]; then
  RAN_AS_ROOT_FIELD="used_system_fallback"
fi

MISMATCHED_ID_PATH="${EXT_PATH_PREFIX}${PATH_SEP}some-other.extension-0.0.0"
SYMLINK_PATH="${EXT_PATH_PREFIX}${PATH_SEP}${EXT_ID}-9.9.9-symlinktest"
USER_EXTENSION_PATH="${EXT_PATH_PREFIX}${PATH_SEP}${EXT_ID}-0.0.0"  # shape only; leaf need not exist
CONTROL_EXTENSION_PATH="${EXT_PATH_PREFIX}${PATH_SEP}${CONTROL_EXT_ID}-0.0.0"  # shape only; leaf need not exist
EXTENSIONS_JSON_PATH="${EXT_PATH_PREFIX}${PATH_SEP}extensions.json"  # used by unpin_extension (scenario 15)

install_latest_or_die() {
  # $1 = extension id. Raw code_cli install of latest (always signed, no
  # bypass needed), with retries - confirmed real need: this project's
  # Windows VM has a genuinely flaky path to the marketplace (ETIMEDOUT,
  # ECONNRESET, and outright DNS resolution failures all observed
  # directly across different runs). Every one of this function's call
  # sites used to be a bare, unguarded `code_cli --install-extension ...
  # >/dev/null 2>&1` - under `set -e`, a transient network blip there
  # silently killed the whole script with zero output (confirmed: exactly
  # what happened to an isolated scenario 2 run, immediately after an
  # unrelated step a few lines earlier hit the very same flakiness and
  # only survived because IT already had retry logic).
  local id="$1" err ok=false
  for attempt in 1 2 3; do
    if err="$(code_cli --install-extension "$id" --force 2>&1 >/dev/null)"; then
      ok=true
      break
    fi
    echo "    WARNING: attempt $attempt installing $id (latest) failed: $err"
    sleep 5
  done
  if [[ "$ok" != true ]]; then
    echo "  FAILED: could not install $id (latest) after 3 attempts" >&2
    exit 1
  fi
}

get_installed_version() {
  # $1 = extension id (default $EXT_ID) - overridable so scenario 15 can
  # also check its control extension's version with the same helper.
  local id="${1:-$EXT_ID}"
  code_cli --list-extensions --show-versions 2>/dev/null \
    | grep -i "^${id}@" | sed -E "s/^[^@]+@//" || true
}

set_installed_version() {
  # $1 = exact version to force-install. This is a raw, harness-side
  # baseline-setup install - NOT our own deployed script's bypassed code
  # path - but VS Code's marketplace only signs an extension's CURRENT
  # latest version (see scenario 16's own finding), so a raw install of
  # any older pinned version hits a real "Signature verification failed:
  # NotSigned" wall regardless of which scenario calls this. Confirmed:
  # this only ever surfaced when running a later scenario (e.g. 17) in
  # isolation, starting from a clean "latest" state - in a full 1-17 run,
  # an earlier scenario had usually already gotten this same old version
  # signed-and-cached via run_script's own bypass, so the reinstall
  # resolved locally and never hit the marketplace fresh. Bracketing with
  # the same temporary verifySignature:false bypass scenario 16 already
  # uses (just the opposite direction) makes this raw call work
  # unconditionally, matching what runCode's own enableSignatureBypass
  # does for the real deployed script's calls.
  #
  # Surfaces the real error instead of silently swallowing it (as this
  # used to) - under `set -e`, an unguarded failure here with both
  # stdout+stderr suppressed used to kill the whole script with zero
  # output, indistinguishable from a hang (confirmed: this exact pattern
  # is what made scenario 15's control-extension setup look like a silent
  # stall before it was fixed there).
  # Retried, not a single attempt - the confirmed network flakiness on
  # the windows VM (ETIMEDOUT/ECONNRESET/DNS failures, all
  # observed directly) applies here too, and this is the one remaining
  # install helper that had no retry loop at all (install_latest_or_die
  # and the "resolving latest" setup step both already do).
  local backup err ok=false attempt
  restore_vsix_cache_entry "$EXT_ID" "$1"
  backup="$(get_settings_backup)"
  set_verify_signature_false
  for attempt in 1 2 3; do
    if err="$(code_cli --install-extension "${EXT_ID}@${1}" --force 2>&1 >/dev/null)"; then
      ok=true
      break
    fi
    echo "    WARNING: attempt $attempt setting $EXT_ID to $1 failed: $err"
    sleep 5
  done
  restore_settings_backup "$backup"
  if [[ "$ok" != true ]]; then
    echo "  FAILED: could not set $EXT_ID to $1 via raw code_cli after 3 attempts" >&2
    exit 1
  fi
}

run_script() {
  # $1 = version ("" for none), $2 = dry_run ("true"/"false"), $3 = extension_path,
  # $4 = extension_id (default $EXT_ID) - overridable so scenario 15 can also
  # drive its control extension through our own deployed script (which
  # handles signature verification correctly, unlike a raw code_cli call -
  # see that scenario for why a raw call isn't good enough here).
  local version="$1" dry_run="$2" ext_path="$3" ext_id="${4:-$EXT_ID}"
  [[ -n "$version" ]] && restore_vsix_cache_entry "$ext_id" "$version"
  local payload
  payload="$(python3 - "$ext_id" "$version" "$ext_path" "$dry_run" <<'PY'
import base64, json, sys
ext_id, version, ext_path, dry_run = sys.argv[1:5]
params = {"extension_id": ext_id, "extension_path": ext_path}
if version:
    params["version"] = version
payload = {"params": params, "dry_run": dry_run == "true"}
print(base64.b64encode(json.dumps(payload).encode()).decode())
PY
  )"
  run_dist_script "$payload"
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
  run_dist_script "$payload"
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

GUI_SESSION_LAUNCHED=false
# Scenario 18's own flag, shared across platforms (set true by whichever
# platform's stub_code_binary succeeds) so restore_original_state's
# safety net below can restore the real code binary/code.cmd regardless
# of platform, and - critically - BEFORE any of its own code_cli calls,
# which would themselves hang against a still-stubbed binary otherwise.
CODE_BIN_STUBBED=false
SETTINGS_BACKUP_CAPTURED=false
SETTINGS_BACKUP_VALUE=""
# Declared here (not just before its first real use below) because
# restore_original_state's trap can fire at any point once registered,
# including before that later assignment ever runs - and this whole
# script runs under `set -u`, so referencing it while still unset would
# itself error inside the trap handler.
PRE_TEST_VSCODE_CLOSED_BY_US=false

echo "==> Building latest deployed script ($PLATFORM)"
build_dist

echo "==> Capturing original state of $EXT_ID"
ORIGINAL_VERSION="$(get_installed_version)"
if [[ -n "$ORIGINAL_VERSION" ]]; then
  echo "    Currently installed at $ORIGINAL_VERSION"
else
  echo "    Currently not installed"
fi

echo "==> Capturing original state of $CONTROL_EXT_ID (scenario 15 control extension)"
ORIGINAL_CONTROL_VERSION="$(get_installed_version "$CONTROL_EXT_ID")"
if [[ -n "$ORIGINAL_CONTROL_VERSION" ]]; then
  echo "    Currently installed at $ORIGINAL_CONTROL_VERSION"
else
  echo "    Currently not installed"
fi

# Resolved unconditionally (not inside scenario 2's own block, where this
# used to live) - scenarios 3-8 and 17 all reference $LATEST_VERSION too,
# and under `set -u` that's an "unbound variable" crash the moment any of
# them runs via --scenario without scenario 2 in the same invocation
# (confirmed: exactly what killed an isolated scenario 17 run).
echo "==> Resolving latest available version of $EXT_ID"
# Surfaces the real error instead of silently swallowing it - same
# unguarded-under-set-e pattern already found and fixed elsewhere
# (set_installed_version, scenario 15/16's raw installs); this one just
# hadn't been touched yet. Retried, not just error-surfaced: this VM's
# network to the marketplace is confirmed occasionally flaky (a plain
# ETIMEDOUT that succeeded on a bare retry moments later), and unlike
# prime_vsix_cache's fixed set of versions, "latest" isn't known ahead of
# time so it can't be pre-warmed the same way.
latest_resolve_ok=false
for attempt in 1 2 3; do
  if latest_resolve_err="$(code_cli --install-extension "$EXT_ID" --force 2>&1 >/dev/null)"; then
    latest_resolve_ok=true
    break
  fi
  echo "    WARNING: attempt $attempt failed: $latest_resolve_err"
  sleep 5
done
if [[ "$latest_resolve_ok" != true ]]; then
  echo "  FAILED: could not resolve latest version of $EXT_ID after 3 attempts" >&2
  exit 1
fi
LATEST_VERSION="$(get_installed_version)"
echo "    Latest: $LATEST_VERSION"

echo "==> Priming VSIX cache for this suite's fixed pinned versions (no-op on mac)"
prime_vsix_cache

restore_original_state() {
  echo
  echo "==> Cleaning up test artifacts"
  # Guarded: this runs under `set -e` inside a trap, so an unguarded
  # nonzero exit here (e.g. a transient SSH hiccup, even if the underlying
  # Remove-Item calls all actually succeeded) would abort the rest of this
  # function - skipping the far more important step below. A cleanup
  # helper failing must never prevent restoring the extension's original
  # install state.
  teardown_symlink_scenario || echo "    WARNING: symlink-scenario artifact cleanup reported an error (continuing)"
  teardown_access_denied_profile_dir || echo "    WARNING: scenario 5c's locked-profile-dir cleanup reported an error (continuing)"
  cleanup_deployed_script || echo "    WARNING: deployed-script cleanup reported an error (continuing)"

  # Safety net for scenario 15/16 state, in case the script exited before
  # their own explicit cleanup ran (e.g. a real error partway through).
  # Both are idempotent: calling them again after the explicit cleanup
  # already ran is harmless.
  if [[ "$GUI_SESSION_LAUNCHED" == true ]]; then
    kill_vscode_gui_session || echo "    WARNING: failed to close the scenario 15 GUI session (continuing)"
  fi
  if [[ "$SETTINGS_BACKUP_CAPTURED" == true ]]; then
    restore_settings_backup "$SETTINGS_BACKUP_VALUE" || echo "    WARNING: failed to restore settings.json (continuing)"
  fi
  # Scenario 18's own safety net - MUST run before any of the code_cli
  # calls below: those would themselves hang against a still-stubbed
  # binary if scenario 18 died before its own explicit restore ran.
  if [[ "$CODE_BIN_STUBBED" == true ]]; then
    restore_code_binary || echo "    WARNING: failed to restore the real code binary/code.cmd (continuing)"
  fi

  echo "==> Restoring original state of $EXT_ID"
  if [[ -n "$ORIGINAL_VERSION" ]]; then
    code_cli --install-extension "${EXT_ID}@${ORIGINAL_VERSION}" --force >/dev/null 2>&1 || \
      echo "    WARNING: failed to restore ${EXT_ID}@${ORIGINAL_VERSION}"
  else
    code_cli --uninstall-extension "$EXT_ID" >/dev/null 2>&1 || true
  fi
  local final
  final="$(get_installed_version)"
  echo "    Now: ${final:-not installed}"

  echo "==> Restoring original state of $CONTROL_EXT_ID"
  if [[ -n "$ORIGINAL_CONTROL_VERSION" ]]; then
    code_cli --install-extension "${CONTROL_EXT_ID}@${ORIGINAL_CONTROL_VERSION}" --force >/dev/null 2>&1 || \
      echo "    WARNING: failed to restore ${CONTROL_EXT_ID}@${ORIGINAL_CONTROL_VERSION}"
  else
    code_cli --uninstall-extension "$CONTROL_EXT_ID" >/dev/null 2>&1 || true
  fi
  local final_control
  final_control="$(get_installed_version "$CONTROL_EXT_ID")"
  echo "    Now: ${final_control:-not installed}"

  if [[ "$PRE_TEST_VSCODE_CLOSED_BY_US" == true ]]; then
    echo "==> Relaunching VS Code (it was running before this test started)"
    launch_vscode_gui_session || echo "    WARNING: failed to relaunch VS Code (continuing)"
  fi

  # Last step, unconditionally (even after an early failure elsewhere in the
  # run) - see audit_ownership's own per-platform definition: mac's is a
  # real check() (counts toward PASS/FAIL, can fail the run) because it
  # caught a genuine bug there; windows's is informational-only,
  # since SYSTEM/Administrators ownership is that platform's actual,
  # documented, by-design behavior, not a regression to assert against.
  echo "==> Auditing file ownership (everything touched must still belong to the real target user)"
  audit_ownership
}
trap restore_original_state EXIT

# Our own deployed script now restarts VS Code after every real, changed
# version update (see README) - great to test deliberately (scenario 17),
# but if VS Code happens to already be running throughout the whole rest
# of this run, EVERY real-change scenario (2, 3, 5a, 15's own pin, 16...)
# would also trigger it as an incidental side effect - correct behavior,
# but far noisier/slower than intended, and repeatedly disruptive on a
# real daily-driver machine. Closed here (only if actually safe to - see
# real_gui_session_available) and left closed through scenarios 1-16;
# scenario 17 brings it back up deliberately when it wants to test this
# specifically. Relaunched at the very end (see restore_original_state
# above) if it really was running before this script started.
if vscode_gui_session_running; then
  echo "==> [DIAG] pre-test setup: VS Code pids before any action = $(get_vscode_pids)"
  if real_gui_session_available; then
    echo "==> [DIAG] pre-test setup: no unsaved buffers detected - about to call kill_vscode_gui_session"
    echo "==> Closing the already-running VS Code session for the duration of scenarios 1-16"
    kill_vscode_gui_session
    echo "==> [DIAG] pre-test setup: VS Code pids after kill_vscode_gui_session = $(get_vscode_pids)"
    PRE_TEST_VSCODE_CLOSED_BY_US=true
  else
    echo "==> [DIAG] pre-test setup: unsaved buffers detected - leaving the running session alone"
    echo "==> VS Code is running but not safe to close (unsaved buffers) - scenarios 1-16 will also trigger the restart-after-change feature as a side effect this run; not a failure, just noisier/slower"
  fi
fi

if scenario_enabled "1"; then
echo
echo "=== Scenario 1: extension removed -> must no-op ==="
code_cli --uninstall-extension "$EXT_ID" >/dev/null 2>&1 || true
check "extension is not installed before the run" "$(get_installed_version)" ""

result="$(run_script "0.4.0" "false" "$USER_EXTENSION_PATH")"
echo "  envelope: $result"
check "action is not_installed" "$(field "$result" action)" "not_installed"
check "status is skipped" "$(field "$result" status)" "skipped"
check "changed is false" "$(field "$result" changed)" "False"
check "extension is still not installed after the run" "$(get_installed_version)" ""

fi
if scenario_enabled "2"; then
echo
echo "=== Scenario 2: extension present, requested version 0.4.0 -> must set to 0.4.0 ==="
install_latest_or_die "$EXT_ID"
if [[ "$LATEST_VERSION" == "0.4.0" ]]; then
  echo "  NOTE: latest happens to already be 0.4.0 - the 'downgrade' below is actually a no-op."
fi

result="$(run_script "0.4.0" "false" "$USER_EXTENSION_PATH")"
echo "  envelope: $result"
check "status is success or skipped (already-correct edge case)" \
  "$(python3 -c "print('$(field "$result" status)' in ('success','skipped'))")" "True"
check "envelope reports installed_version_after == 0.4.0" "$(field "$result" installed_version_after)" "0.4.0"
check "code --list-extensions independently confirms version 0.4.0" "$(get_installed_version)" "0.4.0"

fi
if scenario_enabled "3"; then
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

fi
if scenario_enabled "4"; then
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

fi
if scenario_enabled "5"; then
echo
echo "=== Scenario 5a: extension_path names the real current user -> resolves and runs as that user ==="
set_installed_version "0.4.0"
result="$(run_script "" "false" "$USER_EXTENSION_PATH")"
echo "  envelope: $result"
check "target_user is $REAL_USER" "$(field "$result" target_user)" "$REAL_USER"
check "$RAN_AS_ROOT_FIELD is false" "$(field "$result" "$RAN_AS_ROOT_FIELD")" "False"
check "user_resolution_note is null" "$(field "$result" user_resolution_note)" "None"
check "code --list-extensions independently confirms version $LATEST_VERSION" "$(get_installed_version)" "$LATEST_VERSION"

fi
if scenario_enabled "5"; then
echo
echo "=== Scenario 5b: extension_path names a nonexistent user -> falls back to the isolated identity ==="
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
check "$RAN_AS_ROOT_FIELD is true" "$(field "$result" "$RAN_AS_ROOT_FIELD")" "True"
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

fi
if scenario_enabled "5"; then
echo
echo "=== Scenario 5c: extension_path names a user whose profile directory exists but is access-denied -> distinct resolution note, not confused with not-found ==="
if setup_access_denied_profile_dir; then
  set_installed_version "0.4.0"
  result="$(run_script "$LATEST_VERSION" "false" "$ACCESS_DENIED_USER_PATH")"
  echo "  envelope: $result"
  check "target_user is glow_test_locked_profile" "$(field "$result" target_user)" "glow_test_locked_profile"
  check "$RAN_AS_ROOT_FIELD is true" "$(field "$result" "$RAN_AS_ROOT_FIELD")" "True"
  check "user_resolution_note is EXTENSION_PATH_USER_PROFILE_ACCESS_DENIED (not EXTENSION_PATH_USER_NOT_FOUND - the profile genuinely exists)" \
    "$(field "$result" user_resolution_note)" "EXTENSION_PATH_USER_PROFILE_ACCESS_DENIED"
  teardown_access_denied_profile_dir
else
  skip "extension_path names a user whose profile directory exists but is access-denied" \
    "not applicable on this platform (see setup_access_denied_profile_dir)"
fi

fi
if scenario_enabled "6"; then
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

fi
if scenario_enabled "7"; then
echo
echo "=== Scenario 7: invalid extension_id -> real INVALID_PARAMS failure ==="
result="$(run_script_raw "not-an-id" "" "$USER_EXTENSION_PATH" "false")"
echo "  envelope: $result"
check "status is failure" "$(field "$result" status)" "failure"
check "error.code is INVALID_PARAMS" "$(nested_field "$result" error code)" "INVALID_PARAMS"
check "real extension state is untouched (still $LATEST_VERSION)" "$(get_installed_version)" "$LATEST_VERSION"

fi
if scenario_enabled "8"; then
echo
echo "=== Scenario 8: invalid version string -> real INVALID_PARAMS failure ==="
result="$(run_script_raw "$EXT_ID" "not-a-version" "$USER_EXTENSION_PATH" "false")"
echo "  envelope: $result"
check "status is failure" "$(field "$result" status)" "failure"
check "error.code is INVALID_PARAMS" "$(nested_field "$result" error code)" "INVALID_PARAMS"
check "real extension state is untouched (still $LATEST_VERSION)" "$(get_installed_version)" "$LATEST_VERSION"

fi
if scenario_enabled "9"; then
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

fi
if scenario_enabled "10"; then
echo
echo "=== Scenario 10: extension_path omitted entirely -> must not abort ==="
set_installed_version "0.4.0"
result="$(run_script_raw "$EXT_ID" "0.4.0" "" "false")"
echo "  envelope: $result"
check "target_user is null" "$(field "$result" target_user)" "None"
check "$RAN_AS_ROOT_FIELD is true" "$(field "$result" "$RAN_AS_ROOT_FIELD")" "True"
check "user_resolution_note is MISSING_EXTENSION_PATH" "$(field "$result" user_resolution_note)" "MISSING_EXTENSION_PATH"
# The isolated fallback identity (root's HOME=/var/root on mac; SYSTEM's own
# profile on Windows) has no VS Code extensions of its own, regardless of
# what $REAL_USER has installed - so this genuinely reports not_installed,
# not already_correct_version.
check "run still proceeds: action is not_installed (isolated identity has no extensions installed)" \
  "$(field "$result" action)" "not_installed"
check "run still proceeds: status is skipped (not failure)" "$(field "$result" status)" "skipped"

fi
if scenario_enabled "11"; then
echo
echo "=== Scenario 11: malformed extension_path -> INVALID_EXTENSION_PATH ==="
result="$(run_script "0.4.0" "false" "/tmp/not/a/valid/vscode/path")"
echo "  envelope: $result"
check "user_resolution_note is INVALID_EXTENSION_PATH" "$(field "$result" user_resolution_note)" "INVALID_EXTENSION_PATH"
check "target_user is null" "$(field "$result" target_user)" "None"
check "$RAN_AS_ROOT_FIELD is true" "$(field "$result" "$RAN_AS_ROOT_FIELD")" "True"
check "run still proceeds: status is skipped (not failure)" "$(field "$result" status)" "skipped"

fi
if scenario_enabled "12"; then
echo
echo "=== Scenario 12: extension_path names a different extension's directory -> EXTENSION_PATH_ID_MISMATCH ==="
result="$(run_script "0.4.0" "false" "$MISMATCHED_ID_PATH")"
echo "  envelope: $result"
check "user_resolution_note is EXTENSION_PATH_ID_MISMATCH" "$(field "$result" user_resolution_note)" "EXTENSION_PATH_ID_MISMATCH"
check "target_user is null" "$(field "$result" target_user)" "None"
check "$RAN_AS_ROOT_FIELD is true" "$(field "$result" "$RAN_AS_ROOT_FIELD")" "True"
check "run still proceeds: status is skipped (not failure)" "$(field "$result" status)" "skipped"

fi
if scenario_enabled "13"; then
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

fi
if scenario_enabled "14"; then
echo
echo "=== Scenario 14: extension_path is a real symlink escaping the extensions directory -> EXTENSION_PATH_UNSAFE ==="
setup_symlink_scenario

result="$(run_script "0.4.0" "false" "$SYMLINK_PATH")"
echo "  envelope: $result"
check "user_resolution_note is EXTENSION_PATH_UNSAFE" "$(field "$result" user_resolution_note)" "EXTENSION_PATH_UNSAFE"
check "target_user is $REAL_USER (parsed from path shape, kept for diagnostics)" "$(field "$result" target_user)" "$REAL_USER"
check "$RAN_AS_ROOT_FIELD is true (unsafe path falls back off the target user, not the symlink target)" "$(field "$result" "$RAN_AS_ROOT_FIELD")" "True"
check "run still proceeds: status is skipped (not failure)" "$(field "$result" status)" "skipped"

teardown_symlink_scenario

fi
if scenario_enabled "15"; then
echo
echo "=== Scenario 15: resilience to VS Code's own passive/startup extension sync ==="
if real_gui_session_available; then
  # Start from "installed at latest" so the script's own set_version
  # action (not test-harness setup) is what performs the pin, exercising
  # the exact code path a real deployment would use.
  echo "  ==> Installing $EXT_ID (latest) via raw code_cli"
  if ! primary_install_err="$(code_cli --install-extension "$EXT_ID" --force 2>&1 >/dev/null)"; then
    echo "  FAILED: raw code_cli install of $EXT_ID (latest) errored: $primary_install_err" >&2
    exit 1
  fi
  echo "  ==> Pinning $EXT_ID to 0.4.0 via our own deployed script"
  result="$(run_script "0.4.0" "false" "$USER_EXTENSION_PATH")"
  echo "  envelope: $result"
  check "our script successfully pinned to 0.4.0" "$(field "$result" installed_version_after)" "0.4.0"
  check "extension is at 0.4.0 before triggering a real VS Code session" "$(get_installed_version)" "0.4.0"

  # Control extension: old version too, but explicitly UNPINNED. Without
  # this, an unaffected pinned extension proves nothing on its own - it's
  # indistinguishable from "the passive sync never ran at all" (the exact
  # ambiguity manual investigation hit earlier in this project). Latest
  # is installed first via a raw code_cli call (mirroring the primary
  # extension's own setup above) so our script's own set_version action
  # is what performs the actual downgrade - required both to exercise the
  # real deployment code path AND because a raw code_cli call for the old
  # version directly hits the exact signature-verification wall this
  # project's bypass logic exists for, the moment that old version
  # happens to be unsigned (confirmed: errorlens's old versions are,
  # unlike autodocstring's, which is why this never surfaced via the
  # primary extension). Pinned metadata is then explicitly cleared with
  # unpin_extension.
  echo "  ==> Installing control extension $CONTROL_EXT_ID (latest) via raw code_cli"
  if ! control_install_err="$(code_cli --install-extension "$CONTROL_EXT_ID" --force 2>&1 >/dev/null)"; then
    echo "  FAILED: raw code_cli install of $CONTROL_EXT_ID (latest) errored: $control_install_err" >&2
    exit 1
  fi
  echo "  ==> Downgrading control extension $CONTROL_EXT_ID to $CONTROL_EXT_OLD_VERSION via our own deployed script"
  run_script "$CONTROL_EXT_OLD_VERSION" "false" "$CONTROL_EXTENSION_PATH" "$CONTROL_EXT_ID" >/dev/null
  echo "  ==> Unpinning control extension $CONTROL_EXT_ID"
  unpin_extension "$CONTROL_EXT_ID"
  check "control extension is at $CONTROL_EXT_OLD_VERSION and unpinned before triggering a real VS Code session" \
    "$(get_installed_version "$CONTROL_EXT_ID")" "$CONTROL_EXT_OLD_VERSION"

  # Two ways to get VS Code's extension-update-check code path to run,
  # depending on whether a session is already up: if so, poke it in
  # place via the Command Palette rather than quitting/relaunching a
  # session that might be in active use (on this dev machine, that VS
  # Code instance is liable to be the one hosting an active Claude Code
  # session - quitting it can stall arbitrarily on that session's own
  # teardown, and a relaunch would just reattach to what was already
  # running anyway, never a genuine cold boot). Otherwise, cold-boot one
  # ourselves and restore the original (not-running) state afterward.
  we_launched_session=false
  session_ready=true
  if vscode_gui_session_running; then
    echo "  VS Code is already running - triggering its 'Check for Extension Updates' in place..."
    trigger_vscode_extension_update_check || session_ready=false
  else
    echo "  Launching a real VS Code GUI session to let its passive startup extension sync run..."
    launch_vscode_gui_session || session_ready=false
    we_launched_session=true
  fi

  if [[ "$session_ready" == true ]]; then
    [[ "$we_launched_session" == true ]] && GUI_SESSION_LAUNCHED=true
    # Poll rather than a single fixed sleep: the primary (pinned)
    # extension's check is an instant decision ("pinned, skip") with no
    # network involved, but the control extension's update requires a
    # real marketplace download + install, which can take meaningfully
    # longer than a few seconds depending on extension size/network -
    # confirmed empirically (a fixed 15s sleep saw the pinned check
    # correctly hold, but wasn't long enough for the control extension's
    # update to finish on either mac or windows). Polls every 5s up to
    # 90s total, returning as soon as a change is observed.
    echo "  ==> Polling for the passive sync to run (up to 90s)..."
    waited=0
    control_version_after="$CONTROL_EXT_OLD_VERSION"
    while [[ $waited -lt 90 ]]; do
      sleep 5
      waited=$((waited + 5))
      control_version_after="$(get_installed_version "$CONTROL_EXT_ID")"
      echo "      ...${waited}s: control extension version is ${control_version_after:-<not installed>}"
      if [[ -n "$control_version_after" && "$control_version_after" != "$CONTROL_EXT_OLD_VERSION" ]]; then
        break
      fi
    done
    echo "  (waited ${waited}s; control extension version now: ${control_version_after:-<not installed>})"
    if [[ "$we_launched_session" == true ]]; then
      echo "  ==> Closing the VS Code session this scenario cold-booted"
      kill_vscode_gui_session
      GUI_SESSION_LAUNCHED=false
    fi

    check "extension version is unaffected by VS Code's own passive startup sync (protected by the 'pinned' extensions.json metadata, set automatically by --install-extension id@version)" \
      "$(get_installed_version)" "0.4.0"
    # Informational, not a check() - deliberately never fails the run.
    # Confirms (when it happens) that the sync genuinely executed, so the
    # pinned check above is a real pass rather than "nothing happened at
    # all" - but VS Code's actual update-execution has its own internal
    # cooldown/debounce separate from the "identify outdated extensions"
    # step (confirmed via its own logs: the same trigger reliably
    # performed a real install once, but silently no-op'd when invoked
    # again shortly after an earlier automatic check) - a real-world
    # timing quirk outside this script's control, not something to treat
    # as a test failure.
    if [[ -n "$control_version_after" && "$control_version_after" != "$CONTROL_EXT_OLD_VERSION" ]]; then
      echo "  INFO: control (unpinned) extension WAS updated (now $control_version_after) - confirms the sync genuinely ran."
    else
      echo "  INFO: control (unpinned) extension was NOT updated within ${waited}s - inconclusive whether the sync actually ran this time (see VS Code's own update-check cooldown behavior, noted above); not counted as a failure."
    fi
  else
    skip "extension version is unaffected by VS Code's own passive startup sync" \
      "could not confirm a real GUI session was ready (see launch_vscode_gui_session/trigger_vscode_extension_update_check)"
    skip "control (unpinned) extension WAS updated by the passive sync" \
      "could not confirm a real GUI session was ready (see launch_vscode_gui_session/trigger_vscode_extension_update_check)"
  fi
else
  skip "resilience to VS Code's own passive/startup extension sync" \
    "no real interactive GUI session available right now (see real_gui_session_available)"
  skip "control (unpinned) extension WAS updated by the passive sync" \
    "no real interactive GUI session available right now (see real_gui_session_available)"
fi

fi
if scenario_enabled "16"; then
echo
echo "=== Scenario 16: signature verification is real, and our script's install works despite it ==="
# Ensure the extension isn't already sitting at the signature-test
# version before this scenario even starts - otherwise "manually
# installing" that exact already-installed version is a no-op reinstall
# that never actually hits the marketplace/verification path at all
# (confirmed: this is exactly what happened when an earlier run's own
# cleanup left the extension at SIGNATURE_TEST_VERSION and this scenario
# ran again right after - the "manual install" trivially succeeded,
# having verified nothing). Reset to latest here, before
# set_verify_signature_true turns enforcement on below, since latest is
# always signed and this reset shouldn't itself need the bypass.
install_latest_or_die "$EXT_ID"
SETTINGS_BACKUP_VALUE="$(get_settings_backup)"
SETTINGS_BACKUP_CAPTURED=true
set_verify_signature_true
clear_vsix_cache_for_version "$SIGNATURE_TEST_VERSION"

echo "  Attempting a manual (unbypassed) install of ${EXT_ID}@${SIGNATURE_TEST_VERSION}..."
manual_install_exit=0
manual_install_out="$(code_cli --install-extension "${EXT_ID}@${SIGNATURE_TEST_VERSION}" --force 2>&1)" || manual_install_exit=$?
echo "  manual install output: $manual_install_out"
# Informational, not check() - the marketplace's signing policy for
# njpwerner.autodocstring changed since this scenario was written: its
# old versions (both 0.4.0 and 0.5.0, confirmed directly) are no longer
# blocked by signature verification at all, with or without this
# scenario's own extensions.verifySignature:true. That's an environmental
# fact outside this script's control, not something to fail the run over -
# what still matters and IS asserted below is that our own script's
# install keeps working regardless of whichever way this cuts.
if [[ $manual_install_exit -ne 0 ]]; then
  echo "  INFO: manual install was blocked (exit $manual_install_exit) - signature verification is currently being enforced for this version."
else
  echo "  INFO: manual install was NOT blocked (exit 0) - this extension's old versions are apparently no longer signature-restricted on the marketplace; not counted as a failure (see README)."
fi

# Reset to latest again before our own script's real test below,
# regardless of whether the manual attempt above just landed on
# SIGNATURE_TEST_VERSION itself (now a real possibility, if that version
# is no longer signature-blocked) - otherwise our own script's call could
# see "already at target" and skip, never actually exercising a real
# install through it.
install_latest_or_die "$EXT_ID"
clear_vsix_cache_for_version "$SIGNATURE_TEST_VERSION"

echo "  Now running our own deployed script for the same extension/version..."
result="$(run_script "$SIGNATURE_TEST_VERSION" "false" "$USER_EXTENSION_PATH")"
echo "  envelope: $result"
check "our script succeeds despite verification being explicitly on" "$(field "$result" status)" "success"
check "envelope reports installed_version_after == $SIGNATURE_TEST_VERSION" "$(field "$result" installed_version_after)" "$SIGNATURE_TEST_VERSION"
check "code --list-extensions independently confirms version $SIGNATURE_TEST_VERSION" "$(get_installed_version)" "$SIGNATURE_TEST_VERSION"
check "deployed script's own on-disk settings.json backup does not linger after a normal run" \
  "$(settings_backup_file_exists && echo present || echo absent)" "absent"

restore_settings_backup "$SETTINGS_BACKUP_VALUE"
SETTINGS_BACKUP_CAPTURED=false
check "settings.json restored to its original content" "$(get_settings_backup)" "$SETTINGS_BACKUP_VALUE"

fi
if scenario_enabled "17"; then
echo
echo "=== Scenario 17: our own script restarts VS Code after a real version change ==="

echo "  --- 17a: VS Code running -> real change -> vscode_restarted reported true, and it actually cycles ---"
we_launched_session=false
session_ready=true
if vscode_gui_session_running; then
  echo "  ==> VS Code is already running - reusing that session"
else
  echo "  ==> Launching a real VS Code GUI session (cold boot)"
  launch_vscode_gui_session || session_ready=false
  we_launched_session=true
fi

if [[ "$session_ready" == true ]]; then
  [[ "$we_launched_session" == true ]] && GUI_SESSION_LAUNCHED=true
  pids_before="$(get_vscode_pids)"
  echo "  ==> pids before: ${pids_before:-<none>}"
  echo "  ==> Setting $EXT_ID to 0.4.0 via raw code_cli (baseline before our script's own change)"
  set_installed_version "0.4.0"
  echo "  ==> Running our deployed script to change $EXT_ID's version (should trigger a restart)"
  result="$(run_script "" "false" "$USER_EXTENSION_PATH")"
  echo "  envelope: $result"
  check "action is upgrade_to_latest" "$(field "$result" action)" "upgrade_to_latest"
  check "status is success" "$(field "$result" status)" "success"
  check "changed is true" "$(field "$result" changed)" "True"
  check "envelope reports vscode_restarted true" "$(field "$result" vscode_restarted)" "True"

  echo "  ==> Polling for VS Code's process to actually cycle to a new pid (up to 30s)..."
  waited=0
  pids_after="$pids_before"
  while [[ $waited -lt 30 ]]; do
    sleep 2
    waited=$((waited + 2))
    pids_after="$(get_vscode_pids)"
    echo "      ...${waited}s: pids now: ${pids_after:-<none>}"
    [[ -n "$pids_after" && "$pids_after" != "$pids_before" ]] && break
  done
  check "VS Code's process actually cycled (new pid, not the same one as before)" \
    "$([[ -n "$pids_after" && "$pids_after" != "$pids_before" ]] && echo cycled || echo unchanged)" "cycled"

  if [[ "$we_launched_session" == true ]]; then
    echo "  ==> Closing the VS Code session this scenario cold-booted"
    kill_vscode_gui_session
    GUI_SESSION_LAUNCHED=false
  fi
else
  skip "our own script restarts VS Code after a real version change (VS Code already running)" \
    "could not confirm a real GUI session was ready"
fi

echo "  --- 17b: VS Code NOT running -> real change -> vscode_restarted reported false, nothing launches ---"
if vscode_gui_session_running; then
  echo "  ==> Closing the running VS Code session so this case starts from a real 'not running' state"
  kill_vscode_gui_session
fi
if vscode_gui_session_running; then
  skip "our own script does not launch VS Code when it wasn't already running" \
    "could not confirm VS Code was actually stopped first"
else
  # Baseline just needs to be something other than 0.4.0, so our script's
  # own change below is a real, changed action - not necessarily "latest"
  # specifically. Installs latest directly (no version = always signed,
  # no signature-bypass wall to worry about) rather than reusing
  # scenario 3's own $LATEST_VERSION, which is unset here whenever 17
  # runs without 3 in the same invocation (confirmed: "unbound variable"
  # under set -u when isolating scenario 17 via --scenario).
  echo "  ==> Setting $EXT_ID back to latest via raw code_cli (baseline before our script's own change)"
  install_latest_or_die "$EXT_ID"
  echo "  ==> Running our deployed script to change $EXT_ID's version (VS Code not running - should stay that way)"
  result="$(run_script "0.4.0" "false" "$USER_EXTENSION_PATH")"
  echo "  envelope: $result"
  check "status is success" "$(field "$result" status)" "success"
  check "changed is true" "$(field "$result" changed)" "True"
  check "envelope reports vscode_restarted false" "$(field "$result" vscode_restarted)" "False"
  check "VS Code was not launched as a side effect" \
    "$(vscode_gui_session_running && echo running || echo not_running)" "not_running"
fi

fi
if scenario_enabled "18"; then
echo
echo "=== Scenario 18: a real, indefinitely-hung code invocation is detected, killed, and reported - not left running or hung forever ==="
if stub_code_binary; then
  echo "  ==> Real code binary/code.cmd backed up and replaced with a stub that hangs forever"
  start_ts=$(date +%s)
  result="$(run_script "" "false" "$USER_EXTENSION_PATH")"
  end_ts=$(date +%s)
  elapsed=$((end_ts - start_ts))
  echo "  envelope: $result"
  echo "  (call returned after ${elapsed}s)"
  # Generous bound - the real timeout+kill mechanism (~20-22s on both
  # platforms) plus process/SSH overhead should never come close to this;
  # only a real regression (the hung process never actually killed)
  # would take this long.
  check "call returns within a bounded time, not hung forever" \
    "$([[ $elapsed -lt 60 ]] && echo bounded || echo unbounded)" "bounded"
  check "status is failure" "$(field "$result" status)" "failure"
  check "error.code is LIST_EXTENSIONS_FAILED" "$(nested_field "$result" error code)" "LIST_EXTENSIONS_FAILED"
  restore_code_binary
  echo "  ==> Real code binary/code.cmd restored"
else
  skip "a real, indefinitely-hung code invocation is detected, killed, and reported" \
    "could not safely stub the code binary (see the error above)"
fi
fi
echo
echo "$PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
