# Windows PowerShell 5.1 port of config.sh. Dot-sourced by the entry scripts.
#
# This file is ASCII-only on purpose: Windows PowerShell reads BOM-less scripts
# as ANSI, so non-ASCII literals would be mangled. Glyphs and ANSI escapes are
# built from [char] codes instead.

$script:WtEsc = [char]27
$script:WtChevron = [string][char]0x276F   # heavy right chevron
$script:WtEnterKey = [string][char]0x21B5  # return symbol
$script:WtDot = [string][char]0x00B7       # middle dot
$script:WtArrow = [string][char]0x2192     # rightwards arrow

# PowerShell 5.1 defaults $OutputEncoding (what piped strings become on a native
# command's stdin) to ASCII and console decoding to the OEM codepage. Both ends
# of the fzf/git/wt pipelines are UTF-8, so switch them over. No console exists
# in some contexts (tests with redirected handles), hence the try/catch.
try {
  $script:WtUtf8 = New-Object System.Text.UTF8Encoding $false
  $global:OutputEncoding = $script:WtUtf8
  [Console]::OutputEncoding = $script:WtUtf8
} catch {}

function Write-WtWarning([string]$Message) {
  [Console]::Error.WriteLine("$WtEsc[33mWarning:$WtEsc[0m $Message")
}

function Write-WtError([string]$Message) {
  [Console]::Error.WriteLine("$WtEsc[31m$Message$WtEsc[0m")
}

# "press any key to close" that also works when stdin is redirected (tests):
# ReadKey needs a real console, so fall back to a plain line read.
function Wait-WtAnyKey {
  try {
    [void][Console]::ReadKey($true)
  } catch {
    [void][Console]::In.ReadLine()
  }
}

