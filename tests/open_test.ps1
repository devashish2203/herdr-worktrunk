# Windows PowerShell 5.1 port of open_test.sh: picker placement / open argument
# checks. Runs open.ps1 as a child process, like the bash test runs open.sh.
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

$stubDir = Join-Path ([System.IO.Path]::GetTempPath()) ("wt-open-test-" + [guid]::NewGuid().ToString('N'))
$configDir = Join-Path $stubDir 'config'
New-Item -ItemType Directory -Path $configDir | Out-Null
try {
  # Stand in for the herdr binary and echo back the argv open.ps1 built for it.
  $herdrStub = Join-Path $stubDir 'herdr.cmd'
  Set-Content -LiteralPath $herdrStub -Value @('@echo off', 'echo %*')

  $env:HERDR_PLUGIN_ROOT = $repoRoot
  $env:HERDR_PLUGIN_ID = 'worktrunk'
  $env:HERDR_BIN_PATH = $herdrStub
  $env:HERDR_PLUGIN_CONFIG_DIR = $configDir
  $env:HERDR_WORKSPACE_ID = 'w1'
  $env:HERDR_PLUGIN_CONTEXT_JSON = '{"workspace_cwd":"/tmp/repo","focused_pane_cwd":"/tmp/pane"}'
  $configFile = Join-Path $configDir 'config.toml'

  function Get-OpenArgs([string]$Entrypoint) {
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot 'open.ps1') $Entrypoint 2>&1 | Out-String
    return $out
  }

  function Assert-OpensWith([string]$Expected, [string]$Actual) {
    if ($Actual -notlike "*$Expected*") { Fail "expected '$Expected' in open args '$Actual'" }
  }
  function Refute-OpensWith([string]$Unexpected, [string]$Actual) {
    if ($Actual -like "*$Unexpected*") { Fail "expected no '$Unexpected' in open args '$Actual'" }
  }

  # No config at all: the split pane below the workspace, as before popups existed.
  $opened = Get-OpenArgs 'picker-default-windows'
  Assert-OpensWith '--entrypoint picker-default-windows' $opened
  Assert-OpensWith '--placement split --direction down' $opened
  Assert-OpensWith '--cwd /tmp/repo' $opened
  Assert-OpensWith '--focus' $opened
  Refute-OpensWith 'popup' $opened
  Refute-OpensWith '--env' $opened

  Set-Content -LiteralPath $configFile -Value 'open_mode = "tab"'   # unrelated key -> still split
  $opened = Get-OpenArgs 'remover-windows'
  Assert-OpensWith '--entrypoint remover-windows' $opened
  Assert-OpensWith '--placement split --direction down' $opened

  Set-Content -LiteralPath $configFile -Value 'picker_placement = "popup"'
  $opened = Get-OpenArgs 'picker-current-windows'
  Assert-OpensWith '--entrypoint picker-current-windows' $opened
  Assert-OpensWith '--placement popup' $opened
  # A popup gets no workspace of its own, so the action has to hand its own down.
  Assert-OpensWith '--env HERDR_WORKSPACE_ID=w1' $opened
  Refute-OpensWith '--direction' $opened
  Refute-OpensWith '--width' $opened
  Refute-OpensWith '--height' $opened

  Set-Content -LiteralPath $configFile -Value @('picker_placement = "popup"', 'popup_width = "80%"', 'popup_height = 24')
  $opened = Get-OpenArgs 'picker-default-windows'
  Assert-OpensWith '--width 80% --height 24' $opened

  $opened = Get-OpenArgs 'picker-with-remotes-windows'
  Assert-OpensWith '--entrypoint picker-with-remotes-windows' $opened

  Set-Content -LiteralPath $configFile -Value @('picker_placement = "popup"', 'popup_width = "wide"')
  $opened = Get-OpenArgs 'picker-default-windows'
  Assert-OpensWith '--placement popup' $opened
  Refute-OpensWith '--width' $opened      # malformed -> herdr's default popup size

  # Actions invoked from a pane rather than a workspace carry no workspace_cwd.
  $env:HERDR_PLUGIN_CONTEXT_JSON = '{"workspace_cwd":null,"focused_pane_cwd":"/tmp/pane"}'
  $opened = Get-OpenArgs 'picker-default-windows'
  Assert-OpensWith '--cwd /tmp/pane' $opened

  # herdr hands HERDR_PLUGIN_ROOT over in extended-length form (\\?\C:\...);
  # the scripts must still find and source their own files.
  Set-Content -LiteralPath $configFile -Value 'picker_placement = "popup"'
  $env:HERDR_PLUGIN_ROOT = '\\?\' + $repoRoot
  $opened = Get-OpenArgs 'picker-default-windows'
  Assert-OpensWith '--placement popup' $opened
  $env:HERDR_PLUGIN_ROOT = $repoRoot
} finally {
  $env:HERDR_PLUGIN_ROOT = $null
  $env:HERDR_PLUGIN_ID = $null
  $env:HERDR_BIN_PATH = $null
  $env:HERDR_PLUGIN_CONFIG_DIR = $null
  $env:HERDR_WORKSPACE_ID = $null
  $env:HERDR_PLUGIN_CONTEXT_JSON = $null
  Remove-Item -Recurse -Force -LiteralPath $stubDir -ErrorAction SilentlyContinue
}

Write-Output 'open tests passed'
exit 0
