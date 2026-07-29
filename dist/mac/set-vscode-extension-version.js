// GENERATED FILE - DO NOT EDIT.
// Built by js_scripts/build.sh from:
//   lib/set-vscode-extension-version-policy.js (decision logic, unit tested under Node)
//   lib/set-vscode-extension-version-runner.js (OS-interaction glue, tested via mocked osascript tests)
// Edit those source files and re-run js_scripts/build.sh, not this file.

// =====================================================================
// VS Code extension version-pin decision logic (pure, no ObjC/NSTask/file I/O).
//
// Deliberately dependency-free plain JS - valid standalone under Node (see
// js_scripts/tests/test_vscode_extension_version_policy.js, run with full
// coverage) AND when concatenated into the deployed JXA script (this file +
// vscode-extension-version-runner.js -> dist/set-vscode-extension-version.js
// via js_scripts/build.sh). See vscode-allowed-extensions-policy.js for the
// same pattern applied to the guard-vscode-plugin script.
// =====================================================================

// VS Code extension ids are "<publisher>.<name>", each segment alphanumeric
// plus hyphens (e.g. "ms-python.python", "GitHub.copilot").
var EXT_ID_RE = /^[A-Za-z0-9][A-Za-z0-9-]*\.[A-Za-z0-9][A-Za-z0-9-]*$/;

// Standard semver, optional pre-release/build suffix.
var VERSION_RE = /^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$/;

function validateExtensionId(extId) {
  return typeof extId === 'string' && EXT_ID_RE.test(extId);
}

// version is OPTIONAL: null/undefined means "no pin - upgrade to the latest
// version available", which is valid input, not an error.
function validateVersion(version) {
  if (version === null || version === undefined) return true;
  return typeof version === 'string' && VERSION_RE.test(version);
}

// Parses `code --list-extensions --show-versions` output (one
// "<publisher>.<name>@<version>" per line) into a map of
// lowercased-extension-id -> version. Blank lines and lines that don't match
// the expected shape are ignored rather than throwing, since stray warning
// lines on stdout are a known possibility for the code CLI.
function parseInstalledExtensionsList(rawStdout) {
  var installed = {};
  if (typeof rawStdout !== 'string') return installed;
  var lines = rawStdout.split(/\r?\n/);
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim();
    if (!line) continue;
    var at = line.lastIndexOf('@');
    if (at <= 0) continue;
    var id = line.slice(0, at);
    var version = line.slice(at + 1);
    if (!validateExtensionId(id) || !validateVersion(version)) continue;
    installed[id.toLowerCase()] = version;
  }
  return installed;
}

// Parses and validates a VS Code extension installation path, extracting the
// macOS username it belongs to. This is how the target user is determined -
// NOT "whoever is at the console" - since the path (typically supplied by
// whatever detected/triggered the version drift, e.g. a file watch on the
// extension's own directory) identifies the actual affected user even if
// they aren't the one currently logged into the GUI session.
//
// Expected shape: /Users/<username>/.vscode/extensions/<leaf>[/...], where
// <leaf> is VS Code's own extension directory naming convention,
// "<publisher>.<name>-<version>[-<platform>]" - so <leaf> must start with
// "<extId>-" (case-insensitive) as a cross-check that the path actually
// corresponds to the claimed extension, not an unrelated or spoofed path.
//
// This performs STRING-LEVEL validation only (format, username charset, id
// prefix match) - it cannot check symlinks/traversal against the real
// filesystem (no file I/O in this pure module). The runner additionally
// resolves the path safely against the filesystem before trusting it.
//
// Returns { ok: true, user: '<username>' } or { ok: false, error: '<code>' }.
function parseUserFromExtensionPath(path, extId) {
  if (typeof path !== 'string' || !path) {
    return { ok: false, error: 'MISSING_EXTENSION_PATH' };
  }
  if (path.indexOf('..') !== -1 || /[\x00-\x1f]/.test(path)) {
    return { ok: false, error: 'INVALID_EXTENSION_PATH' };
  }
  var m = path.match(/^\/Users\/([^/]+)\/\.vscode\/extensions\/([^/]+)(?:\/.*)?$/);
  if (!m) {
    return { ok: false, error: 'INVALID_EXTENSION_PATH' };
  }
  var user = m[1];
  var leaf = m[2];
  if (!/^[A-Za-z0-9._-]+$/.test(user)) {
    return { ok: false, error: 'INVALID_EXTENSION_PATH' };
  }
  var idPrefix = String(extId).toLowerCase() + '-';
  if (leaf.toLowerCase().indexOf(idPrefix) !== 0) {
    return { ok: false, error: 'EXTENSION_PATH_ID_MISMATCH' };
  }
  return { ok: true, user: user };
}

