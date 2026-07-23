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
