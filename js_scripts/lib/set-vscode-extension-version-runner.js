// =====================================================================
// Glow Action Script - Set VS Code Extension Version (macOS, JXA) - runner half.
//
// This file is the OS-interaction glue only: RTR contract (base64 in / JSON
// envelope out), running the `code` CLI as the target user, filesystem-level
// path safety checks, diagnostics. Every actual DECISION (is this extension
// installed, does its version already match, what should happen, which user
// does the given path belong to) lives in vscode-extension-version-policy.js,
// which this file assumes is already in scope - see js_scripts/build.sh,
// which concatenates that file first, then this one, into the deployed
// dist/set-vscode-extension-version.js. Mirrors vscode-guard-runner.js's
// split for the same reasons.
//
// Sets an installed VS Code extension to a specific version (upgrading or
// downgrading as needed), or to the latest available version if no version
// is given. Per spec: if the extension is NOT currently installed, this
// script does nothing - it never installs an extension fresh.
//
//   - Not installed                       -> no-op.
//   - Installed, no version given         -> `code --install-extension <id> --force`
//     (no @version resolves and installs latest; `--upgrade-extension` is NOT
//     a real flag on this CLI - see upgradeToLatest for details).
//   - Installed, version given, differs   -> `code --install-extension <id>@<version> --force`
//     (this one command handles both upgrade and downgrade - it just forces
//     the exact requested version, whichever direction that is from current).
//   - Installed, version given, matches   -> no-op.
//
// Target user resolution: NOT "whoever is at the console" - the caller
// supplies `extension_path` (the path to the extension's installed
// directory, or a file within it, e.g. from a file watch on
// ~/.vscode/extensions/<id>-<version>), and the target user is extracted
// from that path. This is NEVER a hard failure: resolveTargetUser cannot
// abort the run. Whenever it can't confidently resolve a real account for
// the path (path missing/malformed, doesn't match extension_id, fails the
// filesystem symlink-safety check, or names a user with no such account),
// it just falls back to running `code` directly as root (RTR's own
// identity) instead of via `launchctl asuser` - and keeps whatever username
// it DID manage to parse (if any) around in the envelope purely for
// diagnostics, never as a reason to stop.
//
// All `code` invocations run inside the resolved user's context via
// `launchctl asuser` when we have a real uid, since installed extensions
// are normally a per-user concept (~/.vscode/extensions).
//
// RTR contract:
//   - Input  : single base64-encoded JSON passed as $args[0].
//   - Output : one compact JSON object on stdout (the ActionResult envelope).
//   - Stderr : SILENT. All errors are reported inside the JSON envelope.
//   - Diag   : file-only at /tmp/glow/rtr.txt. Never stderr.
//
// Local testing (no args uses safe defaults: dry_run=true):
//   INPUT=$(printf '%s' '{"params":{"extension_id":"ms-python.python","version":"2024.1.0","extension_path":"/Users/jdoe/.vscode/extensions/ms-python.python-2024.5.0"},"dry_run":true}' | base64)
//   sudo osascript -l JavaScript set-vscode-extension-version.js "$INPUT"
// =====================================================================

ObjC.import('Foundation');
ObjC.import('stdlib'); // for $.kill (SIGKILL escalation in _runCommand)

// ===== Section 0: Constants =====

var SCRIPT_VERSION = 1;
var OS_FAMILY      = 'mac';
var DIAG_FILE      = '/tmp/glow/rtr.txt';

var DEFAULT_CMD_TIMEOUT_SEC = 20;
var SIGKILL_GRACE_SEC       = 2;
var POLL_INTERVAL_SEC       = 0.1;
// Installing/upgrading an extension downloads a VSIX over the network -
// give it much longer than a quick local command before we give up.
var INSTALL_CMD_TIMEOUT_SEC = 120;

var VSCODE = {
  codePath: '/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code',
};

var _fm = $.NSFileManager.defaultManager;

// ===== Section 1: Small Helpers =====

function nowIso() {
  var f = $.NSISO8601DateFormatter.alloc.init;
  return f.stringFromDate($.NSDate.date).js;
}

function writeDiag(msg) {
  try {
    var dir = '/tmp/glow';
    if (!isDirectory(dir)) {
      _fm.createDirectoryAtPathWithIntermediateDirectoriesAttributesError(dir, true, $(), null);
    }
    var line = '[' + nowIso() + '] ' + msg + '\n';
    var data = $.NSString.alloc.initWithUTF8String(line).dataUsingEncoding($.NSUTF8StringEncoding);
    var fh = $.NSFileHandle.fileHandleForWritingAtPath(DIAG_FILE);
    if (fh.isNil()) {
      $.NSString.alloc.initWithUTF8String(line)
        .writeToFileAtomicallyEncodingError(DIAG_FILE, true, $.NSUTF8StringEncoding, null);
    } else {
      fh.seekToEndOfFile;
      fh.writeData(data);
      fh.closeFile;
    }
  } catch (e) { /* never throw from diagnostics */ }
}

