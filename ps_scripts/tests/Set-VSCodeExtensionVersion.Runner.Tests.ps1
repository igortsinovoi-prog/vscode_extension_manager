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
    Mock New-VSCodeDirectoryIfMissing { }
    Mock Get-VSCodeFileContent { $null }
    Mock Set-VSCodeFileContent { }
    Mock Remove-VSCodeFileIfExists { }

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
    Mock Test-VSCodeDirectoryExists { $false }
    $result = Resolve-VSCodeTargetUser $script:JdoePath 'ms-python.python'
    $result.User | Should -Be 'jdoe'
    $result.ExtensionsDir | Should -Be $Script:RootFallbackExtensionsDir
    $result.ResolutionNote | Should -Be 'EXTENSION_PATH_USER_NOT_FOUND'
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
    $state.BackupPath | Should -Be 'C:\Users\jdoe\AppData\Roaming\Code\User\settings.json.rwcbak'
    # Two calls so far: the real on-disk backup (exact original raw text)
    # and the bypassed settings.json.
    Should -Invoke Set-VSCodeFileContent -Times 1 -ParameterFilter { $Path -eq $state.BackupPath -and $Content -eq $originalRaw }
    Should -Invoke Set-VSCodeFileContent -Times 1 -ParameterFilter {
      $Content -match '"editor.fontSize":\s*14' -and $Content -match '"extensions.verifySignature":\s*false'
    }

    Restore-VSCodeSignatureVerification $state
    # Now three total: the two above, plus the restore write - the
    # backup and the restore both legitimately have the same content
    # (the exact original raw text), so two calls now match that filter.
    Should -Invoke Set-VSCodeFileContent -Times 2 -ParameterFilter { $Content -eq $originalRaw }
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

  It 'running -> stops the process, then registers/starts/unregisters a one-shot interactive Scheduled Task pointed at Code.exe' {
    $script:MockConfig.RunningPids = @(4242)
    $result = Restart-VSCodeIfRunning 'jdoe' 'C:\Program Files\Microsoft VS Code\bin\code.cmd'
    $result | Should -BeTrue
    $script:StopProcessLog | Should -Be @(4242)

    ($script:ScheduledTaskLog | Select-Object -ExpandProperty Event) | Should -Be @('register', 'start', 'unregister')
    $registerEntry = $script:ScheduledTaskLog | Where-Object { $_.Event -eq 'register' }
    $registerEntry.Action.Execute | Should -Be 'C:\Program Files\Microsoft VS Code\Code.exe'
    $registerEntry.Principal.UserId | Should -Be 'jdoe'
    $registerEntry.Principal.LogonType | Should -Be 'Interactive'
  }
}

