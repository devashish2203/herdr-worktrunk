#!/usr/bin/env bash
# Relabel a tab-mode worktree tab after the branch `wt switch` landed on.
#
#   tab-relabel.sh <herdr-bin> <tab-id> <picked-name> <start-cwd>
#
# The picker types this into the new tab's shell right after `wt switch …`, so it
# runs with the shell's cwd already inside the worktree (worktrunk's shell
# integration moved it there). PICKED-NAME is what was chosen in the picker — maybe
# a worktrunk shortcut (^, -, pr:N, mr:N, a PR/MR URL) or a remote-tracking ref
# rather than the branch itself — and stays alongside the branch in parens when the
# two differ, e.g. "feat/eager-worktree-focus (pr:16)". On a detached HEAD there is
# no branch to show, so the placeholder label the picker set stays.
#
# START-CWD is where the tab began. A cwd that never changed means the shell
# integration isn't active in this shell: the bare `wt` binary created the worktree
# but nothing moved the shell into it, so the branch under it is the one we came
# from, not the switch target. Say so instead of labeling the tab with it.

if [[ $# -ne 4 ]]; then
  printf 'usage: %s <herdr-bin> <tab-id> <picked-name> <start-cwd>\n' "${0##*/}" >&2
  exit 2
fi
herdr=$1 tab_id=$2 name=$3 start=$4

plugin_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=./helpers.sh
source "$plugin_root/helpers.sh"

branch=$(git branch --show-current 2>/dev/null)
[[ -z $branch ]] && exit 0

# The branch itself, a shortcut, or origin/<branch> can legitimately resolve to the
# worktree the tab started in; anything else staying put means no integration ran.
if [[ $branch != "$name" && $(pwd -P) == "$(cd -- "$start" 2>/dev/null && pwd -P)" ]] \
  && ! worktrunk_is_shortcut "$name" && [[ $name != */"$branch" ]]; then
  hint="wt switch did not move this shell into the worktree: worktrunk's shell integration is"
  hint+=" not active here. Run \`wt config shell install\`, restart the shell, then \`wt switch $name\`."
  printf '\033[33m%s\033[0m\n' "$hint" >&2
  label=$name
else
  label=$(worktrunk_switch_label "$branch" "$name")
fi

exec "$herdr" tab rename "$tab_id" "$label" >/dev/null