function hostname() {
  try { return $.NSProcessInfo.processInfo.hostName.js || ''; } catch (e) { return ''; }
}

function serialNumber() {
  try {
    var r = _runCommand('/usr/sbin/ioreg', ['-c', 'IOPlatformExpertDevice', '-d', '2']);
    if (r.exitCode === 0 && r.stdout) {
      var m = r.stdout.match(/"IOPlatformSerialNumber"\s*=\s*"([^"]+)"/);
      if (m) return m[1];
    }
  } catch (e) {}
  return '';
}

function getOSMajorVersion() {
  try {
    var r = _runCommand('/usr/bin/sw_vers', ['-productVersion']);
    if (r.exitCode === 0 && r.stdout) {
      var major = parseInt(r.stdout.trim().split('.')[0], 10);
      if (!isNaN(major)) return major;
    }
  } catch (e) {}
  writeDiag('WARN: could not determine macOS version');
  return 0;
}

// ===== Section 2: Filesystem Helpers =====

function fileExists(path) {
  return _fm.fileExistsAtPath(path);
}

function isDirectory(path) {
  var isDir = Ref();
  var exists = _fm.fileExistsAtPathIsDirectory(path, isDir);
  return exists && isDir[0];
}

// Resolve symlink chain; reject control chars and traversal. Returns
// canonical path or null. macOS maps /tmp,/var,/etc to /private/*; strip
// that prefix so only real symlinks (not that mapping) cause a mismatch.
// Same technique as remove-browser-extension.js's resolveSafe.
function resolveSafe(path) {
  if (!path || typeof path !== 'string') return null;
  if (/[\x00-\x1f]/.test(path)) return null;
  if (path.indexOf('..') !== -1) return null;
  var resolved, standardized;
  try {
    resolved     = $(path).stringByResolvingSymlinksInPath.js;
    standardized = $(path).stringByStandardizingPath.js;
  } catch (e) { return null; }
  if (!resolved || !standardized) return null;
  var sys = ['/tmp', '/var', '/etc'];
  for (var i = 0; i < sys.length; i++) {
    if (resolved === sys[i] || resolved.indexOf(sys[i] + '/') === 0) {
      resolved = '/private' + resolved;
      break;
    }
  }
  var cmp = resolved;
  if (!/^\/private\//.test(standardized) && /^\/private\//.test(cmp)) {
    cmp = cmp.replace(/^\/private/, '');
  }
  if (standardized !== cmp) return null;
  return resolved;
}

// ===== Section 3: NSTask Helper =====

