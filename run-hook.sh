#!/usr/bin/env bash
# Runs one of the user's hook scripts inside a worktree the picker just
# created. Invoked with the current directory already inside the worktree:
# picker.sh cd's here in workspace mode; in tab mode the shell's `wt` function
# has already cd'd. (Without worktrunk shell integration the tab's cwd stays
# the old checkout — which is in the snapshot, so the hook is safely skipped
# rather than run in the wrong directory.)
#
#   $1 — snapshot of pre-switch worktree paths (consumed: deleted after the
#        check). The hook runs only when the cwd is NOT in the snapshot,
#        i.e. only when this switch actually created the worktree.
#   $2 — the hook script; executed directly when executable (honoring its
#        shebang), otherwise run with bash.
#   $3 — the hook's name for messages ("post-create" or "post-open").
#
# The hook runs with the new worktree as cwd and these exported so it can
# filter per project and copy files from the primary checkout:
#   WORKTRUNK_WORKTREE_PATH — the new worktree
#   WORKTRUNK_BRANCH        — its checked-out branch (empty on detached HEAD)
#   WORKTRUNK_MAIN_PATH     — the repository's primary checkout
# The post-open hook additionally sees WORKTRUNK_WORKSPACE_ID,
# WORKTRUNK_TAB_ID, WORKTRUNK_PANE_ID, and HERDR_BIN_PATH — set in this
# runner's environment by the picker and inherited by the hook from here.

usage='usage: run-hook.sh <snapshot-file> <hook-script> <hook-name>'
snapshot=${1:?$usage}
hook=${2:?$usage}
hook_name=${3:?$usage}

wtpath=$(pwd -P)

created=true
if [[ -f $snapshot ]]; then
  grep -qxF "$wtpath" "$snapshot" && created=false
  rm -f "$snapshot"
fi
[[ $created == true ]] || exit 0

WORKTRUNK_WORKTREE_PATH=$wtpath
WORKTRUNK_BRANCH=$(git branch --show-current 2>/dev/null || true)
# The primary checkout is always the first `git worktree list` entry;
# canonicalize it the same way as the cwd above.
main_path=$(git worktree list --porcelain 2>/dev/null \
  | sed -n 's/^worktree //p' | head -n1)
WORKTRUNK_MAIN_PATH=$([[ -n $main_path ]] && cd "$main_path" 2>/dev/null && pwd -P)
export WORKTRUNK_WORKTREE_PATH WORKTRUNK_BRANCH WORKTRUNK_MAIN_PATH

printf '\033[36mworktrunk plugin:\033[0m running %s hook in %s\n' "$hook_name" "$wtpath"
if [[ -x $hook ]]; then
  "$hook"
else
  bash "$hook"
fi
status=$?
if (( status != 0 )); then
  printf '\033[31m%s\033[0m\n' "$hook_name hook failed (exit $status)"
  exit "$status"
fi
