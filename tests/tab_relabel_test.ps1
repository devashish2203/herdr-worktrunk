# Windows PowerShell 5.1 port of tab_relabel_test.sh: the deferred tab label
# against a real git repo, with herdr stubbed as a .cmd shim. tab-relabel.ps1
# runs as its own process, the way picker.ps1's tab command starts it.
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

$stubDir = Join-Path ([System.IO.Path]::GetTempPath()) ("wt-relabel-test-" + [guid]::NewGuid().ToString('N'))
$workDir = Join-Path ([System.IO.Path]::GetTempPath()) ("wt-relabel-work-" + [guid]::NewGuid().ToString('N'))
$configDir = Join-Path $stubDir 'config'
New-Item -ItemType Directory -Path $configDir | Out-Null
New-Item -ItemType Directory -Path $workDir | Out-Null
try {
  # A real repo: the relabel reads the branch with git. `elsewhere` is not a
  # repository at all.
  $repo = Join-Path $workDir 'repo'
  git init --quiet --initial-branch=main $repo
  git -C $repo -c user.email=t@example.com -c user.name=test commit --quiet --allow-empty -m init
  git -C $repo branch feat/eager-worktree-focus
  $linked = Join-Path $workDir 'linked'
  git -C $repo worktree add --quiet -b feat/login $linked
  $elsewhere = Join-Path $workDir 'elsewhere'
  New-Item -ItemType Directory -Path $elsewhere | Out-Null

  # herdr stub: `worktree list` names the repository; every other call is
  # recorded. Labels instead of ( ) blocks: the recorded argv may hold
  # parentheses.
  Set-Content -LiteralPath (Join-Path $stubDir 'herdr.cmd') -Value @(
    '@echo off',
    'if "%~1 %~2"=="worktree list" goto worktreelist',
    '>> "%STUB_DIR%\herdr.args" echo %*',
    'exit /b 0',
    ':worktreelist',
    'echo {"result":{"source":{"repo_name":"repo"}}}',
    'exit /b 0'
  )
  $env:STUB_DIR = $stubDir
  $env:HERDR_PLUGIN_CONFIG_DIR = $configDir
  $herdr = Join-Path $stubDir 'herdr.cmd'
  $configFile = Join-Path $configDir 'config.toml'

  # Run the relabel from DIR with ARGS (herdr and the tab id come first unless
  # -Raw), exposing its exit code.
  $script:relabelExit = 0
  function Invoke-Relabel([string]$Dir, [string[]]$Arguments, [switch]$Raw) {
    Remove-Item (Join-Path $stubDir 'herdr.args') -ErrorAction SilentlyContinue
    $argv = @($Arguments)
    if (-not $Raw) { $argv = @($herdr, 't3') + $argv }
    Push-Location $Dir
    try {
      @() | & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot 'tab-relabel.ps1') @argv 2>&1 | Out-Null
      $script:relabelExit = $LASTEXITCODE
    } finally { Pop-Location }
  }

  function Get-HerdrArgs {
    return (@(Get-Content -LiteralPath (Join-Path $stubDir 'herdr.args') -ErrorAction SilentlyContinue) -join "`n")
  }

  function Assert-Eq($Expected, $Actual, $What = 'value') {
    if ([string]$Actual -cne [string]$Expected) {
      Fail "expected $What '$Expected', got '$Actual'"
    }
  }

  # The branch is what was picked: the label is just the branch.
  Invoke-Relabel $repo @('main')
  Assert-Eq 0 $script:relabelExit 'exit code'
  Assert-Eq 'tab rename t3 main' (Get-HerdrArgs) 'herdr call'

  # A shortcut resolved to a branch: keep the shortcut alongside.
  git -C $repo checkout --quiet feat/eager-worktree-focus
  Invoke-Relabel $repo @('pr:16')
  Assert-Eq 'tab rename t3 "feat/eager-worktree-focus (pr:16)"' (Get-HerdrArgs) 'herdr call'

  # Detached HEAD: nothing to label with, so the placeholder label stays.
  git -C $repo checkout --quiet --detach
  Invoke-Relabel $repo @('pr:16')
  Assert-Eq 0 $script:relabelExit 'exit code'
  Assert-Eq '' (Get-HerdrArgs) 'herdr call'
  git -C $repo checkout --quiet main

  # Not in a repository at all: likewise.
  Invoke-Relabel $elsewhere @('feature')
  Assert-Eq 0 $script:relabelExit 'exit code'
  Assert-Eq '' (Get-HerdrArgs) 'herdr call'

  # Configured tab labels use the same templates and retained PR as workspaces.
  Set-Content -LiteralPath $configFile -Value 'label_preset = "pr-first"'
  Invoke-Relabel $linked @('https://github.com/o/r/pull/123')
  Assert-Eq 'tab rename t3 "#123 feat/login"' (Get-HerdrArgs) 'herdr call'
  Invoke-Relabel $linked @('feat/login')
  Assert-Eq 'tab rename t3 "#123 feat/login"' (Get-HerdrArgs) 'herdr call'
  Set-Content -LiteralPath $configFile -Value "label_pr_format = '{repo}: #{pr_number} {branch}'"
  Invoke-Relabel $linked @('feat/login')
  Assert-Eq 'tab rename t3 "repo: #123 feat/login"' (Get-HerdrArgs) 'herdr call'

  # The main checkout formats a PR it is handed but keeps no state for it.
  Invoke-Relabel $repo @('https://github.com/o/r/pull/7')
  Assert-Eq 'tab rename t3 "repo: #7 main"' (Get-HerdrArgs) 'herdr call'
  Invoke-Relabel $repo @('main')
  Assert-Eq 'tab rename t3 main' (Get-HerdrArgs) 'herdr call'
  if (Test-Path -LiteralPath (Join-Path $repo '.git\herdr-worktrunk-label')) { Fail 'unexpected main checkout label state' }

  # Missing arguments are a plugin bug, not a rename to attempt.
  Invoke-Relabel $repo @($herdr, 't3') -Raw
  if ($script:relabelExit -eq 0) { Fail 'expected tab-relabel.ps1 to reject missing arguments' }
  Assert-Eq '' (Get-HerdrArgs) 'herdr call'
} finally {
  foreach ($name in 'STUB_DIR', 'HERDR_PLUGIN_CONFIG_DIR') {
    Remove-Item "Env:\$name" -ErrorAction SilentlyContinue
  }
  Remove-Item -Recurse -Force -LiteralPath $stubDir, $workDir -ErrorAction SilentlyContinue
}

Write-Output 'tab relabel tests passed'
exit 0
