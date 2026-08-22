#!/usr/bin/env bash

# Shared steps for the actions that destroy a worktree (remove.sh, merge.sh):
# listing what they can act on, resolving what herdr has open for it, and closing
# that UI once worktrunk is done. Sourced after config.sh and helpers.sh.

# Print the normalized `wt list` items on stdout, or the pane message for whichever
# step broke on stderr. Messages go to stderr so a caller capturing the items can
# still show them in the pane.
worktrunk_worktree_items() {
  local wtjson

  if ! wtjson=$(wt list --format=json 2>/dev/null); then
    printf '\033[31m%s\033[0m\n' "failed to list worktrees" >&2
    sleep 2
    return 1
  fi

  if ! printf '%s\n' "$wtjson" | worktrunk_list_items; then
    printf '\033[31m%s\033[0m\n' "unsupported worktrunk list output" >&2
    sleep 2
    return 1
  fi
}

# Print one branch per line for every worktree these actions can act on, reading
# items on stdin: any real worktree except the main one (the primary checkout can't
# be removed, and it's the merge target rather than a merge source). The current
# worktree IS included — worktrunk switches you back to the root repo.
worktrunk_worktree_branches() {
  jq -r 'select(.kind == "worktree" and .branch != null and .is_main != true) | .branch'
}

# Print the path of the worktree checked out at BRANCH, reading items on stdin.
worktrunk_worktree_path() {
  jq -r --arg b "$1" 'select(.kind == "worktree" and .branch == $b) | .path'
}

# Print the id of the native herdr workspace open on the worktree at PATH, or
# nothing (tab mode, or a worktree herdr never opened as a workspace). Resolve this
# before the worktree is destroyed — herdr forgets the mapping along with it.
worktrunk_open_workspace_id() {
  "${HERDR_BIN_PATH:-herdr}" worktree list --cwd "$PWD" --json 2>/dev/null \
    | jq -r --arg p "$1" \
        '.result.worktrees[] | select(.path == $p) | .open_workspace_id // empty' \
    | head -n1
}

# fzf over the branches on stdin with PROMPT and HEADER, in the chrome that suits
# the picker placement. Prints nothing when the user cancels. Call
# worktrunk_fzf_layout first.
worktrunk_pick_branch() {
  fzf --reverse --info=inline "${WORKTRUNK_FZF_LAYOUT[@]}" \
      --prompt="$1" --header="$2"
}

# Close the herdr UI a destroyed worktree left behind: its native workspace as a
# unit, or — for the original tab-based mode and worktrees opened by older plugin
# versions — the panes sitting in it. Leaves the calling pane alone.
worktrunk_close_worktree_ui() {
  local wsid=$1 wtpath=$2 herdr=${HERDR_BIN_PATH:-herdr} pid

  if [[ -n $wsid ]]; then
    "$herdr" workspace close "$wsid"
  elif [[ -n $wtpath && $wtpath != "/" ]]; then
    "$herdr" pane list 2>/dev/null \
      | jq -r --arg p "$wtpath" --arg self "${HERDR_PANE_ID:-}" \
          '.result.panes[] | select(.pane_id != $self)
           | select(.cwd == $p or (.cwd | startswith($p + "/"))) | .pane_id' \
      | while read -r pid; do "$herdr" pane close "$pid"; done
  fi
}
