# =====================================================================
# Automated tests for the PowerShell runner half of
# Set-VSCodeExtensionVersion.ps1 (Set-VSCodeExtensionVersion.Runner.ps1 +
# Set-VSCodeExtensionVersion.Policy.ps1).
#
# Mocks Invoke-VSCodeNativeCommand - the single seam ALL process invocation
# (code.cmd) goes through - plus the small filesystem seams
# (Test-VSCodeFileExists, Test-VSCodeDirectoryExists, Resolve-VSCodeSafePath,
# Write-VSCodeDiag), so no real process is spawned and no real filesystem
# state is touched: deterministic, fast, no dependency on a real VS Code
# install or real user profiles existing on the test machine.
# =====================================================================

BeforeAll {
  . "$PSScriptRoot/../lib/Set-VSCodeExtensionVersion.Policy.ps1"
  . "$PSScriptRoot/../lib/Set-VSCodeExtensionVersion.Runner.ps1"

  $script:JdoePath = 'C:\Users\jdoe\.vscode\extensions\ms-python.python-2024.1.0'

  function New-EncodedInput {
    param($Params, [bool]$DryRun = $true)
    $payload = [PSCustomObject]@{ params = $Params; dry_run = $DryRun } | ConvertTo-Json -Compress -Depth 6
    return [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($payload))
  }
}

