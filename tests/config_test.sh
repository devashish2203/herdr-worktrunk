#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../config.sh
source "$repo_root/config.sh"

assert_mode() {
  local expected=$1 actual
  actual=$(worktrunk_open_mode 2>/dev/null)
  if [[ $actual != "$expected" ]]; then
    printf 'expected mode %q, got %q\n' "$expected" "$actual" >&2
    exit 1
  fi
}

unset HERDR_PLUGIN_CONFIG_DIR
assert_mode workspace

config_dir=$(mktemp -d)
trap 'rm -rf "$config_dir"' EXIT
export HERDR_PLUGIN_CONFIG_DIR=$config_dir

assert_mode workspace

printf 'open_mode = "tab"\n' > "$config_dir/config.toml"
assert_mode tab

printf 'open_mode = "workspace" # native worktree workspace\n' > "$config_dir/config.toml"
assert_mode workspace

printf 'open_mode = "unsupported"\n' > "$config_dir/config.toml"
assert_mode workspace

assert_remote() {
  local expected=$1 actual
  actual=$(worktrunk_show_remote_branches 2>/dev/null)
  if [[ $actual != "$expected" ]]; then
    printf 'expected show_remote_branches %q, got %q\n' "$expected" "$actual" >&2
    exit 1
  fi
}

printf 'open_mode = "tab"\n' > "$config_dir/config.toml"   # unrelated key → default
assert_remote false

printf 'show_remote_branches = true\n' > "$config_dir/config.toml"    # bare TOML bool
assert_remote true

printf 'show_remote_branches = "false"\n' > "$config_dir/config.toml" # quoted also ok
assert_remote false

printf 'show_remote_branches = maybe\n' > "$config_dir/config.toml"   # unsupported → default
assert_remote false

assert_slugify() {
  local expected=$1 actual
  actual=$(worktrunk_slugify_new_branches 2>/dev/null)
  if [[ $actual != "$expected" ]]; then
    printf 'expected slugify_new_branches %q, got %q\n' "$expected" "$actual" >&2
    exit 1
  fi
}

printf 'open_mode = "tab"\n' > "$config_dir/config.toml"   # unrelated key → default
assert_slugify false

printf 'slugify_new_branches = true\n' > "$config_dir/config.toml"
assert_slugify true

printf 'slugify_new_branches = "false"\n' > "$config_dir/config.toml"
assert_slugify false

printf 'slugify_new_branches = yes\n' > "$config_dir/config.toml"      # unsupported → default
assert_slugify false

assert_placement() {
  local expected=$1 actual
  actual=$(worktrunk_picker_placement 2>/dev/null)
  if [[ $actual != "$expected" ]]; then
    printf 'expected picker_placement %q, got %q\n' "$expected" "$actual" >&2
    exit 1
  fi
}

printf 'open_mode = "tab"\n' > "$config_dir/config.toml"   # unrelated key → default
assert_placement split

printf 'picker_placement = "popup"\n' > "$config_dir/config.toml"
assert_placement popup

printf 'picker_placement = split\n' > "$config_dir/config.toml"        # bare TOML also ok
assert_placement split

printf 'picker_placement = "overlay"\n' > "$config_dir/config.toml"    # unsupported → default
assert_placement split

assert_fzf_layout() {
  local expected=$1
  worktrunk_fzf_layout
  if [[ "${WORKTRUNK_FZF_LAYOUT[*]}" != "$expected" ]]; then
    printf 'expected fzf layout %q, got %q\n' "$expected" "${WORKTRUNK_FZF_LAYOUT[*]}" >&2
    exit 1
  fi
}

printf 'picker_placement = "split"\n' > "$config_dir/config.toml"
assert_fzf_layout '--border=rounded --margin=20%,30%'

printf 'picker_placement = "popup"\n' > "$config_dir/config.toml"
assert_fzf_layout '--border=none --margin=0'

