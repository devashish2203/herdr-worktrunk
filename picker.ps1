# Windows PowerShell 5.1 port of picker.sh. Picks a branch via fzf (fast), then
# either opens a new tab and runs `wt switch` there, or (default) lets worktrunk
# create/switch the checkout and registers it as a native herdr worktree
# workspace.
#
# Tab mode assumes the tab's interactive shell is PowerShell-family: the command
# sent into the tab is PowerShell syntax. Unlike the Unix tab flow (which relies
# on worktrunk's shell integration to cd), the sent command switches with
# --no-cd --format=json and Set-Locations into the reported path itself.

$createBase = ''
$createBaseLabel = 'default branch'
switch ([string]$args[0]) {
  { $_ -in '', '--create-base=default', '--show-with-remotes' } { break }
  '--create-base=current' {
    $createBase = '@'
    $currentBranch = git branch --show-current 2>$null
    if ($currentBranch) {
      $createBaseLabel = "current branch ($currentBranch)"
    } else {
      $currentCommit = git rev-parse --short HEAD 2>$null
      if ($currentCommit) { $createBaseLabel = "current HEAD ($currentCommit)" }
      else { $createBaseLabel = 'current branch' }
    }
    break
  }
  default {
    [Console]::Error.WriteLine("unsupported picker option: $($args[0])")
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

$WtBin = Resolve-WorktrunkBinOrExit

# Branch refs to offer alongside `wt list`: always local heads, plus
# remote-tracking branches when requested by this dedicated picker or config.
$branchRefs = @('refs/heads')
if ([string]$args[0] -eq '--show-with-remotes' -or (Get-WorktrunkShowRemoteBranches) -eq 'true') {
  $branchRefs += 'refs/remotes'
}

$layout = Get-WorktrunkFzfLayout

# fzf over existing worktree branches; --print-query returns a typed-but-unmatched
# name so we can create it, and alt-enter (print-query) forces the typed name even
# when it fuzzy-matches an existing branch (fzf then prints only the query, so the
# last-line parse below lands on it). Falls back to a plain read if fzf isn't on PATH.
if (Get-Command fzf -CommandType Application -ErrorAction SilentlyContinue) {
  $header = "$WtEnterKey on a match $WtArrow switch $WtDot type a new name + $WtEnterKey $WtArrow create from $createBaseLabel $WtDot alt-$WtEnterKey $WtArrow force typed name $WtDot esc $WtArrow cancel"
  # Ordinal comparer: branch names are case-sensitive, and a PowerShell
  # hashtable would fold 'Feature' into 'feature'.
  $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
  $choice = & {
      # Refs first: `git for-each-ref` answers instantly and in refname order,
      # while `wt list` stats every checkout - seconds on a repo with many
      # worktrees. Drop origin/HEAD: its short form is bare "origin", so filter
      # on the full refname (refs/remotes/origin/HEAD), then emit the short name.
      # Unlike the bash pipeline (where SIGPIPE kills these producers the moment
      # fzf exits), an early pick waits for `wt list` to finish before the
      # switch runs - a known trade-off on repos with very many worktrees.
      git for-each-ref --format='%(refname) %(refname:short)' @branchRefs 2>$null | ForEach-Object {
        $parts = $_ -split ' ', 2
        if ($parts.Count -eq 2 -and $parts[0] -notmatch '/HEAD$') { $parts[1] }
      }
      $wtJson = & $WtBin list --format=json 2>$null | Out-String
      if ($LASTEXITCODE -eq 0 -and $wtJson.Trim()) {
        try {
          Get-WorktrunkListItems $wtJson | Where-Object { $null -ne $_.branch } | ForEach-Object { $_.branch }
        } catch {}
      }
    } |
    ForEach-Object { if ($seen.Add($_)) { $_ } } |
    fzf --print-query --reverse --info=inline @layout `
        --bind=alt-enter:print-query `
        --prompt="worktree $WtChevron " `
        --header="$header"
  $fzfExit = $LASTEXITCODE
  if ($fzfExit -gt 1) { exit 0 }    # 130 = esc/abort -> cancel (0 = picked, 1 = typed-new)
  $lines = @($choice)
  $name = ''                        # last line: the selection if any, else the typed query
  if ($lines.Count -gt 0 -and $null -ne $lines[-1]) { $name = [string]$lines[-1] }
} else {
  $name = Read-Host "Branch (existing $WtArrow switch $WtDot new $WtArrow create from $createBaseLabel)"
}
if (-not $name) { exit 0 }

# Slugify a new branch name. The slug may name an existing branch, which the
# check below then switches to.
if ((Get-WorktrunkSlugifyNewBranches) -eq 'true' -and
    -not (Test-WorktrunkShortcut $name) -and -not (Test-WorktrunkRefExists $name)) {
  $slug = ConvertTo-WorktrunkBranchSlug $name
  if (-not $slug) {
    [Console]::Out.Write("$WtEsc[31mno valid branch name in: $name$WtEsc[0m press any key to close")
    Wait-WtAnyKey
    exit 1
  }
  $name = $slug
}

$openMode = Get-WorktrunkOpenMode

# Existing local or remote-tracking branch -> switch (wt creates the worktree if
# it doesn't exist yet, and checks out a remote ref like origin/foo directly).
# worktrunk shortcuts (^ default, - previous, pr:N/mr:N, PR/MR URL) are resolved
# by worktrunk itself, so pass them through as-is - never --create.
# Anything else is a new branch -> create it.
if ((Test-WorktrunkShortcut $name) -or (Test-WorktrunkRefExists $name)) {
  $wtArgs = @('switch', $name)
  $isCreate = $false
} else {
  $wtArgs = @('switch', '--create', $name)
  if ($createBase) { $wtArgs += @('--base', $createBase) }
  $isCreate = $true
}

$herdr = $env:HERDR_BIN_PATH
if (-not $herdr) { $herdr = 'herdr' }

if ($openMode -eq 'tab') {
  # Preserve the original behavior: run wt in a new tab so the user lands (and
  # stays) in the worktree. The sent command is PowerShell syntax; herdr's
  # default Windows shell is PowerShell-family.
  #
  # A missing workspace id must fail here: PowerShell drops a null argument
  # from a native argv entirely, so herdr would misparse `--workspace --cwd`.
  if (-not $env:HERDR_WORKSPACE_ID) {
    Write-WtError 'no HERDR_WORKSPACE_ID for tab mode (popup pickers need it handed down by the action)'
    Start-Sleep -Seconds 2
    exit 1
  }
  $tabJson = & $herdr tab create --workspace $env:HERDR_WORKSPACE_ID --cwd (Get-WtCurrentPath) --label $name `
    --env "WT_PICKER_NAME=$name" --focus | Out-String
  $rootPane = $null
  try { $rootPane = (ConvertFrom-Json -InputObject $tabJson).result.root_pane } catch {}
  $newPane = [string]$rootPane.pane_id
  $tabId = [string]$rootPane.tab_id
  if (-not $newPane -or -not $tabId) {
    Write-WtError 'failed to open worktree tab'
    Start-Sleep -Seconds 2
    exit 1
  }

  # Single-quoted PowerShell literals for everything user-controlled.
  $qWt = "'" + ($WtBin -replace "'", "''") + "'"
  $qName = "'" + ($name -replace "'", "''") + "'"
  $qHerdr = "'" + ($herdr -replace "'", "''") + "'"
  $qTabId = "'" + ($tabId -replace "'", "''") + "'"

  if ($isCreate) {
    $switchArgs = "--create $qName"
    if ($createBase) { $switchArgs += " --base '@'" }
  } else {
    $switchArgs = $qName
  }

  # The sent command: switch without cd-ing (there is no shell integration to do
  # it), then cd into the path worktrunk reports, then relabel the tab with the
  # real branch $name resolved to, keeping the typed name alongside in parens
  # (e.g. "feat/eager-worktree-focus (pr:16)") when it differs. The command must
  # contain no double quotes: Windows PowerShell does not escape embedded quotes
  # when it builds a native command line, so herdr would receive it split into
  # several argv elements - hence the label is built by concatenation.
  $wtCmd = "`$json = & $qWt switch $switchArgs --no-cd --format=json; " +
    "if (`$LASTEXITCODE -eq 0) { " +
    "try { `$r = ConvertFrom-Json -InputObject ([string]::Join([Environment]::NewLine, @(`$json))); " +
    "if (`$r.path) { Set-Location -LiteralPath `$r.path } } catch {}; " +
    "`$branch = git branch --show-current; " +
    "if (`$branch -ceq `$env:WT_PICKER_NAME) { `$label = `$branch } " +
    "else { `$label = `$branch + ' (' + `$env:WT_PICKER_NAME + ')' }; " +
    "& $qHerdr tab rename $qTabId `$label }"

  # pane run sends the command to the tab's interactive shell; the terminal
  # buffers it until the shell finishes loading.
  & $herdr pane run $newPane $wtCmd
  exit $LASTEXITCODE
}

# Native workspace mode: let worktrunk create/switch the checkout and run hooks,
# then register the resulting existing checkout through herdr's worktree API.
$resultLines = & $WtBin @wtArgs --no-cd --format=json
if ($LASTEXITCODE -ne 0) {
  [Console]::Out.Write("`n$WtEsc[31mwt switch failed (see above).$WtEsc[0m press any key to close")
  Wait-WtAnyKey
  exit 1
}
$resultJson = [string]::Join("`n", @($resultLines))

# $name may be a worktrunk shortcut (^, -, pr:N, mr:N, a PR/MR URL) rather than
# the actual branch, so use what it resolved to for the label, keeping the typed
# name alongside in parens when it differs.
$resolvedBranch = $null
$wtPath = $null
$switchAction = $null
try {
  $result = ConvertFrom-Json -InputObject $resultJson
  $resolvedBranch = $result.branch
  $wtPath = $result.path
  $switchAction = $result.action
} catch {}

if (-not $resolvedBranch) { $label = $name }
elseif ([string]$resolvedBranch -cne $name) { $label = "$resolvedBranch ($name)" }
else { $label = $name }

if (-not $wtPath) {
  $wtJson = & $WtBin list --format=json 2>$null | Out-String
  if ($LASTEXITCODE -eq 0 -and $wtJson.Trim()) {
    try {
      $wtPath = @(Get-WorktrunkListItems $wtJson |
        Where-Object { $_.branch -ceq $name -and $_.kind -ceq 'worktree' } |
        ForEach-Object { $_.path })[0]
    } catch {}
  }
}
if (-not $wtPath) {
  Write-WtError "worktrunk returned no worktree path for: $name"
  Start-Sleep -Seconds 2
  exit 1
}

# Only a worktree worktrunk just created has hook output worth reading; a switch
# to an existing one opens straight away. Hold before the workspace opens below -
# it takes the focus with it.
if ([string]$switchAction -ceq 'created') {
  Wait-WorktrunkHoldPane 'create' "created worktree $label."
}

# Register the worktree under the repo's ROOT workspace, not the picker pane's
# current workspace. When the picker runs from inside an existing worktree
# workspace, $env:HERDR_WORKSPACE_ID is that worktree's own (linked-worktree)
# workspace, which `worktree open` rejects. Resolve the repository root instead;
# Herdr reuses its parent workspace or creates one when absent.
$sourceJson = & $herdr worktree list --cwd (Get-WtCurrentPath) --json 2>$null | Out-String
$source = $null
try { $source = (ConvertFrom-Json -InputObject $sourceJson).result.source } catch {}
$repoRoot = [string]$source.repo_root
if (-not $repoRoot) {
  Write-WtError 'failed to resolve the repository root via herdr worktree list'
  Start-Sleep -Seconds 2
  exit 1
}

# When no workspace covers the root yet, herdr's own auto-created label falls
# back to the checkout directory's basename verbatim (e.g. "repo.git" for a bare
# repo) rather than the repository's name. Pre-create it labeled correctly so
# the `worktree open` below reuses it as-is instead of defaulting the label.
$rootWorkspaceId = [string]$source.source_workspace_id
if (-not $rootWorkspaceId) {
  $repoLabel = ([string]$source.repo_name) -replace '\.git$', ''
  if ($repoLabel) {
    & $herdr workspace create --cwd $repoRoot --label $repoLabel --no-focus | Out-Null
  }
}

# Picking the main/root branch itself resolves wtPath to repoRoot - there's no
# separate linked-worktree workspace to label, it's the repo's own workspace.
# Passing --label here would rename that workspace to the branch (e.g. "main"),
# clobbering the repo-name label set above. Compare canonicalized paths (herdr
# and worktrunk disagree on separators, and Windows paths compare
# case-insensitively).
function Get-WtCanonicalPath([string]$Path) {
  try { return (Get-Item -LiteralPath $Path -ErrorAction Stop).FullName } catch { return $Path }
}
$labelArgs = @('--label', $label)
if ((ConvertTo-WtComparablePath (Get-WtCanonicalPath $wtPath)) -eq (ConvertTo-WtComparablePath (Get-WtCanonicalPath $repoRoot))) {
  $labelArgs = @()
}

& $herdr worktree open --cwd $repoRoot --path $wtPath @labelArgs --focus --json
exit $LASTEXITCODE
