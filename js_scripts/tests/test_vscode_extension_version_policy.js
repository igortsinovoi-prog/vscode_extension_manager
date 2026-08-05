'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  EXT_ID_RE,
  VERSION_RE,
  validateExtensionId,
  validateVersion,
  parseInstalledExtensionsList,
  parseUserFromExtensionPath,
  decideVersionAction,
  computeRunOutcome,
} = require('../lib/set-vscode-extension-version-policy.js');

// ---------------------------------------------------------------------------
// exported regexes
// ---------------------------------------------------------------------------

test('EXT_ID_RE and VERSION_RE are exported as RegExp', () => {
  assert.ok(EXT_ID_RE instanceof RegExp);
  assert.ok(VERSION_RE instanceof RegExp);
});

// ---------------------------------------------------------------------------
// validateExtensionId
// ---------------------------------------------------------------------------

test('validateExtensionId accepts well-formed publisher.name ids', () => {
  assert.equal(validateExtensionId('ms-python.python'), true);
  assert.equal(validateExtensionId('GitHub.copilot'), true);
});

test('validateExtensionId rejects malformed or non-string ids', () => {
  assert.equal(validateExtensionId(''), false);
  assert.equal(validateExtensionId('noDotAtAll'), false);
  assert.equal(validateExtensionId(null), false);
  assert.equal(validateExtensionId(undefined), false);
  assert.equal(validateExtensionId(123), false);
});

// ---------------------------------------------------------------------------
// validateVersion
// ---------------------------------------------------------------------------

test('validateVersion treats null/undefined as valid (means "latest")', () => {
  assert.equal(validateVersion(null), true);
  assert.equal(validateVersion(undefined), true);
});

test('validateVersion accepts semver, including pre-release/build suffixes', () => {
  assert.equal(validateVersion('1.2.3'), true);
  assert.equal(validateVersion('1.2.3-beta.1'), true);
  assert.equal(validateVersion('1.2.3+build.5'), true);
});

test('validateVersion rejects malformed version strings', () => {
  assert.equal(validateVersion('1.2'), false);
  assert.equal(validateVersion('abc'), false);
  assert.equal(validateVersion(''), false);
});

test('validateVersion rejects non-string, non-null/undefined input', () => {
  assert.equal(validateVersion(123), false);
  assert.equal(validateVersion({}), false);
});

// ---------------------------------------------------------------------------
// parseInstalledExtensionsList
// ---------------------------------------------------------------------------

test('parseInstalledExtensionsList parses one id@version per line', () => {
  const raw = 'ms-python.python@2024.1.0\nGitHub.copilot@1.150.0\n';
  assert.deepEqual(parseInstalledExtensionsList(raw), {
    'ms-python.python': '2024.1.0',
    'github.copilot': '1.150.0',
  });
});

test('parseInstalledExtensionsList lowercases ids for case-insensitive lookup', () => {
  const result = parseInstalledExtensionsList('GitHub.Copilot@1.0.0');
  assert.deepEqual(result, { 'github.copilot': '1.0.0' });
});

test('parseInstalledExtensionsList handles CRLF line endings and blank lines', () => {
  const raw = 'ms-python.python@2024.1.0\r\n\r\nGitHub.copilot@1.150.0\r\n';
  assert.deepEqual(parseInstalledExtensionsList(raw), {
    'ms-python.python': '2024.1.0',
    'github.copilot': '1.150.0',
  });
});

test('parseInstalledExtensionsList ignores malformed lines', () => {
  const raw = [
    'not-a-valid-line-at-all',
    '@missing-id',
    'missing-version@',
    'bad_id.format@1.0.0',
    'ms-python.python@not-a-version',
    'ms-python.python@2024.1.0', // the one valid line
  ].join('\n');
  assert.deepEqual(parseInstalledExtensionsList(raw), {
    'ms-python.python': '2024.1.0',
  });
});

test('parseInstalledExtensionsList returns an empty object for non-string input', () => {
  assert.deepEqual(parseInstalledExtensionsList(null), {});
  assert.deepEqual(parseInstalledExtensionsList(undefined), {});
  assert.deepEqual(parseInstalledExtensionsList(123), {});
});

test('parseInstalledExtensionsList returns an empty object for empty output', () => {
  assert.deepEqual(parseInstalledExtensionsList(''), {});
});

// ---------------------------------------------------------------------------
// parseUserFromExtensionPath
// ---------------------------------------------------------------------------

test('parseUserFromExtensionPath extracts the user from a well-formed extension dir path', () => {
  const result = parseUserFromExtensionPath(
    '/Users/jdoe/.vscode/extensions/ms-python.python-2024.1.0',
    'ms-python.python',
  );
  assert.deepEqual(result, { ok: true, user: 'jdoe' });
});

test('parseUserFromExtensionPath accepts a path to a file within the extension dir', () => {
  const result = parseUserFromExtensionPath(
    '/Users/jdoe/.vscode/extensions/ms-python.python-2024.1.0/package.json',
    'ms-python.python',
  );
  assert.deepEqual(result, { ok: true, user: 'jdoe' });
});

