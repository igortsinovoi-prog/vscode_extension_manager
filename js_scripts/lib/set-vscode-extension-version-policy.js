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
