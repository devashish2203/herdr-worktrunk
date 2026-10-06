# Windows PowerShell 5.1 port of lifecycle_test.sh: candidate/workspace
# resolution and cleanup checks, plus Windows path-mixing cases.
$ErrorActionPreference = 'Continue'
# A test that throws must fail, not skip its remaining checks and report
# success: with no catch, an error inside try { } finally { } leaves the try
# and the script carries on to its "passed" line.
trap { [Console]::Error.WriteLine("test aborted: $_"); exit 1 }

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'config.ps1')
. (Join-Path $repoRoot 'helpers.ps1')
. (Join-Path $repoRoot 'lifecycle.ps1')

function Fail([string]$Message) {
  [Console]::Error.WriteLine($Message)
  exit 1
}

$stubDir = Join-Path ([System.IO.Path]::GetTempPath()) ("wt-lifecycle-test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stubDir | Out-Null
try {
  $items = @(Get-WorktrunkListItems @'
[
  {"branch":"main","kind":"worktree","path":"/repo","is_main":true},
  {"branch":"feature","kind":"worktree","path":"/repo.feature","is_main":false},
  {"branch":null,"kind":"worktree","path":"/repo.detached","is_main":false},
  {"branch":"ready","kind":"branch"}
]
'@)

  # The main worktree and branches without a worktree are never candidates.
  $branches = Get-WorktrunkWorktreeBranches $items
  if (($branches -join ' ') -cne 'feature') {
    Fail "expected only feature as a candidate, got '$($branches -join ' ')'"
  }

  $path = Get-WorktrunkWorktreePath $items 'feature'
  if ($path -cne '/repo.feature') { Fail "expected /repo.feature, got '$path'" }

  # The removal runs from the main worktree, wherever the pane happens to be.
  $mainPath = Get-WorktrunkMainPath $items
  if ($mainPath -cne '/repo') { Fail "expected /repo as the main worktree, got '$mainPath'" }

  # Stand in for the herdr binary: `worktree list` answers with one open
  # workspace, `workspace list` with that workspace's label and another's,
  # `pane list` with panes inside and outside the worktree, and everything else
  # records the argv it was called with.
  $worktreeJson = Join-Path $stubDir 'worktrees.json'
  $workspaceJson = Join-Path $stubDir 'workspaces.json'
  $paneJson = Join-Path $stubDir 'panes.json'
  $stubLog = Join-Path $stubDir 'log'
  Set-Content -LiteralPath $worktreeJson -Value @'
{"result":{"worktrees":[
  {"path":"/repo.feature","open_workspace_id":"ws-feature"},
  {"path":"/repo.other"}
]}}
'@
  Set-Content -LiteralPath $workspaceJson -Value @'
{"result":{"workspaces":[
  {"workspace_id":"ws-main","label":"repo"},
  {"workspace_id":"ws-feature","label":"feature (pr:16)"}
]}}
'@
  Set-Content -LiteralPath $paneJson -Value @'
{"result":{"panes":[
  {"pane_id":"p-self","cwd":"/repo.feature"},
  {"pane_id":"p-in","cwd":"/repo.feature/sub"},
  {"pane_id":"p-out","cwd":"/repo"}
]}}
'@
  $herdrStub = Join-Path $stubDir 'herdr.cmd'
  Set-Content -LiteralPath $herdrStub -Value @(
    '@echo off',
    'if "%~1 %~2"=="worktree list" (',
    'type "%HERDR_WORKTREE_JSON%"',
    'exit /b 0',
    ')',
    'if "%~1 %~2"=="workspace list" (',
    'type "%HERDR_WORKSPACE_JSON%"',
    'exit /b 0',
    ')',
    'if "%~1 %~2"=="pane list" (',
    'type "%HERDR_PANE_JSON%"',
    'exit /b 0',
    ')',
    '>> "%HERDR_STUB_LOG%" echo %*',
    'exit /b 0'
  )
  $env:HERDR_BIN_PATH = $herdrStub
  $env:HERDR_WORKTREE_JSON = $worktreeJson
  $env:HERDR_WORKSPACE_JSON = $workspaceJson
  $env:HERDR_PANE_JSON = $paneJson
  $env:HERDR_STUB_LOG = $stubLog
  Set-Content -LiteralPath $stubLog -Value $null

  function Get-WtStubLog {
    $lines = @(Get-Content -LiteralPath $env:HERDR_STUB_LOG -ErrorAction SilentlyContinue | Where-Object { $_ -ne '' })
    return ($lines -join "`n")
  }
  function Clear-WtStubLog { Set-Content -LiteralPath $env:HERDR_STUB_LOG -Value $null }

  $wsid = Get-WorktrunkOpenWorkspaceId '/repo.feature'
  if ($wsid -cne 'ws-feature') { Fail "expected workspace ws-feature, got '$wsid'" }

  # A worktree herdr has no workspace open on resolves to nothing, not an error.
  if (Get-WorktrunkOpenWorkspaceId '/repo.other') { Fail 'expected no workspace id for /repo.other' }

  # The label a failed removal reopens the workspace under, spaces and all; an
  # unknown workspace or unreadable output has none, rather than an error.
  $label = Get-WorktrunkWorkspaceLabel 'ws-feature'
  if ($label -cne 'feature (pr:16)') { Fail "expected label 'feature (pr:16)', got '$label'" }
  $label = Get-WorktrunkWorkspaceLabel 'ws-gone'
  if ($label -cne '') { Fail "expected no label for an unknown workspace, got '$label'" }
  Set-Content -LiteralPath $workspaceJson -Value 'not json'
  $label = Get-WorktrunkWorkspaceLabel 'ws-feature'
  if ($label -cne '') { Fail "expected no label from unparseable output, got '$label'" }

  # A native workspace closes as a unit; its panes are not closed individually.
  Close-WorktrunkWorktreeUi 'ws-feature' '/repo.feature'
  if ((Get-WtStubLog) -cne 'workspace close ws-feature') { Fail "unexpected close calls:`n$(Get-WtStubLog)" }

  # Without a workspace, panes under the worktree are closed - except the caller's.
  Clear-WtStubLog
  $env:HERDR_PANE_ID = 'p-self'
  Close-WorktrunkWorktreeUi '' '/repo.feature'
  $env:HERDR_PANE_ID = $null
  if ((Get-WtStubLog) -cne 'pane close p-in') { Fail "unexpected pane close calls:`n$(Get-WtStubLog)" }

  # "/" would match every pane's cwd, so it is refused outright - and so are the
  # Windows drive-root shapes.
  foreach ($root in @('/', 'C:\', 'C:')) {
    Clear-WtStubLog
    Close-WorktrunkWorktreeUi '' $root
    if (Get-WtStubLog) { Fail "expected no close calls for '$root', got:`n$(Get-WtStubLog)" }
  }

  # Windows: herdr reports forward-slash paths while worktrunk hands the caller
  # native separators; resolution and cleanup still have to line up.
  Set-Content -LiteralPath $worktreeJson -Value '{"result":{"worktrees":[{"path":"C:/x/repo.feature","open_workspace_id":"ws-win"}]}}'
  $wsid = Get-WorktrunkOpenWorkspaceId 'C:\x\repo.feature'
  if ($wsid -cne 'ws-win') { Fail "expected ws-win for a mixed-separator path, got '$wsid'" }

  Set-Content -LiteralPath $paneJson -Value '{"result":{"panes":[{"pane_id":"p-win","cwd":"C:\\x\\repo.feature\\sub"},{"pane_id":"p-other","cwd":"C:\\x\\repo.featurette"}]}}'
  Clear-WtStubLog
  Close-WorktrunkWorktreeUi '' 'C:/x/repo.feature'
  if ((Get-WtStubLog) -cne 'pane close p-win') { Fail "unexpected mixed-separator pane close calls:`n$(Get-WtStubLog)" }

  # A worktree on a network share: herdr and worktrunk can each hand over the
  # \\?\UNC\, \\server or //server form, and resolution and cleanup still have
  # to line up.
  Set-Content -LiteralPath $worktreeJson -Value '{"result":{"worktrees":[{"path":"//server/share/repo.feature","open_workspace_id":"ws-unc"}]}}'
  $wsid = Get-WorktrunkOpenWorkspaceId '\\?\UNC\server\share\repo.feature'
  if ($wsid -cne 'ws-unc') { Fail "expected ws-unc for an extended-length UNC path, got '$wsid'" }

  Set-Content -LiteralPath $paneJson -Value '{"result":{"panes":[{"pane_id":"p-unc","cwd":"\\\\?\\UNC\\server\\share\\repo.feature\\sub"},{"pane_id":"p-unc-other","cwd":"\\\\server\\share\\repo.featurette"},{"pane_id":"p-unc-share","cwd":"\\\\server\\share2\\repo.feature"}]}}'
  Clear-WtStubLog
  Close-WorktrunkWorktreeUi '' '\\server\share\repo.feature'
  if ((Get-WtStubLog) -cne 'pane close p-unc') { Fail "unexpected UNC pane close calls:`n$(Get-WtStubLog)" }

  # A bare server or share is a root like "/": it would match every pane on the
  # share, so it is refused outright in every UNC form.
  foreach ($root in @('\\server\share', '//server/share/', '\\?\UNC\server\share\', '\\server')) {
    Clear-WtStubLog
    Close-WorktrunkWorktreeUi '' $root
    if (Get-WtStubLog) { Fail "expected no close calls for '$root', got:`n$(Get-WtStubLog)" }
  }
} finally {
  $env:HERDR_BIN_PATH = $null
  $env:HERDR_WORKTREE_JSON = $null
  $env:HERDR_WORKSPACE_JSON = $null
  $env:HERDR_PANE_JSON = $null
  $env:HERDR_STUB_LOG = $null
  Remove-Item -Recurse -Force -LiteralPath $stubDir -ErrorAction SilentlyContinue
}

Write-Output 'lifecycle tests passed'
exit 0
