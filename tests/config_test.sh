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

printf 'config tests passed\n'
