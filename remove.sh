#!/usr/bin/env bash
# Remover for the worktrunk herdr plugin — fzf over removable worktrees, then
# `wt remove`. Plain bash, shell-agnostic: it calls the `wt` binary directly, so it
# needs no shell-function/rc integration.

if ! command -v fzf >/dev/null; then
  printf '\033[31m%s\033[0m\n' "fzf not found on PATH"; sleep 2; exit 1
fi

plugin_root=${HERDR_PLUGIN_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}
# shellcheck source=./config.sh
source "$plugin_root/config.sh"
# shellcheck source=./helpers.sh
source "$plugin_root/helpers.sh"
# shellcheck source=./lifecycle.sh
source "$plugin_root/lifecycle.sh"

worktrunk_fzf_layout

wtitems=$(worktrunk_worktree_items) || exit 1

cands=$(printf '%s\n' "$wtitems" | worktrunk_worktree_branches)
if [[ -z $cands ]]; then
  printf '\033[33m%s\033[0m\n' "No removable worktrees (only the main worktree exists)."; sleep 2; exit 0
fi

name=$(printf '%s\n' "$cands" \
  | worktrunk_pick_branch 'remove worktree ❯ ' \
      '↵ to remove (worktrunk will ask to confirm) · esc to cancel')
[[ -z $name ]] && exit 0      # esc / no selection → cancel

# Path and native herdr workspace (if open) of the worktree we're about to remove.
wtpath=$(printf '%s\n' "$wtitems" | worktrunk_worktree_path "$name")
wsid=$(worktrunk_open_workspace_id "$wtpath")

# wt remove prompts for approval itself, refuses unmerged branches without -D, and
# refuses worktrees with untracked files without -f — so run it interactively and let
# worktrunk gate the destructive bits. --foreground keeps the pane until it's done.
if ! wt remove --foreground "$name"; then
  printf '\n\033[31m%s\033[0m press any key to close' "wt remove failed (see above)."; read -n1
  exit 0
fi

worktrunk_close_worktree_ui "$wsid" "$wtpath"