// Run a command with a timeout. SIGTERM after timeoutSec; SIGKILL after an
// additional SIGKILL_GRACE_SEC if the process does not exit.
//
// Uses a single NSPipe for both stdout and stderr (like shell's 2>&1),
// deliberately NOT two separate pipes: NSTask + dual-pipe setups have a
// classic deadlock risk if the child fills one pipe's kernel buffer while
// we're still blocked reading the other. One shared pipe sidesteps that
// entirely. (An earlier version of this function used temp files + late
// NSFileHandle reads instead of a pipe read up front; that silently
// returned empty stdout even on a successful, fast command like `id -u` -
// this pipe-based approach is verified to actually work.)
// Polls task.isRunning against a real wall-clock deadline instead of
// scheduling an NSTimer around a blocking readDataToEndOfFile - the
// previous approach. CONFIRMED real and reproduced (not just theorized):
// under a real RTR-invoked run, `code --list-extensions` never returned;
// the live stuck process's own stack sample showed the main thread still
// blocked inside readDataToEndOfFile minutes past its configured 20s
// timeout, with the scheduled kill timer never having fired. NSTimer
// callbacks only ever run while the run loop is turning, and a
// synchronous blocking read does not pump it - so that timeout was dead
// code whenever the child stalled with its pipe still open.
//
// This fix alone (before the working-directory fix below existed) is
// what surfaced the actual root cause: instead of hanging forever, the
// next real run returned a real error - `code`'s own Node startup
// hitting EACCES on process.cwd() (see the currentDirectoryPath
// assignment's own comment) - which apparently sent it into exactly the
// stuck-in-startup state the stack sample had shown, rather than a clean
// fast exit. With both fixes in place, a full real-world suite run
// against actual RTR passed end to end. Kept as a poll loop rather than
// reverted now that the cause is understood: this class of "the child
// hangs instead of failing fast" behavior is a real thing Node/Electron
// can do, and this function has no way to know in advance it won't
// happen again for some other reason.
//
// Deliberately does not drain the pipe incrementally during the poll:
// Date.now()/task.isRunning/task.terminate/$.kill are all independent of
// pipe I/O, so this loop reliably detects and kills a hang no matter
// what's sitting in the pipe. The one accepted tradeoff: if a child
// writes enough combined stdout+stderr to fill the OS pipe buffer
// (~64KB) before exiting, it blocks on its own write() with nobody
// draining the read end, so isRunning stays true until this loop's own
// timeout forcibly kills it - slower than incremental draining would be,
// but still bounded and correct, and no command in this file ever
// approaches that volume.
function _runCommand(launchPath, args, timeoutSec) {
  var timeout = timeoutSec || DEFAULT_CMD_TIMEOUT_SEC;
  var cmdDesc = launchPath + ' ' + (args ? args.join(' ') : '');
  writeDiag('_runCommand: starting [' + cmdDesc + '] timeout=' + timeout + 's');
  try {
    var task = $.NSTask.alloc.init;
    task.launchPath = launchPath;
    if (args) task.arguments = args;
    // Never trust the inherited working directory - CONFIRMED real via
    // the actual error this was chasing: an RTR run `cd`s into its own
    // staging directory (root-created, mode 0700) before invoking this
    // script; a child spawned here would inherit that same cwd, and once
    // runCode's sudo -H -u '#uid' drops it to the target user, that user
    // can no longer even call getcwd() from inside a directory it has
    // zero permission on - Node/the CLI (and even sudo's own shell-init)
    // failed immediately with EACCES. /tmp is mode 1777 (sticky,
    // world-traversable) - accessible to any uid regardless of whatever
    // directory the caller happened to be sitting in.
    task.currentDirectoryPath = '/tmp';
    var pipe = $.NSPipe.pipe;
    task.standardOutput = pipe;
    task.standardError  = pipe;
    task.launch;

    var pid = task.processIdentifier;
    writeDiag('_runCommand: launched pid=' + pid + ' [' + cmdDesc + ']');

    var deadline     = Date.now() + timeout * 1000;
    var hardDeadline = deadline + SIGKILL_GRACE_SEC * 1000;
    var terminated   = false;
    while (task.isRunning) {
      var now = Date.now();
      if (!terminated && now >= deadline) {
        writeDiag('_runCommand: timeout reached (' + timeout + 's), terminating pid=' + pid + ' [' + cmdDesc + ']');
        try { task.terminate; } catch (_) {}
        terminated = true;
      } else if (terminated && now >= hardDeadline) {
        writeDiag('_runCommand: still running ' + SIGKILL_GRACE_SEC + 's after terminate, SIGKILL pid=' + pid + ' [' + cmdDesc + ']');
        try { $.kill(pid, 9); } catch (_) {}
      }
      $.NSThread.sleepForTimeInterval(POLL_INTERVAL_SEC);
    }

    writeDiag('_runCommand: task no longer running, pid=' + pid + ' - reading output');
    var outData = pipe.fileHandleForReading.readDataToEndOfFile;
    writeDiag('_runCommand: readDataToEndOfFile returned, pid=' + pid + ' - calling waitUntilExit');
    task.waitUntilExit;
    writeDiag('_runCommand: waitUntilExit returned, pid=' + pid + ' exitCode=' + task.terminationStatus);

    var out = _dataToString(outData);
    return { exitCode: task.terminationStatus, stdout: out, stderr: out };
  } catch (e) {
    writeDiag('_runCommand: EXCEPTION [' + cmdDesc + ']: ' + e);
    return { exitCode: -1, stdout: '', stderr: String(e) };
  }
}

function _dataToString(data) {
  try {
    var s = $.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding);
    return s && !s.isNil() ? s.js : '';
  } catch (e) { return ''; }
}

function readFileRaw(path) {
  if (!fileExists(path)) return null;
  try {
    var s = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null);
    return (s && !s.isNil()) ? s.js : null;
  } catch (e) { return null; }
}

