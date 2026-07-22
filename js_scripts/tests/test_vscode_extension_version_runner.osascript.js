// =====================================================================
// Automated tests for the JXA runner half of set-vscode-extension-version.js
// (vscode-extension-version-runner.js + vscode-extension-version-policy.js).
//
// This file uses ObjC/NSTask (via the runner it loads), so it can't run
// under Node the way the pure policy module's tests do. Run instead via:
//   osascript -l JavaScript js_scripts/tests/test_vscode_extension_version_runner.osascript.js
// (must be run with the project root as the current working directory).
//
// Mocks _runCommand - the single seam ALL OS interaction (id, sw_vers,
// ioreg, launchctl, code) goes through - so no real process is ever
// spawned: deterministic, fast, no dependency on real user accounts or a
// real VS Code install having any particular extensions.
//
// Prints one line per test (PASS/FAIL) and a summary, exits 0 if everything
// passed or 1 if anything failed - run_js_tests.sh checks that exit code.
// =====================================================================

ObjC.import('Foundation');
ObjC.import('stdlib'); // for $.exit

function readFile(path) {
  var s = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null);
  if (!s || s.isNil()) throw new Error('could not read ' + path);
  return s.js;
}

function println(msg) {
  var data = $.NSString.alloc.initWithUTF8String(msg + '\n').dataUsingEncoding($.NSUTF8StringEncoding);
  $.NSFileHandle.fileHandleWithStandardOutput.writeData(data);
}

// ----- Load the module under test into this script's scope -----
eval(readFile('js_scripts/lib/set-vscode-extension-version-policy.js'));
eval(readFile('js_scripts/lib/set-vscode-extension-version-runner.js'));

// ----- Minimal assert/test framework -----

function assertEqual(actual, expected, message) {
  var a = JSON.stringify(actual);
  var e = JSON.stringify(expected);
  if (a !== e) {
    throw new Error((message ? message + ' - ' : '') + 'expected ' + e + ' but got ' + a);
  }
}

function assertTrue(value, message) {
  if (!value) {
    throw new Error((message ? message + ' - ' : '') + 'expected truthy, got ' + JSON.stringify(value));
  }
}

var _testsRun = 0;
var _testsFailed = 0;
var _failureMessages = [];

function test(name, fn) {
  _testsRun++;
  resetMocks();
  try {
    fn();
    println('  ✓ ' + name);
  } catch (e) {
    _testsFailed++;
    var msg = e && e.message ? e.message : String(e);
    _failureMessages.push(name + ': ' + msg);
    println('  ✗ ' + name + ' - ' + msg);
  }
}

// ----- Mock _runCommand: simulates id/sw_vers/ioreg/launchctl/code -----

var mockConfig = {};
var commandLog = [];
var fileWriteLog = [];
var killLog = [];

// resetMocks() always reassigns _runCommand back to standardMockRunCommand,
// so a test can never "leak" a custom override into later tests - it must
// go through mockConfig instead (e.g. listExtensionsStdoutSequence below for
// a call returning something different each time it's invoked).
//
// readFileRaw/writeFileRaw are also mocked here (default: no settings.json
// exists, writes are no-ops but logged) so runCode()'s signature-bypass
// enable/restore dance never touches the real filesystem during tests -
// same "no real process, no real file I/O" philosophy as _runCommand.
function resetMocks() {
  mockConfig = {
    idUidByUser: {},
    listExtensionsExitCode: 0,
    listExtensionsStdout: '',
    listExtensionsStdoutSequence: null, // array: nth call gets seq[min(n, len-1)]
    listExtensionsCallIndex: 0,
    installResult: { exitCode: 0, stdout: '', stderr: '' },
    swVersStdout: '14.0',
    settingsFileExists: false,
    settingsRaw: null,
    // Whether VS Code appears "running" (via ps -u <uid>) each time
    // restartVSCodeIfRunning checks - an array so a test can simulate it
    // being up before the quit attempt, then down after (see
    // findRunningVSCodePids call sites: once before quitting at all,
    // then repeatedly in the wait loop).
    vscodeRunningSequence: [false],
    psCallIndex: 0,
  };
  commandLog = [];
  fileWriteLog = [];
  killLog = [];
  _runCommand = standardMockRunCommand;
  killPid = function (pid, sig) { killLog.push({ pid: pid, sig: sig }); };
  fileExists = function (path) {
    if (path === VSCODE.codePath) return true;
    if (path.indexOf('settings.json') !== -1) return mockConfig.settingsFileExists;
    return false;
  };
  readFileRaw = function (path) {
    return mockConfig.settingsFileExists ? mockConfig.settingsRaw : null;
  };
  writeFileRaw = function (path, content) {
    fileWriteLog.push({ path: path, content: content });
  };
  removeFile = function (path) {
    fileWriteLog.push({ path: path, content: null });
  };
}

