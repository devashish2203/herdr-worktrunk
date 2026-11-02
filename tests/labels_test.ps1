$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\config.ps1"
. "$PSScriptRoot\..\helpers.ps1"
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('wt-labels-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tmp | Out-Null
$env:HERDR_PLUGIN_CONFIG_DIR = $tmp
function Assert-Equal($Expected, $Actual) {
  if ([string]$Expected -cne [string]$Actual) { throw "expected [$Expected], got [$Actual]" }
}
try {
  $cases = Get-Content -LiteralPath "$PSScriptRoot\label_cases.json" -Encoding UTF8 -Raw | ConvertFrom-Json
  foreach ($case in $cases) {
    $lines = @($case.config.PSObject.Properties | ForEach-Object { $_.Name + " = '" + $_.Value + "'" })
    if ($case.PSObject.Properties['config_raw']) { $lines = @($case.config_raw) }
    [IO.File]::WriteAllLines((Join-Path $tmp 'config.toml'), [string[]]$lines, (New-Object Text.UTF8Encoding $false))
    # Capture Console.Error, which is how warnings are emitted on both platforms.
    $writer = New-Object IO.StringWriter
    $previous = [Console]::Error
    try {
      [Console]::SetError($writer)
      $actual = Get-WorktrunkSwitchLabel $case.branch $case.selection $case.repo $case.pr
    } finally { [Console]::SetError($previous) }
    Assert-Equal $case.expected $actual
    Assert-Equal $case.warning ([bool]$writer.ToString())
  }
  $repo = Join-Path $tmp 'repo'
  git init -q --initial-branch=main $repo
  git -C $repo -c commit.gpgsign=false -c user.email=t@example.com -c user.name=test commit -q --allow-empty -m init
  $checkout = Join-Path $tmp 'checkout'
  git -C $repo worktree add -q -b feature/login $checkout
  Set-Content -LiteralPath (Join-Path $tmp 'config.toml') -Value 'label_preset = "default"'
  $state = Get-WorktrunkPreparedLabel $checkout feature/login pr:123 repo
  Assert-Equal 'feature/login (pr:123)' $state.Label
  Save-WorktrunkLabel $state feature/login
  $state = Get-WorktrunkPreparedLabel $checkout feature/login feature/login repo 'feature/login (pr:123)'
  Assert-Equal 'feature/login (pr:123)' $state.Label
  Assert-Equal $true $state.Managed
  Set-Content -LiteralPath (Join-Path $tmp 'config.toml') -Value ''
  $state = Get-WorktrunkPreparedLabel $checkout feature/login feature/login repo 'feature/login (pr:123)'
  Assert-Equal 'feature/login (pr:123)' $state.Label
  Set-Content -LiteralPath (Join-Path $tmp 'config.toml') -Value 'label_preset = "pr-first"'
  $state = Get-WorktrunkPreparedLabel $checkout feature/login pr:123 repo
  Assert-Equal '#123 feature/login' $state.Label
  Save-WorktrunkLabel $state feature/login
  $state = Get-WorktrunkPreparedLabel $checkout feature/login feature/login repo '#123 feature/login'
  Assert-Equal 123 $state.Pr
  Assert-Equal $true $state.Managed
  Set-Content -LiteralPath (Join-Path $tmp 'config.toml') -Value 'label_preset = "pr-only"'
  $state = Get-WorktrunkPreparedLabel $checkout feature/login feature/login repo '#123 feature/login'
  Assert-Equal '#123' $state.Label
  Assert-Equal $true $state.Managed
  Save-WorktrunkLabel $state feature/login
  $state = Get-WorktrunkPreparedLabel $checkout feature/login feature/login repo 'My manual name'
  Assert-Equal $false $state.Managed
  Save-WorktrunkLabel $state feature/login
  $state = Get-WorktrunkPreparedLabel $checkout feature/login feature/login repo 'My manual name'
  Assert-Equal $false $state.Managed
  Assert-Equal 123 $state.Pr
  $state = Get-WorktrunkPreparedLabel $checkout different different repo
  Assert-Equal '' $state.Pr
  $state = Get-WorktrunkPreparedLabel $repo main main repo
  Assert-Equal '' $state.Pr
  Assert-Equal '' $state.File
  Save-WorktrunkLabel $state main
  if (Test-Path -LiteralPath (Join-Path $repo '.git\herdr-worktrunk-label')) { throw 'unexpected main checkout label state' }
  Write-Output 'label tests passed'
} finally { Remove-Item -LiteralPath $tmp -Recurse -Force }