# Pester 6 dropped support for BeforeEach/Mock declared directly at the
# container root (only BeforeAll is still allowed there) - everything that
# needs to run per-test must live inside a Describe block, so the shared
# setup below and all the Context blocks that use it are nested inside one
# enclosing Describe rather than sitting at file scope.
Describe 'Set-VSCodeExtensionVersion.Runner' {
  BeforeEach {
    $script:CommandLog = New-Object System.Collections.Generic.List[object]
    $script:MockConfig = [PSCustomObject]@{
      ListExtensionsExitCode       = 0
      ListExtensionsStdout         = ''
      ListExtensionsStdoutSequence = $null
      ListExtensionsCallIndex      = 0
      InstallResult                = [PSCustomObject]@{ ExitCode = 0; Stdout = ''; Stderr = '' }
      # Restart-VSCodeIfRunning's own seam - default to "nobody has VS
      # Code running", overridden per-test. Must be declared here, not
      # added later via plain assignment - PSCustomObject doesn't support
      # adding a new property that way (confirmed: threw "The property
      # 'RunningPids' cannot be found on this object" when tried).
      RunningPids                  = @()
    }

    Mock Write-VSCodeDiag { }
    Mock Test-VSCodeFileExists { $true }
    Mock Test-VSCodeDirectoryExists { $true }
    Mock Resolve-VSCodeSafePath { param($Path) return $Path }
    # Matches the old hardcoded "C:\Users\<user>" behavior these tests
    # were already written against - Resolve-VSCodeUserProfilePath's own
    # real Win32_UserProfile lookup (and its fallback) is covered by its
    # own dedicated tests below, not re-verified by every other test here.
    Mock Resolve-VSCodeUserProfilePath { param($UserName) "C:\Users\$UserName" }
    Mock Test-VSCodePathAccess { [PSCustomObject]@{ Exists = $true; AccessDenied = $false } }
    Mock New-VSCodeDirectoryIfMissing { }
    Mock Get-VSCodeFileContent { $null }
    Mock Set-VSCodeFileContent { }
    Mock Remove-VSCodeFileIfExists { }
    Mock Get-VSCodeFileAcl { $null }
    Mock Set-VSCodeFileAcl { }

    Mock Invoke-VSCodeNativeCommand {
      param($FilePath, $ArgumentList, $TimeoutSec)
      $script:CommandLog.Add([PSCustomObject]@{ FilePath = $FilePath; ArgumentList = $ArgumentList; TimeoutSec = $TimeoutSec })

      if ($ArgumentList -contains '--list-extensions') {
        $stdout = $script:MockConfig.ListExtensionsStdout
        if ($script:MockConfig.ListExtensionsStdoutSequence) {
          $seq = $script:MockConfig.ListExtensionsStdoutSequence
          $idx = [Math]::Min($script:MockConfig.ListExtensionsCallIndex, $seq.Count - 1)
          $stdout = $seq[$idx]
          $script:MockConfig.ListExtensionsCallIndex++
        }
        return [PSCustomObject]@{ ExitCode = $script:MockConfig.ListExtensionsExitCode; Stdout = $stdout; Stderr = '' }
      }
      if ($ArgumentList -contains '--install-extension') {
        return $script:MockConfig.InstallResult
      }
      return [PSCustomObject]@{ ExitCode = 1; Stdout = ''; Stderr = "unmocked command: $FilePath $($ArgumentList -join ' ')" }
    }

    $script:StopProcessLog = New-Object System.Collections.Generic.List[object]
    $script:GracefulCloseLog = New-Object System.Collections.Generic.List[object]
    $script:ScheduledTaskLog = New-Object System.Collections.Generic.List[object]
    Mock Get-VSCodeProcessOwners {
      param($ProcessName)
      return $script:MockConfig.RunningPids | ForEach-Object {
        [PSCustomObject]@{ ProcessId = $_; User = 'jdoe' }
      }
    }
    Mock Stop-Process {
      param($Id)
      $script:StopProcessLog.Add($Id)
    }
    # Default: simulate the process actually exiting in response to the
    # graceful close, matching the common real-world case - a dedicated
    # test below overrides this to leave RunningPids populated instead,
    # exercising the force-kill fallback.
    Mock Invoke-VSCodeCloseMainWindow {
      param($ProcessId)
      $script:GracefulCloseLog.Add($ProcessId)
      $script:MockConfig.RunningPids = @()
    }
    # Real Start-Sleep would make Restart-VSCodeIfRunning's own polling
    # loop actually wait - up to 10 real seconds per test that exercises
    # the force-kill fallback path. Mocked everywhere so the whole suite
    # stays fast regardless of which path a given test takes.
    Mock Start-Sleep { }
    # New-ScheduledTaskAction/New-ScheduledTaskPrincipal deliberately NOT
    # mocked - they're cheap, pure, side-effect-free object constructors,
    # and mocking them turned out to matter: Register-ScheduledTask's real
    # -Action/-Principal parameters expect actual typed CIM objects, and
    # feeding it a generic PSCustomObject stand-in from a mocked
    # constructor failed parameter binding before this test's own
    # Register-ScheduledTask mock ever ran - confirmed only by actually
    # running this suite against a real Windows box; the failure was
    # silently swallowed by Restart-VSCodeIfRunning's own catch block, so
    # only "unregister" ever showed up in the log with no clue why
    # "register"/"start" never did.
    Mock Register-ScheduledTask {
      param($TaskName, $Action, $Principal)
      $script:ScheduledTaskLog.Add([PSCustomObject]@{ Event = 'register'; TaskName = $TaskName; Action = $Action; Principal = $Principal })
    }
    Mock Start-ScheduledTask {
      param($TaskName)
      $script:ScheduledTaskLog.Add([PSCustomObject]@{ Event = 'start'; TaskName = $TaskName })
    }
    Mock Unregister-ScheduledTask {
      param($TaskName)
      $script:ScheduledTaskLog.Add([PSCustomObject]@{ Event = 'unregister'; TaskName = $TaskName })
    }
  }

Context 'Resolve-VSCodeTargetUser' {
  It 'real profile directory -> resolves extensions dir under that user, no resolution note' {
    $result = Resolve-VSCodeTargetUser $script:JdoePath 'ms-python.python'
    $result.User | Should -Be 'jdoe'
    $result.ExtensionsDir | Should -Be 'C:\Users\jdoe\.vscode\extensions'
    $result.ResolutionNote | Should -BeNullOrEmpty
  }

  It 'parsed user has no profile directory -> falls back to SYSTEM dir, user kept, note set' {
    Mock Test-VSCodePathAccess { [PSCustomObject]@{ Exists = $false; AccessDenied = $false } }
    $result = Resolve-VSCodeTargetUser $script:JdoePath 'ms-python.python'
    $result.User | Should -Be 'jdoe'
    $result.ExtensionsDir | Should -Be $Script:RootFallbackExtensionsDir
    $result.ResolutionNote | Should -Be 'EXTENSION_PATH_USER_NOT_FOUND'
  }

  It 'parsed user has a profile directory that exists but cannot be accessed -> falls back to SYSTEM dir, distinct note from not-found' {
    Mock Test-VSCodePathAccess { [PSCustomObject]@{ Exists = $true; AccessDenied = $true } }
    $result = Resolve-VSCodeTargetUser $script:JdoePath 'ms-python.python'
    $result.User | Should -Be 'jdoe'
    $result.ExtensionsDir | Should -Be $Script:RootFallbackExtensionsDir
    $result.ResolutionNote | Should -Be 'EXTENSION_PATH_USER_PROFILE_ACCESS_DENIED'
  }

  It 'missing path -> user $null, falls back to SYSTEM dir, never throws' {
    $result = Resolve-VSCodeTargetUser $null 'ms-python.python'
    $result.User | Should -BeNullOrEmpty
    $result.ExtensionsDir | Should -Be $Script:RootFallbackExtensionsDir
    $result.ResolutionNote | Should -Be 'MISSING_EXTENSION_PATH'
  }

  It 'malformed path -> user $null, falls back to SYSTEM dir' {
    $result = Resolve-VSCodeTargetUser 'C:\not\a\valid\path' 'ms-python.python'
    $result.User | Should -BeNullOrEmpty
    $result.ResolutionNote | Should -Be 'INVALID_EXTENSION_PATH'
  }

  It 'extension id mismatch -> user $null, falls back to SYSTEM dir' {
    $result = Resolve-VSCodeTargetUser 'C:\Users\jdoe\.vscode\extensions\some-other.extension-1.0.0' 'ms-python.python'
    $result.User | Should -BeNullOrEmpty
    $result.ResolutionNote | Should -Be 'EXTENSION_PATH_ID_MISMATCH'
  }

  It 'filesystem safety check mismatch -> falls back to SYSTEM dir, note EXTENSION_PATH_UNSAFE' {
    Mock Resolve-VSCodeSafePath { 'C:\Users\evil\.vscode\extensions\ms-python.python-2024.1.0' }
    $result = Resolve-VSCodeTargetUser $script:JdoePath 'ms-python.python'
    $result.User | Should -Be 'jdoe'
    $result.ExtensionsDir | Should -Be $Script:RootFallbackExtensionsDir
    $result.ResolutionNote | Should -Be 'EXTENSION_PATH_UNSAFE'
  }
}

Context 'Test-VSCodeUsedSystemFallback' {
  It 'a real resolved user with no resolution note -> false (not a fallback)' {
    Test-VSCodeUsedSystemFallback ([PSCustomObject]@{ User = 'jdoe'; ResolutionNote = $null }) | Should -BeFalse
  }

  It 'a resolution note set, user still kept for diagnostics (e.g. not-found) -> true' {
    Test-VSCodeUsedSystemFallback ([PSCustomObject]@{ User = 'glow_test_no_such_user'; ResolutionNote = 'EXTENSION_PATH_USER_NOT_FOUND' }) | Should -BeTrue
  }

  It 'a resolution note set, no user at all (e.g. missing/invalid path) -> true' {
    Test-VSCodeUsedSystemFallback ([PSCustomObject]@{ User = $null; ResolutionNote = 'MISSING_EXTENSION_PATH' }) | Should -BeTrue
  }

  It 'neither user nor resolution note set (Resolve-VSCodeTargetUser never even ran) -> true, not a false "real user resolved"' {
    # A real call to Resolve-VSCodeTargetUser never produces this
    # combination - it's the sentinel default used by early failure
    # envelopes (INVALID_PARAMS on extension_id/version) built before
    # target-user resolution has run at all. Must not be confused with
    # the one real case that also has ResolutionNote = $null: an
    # actually-resolved real user.
    Test-VSCodeUsedSystemFallback ([PSCustomObject]@{ User = $null; ResolutionNote = $null }) | Should -BeTrue
  }
}

Context 'Get-VSCodeUserDataDir' {
  It 'derives AppData\Roaming\Code from the profile root above \.vscode\extensions' {
    Get-VSCodeUserDataDir 'C:\Users\jdoe\.vscode\extensions' | Should -Be 'C:\Users\jdoe\AppData\Roaming\Code'
  }

  It 'derives it the same way for the SYSTEM fallback extensions dir' {
    Get-VSCodeUserDataDir $Script:RootFallbackExtensionsDir | Should -Be (Join-Path (Split-Path $Script:RootFallbackExtensionsDir -Parent | Split-Path -Parent) 'AppData\Roaming\Code')
  }

  It 'throws if the path does not end in \.vscode\extensions' {
    { Get-VSCodeUserDataDir 'C:\Users\jdoe\Documents' } | Should -Throw
  }
}

Context 'Enable-VSCodeSignatureVerificationBypass / Restore-VSCodeSignatureVerification' {
  It 'sets extensions.verifySignature: false when no settings.json existed, and deletes it on restore' {
    Mock Test-VSCodeFileExists { $false }
    $state = Enable-VSCodeSignatureVerificationBypass 'C:\Users\jdoe\AppData\Roaming\Code'
    $state.Applied | Should -BeTrue
    $state.FileExisted | Should -BeFalse
    Should -Invoke Set-VSCodeFileContent -Times 1 -ParameterFilter { $Content -match '"extensions.verifySignature":\s*false' }

    Restore-VSCodeSignatureVerification $state
    # Not-existed case: no backup was ever created, so this is just the
    # removal of the (never-created) settings.json plus the unconditional
    # backup-path cleanup that always runs regardless of FileExisted.
    Should -Invoke Remove-VSCodeFileIfExists -Times 2
  }

  It 'preserves other keys and restores the exact original raw text (from a real on-disk backup, not memory) when settings.json already existed' {
    $originalRaw = '{"editor.fontSize": 14}'
    Mock Get-VSCodeFileContent { $originalRaw }
    $state = Enable-VSCodeSignatureVerificationBypass 'C:\Users\jdoe\AppData\Roaming\Code'
    $state.FileExisted | Should -BeTrue
    # OriginalRaw is deliberately NOT kept on the state object anymore -
    # Restore-VSCodeSignatureVerification reads it back from the on-disk
    # backup instead (State.BackupPath), not from memory - see that
    # function's own comment on why that matters.
    $state.BackupPath | Should -Be 'C:\Users\jdoe\AppData\Roaming\Code\User\settings.json.glow-bak'
    # Two calls so far: the real on-disk backup (exact original raw text)
    # and the bypassed settings.json.
    Should -Invoke Set-VSCodeFileContent -Times 1 -ParameterFilter { $Path -eq $state.BackupPath -and $Content -eq $originalRaw }
    Should -Invoke Set-VSCodeFileContent -Times 1 -ParameterFilter {
      $Content -match '"editor.fontSize":\s*14' -and $Content -match '"extensions.verifySignature":\s*false'
    }
    # The backup's permissions are captured from the ORIGINAL settings.json
    # BEFORE the backup is written, then explicitly reapplied after -
    # never left to whatever ACL the write happens to inherit.
    Should -Invoke Get-VSCodeFileAcl -Times 1 -ParameterFilter { $Path -eq 'C:\Users\jdoe\AppData\Roaming\Code\User\settings.json' }
    Should -Invoke Set-VSCodeFileAcl -Times 1 -ParameterFilter { $Path -eq $state.BackupPath }

    Restore-VSCodeSignatureVerification $state
    # Now three total: the two above, plus the restore write - the
    # backup and the restore both legitimately have the same content
    # (the exact original raw text), so two calls now match that filter.
    Should -Invoke Set-VSCodeFileContent -Times 2 -ParameterFilter { $Content -eq $originalRaw }
    Should -Invoke Remove-VSCodeFileIfExists -Times 1 -ParameterFilter { $Path -eq $state.BackupPath }
  }

  It 'restore backup is deleted even when the restore write itself fails (never stranded - it can carry secrets)' {
    $originalRaw = '{"editor.fontSize": 14}'
    Mock Get-VSCodeFileContent { $originalRaw }
    $state = Enable-VSCodeSignatureVerificationBypass 'C:\Users\jdoe\AppData\Roaming\Code'
    Mock Set-VSCodeFileContent {
      param($Path, $Content)
      if ($Path -eq $state.SettingsPath) { throw 'simulated locked file' }
    }
    Restore-VSCodeSignatureVerification $state
    Should -Invoke Remove-VSCodeFileIfExists -Times 1 -ParameterFilter { $Path -eq $state.BackupPath }
  }

  It 'skips applying (and does not touch the file) if existing settings.json fails to parse' {
    Mock Get-VSCodeFileContent { 'not valid json {' }
    $state = Enable-VSCodeSignatureVerificationBypass 'C:\Users\jdoe\AppData\Roaming\Code'
    $state.Applied | Should -BeFalse
    Should -Invoke Set-VSCodeFileContent -Times 0
  }
}

Context 'Invoke-VSCodeCli dispatch' {
  It 'always prepends --extensions-dir and the derived --user-data-dir before the caller-supplied arguments' {
    Invoke-VSCodeCli -CodePath 'C:\code.cmd' -ExtensionsDir 'C:\Users\jdoe\.vscode\extensions' `
      -Arguments @('--list-extensions', '--show-versions') -TimeoutSec 20
    $script:CommandLog.Count | Should -Be 1
    $script:CommandLog[0].FilePath | Should -Be 'C:\code.cmd'
    $script:CommandLog[0].ArgumentList | Should -Be @(
      '--extensions-dir', 'C:\Users\jdoe\.vscode\extensions',
      '--user-data-dir', 'C:\Users\jdoe\AppData\Roaming\Code',
      '--list-extensions', '--show-versions'
    )
  }

  It 'restores the signature-verification setting even after the CLI call, via try/finally' {
    Mock Get-VSCodeFileContent { '{"foo":"bar"}' }
    Invoke-VSCodeCli -CodePath 'C:\code.cmd' -ExtensionsDir 'C:\Users\jdoe\.vscode\extensions' `
      -Arguments @('--list-extensions') -TimeoutSec 20
    # Three Set-VSCodeFileContent calls: the real on-disk backup, the
    # bypass, and the restore - the backup and the restore both
    # legitimately carry the original raw text, so two calls match that
    # content, not one.
    Should -Invoke Set-VSCodeFileContent -Times 3
    Should -Invoke Set-VSCodeFileContent -Times 2 -ParameterFilter { $Content -eq '{"foo":"bar"}' }
  }
}

Context 'Invoke-VSCodeUpgradeToLatest / Invoke-VSCodeSetExactVersion dry-run gating' {
  It 'upgrade: dry run does not invoke the CLI at all' {
    $result = Invoke-VSCodeUpgradeToLatest 'C:\code.cmd' 'C:\Users\jdoe\.vscode\extensions' 'ms-python.python' $true
    $result.Attempted | Should -BeFalse
    $result.DryRun | Should -BeTrue
    $script:CommandLog.Count | Should -Be 0
  }

  It 'upgrade: real run invokes --install-extension id --force (not --upgrade-extension) and reports Ok on success' {
    $script:MockConfig.InstallResult = [PSCustomObject]@{ ExitCode = 0; Stdout = 'done'; Stderr = '' }
    $result = Invoke-VSCodeUpgradeToLatest 'C:\code.cmd' 'C:\Users\jdoe\.vscode\extensions' 'ms-python.python' $false
    $result.Attempted | Should -BeTrue
    $result.Ok | Should -BeTrue
    $call = $script:CommandLog[-1]
    ($call.ArgumentList | Select-Object -Last 3) | Should -Be @('--install-extension', 'ms-python.python', '--force')
  }

  It 'setExactVersion: real run invokes --install-extension id@version --force' {
    $script:MockConfig.InstallResult = [PSCustomObject]@{ ExitCode = 0; Stdout = ''; Stderr = '' }
    $result = Invoke-VSCodeSetExactVersion 'C:\code.cmd' 'C:\Users\jdoe\.vscode\extensions' 'ms-python.python' '2024.1.0' $false
    $result.Ok | Should -BeTrue
    $call = $script:CommandLog[-1]
    ($call.ArgumentList | Select-Object -Last 3) | Should -Be @('--install-extension', 'ms-python.python@2024.1.0', '--force')
  }

  It 'setExactVersion: CLI failure is reported as not Ok, with stderr captured' {
    $script:MockConfig.InstallResult = [PSCustomObject]@{ ExitCode = 1; Stdout = ''; Stderr = 'network error' }
    $result = Invoke-VSCodeSetExactVersion 'C:\code.cmd' 'C:\Users\jdoe\.vscode\extensions' 'ms-python.python' '2024.1.0' $false
    $result.Ok | Should -BeFalse
    $result.Stderr | Should -Be 'network error'
  }

  It 'setExactVersion: short stdout/stderr pass through unchanged in the envelope' {
    $script:MockConfig.InstallResult = [PSCustomObject]@{ ExitCode = 0; Stdout = 'short output'; Stderr = 'short stderr' }
    $result = Invoke-VSCodeSetExactVersion 'C:\code.cmd' 'C:\Users\jdoe\.vscode\extensions' 'ms-python.python' '2024.1.0' $false
    $result.Stdout | Should -Be 'short output'
    $result.Stderr | Should -Be 'short stderr'
  }

  It 'setExactVersion: stdout/stderr over 2000 chars are truncated for the envelope (full text still goes to diag - see ConvertTo-VSCodeTruncatedText)' {
    $longOutput = 'x' * 2500
    $script:MockConfig.InstallResult = [PSCustomObject]@{ ExitCode = 0; Stdout = $longOutput; Stderr = $longOutput }
    $result = Invoke-VSCodeSetExactVersion 'C:\code.cmd' 'C:\Users\jdoe\.vscode\extensions' 'ms-python.python' '2024.1.0' $false
    $result.Stdout.Length | Should -BeLessThan $longOutput.Length
    $result.Stdout.StartsWith('x' * 2000) | Should -BeTrue
    $result.Stdout | Should -Match 'truncated, 2500 chars total'
    $result.Stderr | Should -Match 'truncated, 2500 chars total'
  }
}

Context 'Get-VSCodeRunningPidsForUser / Restart-VSCodeIfRunning' {
  It 'no VS Code processes running -> empty' {
    $script:MockConfig.RunningPids = @()
    Get-VSCodeRunningPidsForUser 'jdoe' | Should -BeNullOrEmpty
  }

  It 'VS Code running as the target user -> returns its pid' {
    $script:MockConfig.RunningPids = @(4242)
    Get-VSCodeRunningPidsForUser 'jdoe' | Should -Be @(4242)
  }

  It 'null/empty target user -> never attempts anything, returns $false' {
    Restart-VSCodeIfRunning $null 'C:\Program Files\Microsoft VS Code\bin\code.cmd' | Should -BeFalse
    $script:StopProcessLog.Count | Should -Be 0
    $script:ScheduledTaskLog.Count | Should -Be 0
  }

  It 'not running -> no stop/relaunch attempted, returns $false' {
    $script:MockConfig.RunningPids = @()
    Restart-VSCodeIfRunning 'jdoe' 'C:\Program Files\Microsoft VS Code\bin\code.cmd' | Should -BeFalse
    $script:StopProcessLog.Count | Should -Be 0
    $script:ScheduledTaskLog.Count | Should -Be 0
  }

  It 'running, closes gracefully -> a graceful close is tried first and is enough, no force-kill needed, then registers/starts/unregisters a one-shot interactive Scheduled Task pointed at Code.exe' {
    $script:MockConfig.RunningPids = @(4242)
    $result = Restart-VSCodeIfRunning 'jdoe' 'C:\Program Files\Microsoft VS Code\bin\code.cmd'
    $result | Should -BeTrue
    $script:GracefulCloseLog | Should -Be @(4242)
    # The default mock simulates the process actually exiting in
    # response to the graceful close - Stop-Process should never be
    # needed at all in that case.
    $script:StopProcessLog.Count | Should -Be 0

    ($script:ScheduledTaskLog | Select-Object -ExpandProperty Event) | Should -Be @('register', 'start', 'unregister')
    $registerEntry = $script:ScheduledTaskLog | Where-Object { $_.Event -eq 'register' }
    $registerEntry.Action.Execute | Should -Be 'C:\Program Files\Microsoft VS Code\Code.exe'
    $registerEntry.Principal.UserId | Should -Be 'jdoe'
    $registerEntry.Principal.LogonType | Should -Be 'Interactive'
  }

  It 'running, does not close gracefully -> falls back to force-kill after the graceful close had its full chance, then still relaunches' {
    $script:MockConfig.RunningPids = @(4242)
    # Override the default "success" simulation - the process stays
    # "running" (RunningPids never clears) despite the graceful close
    # attempt, exercising the force-kill fallback.
    Mock Invoke-VSCodeCloseMainWindow {
      param($ProcessId)
      $script:GracefulCloseLog.Add($ProcessId)
    }
    $result = Restart-VSCodeIfRunning 'jdoe' 'C:\Program Files\Microsoft VS Code\bin\code.cmd'
    $result | Should -BeTrue
    # Graceful close was still tried first...
    $script:GracefulCloseLog | Should -Be @(4242)
    # ...gave it the full poll window (Start-Sleep mocked, so this
    # doesn't actually wait 10 real seconds)...
    Should -Invoke Start-Sleep -Times 10
    # ...and only THEN force-killed it as the last resort.
    $script:StopProcessLog | Should -Be @(4242)
    ($script:ScheduledTaskLog | Select-Object -ExpandProperty Event) | Should -Be @('register', 'start', 'unregister')
  }

  It 'relaunch scheduled task genuinely fails to start -> returns $false, not just $true because processes were found and killed' {
    $script:MockConfig.RunningPids = @(4242)
    # Register succeeds (still logged/unregistered), but the actual
    # Start-ScheduledTask call throws - e.g. the task's principal/logon
    # type is rejected, or the target user has no interactive session.
    # vscode_restarted must reflect that real failure, not just "VS Code
    # was found running and we attempted something".
    Mock Start-ScheduledTask {
      param($TaskName)
      throw 'Start-ScheduledTask: The task launch failed.'
    }
    $result = Restart-VSCodeIfRunning 'jdoe' 'C:\Program Files\Microsoft VS Code\bin\code.cmd'
    $result | Should -BeFalse
    # The graceful-close-then-relaunch attempt still happened...
    $script:GracefulCloseLog | Should -Be @(4242)
    # ...register was attempted and unregister still ran (cleanup via
    # `finally`), but there's no 'start' entry since it threw.
    ($script:ScheduledTaskLog | Select-Object -ExpandProperty Event) | Should -Be @('register', 'unregister')
  }
}

Context 'Invoke-SetVSCodeExtensionVersion end-to-end' {
  It 'invalid extension_id -> failure envelope, INVALID_PARAMS, wrapped in scope/targets[], mirrored at envelope level' {
    $result = Invoke-SetVSCodeExtensionVersion (New-EncodedInput @{ extension_id = 'not-an-id' } $true) | ConvertFrom-Json
    $result.scope | Should -Be 'anchor'
    $result.targets.Count | Should -Be 1
    $target = $result.targets[0]
    $target.status | Should -Be 'failure'
    $target.error.code | Should -Be 'INVALID_PARAMS'
    # Base envelope fields (contract-standards.md) stay present ALONGSIDE
    # scope/targets[], not replaced by them - mirroring the one target's
    # own status/changed/error since this script only ever has one.
    $result.status | Should -Be 'failure'
    $result.changed | Should -BeFalse
    $result.error.code | Should -Be 'INVALID_PARAMS'
    # Failure targets mirror the success target's own full field list -
    # whatever was already figured out before the failure (here, just the
    # raw invalid extension_id itself) is reported as-is; everything not
    # yet reached stays at its safe "not yet known" default rather than
    # just being absent, so a caller never has to special-case a failure
    # target's shape vs. a success one's.
    $target.extension_id | Should -Be 'not-an-id'
    $target.desired_version | Should -BeNullOrEmpty
    $target.extension_path | Should -BeNullOrEmpty
    $target.action | Should -BeNullOrEmpty
    $target.target_user | Should -BeNullOrEmpty
    $target.used_system_fallback | Should -BeTrue
    $target.cli_result | Should -BeNullOrEmpty
    $target.vscode_restarted | Should -BeFalse
  }

  It 'invalid desired_version -> failure envelope, INVALID_PARAMS' {
    $result = Invoke-SetVSCodeExtensionVersion (New-EncodedInput @{ extension_id = 'ms-python.python'; desired_version = 'not-semver' } $true) | ConvertFrom-Json
    $target = $result.targets[0]
    $target.status | Should -Be 'failure'
    $target.error.code | Should -Be 'INVALID_PARAMS'
    $target.extension_id | Should -Be 'ms-python.python'
    $target.desired_version | Should -Be 'not-semver'
  }

  It 'code.cmd not found anywhere -> failure envelope, CLI_NOT_FOUND' {
    Mock Test-VSCodeFileExists { $false }
    $result = Invoke-SetVSCodeExtensionVersion (New-EncodedInput @{ extension_id = 'ms-python.python'; extension_path = $script:JdoePath } $true) | ConvertFrom-Json
    $target = $result.targets[0]
    $target.status | Should -Be 'failure'
    $target.error.code | Should -Be 'CLI_NOT_FOUND'
    # Unlike macOS (which checks VS Code's own install location before
    # ever reading extension_path), Windows resolves the target user
    # first - so extension_path/target_user are already known here.
    $target.extension_path | Should -Be $script:JdoePath
    $target.target_user | Should -Be 'jdoe'
  }

  It 'code --list-extensions itself fails -> failure envelope, UPGRADE_INCOMPLETE with the raw CLI failure in the message' {
    $script:MockConfig.ListExtensionsExitCode = 1
    $result = Invoke-SetVSCodeExtensionVersion (New-EncodedInput @{ extension_id = 'ms-python.python'; desired_version = '2024.1.0'; extension_path = $script:JdoePath } $true) | ConvertFrom-Json
    $target = $result.targets[0]
    $target.status | Should -Be 'failure'
    $target.error.code | Should -Be 'UPGRADE_INCOMPLETE'
    $target.error.message | Should -BeLike '*list-extensions*'
    $target.extension_id | Should -Be 'ms-python.python'
    $target.desired_version | Should -Be '2024.1.0'
    $target.extension_path | Should -Be $script:JdoePath
    $target.target_user | Should -Be 'jdoe'
    $target.used_system_fallback | Should -BeFalse
  }

  It 'extension not installed -> skipped, no CLI action taken' {
    $script:MockConfig.ListExtensionsStdout = "some-other.extension@1.0.0`n"
    $result = Invoke-SetVSCodeExtensionVersion (New-EncodedInput @{ extension_id = 'ms-python.python'; desired_version = '2024.1.0'; extension_path = $script:JdoePath } $true) | ConvertFrom-Json
    $target = $result.targets[0]
    $target.status | Should -Be 'skipped'
    $target.changed | Should -BeFalse
    $target.action | Should -Be 'not_installed'
    $target.cli_result | Should -BeNullOrEmpty
  }

  It 'already at the target version -> skipped, no CLI action taken' {
    $script:MockConfig.ListExtensionsStdout = "ms-python.python@2024.1.0`n"
    $result = Invoke-SetVSCodeExtensionVersion (New-EncodedInput @{ extension_id = 'ms-python.python'; desired_version = '2024.1.0'; extension_path = $script:JdoePath } $true) | ConvertFrom-Json
    $target = $result.targets[0]
    $target.status | Should -Be 'skipped'
    $target.action | Should -Be 'already_correct_version'
  }

  It 'differing version, real run -> success, changed, version pin invoked' {
    $script:MockConfig.ListExtensionsStdoutSequence = @("ms-python.python@2024.1.0`n", "ms-python.python@2024.5.0`n")
    $script:MockConfig.InstallResult = [PSCustomObject]@{ ExitCode = 0; Stdout = ''; Stderr = '' }
    $result = Invoke-SetVSCodeExtensionVersion (New-EncodedInput @{ extension_id = 'ms-python.python'; desired_version = '2024.5.0'; extension_path = $script:JdoePath } $false) | ConvertFrom-Json
    $target = $result.targets[0]
    $target.status | Should -Be 'success'
    $target.changed | Should -BeTrue
    $target.action | Should -Be 'set_version'
    $target.installed_version_before | Should -Be '2024.1.0'
    $target.installed_version_after | Should -Be '2024.5.0'
    $target.cli_result.Ok | Should -BeTrue
    # VS Code isn't "running" per the default mock (RunningPids empty) -
    # nothing to restart, so this must stay false.
    $target.vscode_restarted | Should -BeFalse
    # Base envelope fields mirror the target on success too.
    $result.status | Should -Be 'success'
    $result.changed | Should -BeTrue
    $result.error | Should -BeNullOrEmpty
  }

  It 'differing version, real run, VS Code already running -> restarts it, reports vscode_restarted true' {
    $script:MockConfig.ListExtensionsStdoutSequence = @("ms-python.python@2024.1.0`n", "ms-python.python@2024.5.0`n")
    $script:MockConfig.InstallResult = [PSCustomObject]@{ ExitCode = 0; Stdout = ''; Stderr = '' }
    $script:MockConfig.RunningPids = @(4242)
    $result = Invoke-SetVSCodeExtensionVersion (New-EncodedInput @{ extension_id = 'ms-python.python'; desired_version = '2024.5.0'; extension_path = $script:JdoePath } $false) | ConvertFrom-Json
    $target = $result.targets[0]
    $target.status | Should -Be 'success'
    $target.changed | Should -BeTrue
    $target.vscode_restarted | Should -BeTrue
    # Graceful close first (the default mock simulates it succeeding) -
    # Stop-Process is the last-resort fallback, not needed here.
    $script:GracefulCloseLog | Should -Be @(4242)
    $script:StopProcessLog.Count | Should -Be 0
  }

  It 'already at the target version (no change) -> never attempts a restart even if VS Code is running' {
    $script:MockConfig.ListExtensionsStdout = "ms-python.python@2024.1.0`n"
    $script:MockConfig.RunningPids = @(4242)
    $result = Invoke-SetVSCodeExtensionVersion (New-EncodedInput @{ extension_id = 'ms-python.python'; desired_version = '2024.1.0'; extension_path = $script:JdoePath } $false) | ConvertFrom-Json
    $target = $result.targets[0]
    $target.status | Should -Be 'skipped'
    $target.vscode_restarted | Should -BeFalse
    $script:StopProcessLog.Count | Should -Be 0
  }

  It 'dry run with a pending change -> never attempts a restart even if VS Code is running' {
    $script:MockConfig.ListExtensionsStdout = "ms-python.python@2024.1.0`n"
    $script:MockConfig.RunningPids = @(4242)
    $result = Invoke-SetVSCodeExtensionVersion (New-EncodedInput @{ extension_id = 'ms-python.python'; desired_version = '2024.5.0'; extension_path = $script:JdoePath } $true) | ConvertFrom-Json
    $target = $result.targets[0]
    $target.status | Should -Be 'skipped'
    $result.dry_run | Should -BeTrue
    $target.vscode_restarted | Should -BeFalse
    $script:StopProcessLog.Count | Should -Be 0
  }

  It 'differing version, CLI install fails -> failure envelope, stderr folded into the message (no stderr key on error)' {
    $script:MockConfig.ListExtensionsStdout = "ms-python.python@2024.1.0`n"
    $script:MockConfig.InstallResult = [PSCustomObject]@{ ExitCode = 1; Stdout = ''; Stderr = 'boom' }
    $result = Invoke-SetVSCodeExtensionVersion (New-EncodedInput @{ extension_id = 'ms-python.python'; desired_version = '2024.5.0'; extension_path = $script:JdoePath } $false) | ConvertFrom-Json
    $target = $result.targets[0]
    $target.status | Should -Be 'failure'
    $target.error.code | Should -Be 'UPGRADE_INCOMPLETE'
    $target.error.message | Should -BeLike '*boom*'
    ($target.error.PSObject.Properties.Name) | Should -Not -Contain 'stderr'
  }

  It 'dry run with a pending version change -> skipped, no CLI action attempted' {
    $script:MockConfig.ListExtensionsStdout = "ms-python.python@2024.1.0`n"
    $result = Invoke-SetVSCodeExtensionVersion (New-EncodedInput @{ extension_id = 'ms-python.python'; desired_version = '2024.5.0'; extension_path = $script:JdoePath } $true) | ConvertFrom-Json
    $target = $result.targets[0]
    $target.status | Should -Be 'skipped'
    $target.changed | Should -BeFalse
    $target.cli_result.attempted | Should -BeFalse
    $target.cli_result.dry_run | Should -BeTrue
  }

  It 'no desired_version given, extension already latest -> success, not changed' {
    $script:MockConfig.ListExtensionsStdout = "ms-python.python@2024.9.0`n" # same before and after
    $script:MockConfig.InstallResult = [PSCustomObject]@{ ExitCode = 0; Stdout = ''; Stderr = '' }
    $result = Invoke-SetVSCodeExtensionVersion (New-EncodedInput @{ extension_id = 'ms-python.python'; extension_path = $script:JdoePath } $false) | ConvertFrom-Json
    $target = $result.targets[0]
    $target.action | Should -Be 'upgrade_to_latest'
    $target.status | Should -Be 'success'
    $target.changed | Should -BeFalse
  }

  It 'extension_path names a user with no profile directory -> still proceeds, used_system_fallback true' {
    Mock Test-VSCodePathAccess { [PSCustomObject]@{ Exists = $false; AccessDenied = $false } }
    $script:MockConfig.ListExtensionsStdout = "ms-python.python@2024.1.0`n"
    $result = Invoke-SetVSCodeExtensionVersion (New-EncodedInput @{ extension_id = 'ms-python.python'; desired_version = '2024.1.0'; extension_path = $script:JdoePath } $true) | ConvertFrom-Json
    $target = $result.targets[0]
    $target.target_user | Should -Be 'jdoe'
    $target.used_system_fallback | Should -BeTrue
    $target.user_resolution_note | Should -Be 'EXTENSION_PATH_USER_NOT_FOUND'
    # And the CLI was pointed at SYSTEM's own extensions dir, not a real user's.
    $listCall = $script:CommandLog | Where-Object { $_.ArgumentList -contains '--list-extensions' } | Select-Object -First 1
    $listCall.ArgumentList[1] | Should -Be $Script:RootFallbackExtensionsDir
  }

  It 'missing extension_path -> still proceeds (SYSTEM fallback), never aborts' {
    $script:MockConfig.ListExtensionsStdout = "ms-python.python@2024.1.0`n"
    $result = Invoke-SetVSCodeExtensionVersion (New-EncodedInput @{ extension_id = 'ms-python.python'; desired_version = '2024.1.0' } $true) | ConvertFrom-Json
    $target = $result.targets[0]
    $target.target_user | Should -BeNullOrEmpty
    $target.used_system_fallback | Should -BeTrue
    $target.status | Should -Be 'skipped' # already at 2024.1.0
  }
}

Context 'ConvertTo-VSCodeCliResultJson / ConvertTo-VSCodeErrorJson' {
  It 'converts a dry-run action result to attempted/dry_run only' {
    $actionResult = [PSCustomObject]@{ Attempted = $false; DryRun = $true; Ok = $false; Stderr = '' }
    $json = ConvertTo-VSCodeCliResultJson $actionResult
    $json.attempted | Should -BeFalse
    $json.dry_run | Should -BeTrue
  }

  It 'converts a real action result to snake_case fields' {
    $actionResult = [PSCustomObject]@{ Attempted = $true; ExitCode = 1; Ok = $false; Stdout = 'out'; Stderr = 'err' }
    $json = ConvertTo-VSCodeCliResultJson $actionResult
    $json.exit_code | Should -Be 1
    $json.ok | Should -BeFalse
    $json.stdout | Should -Be 'out'
    $json.stderr | Should -Be 'err'
  }

  It 'returns $null for a $null action result' {
    ConvertTo-VSCodeCliResultJson $null | Should -BeNullOrEmpty
  }

  It 'converts an error result to lowercase code/message fields only - no stderr key (canonical envelope-level error shape)' {
    $errorResult = [PSCustomObject]@{ Code = 'BOOM'; Message = 'it broke' }
    $json = ConvertTo-VSCodeErrorJson $errorResult
    $json.code | Should -Be 'BOOM'
    $json.message | Should -Be 'it broke'
    ($json.PSObject.Properties.Name) | Should -Not -Contain 'stderr'
  }

  It 'returns $null for a $null error result' {
    ConvertTo-VSCodeErrorJson $null | Should -BeNullOrEmpty
  }
}

Context 'JSON envelope field casing (raw wire format, not just case-insensitive property access)' {
  # ConvertFrom-Json + PowerShell's case-insensitive member access would
  # mask a casing bug (e.g. "ExitCode" vs "exit_code" both read fine via
  # .ExitCode after deserializing, and PowerShell's -match is ALSO
  # case-insensitive by default, so a naive "Should -Not -Match '\"Ok\"'"
  # would false-fail against a correctly-lowercase '"ok":false' too) -
  # these tests inspect the raw JSON text for the exact expected substring,
  # which is sufficient to pin the wire schema without relying on a
  # case-sensitive negative match.
  It 'a real (non-dry-run) successful action serializes cli_result with snake_case keys, not PascalCase' {
    $script:MockConfig.ListExtensionsStdoutSequence = @("ms-python.python@2024.1.0`n", "ms-python.python@2024.5.0`n")
    $script:MockConfig.InstallResult = [PSCustomObject]@{ ExitCode = 0; Stdout = 'ok'; Stderr = '' }
    $rawJson = Invoke-SetVSCodeExtensionVersion (New-EncodedInput @{ extension_id = 'ms-python.python'; desired_version = '2024.5.0'; extension_path = $script:JdoePath } $false)
    $rawJson | Should -Match '"exit_code":0'
    $rawJson | Should -Match '"attempted":true'
    # Plain PowerShell -cmatch (case-SENSITIVE), not Pester's Should -Match
    # (which is case-insensitive) - needed here so "ok" in the correct
    # output can't be mistaken for a match against the wrong "Ok".
    ($rawJson -cmatch '"ok":true') | Should -BeTrue
    ($rawJson -cmatch '"Ok"') | Should -BeFalse
    ($rawJson -cmatch '"ExitCode"') | Should -BeFalse
    ($rawJson -cmatch '"Attempted"') | Should -BeFalse
  }

  It 'a dry-run action serializes cli_result as attempted/dry_run, not PascalCase' {
    $script:MockConfig.ListExtensionsStdout = "ms-python.python@2024.1.0`n"
    $rawJson = Invoke-SetVSCodeExtensionVersion (New-EncodedInput @{ extension_id = 'ms-python.python'; desired_version = '2024.5.0'; extension_path = $script:JdoePath } $true)
    $rawJson | Should -Match '"dry_run":true'
    ($rawJson -cmatch '"DryRun"') | Should -BeFalse
  }

  It 'a failed CLI action serializes error with lowercase code/message keys, no stderr key on the error object (cli_result.stderr is a different, unrelated field and legitimately still carries the raw text)' {
    $script:MockConfig.ListExtensionsStdout = "ms-python.python@2024.1.0`n"
    $script:MockConfig.InstallResult = [PSCustomObject]@{ ExitCode = 1; Stdout = ''; Stderr = 'boom' }
    $rawJson = Invoke-SetVSCodeExtensionVersion (New-EncodedInput @{ extension_id = 'ms-python.python'; desired_version = '2024.5.0'; extension_path = $script:JdoePath } $false)
    $rawJson | Should -Match '"code":"UPGRADE_INCOMPLETE"'
    $rawJson | Should -Match '"message":"[^"]*boom[^"]*"'
    ($rawJson -cmatch '"Code"') | Should -BeFalse
    ($rawJson -cmatch '"Message"') | Should -BeFalse
    # Check the ERROR object specifically (not a blanket string search over
    # the whole JSON) - cli_result.stderr is a separate, legitimate field
    # that DOES still carry "boom" in this exact scenario, so a bare
    # `-cmatch '"stderr":"boom"'` over the raw text would false-fail here.
    $parsed = $rawJson | ConvertFrom-Json
    $parsed.targets[0].error.PSObject.Properties.Name | Should -Not -Contain 'stderr'
    $parsed.error.PSObject.Properties.Name | Should -Not -Contain 'stderr'
    $parsed.targets[0].cli_result.stderr | Should -Be 'boom'
  }

  It 'per-target fields (extension_id etc) live in targets[], not flattened onto the envelope root - but base contract fields (status/changed/error) DO stay at the root too, per contract-standards.md' {
    $script:MockConfig.ListExtensionsStdout = "ms-python.python@2024.1.0`n"
    $result = Invoke-SetVSCodeExtensionVersion (New-EncodedInput @{ extension_id = 'ms-python.python'; desired_version = '2024.1.0'; extension_path = $script:JdoePath } $true) | ConvertFrom-Json
    $result.scope | Should -Be 'anchor'
    $result.targets.Count | Should -Be 1
    $result.targets[0].extension_id | Should -Be 'ms-python.python'
    # extension_id must NOT also appear flattened on the envelope root...
    $result.PSObject.Properties.Name | Should -Not -Contain 'extension_id'
    # ...but status/changed/error are the mandatory base envelope (every
    # script must satisfy it) and ARE required at the root, alongside
    # scope/targets[], not replaced by them.
    $result.PSObject.Properties.Name | Should -Contain 'status'
    $result.PSObject.Properties.Name | Should -Contain 'changed'
    $result.PSObject.Properties.Name | Should -Contain 'error'
    $result.status | Should -Be $result.targets[0].status
    $result.changed | Should -Be $result.targets[0].changed
  }
}
}

