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

# Print the label for a tab or workspace opened by picking NAME, which `wt switch`
# resolved to BRANCH. NAME may be a shortcut or a remote-tracking ref rather than
# the branch itself, so it stays alongside in parens when the two differ, e.g.
# "feat/eager-worktree-focus (pr:16)". With no branch to show (empty BRANCH), the
# label is just NAME.
worktrunk_switch_label() {
  local branch=$1 name=$2
  if [[ -z $branch || $branch == "$name" ]]; then
    printf '%s\n' "$name"
  else
    printf '%s (%s)\n' "$branch" "$name"
  fi
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

# Print the name of the shell running in herdr pane PANE_ID (e.g. `zsh`, `nu`),
# or nothing when it can't be told. Tab mode types a command line into that shell,
# so the line has to be written in its syntax. Asks herdr for the pane's process
# info: the foreground entry whose pid is the shell's is authoritative. When a
# startup child (a prompt, a version manager) holds the foreground instead, the
# shell pid is looked up with ps; failing that, $SHELL is what herdr's default
# shell falls back to as well. Herdr can be asked a moment before the pane's
# process has started, so an empty answer is retried briefly.
worktrunk_pane_shell() {
  local herdr=$1 pane=$2 attempt json='' name='' shell_pid=''
  for attempt in 1 2 3; do
    [[ $attempt -gt 1 ]] && sleep 0.1
    json=$("$herdr" pane process-info --pane "$pane" 2>/dev/null) || json=''
    { read -r name; read -r shell_pid; } < <(
      printf '%s\n' "$json" | jq -r '
        .result.process_info as $p
        | ($p.foreground_processes // []) as $fg
        | ([$fg[] | select(.pid == $p.shell_pid) | (.name // .argv0 // empty)][0] // ""),
          ($p.shell_pid // "" | tostring)' 2>/dev/null
    ) || true
    [[ -n $name || -n $shell_pid ]] && break
  done
  if [[ -z $name && -n $shell_pid ]]; then
    name=$(ps -o comm= -p "$shell_pid" 2>/dev/null || true)
  fi
  [[ -z $name ]] && name=${SHELL:-}
  name=${name##*/}   # /opt/homebrew/bin/nu → nu
  name=${name#-}     # -zsh (a login shell's argv0) → zsh
  printf '%s\n' "$name"
}

# Map a shell name to the syntax family worktrunk_tab_command generates: `nu` for
# nushell, `posix` for everything else. fish belongs with the POSIX shells here —
# it accepts `&&`, `;` and printf %q's backslash and single-quote escapes — and so
# does any shell we don't recognize, including an empty name.
worktrunk_shell_family() {
  case ${1##*/} in
    nu|nushell) printf 'nu\n' ;;
    *) printf 'posix\n' ;;
  esac
}

# Quote S as one word for nushell. Single quotes are literal there, exactly as in
# POSIX, but can't contain a single quote at all; such a value goes in double
# quotes, which process only `\` and `"` (nushell does not interpolate `$` inside
# plain double quotes, so nothing else needs escaping).
worktrunk_quote_nu() {
  local s=$1
  if [[ $s != *\'* ]]; then
    printf "'%s'\n" "$s"
  else
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    printf '"%s"\n' "$s"
  fi
}

# Quote S as one word for a POSIX shell (bash, zsh). fish reads the backslash and
# single-quote escapes %q emits for ordinary names too; only the $'...' form it
# falls back to for bytes the locale can't print would be foreign to it.
worktrunk_quote_posix() {
  printf '%q\n' "$1"
}

# Print the line tab mode types into the new tab's shell for FAMILY (see
# worktrunk_shell_family): `wt WT_ARGS...`, then — only if that succeeded —
# `bash RELABEL HERDR TAB_ID NAME START_CWD` (see tab-relabel.sh).
#
#   worktrunk_tab_command FAMILY RELABEL HERDR TAB_ID NAME START_CWD -- WT_ARGS...
#
# `wt` and its subcommand stay bare words so the shell runs worktrunk's integration
# command — the one that cd's the shell into the worktree — rather than the bare
# binary; the plugin's own flags, --create and --base, stay bare too. Every other
# token is a user value or a path and goes through the family's quoter.
#
# Three nushell facts shape the nu line. There is no `&&`: a `;` chain already
# stops at a failing command, and worktrunk's nushell `wt` ends a failed switch
# with a failing external. A statement that isn't the last one has its *value*
# dropped, and worktrunk's `wt` returns the binary's stdout as its value, so the
# call is wrapped in `print -n (...)` to show it. And `wt ... | print` would not
# do: piping a failing command into print swallows the failure.
worktrunk_tab_command() {
  local family=$1 relabel=$2 herdr=$3 tab_id=$4 name=$5 start=$6
  shift 6
  if [[ ${1:-} != -- ]]; then
    printf 'worktrunk_tab_command: expected -- before the wt arguments\n' >&2
    return 2
  fi
  shift

  local quote
  case $family in
    nu) quote=worktrunk_quote_nu ;;
    *) quote=worktrunk_quote_posix ;;
  esac

  local wt="wt $1" arg
  shift
  for arg in "$@"; do
    case $arg in
      --create|--base) wt+=" $arg" ;;
      *) wt+=" $("$quote" "$arg")" ;;
    esac
  done

  local relabel_cmd
  relabel_cmd="bash $("$quote" "$relabel") $("$quote" "$herdr") $("$quote" "$tab_id")"
  relabel_cmd+=" $("$quote" "$name") $("$quote" "$start")"

  case $family in
    nu) printf 'print -n (%s); %s\n' "$wt" "$relabel_cmd" ;;
    *) printf '%s && %s\n' "$wt" "$relabel_cmd" ;;
  esac
}
