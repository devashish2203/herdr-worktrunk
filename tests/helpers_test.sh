#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../helpers.sh
source "$repo_root/helpers.sh"

assert_eq() {
  local expected=$1 actual=$2 what=${3:-value}
  if [[ $actual != "$expected" ]]; then
    printf 'expected %s %q, got %q\n' "$what" "$expected" "$actual" >&2
    exit 1
  fi
}

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

# The label after a switch: the picked name alone when it is the branch or there is
# no branch to show, otherwise the branch with the picked name alongside.
assert_eq main "$(worktrunk_switch_label main main)" 'switch label'
assert_eq pr:16 "$(worktrunk_switch_label '' pr:16)" 'switch label'
assert_eq 'feat/eager-worktree-focus (pr:16)' \
  "$(worktrunk_switch_label feat/eager-worktree-focus pr:16)" 'switch label'

sandbox=$(mktemp -d)     # a git repo for worktrunk_ref_exists
pane_stub=$(mktemp -d)   # a herdr stand-in for worktrunk_pane_shell, further down
trap 'rm -rf "$sandbox" "$pane_stub"' EXIT

# worktrunk_ref_exists resolves both local heads and remote-tracking branches.
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

schema_one='[
  {"branch":"main","kind":"worktree","path":"/repo","is_main":true},
  {"branch":"feature","kind":"worktree","path":"/repo.feature","is_main":false},
  {"branch":"ready","kind":"branch"}
]'
schema_two='{
  "schema":2,
  "items":[
    {"branch":"main","worktree":{"path":"/repo","main":true}},
    {"branch":"feature","worktree":{"path":"/repo.feature","main":false}},
    {"branch":"ready"}
  ]
}'
expected_items='main|worktree|/repo|true
feature|worktree|/repo.feature|false
ready|branch|null|false'

for list_json in "$schema_one" "$schema_two"; do
  actual_items=$(printf '%s\n' "$list_json" \
    | worktrunk_list_items \
    | jq -r '[.branch, .kind, (.path | tostring), (.is_main | tostring)] | join("|")')
  if [[ $actual_items != "$expected_items" ]]; then
    printf 'unexpected normalized worktrunk list items:\n%s\n' "$actual_items" >&2
    exit 1
  fi
done

if printf '%s\n' '{"schema":3}' | worktrunk_list_items >/dev/null 2>&1; then
  printf 'expected unsupported worktrunk list schema to fail\n' >&2
  exit 1
fi

# A shell name maps to the syntax family the tab-mode line is generated in: only
# nushell needs its own; everything else — fish, an unknown shell, no name at all —
# takes the POSIX form.
for shell in nu nushell /opt/homebrew/bin/nu; do
  assert_eq nu "$(worktrunk_shell_family "$shell")" "family of $shell"
done
for shell in bash zsh fish sh dash ksh /bin/zsh starship ''; do
  assert_eq posix "$(worktrunk_shell_family "$shell")" "family of '$shell'"
done

# Nushell quoting: single quotes unless the value has one, then double quotes with
# only \ and " escaped.
assert_eq "'foo'" "$(worktrunk_quote_nu foo)" 'nu quote'
assert_eq "'a b'" "$(worktrunk_quote_nu 'a b')" 'nu quote'
assert_eq "\"it's\"" "$(worktrunk_quote_nu "it's")" 'nu quote'
assert_eq "'say \"hi\"'" "$(worktrunk_quote_nu 'say "hi"')" 'nu quote'
assert_eq "'back\\slash'" "$(worktrunk_quote_nu 'back\slash')" 'nu quote'
assert_eq "\"it's \\\"q\\\" \\\\\"" "$(worktrunk_quote_nu "it's \"q\" \\")" 'nu quote'
assert_eq "''" "$(worktrunk_quote_nu '')" 'nu quote'

