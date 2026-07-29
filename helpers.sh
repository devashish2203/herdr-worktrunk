#!/usr/bin/env bash

# Return the destination cwd that mirrors SOURCE_CWD's position relative to
# SOURCE_ROOT. This matches Worktrunk's normal shell-switch behavior: preserve
# the relative subdirectory when it exists in the target, otherwise use the
# target worktree root.
worktrunk_preserved_cwd() {
  local target_root=$1 source_root=$2 source_cwd=$3
  local physical_source_root physical_source_cwd relative candidate

  physical_source_root=$(cd -- "$source_root" 2>/dev/null && pwd -P) \
    || { printf '%s\n' "$target_root"; return; }
  physical_source_cwd=$(cd -- "$source_cwd" 2>/dev/null && pwd -P) \
    || { printf '%s\n' "$target_root"; return; }

  case $physical_source_cwd in
    "$physical_source_root"/*)
      relative=${physical_source_cwd#"$physical_source_root"/}
      candidate=$target_root/$relative
      if [[ -d $candidate ]]; then
        printf '%s\n' "$candidate"
        return
      fi
      ;;
  esac

  printf '%s\n' "$target_root"
}

# Open a Worktrunk-created checkout as a native Herdr worktree workspace. Herdr
# creates the workspace at the checkout root, so for a newly opened workspace we
# send its root pane a cd command to restore Worktrunk's preserved subdirectory.
# Existing workspaces retain their current pane state.
worktrunk_open_workspace() {
  local herdr=$1 root_workspace=$2 worktree_root=$3 label=$4 target_cwd=$5
  local response already_open pane_id quoted_target

  response=$("$herdr" worktree open --workspace "$root_workspace" \
    --path "$worktree_root" --label "$label" --focus --json) || return

  already_open=$(printf '%s\n' "$response" | jq -r '.result.already_open // false')
  if [[ $already_open != true && $target_cwd != "$worktree_root" ]]; then
    pane_id=$(printf '%s\n' "$response" | jq -r '.result.root_pane.pane_id // empty')
    if [[ -z $pane_id ]]; then
      printf 'herdr returned no root pane for worktree: %s\n' "$worktree_root" >&2
      return 1
    fi
    printf -v quoted_target '%q' "$target_cwd"
    if ! "$herdr" pane run "$pane_id" "cd -- $quoted_target" >/dev/null; then
      printf 'failed to set worktree workspace cwd to: %s\n' "$target_cwd" >&2
      return 1
    fi
  fi

  printf '%s\n' "$response"
}

# True when NAME is a token worktrunk resolves itself — a branch shortcut
# (^ default, - previous) or `:` syntax (pr:N, mr:N, or a PR/MR URL). Git branch
# names can't be these bare symbols or contain `:`, so these must be passed to
# `wt switch` as-is, never with --create. `@` (current) is omitted: switching to
# the current worktree is a no-op, and its only real use is as a --base.
worktrunk_is_shortcut() {
  case $1 in
    '^'|'-'|*:*) return 0 ;;
    *) return 1 ;;
  esac
}

# True when NAME is an existing local branch or remote-tracking branch. Such refs
# are checked out directly by `wt switch NAME` (worktrunk creates the worktree if
# one doesn't exist yet), so they must never be passed with --create.
worktrunk_ref_exists() {
  git show-ref --quiet --verify "refs/heads/$1" \
    || git show-ref --quiet --verify "refs/remotes/$1"
}
