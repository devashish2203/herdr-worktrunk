#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# A repo with a primary checkout and one linked worktree standing in for a
# checkout the picker just created.
repo=$work/repo
git init -q "$repo"
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name test
git -C "$repo" commit -q --allow-empty -m init
git -C "$repo" branch feature
git -C "$repo" worktree add -q "$work/linked" feature

linked_phys=$(cd "$work/linked" && pwd -P)
repo_phys=$(cd "$repo" && pwd -P)
snap=$work/snapshot
hook=$work/hook.sh

run_in_linked() {
  (cd "$work/linked" && bash "$repo_root/run-hook.sh" "$snap" "$hook" post-create)
}

# Worktree already in the snapshot → pre-existing checkout: the hook must
# not run, and the snapshot is still consumed.
printf 'touch ran-for-existing\n' > "$hook"
printf '%s\n' "$linked_phys" > "$snap"
run_in_linked >/dev/null
if [[ -e $work/linked/ran-for-existing ]]; then
  printf 'hook ran for a pre-existing worktree\n' >&2
  exit 1
fi
if [[ -e $snap ]]; then
  printf 'snapshot not consumed for a pre-existing worktree\n' >&2
  exit 1
fi

# Worktree missing from the snapshot → freshly created: the hook runs in the
# worktree with the context variables exported. A non-executable script is run
# with bash.
printf '%s\n' \
  'printf "%s|%s|%s" "$WORKTRUNK_WORKTREE_PATH" "$WORKTRUNK_BRANCH" "$WORKTRUNK_MAIN_PATH" > env-out' \
  > "$hook"
printf '%s\n' "$repo_phys" > "$snap"
run_in_linked >/dev/null
actual=$(cat "$work/linked/env-out")
expected="$linked_phys|feature|$repo_phys"
if [[ $actual != "$expected" ]]; then
  printf 'unexpected hook env %q, expected %q\n' "$actual" "$expected" >&2
  exit 1
fi
if [[ -e $snap ]]; then
  printf 'snapshot not consumed after running the hook\n' >&2
  exit 1
fi

# An executable hook is executed directly, honoring its shebang.
printf '#!/bin/sh\necho "$0" > exec-out\n' > "$hook"
chmod +x "$hook"
printf '%s\n' "$repo_phys" > "$snap"
run_in_linked >/dev/null
if [[ $(cat "$work/linked/exec-out") != "$hook" ]]; then
  printf 'executable hook was not executed directly\n' >&2
  exit 1
fi

# A failing hook propagates its exit status to the caller, and the failure
# message carries the hook's name.
printf 'exit 7\n' > "$hook"
chmod -x "$hook"
printf '%s\n' "$repo_phys" > "$snap"
status=0
output=$( (cd "$work/linked" && bash "$repo_root/run-hook.sh" "$snap" "$hook" post-open) 2>&1 ) \
  || status=$?
if [[ $status != 7 ]]; then
  printf 'expected exit status 7 from a failing hook, got %q\n' "$status" >&2
  exit 1
fi
if [[ $output != *"post-open hook failed"* ]]; then
  printf 'failure message missing the hook name: %q\n' "$output" >&2
  exit 1
fi

# The post-open invocation passes the caller's herdr ids through to the hook.
printf 'printf "%%s|%%s|%%s" "$WORKTRUNK_WORKSPACE_ID" "$WORKTRUNK_TAB_ID" "$WORKTRUNK_PANE_ID" > id-out\n' > "$hook"
printf '%s\n' "$repo_phys" > "$snap"
(cd "$work/linked" \
  && WORKTRUNK_WORKSPACE_ID=ws-1 WORKTRUNK_TAB_ID=tab-2 WORKTRUNK_PANE_ID=pane-3 \
     bash "$repo_root/run-hook.sh" "$snap" "$hook" post-open) >/dev/null
if [[ $(cat "$work/linked/id-out") != "ws-1|tab-2|pane-3" ]]; then
  printf 'herdr ids were not passed through to the post-open hook\n' >&2
  exit 1
fi

printf 'run-hook tests passed\n'