test('parseUserFromExtensionPath matches the extension id case-insensitively', () => {
  const result = parseUserFromExtensionPath(
    '/Users/jdoe/.vscode/extensions/MS-Python.Python-2024.1.0',
    'ms-python.python',
  );
  assert.deepEqual(result, { ok: true, user: 'jdoe' });
});

test('parseUserFromExtensionPath rejects a missing path', () => {
  assert.deepEqual(
    parseUserFromExtensionPath(null, 'ms-python.python'),
    { ok: false, error: 'MISSING_EXTENSION_PATH' },
  );
  assert.deepEqual(
    parseUserFromExtensionPath('', 'ms-python.python'),
    { ok: false, error: 'MISSING_EXTENSION_PATH' },
  );
});

test('parseUserFromExtensionPath rejects path traversal and control characters', () => {
  assert.deepEqual(
    parseUserFromExtensionPath(
      '/Users/jdoe/.vscode/extensions/../../etc/passwd', 'ms-python.python',
    ),
    { ok: false, error: 'INVALID_EXTENSION_PATH' },
  );
  assert.deepEqual(
    parseUserFromExtensionPath(
      '/Users/jdoe/.vscode/extensions/ms-python.python-1.0.0\x00', 'ms-python.python',
    ),
    { ok: false, error: 'INVALID_EXTENSION_PATH' },
  );
});

test('parseUserFromExtensionPath rejects paths outside the expected shape', () => {
  assert.deepEqual(
    parseUserFromExtensionPath('/Library/Application Support/Glow/foo', 'ms-python.python'),
    { ok: false, error: 'INVALID_EXTENSION_PATH' },
  );
  assert.deepEqual(
    parseUserFromExtensionPath('/Users/jdoe/Documents/notes.txt', 'ms-python.python'),
    { ok: false, error: 'INVALID_EXTENSION_PATH' },
  );
});

test('parseUserFromExtensionPath rejects a username with unexpected characters', () => {
  const result = parseUserFromExtensionPath(
    '/Users/j doe/.vscode/extensions/ms-python.python-2024.1.0',
    'ms-python.python',
  );
  assert.deepEqual(result, { ok: false, error: 'INVALID_EXTENSION_PATH' });
});

test('parseUserFromExtensionPath rejects a path whose leaf does not match the claimed extension id', () => {
  const result = parseUserFromExtensionPath(
    '/Users/jdoe/.vscode/extensions/some-other.extension-1.0.0',
    'ms-python.python',
  );
  assert.deepEqual(result, { ok: false, error: 'EXTENSION_PATH_ID_MISMATCH' });
});

// ---------------------------------------------------------------------------
// decideVersionAction
// ---------------------------------------------------------------------------

test('decideVersionAction: not installed -> not_installed, regardless of target version', () => {
  assert.deepEqual(
    decideVersionAction({}, 'ms-python.python', '2024.1.0'),
    { action: 'not_installed' },
  );
  assert.deepEqual(
    decideVersionAction({}, 'ms-python.python', null),
    { action: 'not_installed' },
  );
});

test('decideVersionAction: installed, no target version -> upgrade_to_latest', () => {
  const installed = { 'ms-python.python': '2024.1.0' };
  assert.deepEqual(
    decideVersionAction(installed, 'ms-python.python', null),
    { action: 'upgrade_to_latest', installedVersion: '2024.1.0' },
  );
  assert.deepEqual(
    decideVersionAction(installed, 'ms-python.python', undefined),
    { action: 'upgrade_to_latest', installedVersion: '2024.1.0' },
  );
});

test('decideVersionAction: installed at the target version already -> already_correct_version', () => {
  const installed = { 'ms-python.python': '2024.1.0' };
  assert.deepEqual(
    decideVersionAction(installed, 'ms-python.python', '2024.1.0'),
    { action: 'already_correct_version', installedVersion: '2024.1.0' },
  );
});

test('decideVersionAction: installed at a newer version than target -> set_version (downgrade)', () => {
  const installed = { 'ms-python.python': '2024.5.0' };
  assert.deepEqual(
    decideVersionAction(installed, 'ms-python.python', '2024.1.0'),
    { action: 'set_version', installedVersion: '2024.5.0' },
  );
});

test('decideVersionAction: installed at an older version than target -> set_version (upgrade)', () => {
  const installed = { 'ms-python.python': '2024.1.0' };
  assert.deepEqual(
    decideVersionAction(installed, 'ms-python.python', '2024.5.0'),
    { action: 'set_version', installedVersion: '2024.1.0' },
  );
});

test('decideVersionAction: extension id lookup is case-insensitive', () => {
  const installed = { 'ms-python.python': '2024.1.0' };
  assert.deepEqual(
    decideVersionAction(installed, 'MS-Python.Python', '2024.1.0'),
    { action: 'already_correct_version', installedVersion: '2024.1.0' },
  );
});

