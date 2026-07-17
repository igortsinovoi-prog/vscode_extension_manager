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

// resetMocks() always reassigns _runCommand back to standardMockRunCommand,
// so a test can never "leak" a custom override into later tests - it must
// go through mockConfig instead (e.g. listExtensionsStdoutSequence below for
// a call returning something different each time it's invoked).
function resetMocks() {
  mockConfig = {
    idUidByUser: {},
    listExtensionsExitCode: 0,
    listExtensionsStdout: '',
    listExtensionsStdoutSequence: null, // array: nth call gets seq[min(n, len-1)]
    listExtensionsCallIndex: 0,
    installResult: { exitCode: 0, stdout: '', stderr: '' },
    swVersStdout: '14.0',
  };
  commandLog = [];
  _runCommand = standardMockRunCommand;
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

  // The `code` CLI, either wrapped in `launchctl asuser <uid> <codePath> ...`
  // (real target user) or invoked directly as VSCODE.codePath (root fallback).
  var codeArgs = null;
  if (launchPath === '/bin/launchctl' && args[0] === 'asuser') {
    codeArgs = args.slice(3);
  } else if (launchPath === VSCODE.codePath) {
    codeArgs = args;
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

test('runCode: real uid -> wraps the command in launchctl asuser', function () {
  runCode(501, ['--list-extensions', '--show-versions']);
  assertEqual(commandLog.length, 1);
  assertEqual(commandLog[0].launchPath, '/bin/launchctl');
  assertEqual(commandLog[0].args, ['asuser', '501', VSCODE.codePath, '--list-extensions', '--show-versions']);
});

test('runCode: null uid -> runs the code CLI directly (as root), no launchctl', function () {
  runCode(null, ['--list-extensions', '--show-versions']);
  assertEqual(commandLog.length, 1);
  assertEqual(commandLog[0].launchPath, VSCODE.codePath);
  assertEqual(commandLog[0].args, ['--list-extensions', '--show-versions']);
});

// ---------------------------------------------------------------------------
// upgradeToLatest / setExactVersion dry-run gating
// ---------------------------------------------------------------------------

test('upgradeToLatest: dry run does not invoke the CLI at all', function () {
  var result = upgradeToLatest(501, 'ms-python.python', true);
  assertEqual(result, { attempted: false, dry_run: true });
  assertEqual(commandLog.length, 0);
});

test('upgradeToLatest: real run invokes --install-extension id --force (not --upgrade-extension, which is not a real CLI flag) and reports ok on success', function () {
  mockConfig.installResult = { exitCode: 0, stdout: 'done', stderr: '' };
  var result = upgradeToLatest(501, 'ms-python.python', false);
  assertTrue(result.attempted);
  assertTrue(result.ok);
  var call = commandLog[commandLog.length - 1];
  assertEqual(call.args.slice(-3), ['--install-extension', 'ms-python.python', '--force']);
});

test('setExactVersion: real run invokes --install-extension id@version --force', function () {
  mockConfig.installResult = { exitCode: 0, stdout: '', stderr: '' };
  var result = setExactVersion(501, 'ms-python.python', '2024.1.0', false);
  assertTrue(result.ok);
  var call = commandLog[commandLog.length - 1];
  assertEqual(call.args.slice(-3), ['--install-extension', 'ms-python.python@2024.1.0', '--force']);
});

test('setExactVersion: CLI failure is reported as not ok, with stderr captured', function () {
  mockConfig.installResult = { exitCode: 1, stdout: '', stderr: 'network error' };
  var result = setExactVersion(501, 'ms-python.python', '2024.1.0', false);
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