// Pure decision function: given the currently-installed extensions map (from
// parseInstalledExtensionsList), an already-validated extension id, and an
// already-validated (possibly null/undefined) target version, decides what
// to do. Matching is case-insensitive on the extension id (VS Code ids are
// conventionally lowercase, but this is defensive either way).
//
// Returns exactly one of:
//   { action: 'not_installed' }
//     - extension isn't installed at all: per spec, do nothing (never
//       installs it fresh), regardless of whether a target version was given.
//   { action: 'already_correct_version', installedVersion: targetVersion }
//     - installed and already pinned to the given targetVersion: no-op.
//   { action: 'set_version', installedVersion: '<current>' }
//     - installed at a version other than the given targetVersion: caller
//       should run `code --install-extension <id>@<targetVersion> --force`,
//       which upgrades or downgrades depending on the direction.
//   { action: 'upgrade_to_latest', installedVersion: '<current>' }
//     - no targetVersion was given: caller should run
//       `code --upgrade-extension <id>` (the code CLI resolves "latest"
//       against the marketplace itself - pure offline logic has no way to
//       know what that is) and compare the installed version before/after
//       to determine whether anything actually changed.
function decideVersionAction(installedExtensions, extId, targetVersion) {
  var installed = installedExtensions || {};
  var current = installed[String(extId).toLowerCase()];

  if (current === undefined) {
    return { action: 'not_installed' };
  }
  if (!targetVersion) {
    return { action: 'upgrade_to_latest', installedVersion: current };
  }
  if (current === targetVersion) {
    return { action: 'already_correct_version', installedVersion: current };
  }
  return { action: 'set_version', installedVersion: current };
}

// Pure decision function: given the decision from decideVersionAction, the
// raw result of whatever CLI action was attempted (or null if none was -
// i.e. decision.action was 'not_installed' or 'already_correct_version'),
// the installed version observed via a fresh listing AFTER that action (used
// for change-detection - relevant for 'upgrade_to_latest', where the actual
// resulting version can't be known in advance), and whether this was a dry
// run, computes the final status/changed/error fields for the RTR envelope.
// No I/O - actionResult is whatever the runner already collected.
//
// actionResult shape (or null): { attempted: bool, ok: bool, stderr: string }
//   attempted is false for a dry run (the runner skips the real CLI call).
function computeRunOutcome(decision, actionResult, installedVersionAfter, dryRun) {
  var actionFailed = !!(actionResult && actionResult.attempted && !actionResult.ok);
  var changed = false;

  if (actionResult && actionResult.attempted && actionResult.ok) {
    changed = installedVersionAfter !== decision.installedVersion;
  }

  if (actionFailed) {
    return {
      status: 'failure',
      changed: false,
      error: {
        code:    'EXTENSION_VERSION_CHANGE_FAILED',
        message: 'code --install-extension/--upgrade-extension failed',
        stderr:  actionResult.stderr || '',
      },
    };
  }
  if (decision.action === 'not_installed' || decision.action === 'already_correct_version') {
    return { status: 'skipped', changed: false, error: null };
  }
  if (dryRun) {
    return { status: 'skipped', changed: false, error: null };
  }
  return { status: 'success', changed: changed, error: null };
}

