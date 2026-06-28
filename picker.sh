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

# Existing local branch → switch (wt creates the worktree if it doesn't exist yet);
# anything else is a new branch → create it.
if git show-ref --quiet --verify "refs/heads/$name"; then
  wtcmd="wt switch \"$name\""
else
  wtcmd="wt switch --create \"$name\""
fi

# Open a tab in the workspace the picker was invoked in (--workspace, so it doesn't
# follow you if you switch away), rooted at the repo, then run wt in its pane.
herdr=${HERDR_BIN_PATH:-herdr}
newpane=$("$herdr" tab create --workspace "$HERDR_WORKSPACE_ID" --cwd "$PWD" --label "$name" --focus \
  | jq -r '.result.root_pane.pane_id')
[[ -z $newpane ]] && { printf '\033[31m%s\033[0m\n' "failed to open worktree tab"; sleep 2; exit 1; }

# pane run sends the command to the tab's interactive shell; the terminal buffers it
# until the shell finishes loading, so its `wt` function is in place when it runs.
"$herdr" pane run "$newpane" "$wtcmd"
