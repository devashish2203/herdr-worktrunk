#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../helpers.sh
source "$repo_root/helpers.sh"

for tok in '^' '-' 'pr:123' 'mr:45' 'https://github.com/o/r/pull/7'; do
  if ! worktrunk_is_shortcut "$tok"; then
    printf 'expected %q to be a worktrunk shortcut\n' "$tok" >&2
    exit 1
  fi
done

# @ (current) is intentionally not a shortcut — see helpers.sh.
for tok in 'my-feature' 'main' 'feature/foo' '@'; do
  if worktrunk_is_shortcut "$tok"; then
    printf 'expected %q not to be a worktrunk shortcut\n' "$tok" >&2
    exit 1
  fi
done

# worktrunk_ref_exists resolves both local heads and remote-tracking branches.
sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox" "$sandbox.linked"' EXIT
(
  cd "$sandbox"
  git init -q
  git config user.email test@example.com
  git config user.name test
  git commit -q --allow-empty -m init
  git branch feature
  git update-ref refs/remotes/origin/remote-feat HEAD
)
cd "$sandbox"

for ref in 'feature' 'origin/remote-feat'; do
  if ! worktrunk_ref_exists "$ref"; then
    printf 'expected %q to be an existing ref\n' "$ref" >&2
    exit 1
  fi
done

for ref in 'does-not-exist' 'origin/nope'; do
  if worktrunk_ref_exists "$ref"; then
    printf 'expected %q not to be an existing ref\n' "$ref" >&2
    exit 1
  fi
done

# worktrunk_worktree_paths emits every worktree's physical path, one per line.
git worktree add -q "$sandbox.linked" feature
expected_paths=$(printf '%s\n%s\n' \
  "$(cd "$sandbox" && pwd -P)" \
  "$(cd "$sandbox.linked" && pwd -P)")
actual_paths=$(worktrunk_worktree_paths)
if [[ $actual_paths != "$expected_paths" ]]; then
  printf 'unexpected worktree paths:\n%s\nexpected:\n%s\n' "$actual_paths" "$expected_paths" >&2
  exit 1
fi

cd - >/dev/null

schema_one='[
  {"branch":"main","kind":"worktree","path":"/repo","is_main":true},
  {"branch":"feature","kind":"worktree","path":"/repo.feature","is_main":false},
  {"branch":"ready","kind":"branch"}
]'
schema_two='{
  "schema":2,
  "items":[
    {"branch":"main","worktree":{"path":"/repo","main":true}},
    {"branch":"feature","worktree":{"path":"/repo.feature","main":false}},
    {"branch":"ready"}
  ]
}'
expected_items='main|worktree|/repo|true
feature|worktree|/repo.feature|false
ready|branch|null|false'

for list_json in "$schema_one" "$schema_two"; do
  actual_items=$(printf '%s\n' "$list_json" \
    | worktrunk_list_items \
    | jq -r '[.branch, .kind, (.path | tostring), (.is_main | tostring)] | join("|")')
  if [[ $actual_items != "$expected_items" ]]; then
    printf 'unexpected normalized worktrunk list items:\n%s\n' "$actual_items" >&2
    exit 1
  fi
done

if printf '%s\n' '{"schema":3}' | worktrunk_list_items >/dev/null 2>&1; then
  printf 'expected unsupported worktrunk list schema to fail\n' >&2
  exit 1
fi

printf 'helpers tests passed\n'
