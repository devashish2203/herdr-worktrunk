# Windows PowerShell 5.1 port of helpers.sh, plus the helpers only Windows
# needs: path normalization (herdr and worktrunk mix \ and / in their JSON on
# Windows) and explicit worktrunk resolution (bare `wt` is Windows Terminal's
# launcher on a stock Windows PATH). Dot-source config.ps1 first.

# True when NAME is a token worktrunk resolves itself - a branch shortcut
# (^ default, - previous) or `:` syntax (pr:N, mr:N, or a PR/MR URL). Git branch
# names can't be these bare symbols or contain `:`, so these must be passed to
# `wt switch` as-is, never with --create. `@` (current) is omitted: switching to
# the current worktree is a no-op, and its only real use is as a --base.
function Test-WorktrunkShortcut([string]$Name) {
  return ($Name -ceq '^' -or $Name -ceq '-' -or $Name.Contains(':'))
}

# True when NAME is an existing local branch or remote-tracking branch. Such refs
# are checked out directly by `wt switch NAME` (worktrunk creates the worktree if
# one doesn't exist yet), so they must never be passed with --create.
function Test-WorktrunkRefExists([string]$Name) {
  git show-ref --quiet --verify "refs/heads/$Name" 2>$null
  if ($LASTEXITCODE -eq 0) { return $true }
  git show-ref --quiet --verify "refs/remotes/$Name" 2>$null
  return ($LASTEXITCODE -eq 0)
}

# TEXT as a lowercase, hyphenated branch name, e.g. "Fix Login Bug" ->
# "fix-login-bug". Keeps `/`, `.` and `_`; returns '' when no valid name is
# left. Only A-Z is lowercased, as `LC_ALL=C tr` does in helpers.sh: every other
# character outside [a-z0-9._/] folds into a dash either way, and a culture-aware
# lowercase could turn some of them into ASCII letters instead.
function ConvertTo-WorktrunkBranchSlug([string]$Text) {
  $slug = [regex]::Replace($Text, '[A-Z]', { param($m) $m.Value.ToLowerInvariant() })
  $slug = $slug -creplace '[^a-z0-9._/]+', '-'
  $slug = $slug -creplace '-*/+-*', '/'
  $slug = $slug -creplace '\.{2,}', '.'
  $slug = $slug -creplace '/\.+', '/'
  $slug = $slug -creplace '^[-/.]+', ''
  $slug = $slug -creplace '[-/.]+$', ''

  if (-not $slug) { return '' }
  git check-ref-format "refs/heads/$slug" 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) { return '' }
  return $slug
}

# Normalize the worktrunk list JSON into objects with the schema 1 location
# fields (`kind`, `path`, `is_main`) plus `branch` at the top level. Worktrunk's
# JSON schema 2 wraps items in an envelope and nests those fields under
# `worktree`. Throws on any other shape.
function Get-WorktrunkListItems([string]$Json) {
  $data = ConvertFrom-Json -InputObject $Json
  if ($data -is [System.Array]) {
    $items = $data
  } elseif ($data -is [System.Management.Automation.PSCustomObject] -and
            $data.PSObject.Properties['items'] -and $data.items -is [System.Array]) {
    $items = $data.items
  } else {
    throw 'unsupported worktrunk list JSON schema'
  }

  foreach ($item in $items) {
    $worktree = $null
    if ($item.PSObject.Properties['worktree']) { $worktree = $item.worktree }

    $kind = $item.kind
    if ($null -eq $kind) {
      if ($worktree -is [System.Management.Automation.PSCustomObject]) { $kind = 'worktree' }
      else { $kind = 'branch' }
    }

    $path = $item.path
    if ($null -eq $path -and $null -ne $worktree) { $path = $worktree.path }

    $isMain = $item.is_main
    if ($null -eq $isMain -and $null -ne $worktree) { $isMain = $worktree.main }
    if ($null -eq $isMain) { $isMain = $false }

    $branch = $null
    if ($item.PSObject.Properties['branch']) { $branch = $item.branch }

    [pscustomobject]@{ kind = $kind; path = $path; is_main = $isMain; branch = $branch }
  }
}

# Keep the pane up with MESSAGE until a key is pressed, when the configuration
# holds ACTION (see Get-WorktrunkHoldOn in config.ps1). Call it once worktrunk
# has succeeded and before herdr is asked to change anything: the pane can sit
# in a workspace that is about to close or lose focus.
function Wait-WorktrunkHoldPane([string]$Action, [string]$Message) {
  if ((Get-WorktrunkHoldOn $Action) -eq 'true') {
    [Console]::Out.Write("`n$WtEsc[32m$Message$WtEsc[0m press any key to continue")
    Wait-WtAnyKey
  }
}

# The current directory as a plain filesystem path, for herdr's --cwd and for
# path comparisons. "$PWD" is not that on a network share: it renders as
# Microsoft.PowerShell.Core\FileSystem::\\server\share\..., which herdr can't
# resolve and ConvertTo-WtComparablePath can't normalize.
function Get-WtCurrentPath {
  return (Get-Location).ProviderPath
}