function standardMockRunCommand(launchPath, args, timeoutSec) {
  args = args || [];
  commandLog.push({ launchPath: launchPath, args: args.slice(), timeoutSec: timeoutSec });

  if (launchPath === '/usr/bin/id' && args[0] === '-u') {
    var user = args[1];
    var uid = mockConfig.idUidByUser[user];
    if (uid === undefined) {
      return { exitCode: 1, stdout: '', stderr: 'id: ' + user + ': no such user' };
    }
    return { exitCode: 0, stdout: String(uid) + '\n', stderr: '' };
  }

  if (launchPath === '/usr/bin/sw_vers') {
    return { exitCode: 0, stdout: mockConfig.swVersStdout + '\n', stderr: '' };
  }

  if (launchPath === '/usr/sbin/ioreg') {
    return { exitCode: 0, stdout: '', stderr: '' };
  }

  // The `code` CLI, either wrapped in `launchctl asuser <uid> sudo -H -u
  // '#<uid>' <codePath> ...` (real target user - launchctl asuser alone only
  // attaches the Mach bootstrap namespace, per `man launchctl`, so `sudo -u`
  // is what actually drops credentials to that uid) or `env HOME=/var/root
  // <codePath> ...` (root fallback). Checks args[6] (the actual target
  // binary past the asuser+sudo prefix) so this doesn't also swallow the
  // restart helpers' own `launchctl asuser <uid> sudo -u ... osascript|open
  // ...` calls below, which need their own mocks.
  var codeArgs = null;
  if (launchPath === '/bin/launchctl' && args[0] === 'asuser' && args[2] === '/usr/bin/sudo' && args[6] === VSCODE.codePath) {
    codeArgs = args.slice(7);
  } else if (launchPath === '/usr/bin/env' && args[1] === VSCODE.codePath) {
    codeArgs = args.slice(2);
  }

  if (codeArgs) {
    if (codeArgs.indexOf('--list-extensions') !== -1) {
      var stdout = mockConfig.listExtensionsStdout;
      if (mockConfig.listExtensionsStdoutSequence) {
        var seq = mockConfig.listExtensionsStdoutSequence;
        var idx = Math.min(mockConfig.listExtensionsCallIndex, seq.length - 1);
        stdout = seq[idx];
        mockConfig.listExtensionsCallIndex++;
      }
      return { exitCode: mockConfig.listExtensionsExitCode, stdout: stdout, stderr: '' };
    }
    if (codeArgs.indexOf('--install-extension') !== -1 || codeArgs.indexOf('--upgrade-extension') !== -1) {
      return mockConfig.installResult;
    }
  }

  // restartVSCodeIfRunning's own commands: `ps -u <uid> -o pid=,comm=` to
  // check whether VS Code is running, then (if so) `launchctl asuser <uid>
  // osascript -e 'quit ...'`, a poll loop of `sleep 1`, and finally
  // `launchctl asuser <uid> open -a 'Visual Studio Code'`.
  if (launchPath === '/bin/ps' && args[0] === '-u') {
    var seq = mockConfig.vscodeRunningSequence || [false];
    var idx2 = Math.min(mockConfig.psCallIndex, seq.length - 1);
    var running = seq[idx2];
    mockConfig.psCallIndex++;
    return {
      exitCode: 0,
      stdout: running ? '12345 /Applications/Visual Studio Code.app/Contents/MacOS/Code\n' : '',
      stderr: '',
    };
  }
  if (launchPath === '/bin/launchctl' && args[0] === 'asuser' && args[2] === '/usr/bin/sudo' && args[5] === '/usr/bin/osascript') {
    return { exitCode: 0, stdout: '', stderr: '' };
  }
  if (launchPath === '/bin/launchctl' && args[0] === 'asuser' && args[2] === '/usr/bin/sudo' && args[5] === '/usr/bin/open') {
    return { exitCode: 0, stdout: '', stderr: '' };
  }
  if (launchPath === '/bin/sleep') {
    return { exitCode: 0, stdout: '', stderr: '' };
  }

  return { exitCode: 1, stdout: '', stderr: 'unmocked command: ' + launchPath + ' ' + args.join(' ') };
};

