# Windows PowerShell 5.1 port of merge.sh: fzf over mergeable worktrees, then
# `wt merge` into the target branch and `wt remove`. It calls the resolved
# worktrunk binary directly, so it needs no shell-function/rc integration.

$actionFlags = @()
switch ([string]$args[0]) {
  '' { break }
  '--no-squash' { $actionFlags = @('--no-squash'); break }
  default {
    [Console]::Error.WriteLine("unsupported merger option: $($args[0])")
    exit 2
  }
}

# herdr hands HERDR_PLUGIN_ROOT to plugins in Windows extended-length form
# (\\?\C:\...), which Join-Path and friends reject in Windows PowerShell -
# strip the prefix before building any path on it.
$pluginRoot = $env:HERDR_PLUGIN_ROOT
if (-not $pluginRoot) { $pluginRoot = $PSScriptRoot }
if ($pluginRoot.StartsWith('\\?\UNC\')) { $pluginRoot = '\\' + $pluginRoot.Substring(8) }
elseif ($pluginRoot.StartsWith('\\?\')) { $pluginRoot = $pluginRoot.Substring(4) }
. "$pluginRoot\config.ps1"
. "$pluginRoot\helpers.ps1"
. "$pluginRoot\lifecycle.ps1"

if (-not (Get-Command fzf -CommandType Application -ErrorAction SilentlyContinue)) {
  Write-WtError 'fzf not found on PATH'
  Start-Sleep -Seconds 2
  exit 1
}

$WtBin = Resolve-WorktrunkBinOrExit

# Configured flags first, then the ones this action adds, skipping any the
# config already asked for so `wt merge` never sees the same flag twice.
$mergeFlags = @(Get-WorktrunkMergeFlags)
foreach ($flag in $actionFlags) {
  if ($mergeFlags -cnotcontains $flag) { $mergeFlags += $flag }
}

$wtItems = Get-WorktrunkWorktreeItems
if ($null -eq $wtItems) { exit 1 }

$cands = Get-WorktrunkWorktreeBranches $wtItems
if ($cands.Count -eq 0) {
  [Console]::Out.WriteLine("$WtEsc[33mNo mergeable worktrees (only the main worktree exists).$WtEsc[0m")
  Start-Sleep -Seconds 2
  exit 0
}

# Spell out the exact wt invocation in the header: which flags are in play is
# the difference between this action and its no-squash variant, and between one
# user's merge_flags and another's.
$flagsSuffix = ''
if ($mergeFlags.Count -gt 0) { $flagsSuffix = ' ' + ($mergeFlags -join ' ') }
$name = Invoke-WorktrunkPickBranch $cands "merge worktree $WtChevron " `
  "$WtEnterKey to run wt merge$flagsSuffix and remove the worktree $WtDot esc to cancel"
if (-not $name) { exit 0 }    # esc / no selection -> cancel

# Path and native herdr workspace (if open) of the worktree we're about to
# merge, and the main checkout to step into while it goes away. All have to be
# resolved before the removal below destroys them.
$wtPath = Get-WorktrunkWorktreePath $wtItems $name
$wsid = Get-WorktrunkOpenWorkspaceId $wtPath
$mainPath = Get-WorktrunkMainPath $wtItems

# -C runs the merge as if from the picked worktree, so the pane never has to be
# in it. --no-remove because wt merge's own removal runs in the background,
# which would race the workspace close below; the foreground `wt remove`
# further down does it. wt merge stages, commits, squashes and rebases per its
# flags, runs pre-commit and pre-merge hooks, and stops on conflicts - so run
# it interactively and let worktrunk gate all of that.
& $WtBin merge --no-remove -C $wtPath @mergeFlags
if ($LASTEXITCODE -ne 0) {
  [Console]::Out.Write("`n$WtEsc[31mwt merge failed (see above).$WtEsc[0m press any key to close")
  Wait-WtAnyKey
  exit 0
}

# The branch is merged now, so wt remove deletes it without -D. The guarded
# remove closes the worktree's herdr UI first (Windows can't delete a process's
# cwd) and reopens it when the removal fails - the workspace still holds a
# live worktree in that case.
if (-not (Invoke-WorktrunkGuardedRemove $name $wsid $wtPath $mainPath 'merge' "merged $name and removed the worktree.")) {
  [Console]::Out.Write("`n$WtEsc[31mmerged, but wt remove failed (see above).$WtEsc[0m press any key to close")
  Wait-WtAnyKey
  exit 0
}
