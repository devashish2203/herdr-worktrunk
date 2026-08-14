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

printf 'config tests passed\n'
