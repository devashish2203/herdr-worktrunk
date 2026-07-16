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

assert_create_base() {
  local expected=$1 actual
  actual=$(worktrunk_create_base 2>/dev/null)
  if [[ $actual != "$expected" ]]; then
    printf 'expected create_base %q, got %q\n' "$expected" "$actual" >&2
    exit 1
  fi
}

unset HERDR_PLUGIN_CONFIG_DIR
assert_mode workspace
assert_create_base ""

config_dir=$(mktemp -d)
trap 'rm -rf "$config_dir"' EXIT
export HERDR_PLUGIN_CONFIG_DIR=$config_dir

assert_mode workspace
assert_create_base ""

printf 'open_mode = "tab"\n' > "$config_dir/config.toml"
assert_mode tab

printf 'open_mode = "workspace" # native worktree workspace\ncreate_base = "@"\n' > "$config_dir/config.toml"
assert_mode workspace
assert_create_base "@"

printf 'create_base = "release/1.4.6" # fixed base\n' > "$config_dir/config.toml"
assert_create_base "release/1.4.6"

printf 'open_mode = "unsupported"\n' > "$config_dir/config.toml"
assert_mode workspace
assert_create_base ""

printf 'config tests passed\n'
