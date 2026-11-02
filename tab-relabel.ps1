# Relabel a tab-mode worktree tab after the branch `wt switch` landed on.
#
#   tab-relabel.ps1 <herdr-bin> <tab-id> <picked-name>
#
# picker.ps1 types this into the new tab's shell once `wt switch` has finished
# and the shell has moved into the worktree, running it as its own Windows
# PowerShell process with -ExecutionPolicy Bypass. Windows twin of
# tab-relabel.sh, without the shell-integration check: picker.ps1 cds into the
# path worktrunk reports itself. On a detached HEAD there is no branch to show,
# so the placeholder label the picker set stays.
param([string]$Herdr, [string]$TabId, [string]$Name)
. "$PSScriptRoot\config.ps1"
. "$PSScriptRoot\helpers.ps1"

if (-not $Herdr -or -not $TabId -or -not $Name) {
  [Console]::Error.WriteLine('usage: tab-relabel.ps1 <herdr-bin> <tab-id> <picked-name>')
  exit 2
}

$branch = [string](git branch --show-current 2>$null)
if (-not $branch) { exit 0 }
$repo = ''
try {
  $source = (ConvertFrom-Json -InputObject (& $Herdr worktree list --cwd (Get-WtCurrentPath) --json 2>$null | Out-String)).result.source
  $repo = ([string]$source.repo_name) -replace '\.git$', ''
} catch {}
$state = Get-WorktrunkPreparedLabel (Get-WtCurrentPath) $branch $Name $repo
& $Herdr tab rename $TabId (ConvertTo-WorktrunkNativeText $state.Label) | Out-Null
if ($LASTEXITCODE -eq 0) {
  # Every tab is new; keep the workspace's last generated label intact.
  $state.Managed = $false
  Save-WorktrunkLabel $state $branch
}
exit 0
