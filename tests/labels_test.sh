#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/config.sh"
source "$root/helpers.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export HERDR_PLUGIN_CONFIG_DIR="$tmp"
assert_eq() { [[ $1 == "$2" ]] || { printf 'expected %q, got %q\n' "$1" "$2" >&2; exit 1; }; }
while IFS= read -r item; do
  # TOML literals keep every fixture value literal, including backslashes.
  printf '%s' "$item" | jq -r 'if has("config_raw") then .config_raw else .config | to_entries[] | .key + " = \u0027" + .value + "\u0027" end' > "$tmp/config.toml"
  branch=$(jq -r .branch <<< "$item")
  name=$(jq -r .selection <<< "$item")
  repo=$(jq -r .repo <<< "$item")
  pr=$(jq -r '.pr // ""' <<< "$item")
  result=$(worktrunk_switch_label "$branch" "$name" "$repo" "$pr" 2>"$tmp/warning")
  assert_eq "$(jq -r .expected <<< "$item")" "$result"
  if [[ $(jq -r .warning <<< "$item") == true ]]; then
    [[ -s $tmp/warning ]] || { echo 'missing warning' >&2; exit 1; }
  else
    assert_eq '' "$(cat "$tmp/warning")"
  fi
done < <(jq -c '.[]' "$root/tests/label_cases.json")

# State lives in each linked worktree's git directory, not the main checkout.
git init -q --initial-branch=main "$tmp/repo"
git -C "$tmp/repo" -c commit.gpgsign=false -c user.email=t@example.com -c user.name=test commit -q --allow-empty -m init
git -C "$tmp/repo" worktree add -q -b feature/login "$tmp/checkout"
printf 'label_preset = "default"\n' > "$tmp/config.toml"
worktrunk_prepare_label "$tmp/checkout" feature/login pr:123 repo
assert_eq 'feature/login (pr:123)' "$WORKTRUNK_LABEL"
worktrunk_save_label feature/login
worktrunk_prepare_label "$tmp/checkout" feature/login feature/login repo 'feature/login (pr:123)'
assert_eq 'feature/login (pr:123)' "$WORKTRUNK_LABEL"
assert_eq true "$WORKTRUNK_MANAGED"
# Keeping the existing PR annotation also works when no preset is configured.
: > "$tmp/config.toml"
worktrunk_prepare_label "$tmp/checkout" feature/login feature/login repo 'feature/login (pr:123)'
assert_eq 'feature/login (pr:123)' "$WORKTRUNK_LABEL"
printf 'label_preset = "pr-first"\n' > "$tmp/config.toml"
worktrunk_prepare_label "$tmp/checkout" feature/login pr:123 repo
assert_eq '#123 feature/login' "$WORKTRUNK_LABEL"
worktrunk_save_label feature/login
worktrunk_prepare_label "$tmp/checkout" feature/login feature/login repo '#123 feature/login'
assert_eq 123 "$WORKTRUNK_PR"
assert_eq true "$WORKTRUNK_MANAGED"
assert_eq '#123 feature/login' "$WORKTRUNK_LABEL"
printf 'label_preset = "pr-only"\n' > "$tmp/config.toml"
worktrunk_prepare_label "$tmp/checkout" feature/login feature/login repo '#123 feature/login'
assert_eq true "$WORKTRUNK_MANAGED"
assert_eq '#123' "$WORKTRUNK_LABEL"
worktrunk_save_label feature/login
worktrunk_prepare_label "$tmp/checkout" feature/login feature/login repo 'My manual name'
assert_eq false "$WORKTRUNK_MANAGED"
worktrunk_save_label feature/login
worktrunk_prepare_label "$tmp/checkout" feature/login feature/login repo 'My manual name'
assert_eq false "$WORKTRUNK_MANAGED"
assert_eq 123 "$WORKTRUNK_PR"
worktrunk_prepare_label "$tmp/checkout" different different repo
assert_eq '' "$WORKTRUNK_PR"
assert_eq different "$WORKTRUNK_LABEL"
worktrunk_prepare_label "$tmp/repo" main main repo
assert_eq '' "$WORKTRUNK_PR"
assert_eq '' "$WORKTRUNK_STATE"
worktrunk_save_label main
[[ ! -e $tmp/repo/.git/herdr-worktrunk-label ]] || { echo 'unexpected main checkout label state' >&2; exit 1; }
printf 'label tests passed\n'