// $3 = uid to chown the written file to afterward (null/omitted = leave as
// this process' own euid - the deliberate root-fallback case). This write
// happens in-process (NSString, not a subprocess) - there is no `launchctl
// asuser`/`sudo` command line to attach a different uid to in the first
// place, so without this explicit chown the file comes out owned by
// whatever euid THIS script itself is running as (root, for any real
// MDM/Jamf deployment) regardless of which user runCode's own `code` CLI
// call is targeting. Confirmed via a real run: settings.json came out
// fresh root-owned immediately after enableSignatureBypass, in the same
// invocation where the actual `code` CLI call correctly reported
// target_user in its envelope.
function writeFileRaw(path, content, uid) {
  var dir = path.substring(0, path.lastIndexOf('/'));
  if (!isDirectory(dir)) {
    _fm.createDirectoryAtPathWithIntermediateDirectoriesAttributesError(dir, true, $(), null);
  }
  $.NSString.alloc.initWithUTF8String(content)
    .writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, null);
  chownToUser(path, uid);
}

function removeFile(path) {
  try { _fm.removeItemAtPathError(path, null); } catch (e) {}
}

function chownToUser(path, uid) {
  if (uid === null || uid === undefined) return;
  try { _runCommand('/usr/sbin/chown', [String(uid), path]); } catch (e) {}
}

// ===== Section 4: Target User Resolution (never aborts) =====

// Combines the pure path-format validation (parseUserFromExtensionPath) with
// a real filesystem symlink-safety check, then looks up the user's uid.
//
// This function ALWAYS returns something usable - it never signals "abort
// the run". Whenever a real, resolvable account can't be confidently
// determined (path missing/malformed, doesn't match extension_id, fails the
// safety check, or names a user with no such account), uid comes back null
// and the caller runs `code` directly as root instead. `user` reflects
// whatever username WAS parsed from the path, if any - kept for diagnostics
// regardless of whether that account actually exists.
//
// Returns { user: string|null, uid: number|null, resolution_note: string|null }.
function resolveTargetUser(extensionPath, extId) {
  var parsed = parseUserFromExtensionPath(extensionPath, extId);
  if (!parsed.ok) {
    return { user: null, uid: null, resolution_note: parsed.error };
  }

  var safePath = resolveSafe(extensionPath);
  var reparsed = safePath ? parseUserFromExtensionPath(safePath, extId) : null;
  if (!safePath || !reparsed.ok || reparsed.user !== parsed.user) {
    writeDiag('WARN: extension_path failed filesystem safety check - running as root instead: ' + extensionPath);
    return { user: parsed.user, uid: null, resolution_note: 'EXTENSION_PATH_UNSAFE' };
  }

  var idr = _runCommand('/usr/bin/id', ['-u', parsed.user]);
  var uid = (idr.exitCode === 0 && idr.stdout) ? parseInt(idr.stdout.trim(), 10) : NaN;
  if (isNaN(uid) || uid < 500) {
    writeDiag('WARN: extension_path names user "' + parsed.user + '" but no such account exists - running as root instead');
    return { user: parsed.user, uid: null, resolution_note: 'EXTENSION_PATH_USER_NOT_FOUND' };
  }
  return { user: parsed.user, uid: uid, resolution_note: null };
}

// Derives the target identity's own VS Code settings.json path from the
// SAME identity runCode() already operates as (a resolved real user via
// launchctl asuser, or root's own HOME=/var/root for the fallback case) -
// never a different user's.
function getSettingsPath(uid, user) {
  if (uid === null) {
    return '/var/root/Library/Application Support/Code/User/settings.json';
  }
  return '/Users/' + user + '/Library/Application Support/Code/User/settings.json';
}

// Real-world finding: as of VS Code 1.127, the marketplace only serves a
// signature for an extension's current latest version - installing or
// pinning ANY older version (the entire point of this script's --version
// support: upgrade OR downgrade to an exact pinned version) fails with
// "Signature verification failed: NotSigned" otherwise. Temporarily
// setting extensions.verifySignature: false in the target identity's own
// settings.json around each CLI call - never a different user's, and
// reverted immediately after (see restoreSignatureVerification) - makes
// this tool's own already-trusted, RTR-driven installs work regardless of
// marketplace signing status, without leaving that setting changed
// afterward or affecting the user's own interactive VS Code session
// beyond the brief window of a single CLI invocation.
//
// Restoration writes back the exact original raw file text, not a
// reparsed/reserialized version - settings.json commonly has jsonc
// comments a parse+rewrite round-trip would silently destroy; only the
// brief window during the CLI call itself goes through a parsed form.
function enableSignatureBypass(settingsPath, uid) {
  var fileExisted = fileExists(settingsPath);
  var originalRaw = fileExisted ? readFileRaw(settingsPath) : null;

  var settings = {};
  if (originalRaw && originalRaw.trim()) {
    try {
      settings = JSON.parse(originalRaw);
    } catch (e) {
      writeDiag('WARN: could not parse existing settings.json at ' + settingsPath + ': ' + e + ' - leaving it untouched, signature bypass not applied for this call');
      return { applied: false };
    }
  }
  settings['extensions.verifySignature'] = false;
  writeFileRaw(settingsPath, JSON.stringify(settings), uid);

  return { applied: true, settingsPath: settingsPath, fileExisted: fileExisted, originalRaw: originalRaw, uid: uid };
}

