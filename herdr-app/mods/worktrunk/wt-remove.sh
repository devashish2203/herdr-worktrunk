# Remove a worktree with `wt remove`, then close the panes and spaces that were in it.
#!/usr/bin/env bash
# fzf over removable worktrees, `wt remove` (it confirms), then close what was open in it.
source "$(dirname "$0")/lib.sh"
trap close_self EXIT

command -v fzf >/dev/null || { printf '\033[31mfzf not found on PATH\033[0m\n'; sleep 2; exit 1; }

json=$(wt list --format=json 2>/dev/null)
cands=$(jq -r '.items[] | select(.branch != null and .worktree != null and .worktree.main != true) | .branch' <<<"$json")
if [[ -z $cands ]]; then
  printf '\033[33mNo removable worktrees (only the main worktree exists).\033[0m\n'; sleep 2; exit 0
fi
name=$(fzf --reverse --info=inline --border=rounded --prompt='remove worktree ❯ ' \
           --header='↵ remove (worktrunk confirms) · esc cancel' <<<"$cands")
[[ -z $name ]] && exit 0
path=$(jq -r --arg b "$name" '.items[] | select(.branch == $b) | .worktree.path' <<<"$json")

if ! wt remove --foreground "$name"; then
  printf '\n\033[31mwt remove failed (see above).\033[0m press any key'; read -rn1; exit 0
fi
hold remove "removed worktree $name."
[[ -z $path || $path == / ]] && exit 0

# Panes elsewhere whose shell sat inside the worktree (not this one).
ls=$(herdr-app ls)
hc ls --json 2>/dev/null \
  | jq -r --arg p "$path" --arg self "$HC_TERMINAL_ID" \
      '.terminals[] | select(.address != $self and (.cwd == $p or (.cwd | startswith($p + "/")))) | .address' \
  | while read -r t; do
      pane=$(jq -r --arg t "$t" '.. | objects | select(.terminal? == $t) | .pane' <<<"$ls" | head -1)
      [[ -n $pane ]] && herdr-app do pane.close --pane "$pane" >/dev/null
    done

# Spaces made in the worktree; last, since this split may live in one of them.
jq -r --arg p "$path" '.spaces[] | select(.folder == $p or (.folder | startswith($p + "/"))) | .id' <<<"$ls" \
  | while read -r id; do herdr-app do space.close --id "$id" --confirmed true >/dev/null; done
