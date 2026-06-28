#!/bin/bash
# Remover for the worktrunk herdr plugin — fzf over removable worktrees, then
# `wt remove`. Plain bash, shell-agnostic: it calls the `wt` binary directly, so it
# needs no shell-function/rc integration.

if ! command -v fzf >/dev/null; then
  printf '\033[31m%s\033[0m\n' "fzf not found on PATH"; sleep 2; exit 1
fi

herdr=${HERDR_BIN_PATH:-herdr}
wtjson=$(wt list --format=json 2>/dev/null)

# Removable = any real worktree except the main one (the primary checkout can't be
# removed). The current worktree IS removable — wt switches you back to the root repo.
cands=$(printf '%s\n' "$wtjson" \
  | jq -r '.[] | select(.branch != null and .is_main != true) | .branch')
if [[ -z $cands ]]; then
  printf '\033[33m%s\033[0m\n' "No removable worktrees (only the main worktree exists)."; sleep 2; exit 0
fi

name=$(printf '%s\n' "$cands" \
  | fzf --reverse --info=inline --border=rounded --margin=20%,30% \
        --prompt='remove worktree ❯ ' \
        --header='↵ to remove (worktrunk will ask to confirm) · esc to cancel')
[[ -z $name ]] && exit 0      # esc / no selection → cancel

# Path of the worktree we're about to remove, so we can close orphaned panes after.
wtpath=$(printf '%s\n' "$wtjson" | jq -r --arg b "$name" '.[] | select(.branch==$b) | .path')

# wt's directive file isn't needed here (we don't cd), but setting it suppresses
# wt's "run wt config shell install" hint when it removes the current worktree.
WORKTRUNK_DIRECTIVE_FILE=$(mktemp)
export WORKTRUNK_DIRECTIVE_FILE
trap 'rm -f "$WORKTRUNK_DIRECTIVE_FILE"' EXIT

# wt remove prompts for approval itself, refuses unmerged branches without -D, and
# refuses worktrees with untracked files without -f — so run it interactively and let
# worktrunk gate the destructive bits. --foreground keeps the overlay until it's done.
if ! wt remove --foreground "$name"; then
  printf '\n\033[31m%s\033[0m press any key to close' "wt remove failed (see above)."; read -n1
  exit 0
fi

# Close any panes left sitting in the now-deleted worktree (or a subdir of it),
# except this overlay. Guard against an empty path matching everything.
# ponytail: matches the pane's shell cwd string; a process that cd'd elsewhere
# under a still-open shell won't be caught — fine for the common shell-in-worktree case.
if [[ -n $wtpath && $wtpath != "/" ]]; then
  "$herdr" pane list 2>/dev/null \
    | jq -r --arg p "$wtpath" --arg self "${HERDR_PANE_ID:-}" \
        '.result.panes[] | select(.pane_id != $self)
         | select(.cwd == $p or (.cwd | startswith($p + "/"))) | .pane_id' \
    | while read -r pid; do "$herdr" pane close "$pid"; done
fi
