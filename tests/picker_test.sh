#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

stub_dir=$(mktemp -d)
work_dir=$(mktemp -d)
trap 'rm -rf "$stub_dir" "$work_dir"' EXIT

config_dir="$stub_dir/config"
mkdir -p "$config_dir"

# A real repo: picker.sh lists refs with `git for-each-ref` and helpers.sh resolves
# existing branches with `git show-ref`, so git is never stubbed.
git init --quiet --initial-branch=main "$work_dir/repo"
git -C "$work_dir/repo" -c user.email=t@example.com -c user.name=test \
  commit --quiet --allow-empty -m init
git -C "$work_dir/repo" branch silas/foo-bar

# fzf stub: records the candidate list and its argv, then replays the output the
# real picker would produce for the scripted keypress.
cat > "$stub_dir/fzf" <<'EOF'
#!/usr/bin/env bash
cat > "$STUB_DIR/fzf.stdin"
printf '%s\n' "$@" > "$STUB_DIR/fzf.args"
printf '%s' "$FZF_STUB_OUT"
exit "${FZF_STUB_EXIT:-0}"
EOF

# wt stub: `list` feeds the picker, `switch` records the argv under test.
cat > "$stub_dir/wt" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == list ]]; then
  printf '%s\n' "$WT_STUB_LIST"
  exit 0
fi
printf '%s ' "$@" > "$STUB_DIR/wt.args"
printf '{"branch":"%s","path":"%s"}\n' "${2:-}" "$STUB_DIR/checkout"
EOF

# herdr stub: `worktree list` locates the repo root and `worktree open` is the
# workspace-mode result. In tab mode `tab create` answers with a pane, `pane
# process-info` describes the shell running in it ($HERDR_STUB_SHELL, or a failure
# when that is `fail`), and `pane run` records the line typed into it.
cat > "$stub_dir/herdr" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_DIR/herdr.log"
case "${1:-} ${2:-}" in
  "worktree list")
    printf '{"result":{"source":{"repo_root":"%s","repo_name":"repo","source_workspace_id":"w1"}}}\n' "$REPO_CWD"
    ;;
  "tab create")
    printf '%s\n' "$@" > "$STUB_DIR/tab_create.args"
    printf '{"result":{"root_pane":{"pane_id":"w1V:p5","tab_id":"w1V:t3"}}}\n'
    ;;
  "pane process-info")
    [[ $HERDR_STUB_SHELL == fail ]] && exit 1
    printf '{"result":{"process_info":{"shell_pid":42,"foreground_processes":[{"pid":42,"name":"%s"}]}}}\n' \
      "$HERDR_STUB_SHELL"
    ;;
  "pane run")
    printf '%s\n' "$4" > "$STUB_DIR/pane_run.args"
    ;;
esac
EOF

chmod +x "$stub_dir/fzf" "$stub_dir/wt" "$stub_dir/herdr"

# Two worktree branches from `wt list`, one of them already a local head.
wt_list='[{"branch":"silas/foo-bar","path":"/tmp/a","kind":"worktree"},
          {"branch":"pr-42","path":"/tmp/b","kind":"worktree"}]'

# The shell herdr reports for a new tab and the $SHELL the picker would fall back
# to are pinned so the runner's own shell can't leak into the tab-mode cases.
run_picker() {
  local out=$1 exit_code=$2
  shift 2
  rm -f "$stub_dir/wt.args" "$stub_dir/herdr.log" "$stub_dir/tab_create.args" "$stub_dir/pane_run.args"
  (
    cd "$work_dir/repo"
    PATH="$stub_dir:$PATH" \
    STUB_DIR="$stub_dir" \
    REPO_CWD="$work_dir/repo" \
    FZF_STUB_OUT="$out" \
    FZF_STUB_EXIT="$exit_code" \
    WT_STUB_LIST="$wt_list" \
    HERDR_STUB_SHELL="${HERDR_STUB_SHELL:-zsh}" \
    SHELL="${PICKER_SHELL:-/bin/zsh}" \
    HERDR_PLUGIN_ROOT="$repo_root" \
    HERDR_BIN_PATH="$stub_dir/herdr" \
    HERDR_PLUGIN_CONFIG_DIR="$config_dir" \
    HERDR_WORKSPACE_ID=w1 \
      bash "$repo_root/picker.sh" "$@" >/dev/null 2>&1
  )
}

wt_args() { cat "$stub_dir/wt.args" 2>/dev/null || true; }
pane_run_args() { cat "$stub_dir/pane_run.args" 2>/dev/null || true; }
herdr_log() { cat "$stub_dir/herdr.log" 2>/dev/null || true; }

assert_eq() {
  local expected=$1 actual=$2 what=${3:-value}
  if [[ $actual != "$expected" ]]; then
    printf 'expected %s %q, got %q\n' "$what" "$expected" "$actual" >&2
    exit 1
  fi
}