if (typeof module !== 'undefined' && module.exports) {
  module.exports = {
    EXT_ID_RE: EXT_ID_RE,
    VERSION_RE: VERSION_RE,
    validateExtensionId: validateExtensionId,
    validateVersion: validateVersion,
    parseInstalledExtensionsList: parseInstalledExtensionsList,
    parseUserFromExtensionPath: parseUserFromExtensionPath,
    decideVersionAction: decideVersionAction,
    computeRunOutcome: computeRunOutcome,
  };
}

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
function _runCommand(launchPath, args, timeoutSec) {
  var timeout = timeoutSec || DEFAULT_CMD_TIMEOUT_SEC;
  try {
    var task = $.NSTask.alloc.init;
    task.launchPath = launchPath;
    if (args) task.arguments = args;
    var pipe = $.NSPipe.pipe;
    task.standardOutput = pipe;
    task.standardError  = pipe;
    task.launch;

    var pid = task.processIdentifier;
    var killTimer = $.NSTimer.scheduledTimerWithTimeIntervalRepeatsBlock(
      timeout, false, function () {
        try { task.terminate; } catch (_) {}
      }
    );
    var hardKill = $.NSTimer.scheduledTimerWithTimeIntervalRepeatsBlock(
      timeout + SIGKILL_GRACE_SEC, false, function () {
        try { $.kill(pid, 9); } catch (_) {}
      }
    );

    // Read before waitUntilExit: readDataToEndOfFile blocks until the
    // pipe's write end closes (i.e. the child exits), so reading first is
    // safe and avoids the fill-the-buffer-before-anyone-reads deadlock that
    // reading only *after* waitUntilExit would risk.
    var outData = pipe.fileHandleForReading.readDataToEndOfFile;
    task.waitUntilExit;
    if (killTimer.isValid) killTimer.invalidate;
    if (hardKill.isValid)  hardKill.invalidate;

    var out = _dataToString(outData);
    return { exitCode: task.terminationStatus, stdout: out, stderr: out };
  } catch (e) {
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
  var settingsPath = getSettingsPath(uid, user);
  var bypassState = enableSignatureBypass(settingsPath, uid);
  try {
    if (uid === null) {
      var rootArgs = ['HOME=/var/root', VSCODE.codePath].concat(args);
      return _runCommand('/usr/bin/env', rootArgs, timeoutSec);
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
    return _runCommand('/bin/launchctl', fullArgs, timeoutSec);
  } finally {
    restoreSignatureVerification(bypassState);
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
  try { $.kill(pid, sig); } catch (e) { /* best-effort */ }
}

function restartVSCodeIfRunning(uid) {
  if (uid === null) return false;
  if (findRunningVSCodePids(uid).length === 0) return false;

  // See runCode's own comment: `launchctl asuser` alone does not drop this
  // process' credentials, only its Mach bootstrap namespace - layering
  // `sudo -u '#uid'` inside that context is what actually makes these
  // AppleEvents originate as the real target user (matching that user's
  // own previously-granted Automation/TCC permissions) instead of root's.
  _runCommand('/bin/launchctl', ['asuser', String(uid), '/usr/bin/sudo', '-u', '#' + uid, '/usr/bin/osascript', '-e', 'quit app "Visual Studio Code"']);

  var waited = 0;
  while (findRunningVSCodePids(uid).length > 0 && waited < 10) {
    _runCommand('/bin/sleep', ['1']);
    waited++;
  }
  var remaining = findRunningVSCodePids(uid);
  for (var i = 0; i < remaining.length; i++) {
    killPid(parseInt(remaining[i], 10), 9);
  }

  _runCommand('/bin/launchctl', ['asuser', String(uid), '/usr/bin/sudo', '-u', '#' + uid, '/usr/bin/open', '-a', 'Visual Studio Code']);
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

  try {
    var input = null;
    if (argv && argv.length > 0 && argv[0]) {
      var data    = $.NSData.alloc.initWithBase64EncodedStringOptions(argv[0], 0);
      var decoded = $.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding).js;
      input        = JSON.parse(decoded);
      dryRun = castBool(getProp(input, 'dry_run', false), false);
    }
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
    var osMajor = getOSMajorVersion();

    var listResult = listInstalledExtensions(targetUser.uid, targetUser.user);
    if (listResult.exitCode !== 0) {
      throw {
        code: 'LIST_EXTENSIONS_FAILED',
        message: 'code --list-extensions failed: ' + (listResult.stderr || listResult.stdout || '').trim(),
      };
    }
    var installedBefore = parseInstalledExtensionsList(listResult.stdout);
    var decision = decideVersionAction(installedBefore, extId, targetVersion);

    var action = null;
    var installedVersionAfter = decision.installedVersion || null;

    if (decision.action === 'not_installed') {
      // Per spec: never install fresh. Nothing more to do.
    } else if (decision.action === 'already_correct_version') {
      // Idempotent no-op.
    } else if (decision.action === 'set_version') {
      action = setExactVersion(targetUser.uid, targetUser.user, extId, targetVersion, dryRun);
    } else if (decision.action === 'upgrade_to_latest') {
      action = upgradeToLatest(targetUser.uid, targetUser.user, extId, dryRun);
    }

    if (action && action.attempted && action.ok) {
      // Re-list to find out what version we actually ended up at, and
      // whether anything really changed (relevant for upgrade_to_latest,
      // where we couldn't know the target version in advance).
      var listAfter = listInstalledExtensions(targetUser.uid, targetUser.user);
      if (listAfter.exitCode === 0) {
        var installedAfter = parseInstalledExtensionsList(listAfter.stdout);
        installedVersionAfter = installedAfter[extId.toLowerCase()] || null;
      }
    }

    var outcome = computeRunOutcome(decision, action, installedVersionAfter, dryRun);

    var vscodeRestarted = false;
    if (outcome.status === 'success' && outcome.changed && !dryRun) {
      try {
        vscodeRestarted = restartVSCodeIfRunning(targetUser.uid);
      } catch (e) {
        writeDiag('WARN: failed to restart VS Code after version change: ' + e);
      }
    }

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