function makeArgv(paramsObj, dryRun) {
  var payload = JSON.stringify({ params: paramsObj, dry_run: dryRun !== false });
  var nsStr = $.NSString.alloc.initWithUTF8String(payload);
  var b64 = nsStr.dataUsingEncoding($.NSUTF8StringEncoding).base64EncodedStringWithOptions(0).js;
  return [b64];
}

var JDOE_PATH = '/Users/jdoe/.vscode/extensions/ms-python.python-2024.1.0';

// ---------------------------------------------------------------------------
// resolveTargetUser
// ---------------------------------------------------------------------------

test('resolveTargetUser: real account -> resolves uid, no resolution_note', function () {
  mockConfig.idUidByUser.jdoe = 501;
  var result = resolveTargetUser(JDOE_PATH, 'ms-python.python');
  assertEqual(result, { user: 'jdoe', uid: 501, resolution_note: null });
});

test('resolveTargetUser: parsed user has no account -> uid null, user kept, note set', function () {
  var result = resolveTargetUser(JDOE_PATH, 'ms-python.python'); // idUidByUser left empty
  assertEqual(result.user, 'jdoe');
  assertEqual(result.uid, null);
  assertEqual(result.resolution_note, 'EXTENSION_PATH_USER_NOT_FOUND');
});

test('resolveTargetUser: missing path -> user null, uid null, never throws', function () {
  var result = resolveTargetUser(null, 'ms-python.python');
  assertEqual(result, { user: null, uid: null, resolution_note: 'MISSING_EXTENSION_PATH' });
});

test('resolveTargetUser: malformed path -> user null, uid null', function () {
  var result = resolveTargetUser('/not/a/valid/path', 'ms-python.python');
  assertEqual(result.user, null);
  assertEqual(result.uid, null);
  assertEqual(result.resolution_note, 'INVALID_EXTENSION_PATH');
});

test('resolveTargetUser: extension id mismatch -> user null, uid null', function () {
  var path = '/Users/jdoe/.vscode/extensions/some-other.extension-1.0.0';
  var result = resolveTargetUser(path, 'ms-python.python');
  assertEqual(result.user, null);
  assertEqual(result.uid, null);
  assertEqual(result.resolution_note, 'EXTENSION_PATH_ID_MISMATCH');
});

test('resolveTargetUser: id -u is looked up for the parsed user, not a fixed value', function () {
  mockConfig.idUidByUser.jdoe = 777;
  var result = resolveTargetUser(JDOE_PATH, 'ms-python.python');
  assertEqual(result.uid, 777);
  var idCalls = commandLog.filter(function (c) { return c.launchPath === '/usr/bin/id'; });
  assertEqual(idCalls.length, 1);
  assertEqual(idCalls[0].args, ['-u', 'jdoe']);
});

// ---------------------------------------------------------------------------
// runCode dispatch
// ---------------------------------------------------------------------------

test('runCode: real uid -> wraps the command in launchctl asuser, dropping credentials via sudo -u', function () {
  runCode(501, 'jdoe', ['--list-extensions', '--show-versions']);
  assertEqual(commandLog.length, 1);
  assertEqual(commandLog[0].launchPath, '/bin/launchctl');
  assertEqual(commandLog[0].args, ['asuser', '501', '/usr/bin/sudo', '-H', '-u', '#501', VSCODE.codePath, '--list-extensions', '--show-versions']);
});