assert_dimension() {
  local key=$1 expected=$2 actual
  actual=$(worktrunk_popup_dimension "$key" 2>/dev/null)
  if [[ $actual != "$expected" ]]; then
    printf 'expected %s %q, got %q\n' "$key" "$expected" "$actual" >&2
    exit 1
  fi
}

printf 'picker_placement = "popup"\n' > "$config_dir/config.toml"      # unset → herdr's default
assert_dimension popup_width ""
assert_dimension popup_height ""

printf 'popup_width = "80%%"\npopup_height = 24\n' > "$config_dir/config.toml"
assert_dimension popup_width "80%"
assert_dimension popup_height 24

printf 'popup_width = "80 %%"\n' > "$config_dir/config.toml"           # malformed → dropped
assert_dimension popup_width ""

printf 'popup_height = "%%50"\n' > "$config_dir/config.toml"           # malformed → dropped
assert_dimension popup_height ""

assert_merge_flags() {
  local expected=$1 actual
  actual=$(worktrunk_merge_flags 2>/dev/null | tr '\n' ' ')
  actual=${actual% }
  if [[ $actual != "$expected" ]]; then
    printf 'expected merge_flags %q, got %q\n' "$expected" "$actual" >&2
    exit 1
  fi
}

printf 'open_mode = "tab"\n' > "$config_dir/config.toml"   # unrelated key → no flags
assert_merge_flags ""

printf 'merge_flags = "--no-squash"\n' > "$config_dir/config.toml"
assert_merge_flags "--no-squash"

printf 'merge_flags = "--no-squash --no-rebase --stage=tracked"\n' > "$config_dir/config.toml"
assert_merge_flags "--no-squash --no-rebase --stage=tracked"

# Unrecognized entries are dropped, the rest still pass through.
printf 'merge_flags = "--no-squash --wat --stage=some"\n' > "$config_dir/config.toml"
assert_merge_flags "--no-squash"

# Flags the merger owns can't be overridden from config.
printf 'merge_flags = "--no-remove --format=json -C /tmp --yes"\n' > "$config_dir/config.toml"
assert_merge_flags ""

# One config.toml may be shared between macOS/Linux and Windows, so
# worktrunk_config_value and config.ps1's Get-WorktrunkConfigValue must read it
# the same way: config_test.ps1 runs this same table.
assert_value() {
  local key=$1 expected=$2 actual
  actual=$(worktrunk_config_value "$key")
  if [[ $actual != "$expected" ]]; then
    printf 'expected %s %q, got %q\n' "$key" "$expected" "$actual" >&2
    exit 1
  fi
}

printf '%s\n' 'open_mode = "tab"' > "$config_dir/config.toml"
assert_value open_mode tab

# Single-quoted TOML literals, the natural form for Windows paths, lose their
# quotes and keep spaces and backslashes as written.
printf '%s\n' "worktrunk_bin = 'C:\path\to\wt.exe'" > "$config_dir/config.toml"
assert_value worktrunk_bin 'C:\path\to\wt.exe'

printf '%s\n' "worktrunk_bin = 'C:\Program Files\worktrunk\wt.exe'" > "$config_dir/config.toml"
assert_value worktrunk_bin 'C:\Program Files\worktrunk\wt.exe'

printf '%s\n' "worktrunk_bin = 'C:\tools\wt.exe' # literal" > "$config_dir/config.toml"
assert_value worktrunk_bin 'C:\tools\wt.exe'

printf '%s\n' 'worktrunk_bin = "C:\\tools\\wt.exe"' > "$config_dir/config.toml"   # escapes kept as written
assert_value worktrunk_bin 'C:\\tools\\wt.exe'

printf '%s\n' 'open_mode = "tab" # note' > "$config_dir/config.toml"
assert_value open_mode tab

printf '%s\n' 'open_mode = "a # b" # note' > "$config_dir/config.toml"   # a quoted # is no comment
assert_value open_mode 'a # b'

printf '%s\n' "open_mode = 'a # b' # note" > "$config_dir/config.toml"
assert_value open_mode 'a # b'

