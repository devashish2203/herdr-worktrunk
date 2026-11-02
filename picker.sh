#!/usr/bin/env bash
# Picker for the worktrunk herdr plugin. Picks a branch via fzf (fast), then either
# lets worktrunk create/switch the checkout and registers it as a native worktree
# workspace (the default), or — in tab mode — opens a new tab and types `wt switch`
# into THAT tab's shell, so the worktree creation and any hook output happen in the
# pane you keep and the shell's own `wt` integration cd's it into the worktree.

create_base=""
create_base_label="default branch"
case ${1:-} in
  ""|--create-base=default|--show-with-remotes)
    ;;
  --create-base=current)
    create_base="@"
    current_branch=$(git branch --show-current 2>/dev/null || true)
    if [[ -n $current_branch ]]; then
      create_base_label="current branch (${current_branch})"
    else
      current_commit=$(git rev-parse --short HEAD 2>/dev/null || true)
      if [[ -n $current_commit ]]; then
        create_base_label="current HEAD (${current_commit})"
      else
        create_base_label="current branch"
      fi
    fi
    ;;
  *)
    printf '\033[31m%s\033[0m\n' "unsupported picker option: $1" >&2
    exit 2
    ;;
esac

plugin_root=${HERDR_PLUGIN_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}
# shellcheck source=./config.sh
source "$plugin_root/config.sh"
# shellcheck source=./helpers.sh
source "$plugin_root/helpers.sh"

# Branch refs to offer alongside `wt list`: always local heads, plus
# remote-tracking branches when requested by this dedicated picker or config.
branch_refs=(refs/heads)
if [[ ${1:-} == --show-with-remotes || $(worktrunk_show_remote_branches) == true ]]; then
  branch_refs+=(refs/remotes)
fi

worktrunk_fzf_layout