# Resolve the managed config path once so presence and value readers apply the
# same Windows extended-path normalization.
function Get-WorktrunkConfigFile {
  $configDir = $env:HERDR_PLUGIN_CONFIG_DIR
  if (-not $configDir) { return '' }
  # Like HERDR_PLUGIN_ROOT, the config dir may arrive in extended-length form
  # (\\?\C:\...), which Join-Path rejects in Windows PowerShell.
  if ($configDir.StartsWith('\\?\UNC\')) { $configDir = '\\' + $configDir.Substring(8) }
  elseif ($configDir.StartsWith('\\?\')) { $configDir = $configDir.Substring(4) }
  return Join-Path $configDir 'config.toml'
}

# Print the configured value for KEY from the plugin's managed config.toml, or
# '' when unset. Accepts double-quoted strings (open_mode = "tab"),
# single-quoted TOML literals (worktrunk_bin = 'C:\path\to\wt.exe' - the
# natural form for Windows paths, since literals need no backslash escaping),
# and bare TOML scalars (show_remote_branches = false); the last occurrence
# wins, like the sed | tail -n1 in config.sh. Like config.sh, keys match
# case-sensitively (as in TOML), and the file is read as UTF-8 rather than
# Windows PowerShell's ANSI default; Get-Content drops a BOM if there is one.
function Get-WorktrunkConfigValue([string]$Key) {
  $configFile = Get-WorktrunkConfigFile
  if (-not $configFile) { return '' }
  if (-not (Test-Path -LiteralPath $configFile)) { return '' }

  $value = ''
  $pattern = '^\s*' + [regex]::Escape($Key) + '\s*=\s*("([^"]*)"|''([^'']*)''|([^\s#"'']+))\s*(#.*)?$'
  foreach ($line in (Get-Content -LiteralPath $configFile -Encoding UTF8)) {
    if ($line -cmatch $pattern) {
      if ($Matches.ContainsKey(2)) { $value = $Matches[2] }
      elseif ($Matches.ContainsKey(3)) { $value = $Matches[3] }
      else { $value = $Matches[4] }
    }
  }
  return $value
}

# "true"/"false" for whether the picker lists remote-tracking branches
# (origin/foo). Disabled by default; set show_remote_branches = true to show them.
function Get-WorktrunkShowRemoteBranches {
  $value = Get-WorktrunkConfigValue 'show_remote_branches'
  switch ($value) {
    { $_ -ceq '' -or $_ -ceq 'false' } { return 'false' }
    { $_ -ceq 'true' } { return 'true' }
    default {
      Write-WtWarning "unsupported show_remote_branches `"$value`"; hiding remote branches"
      return 'false'
    }
  }
}

# "true"/"false" for whether new branch names are slugified before creation.
# Disabled by default; set slugify_new_branches = true.
function Get-WorktrunkSlugifyNewBranches {
  $value = Get-WorktrunkConfigValue 'slugify_new_branches'
  switch ($value) {
    { $_ -ceq '' -or $_ -ceq 'false' } { return 'false' }
    { $_ -ceq 'true' } { return 'true' }
    default {
      Write-WtWarning "unsupported slugify_new_branches `"$value`"; creating names as typed"
      return 'false'
    }
  }
}

# The configured worktree presentation mode. Native workspace mode is the
# default; set open_mode = "tab" to keep the original tab-based behavior.
function Get-WorktrunkOpenMode {
  $mode = Get-WorktrunkConfigValue 'open_mode'
  switch ($mode) {
    { $_ -ceq '' -or $_ -ceq 'workspace' } { return 'workspace' }
    { $_ -ceq 'tab' } { return 'tab' }
    default {
      Write-WtWarning "unsupported open_mode `"$mode`"; using workspace"
      return 'workspace'
    }
  }
}

# How the picker itself is presented: a split pane below the workspace (the
# default) or a session-modal popup over it. Popups need herdr 0.7.4.
function Get-WorktrunkPickerPlacement {
  $placement = Get-WorktrunkConfigValue 'picker_placement'
  switch ($placement) {
    { $_ -ceq '' -or $_ -ceq 'split' } { return 'split' }
    { $_ -ceq 'popup' } { return 'popup' }
    default {
      Write-WtWarning "unsupported picker_placement `"$placement`"; using split"
      return 'split'
    }
  }
}

# The fzf chrome that suits the picker placement, as an argument array. A split
# pane is full-width, so the picker draws its own inset box to read as a dialog.
# A popup already is one, and herdr frames it with the pane title.
function Get-WorktrunkFzfLayout {
  if ((Get-WorktrunkPickerPlacement) -eq 'popup') {
    return @('--border=none', '--margin=0')
  }
  return @('--border=rounded', '--margin=20%,30%')
}

# The configured popup_width/popup_height, or '' when unset. herdr takes a popup
# dimension as terminal cells (24) or a percentage of the window ("80%"), and
# falls back to a half-size popup when one is omitted. Drop a malformed value
# rather than passing it on and failing the open.
function Get-WorktrunkPopupDimension([string]$Key) {
  $value = Get-WorktrunkConfigValue $Key
  if ($value -ceq '') { return '' }
  if ($value -match '^[0-9]+%?$') { return $value }
  Write-WtWarning "unsupported $Key `"$value`"; using the default popup size"
  return ''
}

# "true"/"false" for whether ACTION's pane (create, merge or remove) waits for a
# key once worktrunk succeeds, so its output can be read before the pane closes.
# Disabled by default. hold_on_<action> decides for that action alone and wins
# over hold_on_success, which covers every action; an unsupported value is
# skipped, so the next key in line still decides.
function Get-WorktrunkHoldOn([string]$Action) {
  foreach ($key in @("hold_on_$Action", 'hold_on_success')) {
    $value = Get-WorktrunkConfigValue $key
    if ($value -ceq '') { continue }
    if ($value -ceq 'true' -or $value -ceq 'false') { return $value }
    Write-WtWarning "unsupported $key `"$value`"; ignoring it"
  }
  return 'false'
}

# The extra flags to pass to `wt merge`, as an array, from the
# whitespace-separated merge_flags value. Only flags that leave the merger's own
# contract intact are accepted: -C, --no-remove and --format are the merger's to
# set, and an unrecognized flag is dropped rather than handed to wt as a broken
# argv. --yes is excluded on purpose: hook approval is the user's call.
function Get-WorktrunkMergeFlags {
  $flags = @()
  $value = Get-WorktrunkConfigValue 'merge_flags'
  foreach ($flag in ($value -split '\s+')) {
    if ($flag -ceq '') { continue }
    switch -CaseSensitive ($flag) {
      { $_ -cin '--no-squash', '--no-rebase', '--no-ff', '--no-commit', '--no-hooks' } { $flags += $flag }
      { $_ -cin '--stage=all', '--stage=tracked', '--stage=none' } { $flags += $flag }
      default { Write-WtWarning "unsupported merge_flags entry `"$flag`"; ignoring it" }
    }
  }
  # Unrolled on return; callers collect with @(Get-WorktrunkMergeFlags).
  return $flags
}

function Test-WorktrunkConfigKey([string]$Key) {
  $file = Get-WorktrunkConfigFile
  if (-not $file) { return $false }
  if (-not (Test-Path -LiteralPath $file)) { return $false }
  return [bool](@(Get-Content -LiteralPath $file -Encoding UTF8 | Where-Object {
    $_ -cmatch ('^\s*' + [regex]::Escape($Key) + '\s*=')
  }).Count)
}

# Single-line TOML strings for label settings. Invalid escapes return an empty
# value so the formatter emits its normal warning and uses the legacy label, as
# do control characters other than tab: labels are single-line.
function Get-WorktrunkLabelConfigValue([string]$Key) {
  $value = Get-WorktrunkLabelConfigText $Key
  if ($value -cmatch '[\x00-\x08\x0A-\x1F\x7F]') { return '' }
  return $value
}

function Get-WorktrunkLabelConfigText([string]$Key) {
  $file = Get-WorktrunkConfigFile
  if (-not $file -or -not (Test-Path -LiteralPath $file)) { return '' }
  $raw = ''
  foreach ($line in (Get-Content -LiteralPath $file -Encoding UTF8)) {
    if ($line -cmatch ('^\s*' + [regex]::Escape($Key) + '\s*=\s*(.*)$')) { $raw = $Matches[1] }
  }
  if ($raw -cnotmatch '^("(?:[^"\\]|\\.)*"|''[^'']*''|[^\s#"'']+)\s*(#.*)?$') { return '' }
  $raw = $Matches[1]
  if ($raw.StartsWith("'")) { return $raw.Substring(1, $raw.Length - 2) }
  if (-not $raw.StartsWith('"')) { return $raw }
  $body = $raw.Substring(1, $raw.Length - 2)
  $decoded = New-Object Text.StringBuilder
  $escapes = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
  $escapes['b'] = [string][char]8; $escapes['t'] = [string][char]9; $escapes['n'] = [string][char]10
  $escapes['f'] = [string][char]12; $escapes['r'] = [string][char]13; $escapes['"'] = '"'; $escapes['\'] = '\'
  for ($i = 0; $i -lt $body.Length; $i++) {
    if ($body[$i] -cne [char]92) { [void]$decoded.Append($body[$i]); continue }
    $i++
    if ($i -ge $body.Length) { return '' }
    $escape = [string]$body[$i]
    if ($escapes.ContainsKey($escape)) { [void]$decoded.Append($escapes[$escape]); continue }
    $width = 0
    if ($escape -ceq 'u') { $width = 4 } elseif ($escape -ceq 'U') { $width = 8 }
    if (-not $width -or $i + $width -ge $body.Length) { return '' }
    $hex = $body.Substring($i + 1, $width)
    if ($hex -cnotmatch '^[0-9A-Fa-f]+$') { return '' }
    try {
      $scalar = [Convert]::ToInt32($hex, 16)
      if ($scalar -eq 0) { return '' }
      [void]$decoded.Append([char]::ConvertFromUtf32($scalar))
    } catch { return '' }
    $i += $width
  }
  return $decoded.ToString()
}