# A separate, sibling Describe (not nested inside the one above) so this
# one is NOT subject to that Describe's own BeforeEach, which mocks
# Resolve-VSCodeUserProfilePath itself for every other test in this file -
# this is the one place that function's REAL body actually runs. Its
# happy path (NTAccount.Translate + Get-CimInstance Win32_UserProfile)
# can't be meaningfully exercised here at all: NTAccount.Translate() is a
# .NET object method, not a PowerShell command, so Pester's Mock can't
# intercept it, and there's no real "jdoe" account on a test machine to
# translate anyway - this project's own Runner.Tests.ps1 header already
# documents mocking chained CIM calls as unreliable, so this doesn't
# attempt it. What IS both real and reliably testable: a nonexistent
# account genuinely fails NTAccount.Translate() (a real
# IdentityNotMappedException, not a mock), which is exactly the fallback
# path - so this exercises the real error handling for real, no mocking
# needed at all.
Describe 'Resolve-VSCodeUserProfilePath (real, unmocked)' {
  It 'falls back to the naive C:\Users\USERNAME guess when the account cannot be resolved via Win32_UserProfile' {
    Resolve-VSCodeUserProfilePath 'definitely-not-a-real-account-98765' | Should -Be 'C:\Users\definitely-not-a-real-account-98765'
  }
}

