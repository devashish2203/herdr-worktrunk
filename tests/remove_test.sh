#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

stub_dir=$(mktemp -d)
trap 'rm -rf "$stub_dir"' EXIT

config_dir="$stub_dir/config"
mkdir -p "$config_dir"

# Stand in for `wt`: list answers with one removable worktree, and remove records
# its argv and fails when the test asks it to.
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
  *) printf '%s\n' "$*" | tee -a "$HERDR_STUB_LOG" ;;
esac
EOF
chmod +x "$stub_dir"/wt "$stub_dir"/fzf "$stub_dir"/herdr

export PATH="$stub_dir:$PATH"
export WT_STUB_LOG="$stub_dir/wt.log"
export HERDR_STUB_LOG="$stub_dir/herdr.log"
pane_out="$stub_dir/pane.out"

# Run remove.sh with the config already in place, then expose what wt and herdr
# were asked to do and what the pane showed. The herdr stub echoes its calls into
# the pane too, so a message can be placed before or after them. With stdin at
# /dev/null a "press any key" read returns at once.
run_remove() {
  : > "$WT_STUB_LOG"
  : > "$HERDR_STUB_LOG"
  HERDR_PLUGIN_ROOT="$repo_root" \
  HERDR_BIN_PATH="$stub_dir/herdr" \
  HERDR_PLUGIN_CONFIG_DIR="$config_dir" \
    bash "$repo_root/remove.sh" </dev/null >"$pane_out" 2>&1
}

assert_log() {
  local label=$1 expected=$2 log=$3
  if ! grep -qxF -- "$expected" "$log"; then
    printf 'expected %s call %q, got:\n%s\n' "$label" "$expected" "$(cat "$log")" >&2
    exit 1
  fi
}

refute_log() {
  local label=$1 unexpected=$2 log=$3
  if grep -q -- "^$unexpected" "$log"; then
    printf 'unexpected %s call %q in:\n%s\n' "$label" "$unexpected" "$(cat "$log")" >&2
    exit 1
  fi
}

# Match an extended regex against the pane output flattened to one line, so a
# pattern can span the order things were shown in.
assert_pane() {
  local pattern=$1
  if ! tr '\n' ' ' < "$pane_out" | grep -qE -- "$pattern"; then
    printf 'expected pane output matching %q, got:\n%s\n' "$pattern" "$(cat "$pane_out")" >&2
    exit 1
  fi
}

refute_pane() {
  local pattern=$1
  if tr '\n' ' ' < "$pane_out" | grep -qE -- "$pattern"; then
    printf 'unexpected pane output matching %q in:\n%s\n' "$pattern" "$(cat "$pane_out")" >&2
    exit 1
  fi
}

# Remove the picked worktree in the foreground, so the workspace close can't race
# the removal, and from the main worktree, so worktrunk has no directory change to
# warn about. Close without waiting.
: > "$config_dir/config.toml"
run_remove
assert_log wt 'remove --foreground -C /repo feature' "$WT_STUB_LOG"
assert_log herdr 'workspace close ws-feature' "$HERDR_STUB_LOG"
refute_pane 'press any key to continue'

# Cancelling the picker touches nothing.
FZF_STUB_PICK="" run_remove
refute_log wt 'remove' "$WT_STUB_LOG"
refute_log herdr 'workspace close' "$HERDR_STUB_LOG"

# A failed removal keeps the workspace open — it still holds the worktree.
WT_STUB_REMOVE_STATUS=1 run_remove
assert_pane 'wt remove failed \(see above\)\.'
refute_log herdr 'workspace close' "$HERDR_STUB_LOG"

# hold_on_remove keeps the pane up after a successful removal, and asks for the key
# before the workspace closes: in a split the pane can sit in that workspace.
printf 'hold_on_remove = true\n' > "$config_dir/config.toml"
run_remove
assert_pane 'removed feature\..*press any key to continue.*workspace close ws-feature'
assert_log herdr 'workspace close ws-feature' "$HERDR_STUB_LOG"

# hold_on_success covers the removal as well, unless hold_on_remove says otherwise.
printf 'hold_on_success = true\n' > "$config_dir/config.toml"
run_remove
assert_pane 'removed feature\.'

printf 'hold_on_success = true\nhold_on_remove = false\n' > "$config_dir/config.toml"
run_remove
refute_pane 'press any key to continue'
assert_log herdr 'workspace close ws-feature' "$HERDR_STUB_LOG"

# A failure keeps its own message whatever the hold settings say.
printf 'hold_on_success = true\n' > "$config_dir/config.toml"
WT_STUB_REMOVE_STATUS=1 run_remove
assert_pane 'wt remove failed \(see above\)\.'
refute_pane 'removed feature'
refute_log herdr 'workspace close' "$HERDR_STUB_LOG"

printf 'remove tests passed\n'