test('runCode: null uid -> runs the code CLI as root via env HOME=/var/root, no launchctl', function () {
  runCode(null, null, ['--list-extensions', '--show-versions']);
  assertEqual(commandLog.length, 1);
  assertEqual(commandLog[0].launchPath, '/usr/bin/env');
  assertEqual(commandLog[0].args, ['HOME=/var/root', VSCODE.codePath, '--list-extensions', '--show-versions']);
});

test('runCode: brackets the call with the signature-verification bypass, enabling then restoring', function () {
  mockConfig.settingsFileExists = true;
  mockConfig.settingsRaw = '{"foo":"bar"}';
  runCode(501, 'jdoe', ['--list-extensions']);
  // One write to apply the bypass, one to restore - the restore must be
  // the exact original raw text, not the bypassed version.
  assertEqual(fileWriteLog.length, 2);
  assertEqual(fileWriteLog[0].path, '/Users/jdoe/Library/Application Support/Code/User/settings.json');
  assertTrue(JSON.parse(fileWriteLog[0].content)['extensions.verifySignature'] === false);
  assertEqual(fileWriteLog[1].content, '{"foo":"bar"}');
});

test('runCode: uses root\'s own settings.json when uid is null, never a real user\'s', function () {
  runCode(null, null, ['--list-extensions']);
  assertEqual(fileWriteLog[0].path, '/var/root/Library/Application Support/Code/User/settings.json');
});

// ---------------------------------------------------------------------------
// getSettingsPath / enableSignatureBypass / restoreSignatureVerification
// ---------------------------------------------------------------------------

test('getSettingsPath: real uid -> that user\'s own settings.json', function () {
  assertEqual(getSettingsPath(501, 'jdoe'), '/Users/jdoe/Library/Application Support/Code/User/settings.json');
});

test('getSettingsPath: null uid -> root\'s own settings.json regardless of user', function () {
  assertEqual(getSettingsPath(null, 'jdoe'), '/var/root/Library/Application Support/Code/User/settings.json');
});

test('enableSignatureBypass: no existing settings.json -> creates one with verifySignature false, restore deletes it', function () {
  mockConfig.settingsFileExists = false;
  var path = '/Users/jdoe/Library/Application Support/Code/User/settings.json';
  var state = enableSignatureBypass(path);
  assertTrue(state.applied);
  assertEqual(state.fileExisted, false);
  assertEqual(JSON.parse(fileWriteLog[0].content)['extensions.verifySignature'], false);

  restoreSignatureVerification(state);
  assertEqual(fileWriteLog.length, 2);
  assertEqual(fileWriteLog[1].content, null); // removeFile logs content: null
});

test('enableSignatureBypass: existing settings.json -> preserves other keys, restore writes back the exact original raw text', function () {
  mockConfig.settingsFileExists = true;
  mockConfig.settingsRaw = '{"editor.fontSize":14}';
  var path = '/Users/jdoe/Library/Application Support/Code/User/settings.json';
  var state = enableSignatureBypass(path);
  assertEqual(state.fileExisted, true);
  assertEqual(state.originalRaw, '{"editor.fontSize":14}');
  var written = JSON.parse(fileWriteLog[0].content);
  assertEqual(written['editor.fontSize'], 14);
  assertEqual(written['extensions.verifySignature'], false);

  restoreSignatureVerification(state);
  assertEqual(fileWriteLog[1].content, '{"editor.fontSize":14}');
});

test('enableSignatureBypass: unparseable existing settings.json -> does not apply, does not touch the file', function () {
  mockConfig.settingsFileExists = true;
  mockConfig.settingsRaw = 'not valid json {';
  var state = enableSignatureBypass('/Users/jdoe/Library/Application Support/Code/User/settings.json');
  assertEqual(state.applied, false);
  assertEqual(fileWriteLog.length, 0);
});