# Set-VSCodeFileContent is mocked away in every test in the main Describe
# above - its own [System.IO.File]::Replace-based atomic-write pattern
# (Test-VSCodeFileExists, Test-VSCodeFileExists again for the swap
# backup, ...) is never actually exercised there. Real, unmocked
# filesystem operations against a real temp directory, same rationale as
# the sibling Describe above.
Describe 'Set-VSCodeFileContent (real, unmocked)' {
  BeforeEach {
    $script:TestDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Path $script:TestDir -Force | Out-Null
    $script:TestPath = Join-Path $script:TestDir 'settings.json'
  }

  AfterEach {
    Remove-Item -LiteralPath $script:TestDir -Recurse -Force -ErrorAction SilentlyContinue
  }

  It 'writes a brand-new file (nothing to replace yet), UTF-8 with NO BOM, and leaves no stray temp files behind' {
    Set-VSCodeFileContent $script:TestPath '{"a":1}'
    Get-Content -LiteralPath $script:TestPath -Raw | Should -Be '{"a":1}'
    # @() wrap matters under real PS 5.1 - a bare Get-ChildItem result for
    # exactly one match is a scalar with no .Count property there (only
    # PS 7+ gives every scalar a universal Count) - confirmed live via a
    # real PropertyNotFoundException on real hardware before this fix.
    @(Get-ChildItem -Path $script:TestDir).Count | Should -Be 1
    $firstBytes = [System.IO.File]::ReadAllBytes($script:TestPath) | Select-Object -First 3
    # UTF-8 BOM is EF BB BF - Set-Content -Encoding utf8 would have
    # written it on PS 5.1; WriteAllText with an explicit no-BOM
    # UTF8Encoding must not.
    ($firstBytes[0] -eq 0xEF -and $firstBytes[1] -eq 0xBB -and $firstBytes[2] -eq 0xBF) | Should -BeFalse
  }

  It 'overwrites an existing file via File.Replace, UTF-8 with no BOM, and leaves no stray temp/netbak files behind' {
    Set-Content -LiteralPath $script:TestPath -Value '{"a":1}' -Encoding utf8
    Set-VSCodeFileContent $script:TestPath '{"a":2}'
    Get-Content -LiteralPath $script:TestPath -Raw | Should -Be '{"a":2}'
    @(Get-ChildItem -Path $script:TestDir).Count | Should -Be 1
    $firstBytes = [System.IO.File]::ReadAllBytes($script:TestPath) | Select-Object -First 3
    ($firstBytes[0] -eq 0xEF -and $firstBytes[1] -eq 0xBB -and $firstBytes[2] -eq 0xBF) | Should -BeFalse
  }

  It 'preserves the original file''s ACL across an overwrite (captured before, reapplied after)' {
    Set-Content -LiteralPath $script:TestPath -Value '{"a":1}' -Encoding utf8
    $originalAcl = Get-Acl -LiteralPath $script:TestPath
    Set-VSCodeFileContent $script:TestPath '{"a":2}'
    $newAcl = Get-Acl -LiteralPath $script:TestPath
    $newAcl.Owner | Should -Be $originalAcl.Owner
  }

  It 'a locked destination (simulated AV/Defender contention) is retried, then fails without leaving the original content missing or a stray netbak behind' {
    # -NoNewline matters here specifically: this test reads the ORIGINAL
    # content back at the end (the write is expected to fail and leave it
    # untouched) - Set-Content appends a trailing newline by default,
    # which would make a plain '{"a":1}' equality check false-fail
    # against the real file content otherwise. The other two setup calls
    # above don't need this - their content gets fully overwritten by a
    # successful Set-VSCodeFileContent call either way.
    Set-Content -LiteralPath $script:TestPath -Value '{"a":1}' -Encoding utf8 -NoNewline
    # [System.IO.File]::Replace is a static .NET method - Pester can't
    # mock it directly, so real contention is simulated with a real
    # exclusive file lock (FileShare.None) instead, held for the whole
    # call so both retry attempts genuinely fail with a sharing
    # violation. This exercises the real bounded-retry loop for real, and
    # confirms the one guarantee that matters even when both attempts
    # fail: the destination is never left missing (File.Replace itself
    # never gets far enough to touch it while the lock holds), and no
    # throwaway netbak is left stranded on disk afterward.
    $lockedStream = [System.IO.File]::Open($script:TestPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
    try {
      { Set-VSCodeFileContent $script:TestPath '{"a":2}' } | Should -Throw
    } finally {
      $lockedStream.Close()
    }
    Get-Content -LiteralPath $script:TestPath -Raw | Should -Be '{"a":1}'
    @(Get-ChildItem -Path $script:TestDir -Filter '*.glow-netbak').Count | Should -Be 0
    @(Get-ChildItem -Path $script:TestDir -Filter '*.glow-tmp').Count | Should -Be 0
  }
}

# Resolve-VSCodeSafePath is mocked away in every test in the main Describe
# above - its real ancestor-chain-walking behavior (the actual point of
# this fix: an ancestor DIRECTORY that's a reparse point, not just the
# leaf) needs a real junction on a real filesystem to mean anything.
# New-Item -ItemType Junction does not require elevation/Developer Mode
# on Windows (unlike -ItemType SymbolicLink), so this runs in an ordinary
# CI/test context.
Describe 'Resolve-VSCodeSafePath / ancestor-chain safety (real, unmocked)' {
  BeforeEach {
    $script:TestDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Path $script:TestDir -Force | Out-Null
  }

  AfterEach {
    Remove-Item -LiteralPath $script:TestDir -Recurse -Force -ErrorAction SilentlyContinue
  }

  It 'Test-VSCodeLocalDrive: the real system drive is not Network/CDRom -> true' {
    Test-VSCodeLocalDrive $script:TestDir | Should -BeTrue
  }

  It 'Test-VSCodeLocalDrive: a UNC-shaped path -> false (DriveInfo rejects a non-drive-letter root)' {
    Test-VSCodeLocalDrive '\\fileserver\share\extensions\foo-1.0.0' | Should -BeFalse
  }

  It 'Resolve-VSCodeSafePath: a real UNC path is rejected, but a \\?\-prefixed extended-length LOCAL path is not treated as UNC' {
    Resolve-VSCodeSafePath '\\fileserver\share\extensions\foo-1.0.0' | Should -BeNullOrEmpty
    $extendedPath = '\\?\' + (Join-Path $script:TestDir 'extensions\ms-python.python-2024.1.0')
    New-Item -ItemType Directory -Path (Join-Path $script:TestDir 'extensions\ms-python.python-2024.1.0') -Force | Out-Null
    Resolve-VSCodeSafePath $extendedPath | Should -Not -BeNullOrEmpty
  }

  It 'a clean nested path with no reparse points anywhere in its ancestry -> resolves normally' {
    $nested = Join-Path $script:TestDir 'real\extensions\ms-python.python-2024.1.0'
    New-Item -ItemType Directory -Path $nested -Force | Out-Null
    Test-VSCodeAncestorChainSafe $nested | Should -BeTrue
    Resolve-VSCodeSafePath $nested | Should -Be ([System.IO.Path]::GetFullPath($nested))
  }

  It 'a reparse point TWO LEVELS above the leaf (not the leaf itself) -> ancestor check catches it, ResolveVSCodeSafePath returns $null' {
    $realTarget = Join-Path $script:TestDir 'real-target'
    New-Item -ItemType Directory -Path $realTarget -Force | Out-Null
    $junctionLink = Join-Path $script:TestDir 'linked'
    New-Item -ItemType Junction -Path $junctionLink -Target $realTarget -Force | Out-Null
    $leafUnderJunction = Join-Path $junctionLink 'extensions\ms-python.python-2024.1.0'
    New-Item -ItemType Directory -Path (Join-Path $realTarget 'extensions\ms-python.python-2024.1.0') -Force | Out-Null

    # The leaf itself ($leafUnderJunction) is an ordinary directory, not a
    # reparse point - only its grandparent ($junctionLink) is. A guard
    # that only checked the leaf's own reparse point would miss this.
    Test-VSCodeAncestorChainSafe $leafUnderJunction | Should -BeFalse
    Resolve-VSCodeSafePath $leafUnderJunction | Should -BeNullOrEmpty
  }

  It 'a missing (nonexistent) ancestor is not itself unsafe - only a REAL reparse point is' {
    $neverCreated = Join-Path $script:TestDir 'does\not\exist\extensions\ms-python.python-2024.1.0'
    Test-VSCodeAncestorChainSafe $neverCreated | Should -BeTrue
  }
}

# Invoke-VSCodeNativeCommand is mocked away as the single seam in every
# other test in this file - its own real behavior (the file-redirection
# capture this function was rewritten to use, replacing the
# Register-ObjectEvent-based capture flagged as a real PowerShell-5.1
# host-crash risk - see this function's own FIX comment) is exercised
# here for real, against a real child process, on whatever real Windows
# box actually runs this suite. powershell.exe (not pwsh) is used as the
# real child target specifically because it's always present under real
# RTR's own runtime assumption (Windows PowerShell 5.1, no bundled pwsh
# dependency) - same reasoning this project already applies elsewhere for
# why the 5.1-specific bugs only ever surfaced via real hardware, not the
# pwsh-7-bootstrapped test path.
Describe 'Invoke-VSCodeNativeCommand (real, unmocked)' {
  BeforeAll {
    $script:RealPwshPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  }

  It 'captures stdout and stderr SEPARATELY (not merged) and the real exit code, for a real child process' {
    $result = Invoke-VSCodeNativeCommand -FilePath $script:RealPwshPath `
      -ArgumentList @('-NoProfile', '-Command', '[Console]::Error.WriteLine(''err-marker''); Write-Output ''out-marker''; exit 3') `
      -TimeoutSec 20
    $result.ExitCode | Should -Be 3
    $result.Stdout | Should -Match 'out-marker'
    $result.Stdout | Should -Not -Match 'err-marker'
    $result.Stderr | Should -Match 'err-marker'
    $result.Stderr | Should -Not -Match 'out-marker'
  }

  It 'an argument containing spaces round-trips correctly through the outer cmd.exe quote-wrap' {
    $result = Invoke-VSCodeNativeCommand -FilePath $script:RealPwshPath `
      -ArgumentList @('-NoProfile', '-Command', 'Write-Output ''hello world with spaces''') `
      -TimeoutSec 20
    $result.ExitCode | Should -Be 0
    $result.Stdout | Should -Match 'hello world with spaces'
  }

  It 'leaves no stray redirection temp files behind in $env:TEMP after a real run' {
    $before = @(Get-ChildItem -Path $env:TEMP -Filter 'glow_vscode_*' -ErrorAction SilentlyContinue).Count
    Invoke-VSCodeNativeCommand -FilePath $script:RealPwshPath -ArgumentList @('-NoProfile', '-Command', 'exit 0') -TimeoutSec 20 | Out-Null
    $after = @(Get-ChildItem -Path $env:TEMP -Filter 'glow_vscode_*' -ErrorAction SilentlyContinue).Count
    $after | Should -Be $before
  }
}