function restoreSignatureVerification(state) {
  if (!state || !state.applied) return;
  try {
    if (state.fileExisted) {
      writeFileRaw(state.settingsPath, state.originalRaw, state.uid);
    } else {
      removeFile(state.settingsPath);
    }
  } catch (e) {
    writeDiag('WARN: could not restore settings.json at ' + state.settingsPath + ': ' + e);
  }
}

// Run the `code` CLI as the target user via launchctl asuser, so it reads/
// writes that user's ~/.vscode/extensions - or, when uid is null (no
// confidently-resolved account), as root's own identity instead.
//
// The root-fallback case forces HOME=/var/root via `/usr/bin/env` rather
// than just launching VSCODE.codePath directly: NSTask inherits this
// process's ambient environment when none is given, and that environment's
// HOME is not reliably root's own - e.g. a plain interactive `sudo` (as
// opposed to `sudo -i`) commonly leaves the invoking user's HOME in place.
// Without this override, "falls back to root" could silently operate on
// whichever real user's ~/.vscode/extensions happens to be ambient, instead
// of being isolated from any specific user as intended.
//
// Brackets the call with the signature-verification bypass above, enabled
// only for this one invocation and always restored afterward, success or
// failure (see enableSignatureBypass/restoreSignatureVerification).
function runCode(uid, user, args, timeoutSec) {
  writeDiag('runCode: entry, uid=' + uid + ' user=' + user + ' args=[' + (args || []).join(' ') + ']');
  var settingsPath = getSettingsPath(uid, user);
  var bypassState = enableSignatureBypass(settingsPath, uid);
  writeDiag('runCode: signature bypass applied=' + (bypassState && bypassState.applied));
  try {
    if (uid === null) {
      var rootArgs = ['HOME=/var/root', VSCODE.codePath].concat(args);
      var rootResult = _runCommand('/usr/bin/env', rootArgs, timeoutSec);
      writeDiag('runCode: root-fallback _runCommand returned exitCode=' + rootResult.exitCode);
      return rootResult;
    }
    // `launchctl asuser` only attaches this process to the target user's
    // Mach bootstrap namespace/session (needed so `code` can reach the
    // right window server / TCC identity) - per `man launchctl`, it
    // explicitly "does not modify the process' credentials (UID, GID,
    // etc.)". Without also dropping real credentials via `sudo -H -u
    // '#uid'` inside that already-attached context, `code` (and every
    // file it writes - ~/.vscode/extensions/<id>-<version>, extensions.json,
    // .obsolete) runs and is owned by whichever euid invoked this script
    // in the first place (root, for any real Jamf/MDM deployment) -
    // confirmed via a real run: a "successful" install left its new
    // extension folder root-owned despite the envelope correctly
    // reporting target_user. `#uid` (not the username) so this works even
    // when only a numeric uid was resolved.
    var fullArgs = ['asuser', String(uid), '/usr/bin/sudo', '-H', '-u', '#' + uid, VSCODE.codePath].concat(args);
    var result = _runCommand('/bin/launchctl', fullArgs, timeoutSec);
    writeDiag('runCode: launchctl asuser _runCommand returned exitCode=' + result.exitCode);
    return result;
  } finally {
    writeDiag('runCode: restoring signature verification state');
    restoreSignatureVerification(bypassState);
    writeDiag('runCode: exit');
  }
}

// A changed extension version only takes effect for a window's already-
// running extension host once that window is reloaded/restarted - VS
// Code does not hot-swap an active extension's code on disk changing out
// from under it. A managed version-pinning tool can't rely on the user
// noticing a "reload required" prompt (or one even appearing) on their
// own, so if the target user's VS Code is currently running, it's fully
// restarted after a real, successful, changed version update - quit and
// relaunched, not just a lighter reload, since there's no CLI/API surface
// to trigger a window reload externally in an already-running instance
// (see real_world_check_set_vscode_extension_version.sh's own
// investigation of this same gap in its Command Palette automation).
// Only applies to a real resolved user (uid !== null) - the root-fallback
// identity has no real GUI session to restart. Best-effort: never
// affects the run's overall success/failure, only logged to diagnostics.
//
// Uses `ps -u <uid>` + a literal substring match on comm, not
// pgrep/pkill -f: both were found, empirically, to unreliably fail to
// match this exact binary for reasons that resisted explanation (same
// finding as the real-world check's own _vscode_main_process_running).
function findRunningVSCodePids(uid) {
  var r = _runCommand('/bin/ps', ['-u', String(uid), '-o', 'pid=,comm=']);
  if (r.exitCode !== 0) return [];
  var pids = [];
  var lines = (r.stdout || '').split('\n');
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim();
    if (!line) continue;
    var m = line.match(/^(\d+)\s+(.*)$/);
    if (m && m[2].indexOf('Visual Studio Code.app/Contents/MacOS/Code') !== -1) {
      pids.push(m[1]);
    }
  }
  return pids;
}