// ---------------------------------------------------------------------------
// findRunningVSCodePids / restartVSCodeIfRunning
// ---------------------------------------------------------------------------

test('findRunningVSCodePids: VS Code running -> returns its pid', function () {
  mockConfig.vscodeRunningSequence = [true];
  assertEqual(findRunningVSCodePids(501), ['12345']);
});

test('findRunningVSCodePids: VS Code not running -> empty', function () {
  mockConfig.vscodeRunningSequence = [false];
  assertEqual(findRunningVSCodePids(501), []);
});

test('restartVSCodeIfRunning: null uid (root fallback) -> never attempts anything, returns false', function () {
  var result = restartVSCodeIfRunning(null);
  assertEqual(result, false);
  assertEqual(commandLog.length, 0);
});

test('restartVSCodeIfRunning: not running -> no quit/relaunch attempted, returns false', function () {
  mockConfig.vscodeRunningSequence = [false];
  var result = restartVSCodeIfRunning(501);
  assertEqual(result, false);
  var quitCalls = commandLog.filter(function (c) {
    return c.launchPath === '/bin/launchctl' && c.args[2] === '/usr/bin/sudo' && c.args[5] === '/usr/bin/osascript';
  });
  assertEqual(quitCalls.length, 0);
});

test('restartVSCodeIfRunning: running, quits promptly -> quits then relaunches as the same user, no force-kill', function () {
  // [true, false]: running when first checked, gone by the very next
  // check inside the wait loop - the graceful quit alone was enough.
  mockConfig.vscodeRunningSequence = [true, false];
  var result = restartVSCodeIfRunning(501);
  assertEqual(result, true);

  var quitCall = commandLog.filter(function (c) {
    return c.launchPath === '/bin/launchctl' && c.args[2] === '/usr/bin/sudo' && c.args[5] === '/usr/bin/osascript';
  });
  assertEqual(quitCall.length, 1);
  assertEqual(quitCall[0].args[1], String(501));
  assertEqual(quitCall[0].args[4], '#501'); // sudo -u '#uid' - real credentials, not just the bootstrap namespace

  var openCall = commandLog.filter(function (c) {
    return c.launchPath === '/bin/launchctl' && c.args[2] === '/usr/bin/sudo' && c.args[5] === '/usr/bin/open';
  });
  assertEqual(openCall.length, 1);
  assertEqual(openCall[0].args[1], String(501));
  assertEqual(openCall[0].args.slice(6), ['-a', 'Visual Studio Code']);
});

test('restartVSCodeIfRunning: still running after the wait loop -> force-kills by pid, then relaunches anyway', function () {
  // Every check in the 10s wait loop still reports "running" - falls
  // back to killPid (mocked here, not the real $.kill - see killPid's
  // own comment for why that indirection exists), then still relaunches.
  mockConfig.vscodeRunningSequence = [true];
  var result = restartVSCodeIfRunning(501);
  assertEqual(result, true);
  assertEqual(killLog, [{ pid: 12345, sig: 9 }]);
  var openCall = commandLog.filter(function (c) {
    return c.launchPath === '/bin/launchctl' && c.args[2] === '/usr/bin/sudo' && c.args[5] === '/usr/bin/open';
  });
  assertEqual(openCall.length, 1);
});

// ---------------------------------------------------------------------------
// upgradeToLatest / setExactVersion dry-run gating
// ---------------------------------------------------------------------------

test('upgradeToLatest: dry run does not invoke the CLI at all', function () {
  var result = upgradeToLatest(501, 'jdoe', 'ms-python.python', true);
  assertEqual(result, { attempted: false, dry_run: true });
  assertEqual(commandLog.length, 0);
});

test('upgradeToLatest: real run invokes --install-extension id --force (not --upgrade-extension, which is not a real CLI flag) and reports ok on success', function () {
  mockConfig.installResult = { exitCode: 0, stdout: 'done', stderr: '' };
  var result = upgradeToLatest(501, 'jdoe', 'ms-python.python', false);
  assertTrue(result.attempted);
  assertTrue(result.ok);
  var call = commandLog[commandLog.length - 1];
  assertEqual(call.args.slice(-3), ['--install-extension', 'ms-python.python', '--force']);
});