assert_contains() {
  local needle=$1 haystack=$2 what=${3:-output}
  if [[ $haystack != *"$needle"* ]]; then
    printf 'expected %q in %s %q\n' "$needle" "$what" "$haystack" >&2
    exit 1
  fi
}

# Plain ↵ on a match switches to the match, not to the query.
run_picker $'silas/foo\nsilas/foo-bar' 0
assert_eq 'switch silas/foo-bar --no-cd --format=json ' "$(wt_args)" 'wt argv'

# Plain ↵ with nothing matched creates the typed name (fzf exits 1).
run_picker $'silas/brand-new' 1
assert_eq 'switch --create silas/brand-new --no-cd --format=json ' "$(wt_args)" 'wt argv'

# alt-↵ prints the query alone, so the typed name is created even though the list
# had a fuzzy match highlighted.
run_picker $'silas/foo' 0
assert_eq 'switch --create silas/foo --no-cd --format=json ' "$(wt_args)" 'wt argv'

# ...and the base is carried through when creating from the current branch.
run_picker $'silas/foo' 0 --create-base=current
assert_eq 'switch --create silas/foo --base @ --no-cd --format=json ' "$(wt_args)" 'wt argv'

# A name that is an existing branch is switched to, never created: worktrunk checks
# out existing refs and --create would fail.
run_picker $'silas/foo-bar' 0
assert_eq 'switch silas/foo-bar --no-cd --format=json ' "$(wt_args)" 'wt argv'

# esc cancels without touching worktrunk.
run_picker '' 130
assert_eq '' "$(wt_args)" 'wt argv'

# The binding the header advertises is the one fzf is asked for.
assert_contains '--bind=alt-enter:print-query' "$(cat "$stub_dir/fzf.args")" 'fzf argv'

# Refs are offered before the slow `wt list` source and deduped without sorting, so
# the picker fills in before worktrunk has finished stat-ing every checkout.
assert_eq $'main\nsilas/foo-bar\npr-42' "$(cat "$stub_dir/fzf.stdin")" 'candidate list'

# Tab mode never runs wt here: it opens a tab and types `wt switch` into that tab's
# shell, in the syntax of whichever shell herdr says the tab runs, followed by the
# relabel step. Nothing else about the picker changes. The exact lines below spell
# the temp and checkout paths as-is, assuming they hold no shell metacharacters.
printf 'open_mode = "tab"\n' > "$config_dir/config.toml"
repo_cwd="$work_dir/repo"
relabel="$repo_root/tab-relabel.sh"

HERDR_STUB_SHELL=nu run_picker $'silas/brand-new' 1
assert_eq "print -n (wt switch --create 'silas/brand-new'); bash '$relabel' '$stub_dir/herdr' 'w1V:t3' 'silas/brand-new' '$repo_cwd'" \
  "$(pane_run_args)" 'pane run line'
assert_eq '' "$(wt_args)" 'wt argv'
assert_eq $'tab\ncreate\n--workspace\nw1\n--cwd\n'"$repo_cwd"$'\n--label\nsilas/brand-new\n--focus' \
  "$(cat "$stub_dir/tab_create.args")" 'tab create argv'
assert_contains 'pane process-info --pane w1V:p5' "$(herdr_log)" 'herdr calls'
assert_contains 'pane run w1V:p5 ' "$(herdr_log)" 'herdr calls'

# A POSIX shell gets the && form with %q quoting, and the base comes along.
HERDR_STUB_SHELL=zsh run_picker $'silas/brand-new' 1 --create-base=current
assert_eq "wt switch --create silas/brand-new --base @ && bash $relabel $stub_dir/herdr w1V:t3 silas/brand-new $repo_cwd" \
  "$(pane_run_args)" 'pane run line'
assert_eq '' "$(wt_args)" 'wt argv'

# Existing branches and worktrunk shortcuts are switched to, never created.
HERDR_STUB_SHELL=nu run_picker $'silas/foo-bar' 0
assert_contains "print -n (wt switch 'silas/foo-bar'); bash " "$(pane_run_args)" 'pane run line'
HERDR_STUB_SHELL=nu run_picker $'pr:16' 1
assert_contains "print -n (wt switch 'pr:16'); bash " "$(pane_run_args)" 'pane run line'
HERDR_STUB_SHELL=fish run_picker $'^' 1
assert_contains 'wt switch \^ && bash ' "$(pane_run_args)" 'pane run line'

# When herdr can't say what the tab runs, $SHELL decides.
HERDR_STUB_SHELL=fail PICKER_SHELL=/opt/homebrew/bin/nu run_picker $'silas/brand-new' 1
assert_contains "print -n (wt switch --create 'silas/brand-new'); bash " "$(pane_run_args)" 'pane run line'
HERDR_STUB_SHELL=fail PICKER_SHELL=/bin/bash run_picker $'silas/brand-new' 1
assert_contains 'wt switch --create silas/brand-new && bash ' "$(pane_run_args)" 'pane run line'

# esc still cancels before any tab is opened.
run_picker '' 130
assert_eq '' "$(herdr_log)" 'herdr calls'

printf 'picker_test: ok\n'
