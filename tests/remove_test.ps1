# Windows PowerShell 5.1 port of remove_test.sh: remove argument, failure-path
# and hold checks. Runs remove.ps1 as a child process with wt/fzf/herdr stubbed
# as .cmd shims; JSON payloads travel through files so cmd quoting can't mangle
# them.
$ErrorActionPreference = 'Continue'
# A test that throws must fail, not skip its remaining checks and report
# success: with no catch, an error inside try { } finally { } leaves the try
# and the script carries on to its "passed" line.
trap { [Console]::Error.WriteLine("test aborted: $_"); exit 1 }

$repoRoot = Split-Path -Parent $PSScriptRoot

function Fail([string]$Message) {
  [Console]::Error.WriteLine($Message)
  exit 1
}

$stubDir = Join-Path ([System.IO.Path]::GetTempPath()) ("wt-remove-test-" + [guid]::NewGuid().ToString('N'))
$configDir = Join-Path $stubDir 'config'
New-Item -ItemType Directory -Path $configDir | Out-Null
$origPath = $env:Path
try {
  $wtLog = Join-Path $stubDir 'wt.log'
  $herdrLog = Join-Path $stubDir 'herdr.log'
  $listFile = Join-Path $stubDir 'wt-list.json'
  $worktreeJson = Join-Path $stubDir 'worktrees.json'
  $workspaceJson = Join-Path $stubDir 'workspaces.json'
  $pickFile = Join-Path $stubDir 'fzf-pick.txt'
  $configFile = Join-Path $configDir 'config.toml'

  # Stand in for `wt`: list answers with one removable worktree, and remove
  # records its argv and fails when the test asks it to - or, with
  # $env:WT_STUB_REMOVE_DIR set, really deletes that directory, which Windows
  # refuses while any process has it as its working directory. The feature
  # worktree is a real directory: a failed removal only reopens the workspace
  # when the checkout still exists on disk.
  $fakeWt = Join-Path $stubDir 'repo.feature'
  New-Item -ItemType Directory -Path $fakeWt | Out-Null
  $fakeWtFwd = $fakeWt -replace '\\', '/'
  Set-Content -LiteralPath $listFile -Value (ConvertTo-Json -Compress -Depth 5 -InputObject @(
    @{ branch = 'main'; kind = 'worktree'; path = '/repo'; is_main = $true },
    @{ branch = 'feature'; kind = 'worktree'; path = $fakeWt; is_main = $false }
  ))
  Set-Content -LiteralPath (Join-Path $stubDir 'wt.cmd') -Value @(
    '@echo off',
    '>> "%WT_STUB_LOG%" echo %*',
    'if "%~1"=="list" (',
    'type "%WT_STUB_LIST_FILE%"',
    'exit /b 0',
    ')',
    'if not "%~1"=="remove" exit /b 0',
    'if defined WT_STUB_REMOVE_DIR rmdir "%WT_STUB_REMOVE_DIR%" || exit /b 1',
    'exit /b %WT_STUB_REMOVE_STATUS%'
  )

  # fzf picks whatever the pick file holds; the picker's stdin is drained either way.
  Set-Content -LiteralPath (Join-Path $stubDir 'fzf.cmd') -Value @(
    '@echo off',
    'findstr "^" > nul 2> nul',
    'type "%FZF_STUB_PICK_FILE%"',
    'exit /b 0'
  )

  # herdr also echoes its calls into the pane, so a message can be placed before
  # or after them. The feature workspace's label has the spaces and parentheses
  # the picker's "branch (typed)" labels carry.
  Set-Content -LiteralPath $worktreeJson -Value "{`"result`":{`"worktrees`":[{`"path`":`"$fakeWtFwd`",`"open_workspace_id`":`"ws-feature`"}]}}"
  $workspaceListJson = '{"result":{"workspaces":[{"workspace_id":"ws-main","label":"repo"},{"workspace_id":"ws-feature","label":"feature (pr:16)"}]}}'
  Set-Content -LiteralPath $workspaceJson -Value $workspaceListJson
  Set-Content -LiteralPath (Join-Path $stubDir 'herdr.cmd') -Value @(
    '@echo off',
    'if "%~1 %~2"=="worktree list" (',
    'type "%HERDR_WORKTREE_JSON%"',
    'exit /b 0',
    ')',
    'if "%~1 %~2"=="workspace list" (',
    'type "%HERDR_WORKSPACE_JSON%"',
    'exit /b 0',
    ')',
    '>> "%HERDR_STUB_LOG%" echo %*',
    'echo %*',
    'exit /b 0'
  )

  $env:Path = "$stubDir;$origPath"
  $env:WORKTRUNK_BIN = Join-Path $stubDir 'wt.cmd'
  $env:WT_STUB_LOG = $wtLog
  $env:WT_STUB_LIST_FILE = $listFile
  $env:WT_STUB_REMOVE_STATUS = '0'
  $env:HERDR_BIN_PATH = Join-Path $stubDir 'herdr.cmd'
  $env:HERDR_WORKTREE_JSON = $worktreeJson
  $env:HERDR_WORKSPACE_JSON = $workspaceJson
  $env:HERDR_STUB_LOG = $herdrLog
  $env:HERDR_PLUGIN_ROOT = $repoRoot
  $env:HERDR_PLUGIN_CONFIG_DIR = $configDir
  $env:FZF_STUB_PICK_FILE = $pickFile

  # Run remove.ps1 with the config already in place; the wt and herdr logs then
  # expose what each was asked to do, and $paneOut what the pane showed,
  # flattened to one line so a pattern can span the order things were shown in.
  $script:paneOut = ''
  function Invoke-Remove {
    Set-Content -LiteralPath $env:WT_STUB_LOG -Value $null
    Set-Content -LiteralPath $env:HERDR_STUB_LOG -Value $null
    # Empty pipeline input closes the child's stdin (the bash test's </dev/null),
    # so a "press any key" read returns at once.
    $out = @() | & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot 'remove.ps1') 2>&1
    $script:paneOut = (@($out) -join ' ') -replace '\s+', ' '
  }

  function Get-LogLines([string]$Log) {
    return @(Get-Content -LiteralPath $Log -ErrorAction SilentlyContinue | Where-Object { $_ -ne '' })
  }
  function Assert-Log([string]$Label, [string]$Expected, [string]$Log) {
    if (@(Get-LogLines $Log) -cnotcontains $Expected) {
      Fail "expected $Label call '$Expected', got:`n$(@(Get-LogLines $Log) -join "`n")"
    }
  }
  # Matches on the start of a recorded argv.
  function Refute-Log([string]$Label, [string]$Unexpected, [string]$Log) {
    foreach ($line in (Get-LogLines $Log)) {
      if ($line.StartsWith($Unexpected)) {
        Fail "unexpected $Label call '$Unexpected' in:`n$(@(Get-LogLines $Log) -join "`n")"
      }
    }
  }
  function Assert-Pane([string]$Pattern) {
    if ($script:paneOut -cnotmatch $Pattern) { Fail "expected pane output matching '$Pattern', got:`n$script:paneOut" }
  }
  function Refute-Pane([string]$Pattern) {
    if ($script:paneOut -cmatch $Pattern) { Fail "unexpected pane output matching '$Pattern' in:`n$script:paneOut" }
  }

  # Remove the picked worktree in the foreground, from the main worktree so
  # worktrunk has no directory change to warn about. The workspace closes first
  # (Windows can't delete a process's cwd), and nothing waits for a key.
  Set-Content -LiteralPath $configFile -Value $null
  Set-Content -LiteralPath $pickFile -Value 'feature'
  Invoke-Remove
  Assert-Log wt 'remove --foreground -C /repo feature' $wtLog
  Assert-Log herdr 'workspace close ws-feature' $herdrLog
  Refute-Log herdr 'worktree open' $herdrLog
  Refute-Pane 'press any key to continue'

  # Cancelling the picker touches nothing.
  Set-Content -LiteralPath $pickFile -Value $null
  Invoke-Remove
  Refute-Log wt 'remove' $wtLog
  Refute-Log herdr 'workspace close' $herdrLog
  Set-Content -LiteralPath $pickFile -Value 'feature'

  # A failed removal reopens the workspace the guarded remove closed up front -
  # it still holds the worktree.
  $env:WT_STUB_REMOVE_STATUS = '1'
  Invoke-Remove
  Assert-Pane 'wt remove failed \(see above\)\.'
  $reopened = @(Get-LogLines $herdrLog) | Where-Object { $_ -clike "worktree open*--path $fakeWt*--no-focus*" }
  if (-not $reopened) {
    Fail "expected the workspace to be reopened after a failed removal, got:`n$(@(Get-LogLines $herdrLog) -join "`n")"
  }

  # It comes back under the label it had rather than herdr's default. The
  # stub's %* keeps the quotes PowerShell puts around an argument with spaces,
  # so the label shows up quoted - as the one argument it is.
  $relabeled = @(Get-LogLines $herdrLog) | Where-Object { $_ -clike "worktree open*--label `"feature (pr:16)`" --no-focus*" }
  if (-not $relabeled) {
    Fail "expected the reopened workspace to keep its label, got:`n$(@(Get-LogLines $herdrLog) -join "`n")"
  }

  # With no label to restore, --label is left out entirely: an empty value
  # would vanish from the argv and leave the flag swallowing --no-focus.
  Set-Content -LiteralPath $workspaceJson -Value '{"result":{"workspaces":[]}}'
  Invoke-Remove
  $reopened = @(Get-LogLines $herdrLog) | Where-Object { $_ -clike "worktree open*--path $fakeWt --no-focus" }
  if (-not $reopened) {
    Fail "expected a reopen without --label when the label is unknown, got:`n$(@(Get-LogLines $herdrLog) -join "`n")"
  }
  Set-Content -LiteralPath $workspaceJson -Value $workspaceListJson
  $env:WT_STUB_REMOVE_STATUS = '0'

  # hold_on_remove keeps the pane up after a successful removal. The worktree's
  # workspace has already closed by then...
  Set-Content -LiteralPath $configFile -Value 'hold_on_remove = true'
  Invoke-Remove
  Assert-Pane 'workspace close ws-feature.*removed feature\..*press any key to continue'

  # ...unless the action runs inside that workspace: closing it ends the pane,
  # so there the hold comes first.
  $env:HERDR_WORKSPACE_ID = 'ws-feature'
  Invoke-Remove
  Assert-Pane 'removed feature\..*press any key to continue.*workspace close ws-feature'
  Remove-Item Env:\HERDR_WORKSPACE_ID -ErrorAction SilentlyContinue

  # hold_on_success covers the removal as well, unless hold_on_remove says otherwise.
  Set-Content -LiteralPath $configFile -Value 'hold_on_success = true'
  Invoke-Remove
  Assert-Pane 'removed feature\.'

  Set-Content -LiteralPath $configFile -Value @('hold_on_success = true', 'hold_on_remove = false')
  Invoke-Remove
  Refute-Pane 'press any key to continue'
  Assert-Log herdr 'workspace close ws-feature' $herdrLog

  # A failure keeps its own message whatever the hold settings say.
  Set-Content -LiteralPath $configFile -Value 'hold_on_success = true'
  $env:WT_STUB_REMOVE_STATUS = '1'
  Invoke-Remove
  Assert-Pane 'wt remove failed \(see above\)\.'
  Refute-Pane 'removed feature'
  $env:WT_STUB_REMOVE_STATUS = '0'
  Set-Content -LiteralPath $configFile -Value $null

  # Run from inside the worktree it removes - a pane in that worktree's own
  # workspace - the script has to let go of the directory before worktrunk
  # deletes it: not just PowerShell's location, but the process's working
  # directory, which is what Windows locks. Last, since the checkout goes away.
  $fakeMain = Join-Path $stubDir 'repo'
  New-Item -ItemType Directory -Path $fakeMain | Out-Null
  Set-Content -LiteralPath $listFile -Value (ConvertTo-Json -Compress -Depth 5 -InputObject @(
    @{ branch = 'main'; kind = 'worktree'; path = $fakeMain; is_main = $true },
    @{ branch = 'feature'; kind = 'worktree'; path = $fakeWt; is_main = $false }
  ))
  $env:WT_STUB_REMOVE_DIR = $fakeWt
  $env:HERDR_WORKSPACE_ID = 'ws-feature'
  Push-Location -LiteralPath $fakeWt
  try { Invoke-Remove } finally { Pop-Location }
  Remove-Item Env:\WT_STUB_REMOVE_DIR, Env:\HERDR_WORKSPACE_ID -ErrorAction SilentlyContinue
  Assert-Log wt "remove --foreground -C $fakeMain feature" $wtLog
  if (Test-Path -LiteralPath $fakeWt) {
    Fail "expected the worktree to be deletable once the script stepped out of it; pane showed:`n$script:paneOut"
  }
  Assert-Log herdr 'workspace close ws-feature' $herdrLog
} finally {
  $env:Path = $origPath
  foreach ($name in 'WORKTRUNK_BIN', 'WT_STUB_LOG', 'WT_STUB_LIST_FILE', 'WT_STUB_REMOVE_STATUS',
                    'HERDR_BIN_PATH', 'HERDR_WORKTREE_JSON', 'HERDR_WORKSPACE_JSON', 'HERDR_STUB_LOG',
                    'HERDR_PLUGIN_ROOT', 'HERDR_PLUGIN_CONFIG_DIR', 'HERDR_WORKSPACE_ID', 'FZF_STUB_PICK_FILE',
                    'WT_STUB_REMOVE_DIR') {
    Remove-Item "Env:\$name" -ErrorAction SilentlyContinue
  }
  Remove-Item -Recurse -Force -LiteralPath $stubDir -ErrorAction SilentlyContinue
}

Write-Output 'remove tests passed'
exit 0