test('setExactVersion: real run invokes --install-extension id@version --force', function () {
  mockConfig.installResult = { exitCode: 0, stdout: '', stderr: '' };
  var result = setExactVersion(501, 'jdoe', 'ms-python.python', '2024.1.0', false);
  assertTrue(result.ok);
  var call = commandLog[commandLog.length - 1];
  assertEqual(call.args.slice(-3), ['--install-extension', 'ms-python.python@2024.1.0', '--force']);
});

test('setExactVersion: CLI failure is reported as not ok, with stderr captured', function () {
  mockConfig.installResult = { exitCode: 1, stdout: '', stderr: 'network error' };
  var result = setExactVersion(501, 'jdoe', 'ms-python.python', '2024.1.0', false);
  assertEqual(result.ok, false);
  assertEqual(result.stderr, 'network error');
});

// ---------------------------------------------------------------------------
// run(argv) end-to-end (mocked _runCommand; fileExists temporarily overridden
// where needed so this doesn't depend on VS Code actually being installed)
// ---------------------------------------------------------------------------

function withFileExists(fn, testFn) {
  var original = fileExists;
  fileExists = fn;
  try {
    testFn();
  } finally {
    fileExists = original;
  }
}

test('run(): invalid extension_id -> failure envelope, INVALID_PARAMS', function () {
  var result = JSON.parse(run(makeArgv({ extension_id: 'not-an-id' }, true)));
  assertEqual(result.status, 'failure');
  assertEqual(result.error.code, 'INVALID_PARAMS');
});

test('run(): invalid version -> failure envelope, INVALID_PARAMS', function () {
  var result = JSON.parse(run(makeArgv({ extension_id: 'ms-python.python', version: 'not-semver' }, true)));
  assertEqual(result.status, 'failure');
  assertEqual(result.error.code, 'INVALID_PARAMS');
});

test('run(): VS Code not installed -> failure envelope, VSCODE_NOT_INSTALLED', function () {
  withFileExists(function () { return false; }, function () {
    var result = JSON.parse(run(makeArgv({ extension_id: 'ms-python.python', extension_path: JDOE_PATH }, true)));
    assertEqual(result.status, 'failure');
    assertEqual(result.error.code, 'VSCODE_NOT_INSTALLED');
  });
});

test('run(): code --list-extensions itself fails -> failure envelope, LIST_EXTENSIONS_FAILED', function () {
  withFileExists(function () { return true; }, function () {
    mockConfig.idUidByUser.jdoe = 501;
    mockConfig.listExtensionsExitCode = 1;
    var result = JSON.parse(run(makeArgv(
      { extension_id: 'ms-python.python', version: '2024.1.0', extension_path: JDOE_PATH }, true,
    )));
    assertEqual(result.status, 'failure');
    assertEqual(result.error.code, 'LIST_EXTENSIONS_FAILED');
  });
});

test('run(): extension not installed -> skipped, no CLI action taken', function () {
  withFileExists(function () { return true; }, function () {
    mockConfig.idUidByUser.jdoe = 501;
    mockConfig.listExtensionsStdout = 'some-other.extension@1.0.0\n';
    var result = JSON.parse(run(makeArgv(
      { extension_id: 'ms-python.python', version: '2024.1.0', extension_path: JDOE_PATH }, true,
    )));
    assertEqual(result.status, 'skipped');
    assertEqual(result.changed, false);
    assertEqual(result.action, 'not_installed');
    assertEqual(result.cli_result, null);
  });
});

test('run(): already at the target version -> skipped, no CLI action taken', function () {
  withFileExists(function () { return true; }, function () {
    mockConfig.idUidByUser.jdoe = 501;
    mockConfig.listExtensionsStdout = 'ms-python.python@2024.1.0\n';
    var result = JSON.parse(run(makeArgv(
      { extension_id: 'ms-python.python', version: '2024.1.0', extension_path: JDOE_PATH }, true,
    )));
    assertEqual(result.status, 'skipped');
    assertEqual(result.action, 'already_correct_version');
  });
});

