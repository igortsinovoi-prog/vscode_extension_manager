BeforeAll {
  . "$PSScriptRoot/../lib/Set-VSCodeExtensionVersion.Policy.ps1"
}

Describe 'Test-VSCodeExtensionId' {
  It 'accepts well-formed publisher.name ids' {
    Test-VSCodeExtensionId 'ms-python.python' | Should -BeTrue
    Test-VSCodeExtensionId 'GitHub.copilot' | Should -BeTrue
  }

  It 'rejects malformed or non-string ids' {
    Test-VSCodeExtensionId '' | Should -BeFalse
    Test-VSCodeExtensionId 'noDotAtAll' | Should -BeFalse
    Test-VSCodeExtensionId $null | Should -BeFalse
    Test-VSCodeExtensionId 123 | Should -BeFalse
  }
}

Describe 'Test-VSCodeExtensionVersion' {
  It 'treats $null as valid (means "latest")' {
    Test-VSCodeExtensionVersion $null | Should -BeTrue
  }

  It 'accepts semver, including pre-release/build suffixes' {
    Test-VSCodeExtensionVersion '1.2.3' | Should -BeTrue
    Test-VSCodeExtensionVersion '1.2.3-beta.1' | Should -BeTrue
    Test-VSCodeExtensionVersion '1.2.3+build.5' | Should -BeTrue
  }

  It 'rejects malformed version strings' {
    Test-VSCodeExtensionVersion '1.2' | Should -BeFalse
    Test-VSCodeExtensionVersion 'abc' | Should -BeFalse
    Test-VSCodeExtensionVersion '' | Should -BeFalse
  }

  It 'rejects non-string, non-null input' {
    Test-VSCodeExtensionVersion 123 | Should -BeFalse
    Test-VSCodeExtensionVersion @{} | Should -BeFalse
  }
}

Describe 'ConvertFrom-VSCodeInstalledExtensionsList' {
  It 'parses one id@version per line' {
    $raw = "ms-python.python@2024.1.0`nGitHub.copilot@1.150.0`n"
    $result = ConvertFrom-VSCodeInstalledExtensionsList $raw
    $result['ms-python.python'] | Should -Be '2024.1.0'
    $result['github.copilot'] | Should -Be '1.150.0'
    $result.Count | Should -Be 2
  }

  It 'lowercases ids for case-insensitive lookup' {
    $result = ConvertFrom-VSCodeInstalledExtensionsList 'GitHub.Copilot@1.0.0'
    $result['github.copilot'] | Should -Be '1.0.0'
    $result.Count | Should -Be 1
  }

  It 'handles CRLF line endings and blank lines' {
    $raw = "ms-python.python@2024.1.0`r`n`r`nGitHub.copilot@1.150.0`r`n"
    $result = ConvertFrom-VSCodeInstalledExtensionsList $raw
    $result['ms-python.python'] | Should -Be '2024.1.0'
    $result['github.copilot'] | Should -Be '1.150.0'
    $result.Count | Should -Be 2
  }

  It 'ignores malformed lines' {
    $raw = @(
      'not-a-valid-line-at-all',
      '@missing-id',
      'missing-version@',
      'bad_id.format@1.0.0',
      'ms-python.python@not-a-version',
      'ms-python.python@2024.1.0'
    ) -join "`n"
    $result = ConvertFrom-VSCodeInstalledExtensionsList $raw
    $result.Count | Should -Be 1
    $result['ms-python.python'] | Should -Be '2024.1.0'
  }

  It 'returns an empty hashtable for non-string input' {
    (ConvertFrom-VSCodeInstalledExtensionsList $null).Count | Should -Be 0
    (ConvertFrom-VSCodeInstalledExtensionsList 123).Count | Should -Be 0
  }

  It 'returns an empty hashtable for empty output' {
    (ConvertFrom-VSCodeInstalledExtensionsList '').Count | Should -Be 0
  }
}

