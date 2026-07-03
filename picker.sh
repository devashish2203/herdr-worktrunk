#!/usr/bin/env bash
# Picker for the worktrunk herdr plugin. Picks a branch via fzf (fast), then opens a
# new tab and runs `wt switch` in THAT pane — so the worktree creation and any hook
# output happen in the pane you keep, not in this transient picker pane. The new tab
# runs your interactive shell, so its `wt` function cd's into the worktree and sticks.

# fzf over existing worktree branches; --print-query returns a typed-but-unmatched
# name so we can create it. Falls back to a plain read if fzf isn't on PATH.
if command -v fzf >/dev/null; then
  choice=$(
    wt list --format=json 2>/dev/null \
      | jq -r '.[] | select(.branch != null) | .branch' \
      | fzf --print-query --reverse --info=inline --border=rounded --margin=20%,30% \
            --prompt='worktree ❯ ' \
            --header='↵ on a match → switch · type a new name + ↵ → create · esc → cancel'
  )
  ret=$?
  [[ $ret -gt 1 ]] && exit 0      # 130 = esc/abort → cancel (0 = picked, 1 = typed-new)
  name=${choice##*$'\n'}          # last line: the selection if any, else the typed query
else
  printf 'Branch (existing → switch · new → create): '
  read -r name
fi
[[ -z $name ]] && exit 0

plugin_root=${HERDR_PLUGIN_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}
# shellcheck source=./config.sh
source "$plugin_root/config.sh"
# shellcheck source=./helpers.sh
source "$plugin_root/helpers.sh"
open_mode=$(worktrunk_open_mode)

# Existing local branch → switch (wt creates the worktree if it doesn't exist yet).
# worktrunk shortcuts (^ default, - previous, pr:N/mr:N, PR/MR URL) are resolved
# by worktrunk itself, so pass them through as-is — never --create.
# Anything else is a new branch → create it.
if worktrunk_is_shortcut "$name" || git show-ref --quiet --verify "refs/heads/$name"; then
  wtargs=(switch "$name")
else
  wtargs=(switch --create "$name")
fi

herdr=${HERDR_BIN_PATH:-herdr}

if [[ $open_mode == tab ]]; then
  # Preserve the original behavior: run wt in a new tab's interactive shell so
  # shell integration can cd into the worktree and keep the user there.
  printf -v quoted_name '%q' "$name"
  if [[ ${wtargs[1]} == --create ]]; then
    wtcmd="wt switch --create $quoted_name"
  else
    wtcmd="wt switch $quoted_name"
  fi

  newpane=$("$herdr" tab create --workspace "$HERDR_WORKSPACE_ID" --cwd "$PWD" --label "$name" --focus \
    | jq -r '.result.root_pane.pane_id')
  [[ -z $newpane ]] && { printf '\033[31m%s\033[0m\n' "failed to open worktree tab"; sleep 2; exit 1; }

  # pane run sends the command to the tab's interactive shell; the terminal buffers it
  # until the shell finishes loading, so its `wt` function is in place when it runs.
  "$herdr" pane run "$newpane" "$wtcmd"
  exit
fi

# Native workspace mode: let worktrunk create/switch the checkout and run hooks,
# then register the resulting existing checkout through herdr's worktree API.
if ! result=$(wt "${wtargs[@]}" --no-cd --format=json); then
  printf '\n\033[31m%s\033[0m press any key to close' "wt switch failed (see above)."
  read -n1
  exit 1
fi

wtpath=$(printf '%s\n' "$result" | jq -r '.path // empty' 2>/dev/null)
if [[ -z $wtpath ]]; then
  wtpath=$(wt list --format=json 2>/dev/null \
    | jq -r --arg b "$name" '.[] | select(.branch == $b and .kind == "worktree") | .path' \
    | head -n1)
fi
if [[ -z $wtpath ]]; then
  printf '\033[31m%s\033[0m\n' "worktrunk returned no worktree path for: $name"
  sleep 2
  exit 1
fi

# Register the worktree under the repo's ROOT workspace, not the picker pane's
# current workspace. When the picker runs from inside an existing worktree
# workspace, $HERDR_WORKSPACE_ID is that worktree's own (linked-worktree)
# workspace, and `worktree open` rejects it with `linked_worktree_source`
# ("New and open worktree actions start from the repo parent workspace."), so
# the checkout never surfaces in the sidebar. herdr resolves the repo's root
# workspace from any checkout cwd via .result.source.source_workspace_id, so
# prefer that; fall back to the pane's workspace if it can't be resolved.
root_ws=$("$herdr" worktree list --cwd "$PWD" --json 2>/dev/null \
  | jq -r '.result.source.source_workspace_id // empty')
[[ -z $root_ws ]] && root_ws=$HERDR_WORKSPACE_ID

exec "$herdr" worktree open --workspace "$root_ws" \
  --path "$wtpath" --label "$name" --focus --json
