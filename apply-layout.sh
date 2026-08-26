#!/usr/bin/env bash
# Applies the user's declarative tab/pane layout (layout.toml in the plugin's
# managed config directory) to a freshly opened worktree workspace or tab.
# Runs as the built-in post-open hook via run-hook.sh when the user has no
# post-open.sh script of their own, under the same contract: cwd is the new
# worktree, and WORKTRUNK_WORKTREE_PATH / WORKTRUNK_MAIN_PATH /
# WORKTRUNK_WORKSPACE_ID / WORKTRUNK_TAB_ID / WORKTRUNK_PANE_ID /
# HERDR_BIN_PATH are exported.
#
# layout.toml is a restricted TOML subset: [[layout]] sections holding scalar
# `key = value` lines (quoted strings or bare scalars, one per line — no
# inline tables, arrays, or multi-line values) and [[layout.pane]] /
# [[layout.tab]] / [[layout.tab.pane]] subsections. The first [[layout]]
# section whose `match` glob matches the primary checkout path — or that has
# no `match` at all — is applied; later sections are ignored.
#
# Within a tab, the first pane entry is the tab's root pane; every further
# pane names a `split` direction and is split off an earlier pane of the same
# tab (`of = N`, defaulting to the previous one). Unknown keys warn and are
# skipped so newer layout files degrade gracefully; unknown tables are errors.

set -u

herdr=${HERDR_BIN_PATH:-herdr}
wtpath=${WORKTRUNK_WORKTREE_PATH:?apply-layout.sh runs via run-hook.sh}
root_pane=${WORKTRUNK_PANE_ID:?apply-layout.sh needs the herdr pane id}
workspace=${WORKTRUNK_WORKSPACE_ID:?apply-layout.sh needs the herdr workspace id}
layout_file="${HERDR_PLUGIN_CONFIG_DIR:?apply-layout.sh needs the plugin config dir}/layout.toml"

[[ -f $layout_file ]] || exit 0

fail() { printf '\033[31mlayout.toml:\033[0m %s\n' "$1" >&2; exit 1; }
warn() { printf '\033[33mlayout.toml:\033[0m %s\n' "$1" >&2; }

# Line shapes of the supported TOML subset. \2 of re_kv is a quoted value's
# body, \3 a bare scalar — same convention as worktrunk_config_value.
re_blank='^[[:space:]]*(#.*)?$'
re_kv='^[[:space:]]*([A-Za-z_]+)[[:space:]]*=[[:space:]]*("([^"]*)"|([^[:space:]#"]+))[[:space:]]*(#.*)?$'
re_sec='^[[:space:]]*\[\[layout\]\][[:space:]]*(#.*)?$'
re_pane='^[[:space:]]*\[\[layout\.pane\]\][[:space:]]*(#.*)?$'
re_tab='^[[:space:]]*\[\[layout\.tab\]\][[:space:]]*(#.*)?$'
re_tabpane='^[[:space:]]*\[\[layout\.tab\.pane\]\][[:space:]]*(#.*)?$'
re_table='^[[:space:]]*\['

# Pass 1 — pick the section to apply: the first whose match glob matches the
# primary checkout, where a section without a match key matches every repo.
# A section's own keys sit between its header and its first subsection.
section=-1 chosen=-1 match='' context=top lineno=0
finalize_section() {
  if (( section >= 0 && chosen < 0 )); then
    # shellcheck disable=SC2053  # $match is deliberately a glob
    if [[ -z $match || ${WORKTRUNK_MAIN_PATH:-} == $match ]]; then
      chosen=$section
    fi
  fi
}
while IFS= read -r line || [[ -n $line ]]; do
  lineno=$((lineno + 1))
  if [[ $line =~ $re_blank ]]; then
    continue
  elif [[ $line =~ $re_sec ]]; then
    finalize_section
    section=$((section + 1)); match=''; context=top
  elif [[ $line =~ $re_pane || $line =~ $re_tab || $line =~ $re_tabpane ]]; then
    (( section >= 0 )) || fail "line $lineno: pane/tab tables belong under a [[layout]] section"
    context=sub
  elif [[ $line =~ $re_kv ]]; then
    (( section >= 0 )) || fail "line $lineno: keys belong under a [[layout]] section"
    if [[ $context == top && ${BASH_REMATCH[1]} == match ]]; then
      match=${BASH_REMATCH[3]}${BASH_REMATCH[4]}
    fi
  elif [[ $line =~ $re_table ]]; then
    fail "line $lineno: unsupported table $line"
  else
    fail "line $lineno: unparsable line $line"
  fi
done < "$layout_file"
finalize_section

if (( chosen < 0 )); then
  printf 'worktrunk plugin: no layout.toml section matches %s\n' "${WORKTRUNK_MAIN_PATH:-?}"
  exit 0
fi

