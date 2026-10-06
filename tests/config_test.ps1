# Windows PowerShell 5.1 port of config_test.sh: configuration parser checks.
$ErrorActionPreference = 'Continue'
# A test that throws must fail, not skip its remaining checks and report
# success: with no catch, an error inside try { } finally { } leaves the try
# and the script carries on to its "passed" line.
trap { [Console]::Error.WriteLine("test aborted: $_"); exit 1 }

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'config.ps1')

function Assert-Eq($Expected, $Actual, $What = 'value') {
  if ([string]$Actual -cne [string]$Expected) {
    [Console]::Error.WriteLine("expected $What '$Expected', got '$Actual'")
    exit 1
  }
}

$configDir = Join-Path ([System.IO.Path]::GetTempPath()) ("wt-config-test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $configDir | Out-Null
try {
  $env:HERDR_PLUGIN_CONFIG_DIR = $null
  Assert-Eq 'workspace' (Get-WorktrunkOpenMode) 'mode'

  $env:HERDR_PLUGIN_CONFIG_DIR = $configDir
  $configFile = Join-Path $configDir 'config.toml'

  Assert-Eq 'workspace' (Get-WorktrunkOpenMode) 'mode'

  Set-Content -LiteralPath $configFile -Value 'open_mode = "tab"'
  Assert-Eq 'tab' (Get-WorktrunkOpenMode) 'mode'

  Set-Content -LiteralPath $configFile -Value 'open_mode = "workspace" # native worktree workspace'
  Assert-Eq 'workspace' (Get-WorktrunkOpenMode) 'mode'

  Set-Content -LiteralPath $configFile -Value 'open_mode = "unsupported"'
  Assert-Eq 'workspace' (Get-WorktrunkOpenMode) 'mode'

  Set-Content -LiteralPath $configFile -Value 'open_mode = "tab"'   # unrelated key -> default
  Assert-Eq 'false' (Get-WorktrunkShowRemoteBranches) 'show_remote_branches'

  Set-Content -LiteralPath $configFile -Value 'show_remote_branches = true'    # bare TOML bool
  Assert-Eq 'true' (Get-WorktrunkShowRemoteBranches) 'show_remote_branches'

  Set-Content -LiteralPath $configFile -Value 'show_remote_branches = "false"' # quoted also ok
  Assert-Eq 'false' (Get-WorktrunkShowRemoteBranches) 'show_remote_branches'

  Set-Content -LiteralPath $configFile -Value 'show_remote_branches = maybe'   # unsupported -> default
  Assert-Eq 'false' (Get-WorktrunkShowRemoteBranches) 'show_remote_branches'

  Set-Content -LiteralPath $configFile -Value 'open_mode = "tab"'   # unrelated key -> default
  Assert-Eq 'split' (Get-WorktrunkPickerPlacement) 'picker_placement'

  Set-Content -LiteralPath $configFile -Value 'picker_placement = "popup"'
  Assert-Eq 'popup' (Get-WorktrunkPickerPlacement) 'picker_placement'

  Set-Content -LiteralPath $configFile -Value 'picker_placement = split'       # bare TOML also ok
  Assert-Eq 'split' (Get-WorktrunkPickerPlacement) 'picker_placement'

  Set-Content -LiteralPath $configFile -Value 'picker_placement = "overlay"'   # unsupported -> default
  Assert-Eq 'split' (Get-WorktrunkPickerPlacement) 'picker_placement'

  Set-Content -LiteralPath $configFile -Value 'picker_placement = "split"'
  Assert-Eq '--border=rounded --margin=20%,30%' ((Get-WorktrunkFzfLayout) -join ' ') 'fzf layout'

  Set-Content -LiteralPath $configFile -Value 'picker_placement = "popup"'
  Assert-Eq '--border=none --margin=0' ((Get-WorktrunkFzfLayout) -join ' ') 'fzf layout'

  Set-Content -LiteralPath $configFile -Value 'picker_placement = "popup"'     # unset -> herdr's default
  Assert-Eq '' (Get-WorktrunkPopupDimension 'popup_width') 'popup_width'
  Assert-Eq '' (Get-WorktrunkPopupDimension 'popup_height') 'popup_height'

  Set-Content -LiteralPath $configFile -Value @('popup_width = "80%"', 'popup_height = 24')
  Assert-Eq '80%' (Get-WorktrunkPopupDimension 'popup_width') 'popup_width'
  Assert-Eq '24' (Get-WorktrunkPopupDimension 'popup_height') 'popup_height'

  Set-Content -LiteralPath $configFile -Value 'popup_width = "80 %"'           # malformed -> dropped
  Assert-Eq '' (Get-WorktrunkPopupDimension 'popup_width') 'popup_width'

  Set-Content -LiteralPath $configFile -Value 'popup_height = "%50"'           # malformed -> dropped
  Assert-Eq '' (Get-WorktrunkPopupDimension 'popup_height') 'popup_height'

  Set-Content -LiteralPath $configFile -Value 'open_mode = "tab"'   # unrelated key -> no flags
  Assert-Eq '' ((Get-WorktrunkMergeFlags) -join ' ') 'merge_flags'

  Set-Content -LiteralPath $configFile -Value 'merge_flags = "--no-squash"'
  Assert-Eq '--no-squash' ((Get-WorktrunkMergeFlags) -join ' ') 'merge_flags'

  Set-Content -LiteralPath $configFile -Value 'merge_flags = "--no-squash --no-rebase --stage=tracked"'
  Assert-Eq '--no-squash --no-rebase --stage=tracked' ((Get-WorktrunkMergeFlags) -join ' ') 'merge_flags'

  # Unrecognized entries are dropped, the rest still pass through.
  Set-Content -LiteralPath $configFile -Value 'merge_flags = "--no-squash --wat --stage=some"'
  Assert-Eq '--no-squash' ((Get-WorktrunkMergeFlags) -join ' ') 'merge_flags'

  # Flags the merger owns can't be overridden from config.
  Set-Content -LiteralPath $configFile -Value 'merge_flags = "--no-remove --format=json -C /tmp --yes"'
  Assert-Eq '' ((Get-WorktrunkMergeFlags) -join ' ') 'merge_flags'

  # One config.toml may be shared between Windows and macOS/Linux, so
  # Get-WorktrunkConfigValue and config.sh's worktrunk_config_value must read it
  # the same way: config_test.sh runs this same table. Set-Config writes the
  # bytes the bash side does: UTF-8 without a BOM, LF line ends.
  function Set-Config([string[]]$Lines, [string]$Eol = "`n", [string]$Prefix = '') {
    $text = $Prefix + (($Lines | ForEach-Object { $_ + $Eol }) -join '')
    [IO.File]::WriteAllText($configFile, $text, (New-Object System.Text.UTF8Encoding $false))
  }
  function Assert-Value([string]$Key, [string]$Expected) {
    Assert-Eq $Expected (Get-WorktrunkConfigValue $Key) $Key
  }

  Set-Config 'open_mode = "tab"'
  Assert-Value open_mode tab

  # Single-quoted TOML literals, the natural form for Windows paths, lose their
  # quotes and keep spaces and backslashes as written.
  Set-Config "worktrunk_bin = 'C:\path\to\wt.exe'"
  Assert-Value worktrunk_bin 'C:\path\to\wt.exe'

  Set-Config "worktrunk_bin = 'C:\Program Files\worktrunk\wt.exe'"
  Assert-Value worktrunk_bin 'C:\Program Files\worktrunk\wt.exe'

  Set-Config "worktrunk_bin = 'C:\tools\wt.exe' # literal"
  Assert-Value worktrunk_bin 'C:\tools\wt.exe'

  Set-Config 'worktrunk_bin = "C:\\tools\\wt.exe"'   # escapes kept as written
  Assert-Value worktrunk_bin 'C:\\tools\\wt.exe'

  Set-Config 'open_mode = "tab" # note'
  Assert-Value open_mode tab

  Set-Config 'open_mode = "a # b" # note'   # a quoted # is no comment
  Assert-Value open_mode 'a # b'

  Set-Config "open_mode = 'a # b' # note"
  Assert-Value open_mode 'a # b'

  Set-Config "open_mode = 'say `"hi`"'"
  Assert-Value open_mode 'say "hi"'

  Set-Config "open_mode = ''"
  Assert-Value open_mode ''

  Set-Config 'open_mode = ""'
  Assert-Value open_mode ''

  Set-Config 'show_remote_branches = true # note'
  Assert-Value show_remote_branches true

  Set-Config " `topen_mode = tab"                 # leading whitespace
  Assert-Value open_mode tab

  Set-Config 'open_mode="tab"'
  Assert-Value open_mode tab

  Set-Config @('open_mode = "tab"', 'open_mode = "workspace"')   # last one wins
  Assert-Value open_mode workspace

  Set-Config '# open_mode = "tab"'           # commented out
  Assert-Value open_mode ''

  Set-Config @('open_mode = "workspace"', '# open_mode = "tab"')
  Assert-Value open_mode workspace

  # A key never matches a longer key that it is a prefix of, or another case.
  Set-Config 'hold_on_success = true'
  Assert-Value hold_on ''

  Set-Config @('hold_on = "x"', 'hold_on_success = true')
  Assert-Value hold_on x
  Assert-Value hold_on_success true

  Set-Config 'OPEN_MODE = "tab"'
  Assert-Value open_mode ''

  # Not TOML: a bare value can't hold a quote, so it reads as unset.
  Set-Config "open_mode = it's"
  Assert-Value open_mode ''

  # What a Windows editor may write: a UTF-8 BOM, CRLF line ends, non-ASCII text.
  Set-Config 'open_mode = "tab"' -Prefix ([string][char]0xFEFF)
  Assert-Value open_mode tab

  Set-Config @('open_mode = "tab"', 'show_remote_branches = true', "worktrunk_bin = 'C:\tools\wt.exe' # literal") -Eol "`r`n"
  Assert-Value open_mode tab
  Assert-Value show_remote_branches true
  Assert-Value worktrunk_bin 'C:\tools\wt.exe'

  Set-Config "worktrunk_bin = 'C:\Users\Zo$([char]0xEB)\wt.exe'"
  Assert-Value worktrunk_bin "C:\Users\Zo$([char]0xEB)\wt.exe"

  Set-Content -LiteralPath $configFile -Value 'open_mode = "tab"'   # unrelated key -> default
  Assert-Eq 'false' (Get-WorktrunkSlugifyNewBranches) 'slugify_new_branches'
  Set-Content -LiteralPath $configFile -Value 'slugify_new_branches = true'
  Assert-Eq 'true' (Get-WorktrunkSlugifyNewBranches) 'slugify_new_branches'
  Set-Content -LiteralPath $configFile -Value 'slugify_new_branches = "false"'
  Assert-Eq 'false' (Get-WorktrunkSlugifyNewBranches) 'slugify_new_branches'
  Set-Content -LiteralPath $configFile -Value 'slugify_new_branches = yes'      # unsupported -> default
  Assert-Eq 'false' (Get-WorktrunkSlugifyNewBranches 2>$null) 'slugify_new_branches'

  function Assert-Hold([string]$Action, [string]$Expected) {
    Assert-Eq $Expected (Get-WorktrunkHoldOn $Action 2>$null) "hold on $Action"
  }

  Set-Content -LiteralPath $configFile -Value 'open_mode = "tab"'   # unrelated key -> default
  Assert-Hold create false
  Assert-Hold merge false
  Assert-Hold remove false

  Set-Content -LiteralPath $configFile -Value 'hold_on_success = true'          # covers every action
  Assert-Hold create true
  Assert-Hold merge true
  Assert-Hold remove true

  Set-Content -LiteralPath $configFile -Value 'hold_on_merge = "true"'          # one action, quoted also ok
  Assert-Hold create false
  Assert-Hold merge true
  Assert-Hold remove false

  # The action's own key wins over hold_on_success, in either direction.
  Set-Content -LiteralPath $configFile -Value @('hold_on_success = true', 'hold_on_remove = false')
  Assert-Hold create true
  Assert-Hold merge true
  Assert-Hold remove false

  Set-Content -LiteralPath $configFile -Value @('hold_on_success = false', 'hold_on_create = true')
  Assert-Hold create true
  Assert-Hold merge false

  # An unsupported value is ignored, so the next key in line still decides.
  Set-Content -LiteralPath $configFile -Value @('hold_on_success = true', 'hold_on_merge = maybe')
  Assert-Hold merge true

  Set-Content -LiteralPath $configFile -Value 'hold_on_success = maybe'
  Assert-Hold merge false

  # herdr may hand the config dir over in extended-length form (\\?\C:\...),
  # like it does the plugin root; values must still be found.
  Set-Content -LiteralPath $configFile -Value 'open_mode = "tab"'
  $env:HERDR_PLUGIN_CONFIG_DIR = '\\?\' + $configDir
  Assert-Eq 'tab' (Get-WorktrunkOpenMode) 'mode'
  $env:HERDR_PLUGIN_CONFIG_DIR = $configDir
} finally {
  Remove-Item -Recurse -Force -LiteralPath $configDir -ErrorAction SilentlyContinue
}

Write-Output 'config tests passed'
exit 0