# POSIX quoting is bash's own %q; a few shapes tab mode relies on.
assert_eq 'a\ b' "$(worktrunk_quote_posix 'a b')" 'posix quote'
assert_eq "it\\'s" "$(worktrunk_quote_posix "it's")" 'posix quote'
assert_eq '@' "$(worktrunk_quote_posix '@')" 'posix quote'
assert_eq 'pr:16' "$(worktrunk_quote_posix 'pr:16')" 'posix quote'
assert_eq '-' "$(worktrunk_quote_posix '-')" 'posix quote'
assert_eq "''" "$(worktrunk_quote_posix '')" 'posix quote'

# Both quoters round-trip through their shell. The nushell leg is skipped where nu
# isn't installed.
samples=(foo 'a b' "it's" 'say "hi"' 'back\slash' "it's \"q\" \\" '^' '-' '@' 'pr:16' '$x'
         'https://github.com/o/r/pull/7')
for s in "${samples[@]}"; do
  assert_eq "$s" "$(eval "printf '%s' $(worktrunk_quote_posix "$s")")" "posix round-trip of $s"
  if command -v nu >/dev/null; then
    assert_eq "$s" "$(nu -n -c "print -n $(worktrunk_quote_nu "$s")")" "nu round-trip of $s"
  fi
done

# The typed line: wt, its subcommand and the plugin's flags bare; user values and
# paths quoted for the family. The nu form wraps wt in print -n (...) and chains
# with `;`, the POSIX form chains with &&.
line=$(worktrunk_tab_command nu '/plug in/tab-relabel.sh' '/her dr/herdr' w1V:t3 foo /Users/x/repo \
  -- switch --create foo --base @)
assert_eq "print -n (wt switch --create 'foo' --base '@'); bash '/plug in/tab-relabel.sh' '/her dr/herdr' 'w1V:t3' 'foo' '/Users/x/repo'" \
  "$line" 'nu tab line'

line=$(worktrunk_tab_command posix '/plug in/tab-relabel.sh' '/her dr/herdr' w1V:t3 foo /Users/x/repo \
  -- switch --create foo --base @)
assert_eq 'wt switch --create foo --base @ && bash /plug\ in/tab-relabel.sh /her\ dr/herdr w1V:t3 foo /Users/x/repo' \
  "$line" 'posix tab line'

line=$(worktrunk_tab_command nu /p/tab-relabel.sh herdr w1:t1 pr:16 /r -- switch pr:16)
assert_eq "print -n (wt switch 'pr:16'); bash '/p/tab-relabel.sh' 'herdr' 'w1:t1' 'pr:16' '/r'" "$line" 'nu shortcut line'

line=$(worktrunk_tab_command nu /p/tab-relabel.sh herdr w1:t1 - /r -- switch -)
assert_eq "print -n (wt switch '-'); bash '/p/tab-relabel.sh' 'herdr' 'w1:t1' '-' '/r'" "$line" 'nu previous line'

line=$(worktrunk_tab_command posix /p/tab-relabel.sh herdr w1:t1 '^' /r -- switch '^')
assert_eq 'wt switch \^ && bash /p/tab-relabel.sh herdr w1:t1 \^ /r' "$line" 'posix shortcut line'

line=$(worktrunk_tab_command nu /p/tab-relabel.sh herdr w1:t1 "it's" /r -- switch --create "it's")
assert_eq "print -n (wt switch --create \"it's\"); bash '/p/tab-relabel.sh' 'herdr' 'w1:t1' \"it's\" '/r'" "$line" 'nu quote line'

line=$(worktrunk_tab_command '' /p/tab-relabel.sh herdr w1:t1 x /r -- switch x)   # unknown family → POSIX
assert_eq 'wt switch x && bash /p/tab-relabel.sh herdr w1:t1 x /r' "$line" 'default family line'

