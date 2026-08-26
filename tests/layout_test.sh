#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

config_dir=$work/config
mkdir -p "$config_dir"
log=$work/herdr.log

# Stand in for the herdr binary: log every argv and answer with the JSON shape
# apply-layout.sh parses. Pane/tab ids embed the call number (the log line).
cat > "$work/herdr" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HERDR_STUB_LOG"
n=$(wc -l < "$HERDR_STUB_LOG" | tr -d ' ')
case "$1 $2" in
  "pane split") printf '{"result":{"pane":{"pane_id":"p%s"}}}\n' "$n" ;;
  "tab create") printf '{"result":{"root_pane":{"pane_id":"tab%sroot","tab_id":"tab%s"}}}\n' "$n" "$n" ;;
  *) printf '{"result":{"type":"ok"}}\n' ;;
esac
EOF
chmod +x "$work/herdr"

apply() {
  : > "$log"
  HERDR_STUB_LOG=$log \
  HERDR_BIN_PATH=$work/herdr \
  HERDR_PLUGIN_CONFIG_DIR=$config_dir \
  WORKTRUNK_MAIN_PATH=/repos/myrepo \
  WORKTRUNK_WORKTREE_PATH=/wt \
  WORKTRUNK_WORKSPACE_ID=wsX \
  WORKTRUNK_TAB_ID=tX \
  WORKTRUNK_PANE_ID=root1 \
    bash "$repo_root/apply-layout.sh"
}

assert_line() {
  local n=$1 expected=$2 actual
  actual=$(sed -n "${n}p" "$log")
  if [[ $actual != "$expected" ]]; then
    printf 'call %s: expected %q, got %q\n' "$n" "$expected" "$actual" >&2
    exit 1
  fi
}

assert_calls() {
  local n=$1 actual
  actual=$(wc -l < "$log" | tr -d ' ')
  if [[ $actual != "$n" ]]; then
    printf 'expected %s herdr calls, got %s:\n' "$n" "$actual" >&2
    cat "$log" >&2
    exit 1
  fi
}

# A full layout: an earlier non-matching section is skipped; the matching one
# runs a command in the root pane, splits with a defaulted target (the
# previous pane), splits with an of override and a relative cwd, and opens a
# labeled extra tab with its own pane commands.
cat > "$config_dir/layout.toml" <<'EOF'
# picked per repo via match
[[layout]]
match = "*/other"

[[layout.pane]]
run = "never"

[[layout]]
match = "*/myrepo"   # trailing comments are fine

[[layout.pane]]
run = "claude"

[[layout.pane]]
split = "right"
ratio = 0.4
run = "npm run dev"

[[layout.pane]]
split = "down"
of = 1
cwd = "packages/web"
run = "make watch"

[[layout.tab]]
label = "tests"

[[layout.tab.pane]]
run = "npm test"
EOF
apply >/dev/null
assert_calls 7
assert_line 1 'pane run root1 claude'
assert_line 2 'pane split --pane root1 --direction right --cwd /wt --no-focus --ratio 0.4'
assert_line 3 'pane run p2 npm run dev'
assert_line 4 'pane split --pane root1 --direction down --cwd /wt/packages/web --no-focus'
assert_line 5 'pane run p4 make watch'
assert_line 6 'tab create --workspace wsX --cwd /wt --no-focus --label tests'
assert_line 7 'pane run tab6root npm test'

# A cwd on the root pane of the root tab becomes a cd typed into its shell.
cat > "$config_dir/layout.toml" <<'EOF'
[[layout]]

[[layout.pane]]
cwd = "sub dir"
run = "claude"
EOF
apply >/dev/null
assert_calls 1
assert_line 1 "pane run root1 cd /wt/sub\\ dir && claude"

# A tab with no panes is still created, cwd'd to the worktree.
cat > "$config_dir/layout.toml" <<'EOF'
[[layout]]

[[layout.tab]]
label = "scratch"
EOF
apply >/dev/null
assert_calls 1
assert_line 1 'tab create --workspace wsX --cwd /wt --no-focus --label scratch'

# No section matches → nothing is applied and the applier still succeeds.
cat > "$config_dir/layout.toml" <<'EOF'
[[layout]]
match = "*/other"

[[layout.pane]]
run = "never"
EOF
output=$(apply)
assert_calls 0
if [[ $output != *"no layout.toml section matches"* ]]; then
  printf 'expected a no-match note, got %q\n' "$output" >&2
  exit 1
fi

# A second pane without a split direction is an error before anything runs.
cat > "$config_dir/layout.toml" <<'EOF'
[[layout]]

[[layout.pane]]
run = "claude"

[[layout.pane]]
run = "npm run dev"
EOF
status=0
apply >/dev/null 2>&1 || status=$?
if [[ $status == 0 ]]; then
  printf 'expected a failure for a splitless second pane\n' >&2
  exit 1
fi
assert_calls 0

# An unsupported table fails the whole file loudly.
cat > "$config_dir/layout.toml" <<'EOF'
[[layout]]

[layout.window]
EOF
status=0
apply >/dev/null 2>&1 || status=$?
if [[ $status == 0 ]]; then
  printf 'expected a failure for an unsupported table\n' >&2
  exit 1
fi

# An of pointing at a pane that doesn't exist yet is an error.
cat > "$config_dir/layout.toml" <<'EOF'
[[layout]]

[[layout.pane]]

[[layout.pane]]
split = "right"
of = 3
EOF
status=0
apply >/dev/null 2>&1 || status=$?
if [[ $status == 0 ]]; then
  printf 'expected a failure for a dangling of target\n' >&2
  exit 1
fi

# Without a layout.toml the applier is a no-op.
rm "$config_dir/layout.toml"
apply >/dev/null
assert_calls 0

printf 'layout tests passed\n'