# A path shaped for comparison: extended-length prefix dropped (`\\?\C:\...`
# becomes C:\..., `\\?\UNC\server\share` becomes \\server\share, as the entry
# scripts do for the plugin root), separators forward, no trailing slash
# (drive roots keep theirs, and a UNC path keeps its leading //). Needed
# because herdr's own JSON mixes styles on Windows - repo_root comes back as
# C:\Users\... while worktrees[].path is C:/Users/... - and worktrunk emits its
# own flavor. Compare results with -eq (case-insensitive in PowerShell), or
# via Test-WtPathPrefix for containment.
function ConvertTo-WtComparablePath([string]$Path) {
  if (-not $Path) { return '' }
  $p = $Path
  if ($p.StartsWith('\\?\UNC\')) { $p = '\\' + $p.Substring(8) }
  elseif ($p.StartsWith('\\?\')) { $p = $p.Substring(4) }
  $p = $p -replace '\\', '/'
  $floor = 1
  if ($p.StartsWith('//')) { $floor = 2 }
  while ($p.Length -gt $floor -and $p.EndsWith('/') -and -not ($p -match '^[A-Za-z]:/$')) {
    $p = $p.Substring(0, $p.Length - 1)
  }
  return $p
}

# True when CHILD is PARENT or lives under it. Both are normalized here, so
# callers can pass raw JSON values.
function Test-WtPathPrefix([string]$Child, [string]$Parent) {
  $c = ConvertTo-WtComparablePath $Child
  $p = ConvertTo-WtComparablePath $Parent
  if (-not $c -or -not $p) { return $false }
  if ($c -eq $p) { return $true }
  if (-not $p.EndsWith('/')) { $p = $p + '/' }
  return $c.StartsWith($p, [System.StringComparison]::OrdinalIgnoreCase)
}

# True when PATH normalizes to a filesystem root ('/', 'C:', 'C:/', or a bare
# network server or share such as //server/share) - the guard the pane-closing
# cleanup uses so a degenerate worktree path can never match every pane on the
# drive or share.
function Test-WtRootPath([string]$Path) {
  $p = ConvertTo-WtComparablePath $Path
  return ($p -eq '' -or $p -match '^([A-Za-z]:)?/?$' -or $p -match '^//[^/]*(/[^/]+)?$')
}

# The worktrunk executable to run. On a stock Windows PATH, `wt` is Windows
# Terminal's launcher alias (...\Microsoft\WindowsApps\wt.exe), so bare `wt`
# is never trusted blindly. Resolution order:
#   1. WORKTRUNK_BIN environment variable (also how the tests stub wt)
#   2. worktrunk_bin in the plugin's managed config.toml
#   3. `worktrunk` on PATH
#   4. `wt` on PATH, skipping the WindowsApps alias directory
#   5. ~\.cargo\bin\wt.exe (a cargo install not yet on PATH)
# Returns '' when nothing is found; callers print the actionable error.
function Get-WorktrunkBin {
  if ($env:WORKTRUNK_BIN) { return $env:WORKTRUNK_BIN }

  $configured = Get-WorktrunkConfigValue 'worktrunk_bin'
  if ($configured) { return $configured }

  $cmd = Get-Command 'worktrunk' -CommandType Application -ErrorAction SilentlyContinue
  if ($cmd) { return @($cmd)[0].Source }

  foreach ($candidate in @(Get-Command 'wt' -CommandType Application -All -ErrorAction SilentlyContinue)) {
    if ($candidate.Source -notmatch '\\Microsoft\\WindowsApps\\') { return $candidate.Source }
  }

  $cargoWt = Join-Path $env:USERPROFILE '.cargo\bin\wt.exe'
  if (Test-Path -LiteralPath $cargoWt) { return $cargoWt }

  return ''
}

# Resolve worktrunk or fail the pane with an actionable message. Entry scripts
# call this once and pass the result around.
function Resolve-WorktrunkBinOrExit {
  $bin = Get-WorktrunkBin
  if ($bin) { return $bin }
  Write-WtError 'worktrunk not found. Install it (https://github.com/max-sixty/worktrunk) and either put its binary on PATH as `worktrunk`, or set worktrunk_bin in the plugin config.toml / the WORKTRUNK_BIN environment variable. Note: `wt` under ...\Microsoft\WindowsApps is Windows Terminal, not worktrunk.'
  Start-Sleep -Seconds 2
  exit 1
}

function Get-WorktrunkPrNumber([string]$Name) {
  if ($Name -cmatch '^pr:([0-9]+)$' -or
      $Name -cmatch '^https://github\.com/[^/]+/[^/]+/pull/([0-9]+)([/#?].*)?$') {
    return $Matches[1]
  }
  return ''
}

function Get-WorktrunkDefaultLabel([string]$Branch, [string]$Name) {
  if (-not $Branch -or $Branch -ceq $Name) { return $Name }
  return "$Branch ($Name)"
}

function Get-WorktrunkSwitchLabel([string]$Branch, [string]$Name, [string]$Repo = '', [string]$Pr = '') {
  if (-not $Pr) { $Pr = Get-WorktrunkPrNumber $Name }
  $preset = 'default'
  $presetConfigured = Test-WorktrunkConfigKey 'label_preset'
  if ($presetConfigured) { $preset = Get-WorktrunkLabelConfigValue 'label_preset' }
  if ($preset -cnotin @('default', 'pr-first', 'branch-first', 'branch-only', 'pr-only')) {
    Write-WtWarning "invalid label_preset $preset; using current naming behavior"
    return Get-WorktrunkDefaultLabel $Branch $Name
  }
  $format = '{branch}'
  if ($Pr) {
    switch -CaseSensitive ($preset) {
      'pr-first' { $format = '#{pr_number} {branch}' }
      'branch-first' { $format = '{branch} ' + [char]0x00B7 + ' #{pr_number}' }
      'pr-only' { $format = '#{pr_number}' }
    }
  }
  $key = 'label_format'
  if ($Pr) { $key = 'label_pr_format' }
  if (Test-WorktrunkConfigKey $key) {
    $format = Get-WorktrunkLabelConfigValue $key
  } elseif ($preset -ceq 'default') {
    if ($Pr -and ($presetConfigured -or $Name -ceq $Branch)) {
      return Get-WorktrunkDefaultLabel $Branch ('pr:' + $Pr)
    }
    return Get-WorktrunkDefaultLabel $Branch $Name
  }
  $values = @{ branch = $Branch; selection = $Name; repo = $Repo }
  if ($Pr) { $values['pr_number'] = $Pr }
  $remaining = $format -creplace '\{(branch|selection|repo)\}', ''
  if ($Pr) { $remaining = $remaining -creplace '\{pr_number\}', '' }
  $invalid = $remaining.Contains('{') -or $remaining.Contains('}')
  $label = [regex]::Replace($format, '\{(branch|selection|repo|pr_number)\}', {
    param($m)
    return [string]$values[$m.Groups[1].Value]
  })
  if ($invalid -or -not $label.Trim()) {
    Write-WtWarning "invalid placeholders or empty label in $key; using current naming behavior"
    return Get-WorktrunkDefaultLabel $Branch $Name
  }
  return $label
}

# Git's config codec keeps state portable without touching tracked files or the
# repo config. Worktree removal also removes this private per-checkout state.
# Only linked worktrees keep state: the main checkout belongs to the repository's
# own workspace, which the plugin never relabels. A linked worktree's git dir is
# the one with a commondir file, which works on any git with worktrees.
function Get-WorktrunkLabelStateFile([string]$Path) {
  $dir = git -C $Path rev-parse --absolute-git-dir 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $dir) { return '' }
  if (-not (Test-Path -LiteralPath (Join-Path $dir 'commondir') -PathType Leaf)) { return '' }
  return Join-Path $dir 'herdr-worktrunk-label'
}

function Get-WorktrunkPreparedLabel([string]$Path, [string]$Branch, [string]$Name,
    [string]$Repo, [string]$Current = '') {
  $file = Get-WorktrunkLabelStateFile $Path
  $pr = Get-WorktrunkPrNumber $Name
  $last = ''
  if ($file -and (Test-Path -LiteralPath $file)) {
    $oldBranch = git config --file $file --get label.branch 2>$null
    if ($oldBranch -ceq $Branch) {
      if (-not $pr) { $pr = git config --file $file --get label.pr 2>$null }
      $last = git config --file $file --get label.generated 2>$null
    }
  }
  return [pscustomobject]@{
    File = $file; Pr = [string]$pr
    Label = Get-WorktrunkSwitchLabel $Branch $Name $Repo ([string]$pr)
    Managed = (-not $Current -or ($last -and $Current -ceq $last))
  }
}

function Save-WorktrunkLabel($State, [string]$Branch) {
  if (-not $State.File) { return }
  # PowerShell 5.1 drops empty native arguments.
  git config --file $State.File --unset-all label.branch 2>$null
  if ($Branch) { git config --file $State.File label.branch (ConvertTo-WorktrunkNativeText $Branch) } else { $global:LASTEXITCODE = 0 }
  if ($LASTEXITCODE -ne 0) { Write-WtWarning 'could not save worktrunk label metadata'; return }
  git config --file $State.File --unset-all label.pr 2>$null
  if ($State.Pr) { git config --file $State.File label.pr $State.Pr }
  if ($State.Managed) { git config --file $State.File label.generated (ConvertTo-WorktrunkNativeText $State.Label) }
  if ($LASTEXITCODE -ne 0 -and ($State.Pr -or $State.Managed)) {
    Write-WtWarning 'could not save worktrunk label metadata'
  }
}

# Windows PowerShell 5.1's native argv builder removes embedded double quotes.
# Protect them for the Windows command-line decoder; modern PowerShell already
# preserves them. Values still go directly to native argv, never to a shell.
function ConvertTo-WorktrunkNativeText([string]$Text) {
  if ($PSVersionTable.PSVersion.Major -le 5 -and $env:OS -eq 'Windows_NT') {
    return [regex]::Replace($Text, '(\\*)"', {
      param($m)
      return ($m.Groups[1].Value + $m.Groups[1].Value + '\"')
    })
  }
  return $Text
}
