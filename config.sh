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

  sed -nE \
    "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\"([^\"]*)\"[[:space:]]*(#.*)?$/\\1/p" \
    "$config_file" | tail -n1
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
