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
function runCode(uid, args, timeoutSec) {
  if (uid === null) {
    var rootArgs = ['HOME=/var/root', VSCODE.codePath].concat(args);
    return _runCommand('/usr/bin/env', rootArgs, timeoutSec);
  }
  var fullArgs = ['asuser', String(uid), VSCODE.codePath].concat(args);
  return _runCommand('/bin/launchctl', fullArgs, timeoutSec);
}

// ===== Section 5: Extension Version Actions =====

function listInstalledExtensions(uid) {
  return runCode(uid, ['--list-extensions', '--show-versions']);
}

function upgradeToLatest(uid, extId, dryRun) {
  if (dryRun) return { attempted: false, dry_run: true };
  // `code --upgrade-extension <id>` is NOT a real flag on this CLI (verified
  // against VS Code 1.127.0: it silently no-ops with exit code 0 while
  // Electron prints "not in the list of known options" to stderr) - installs
  // an extension by id with no @version and --force correctly resolves and
  // installs latest instead.
  var r = runCode(uid, ['--install-extension', extId, '--force'], INSTALL_CMD_TIMEOUT_SEC);
  return {
    attempted: true,
    exit_code: r.exitCode,
    ok: r.exitCode === 0,
    stdout: (r.stdout || '').trim(),
    stderr: (r.stderr || '').trim(),
  };
}

function setExactVersion(uid, extId, version, dryRun) {
  if (dryRun) return { attempted: false, dry_run: true };
  var r = runCode(
    uid, ['--install-extension', extId + '@' + version, '--force'], INSTALL_CMD_TIMEOUT_SEC,
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

    var listResult = listInstalledExtensions(targetUser.uid);
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
      action = setExactVersion(targetUser.uid, extId, targetVersion, dryRun);
    } else if (decision.action === 'upgrade_to_latest') {
      action = upgradeToLatest(targetUser.uid, extId, dryRun);
    }

    if (action && action.attempted && action.ok) {
      // Re-list to find out what version we actually ended up at, and
      // whether anything really changed (relevant for upgrade_to_latest,
      // where we couldn't know the target version in advance).
      var listAfter = listInstalledExtensions(targetUser.uid);
      if (listAfter.exitCode === 0) {
        var installedAfter = parseInstalledExtensionsList(listAfter.stdout);
        installedVersionAfter = installedAfter[extId.toLowerCase()] || null;
      }
    }

    var outcome = computeRunOutcome(decision, action, installedVersionAfter, dryRun);

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
