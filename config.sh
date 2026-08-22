#!/usr/bin/env bash

# Print the configured worktree presentation mode. Native workspace mode is the
# default; set open_mode = "tab" to keep the original tab-based behavior.
worktrunk_config_value() {
  local key=$1 config_file

  if [[ -z ${HERDR_PLUGIN_CONFIG_DIR:-} ]]; then
    return
  fi

  config_file="$HERDR_PLUGIN_CONFIG_DIR/config.toml"
  if [[ ! -f $config_file ]]; then
    return
  fi

  # Accept both quoted strings (open_mode = "tab") and bare TOML scalars
  # (show_remote_branches = false); \2 is the quoted body, \3 the unquoted token.
  sed -nE \
    "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*(\"([^\"]*)\"|([^[:space:]#\"]+))[[:space:]]*(#.*)?$/\\2\\3/p" \
    "$config_file" | tail -n1
}

# Print "true"/"false" for whether the picker lists remote-tracking branches
# (origin/foo). Disabled by default; set show_remote_branches = true to show them.
worktrunk_show_remote_branches() {
  local value

  value=$(worktrunk_config_value show_remote_branches)

  case "$value" in
    ""|false)
      printf '%s\n' false
      ;;
    true)
      printf '%s\n' true
      ;;
    *)
      printf '\033[33mWarning:\033[0m unsupported show_remote_branches %q; hiding remote branches\n' "$value" >&2
      printf '%s\n' false
      ;;
  esac
}

worktrunk_open_mode() {
  local mode

  mode=$(worktrunk_config_value open_mode)

  case "$mode" in
    ""|workspace)
      printf '%s\n' workspace
      ;;
    tab)
      printf '%s\n' tab
      ;;
    *)
      printf '\033[33mWarning:\033[0m unsupported open_mode %q; using workspace\n' "$mode" >&2
      printf '%s\n' workspace
      ;;
  esac
}

# Print how the picker itself is presented: a split pane below the workspace
# (the default) or a session-modal popup over it. Popups need herdr 0.7.4.
worktrunk_picker_placement() {
  local placement

  placement=$(worktrunk_config_value picker_placement)

  case "$placement" in
    ""|split)
      printf '%s\n' split
      ;;
    popup)
      printf '%s\n' popup
      ;;
    *)
      printf '\033[33mWarning:\033[0m unsupported picker_placement %q; using split\n' "$placement" >&2
      printf '%s\n' split
      ;;
  esac
}

# Set WORKTRUNK_FZF_LAYOUT to the fzf chrome that suits the picker placement. A
# split pane is full-width, so the picker draws its own inset box to read as a
# dialog. A popup already is one, and herdr frames it with the pane title. Both
# are stated outright so a border in the user's FZF_DEFAULT_OPTS can't double up
# on the frame herdr draws.
# shellcheck disable=SC2034  # read by the scripts that source this file
worktrunk_fzf_layout() {
  case $(worktrunk_picker_placement) in
    popup)
      WORKTRUNK_FZF_LAYOUT=(--border=none --margin=0)
      ;;
    *)
      WORKTRUNK_FZF_LAYOUT=(--border=rounded '--margin=20%,30%')
      ;;
  esac
}

# Print the configured popup_width/popup_height, or nothing when unset. herdr
# takes a popup dimension as terminal cells (24) or a percentage of the window
# ("80%"), and falls back to a half-size popup when one is omitted. Drop a
# malformed value rather than passing it on and failing the open.
worktrunk_popup_dimension() {
  local key=$1 value

  value=$(worktrunk_config_value "$key")

  case "$value" in
    "")
      ;;
    *[!0-9%]*|*%?*|%*)
      printf '\033[33mWarning:\033[0m unsupported %s %q; using the default popup size\n' "$key" "$value" >&2
      ;;
    *)
      printf '%s\n' "$value"
      ;;
  esac
}

# Print the extra flags to pass to `wt merge`, one per line, from the
# whitespace-separated merge_flags value. Only flags that leave the merger's own
# contract intact are accepted: -C, --no-remove and --format are the merger's to
# set — it removes the worktree in a second step so it can close herdr's workspace
# afterwards — and an unrecognized flag is dropped rather than handed to wt as a
# broken argv. --yes is excluded on purpose: hook approval is the user's call.
worktrunk_merge_flags() {
  local value flag

  value=$(worktrunk_config_value merge_flags)

  # shellcheck disable=SC2086  # whitespace-separated flags, split on purpose
  for flag in $value; do
    case "$flag" in
      --no-squash|--no-rebase|--no-ff|--no-commit|--no-hooks)
        printf '%s\n' "$flag"
        ;;
      --stage=all|--stage=tracked|--stage=none)
        printf '%s\n' "$flag"
        ;;
      *)
        printf '\033[33mWarning:\033[0m unsupported merge_flags entry %q; ignoring it\n' "$flag" >&2
        ;;
    esac
  done
}