Describe 'Get-VSCodeExtensionPathUser' {
  It 'extracts the user from a well-formed extension dir path' {
    $result = Get-VSCodeExtensionPathUser 'C:\Users\jdoe\.vscode\extensions\ms-python.python-2024.1.0' 'ms-python.python'
    $result.Ok | Should -BeTrue
    $result.User | Should -Be 'jdoe'
  }

  It 'accepts a path to a file within the extension dir' {
    $result = Get-VSCodeExtensionPathUser 'C:\Users\jdoe\.vscode\extensions\ms-python.python-2024.1.0\package.json' 'ms-python.python'
    $result.Ok | Should -BeTrue
    $result.User | Should -Be 'jdoe'
  }

  It 'matches the extension id case-insensitively' {
    $result = Get-VSCodeExtensionPathUser 'C:\Users\jdoe\.vscode\extensions\MS-Python.Python-2024.1.0' 'ms-python.python'
    $result.Ok | Should -BeTrue
    $result.User | Should -Be 'jdoe'
  }

  It 'matches the drive letter case-insensitively' {
    $result = Get-VSCodeExtensionPathUser 'c:\users\jdoe\.vscode\extensions\ms-python.python-2024.1.0' 'ms-python.python'
    $result.Ok | Should -BeTrue
    $result.User | Should -Be 'jdoe'
  }

  It 'rejects a missing path' {
    (Get-VSCodeExtensionPathUser $null 'ms-python.python').Error | Should -Be 'MISSING_EXTENSION_PATH'
    (Get-VSCodeExtensionPathUser '' 'ms-python.python').Error | Should -Be 'MISSING_EXTENSION_PATH'
  }

  It 'rejects path traversal and control characters' {
    (Get-VSCodeExtensionPathUser 'C:\Users\jdoe\.vscode\extensions\..\..\Windows\System32' 'ms-python.python').Error |
      Should -Be 'INVALID_EXTENSION_PATH'
    (Get-VSCodeExtensionPathUser "C:\Users\jdoe\.vscode\extensions\ms-python.python-1.0.0`0" 'ms-python.python').Error |
      Should -Be 'INVALID_EXTENSION_PATH'
  }

  It 'rejects paths outside the expected shape' {
    (Get-VSCodeExtensionPathUser 'C:\ProgramData\Glow\foo' 'ms-python.python').Error | Should -Be 'INVALID_EXTENSION_PATH'
    (Get-VSCodeExtensionPathUser 'C:\Users\jdoe\Documents\notes.txt' 'ms-python.python').Error | Should -Be 'INVALID_EXTENSION_PATH'
  }

  It 'rejects a username with unexpected characters (e.g. a space)' {
    (Get-VSCodeExtensionPathUser 'C:\Users\j doe\.vscode\extensions\ms-python.python-2024.1.0' 'ms-python.python').Error |
      Should -Be 'INVALID_EXTENSION_PATH'
  }

  It 'rejects a path whose leaf does not match the claimed extension id' {
    (Get-VSCodeExtensionPathUser 'C:\Users\jdoe\.vscode\extensions\some-other.extension-1.0.0' 'ms-python.python').Error |
      Should -Be 'EXTENSION_PATH_ID_MISMATCH'
  }
}

Describe 'Get-VSCodeVersionAction' {
  It 'returns not_installed regardless of target version when not installed' {
    (Get-VSCodeVersionAction @{} 'ms-python.python' '2024.1.0').Action | Should -Be 'not_installed'
    (Get-VSCodeVersionAction @{} 'ms-python.python' $null).Action | Should -Be 'not_installed'
  }

  It 'returns upgrade_to_latest when installed with no target version' {
    $installed = @{ 'ms-python.python' = '2024.1.0' }
    $result = Get-VSCodeVersionAction $installed 'ms-python.python' $null
    $result.Action | Should -Be 'upgrade_to_latest'
    $result.InstalledVersion | Should -Be '2024.1.0'
  }

  It 'returns already_correct_version when installed at the target version' {
    $installed = @{ 'ms-python.python' = '2024.1.0' }
    $result = Get-VSCodeVersionAction $installed 'ms-python.python' '2024.1.0'
    $result.Action | Should -Be 'already_correct_version'
    $result.InstalledVersion | Should -Be '2024.1.0'
  }

  It 'returns set_version when installed at a newer version than target (downgrade)' {
    $installed = @{ 'ms-python.python' = '2024.5.0' }
    $result = Get-VSCodeVersionAction $installed 'ms-python.python' '2024.1.0'
    $result.Action | Should -Be 'set_version'
    $result.InstalledVersion | Should -Be '2024.5.0'
  }

  It 'returns set_version when installed at an older version than target (upgrade)' {
    $installed = @{ 'ms-python.python' = '2024.1.0' }
    $result = Get-VSCodeVersionAction $installed 'ms-python.python' '2024.5.0'
    $result.Action | Should -Be 'set_version'
    $result.InstalledVersion | Should -Be '2024.1.0'
  }

  It 'looks up the extension id case-insensitively' {
    $installed = @{ 'ms-python.python' = '2024.1.0' }
    $result = Get-VSCodeVersionAction $installed 'MS-Python.Python' '2024.1.0'
    $result.Action | Should -Be 'already_correct_version'
  }

  It 'tolerates a $null installed-extensions map' {
    (Get-VSCodeVersionAction $null 'ms-python.python' '2024.1.0').Action | Should -Be 'not_installed'
  }
}

