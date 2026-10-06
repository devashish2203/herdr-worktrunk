# Windows PowerShell 5.1 port of remove.sh: fzf over removable worktrees, then
# `wt remove`. It calls the resolved worktrunk binary directly, so it needs no
# shell-function/rc integration.

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

$wtItems = Get-WorktrunkWorktreeItems
if ($null -eq $wtItems) { exit 1 }

$cands = Get-WorktrunkWorktreeBranches $wtItems
if ($cands.Count -eq 0) {
  [Console]::Out.WriteLine("$WtEsc[33mNo removable worktrees (only the main worktree exists).$WtEsc[0m")
  Start-Sleep -Seconds 2
  exit 0
}

$name = Invoke-WorktrunkPickBranch $cands "remove worktree $WtChevron " `
  "$WtEnterKey to remove (worktrunk will ask to confirm) $WtDot esc to cancel"
if (-not $name) { exit 0 }    # esc / no selection -> cancel

# Path and native herdr workspace (if open) of the worktree we're about to
# remove, and the main checkout to step into while it goes away.
$wtPath = Get-WorktrunkWorktreePath $wtItems $name
$wsid = Get-WorktrunkOpenWorkspaceId $wtPath
$mainPath = Get-WorktrunkMainPath $wtItems

# wt remove prompts for approval itself, refuses unmerged branches without -D,
# and refuses worktrees with untracked files without -f - so run it
# interactively and let worktrunk gate the destructive bits. --foreground keeps
# the pane until it's done. The guarded remove closes the worktree's herdr UI
# first (Windows can't delete a process's cwd) and reopens it on failure.
if (-not (Invoke-WorktrunkGuardedRemove $name $wsid $wtPath $mainPath 'remove' "removed $name.")) {
  [Console]::Out.Write("`n$WtEsc[31mwt remove failed (see above).$WtEsc[0m press any key to close")
  Wait-WtAnyKey
  exit 0
}
