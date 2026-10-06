# Windows PowerShell 5.1 port of lifecycle.sh: shared steps for the actions that
# destroy a worktree (remove.ps1, merge.ps1): listing what they can act on,
# resolving what herdr has open for it, and closing that UI once worktrunk is
# done. Dot-sourced after config.ps1 and helpers.ps1; entry scripts set $WtBin
# (via Resolve-WorktrunkBinOrExit) before calling into here.

# The normalized `wt list` items as an array, or $null after printing the pane
# message for whichever step broke.
function Get-WorktrunkWorktreeItems {
  $json = & $WtBin list --format=json 2>$null | Out-String
  if ($LASTEXITCODE -ne 0) {
    Write-WtError 'failed to list worktrees'
    Start-Sleep -Seconds 2
    return $null
  }

  try {
    return , @(Get-WorktrunkListItems $json)
  } catch {
    Write-WtError 'unsupported worktrunk list output'
    Start-Sleep -Seconds 2
    return $null
  }
}

# One branch per line for every worktree these actions can act on: any real
# worktree except the main one (the primary checkout can't be removed, and it's
# the merge target rather than a merge source). The current worktree IS included
# - worktrunk switches you back to the root repo.
function Get-WorktrunkWorktreeBranches($Items) {
  return , @($Items |
    Where-Object { $_.kind -ceq 'worktree' -and $null -ne $_.branch -and $_.is_main -ne $true } |
    ForEach-Object { $_.branch })
}

# The path of the worktree checked out at BRANCH, or $null.
function Get-WorktrunkWorktreePath($Items, [string]$Branch) {
  foreach ($item in $Items) {
    if ($item.kind -ceq 'worktree' -and $item.branch -ceq $Branch) { return $item.path }
  }
  return $null
}

# The path of the main checkout, or $null.
function Get-WorktrunkMainPath($Items) {
  foreach ($item in $Items) {
    if ($item.kind -ceq 'worktree' -and $item.is_main -eq $true -and $item.path) { return $item.path }
  }
  return $null
}

# The id of the native herdr workspace open on the worktree at PATH, or '' (tab
# mode, or a worktree herdr never opened as a workspace). Resolve this before
# the worktree is destroyed - herdr forgets the mapping along with it. Paths are
# compared normalized: on Windows, herdr's worktrees[].path uses forward
# slashes while worktrunk reports native separators.
function Get-WorktrunkOpenWorkspaceId([string]$WtPath) {
  $herdr = $env:HERDR_BIN_PATH
  if (-not $herdr) { $herdr = 'herdr' }

  $json = & $herdr worktree list --cwd (Get-WtCurrentPath) --json 2>$null | Out-String
  try { $worktrees = (ConvertFrom-Json -InputObject $json).result.worktrees } catch { return '' }

  $wanted = ConvertTo-WtComparablePath $WtPath
  foreach ($worktree in @($worktrees)) {
    if ((ConvertTo-WtComparablePath $worktree.path) -eq $wanted -and $worktree.open_workspace_id) {
      return [string]$worktree.open_workspace_id
    }
  }
  return ''
}

# The label of the herdr workspace WORKSPACEID, or '' (no such workspace, or
# `workspace list` output that doesn't parse). Read it before the workspace
# closes: reopening the worktree without it gives the workspace herdr's default
# label, losing e.g. the picker's "branch (typed)" form. Ids compare
# case-sensitively - herdr's mix cases (w5, wM, wN).
function Get-WorktrunkWorkspaceLabel([string]$WorkspaceId) {
  $herdr = $env:HERDR_BIN_PATH
  if (-not $herdr) { $herdr = 'herdr' }

  $json = & $herdr workspace list 2>$null | Out-String
  try { $workspaces = (ConvertFrom-Json -InputObject $json).result.workspaces } catch { return '' }

  foreach ($workspace in @($workspaces)) {
    if ($workspace.workspace_id -ceq $WorkspaceId -and $workspace.label) {
      return [string]$workspace.label
    }
  }
  return ''
}

# fzf over the branches in CANDIDATES with PROMPT and HEADER, in the chrome that
# suits the picker placement. Returns '' when the user cancels.
function Invoke-WorktrunkPickBranch($Candidates, [string]$Prompt, [string]$Header) {
  $layout = Get-WorktrunkFzfLayout
  $picked = $Candidates | fzf --reverse --info=inline @layout --prompt="$Prompt" --header="$Header"
  if ($LASTEXITCODE -ne 0 -or $null -eq $picked) { return '' }
  return [string](@($picked)[-1])
}