Describe 'Get-VSCodeRunOutcome' {
  It 'not_installed -> skipped, unchanged, no error' {
    $decision = [PSCustomObject]@{ Action = 'not_installed'; InstalledVersion = $null }
    $outcome = Get-VSCodeRunOutcome $decision $null $null $false
    $outcome.Status | Should -Be 'skipped'
    $outcome.Changed | Should -BeFalse
    $outcome.Error | Should -BeNullOrEmpty
  }

  It 'already_correct_version -> skipped, unchanged, no error' {
    $decision = [PSCustomObject]@{ Action = 'already_correct_version'; InstalledVersion = '2024.1.0' }
    $outcome = Get-VSCodeRunOutcome $decision $null '2024.1.0' $false
    $outcome.Status | Should -Be 'skipped'
    $outcome.Changed | Should -BeFalse
  }

  It 'set_version succeeds and the version actually changed -> success, changed' {
    $decision = [PSCustomObject]@{ Action = 'set_version'; InstalledVersion = '2024.1.0' }
    $actionResult = [PSCustomObject]@{ Attempted = $true; Ok = $true; Stderr = '' }
    $outcome = Get-VSCodeRunOutcome $decision $actionResult '2024.5.0' $false
    $outcome.Status | Should -Be 'success'
    $outcome.Changed | Should -BeTrue
  }

  It 'set_version succeeds but the version is unchanged -> success, not changed' {
    $decision = [PSCustomObject]@{ Action = 'set_version'; InstalledVersion = '2024.1.0' }
    $actionResult = [PSCustomObject]@{ Attempted = $true; Ok = $true; Stderr = '' }
    $outcome = Get-VSCodeRunOutcome $decision $actionResult '2024.1.0' $false
    $outcome.Status | Should -Be 'success'
    $outcome.Changed | Should -BeFalse
  }

  It 'set_version fails -> failure, with stderr in the error' {
    $decision = [PSCustomObject]@{ Action = 'set_version'; InstalledVersion = '2024.1.0' }
    $actionResult = [PSCustomObject]@{ Attempted = $true; Ok = $false; Stderr = 'network error' }
    $outcome = Get-VSCodeRunOutcome $decision $actionResult $null $false
    $outcome.Status | Should -Be 'failure'
    $outcome.Changed | Should -BeFalse
    $outcome.Error.Code | Should -Be 'EXTENSION_VERSION_CHANGE_FAILED'
    $outcome.Error.Stderr | Should -Be 'network error'
  }

  It 'set_version fails with no stderr -> error.Stderr defaults to empty string' {
    $decision = [PSCustomObject]@{ Action = 'set_version'; InstalledVersion = '2024.1.0' }
    $actionResult = [PSCustomObject]@{ Attempted = $true; Ok = $false }
    $outcome = Get-VSCodeRunOutcome $decision $actionResult $null $false
    $outcome.Error.Stderr | Should -Be ''
  }

  It 'upgrade_to_latest succeeds and version changed -> success, changed' {
    $decision = [PSCustomObject]@{ Action = 'upgrade_to_latest'; InstalledVersion = '2024.1.0' }
    $actionResult = [PSCustomObject]@{ Attempted = $true; Ok = $true; Stderr = '' }
    $outcome = Get-VSCodeRunOutcome $decision $actionResult '2024.9.0' $false
    $outcome.Status | Should -Be 'success'
    $outcome.Changed | Should -BeTrue
  }

  It 'upgrade_to_latest succeeds but was already latest -> success, not changed' {
    $decision = [PSCustomObject]@{ Action = 'upgrade_to_latest'; InstalledVersion = '2024.9.0' }
    $actionResult = [PSCustomObject]@{ Attempted = $true; Ok = $true; Stderr = '' }
    $outcome = Get-VSCodeRunOutcome $decision $actionResult '2024.9.0' $false
    $outcome.Status | Should -Be 'success'
    $outcome.Changed | Should -BeFalse
  }

  It 'upgrade_to_latest fails -> failure' {
    $decision = [PSCustomObject]@{ Action = 'upgrade_to_latest'; InstalledVersion = '2024.1.0' }
    $actionResult = [PSCustomObject]@{ Attempted = $true; Ok = $false; Stderr = 'boom' }
    (Get-VSCodeRunOutcome $decision $actionResult $null $false).Status | Should -Be 'failure'
  }

  It 'dry run with a pending set_version -> skipped, not changed, no error' {
    $decision = [PSCustomObject]@{ Action = 'set_version'; InstalledVersion = '2024.1.0' }
    $actionResult = [PSCustomObject]@{ Attempted = $false }
    $outcome = Get-VSCodeRunOutcome $decision $actionResult '2024.1.0' $true
    $outcome.Status | Should -Be 'skipped'
    $outcome.Changed | Should -BeFalse
  }

  It 'dry run with a pending upgrade_to_latest -> skipped, not changed, no error' {
    $decision = [PSCustomObject]@{ Action = 'upgrade_to_latest'; InstalledVersion = '2024.1.0' }
    $actionResult = [PSCustomObject]@{ Attempted = $false }
    $outcome = Get-VSCodeRunOutcome $decision $actionResult '2024.1.0' $true
    $outcome.Status | Should -Be 'skipped'
    $outcome.Changed | Should -BeFalse
  }
}
