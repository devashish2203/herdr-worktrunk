#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

stub_dir=$(mktemp -d)
work_dir=$(mktemp -d)
trap 'rm -rf "$stub_dir" "$work_dir"' EXIT

# herdr stub: records every call it gets.
cat > "$stub_dir/herdr" <<'STUB'
#!/usr/bin/env bash
if [[ $1 == worktree && $2 == list ]]; then
  printf '%s\n' '{"result":{"source":{"repo_name":"repo"}}}'
  exit
fi
printf '%s\n' "$*" >> "$HERDR_STUB_LOG"
STUB
chmod +x "$stub_dir/herdr"
export HERDR_STUB_LOG="$stub_dir/herdr.log"

# A real repo: the relabel reads the branch with git. `elsewhere` plays the tab's
# starting directory when the switch is expected to have moved the shell.
repo="$work_dir/repo"
git init --quiet --initial-branch=main "$repo"
git -C "$repo" -c user.email=t@example.com -c user.name=test \
  commit --quiet --allow-empty -m init
git -C "$repo" branch feat/eager-worktree-focus
git -C "$repo" branch feature
elsewhere="$work_dir/elsewhere"
mkdir -p "$elsewhere"

# Run the relabel from DIR as if the tab had started in START, exposing its exit
# status, its stderr, and what herdr was asked to do.
run_relabel() {   # DIR NAME START
  local dir=$1 name=$2 start=$3
  : > "$HERDR_STUB_LOG"
  relabel_status=0
  relabel_stderr=$(cd "$dir" && bash "$repo_root/tab-relabel.sh" "$stub_dir/herdr" w1V:t3 "$name" "$start" 2>&1 >/dev/null) \
    || relabel_status=$?
}

assert_eq() {
  local expected=$1 actual=$2 what=${3:-value}
  if [[ $actual != "$expected" ]]; then
    printf 'expected %s %q, got %q\n' "$what" "$expected" "$actual" >&2
    exit 1
  fi
}

# The branch is what was picked: the label is just the branch.
run_relabel "$repo" main "$elsewhere"
assert_eq 0 "$relabel_status" 'exit status'
assert_eq 'tab rename w1V:t3 main' "$(cat "$HERDR_STUB_LOG")" 'herdr call'
assert_eq '' "$relabel_stderr" 'stderr'

# A shortcut resolved to a branch: keep the shortcut alongside.
git -C "$repo" checkout --quiet feat/eager-worktree-focus
run_relabel "$repo" pr:16 "$elsewhere"
assert_eq 'tab rename w1V:t3 feat/eager-worktree-focus (pr:16)' "$(cat "$HERDR_STUB_LOG")" 'herdr call'
assert_eq '' "$relabel_stderr" 'stderr'

# Detached HEAD: nothing to label with, so the placeholder label stays.
git -C "$repo" checkout --quiet --detach
run_relabel "$repo" pr:16 "$elsewhere"
assert_eq 0 "$relabel_status" 'exit status'
assert_eq '' "$(cat "$HERDR_STUB_LOG")" 'herdr call'

# Not in a repository at all: likewise.
run_relabel "$elsewhere" feature "$repo"
assert_eq 0 "$relabel_status" 'exit status'
assert_eq '' "$(cat "$HERDR_STUB_LOG")" 'herdr call'

# The shell never left the directory the tab started in, and the name is neither
# the branch under it nor something that resolves to it: no shell integration ran
# `wt`, so the branch here is the source branch. Keep the typed name and say why.
git -C "$repo" checkout --quiet main
run_relabel "$repo" foo "$repo"
assert_eq 'tab rename w1V:t3 foo' "$(cat "$HERDR_STUB_LOG")" 'herdr call'
if [[ $relabel_stderr != *'wt config shell install'* ]]; then
  printf 'expected the shell integration hint, got %q\n' "$relabel_stderr" >&2
  exit 1
fi

# ...but picking origin/<branch> from inside that branch's worktree, or a shortcut
# that resolves to the worktree we're already in, legitimately stays put.
git -C "$repo" checkout --quiet feature
run_relabel "$repo" origin/feature "$repo"
assert_eq 'tab rename w1V:t3 feature (origin/feature)' "$(cat "$HERDR_STUB_LOG")" 'herdr call'
assert_eq '' "$relabel_stderr" 'stderr'

git -C "$repo" checkout --quiet main
run_relabel "$repo" '^' "$repo"
assert_eq 'tab rename w1V:t3 main (^)' "$(cat "$HERDR_STUB_LOG")" 'herdr call'
assert_eq '' "$relabel_stderr" 'stderr'

# So does picking the branch already checked out here, whatever the shell did.
run_relabel "$repo" main "$repo"
assert_eq 'tab rename w1V:t3 main' "$(cat "$HERDR_STUB_LOG")" 'herdr call'
assert_eq '' "$relabel_stderr" 'stderr'

# Configured tab labels use the same templates and retained PR as workspaces.
linked="$work_dir/linked"
git -C "$repo" worktree add --quiet -b feat/login "$linked"
export HERDR_PLUGIN_CONFIG_DIR="$stub_dir/config"
mkdir -p "$HERDR_PLUGIN_CONFIG_DIR"
printf 'label_preset = "pr-first"\n' > "$HERDR_PLUGIN_CONFIG_DIR/config.toml"
run_relabel "$linked" https://github.com/o/r/pull/123 "$elsewhere"
assert_eq 'tab rename w1V:t3 #123 feat/login' "$(cat "$HERDR_STUB_LOG")" 'herdr call'
run_relabel "$linked" feat/login "$elsewhere"
assert_eq 'tab rename w1V:t3 #123 feat/login' "$(cat "$HERDR_STUB_LOG")" 'herdr call'
printf "label_pr_format = '{repo}: #{pr_number} {branch}'\n" > "$HERDR_PLUGIN_CONFIG_DIR/config.toml"
run_relabel "$linked" feat/login "$elsewhere"
assert_eq 'tab rename w1V:t3 repo: #123 feat/login' "$(cat "$HERDR_STUB_LOG")" 'herdr call'

# The main checkout formats a PR it is handed but keeps no state for it.
run_relabel "$repo" https://github.com/o/r/pull/7 "$elsewhere"
assert_eq 'tab rename w1V:t3 repo: #7 main' "$(cat "$HERDR_STUB_LOG")" 'herdr call'
run_relabel "$repo" main "$elsewhere"
assert_eq 'tab rename w1V:t3 main' "$(cat "$HERDR_STUB_LOG")" 'herdr call'
[[ ! -e $repo/.git/herdr-worktrunk-label ]] || { echo 'unexpected main checkout label state' >&2; exit 1; }

# Missing arguments are a plugin bug, not a rename to attempt.
: > "$HERDR_STUB_LOG"
if (cd "$repo" && bash "$repo_root/tab-relabel.sh" "$stub_dir/herdr" w1V:t3 2>/dev/null); then
  printf 'expected tab-relabel.sh to reject missing arguments\n' >&2
  exit 1
fi
assert_eq '' "$(cat "$HERDR_STUB_LOG")" 'herdr call'

printf 'tab relabel tests passed\n'