printf '%s\n' "open_mode = 'say \"hi\"'" > "$config_dir/config.toml"
assert_value open_mode 'say "hi"'

printf '%s\n' "open_mode = ''" > "$config_dir/config.toml"
assert_value open_mode ''

printf '%s\n' 'open_mode = ""' > "$config_dir/config.toml"
assert_value open_mode ''

printf '%s\n' 'show_remote_branches = true # note' > "$config_dir/config.toml"
assert_value show_remote_branches true

printf ' \topen_mode = tab\n' > "$config_dir/config.toml"                 # leading whitespace
assert_value open_mode tab

printf '%s\n' 'open_mode="tab"' > "$config_dir/config.toml"
assert_value open_mode tab

printf '%s\n' 'open_mode = "tab"' 'open_mode = "workspace"' > "$config_dir/config.toml"   # last one wins
assert_value open_mode workspace

printf '%s\n' '# open_mode = "tab"' > "$config_dir/config.toml"           # commented out
assert_value open_mode ''

printf '%s\n' 'open_mode = "workspace"' '# open_mode = "tab"' > "$config_dir/config.toml"
assert_value open_mode workspace

# A key never matches a longer key that it is a prefix of, or another case.
printf '%s\n' 'hold_on_success = true' > "$config_dir/config.toml"
assert_value hold_on ''

printf '%s\n' 'hold_on = "x"' 'hold_on_success = true' > "$config_dir/config.toml"
assert_value hold_on x
assert_value hold_on_success true

printf '%s\n' 'OPEN_MODE = "tab"' > "$config_dir/config.toml"
assert_value open_mode ''

# Not TOML: a bare value can't hold a quote, so it reads as unset.
printf '%s\n' "open_mode = it's" > "$config_dir/config.toml"
assert_value open_mode ''

# What a Windows editor may write: a UTF-8 BOM, CRLF line ends, non-ASCII text.
printf '\357\273\277%s\n' 'open_mode = "tab"' > "$config_dir/config.toml"
assert_value open_mode tab

printf '%s\r\n' 'open_mode = "tab"' 'show_remote_branches = true' "worktrunk_bin = 'C:\tools\wt.exe' # literal" \
  > "$config_dir/config.toml"
assert_value open_mode tab
assert_value show_remote_branches true
assert_value worktrunk_bin 'C:\tools\wt.exe'

printf '%s\n' "worktrunk_bin = 'C:\Users\Zoë\wt.exe'" > "$config_dir/config.toml"
assert_value worktrunk_bin 'C:\Users\Zoë\wt.exe'

assert_hold() {
  local action=$1 expected=$2 actual
  actual=$(worktrunk_hold_on "$action" 2>/dev/null)
  if [[ $actual != "$expected" ]]; then
    printf 'expected hold on %s %q, got %q\n' "$action" "$expected" "$actual" >&2
    exit 1
  fi
}

printf 'open_mode = "tab"\n' > "$config_dir/config.toml"   # unrelated key → default
assert_hold create false
assert_hold merge false
assert_hold remove false

printf 'hold_on_success = true\n' > "$config_dir/config.toml"          # covers every action
assert_hold create true
assert_hold merge true
assert_hold remove true

printf 'hold_on_merge = "true"\n' > "$config_dir/config.toml"          # one action, quoted also ok
assert_hold create false
assert_hold merge true
assert_hold remove false

# The action's own key wins over hold_on_success, in either direction.
printf 'hold_on_success = true\nhold_on_remove = false\n' > "$config_dir/config.toml"
assert_hold create true
assert_hold merge true
assert_hold remove false

printf 'hold_on_success = false\nhold_on_create = true\n' > "$config_dir/config.toml"
assert_hold create true
assert_hold merge false

# An unsupported value is ignored, so the next key in line still decides.
printf 'hold_on_success = true\nhold_on_merge = maybe\n' > "$config_dir/config.toml"
assert_hold merge true

printf 'hold_on_success = maybe\n' > "$config_dir/config.toml"
assert_hold merge false

printf 'config tests passed\n'
