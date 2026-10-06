# Windows PowerShell 5.1 port of open.sh: shared entrypoint for the plugin's
# workspace actions. Resolves the repo to run in, then opens ENTRYPOINT with the
# configured picker placement.
#
# Plugin panes default their cwd to the plugin root, so the workspace's repo
# (from the injected context JSON) has to be passed explicitly. Otherwise `wt`
# runs in the plugin dir, not the repo you're in.

if (-not $args -or -not $args[0]) {
  [Console]::Error.WriteLine('usage: open.ps1 <entrypoint>')
  exit 2
}
$entrypoint = [string]$args[0]

# herdr hands HERDR_PLUGIN_ROOT to plugins in Windows extended-length form
# (\\?\C:\...), which Join-Path and friends reject in Windows PowerShell -
# strip the prefix before building any path on it.
$pluginRoot = $env:HERDR_PLUGIN_ROOT
if (-not $pluginRoot) { $pluginRoot = $PSScriptRoot }
if ($pluginRoot.StartsWith('\\?\UNC\')) { $pluginRoot = '\\' + $pluginRoot.Substring(8) }
elseif ($pluginRoot.StartsWith('\\?\')) { $pluginRoot = $pluginRoot.Substring(4) }
. "$pluginRoot\config.ps1"

$cwd = $null
try {
  $context = ConvertFrom-Json -InputObject $env:HERDR_PLUGIN_CONTEXT_JSON
  if ($context.workspace_cwd) { $cwd = $context.workspace_cwd }
  elseif ($context.focused_pane_cwd) { $cwd = $context.focused_pane_cwd }
} catch {}
if (-not $cwd) {
  Write-WtError 'no workspace cwd in HERDR_PLUGIN_CONTEXT_JSON'
  exit 1
}

$herdr = $env:HERDR_BIN_PATH
if (-not $herdr) { $herdr = 'herdr' }
$pluginId = $env:HERDR_PLUGIN_ID
if (-not $pluginId) { $pluginId = 'worktrunk' }

$herdrArgs = @(
  'plugin', 'pane', 'open',
  '--plugin', $pluginId,
  '--entrypoint', $entrypoint,
  '--cwd', $cwd,
  '--focus')

if ((Get-WorktrunkPickerPlacement) -eq 'popup') {
  $herdrArgs += @('--placement', 'popup')

  $width = Get-WorktrunkPopupDimension 'popup_width'
  $height = Get-WorktrunkPopupDimension 'popup_height'
  if ($width) { $herdrArgs += @('--width', $width) }
  if ($height) { $herdrArgs += @('--height', $height) }

  # A popup is session-modal and belongs to no pane, so herdr injects none of
  # HERDR_WORKSPACE_ID/HERDR_TAB_ID/HERDR_PANE_ID into it. The picker opens the
  # checkout in a workspace, so hand it the one the action was invoked from.
  if ($env:HERDR_WORKSPACE_ID) {
    $herdrArgs += @('--env', "HERDR_WORKSPACE_ID=$($env:HERDR_WORKSPACE_ID)")
  }
} else {
  $herdrArgs += @('--placement', 'split', '--direction', 'down')
}

& $herdr @herdrArgs
exit $LASTEXITCODE
