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
assert_mode tab

config_dir=$(mktemp -d)
trap 'rm -rf "$config_dir"' EXIT
export HERDR_PLUGIN_CONFIG_DIR=$config_dir

assert_mode tab

printf 'open_mode = "workspace"\n' > "$config_dir/config.toml"
assert_mode workspace

printf 'open_mode = "tab" # keep the original presentation\n' > "$config_dir/config.toml"
assert_mode tab

printf 'open_mode = "unsupported"\n' > "$config_dir/config.toml"
assert_mode tab

printf 'config tests passed\n'