# Pass 2 — collect the chosen section into parallel arrays: one entry per pane
# across all tabs (tab 0 = the already-open root tab), plus per-tab labels.
tab_count=0 npanes=0
tab_labels=()
pane_tab=() pane_num=() pane_split=() pane_ratio=() pane_of=() pane_run=() pane_cwd=()
section=-1 tab=0 pane=0 context=top lineno=0
while IFS= read -r line || [[ -n $line ]]; do
  lineno=$((lineno + 1))
  if [[ $line =~ $re_blank ]]; then
    continue
  elif [[ $line =~ $re_sec ]]; then
    section=$((section + 1)); tab=0; pane=0; context=top
    continue
  fi
  (( section == chosen )) || continue
  if [[ $line =~ $re_pane ]]; then
    (( tab == 0 )) || fail "line $lineno: [[layout.pane]] after [[layout.tab]]; use [[layout.tab.pane]]"
    pane=$((pane + 1)); npanes=$((npanes + 1))
    pane_tab[npanes]=0; pane_num[npanes]=$pane
    context=pane
  elif [[ $line =~ $re_tab ]]; then
    tab=$((tab + 1)); tab_count=$tab; pane=0
    context=tab
  elif [[ $line =~ $re_tabpane ]]; then
    (( tab > 0 )) || fail "line $lineno: [[layout.tab.pane]] before any [[layout.tab]]"
    pane=$((pane + 1)); npanes=$((npanes + 1))
    pane_tab[npanes]=$tab; pane_num[npanes]=$pane
    context=pane
  elif [[ $line =~ $re_kv ]]; then
    key=${BASH_REMATCH[1]}
    value=${BASH_REMATCH[3]}${BASH_REMATCH[4]}
    case $context in
      top)
        [[ $key == match ]] || warn "line $lineno: unknown layout key $key (ignored)"
        ;;
      tab)
        if [[ $key == label ]]; then
          tab_labels[tab]=$value
        else
          warn "line $lineno: unknown tab key $key (ignored)"
        fi
        ;;
      pane)
        case $key in
          split)  pane_split[npanes]=$value ;;
          ratio)  pane_ratio[npanes]=$value ;;
          of)     pane_of[npanes]=$value ;;
          run)    pane_run[npanes]=$value ;;
          cwd)    pane_cwd[npanes]=$value ;;
          *)      warn "line $lineno: unknown pane key $key (ignored)" ;;
        esac
        ;;
    esac
  fi
done < "$layout_file"

# Validate every pane before touching herdr, so a bad layout fails cleanly
# instead of leaving a half-built one behind.
for (( j = 1; j <= npanes; j++ )); do
  p=${pane_num[$j]}
  split=${pane_split[$j]:-} of=${pane_of[$j]:-}
  if (( p == 1 )); then
    [[ -z $split ]] || fail "the first pane of a tab is its root pane; it can't have split"
    [[ -z $of ]] || fail "the first pane of a tab is its root pane; it can't have of"
  else
    case $split in
      right|down) ;;
      '') fail "pane $p needs split = \"right\" or \"down\"" ;;
      *)  fail "pane $p: unsupported split $split (use right or down)" ;;
    esac
    if [[ -n $of ]]; then
      case $of in
        *[!0-9]*|'') fail "pane $p: of must be a pane number, got $of" ;;
      esac
      (( of >= 1 && of < p )) || fail "pane $p: of = $of names no earlier pane of this tab"
    fi
  fi
done

abs_cwd() {
  case $1 in
    '') printf '%s\n' "$wtpath" ;;
    /*) printf '%s\n' "$1" ;;
    *)  printf '%s/%s\n' "$wtpath" "$1" ;;
  esac
}

run_in_pane() {
  "$herdr" pane run "$1" "$2" >/dev/null \
    || fail "pane run failed for: $2"
}

create_tab() { # <tab-number> <cwd>
  local args
  args=(tab create --workspace "$workspace" --cwd "$2" --no-focus)
  [[ -n ${tab_labels[$1]:-} ]] && args+=(--label "${tab_labels[$1]}")
  "$herdr" "${args[@]}" | jq -r '.result.root_pane.pane_id // empty'
}

for (( t = 0; t <= tab_count; t++ )); do
  ids=()  # pane ids of this tab, indexed by the tab-local pane number
  tab_created=false
  for (( j = 1; j <= npanes; j++ )); do
    (( pane_tab[j] == t )) || continue
    p=${pane_num[$j]}
    split=${pane_split[$j]:-} ratio=${pane_ratio[$j]:-} of=${pane_of[$j]:-}
    run=${pane_run[$j]:-} cwd=${pane_cwd[$j]:-}
    if (( p == 1 )); then
      if (( t == 0 )); then
        # The root tab's root pane already exists (cwd: the worktree), so a
        # cwd here becomes a cd typed into its shell ahead of any command.
        id=$root_pane
        if [[ -n $cwd ]]; then
          if [[ -n $run ]]; then
            printf -v run 'cd %q && %s' "$(abs_cwd "$cwd")" "$run"
          else
            printf -v run 'cd %q' "$(abs_cwd "$cwd")"
          fi
        fi
      else
        id=$(create_tab "$t" "$(abs_cwd "$cwd")")
        [[ -n $id ]] || fail "tab create failed for tab ${tab_labels[$t]:-$t}"
        tab_created=true
      fi
    else
      target_num=${of:-$((p - 1))}
      target=${ids[$target_num]}
      args=(pane split --pane "$target" --direction "$split" --cwd "$(abs_cwd "$cwd")" --no-focus)
      [[ -n $ratio ]] && args+=(--ratio "$ratio")
      id=$("$herdr" "${args[@]}" | jq -r '.result.pane.pane_id // empty')
      [[ -n $id ]] || fail "pane split failed for pane $p"
    fi
    if [[ -n $run ]]; then
      run_in_pane "$id" "$run"
    fi
    ids[p]=$id
  done
  # A [[layout.tab]] with no panes of its own is still a tab to open.
  if (( t > 0 )) && [[ $tab_created == false ]]; then
    id=$(create_tab "$t" "$wtpath")
    [[ -n $id ]] || fail "tab create failed for tab ${tab_labels[$t]:-$t}"
  fi
done

exit 0