test('decideVersionAction: tolerates a null/undefined installedExtensions map', () => {
  assert.deepEqual(
    decideVersionAction(null, 'ms-python.python', '2024.1.0'),
    { action: 'not_installed' },
  );
  assert.deepEqual(
    decideVersionAction(undefined, 'ms-python.python', '2024.1.0'),
    { action: 'not_installed' },
  );
});

// ---------------------------------------------------------------------------
// computeRunOutcome
// ---------------------------------------------------------------------------

test('computeRunOutcome: not_installed -> skipped, unchanged, no error', () => {
  const decision = { action: 'not_installed' };
  assert.deepEqual(
    computeRunOutcome(decision, null, null, false),
    { status: 'skipped', changed: false, error: null },
  );
});

test('computeRunOutcome: already_correct_version -> skipped, unchanged, no error', () => {
  const decision = { action: 'already_correct_version', installedVersion: '2024.1.0' };
  assert.deepEqual(
    computeRunOutcome(decision, null, '2024.1.0', false),
    { status: 'skipped', changed: false, error: null },
  );
});

test('computeRunOutcome: set_version succeeds and the version actually changed -> success, changed', () => {
  const decision = { action: 'set_version', installedVersion: '2024.1.0' };
  const actionResult = { attempted: true, ok: true, stderr: '' };
  assert.deepEqual(
    computeRunOutcome(decision, actionResult, '2024.5.0', false),
    { status: 'success', changed: true, error: null },
  );
});

test('computeRunOutcome: set_version succeeds but the version is unchanged -> success, not changed', () => {
  // Edge case: the CLI reported success but a fresh listing shows the same
  // version as before - still "success" (the command didn't fail), just
  // nothing to report as changed.
  const decision = { action: 'set_version', installedVersion: '2024.1.0' };
  const actionResult = { attempted: true, ok: true, stderr: '' };
  assert.deepEqual(
    computeRunOutcome(decision, actionResult, '2024.1.0', false),
    { status: 'success', changed: false, error: null },
  );
});

test('computeRunOutcome: set_version fails -> failure, UPGRADE_INCOMPLETE, stderr folded into the message (canonical error object is {code, message} only)', () => {
  const decision = { action: 'set_version', installedVersion: '2024.1.0' };
  const actionResult = { attempted: true, ok: false, stderr: 'network error' };
  const outcome = computeRunOutcome(decision, actionResult, null, false);
  assert.equal(outcome.status, 'failure');
  assert.equal(outcome.changed, false);
  assert.equal(outcome.error.code, 'UPGRADE_INCOMPLETE');
  assert.ok(outcome.error.message.indexOf('network error') !== -1);
  assert.ok(!Object.prototype.hasOwnProperty.call(outcome.error, 'stderr'));
});

test('computeRunOutcome: set_version fails with no stderr -> message has no dangling separator', () => {
  const decision = { action: 'set_version', installedVersion: '2024.1.0' };
  const actionResult = { attempted: true, ok: false };
  const outcome = computeRunOutcome(decision, actionResult, null, false);
  assert.equal(outcome.error.message, 'code --install-extension failed');
});

test('computeRunOutcome: upgrade_to_latest succeeds and version changed -> success, changed', () => {
  const decision = { action: 'upgrade_to_latest', installedVersion: '2024.1.0' };
  const actionResult = { attempted: true, ok: true, stderr: '' };
  assert.deepEqual(
    computeRunOutcome(decision, actionResult, '2024.9.0', false),
    { status: 'success', changed: true, error: null },
  );
});

test('computeRunOutcome: upgrade_to_latest succeeds but was already latest -> success, not changed', () => {
  const decision = { action: 'upgrade_to_latest', installedVersion: '2024.9.0' };
  const actionResult = { attempted: true, ok: true, stderr: '' };
  assert.deepEqual(
    computeRunOutcome(decision, actionResult, '2024.9.0', false),
    { status: 'success', changed: false, error: null },
  );
});

test('computeRunOutcome: upgrade_to_latest fails -> failure', () => {
  const decision = { action: 'upgrade_to_latest', installedVersion: '2024.1.0' };
  const actionResult = { attempted: true, ok: false, stderr: 'boom' };
  const outcome = computeRunOutcome(decision, actionResult, null, false);
  assert.equal(outcome.status, 'failure');
});

test('computeRunOutcome: dry run with a pending set_version -> skipped, not changed, no error', () => {
  const decision = { action: 'set_version', installedVersion: '2024.1.0' };
  const actionResult = { attempted: false, dry_run: true };
  assert.deepEqual(
    computeRunOutcome(decision, actionResult, '2024.1.0', true),
    { status: 'skipped', changed: false, error: null },
  );
});

test('computeRunOutcome: dry run with a pending upgrade_to_latest -> skipped, not changed, no error', () => {
  const decision = { action: 'upgrade_to_latest', installedVersion: '2024.1.0' };
  const actionResult = { attempted: false, dry_run: true };
  assert.deepEqual(
    computeRunOutcome(decision, actionResult, '2024.1.0', true),
    { status: 'skipped', changed: false, error: null },
  );
});