// Thin wrapper so tests can override this the same way they override
// _runCommand/writeFileRaw/etc. - $.kill is a direct ObjC bridge call, not
// something that goes through _runCommand, so without this indirection a
// mocked test run would send a real SIGKILL to whatever real PID happens
// to match.
function killPid(pid, sig) {
  try {
    $.kill(pid, sig);
    writeDiag('killPid: sent signal ' + sig + ' to pid ' + pid);
  } catch (e) {
    writeDiag('killPid: FAILED to signal pid ' + pid + ' with signal ' + sig + ': ' + e);
  }
}

// Deliberately verbose diagnostic tracing (writeDiag, not just the odd
// WARN like elsewhere in this file). Kept permanently, not trimmed back
// after the investigation that added it closed out: this RTR/root
// execution path has repeatedly proven far harder to reason about than
// the same commands run locally as the real user (see _runCommand's own
// comment for two confirmed, previously invisible failures found this
// way - a dead timeout and an inherited-cwd permission crash), so every
// step here is logged with the pids observed and each spawned command's
// exitCode/stdout/stderr. A real RTR run's own /tmp/glow/rtr.txt (this
// machine, since --platform mac-rtr targets itself) shows exactly which
// step did what - in particular, whether the quit AppleEvent or the
// killPid force-kill actually reduced pids to zero before the
// unconditional `open -a` below ever runs.
function restartVSCodeIfRunning(uid) {
  if (uid === null) return false;
  var pidsBefore = findRunningVSCodePids(uid);
  writeDiag('restartVSCodeIfRunning: pids before anything = [' + pidsBefore.join(',') + ']');
  if (pidsBefore.length === 0) return false;

  // See runCode's own comment: `launchctl asuser` alone does not drop this
  // process' credentials, only its Mach bootstrap namespace - layering
  // `sudo -H -u '#uid'` inside that context is what actually makes these
  // AppleEvents originate as the real target user (matching that user's
  // own previously-granted Automation/TCC permissions) instead of root's.
  // -H matters here same as in runCode: without it, HOME stays whatever
  // this process' own euid's home is (root's /var/root under a real
  // root/RTR invocation) - confirmed real: the relaunched VS Code GUI
  // itself then can't find its own user data or keychain ("Unable to
  // write program user data", "Keychain Not Found"), and shows real
  // blocking dialogs on screen instead of just working.
  var quitResult = _runCommand('/bin/launchctl', ['asuser', String(uid), '/usr/bin/sudo', '-H', '-u', '#' + uid, '/usr/bin/osascript', '-e', 'quit app "Visual Studio Code"']);
  writeDiag('restartVSCodeIfRunning: quit command exitCode=' + quitResult.exitCode +
    ' stdout=' + JSON.stringify(quitResult.stdout) + ' stderr=' + JSON.stringify(quitResult.stderr));

  var waited = 0;
  while (findRunningVSCodePids(uid).length > 0 && waited < 10) {
    _runCommand('/bin/sleep', ['1']);
    waited++;
  }
  var pidsAfterWait = findRunningVSCodePids(uid);
  writeDiag('restartVSCodeIfRunning: waited ' + waited + 's for quit to take effect; pids now = [' + pidsAfterWait.join(',') + ']');

  var remaining = pidsAfterWait;
  if (remaining.length > 0) {
    writeDiag('restartVSCodeIfRunning: quit did not fully work - force-killing remaining pids [' + remaining.join(',') + ']');
  }
  for (var i = 0; i < remaining.length; i++) {
    killPid(parseInt(remaining[i], 10), 9);
  }
  var pidsAfterKill = findRunningVSCodePids(uid);
  writeDiag('restartVSCodeIfRunning: pids after force-kill = [' + pidsAfterKill.join(',') + ']' +
    (pidsAfterKill.length > 0 ? ' - STILL RUNNING, about to call open -a anyway' : ''));

  var openResult = _runCommand('/bin/launchctl', ['asuser', String(uid), '/usr/bin/sudo', '-H', '-u', '#' + uid, '/usr/bin/open', '-a', 'Visual Studio Code']);
  writeDiag('restartVSCodeIfRunning: open command exitCode=' + openResult.exitCode +
    ' stdout=' + JSON.stringify(openResult.stdout) + ' stderr=' + JSON.stringify(openResult.stderr));
  return true;
}

