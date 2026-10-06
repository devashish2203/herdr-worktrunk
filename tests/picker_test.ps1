# Windows PowerShell 5.1 port of picker_test.sh: picker argument checks against
# a real git repo, with wt/fzf/herdr stubbed as .cmd shims.
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

$stubDir = Join-Path ([System.IO.Path]::GetTempPath()) ("wt-picker-test-" + [guid]::NewGuid().ToString('N'))
$workDir = Join-Path ([System.IO.Path]::GetTempPath()) ("wt-picker-work-" + [guid]::NewGuid().ToString('N'))
$configDir = Join-Path $stubDir 'config'
New-Item -ItemType Directory -Path $configDir | Out-Null
New-Item -ItemType Directory -Path $workDir | Out-Null
$origPath = $env:Path
try {
  # A real repo: picker.ps1 lists refs with `git for-each-ref` and helpers.ps1
  # resolves existing branches with `git show-ref`, so git is never stubbed.
  $repo = Join-Path $workDir 'repo'
  git init --quiet --initial-branch=main $repo
  git -C $repo -c user.email=t@example.com -c user.name=test commit --quiet --allow-empty -m init
  git -C $repo branch silas/foo-bar

  # fzf stub: records the candidate list and its argv, then replays the output
  # the real picker would produce for the scripted keypress.
  Set-Content -LiteralPath (Join-Path $stubDir 'fzf.cmd') -Value @(
    '@echo off',
    'findstr "^" > "%STUB_DIR%\fzf.stdin"',
    '> "%STUB_DIR%\fzf.args" echo %*',
    'type "%FZF_STUB_OUT_FILE%"',
    'exit /b %FZF_STUB_EXIT%'
  )

  # wt stub: `list` feeds the picker, `switch` records the argv under test and
  # answers with the switch result file (see Set-SwitchResult) - or fails when
  # $env:WT_STUB_SWITCH_STATUS asks. PR-42 next to pr-42 checks that dedup keeps
  # branches that differ only in case - they are distinct git refs.
  $listFile = Join-Path $stubDir 'wt-list.json'
  Set-Content -LiteralPath $listFile -Value '[{"branch":"silas/foo-bar","path":"/tmp/a","kind":"worktree"},{"branch":"pr-42","path":"/tmp/b","kind":"worktree"},{"branch":"PR-42","path":"/tmp/c","kind":"worktree"}]'
  $switchJson = Join-Path $stubDir 'wt-switch.json'
  @{ branch = 'x'; path = (Join-Path $stubDir 'checkout') } | ConvertTo-Json -Compress |
    Set-Content -LiteralPath $switchJson
  Set-Content -LiteralPath (Join-Path $stubDir 'wt.cmd') -Value @(
    '@echo off',
    'if "%~1"=="list" (',
    'type "%WT_STUB_LIST_FILE%"',
    'exit /b 0',
    ')',
    '> "%STUB_DIR%\wt.args" echo %*',
    'if not "%WT_STUB_SWITCH_STATUS%"=="0" exit /b %WT_STUB_SWITCH_STATUS%',
    'type "%WT_STUB_SWITCH_JSON%"',
    'exit /b 0'
  )

  # herdr stub: `worktree list` locates the repo root, `worktree open` is the
  # result, echoed into the pane too so a message can be placed before or after
  # it. In tab mode `tab create` answers with a pane, and `pane run` records the
  # line typed into it. Labels instead of ( ) blocks: the recorded argv may hold
  # parentheses.
  $worktreeJson = Join-Path $stubDir 'worktrees.json'
  @{ result = @{ source = @{ repo_root = $repo; repo_name = 'repo'; source_workspace_id = 'w1' } } } |
    ConvertTo-Json -Compress -Depth 5 | Set-Content -LiteralPath $worktreeJson
  $tabJson = Join-Path $stubDir 'tab.json'
  Set-Content -LiteralPath $tabJson -Value '{"result":{"root_pane":{"pane_id":"p5","tab_id":"t5"}}}'
  Set-Content -LiteralPath (Join-Path $stubDir 'herdr.cmd') -Value @(
    '@echo off',
    'if "%~1 %~2"=="worktree list" goto worktreelist',
    '>> "%STUB_DIR%\herdr.args" echo %*',
    'if "%~1 %~2"=="tab create" goto tabcreate',
    'echo %*',
    'exit /b 0',
    ':worktreelist',
    'type "%HERDR_WORKTREE_JSON%"',
    'exit /b 0',
    ':tabcreate',
    'type "%HERDR_TAB_JSON%"',
    'exit /b 0'
  )

  $env:Path = "$stubDir;$origPath"
  $env:STUB_DIR = $stubDir
  $env:WT_STUB_LIST_FILE = $listFile
  $env:WT_STUB_SWITCH_JSON = $switchJson
  $env:HERDR_WORKTREE_JSON = $worktreeJson
  $env:HERDR_TAB_JSON = $tabJson
  $env:WT_STUB_SWITCH_STATUS = '0'
  $env:WORKTRUNK_BIN = Join-Path $stubDir 'wt.cmd'
  $env:HERDR_PLUGIN_ROOT = $repoRoot
  $env:HERDR_BIN_PATH = Join-Path $stubDir 'herdr.cmd'
  $env:HERDR_PLUGIN_CONFIG_DIR = $configDir
  $env:HERDR_WORKSPACE_ID = 'w1'
  $outFile = Join-Path $stubDir 'fzf-out.txt'
  $env:FZF_STUB_OUT_FILE = $outFile
  $configFile = Join-Path $configDir 'config.toml'

  # What `wt switch` answers, as worktrunk does: ACTION says whether it
  # `created` the worktree or switched to an `existing` one.
  function Set-SwitchResult([string]$Action, [string]$Branch) {
    @{ action = $Action; branch = $Branch; path = (Join-Path $stubDir 'checkout') } |
      ConvertTo-Json -Compress | Set-Content -LiteralPath $switchJson
  }

  # Run picker.ps1 with the scripted fzf result. $pickerExit then holds its exit
  # code and $paneOut what the pane showed, flattened to one line so a pattern
  # can span the order things were shown in.
  $script:paneOut = ''
  $script:pickerExit = 0
  function Invoke-Picker([string[]]$FzfOut, [string]$FzfExit, [string[]]$Extra = @()) {
    $extra = @($Extra)
    Remove-Item (Join-Path $stubDir 'wt.args'), (Join-Path $stubDir 'herdr.args') -ErrorAction SilentlyContinue
    Set-Content -LiteralPath $outFile -Value $FzfOut
    $env:FZF_STUB_EXIT = $FzfExit
    Push-Location $repo
    # Empty pipeline input closes the child's stdin so failure paths that read
    # a key can never block the test run.
    try {
      $out = @() | & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot 'picker.ps1') @extra 2>&1
      $script:pickerExit = $LASTEXITCODE
      $script:paneOut = (@($out) -join ' ') -replace '\s+', ' '
    } finally { Pop-Location }
  }

  function Get-WtArgs {
    $line = Get-Content -LiteralPath (Join-Path $stubDir 'wt.args') -ErrorAction SilentlyContinue
    return [string]@($line)[0]
  }

  function Get-HerdrArgs {
    return (@(Get-Content -LiteralPath (Join-Path $stubDir 'herdr.args') -ErrorAction SilentlyContinue) -join "`n")
  }

  function Assert-Eq($Expected, $Actual, $What = 'value') {
    if ([string]$Actual -cne [string]$Expected) {
      Fail "expected $What '$Expected', got '$Actual'"
    }
  }
  function Assert-Contains([string]$Needle, [string]$Haystack, [string]$What = 'output') {
    if (-not $Haystack.Contains($Needle)) { Fail "expected '$Needle' in $What '$Haystack'" }
  }
  function Refute-Contains([string]$Needle, [string]$Haystack, [string]$What = 'output') {
    if ($Haystack.Contains($Needle)) { Fail "unexpected '$Needle' in $What '$Haystack'" }
  }
  function Assert-Pane([string]$Pattern) {
    if ($script:paneOut -cnotmatch $Pattern) { Fail "expected pane output matching '$Pattern', got:`n$script:paneOut" }
  }
  function Refute-Pane([string]$Pattern) {
    if ($script:paneOut -cmatch $Pattern) { Fail "unexpected pane output matching '$Pattern' in:`n$script:paneOut" }
  }

  # Plain enter on a match switches to the match, not to the query.
  Invoke-Picker @('silas/foo', 'silas/foo-bar') '0'
  Assert-Eq 'switch silas/foo-bar --no-cd --format=json' (Get-WtArgs) 'wt argv'

  # Plain enter with nothing matched creates the typed name (fzf exits 1).
  Invoke-Picker @('silas/brand-new') '1'
  Assert-Eq 'switch --create silas/brand-new --no-cd --format=json' (Get-WtArgs) 'wt argv'

  # alt-enter prints the query alone, so the typed name is created even though
  # the list had a fuzzy match highlighted.
  Invoke-Picker @('silas/foo') '0'
  Assert-Eq 'switch --create silas/foo --no-cd --format=json' (Get-WtArgs) 'wt argv'

  # ...and the base is carried through when creating from the current branch.
  Invoke-Picker @('silas/foo') '0' @('--create-base=current')
  Assert-Eq 'switch --create silas/foo --base @ --no-cd --format=json' (Get-WtArgs) 'wt argv'

  # A name that is an existing branch is switched to, never created: worktrunk
  # checks out existing refs and --create would fail.
  Invoke-Picker @('silas/foo-bar') '0'
  Assert-Eq 'switch silas/foo-bar --no-cd --format=json' (Get-WtArgs) 'wt argv'

  # esc cancels without touching worktrunk.
  Invoke-Picker @() '130'
  Assert-Eq '' (Get-WtArgs) 'wt argv'

  # The binding the header advertises is the one fzf is asked for.
  $fzfArgs = (Get-Content -LiteralPath (Join-Path $stubDir 'fzf.args') -ErrorAction SilentlyContinue) -join ' '
  if ($fzfArgs -notlike '*--bind=alt-enter:print-query*') {
    Fail "expected --bind=alt-enter:print-query in fzf argv '$fzfArgs'"
  }

  # Refs are offered before the slow `wt list` source and deduped without
  # sorting, so the picker fills in before worktrunk has finished stat-ing
  # every checkout.
  $stdin = @(Get-Content -LiteralPath (Join-Path $stubDir 'fzf.stdin') -ErrorAction SilentlyContinue) -join "`n"
  Assert-Eq "main`nsilas/foo-bar`npr-42`nPR-42" $stdin 'candidate list'

  # A new name is created as typed by default...
  Invoke-Picker @('optimize Stripe loading waterfall') '1'
  Assert-Eq 'switch --create "optimize Stripe loading waterfall" --no-cd --format=json' (Get-WtArgs) 'wt argv'

  # ...and slugified with slugify_new_branches, keeping the base.
  Set-Content -LiteralPath $configFile -Value 'slugify_new_branches = true'
  Invoke-Picker @('optimize Stripe loading waterfall') '1'
  Assert-Eq 'switch --create optimize-stripe-loading-waterfall --no-cd --format=json' (Get-WtArgs) 'wt argv'
  Assert-Contains 'worktree open ' (Get-HerdrArgs) 'herdr calls'
  Invoke-Picker @('Silas / Brand New') '1' @('--create-base=current')
  Assert-Eq 'switch --create silas/brand-new --base @ --no-cd --format=json' (Get-WtArgs) 'wt argv'

  # A slug that names an existing branch switches to it.
  Invoke-Picker @('Silas / Foo Bar') '1'
  Assert-Eq 'switch silas/foo-bar --no-cd --format=json' (Get-WtArgs) 'wt argv'

  # Existing branches and shortcuts are left alone.
  Invoke-Picker @('silas/foo-bar') '0'
  Assert-Eq 'switch silas/foo-bar --no-cd --format=json' (Get-WtArgs) 'wt argv'
  Invoke-Picker @('pr:16') '1'
  Assert-Eq 'switch pr:16 --no-cd --format=json' (Get-WtArgs) 'wt argv'

  # No valid name left fails before wt runs.
  Invoke-Picker @('!!!') '1'
  if ($script:pickerExit -eq 0) { Fail 'expected picker.ps1 to fail when no branch name is left' }
  Assert-Pane 'no valid branch name in: !!!'
  Assert-Eq '' (Get-WtArgs) 'wt argv'
  Refute-Contains 'worktree open ' (Get-HerdrArgs) 'herdr calls'

  # Tab mode uses the slug too.
  Set-Content -LiteralPath $configFile -Value @('slugify_new_branches = true', 'open_mode = "tab"')
  Invoke-Picker @('Optimize Stripe') '1'
  Assert-Contains '--label optimize-stripe ' (Get-HerdrArgs) 'tab create argv'
  Assert-Contains "switch --create 'optimize-stripe' --no-cd --format=json" (Get-HerdrArgs) 'pane run line'
  Set-Content -LiteralPath $configFile -Value $null

  # A created worktree opens its workspace without waiting.
  Set-SwitchResult 'created' 'silas/brand-new'
  Invoke-Picker @('silas/brand-new') '1'
  Refute-Pane 'press any key to continue'
  Assert-Contains 'worktree open ' (Get-HerdrArgs) 'herdr calls'

  # hold_on_create keeps the pane up once worktrunk has created the worktree, and
  # asks for the key before the workspace opens and takes the focus away.
  Set-Content -LiteralPath $configFile -Value 'hold_on_create = true'
  Invoke-Picker @('silas/brand-new') '1'
  Assert-Pane 'created worktree silas/brand-new\..*press any key to continue.*worktree open '
  Assert-Contains 'worktree open ' (Get-HerdrArgs) 'herdr calls'

  # Switching to a worktree that already exists has nothing to read, so it never holds.
  Set-SwitchResult 'existing' 'silas/foo-bar'
  Invoke-Picker @('silas/foo-bar') '0'
  Refute-Pane 'press any key to continue'
  Assert-Contains 'worktree open ' (Get-HerdrArgs) 'herdr calls'

  # hold_on_success covers creation as well, unless hold_on_create says otherwise.
  Set-SwitchResult 'created' 'silas/brand-new'
  Set-Content -LiteralPath $configFile -Value 'hold_on_success = true'
  Invoke-Picker @('silas/brand-new') '1'
  Assert-Pane 'created worktree silas/brand-new\.'

  Set-Content -LiteralPath $configFile -Value @('hold_on_success = true', 'hold_on_create = false')
  Invoke-Picker @('silas/brand-new') '1'
  Refute-Pane 'press any key to continue'

  # A failure keeps its own message whatever the hold settings say.
  Set-Content -LiteralPath $configFile -Value 'hold_on_success = true'
  $env:WT_STUB_SWITCH_STATUS = '1'
  Invoke-Picker @('silas/brand-new') '1'
  if ($script:pickerExit -eq 0) { Fail 'expected picker.ps1 to fail when wt switch does' }
  Assert-Pane 'wt switch failed \(see above\)\.'
  Refute-Pane 'created worktree'
  Refute-Contains 'worktree open ' (Get-HerdrArgs) 'herdr calls'
  $env:WT_STUB_SWITCH_STATUS = '0'

  # wt's output lands in the tab the user keeps, so tab mode has nothing to hold for.
  Set-Content -LiteralPath $configFile -Value @('open_mode = "tab"', 'hold_on_create = true')
  Invoke-Picker @('silas/brand-new') '1'
  Refute-Pane 'press any key to continue'
  Assert-Contains 'pane run p5 ' (Get-HerdrArgs) 'herdr calls'
  Set-Content -LiteralPath $configFile -Value $null
} finally {
  $env:Path = $origPath
  foreach ($name in 'STUB_DIR', 'WT_STUB_LIST_FILE', 'WT_STUB_SWITCH_JSON', 'WT_STUB_SWITCH_STATUS',
                    'HERDR_WORKTREE_JSON', 'HERDR_TAB_JSON',
                    'WORKTRUNK_BIN', 'HERDR_PLUGIN_ROOT', 'HERDR_BIN_PATH', 'HERDR_PLUGIN_CONFIG_DIR',
                    'HERDR_WORKSPACE_ID', 'FZF_STUB_OUT_FILE', 'FZF_STUB_EXIT') {
    Remove-Item "Env:\$name" -ErrorAction SilentlyContinue
  }
  Remove-Item -Recurse -Force -LiteralPath $stubDir, $workDir -ErrorAction SilentlyContinue
}

Write-Output 'picker tests passed'
exit 0
