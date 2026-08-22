#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../helpers.sh
source "$repo_root/helpers.sh"
# shellcheck source=../lifecycle.sh
source "$repo_root/lifecycle.sh"

stub_dir=$(mktemp -d)
trap 'rm -rf "$stub_dir"' EXIT

items=$(printf '%s\n' '[
  {"branch":"main","kind":"worktree","path":"/repo","is_main":true},
  {"branch":"feature","kind":"worktree","path":"/repo.feature","is_main":false},
  {"branch":null,"kind":"worktree","path":"/repo.detached","is_main":false},
  {"branch":"ready","kind":"branch"}
]' | worktrunk_list_items)

# The main worktree and branches without a worktree are never candidates.
branches=$(printf '%s\n' "$items" | worktrunk_worktree_branches | tr '\n' ' ')
if [[ ${branches% } != "feature" ]]; then
  printf 'expected only feature as a candidate, got %q\n' "$branches" >&2
  exit 1
fi

path=$(printf '%s\n' "$items" | worktrunk_worktree_path feature)
if [[ $path != /repo.feature ]]; then
  printf 'expected /repo.feature, got %q\n' "$path" >&2
  exit 1
fi

# Stand in for the herdr binary: `worktree list` answers with one open workspace,
# `pane list` with panes inside and outside the worktree, and everything else
# records the argv it was called with.
cat > "$stub_dir/herdr" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "worktree list")
    printf '%s' '{"result":{"worktrees":[
      {"path":"/repo.feature","open_workspace_id":"ws-feature"},
      {"path":"/repo.other"}
    ]}}'
    ;;
  "pane list")
    printf '%s' '{"result":{"panes":[
      {"pane_id":"p-self","cwd":"/repo.feature"},
      {"pane_id":"p-in","cwd":"/repo.feature/sub"},
      {"pane_id":"p-out","cwd":"/repo"}
    ]}}'
    ;;
  *)
    printf '%s\n' "$*" >> "$HERDR_STUB_LOG"
    ;;
esac
EOF
chmod +x "$stub_dir/herdr"
export HERDR_BIN_PATH="$stub_dir/herdr"
export HERDR_STUB_LOG="$stub_dir/log"
: > "$HERDR_STUB_LOG"

wsid=$(worktrunk_open_workspace_id /repo.feature)
if [[ $wsid != ws-feature ]]; then
  printf 'expected workspace ws-feature, got %q\n' "$wsid" >&2
  exit 1
fi

# A worktree herdr has no workspace open on resolves to nothing, not to an error.
if [[ -n $(worktrunk_open_workspace_id /repo.other) ]]; then
  printf 'expected no workspace id for /repo.other\n' >&2
  exit 1
fi

# A native workspace closes as a unit; its panes are not closed individually.
worktrunk_close_worktree_ui ws-feature /repo.feature
if [[ $(cat "$HERDR_STUB_LOG") != "workspace close ws-feature" ]]; then
  printf 'unexpected close calls:\n%s\n' "$(cat "$HERDR_STUB_LOG")" >&2
  exit 1
fi

# Without a workspace, panes under the worktree are closed — except the caller's.
: > "$HERDR_STUB_LOG"
HERDR_PANE_ID=p-self worktrunk_close_worktree_ui "" /repo.feature
if [[ $(cat "$HERDR_STUB_LOG") != "pane close p-in" ]]; then
  printf 'unexpected pane close calls:\n%s\n' "$(cat "$HERDR_STUB_LOG")" >&2
  exit 1
fi

# "/" would match every pane's cwd, so it is refused outright.
: > "$HERDR_STUB_LOG"
worktrunk_close_worktree_ui "" /
if [[ -s $HERDR_STUB_LOG ]]; then
  printf 'expected no close calls for /, got:\n%s\n' "$(cat "$HERDR_STUB_LOG")" >&2
  exit 1
fi

printf 'lifecycle tests passed\n'
