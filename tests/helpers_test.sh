#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../helpers.sh
source "$repo_root/helpers.sh"

for tok in '^' '-' 'pr:123' 'mr:45' 'https://github.com/o/r/pull/7'; do
  if ! worktrunk_is_shortcut "$tok"; then
    printf 'expected %q to be a worktrunk shortcut\n' "$tok" >&2
    exit 1
  fi
done

# @ (current) is intentionally not a shortcut — see helpers.sh.
for tok in 'my-feature' 'main' 'feature/foo' '@'; do
  if worktrunk_is_shortcut "$tok"; then
    printf 'expected %q not to be a worktrunk shortcut\n' "$tok" >&2
    exit 1
  fi
done

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

# worktrunk_ref_exists resolves both local heads and remote-tracking branches.
sandbox=$tmp_dir/repo
mkdir -p "$sandbox"
(
  cd "$sandbox"
  git init -q
  git config user.email test@example.com
  git config user.name test
  git commit -q --allow-empty -m init
  git branch feature
  git update-ref refs/remotes/origin/remote-feat HEAD
)
cd "$sandbox"

for ref in 'feature' 'origin/remote-feat'; do
  if ! worktrunk_ref_exists "$ref"; then
    printf 'expected %q to be an existing ref\n' "$ref" >&2
    exit 1
  fi
done

for ref in 'does-not-exist' 'origin/nope'; do
  if worktrunk_ref_exists "$ref"; then
    printf 'expected %q not to be an existing ref\n' "$ref" >&2
    exit 1
  fi
done

cd - >/dev/null

# Native workspace mode preserves the source worktree's relative subdirectory
# when that same directory exists in the destination.
source_root="$tmp_dir/source tree"
target_root="$tmp_dir/target tree"
relative=areas/clients/checkout-web
mkdir -p "$source_root/$relative" "$target_root/$relative"

preserved=$(worktrunk_preserved_cwd "$target_root" "$source_root" "$source_root/$relative")
if [[ $preserved != "$target_root/$relative" ]]; then
  printf 'expected preserved cwd %q, got %q\n' "$target_root/$relative" "$preserved" >&2
  exit 1
fi

rm -rf "$target_root/$relative"
preserved=$(worktrunk_preserved_cwd "$target_root" "$source_root" "$source_root/$relative")
if [[ $preserved != "$target_root" ]]; then
  printf 'expected missing target subdir to fall back to %q, got %q\n' "$target_root" "$preserved" >&2
  exit 1
fi

preserved=$(worktrunk_preserved_cwd "$target_root" "$source_root" "$tmp_dir")
if [[ $preserved != "$target_root" ]]; then
  printf 'expected cwd outside source to fall back to %q, got %q\n' "$target_root" "$preserved" >&2
  exit 1
fi

preserved=$(worktrunk_preserved_cwd "$target_root" "$source_root" "$source_root")
if [[ $preserved != "$target_root" ]]; then
  printf 'expected source root cwd to map to target root %q, got %q\n' "$target_root" "$preserved" >&2
  exit 1
fi

preserved=$(worktrunk_preserved_cwd "$target_root" "$tmp_dir/missing" "$tmp_dir/missing/subdir")
if [[ $preserved != "$target_root" ]]; then
  printf 'expected missing source root to fall back to %q, got %q\n' "$target_root" "$preserved" >&2
  exit 1
fi

# Opening a new native workspace uses Herdr's supported pane API to cd its root
# pane. Reopening an existing workspace leaves that workspace's pane state alone.
fake_herdr="$tmp_dir/herdr"
herdr_log="$tmp_dir/herdr.log"
cat >"$fake_herdr" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$HERDR_TEST_LOG"
case "$1 $2" in
  'worktree open')
    if [[ ${HERDR_TEST_INCLUDE_PANE:-true} == true ]]; then
      printf '{"result":{"already_open":%s,"root_pane":{"pane_id":"w2:p1"}}}\n' \
        "${HERDR_TEST_ALREADY_OPEN:-false}"
    else
      printf '{"result":{"already_open":%s}}\n' "${HERDR_TEST_ALREADY_OPEN:-false}"
    fi
    ;;
  'pane run')
    [[ ${HERDR_TEST_PANE_RUN_FAIL:-false} != true ]] || exit 1
    printf '{"result":{"type":"pane_input_sent"}}\n'
    ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$fake_herdr"
export HERDR_TEST_LOG=$herdr_log
export HERDR_TEST_ALREADY_OPEN=false
mkdir -p "$target_root/$relative"
worktrunk_open_workspace "$fake_herdr" w1 "$target_root" feature "$target_root/$relative" >/dev/null
printf -v quoted_preserved '%q' "$target_root/$relative"
if ! grep -Fq "pane run w2:p1 cd -- $quoted_preserved" "$herdr_log"; then
  printf 'expected new workspace root pane to cd to preserved cwd; log:\n' >&2
  cat "$herdr_log" >&2
  exit 1
fi

: >"$herdr_log"
export HERDR_TEST_ALREADY_OPEN=false
worktrunk_open_workspace "$fake_herdr" w1 "$target_root" feature "$target_root" >/dev/null
if grep -Fq 'pane run' "$herdr_log"; then
  printf 'expected target root cwd not to issue a redundant cd; log:\n' >&2
  cat "$herdr_log" >&2
  exit 1
fi

: >"$herdr_log"
export HERDR_TEST_ALREADY_OPEN=true
worktrunk_open_workspace "$fake_herdr" w1 "$target_root" feature "$target_root/$relative" >/dev/null
if ! grep -Fq 'worktree open' "$herdr_log" || grep -Fq 'pane run' "$herdr_log"; then
  printf 'expected already-open workspace to open without changing pane cwd; log:\n' >&2
  cat "$herdr_log" >&2
  exit 1
fi

: >"$herdr_log"
export HERDR_TEST_ALREADY_OPEN=false
export HERDR_TEST_INCLUDE_PANE=false
if worktrunk_open_workspace "$fake_herdr" w1 "$target_root" feature "$target_root/$relative" \
  >/dev/null 2>"$tmp_dir/missing-pane.err"; then
  printf 'expected missing root pane to fail\n' >&2
  exit 1
fi
if ! grep -Fq 'herdr returned no root pane' "$tmp_dir/missing-pane.err"; then
  printf 'expected a useful missing-pane error; stderr:\n' >&2
  cat "$tmp_dir/missing-pane.err" >&2
  exit 1
fi

: >"$herdr_log"
export HERDR_TEST_INCLUDE_PANE=true
export HERDR_TEST_PANE_RUN_FAIL=true
if worktrunk_open_workspace "$fake_herdr" w1 "$target_root" feature "$target_root/$relative" \
  >/dev/null 2>"$tmp_dir/pane-run.err"; then
  printf 'expected pane run failure to propagate\n' >&2
  exit 1
fi
if ! grep -Fq 'failed to set worktree workspace cwd' "$tmp_dir/pane-run.err"; then
  printf 'expected a useful pane-run error; stderr:\n' >&2
  cat "$tmp_dir/pane-run.err" >&2
  exit 1
fi
unset HERDR_TEST_LOG HERDR_TEST_ALREADY_OPEN HERDR_TEST_INCLUDE_PANE HERDR_TEST_PANE_RUN_FAIL

printf 'helpers tests passed\n'
