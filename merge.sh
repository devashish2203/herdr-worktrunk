#!/usr/bin/env bash
# Merger for the worktrunk herdr plugin — fzf over mergeable worktrees, then
# `wt merge` into the target branch and `wt remove`. Plain bash, shell-agnostic: it
# calls the `wt` binary directly, so it needs no shell-function/rc integration.

if ! command -v fzf >/dev/null; then
  printf '\033[31m%s\033[0m\n' "fzf not found on PATH"; sleep 2; exit 1
fi

action_flags=()
case ${1:-} in
  "")
    ;;
  --no-squash)
    action_flags=(--no-squash)
    ;;
  *)
    printf '\033[31m%s\033[0m\n' "unsupported merger option: $1" >&2
    exit 2
    ;;
esac

plugin_root=${HERDR_PLUGIN_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}
# shellcheck source=./config.sh
source "$plugin_root/config.sh"
# shellcheck source=./helpers.sh
source "$plugin_root/helpers.sh"
# shellcheck source=./lifecycle.sh
source "$plugin_root/lifecycle.sh"

# Configured flags first, then the ones this action adds, skipping any the config
# already asked for so `wt merge` never sees the same flag twice.
merge_flags=()
while IFS= read -r flag; do
  merge_flags+=("$flag")
done < <(worktrunk_merge_flags)
for flag in "${action_flags[@]}"; do
  if [[ " ${merge_flags[*]} " != *" $flag "* ]]; then
    merge_flags+=("$flag")
  fi
done

worktrunk_fzf_layout

wtitems=$(worktrunk_worktree_items) || exit 1

cands=$(printf '%s\n' "$wtitems" | worktrunk_worktree_branches)
if [[ -z $cands ]]; then
  printf '\033[33m%s\033[0m\n' "No mergeable worktrees (only the main worktree exists)."; sleep 2; exit 0
fi

# Spell out the exact wt invocation in the header: which flags are in play is the
# difference between this action and its no-squash variant, and between one user's
# merge_flags and another's.
name=$(printf '%s\n' "$cands" \
  | worktrunk_pick_branch 'merge worktree ❯ ' \
      "↵ to run wt merge${merge_flags[*]:+ ${merge_flags[*]}} and remove the worktree · esc to cancel")
[[ -z $name ]] && exit 0      # esc / no selection → cancel

# Path and native herdr workspace (if open) of the worktree we're about to merge.
# Both have to be resolved before the removal below destroys them.
wtpath=$(printf '%s\n' "$wtitems" | worktrunk_worktree_path "$name")
wsid=$(worktrunk_open_workspace_id "$wtpath")

# -C runs the merge as if from the picked worktree, so the pane never has to be in
# it. --no-remove because wt merge's own removal runs in the background, which would
# race the workspace close below; the foreground `wt remove` further down does it.
# wt merge stages, commits, squashes and rebases per its flags, runs pre-commit and
# pre-merge hooks, and stops on conflicts — so run it interactively and let
# worktrunk gate all of that.
if ! wt merge --no-remove -C "$wtpath" "${merge_flags[@]}"; then
  printf '\n\033[31m%s\033[0m press any key to close' "wt merge failed (see above)."; read -n1
  exit 0
fi

# The branch is merged now, so wt remove deletes it without -D. --foreground blocks
# until the worktree is really gone, so closing its workspace can't outrun it.
if ! wt remove --foreground "$name"; then
  printf '\n\033[31m%s\033[0m press any key to close' \
    "merged, but wt remove failed (see above)."; read -n1
  exit 0
fi

worktrunk_close_worktree_ui "$wsid" "$wtpath"