Context 'Invoke-SetVSCodeExtensionVersion end-to-end' {
  It 'invalid extension_id -> failure envelope, INVALID_PARAMS' {
    $result = Invoke-SetVSCodeExtensionVersion (New-EncodedInput @{ extension_id = 'not-an-id' } $true) | ConvertFrom-Json
    $result.status | Should -Be 'failure'
    $result.error.code | Should -Be 'INVALID_PARAMS'
  }

  It 'invalid version -> failure envelope, INVALID_PARAMS' {
    $result = Invoke-SetVSCodeExtensionVersion (New-EncodedInput @{ extension_id = 'ms-python.python'; version = 'not-semver' } $true) | ConvertFrom-Json
    $result.status | Should -Be 'failure'
    $result.error.code | Should -Be 'INVALID_PARAMS'
  }

  It 'code.cmd not found anywhere -> failure envelope, VSCODE_NOT_INSTALLED' {
    Mock Test-VSCodeFileExists { $false }
    $result = Invoke-SetVSCodeExtensionVersion (New-EncodedInput @{ extension_id = 'ms-python.python'; extension_path = $script:JdoePath } $true) | ConvertFrom-Json
    $result.status | Should -Be 'failure'
    $result.error.code | Should -Be 'VSCODE_NOT_INSTALLED'
  }

  It 'code --list-extensions itself fails -> failure envelope, LIST_EXTENSIONS_FAILED' {
    $script:MockConfig.ListExtensionsExitCode = 1
    $result = Invoke-SetVSCodeExtensionVersion (New-EncodedInput @{ extension_id = 'ms-python.python'; version = '2024.1.0'; extension_path = $script:JdoePath } $true) | ConvertFrom-Json
    $result.status | Should -Be 'failure'
    $result.error.code | Should -Be 'LIST_EXTENSIONS_FAILED'
  }

  It 'extension not installed -> skipped, no CLI action taken' {
    $script:MockConfig.ListExtensionsStdout = "some-other.extension@1.0.0`n"
    $result = Invoke-SetVSCodeExtensionVersion (New-EncodedInput @{ extension_id = 'ms-python.python'; version = '2024.1.0'; extension_path = $script:JdoePath } $true) | ConvertFrom-Json
    $result.status | Should -Be 'skipped'
    $result.changed | Should -BeFalse
    $result.action | Should -Be 'not_installed'
    $result.cli_result | Should -BeNullOrEmpty
  }

  It 'already at the target version -> skipped, no CLI action taken' {
    $script:MockConfig.ListExtensionsStdout = "ms-python.python@2024.1.0`n"
    $result = Invoke-SetVSCodeExtensionVersion (New-EncodedInput @{ extension_id = 'ms-python.python'; version = '2024.1.0'; extension_path = $script:JdoePath } $true) | ConvertFrom-Json
    $result.status | Should -Be 'skipped'
    $result.action | Should -Be 'already_correct_version'
  }

  It 'differing version, real run -> success, changed, version pin invoked' {
    $script:MockConfig.ListExtensionsStdoutSequence = @("ms-python.python@2024.1.0`n", "ms-python.python@2024.5.0`n")
    $script:MockConfig.InstallResult = [PSCustomObject]@{ ExitCode = 0; Stdout = ''; Stderr = '' }
    $result = Invoke-SetVSCodeExtensionVersion (New-EncodedInput @{ extension_id = 'ms-python.python'; version = '2024.5.0'; extension_path = $script:JdoePath } $false) | ConvertFrom-Json
    $result.status | Should -Be 'success'
    $result.changed | Should -BeTrue
    $result.action | Should -Be 'set_version'
    $result.installed_version_before | Should -Be '2024.1.0'
    $result.installed_version_after | Should -Be '2024.5.0'
    $result.cli_result.Ok | Should -BeTrue
    # VS Code isn't "running" per the default mock (RunningPids empty) -
    # nothing to restart, so this must stay false.
    $result.vscode_restarted | Should -BeFalse
  }

  It 'differing version, real run, VS Code already running -> restarts it, reports vscode_restarted true' {
    $script:MockConfig.ListExtensionsStdoutSequence = @("ms-python.python@2024.1.0`n", "ms-python.python@2024.5.0`n")
    $script:MockConfig.InstallResult = [PSCustomObject]@{ ExitCode = 0; Stdout = ''; Stderr = '' }
    $script:MockConfig.RunningPids = @(4242)
    $result = Invoke-SetVSCodeExtensionVersion (New-EncodedInput @{ extension_id = 'ms-python.python'; version = '2024.5.0'; extension_path = $script:JdoePath } $false) | ConvertFrom-Json
    $result.status | Should -Be 'success'
    $result.changed | Should -BeTrue
    $result.vscode_restarted | Should -BeTrue
    $script:StopProcessLog | Should -Be @(4242)
  }

  It 'already at the target version (no change) -> never attempts a restart even if VS Code is running' {
    $script:MockConfig.ListExtensionsStdout = "ms-python.python@2024.1.0`n"
    $script:MockConfig.RunningPids = @(4242)
    $result = Invoke-SetVSCodeExtensionVersion (New-EncodedInput @{ extension_id = 'ms-python.python'; version = '2024.1.0'; extension_path = $script:JdoePath } $false) | ConvertFrom-Json
    $result.status | Should -Be 'skipped'
    $result.vscode_restarted | Should -BeFalse
    $script:StopProcessLog.Count | Should -Be 0
  }

  It 'dry run with a pending change -> never attempts a restart even if VS Code is running' {
    $script:MockConfig.ListExtensionsStdout = "ms-python.python@2024.1.0`n"
    $script:MockConfig.RunningPids = @(4242)
    $result = Invoke-SetVSCodeExtensionVersion (New-EncodedInput @{ extension_id = 'ms-python.python'; version = '2024.5.0'; extension_path = $script:JdoePath } $true) | ConvertFrom-Json
    $result.status | Should -Be 'skipped'
    $result.dry_run | Should -BeTrue
    $result.vscode_restarted | Should -BeFalse
    $script:StopProcessLog.Count | Should -Be 0
  }

  It 'differing version, CLI install fails -> failure envelope' {
    $script:MockConfig.ListExtensionsStdout = "ms-python.python@2024.1.0`n"
    $script:MockConfig.InstallResult = [PSCustomObject]@{ ExitCode = 1; Stdout = ''; Stderr = 'boom' }
    $result = Invoke-SetVSCodeExtensionVersion (New-EncodedInput @{ extension_id = 'ms-python.python'; version = '2024.5.0'; extension_path = $script:JdoePath } $false) | ConvertFrom-Json
    $result.status | Should -Be 'failure'
    $result.error.code | Should -Be 'EXTENSION_VERSION_CHANGE_FAILED'
    $result.error.stderr | Should -Be 'boom'
  }

  It 'dry run with a pending version change -> skipped, no CLI action attempted' {
    $script:MockConfig.ListExtensionsStdout = "ms-python.python@2024.1.0`n"
    $result = Invoke-SetVSCodeExtensionVersion (New-EncodedInput @{ extension_id = 'ms-python.python'; version = '2024.5.0'; extension_path = $script:JdoePath } $true) | ConvertFrom-Json
    $result.status | Should -Be 'skipped'
    $result.changed | Should -BeFalse
    $result.cli_result.attempted | Should -BeFalse
    $result.cli_result.dry_run | Should -BeTrue
  }

  It 'no version given, extension already latest -> success, not changed' {
    $script:MockConfig.ListExtensionsStdout = "ms-python.python@2024.9.0`n" # same before and after
    $script:MockConfig.InstallResult = [PSCustomObject]@{ ExitCode = 0; Stdout = ''; Stderr = '' }
    $result = Invoke-SetVSCodeExtensionVersion (New-EncodedInput @{ extension_id = 'ms-python.python'; extension_path = $script:JdoePath } $false) | ConvertFrom-Json
    $result.action | Should -Be 'upgrade_to_latest'
    $result.status | Should -Be 'success'
    $result.changed | Should -BeFalse
  }

  It 'extension_path names a user with no profile directory -> still proceeds, ran_as_root true' {
    Mock Test-VSCodeDirectoryExists { $false }
    $script:MockConfig.ListExtensionsStdout = "ms-python.python@2024.1.0`n"
    $result = Invoke-SetVSCodeExtensionVersion (New-EncodedInput @{ extension_id = 'ms-python.python'; version = '2024.1.0'; extension_path = $script:JdoePath } $true) | ConvertFrom-Json
    $result.target_user | Should -Be 'jdoe'
    $result.ran_as_root | Should -BeTrue
    $result.user_resolution_note | Should -Be 'EXTENSION_PATH_USER_NOT_FOUND'
    # And the CLI was pointed at SYSTEM's own extensions dir, not a real user's.
    $listCall = $script:CommandLog | Where-Object { $_.ArgumentList -contains '--list-extensions' } | Select-Object -First 1
    $listCall.ArgumentList[1] | Should -Be $Script:RootFallbackExtensionsDir
  }

  It 'missing extension_path -> still proceeds (SYSTEM fallback), never aborts' {
    $script:MockConfig.ListExtensionsStdout = "ms-python.python@2024.1.0`n"
    $result = Invoke-SetVSCodeExtensionVersion (New-EncodedInput @{ extension_id = 'ms-python.python'; version = '2024.1.0' } $true) | ConvertFrom-Json
    $result.target_user | Should -BeNullOrEmpty
    $result.ran_as_root | Should -BeTrue
    $result.status | Should -Be 'skipped' # already at 2024.1.0
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

  It 'converts an error result to lowercase code/message/stderr fields' {
    $errorResult = [PSCustomObject]@{ Code = 'BOOM'; Message = 'it broke'; Stderr = 'trace' }
    $json = ConvertTo-VSCodeErrorJson $errorResult
    $json.code | Should -Be 'BOOM'
    $json.message | Should -Be 'it broke'
    $json.stderr | Should -Be 'trace'
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
    $rawJson = Invoke-SetVSCodeExtensionVersion (New-EncodedInput @{ extension_id = 'ms-python.python'; version = '2024.5.0'; extension_path = $script:JdoePath } $false)
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
    $rawJson = Invoke-SetVSCodeExtensionVersion (New-EncodedInput @{ extension_id = 'ms-python.python'; version = '2024.5.0'; extension_path = $script:JdoePath } $true)
    $rawJson | Should -Match '"dry_run":true'
    ($rawJson -cmatch '"DryRun"') | Should -BeFalse
  }

  It 'a failed CLI action serializes error with lowercase code/message/stderr keys' {
    $script:MockConfig.ListExtensionsStdout = "ms-python.python@2024.1.0`n"
    $script:MockConfig.InstallResult = [PSCustomObject]@{ ExitCode = 1; Stdout = ''; Stderr = 'boom' }
    $rawJson = Invoke-SetVSCodeExtensionVersion (New-EncodedInput @{ extension_id = 'ms-python.python'; version = '2024.5.0'; extension_path = $script:JdoePath } $false)
    $rawJson | Should -Match '"code":"EXTENSION_VERSION_CHANGE_FAILED"'
    $rawJson | Should -Match '"stderr":"boom"'
    ($rawJson -cmatch '"Code"') | Should -BeFalse
    ($rawJson -cmatch '"Message"') | Should -BeFalse
  }
}
}