# Only the plugin's own flags stay bare; any other dash token is quoted like a value.
line=$(worktrunk_tab_command nu /p/tab-relabel.sh herdr w1:t1 x /r -- switch --other x)
assert_eq "print -n (wt switch '--other' 'x'); bash '/p/tab-relabel.sh' 'herdr' 'w1:t1' 'x' '/r'" "$line" 'nu other flag line'

if worktrunk_tab_command nu /p/tab-relabel.sh herdr w1:t1 x /r switch x 2>/dev/null; then
  printf 'expected worktrunk_tab_command to insist on the -- separator\n' >&2
  exit 1
fi

# Shell detection asks herdr for the pane's processes. The stub answers with
# $PANE_STUB_JSON, failing the first $PANE_STUB_FAIL_CALLS calls, and logs each call.
cat > "$pane_stub/herdr" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PANE_STUB_LOG"
if (( $(wc -l < "$PANE_STUB_LOG") <= ${PANE_STUB_FAIL_CALLS:-0} )); then
  exit 1
fi
printf '%s\n' "$PANE_STUB_JSON"
EOF
chmod +x "$pane_stub/herdr"
export PANE_STUB_LOG="$pane_stub/log"

pane_shell() {   # JSON FAIL_CALLS SHELL
  : > "$PANE_STUB_LOG"
  PANE_STUB_JSON=$1 PANE_STUB_FAIL_CALLS=$2 SHELL=$3 worktrunk_pane_shell "$pane_stub/herdr" w1V:p5
}
pane_calls() { wc -l < "$PANE_STUB_LOG" | tr -d ' '; }

# The foreground entry that is the shell itself names it.
nu_json='{"result":{"process_info":{"shell_pid":42,"foreground_processes":[{"pid":42,"name":"nu","argv0":"nu","argv":["-nu"]}]}}}'
assert_eq nu "$(pane_shell "$nu_json" 0 /bin/zsh)" 'pane shell'
assert_eq 1 "$(pane_calls)" 'process-info calls'
assert_eq 'pane process-info --pane w1V:p5' "$(cat "$PANE_STUB_LOG")" 'process-info argv'

zsh_json='{"result":{"process_info":{"shell_pid":7,"foreground_processes":[{"pid":7,"name":"zsh","argv0":"-zsh"}]}}}'
assert_eq zsh "$(pane_shell "$zsh_json" 0 /opt/homebrew/bin/nu)" 'pane shell'

# Login shells announce themselves with a leading dash; argv0 stands in for a
# missing name.
fish_json='{"result":{"process_info":{"shell_pid":7,"foreground_processes":[{"pid":7,"argv0":"-fish"}]}}}'
assert_eq fish "$(pane_shell "$fish_json" 0 /bin/zsh)" 'pane shell'

# A startup child holding the foreground is not the shell: the shell pid is looked
# up instead (this test's own bash stands in for it).
child_json='{"result":{"process_info":{"shell_pid":'"$$"',"foreground_processes":[{"pid":999999,"name":"starship"}]}}}'
assert_eq bash "$(pane_shell "$child_json" 0 /opt/homebrew/bin/nu)" 'pane shell'

# Herdr not answering falls back to $SHELL after a few tries, then to nothing.
assert_eq fish "$(pane_shell '' 99 /usr/local/bin/fish)" 'pane shell'
assert_eq 3 "$(pane_calls)" 'process-info calls'
assert_eq '' "$(pane_shell '' 99 '')" 'pane shell'

# A transient failure is retried.
assert_eq nu "$(pane_shell "$nu_json" 1 /bin/zsh)" 'pane shell'
assert_eq 2 "$(pane_calls)" 'process-info calls'

# An answer without a shell pid is treated as not ready.
early_json='{"result":{"process_info":{"shell_pid":null,"foreground_processes":[]}}}'
assert_eq zsh "$(pane_shell "$early_json" 0 /bin/zsh)" 'pane shell'
assert_eq 3 "$(pane_calls)" 'process-info calls'

printf 'helpers tests passed\n'