// ===== Section 5: Extension Version Actions =====

function listInstalledExtensions(uid, user) {
  return runCode(uid, user, ['--list-extensions', '--show-versions']);
}

function upgradeToLatest(uid, user, extId, dryRun) {
  if (dryRun) return { attempted: false, dry_run: true };
  // `code --upgrade-extension <id>` is NOT a real flag on this CLI (verified
  // against VS Code 1.127.0: it silently no-ops with exit code 0 while
  // Electron prints "not in the list of known options" to stderr) - installs
  // an extension by id with no @version and --force correctly resolves and
  // installs latest instead.
  var r = runCode(uid, user, ['--install-extension', extId, '--force'], INSTALL_CMD_TIMEOUT_SEC);
  return {
    attempted: true,
    exit_code: r.exitCode,
    ok: r.exitCode === 0,
    stdout: (r.stdout || '').trim(),
    stderr: (r.stderr || '').trim(),
  };
}

function setExactVersion(uid, user, extId, version, dryRun) {
  if (dryRun) return { attempted: false, dry_run: true };
  var r = runCode(
    uid, user, ['--install-extension', extId + '@' + version, '--force'], INSTALL_CMD_TIMEOUT_SEC,
  );
  return {
    attempted: true,
    exit_code: r.exitCode,
    ok: r.exitCode === 0,
    stdout: (r.stdout || '').trim(),
    stderr: (r.stderr || '').trim(),
  };
}

// ===== Section 6: Input Decode & Main =====

function getProp(obj, name, dflt) {
  if (obj === null || typeof obj !== 'object') return dflt;
  return Object.prototype.hasOwnProperty.call(obj, name) && obj[name] != null ? obj[name] : dflt;
}

function castBool(v, dflt) {
  if (typeof v === 'boolean') return v;
  if (typeof v === 'string')  return v === 'true';
  return dflt;
}

