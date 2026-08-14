#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

stub_dir=$(mktemp -d)
trap 'rm -rf "$stub_dir"' EXIT

config_dir="$stub_dir/config"
mkdir -p "$config_dir"

# Stand in for the herdr binary and echo back the argv open.sh built for it.
cat > "$stub_dir/herdr" <<'EOF'
#!/usr/bin/env bash
printf '%s ' "$@"
EOF
chmod +x "$stub_dir/herdr"

context='{"workspace_cwd":"/tmp/repo","focused_pane_cwd":"/tmp/pane"}'

open_args() {
  HERDR_PLUGIN_ROOT="$repo_root" \
  HERDR_PLUGIN_ID=worktrunk \
  HERDR_BIN_PATH="$stub_dir/herdr" \
  HERDR_PLUGIN_CONFIG_DIR="$config_dir" \
  HERDR_WORKSPACE_ID=w1 \
  HERDR_PLUGIN_CONTEXT_JSON="$context" \
    bash "$repo_root/open.sh" "$1" 2>/dev/null
}

assert_opens_with() {
  local expected=$1 actual=$2
  if [[ $actual != *"$expected "* ]]; then
    printf 'expected %q in open args %q\n' "$expected" "$actual" >&2
    exit 1
  fi
}

refute_opens_with() {
  local unexpected=$1 actual=$2
  if [[ $actual == *"$unexpected"* ]]; then
    printf 'expected no %q in open args %q\n' "$unexpected" "$actual" >&2
    exit 1
  fi
}

# No config at all: the split pane below the workspace, as before popups existed.
args=$(open_args picker-default)
assert_opens_with '--entrypoint picker-default' "$args"
assert_opens_with '--placement split --direction down' "$args"
assert_opens_with '--cwd /tmp/repo' "$args"
assert_opens_with '--focus' "$args"
refute_opens_with popup "$args"
refute_opens_with '--env' "$args"

printf 'open_mode = "tab"\n' > "$config_dir/config.toml"   # unrelated key → still split
args=$(open_args remover)
assert_opens_with '--entrypoint remover' "$args"
assert_opens_with '--placement split --direction down' "$args"

printf 'picker_placement = "popup"\n' > "$config_dir/config.toml"
args=$(open_args picker-current)
assert_opens_with '--entrypoint picker-current' "$args"
assert_opens_with '--placement popup' "$args"
# A popup gets no workspace of its own, so the action has to hand its own down.
assert_opens_with '--env HERDR_WORKSPACE_ID=w1' "$args"
refute_opens_with '--direction' "$args"
refute_opens_with '--width' "$args"
refute_opens_with '--height' "$args"

printf 'picker_placement = "popup"\npopup_width = "80%%"\npopup_height = 24\n' \
  > "$config_dir/config.toml"
args=$(open_args picker-default)
assert_opens_with '--width 80% --height 24' "$args"

printf 'picker_placement = "popup"\npopup_width = "wide"\n' > "$config_dir/config.toml"
args=$(open_args picker-default)
assert_opens_with '--placement popup' "$args"
refute_opens_with '--width' "$args"      # malformed → herdr's default popup size

# Actions invoked from a pane rather than a workspace carry no workspace_cwd.
context='{"workspace_cwd":null,"focused_pane_cwd":"/tmp/pane"}'
args=$(open_args picker-default)
assert_opens_with '--cwd /tmp/pane' "$args"

printf 'open tests passed\n'