# fzf over existing worktree branches; --print-query returns a typed-but-unmatched
# name so we can create it, and alt-↵ (print-query) forces the typed name even when
# it fuzzy-matches an existing branch (fzf then prints only the query, so the
# last-line parse below lands on it). Falls back to a plain read if fzf isn't on PATH.
if command -v fzf >/dev/null; then
  choice=$(
    {
      # Refs first: `git for-each-ref` answers instantly and in refname order,
      # while `wt list` stats every checkout — seconds on a repo with many
      # worktrees. Drop origin/HEAD: its short form is bare "origin", so filter
      # on the full refname (refs/remotes/origin/HEAD), then emit the short name.
      git for-each-ref --format='%(refname) %(refname:short)' "${branch_refs[@]}" 2>/dev/null \
        | awk '$1 !~ /\/HEAD$/ {print $2}'
      wt list --format=json 2>/dev/null \
        | worktrunk_list_items \
        | jq -r 'select(.branch != null) | .branch'
    } | awk '!seen[$0]++ { print; fflush() }' \
      | fzf --print-query --reverse --info=inline "${WORKTRUNK_FZF_LAYOUT[@]}" \
            --bind=alt-enter:print-query \
            --prompt='worktree ❯ ' \
            --header="↵ on a match → switch · type a new name + ↵ → create from ${create_base_label} · alt-↵ → force typed name · esc → cancel"
  )
  ret=$?
  [[ $ret -gt 1 ]] && exit 0      # 130 = esc/abort → cancel (0 = picked, 1 = typed-new)
  name=${choice##*$'\n'}          # last line: the selection if any, else the typed query
else
  printf 'Branch (existing → switch · new → create from %s): ' "$create_base_label"
  read -r name
fi
[[ -z $name ]] && exit 0

# Slugify a new branch name. The slug may name an existing branch, which the
# check below then switches to.
if [[ $(worktrunk_slugify_new_branches) == true ]] \
  && ! worktrunk_is_shortcut "$name" && ! worktrunk_ref_exists "$name"; then
  if ! slug=$(worktrunk_branch_slug "$name"); then
    printf '\033[31m%s\033[0m press any key to close' "no valid branch name in: $name"
    read -n1
    exit 1
  fi
  name=$slug
fi

open_mode=$(worktrunk_open_mode)

# Existing local or remote-tracking branch → switch (wt creates the worktree if
# it doesn't exist yet, and checks out a remote ref like origin/foo directly).
# worktrunk shortcuts (^ default, - previous, pr:N/mr:N, PR/MR URL) are resolved
# by worktrunk itself, so pass them through as-is — never --create.
# Anything else is a new branch → create it.
if worktrunk_is_shortcut "$name" || worktrunk_ref_exists "$name"; then
  wtargs=(switch "$name")
else
  wtargs=(switch --create "$name")
  [[ -n $create_base ]] && wtargs+=(--base "$create_base")
fi

herdr=${HERDR_BIN_PATH:-herdr}

if [[ $open_mode == tab ]]; then
  # Run wt in a new tab's interactive shell rather than here: only that shell can
  # cd itself into the worktree (through worktrunk's shell integration), and the
  # hook output then lands in the pane the user keeps, not in this transient one.
  tab_env=()
  [[ -z ${HERDR_PLUGIN_CONFIG_DIR:-} ]] || tab_env=(--env "HERDR_PLUGIN_CONFIG_DIR=$HERDR_PLUGIN_CONFIG_DIR")
  tab_json=$("$herdr" tab create --workspace "$HERDR_WORKSPACE_ID" --cwd "$PWD" --label "$name" "${tab_env[@]}" --focus)
  newpane=$(printf '%s\n' "$tab_json" | jq -r '.result.root_pane.pane_id // empty')
  tab_id=$(printf '%s\n' "$tab_json" | jq -r '.result.root_pane.tab_id // empty')
  [[ -z $newpane || -z $tab_id ]] && { printf '\033[31m%s\033[0m\n' "failed to open worktree tab"; sleep 2; exit 1; }

  # The line is typed into that tab's own shell, so it is generated in that shell's
  # syntax (see worktrunk_tab_command). The label above is a placeholder — $name may
  # be a shortcut — that tab-relabel.sh replaces once the switch lands.
  shell=$(worktrunk_pane_shell "$herdr" "$newpane")
  family=$(worktrunk_shell_family "$shell")
  line=$(worktrunk_tab_command "$family" "$plugin_root/tab-relabel.sh" "$herdr" "$tab_id" "$name" "$PWD" -- "${wtargs[@]}")

  # pane run sends the line to the tab's interactive shell; the terminal buffers it
  # until the shell finishes loading, so its `wt` command is in place when it runs.
  "$herdr" pane run "$newpane" "$line"
  exit
fi

# Native workspace mode: let worktrunk create/switch the checkout and run hooks,
# then register the resulting existing checkout through herdr's worktree API.
if ! result=$(wt "${wtargs[@]}" --no-cd --format=json); then
  printf '\n\033[31m%s\033[0m press any key to close' "wt switch failed (see above)."
  read -n1
  exit 1
fi

# $name may be a worktrunk shortcut rather than the actual branch: label with what
# it resolved to (see worktrunk_switch_label).
branch=$(printf '%s\n' "$result" | jq -r '.branch // empty' 2>/dev/null)

wtpath=$(printf '%s\n' "$result" | jq -r '.path // empty' 2>/dev/null)
if [[ -z $wtpath ]]; then
  wtpath=$(wt list --format=json 2>/dev/null \
    | worktrunk_list_items \
    | jq -r --arg b "$name" 'select(.branch == $b and .kind == "worktree") | .path' \
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
# workspace, which `worktree open` rejects. Resolve the repository root instead;
# Herdr reuses its parent workspace or creates one when absent.
source_json=$("$herdr" worktree list --cwd "$PWD" --json 2>/dev/null)
repo_root=$(printf '%s\n' "$source_json" | jq -r '.result.source.repo_root')

# When no workspace covers the root yet, herdr's own auto-created label falls back
# to the checkout directory's basename verbatim (e.g. "repo.git" for a bare repo)
# rather than the repository's name. Pre-create it labeled correctly so the
# `worktree open` below reuses it as-is instead of defaulting the label.
root_workspace_id=$(printf '%s\n' "$source_json" | jq -r '.result.source.source_workspace_id // empty')
repo_label=$(printf '%s\n' "$source_json" | jq -r '.result.source.repo_name // empty')
repo_label=${repo_label%.git}
if [[ -z $root_workspace_id ]]; then
  [[ -n $repo_label ]] && "$herdr" workspace create --cwd "$repo_root" --label "$repo_label" --no-focus >/dev/null
fi

# Update only linked workspaces still carrying the plugin's last generated label.
workspace_id=''
while IFS= read -r tree; do
  tree_path=$(printf '%s' "$tree" | jq -r '.path // empty')
  if [[ -n $tree_path && "$(cd "$tree_path" 2>/dev/null && pwd -P)" == "$(cd "$wtpath" 2>/dev/null && pwd -P)" ]]; then
    workspace_id=$(printf '%s' "$tree" | jq -r '.open_workspace_id // empty')
    break
  fi
done < <(printf '%s' "$source_json" | jq -c '.result.worktrees[]?')
current_label=''
if [[ -n $workspace_id ]]; then
  current_label=$("$herdr" workspace list 2>/dev/null | jq -r --arg id "$workspace_id" \
    '.result.workspaces[]? | select(.workspace_id == $id) | .label // empty')
  current_label=${current_label:-?}
fi
worktrunk_prepare_label "$wtpath" "$branch" "$name" "$repo_label" "$current_label"
label_args=()
[[ $WORKTRUNK_MANAGED != true ]] || label_args=(--label "$WORKTRUNK_LABEL")
# The main checkout is the repository's own workspace: --label would rename it to
# the branch. Compare canonicalized paths since repo_root and wtpath may resolve
# symlinks differently (e.g. macOS /tmp).
if [[ "$(cd "$wtpath" 2>/dev/null && pwd -P)" == "$(cd "$repo_root" 2>/dev/null && pwd -P)" ]]; then
  label_args=()
fi

# Name the worktree by the label it keeps: a manual one stays in place.
shown_label=$WORKTRUNK_LABEL
if [[ $WORKTRUNK_MANAGED != true ]]; then
  shown_label=$current_label
  [[ $shown_label != '?' ]] || shown_label=${branch:-$name}
fi

# Only a worktree worktrunk just created has hook output worth reading; a switch to
# an existing one opens straight away. Hold before the workspace opens below — it
# takes the focus with it.
if [[ $(printf '%s\n' "$result" | jq -r '.action // empty' 2>/dev/null) == created ]]; then
  worktrunk_hold_pane create "created worktree $shown_label."
fi

# The main checkout keeps no label state, so saving is a no-op there.
if "$herdr" worktree open --cwd "$repo_root" \
  --path "$wtpath" "${label_args[@]}" --focus --json; then
  worktrunk_save_label "$branch"
else
  exit $?
fi