test('run(): differing version, real run -> success, changed, version pin invoked', function () {
  withFileExists(function () { return true; }, function () {
    mockConfig.idUidByUser.jdoe = 501;
    // First --list-extensions call (before the install) sees the old
    // version; the second (after) sees the new one.
    mockConfig.listExtensionsStdoutSequence = [
      'ms-python.python@2024.1.0\n',
      'ms-python.python@2024.5.0\n',
    ];
    mockConfig.installResult = { exitCode: 0, stdout: '', stderr: '' };

    var result = JSON.parse(run(makeArgv(
      { extension_id: 'ms-python.python', version: '2024.5.0', extension_path: JDOE_PATH }, false,
    )));
    assertEqual(result.status, 'success');
    assertEqual(result.changed, true);
    assertEqual(result.action, 'set_version');
    assertEqual(result.installed_version_before, '2024.1.0');
    assertEqual(result.installed_version_after, '2024.5.0');
    assertTrue(result.cli_result.ok);
    // VS Code isn't "running" per the default mock (vscodeRunningSequence:
    // [false]) - nothing to restart, so this must stay false.
    assertEqual(result.vscode_restarted, false);
  });
});

test('run(): differing version, real run, VS Code already running -> restarts it, reports vscode_restarted true', function () {
  withFileExists(function () { return true; }, function () {
    mockConfig.idUidByUser.jdoe = 501;
    mockConfig.listExtensionsStdoutSequence = [
      'ms-python.python@2024.1.0\n',
      'ms-python.python@2024.5.0\n',
    ];
    mockConfig.installResult = { exitCode: 0, stdout: '', stderr: '' };
    mockConfig.vscodeRunningSequence = [true, false];

    var result = JSON.parse(run(makeArgv(
      { extension_id: 'ms-python.python', version: '2024.5.0', extension_path: JDOE_PATH }, false,
    )));
    assertEqual(result.status, 'success');
    assertEqual(result.changed, true);
    assertEqual(result.vscode_restarted, true);

    var quitCall = commandLog.filter(function (c) {
      return c.launchPath === '/bin/launchctl' && c.args[2] === '/usr/bin/sudo' && c.args[5] === '/usr/bin/osascript';
    });
    assertEqual(quitCall.length, 1);
    assertEqual(quitCall[0].args[1], '501');
  });
});

test('run(): already at the target version (no change) -> never attempts a restart even if VS Code is running', function () {
  withFileExists(function () { return true; }, function () {
    mockConfig.idUidByUser.jdoe = 501;
    mockConfig.listExtensionsStdout = 'ms-python.python@2024.1.0\n';
    mockConfig.vscodeRunningSequence = [true];
    var result = JSON.parse(run(makeArgv(
      { extension_id: 'ms-python.python', version: '2024.1.0', extension_path: JDOE_PATH }, false,
    )));
    assertEqual(result.status, 'skipped');
    assertEqual(result.vscode_restarted, false);
    var quitCall = commandLog.filter(function (c) {
      return c.launchPath === '/bin/launchctl' && c.args[2] === '/usr/bin/sudo' && c.args[5] === '/usr/bin/osascript';
    });
    assertEqual(quitCall.length, 0);
  });
});

test('run(): dry run with a pending change -> never attempts a restart even if VS Code is running', function () {
  withFileExists(function () { return true; }, function () {
    mockConfig.idUidByUser.jdoe = 501;
    mockConfig.listExtensionsStdout = 'ms-python.python@2024.1.0\n';
    mockConfig.vscodeRunningSequence = [true];
    var result = JSON.parse(run(makeArgv(
      { extension_id: 'ms-python.python', version: '2024.5.0', extension_path: JDOE_PATH }, true,
    )));
    assertEqual(result.status, 'skipped');
    assertEqual(result.dry_run, true);
    assertEqual(result.vscode_restarted, false);
    var quitCall = commandLog.filter(function (c) {
      return c.launchPath === '/bin/launchctl' && c.args[2] === '/usr/bin/sudo' && c.args[5] === '/usr/bin/osascript';
    });
    assertEqual(quitCall.length, 0);
  });
});