# Remove BRANCH's worktree with the herdr UI already out of the way, and put
# the UI back if the removal fails. On Windows a directory cannot be deleted
# while any process has it as its cwd - and the worktree's own workspace pane
# (or its tab-mode panes) is exactly such a process - so unlike the Unix
# scripts, the UI has to close BEFORE `wt remove` deletes the checkout, not
# after. When worktrunk then refuses or fails, the workspace is reopened so a
# failed removal doesn't also cost the user their UI (closed tab-mode panes
# have no such undo - their shells are gone).
#
# HOLDACTION and HOLDMESSAGE are handed to Wait-WorktrunkHoldPane once the
# removal succeeds. The hold comes after the removal (the UI had to close
# first), but before this pane's own workspace closes, which ends the pane.
function Invoke-WorktrunkGuardedRemove([string]$Branch, [string]$WorkspaceId, [string]$WtPath, [string]$MainPath,
                                       [string]$HoldAction, [string]$HoldMessage) {
  $herdr = $env:HERDR_BIN_PATH
  if (-not $herdr) { $herdr = 'herdr' }

  # This script itself holds a cwd lock when its pane was opened inside the
  # worktree being removed - step out to the main checkout first. Set-Location
  # only moves PowerShell's own location; the lock is on the process's working
  # directory, which has to move as well.
  $inWorktree = (Test-WtPathPrefix (Get-WtCurrentPath) $WtPath) -or
                (Test-WtPathPrefix ([Environment]::CurrentDirectory) $WtPath)
  if ($inWorktree -and $MainPath -and (Test-Path -LiteralPath $MainPath)) {
    Set-Location -LiteralPath $MainPath
    [Environment]::CurrentDirectory = Get-WtCurrentPath
  }

  # Closing the workspace this script's own pane lives in would kill the script
  # before the removal happens - close that workspace only AFTER a successful
  # removal, and close just its other panes (the cwd-lock holders) up front.
  $closeSelfAfter = ($WorkspaceId -and $env:HERDR_WORKSPACE_ID -and
    $WorkspaceId -ceq $env:HERDR_WORKSPACE_ID)
  $workspaceLabel = ''
  if ($closeSelfAfter) {
    $closed = Close-WorktrunkWorktreeUi '' $WtPath
  } else {
    # Only a workspace closed here can need reopening; keep its label for that.
    if ($WorkspaceId) { $workspaceLabel = Get-WorktrunkWorkspaceLabel $WorkspaceId }
    $closed = Close-WorktrunkWorktreeUi $WorkspaceId $WtPath
  }
  if ($closed -gt 0) {
    # The closed panes' shells need a moment to exit and release their cwd locks.
    Start-Sleep -Seconds 2
  }

  # -C runs it from the main checkout: removing the worktree the pane sits in
  # makes worktrunk try to cd the shell back to the main one, and this pane has
  # no shell integration for that, so it would warn on every such removal. A
  # null -C value would vanish from the argv, so it is only passed when known.
  $removeArgs = @('remove', '--foreground')
  if ($MainPath) { $removeArgs += @('-C', $MainPath) }
  & $WtBin @removeArgs $Branch
  if ($LASTEXITCODE -eq 0) {
    if ($HoldAction) { Wait-WorktrunkHoldPane $HoldAction $HoldMessage }
    if ($closeSelfAfter) {
      # Kills this very pane; nothing may follow this line.
      & $herdr workspace close $WorkspaceId | Out-Host
    }
    return $true
  }

  if ($WorkspaceId -and -not $closeSelfAfter -and (Test-Path -LiteralPath $WtPath)) {
    # Under the label it had, not herdr's default. An empty --label value would
    # vanish from the argv, so the flag is only passed when the label is known.
    $labelArgs = @()
    if ($workspaceLabel) { $labelArgs = @('--label', $workspaceLabel) }
    & $herdr worktree open --cwd (Get-WtCurrentPath) --path $WtPath @labelArgs --no-focus | Out-Null
  }
  return $false
}

# Close the herdr UI a worktree leaves behind: its native workspace as a unit,
# or - for the original tab-based mode and worktrees opened by older plugin
# versions - the panes sitting in it. Leaves the calling pane alone. Returns
# how many things it closed, so callers know whether shells need time to exit.
function Close-WorktrunkWorktreeUi([string]$WorkspaceId, [string]$WtPath) {
  $herdr = $env:HERDR_BIN_PATH
  if (-not $herdr) { $herdr = 'herdr' }

  if ($WorkspaceId) {
    & $herdr workspace close $WorkspaceId | Out-Host
    return 1
  }

  if (Test-WtRootPath $WtPath) { return 0 }

  $json = & $herdr pane list 2>$null | Out-String
  try { $panes = (ConvertFrom-Json -InputObject $json).result.panes } catch { return 0 }

  $count = 0
  foreach ($pane in @($panes)) {
    if ($pane.pane_id -ceq $env:HERDR_PANE_ID) { continue }
    if (Test-WtPathPrefix $pane.cwd $WtPath) {
      & $herdr pane close $pane.pane_id | Out-Host
      $count++
    }
  }
  return $count
}
