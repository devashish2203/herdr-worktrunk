#!/usr/bin/env bash

# Print the configured worktree presentation mode. The original tab-based mode
# remains the default so existing installations keep their current behavior.
worktrunk_open_mode() {
  local config_file mode

  if [[ -z ${HERDR_PLUGIN_CONFIG_DIR:-} ]]; then
    printf '%s\n' tab
    return
  fi

  config_file="$HERDR_PLUGIN_CONFIG_DIR/config.toml"
  if [[ ! -f $config_file ]]; then
    printf '%s\n' tab
    return
  fi

  mode=$(sed -nE \
    's/^[[:space:]]*open_mode[[:space:]]*=[[:space:]]*"([^"]+)"[[:space:]]*(#.*)?$/\1/p' \
    "$config_file" | tail -n1)

  case "$mode" in
    ""|tab)
      printf '%s\n' tab
      ;;
    workspace)
      printf '%s\n' workspace
      ;;
    *)
      printf '\033[33mWarning:\033[0m unsupported open_mode %q; using tab\n' "$mode" >&2
      printf '%s\n' tab
      ;;
  esac
}