function run(argv) {
  var startTime = nowIso();
  var dryRun    = true; // safe default for bare local invocation
  var envelope;

  // Deliberately placed before any real work at all - see restartVSCodeIfRunning's
  // own comment on why this tracing is kept permanently rather than
  // trimmed back. This specific checkpoint was what proved the real
  // RTR-only "Timed out waiting for script to exit" failure was inside
  // _runCommand itself (a dead timeout, since fixed) rather than earlier
  // in staging/invocation: this line consistently reached DIAG_FILE while
  // the unconditional RESULT: line at the bottom of this function did not.
  writeDiag('run(): started, argv.length=' + (argv ? argv.length : 'null'));

  try {
    var input = null;
    if (argv && argv.length > 0 && argv[0]) {
      var data    = $.NSData.alloc.initWithBase64EncodedStringOptions(argv[0], 0);
      var decoded = $.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding).js;
      input        = JSON.parse(decoded);
      dryRun = castBool(getProp(input, 'dry_run', false), false);
    }
    writeDiag('run(): decoded input, dry_run=' + dryRun);
    var params = getProp(input, 'params', {});

    var extId = getProp(params, 'extension_id', null);
    extId = (extId == null) ? '' : String(extId);
    if (!validateExtensionId(extId)) {
      throw { code: 'INVALID_PARAMS', message: 'invalid or missing extension_id (expected "<publisher>.<name>")' };
    }

    var targetVersion = getProp(params, 'version', null);
    if (targetVersion != null) targetVersion = String(targetVersion);
    if (!validateVersion(targetVersion)) {
      throw { code: 'INVALID_PARAMS', message: 'invalid version: ' + targetVersion };
    }

    if (!fileExists(VSCODE.codePath)) {
      throw { code: 'VSCODE_NOT_INSTALLED', message: 'VS Code is not installed at ' + VSCODE.codePath };
    }

    var extensionPath = getProp(params, 'extension_path', null);
    var targetUser = resolveTargetUser(extensionPath, extId); // never aborts
    writeDiag('run(): resolved target user=' + targetUser.user + ' uid=' + targetUser.uid +
      ' resolution_note=' + targetUser.resolution_note);
    var osMajor = getOSMajorVersion();
    writeDiag('run(): about to call code --list-extensions (first call)');

    var listResult = listInstalledExtensions(targetUser.uid, targetUser.user);
    writeDiag('run(): code --list-extensions (first call) returned exitCode=' + listResult.exitCode);
    if (listResult.exitCode !== 0) {
      throw {
        code: 'LIST_EXTENSIONS_FAILED',
        message: 'code --list-extensions failed: ' + (listResult.stderr || listResult.stdout || '').trim(),
      };
    }
    var installedBefore = parseInstalledExtensionsList(listResult.stdout);
    var decision = decideVersionAction(installedBefore, extId, targetVersion);
    writeDiag('run(): decision.action=' + decision.action + ' installedVersion=' + decision.installedVersion);

    var action = null;
    var installedVersionAfter = decision.installedVersion || null;

    if (decision.action === 'not_installed') {
      // Per spec: never install fresh. Nothing more to do.
    } else if (decision.action === 'already_correct_version') {
      // Idempotent no-op.
    } else if (decision.action === 'set_version') {
      writeDiag('run(): calling setExactVersion(' + extId + '@' + targetVersion + ')');
      action = setExactVersion(targetUser.uid, targetUser.user, extId, targetVersion, dryRun);
      writeDiag('run(): setExactVersion returned ok=' + (action && action.ok));
    } else if (decision.action === 'upgrade_to_latest') {
      writeDiag('run(): calling upgradeToLatest(' + extId + ')');
      action = upgradeToLatest(targetUser.uid, targetUser.user, extId, dryRun);
      writeDiag('run(): upgradeToLatest returned ok=' + (action && action.ok));
    }

    if (action && action.attempted && action.ok) {
      // Re-list to find out what version we actually ended up at, and
      // whether anything really changed (relevant for upgrade_to_latest,
      // where we couldn't know the target version in advance).
      writeDiag('run(): action ok - about to call code --list-extensions (re-list)');
      var listAfter = listInstalledExtensions(targetUser.uid, targetUser.user);
      writeDiag('run(): code --list-extensions (re-list) returned exitCode=' + listAfter.exitCode);
      if (listAfter.exitCode === 0) {
        var installedAfter = parseInstalledExtensionsList(listAfter.stdout);
        installedVersionAfter = installedAfter[extId.toLowerCase()] || null;
      }
    }

    var outcome = computeRunOutcome(decision, action, installedVersionAfter, dryRun);
    writeDiag('run(): outcome status=' + outcome.status + ' changed=' + outcome.changed);

    var vscodeRestarted = false;
    if (outcome.status === 'success' && outcome.changed && !dryRun) {
      writeDiag('run(): outcome is a real change - about to call restartVSCodeIfRunning');
      try {
        vscodeRestarted = restartVSCodeIfRunning(targetUser.uid);
        writeDiag('run(): restartVSCodeIfRunning returned ' + vscodeRestarted);
      } catch (e) {
        writeDiag('WARN: failed to restart VS Code after version change: ' + e);
      }
    }
    writeDiag('run(): about to build envelope and return');

    envelope = {
      os_family:                OS_FAMILY,
      script_version:           SCRIPT_VERSION,
      status:                   outcome.status,
      changed:                  outcome.changed,
      error:                    outcome.error,
      dry_run:                  dryRun,
      start_time:               startTime,
      end_time:                 nowIso(),
      metadata:                 { hostname: hostname(), serial_number: serialNumber() },
      extension_id:             extId,
      target_version:           targetVersion,
      extension_path:           extensionPath,
      action:                   decision.action,
      installed_version_before: decision.installedVersion || null,
      installed_version_after:  installedVersionAfter,
      target_user:              targetUser.user,
      ran_as_root:              targetUser.uid === null,
      user_resolution_note:     targetUser.resolution_note,
      os_major_version:         osMajor,
      cli_result:               action,
      vscode_restarted:         vscodeRestarted,
    };
  } catch (e) {
    var code = (e && e.code)    ? e.code    : 'UNHANDLED_ERROR';
    var msg  = (e && e.message) ? e.message : String(e);
    writeDiag('ERROR: ' + code + ': ' + msg);
    envelope = {
      os_family:      OS_FAMILY,
      script_version: SCRIPT_VERSION,
      status:         'failure',
      changed:        false,
      error:          { code: code, message: msg, stderr: '' },
      dry_run:        dryRun,
      start_time:     startTime,
      end_time:       nowIso(),
      metadata:       { hostname: hostname(), serial_number: '' },
    };
  }

  var json = JSON.stringify(envelope);
  writeDiag('RESULT: ' + json);
  return json;
}

// osascript invokes the global run(argv) automatically; its return value is
// printed to stdout. That is the only thing this script writes to stdout.
