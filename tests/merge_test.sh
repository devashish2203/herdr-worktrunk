#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

stub_dir=$(mktemp -d)
trap 'rm -rf "$stub_dir"' EXIT

config_dir="$stub_dir/config"
mkdir -p "$config_dir"

# Stand in for `wt`: list answers with one mergeable worktree, and merge/remove
# record their argv and fail when the test asks them to.
cat > "$stub_dir/wt" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$WT_STUB_LOG"
case "$1" in
  list)
    printf '%s' '[
      {"branch":"main","kind":"worktree","path":"/repo","is_main":true},
      {"branch":"feature","kind":"worktree","path":"/repo.feature","is_main":false}
    ]'
    ;;
  merge)  exit "${WT_STUB_MERGE_STATUS:-0}" ;;
  remove) exit "${WT_STUB_REMOVE_STATUS:-0}" ;;
esac
EOF

# fzf picks the only candidate; the picker's stdin has to be drained either way.
cat > "$stub_dir/fzf" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n' "${FZF_STUB_PICK-feature}"
EOF

cat > "$stub_dir/herdr" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "worktree list")
    printf '%s' '{"result":{"worktrees":[{"path":"/repo.feature","open_workspace_id":"ws-feature"}]}}'
    ;;
  *) printf '%s\n' "$*" >> "$HERDR_STUB_LOG" ;;
esac
EOF
chmod +x "$stub_dir"/wt "$stub_dir"/fzf "$stub_dir"/herdr

export PATH="$stub_dir:$PATH"
export WT_STUB_LOG="$stub_dir/wt.log"
export HERDR_STUB_LOG="$stub_dir/herdr.log"

# Run merge.sh with the given argv and the config already in place, then expose
# what wt and herdr were asked to do.
run_merge() {
  : > "$WT_STUB_LOG"
  : > "$HERDR_STUB_LOG"
  HERDR_PLUGIN_ROOT="$repo_root" \
  HERDR_BIN_PATH="$stub_dir/herdr" \
  HERDR_PLUGIN_CONFIG_DIR="$config_dir" \
    bash "$repo_root/merge.sh" "$@" </dev/null >/dev/null 2>&1
}

assert_log() {
  local label=$1 expected=$2 log=$3
  if ! grep -qxF -- "$expected" "$log"; then
    printf 'expected %s call %q, got:\n%s\n' "$label" "$expected" "$(cat "$log")" >&2
    exit 1
  fi
}

# Matches on the start of a recorded argv, so refuting `remove` can't trip over
# the `--no-remove` flag the merge call carries.
refute_log() {
  local label=$1 unexpected=$2 log=$3
  if grep -q -- "^$unexpected" "$log"; then
    printf 'unexpected %s call %q in:\n%s\n' "$label" "$unexpected" "$(cat "$log")" >&2
    exit 1
  fi
}

# Default action: merge the picked worktree by path, keep it, then remove it in the
# foreground so the workspace close can't race the removal.
: > "$config_dir/config.toml"
run_merge
assert_log wt 'merge --no-remove -C /repo.feature' "$WT_STUB_LOG"
assert_log wt 'remove --foreground feature' "$WT_STUB_LOG"
assert_log herdr 'workspace close ws-feature' "$HERDR_STUB_LOG"

# The no-squash variant adds its flag; config flags come along too, once each.
printf 'merge_flags = "--no-rebase"\n' > "$config_dir/config.toml"
run_merge --no-squash
assert_log wt 'merge --no-remove -C /repo.feature --no-rebase --no-squash' "$WT_STUB_LOG"

printf 'merge_flags = "--no-squash"\n' > "$config_dir/config.toml"
run_merge --no-squash
assert_log wt 'merge --no-remove -C /repo.feature --no-squash' "$WT_STUB_LOG"

# An unsupported option is a plugin bug, not a merge to attempt.
: > "$config_dir/config.toml"
if run_merge --no-such-flag; then
  printf 'expected merge.sh to reject an unsupported option\n' >&2
  exit 1
fi
refute_log wt 'merge' "$WT_STUB_LOG"

# Cancelling the picker touches nothing.
FZF_STUB_PICK="" run_merge
refute_log wt 'merge' "$WT_STUB_LOG"
refute_log herdr 'workspace close' "$HERDR_STUB_LOG"

# A failed merge leaves the worktree and its workspace alone.
WT_STUB_MERGE_STATUS=1 run_merge
refute_log wt 'remove' "$WT_STUB_LOG"
refute_log herdr 'workspace close' "$HERDR_STUB_LOG"

# A merge that landed but a removal that didn't keeps the workspace open — it still
# holds the worktree.
WT_STUB_REMOVE_STATUS=1 run_merge
assert_log wt 'remove --foreground feature' "$WT_STUB_LOG"
refute_log herdr 'workspace close' "$HERDR_STUB_LOG"

printf 'merge tests passed\n'