test('run(): differing version, CLI install fails -> failure envelope', function () {
  withFileExists(function () { return true; }, function () {
    mockConfig.idUidByUser.jdoe = 501;
    mockConfig.listExtensionsStdout = 'ms-python.python@2024.1.0\n';
    mockConfig.installResult = { exitCode: 1, stdout: '', stderr: 'boom' };
    var result = JSON.parse(run(makeArgv(
      { extension_id: 'ms-python.python', version: '2024.5.0', extension_path: JDOE_PATH }, false,
    )));
    assertEqual(result.status, 'failure');
    assertEqual(result.error.code, 'EXTENSION_VERSION_CHANGE_FAILED');
    assertEqual(result.error.stderr, 'boom');
  });
});

test('run(): dry run with a pending version change -> skipped, no CLI action attempted', function () {
  withFileExists(function () { return true; }, function () {
    mockConfig.idUidByUser.jdoe = 501;
    mockConfig.listExtensionsStdout = 'ms-python.python@2024.1.0\n';
    var result = JSON.parse(run(makeArgv(
      { extension_id: 'ms-python.python', version: '2024.5.0', extension_path: JDOE_PATH }, true,
    )));
    assertEqual(result.status, 'skipped');
    assertEqual(result.changed, false);
    assertEqual(result.cli_result, { attempted: false, dry_run: true });
  });
});

test('run(): no version given, extension already latest -> success, not changed', function () {
  withFileExists(function () { return true; }, function () {
    mockConfig.idUidByUser.jdoe = 501;
    mockConfig.listExtensionsStdout = 'ms-python.python@2024.9.0\n'; // same before and after
    mockConfig.installResult = { exitCode: 0, stdout: '', stderr: '' };
    var result = JSON.parse(run(makeArgv(
      { extension_id: 'ms-python.python', extension_path: JDOE_PATH }, false,
    )));
    assertEqual(result.action, 'upgrade_to_latest');
    assertEqual(result.status, 'success');
    assertEqual(result.changed, false);
  });
});

test('run(): extension_path names a user with no account -> still proceeds, ran_as_root true', function () {
  withFileExists(function () { return true; }, function () {
    // idUidByUser left empty on purpose - "jdoe" has no resolvable account.
    mockConfig.listExtensionsStdout = 'ms-python.python@2024.1.0\n';
    var result = JSON.parse(run(makeArgv(
      { extension_id: 'ms-python.python', version: '2024.1.0', extension_path: JDOE_PATH }, true,
    )));
    assertEqual(result.target_user, 'jdoe');
    assertEqual(result.ran_as_root, true);
    assertEqual(result.user_resolution_note, 'EXTENSION_PATH_USER_NOT_FOUND');
    // And the code CLI was invoked directly (root), not via launchctl asuser.
    var launchctlCalls = commandLog.filter(function (c) { return c.launchPath === '/bin/launchctl'; });
    assertEqual(launchctlCalls.length, 0);
  });
});

test('run(): missing extension_path -> still proceeds (runs as root), never aborts', function () {
  withFileExists(function () { return true; }, function () {
    mockConfig.listExtensionsStdout = 'ms-python.python@2024.1.0\n';
    var result = JSON.parse(run(makeArgv(
      { extension_id: 'ms-python.python', version: '2024.1.0' }, true,
    )));
    assertEqual(result.target_user, null);
    assertEqual(result.ran_as_root, true);
    assertEqual(result.status, 'skipped'); // already at 2024.1.0
  });
});

// ---------------------------------------------------------------------------
// Summary
// ---------------------------------------------------------------------------

println('');
println(_testsRun + ' tests, ' + (_testsRun - _testsFailed) + ' passed, ' + _testsFailed + ' failed');
if (_testsFailed > 0) {
  println('');
  println('Failures:');
  _failureMessages.forEach(function (m) { println('  - ' + m); });
  $.exit(1);
}
$.exit(0);
