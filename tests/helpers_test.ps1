# Windows PowerShell 5.1 port of helpers_test.sh: helper function checks, plus
# the path helpers only the Windows side has.
$ErrorActionPreference = 'Continue'
# A test that throws must fail, not skip its remaining checks and report
# success: with no catch, an error inside try { } finally { } leaves the try
# and the script carries on to its "passed" line.
trap { [Console]::Error.WriteLine("test aborted: $_"); exit 1 }

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'config.ps1')
. (Join-Path $repoRoot 'helpers.ps1')

function Fail([string]$Message) {
  [Console]::Error.WriteLine($Message)
  exit 1
}

foreach ($tok in @('^', '-', 'pr:123', 'mr:45', 'https://github.com/o/r/pull/7')) {
  if (-not (Test-WorktrunkShortcut $tok)) { Fail "expected '$tok' to be a worktrunk shortcut" }
}

# @ (current) is intentionally not a shortcut - see helpers.ps1.
foreach ($tok in @('my-feature', 'main', 'feature/foo', '@')) {
  if (Test-WorktrunkShortcut $tok) { Fail "expected '$tok' not to be a worktrunk shortcut" }
}

# Test-WorktrunkRefExists resolves both local heads and remote-tracking branches.
$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("wt-helpers-test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $sandbox | Out-Null
try {
  Push-Location $sandbox
  git init -q | Out-Null
  git config user.email test@example.com
  git config user.name test
  git commit -q --allow-empty -m init | Out-Null
  git branch feature
  git update-ref refs/remotes/origin/remote-feat HEAD

  foreach ($ref in @('feature', 'origin/remote-feat')) {
    if (-not (Test-WorktrunkRefExists $ref)) { Fail "expected '$ref' to be an existing ref" }
  }

  foreach ($ref in @('does-not-exist', 'origin/nope')) {
    if (Test-WorktrunkRefExists $ref) { Fail "expected '$ref' not to be an existing ref" }
  }
} finally {
  Pop-Location
  Remove-Item -Recurse -Force -LiteralPath $sandbox -ErrorAction SilentlyContinue
}

$schemaOne = @'
[
  {"branch":"main","kind":"worktree","path":"/repo","is_main":true},
  {"branch":"feature","kind":"worktree","path":"/repo.feature","is_main":false},
  {"branch":"ready","kind":"branch"}
]
'@
$schemaTwo = @'
{
  "schema":2,
  "items":[
    {"branch":"main","worktree":{"path":"/repo","main":true}},
    {"branch":"feature","worktree":{"path":"/repo.feature","main":false}},
    {"branch":"ready"}
  ]
}
'@
$expectedItems = @(
  'main|worktree|/repo|true',
  'feature|worktree|/repo.feature|false',
  'ready|branch|null|false'
) -join "`n"

foreach ($listJson in @($schemaOne, $schemaTwo)) {
  $actualItems = @(Get-WorktrunkListItems $listJson | ForEach-Object {
    $path = if ($null -eq $_.path) { 'null' } else { [string]$_.path }
    $isMain = ([string]$_.is_main).ToLowerInvariant()
    "$($_.branch)|$($_.kind)|$path|$isMain"
  }) -join "`n"
  if ($actualItems -cne $expectedItems) {
    Fail "unexpected normalized worktrunk list items:`n$actualItems"
  }
}

$schemaFailed = $false
try { Get-WorktrunkListItems '{"schema":3}' | Out-Null } catch { $schemaFailed = $true }
if (-not $schemaFailed) { Fail 'expected unsupported worktrunk list schema to fail' }

# Branch slugs. The right single quote is built from its code point: this file
# stays ASCII so Windows PowerShell can't misread it.
$rsquo = [string][char]0x2019
foreach ($case in @(
    @('optimize Stripe loading waterfall', 'optimize-stripe-loading-waterfall'),
    @("  Fix: user's LOGIN bug!! ", 'fix-user-s-login-bug'),
    @("fix user${rsquo}s login", 'fix-user-s-login'),
    @('Feat / Add API v2', 'feat/add-api-v2'),
    @('//a//b//', 'a/b'),
    @('v1..2_FIX.', 'v1.2_fix'),
    @('a/.b', 'a/b'),
    @('already-a-slug', 'already-a-slug'))) {
  $slug = ConvertTo-WorktrunkBranchSlug $case[0]
  if ($slug -cne $case[1]) { Fail "expected branch slug '$($case[1])' for '$($case[0])', got '$slug'" }
}

# No valid name left: nothing comes back.
foreach ($text in @('', '!!!', ' - / . ', 'foo.lock')) {
  $slug = ConvertTo-WorktrunkBranchSlug $text
  if ($slug -cne '') { Fail "expected no branch slug for '$text', got '$slug'" }
}

# Windows-side path helpers: herdr mixes \ and / in its JSON, worktrunk emits
# native separators, and Windows paths compare case-insensitively.
if ((ConvertTo-WtComparablePath 'C:\Users\x\repo\') -cne 'C:/Users/x/repo') { Fail 'expected backslashes normalized and trailing slash trimmed' }
if ((ConvertTo-WtComparablePath '\\?\C:\Users\x\repo') -cne 'C:/Users/x/repo') { Fail 'expected \\?\ prefix dropped' }
if ((ConvertTo-WtComparablePath 'C:/') -cne 'C:/') { Fail 'expected drive root kept intact' }
if (-not (Test-WtPathPrefix 'C:\Repo.Feature\sub' 'C:/repo.feature')) { Fail 'expected mixed-separator, mixed-case containment to match' }
if (Test-WtPathPrefix 'C:/repo.feature-two' 'C:/repo.feature') { Fail 'expected sibling with a shared prefix not to match' }
if (-not (Test-WtPathPrefix 'C:/repo.feature' 'C:\repo.feature')) { Fail 'expected the path itself to match' }
foreach ($root in @('/', 'C:', 'C:\', 'c:/', '')) {
  if (-not (Test-WtRootPath $root)) { Fail "expected '$root' to be treated as a root path" }
}
if (Test-WtRootPath 'C:\repo') { Fail 'expected a real path not to be treated as a root' }

# UNC paths (a worktree on a network share): the extended-length \\?\UNC\ form,
# the backslash form and the forward-slash form all compare as //server/share.
foreach ($unc in @('\\?\UNC\server\share\repo', '\\server\share\repo\', '//server/share/repo/')) {
  $got = ConvertTo-WtComparablePath $unc
  if ($got -cne '//server/share/repo') { Fail "expected '$unc' to normalize to //server/share/repo, got '$got'" }
}
foreach ($case in @(
    @('\\server\share\', '//server/share'),
    @('\\?\UNC\server\share\', '//server/share'),
    @('\\server\', '//server'),
    @('\\', '//'),
    @('///', '//'))) {
  $got = ConvertTo-WtComparablePath $case[0]
  if ($got -cne $case[1]) { Fail "expected '$($case[0])' to keep its leading // as '$($case[1])', got '$got'" }
}
if (-not (Test-WtPathPrefix '\\?\UNC\Server\Share\repo.feature\sub' '//server/share/repo.feature')) { Fail 'expected \\?\UNC\ containment to match the forward-slash UNC form' }
if (-not (Test-WtPathPrefix '//server/share/repo.feature/sub' '\\?\UNC\server\share\repo.feature')) { Fail 'expected forward-slash UNC containment to match the \\?\UNC\ form' }
if (-not (Test-WtPathPrefix '\\SERVER\share\repo.feature' '\\?\UNC\server\SHARE\repo.feature\')) { Fail 'expected the UNC path itself to match across forms and case' }
if (Test-WtPathPrefix '//server/share/repo.feature-two' '\\server\share\repo.feature') { Fail 'expected a UNC sibling with a shared prefix not to match' }
if (Test-WtPathPrefix '\\server\share2\repo' '\\?\UNC\server\share') { Fail 'expected a sibling share with a shared prefix not to match' }
if (Test-WtPathPrefix '\\server2\share\repo' '//server/share') { Fail 'expected another server with a shared prefix not to match' }
foreach ($root in @('\\server\share', '\\server\share\', '//server/share/', '\\?\UNC\server\share', '\\?\UNC\server\share\', '\\server', '//server/', '\\?\UNC\server', '\\')) {
  if (-not (Test-WtRootPath $root)) { Fail "expected '$root' to be treated as a root path" }
}
foreach ($path in @('\\server\share\repo', '//server/share/repo/', '\\?\UNC\server\share\repo')) {
  if (Test-WtRootPath $path) { Fail "expected '$path' not to be treated as a root" }
}

# The current directory reaches herdr as a plain path. On a network share
# "$PWD" is provider-qualified (Microsoft.PowerShell.Core\FileSystem::\\...),
# so the scripts must never pass it on. The share case needs the local admin
# share; it is skipped where that is not reachable.
Push-Location -LiteralPath $env:SystemRoot
try {
  if ((Get-WtCurrentPath) -ne $env:SystemRoot) { Fail "expected '$env:SystemRoot', got '$(Get-WtCurrentPath)'" }
} finally { Pop-Location }
$share = '\\localhost\' + $env:SystemDrive.TrimEnd(':') + '$' + $env:SystemRoot.Substring(2)
if (Test-Path -LiteralPath $share) {
  Push-Location -LiteralPath $share
  try {
    if ((Get-WtCurrentPath) -ne $share) { Fail "expected '$share' from a share, got '$(Get-WtCurrentPath)'" }
  } finally { Pop-Location }
} else {
  Write-Output "  (skipped the network-share case: $share is not reachable)"
}
$scripts = Get-ChildItem -LiteralPath $repoRoot -Filter '*.ps1' -File
foreach ($hit in @($scripts | Select-String -SimpleMatch '"$PWD"' | Where-Object { $_.Line -notmatch '^\s*#' })) {
  Fail "use Get-WtCurrentPath, not `"`$PWD`": $($hit.Filename):$($hit.LineNumber)"
}

Write-Output 'helpers tests passed'
exit 0
