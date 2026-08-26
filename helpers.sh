#!/usr/bin/env bash

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

# Emit one worktrunk list item per line with the schema 1 location fields
# (`kind`, `path`, and `is_main`) available at the top level. Worktrunk's JSON
# schema 2 wraps items in an envelope and nests those fields under `worktree`.
worktrunk_list_items() {
  jq -c '
    def normalize:
      . + {
        kind: (.kind // (if (.worktree | type) == "object" then "worktree" else "branch" end)),
        path: (.path // .worktree.path // null),
        is_main: (.is_main // .worktree.main // false)
      };

    if type == "array" then
      .[] | normalize
    elif type == "object" and ((.items | type) == "array") then
      .items[] | normalize
    else
      error("unsupported worktrunk list JSON schema")
    end
  '
}

# Emit the physical (symlink-resolved) path of every existing worktree of the
# current repo, one per line. The picker snapshots these before `wt switch`: a
# worktree whose path isn't in the snapshot afterwards is one the switch
# created, which is what gates the configured post_create_command.
worktrunk_worktree_paths() {
  git worktree list --porcelain 2>/dev/null | while IFS= read -r line; do
    [[ $line == "worktree "* ]] || continue
    (cd "${line#worktree }" 2>/dev/null && pwd -P)
  done
}
