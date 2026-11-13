# Shared by wt-pick.sh and wt-remove.sh. Splits from terminal.open don't read
# shell rc files, so load mise's PATH (fzf, wt, jq may live there) when present.
command -v mise >/dev/null && eval "$(mise env -s bash)"

config=$(dirname "${BASH_SOURCE[0]}")/config.json

# cfg KEY DEFAULT: the key's value from config.json, DEFAULT when the key or the file is missing.
cfg() {
  local v
  v=$(jq -r --arg k "$1" '.[$k] | select(. != null) | tostring' "$config" 2>/dev/null)
  printf '%s\n' "${v:-$2}"
}

# hold ACTION MESSAGE: wait for a key when hold_on_<ACTION> is true, so output can be read.
hold() {
  [[ $(cfg "hold_on_$1" false) == true ]] || return 0
  printf '\n\033[32m%s\033[0m press any key' "$2"; read -rn1
}

focus_or_new_space() {
  local id
  id=$(herdr-app ls | jq -r --arg d "$1" '.spaces[] | select(.folder == $d) | .id' | head -1)
  if [[ -n $id ]]; then
    herdr-app do space.select --id "$id" >/dev/null
  else
    herdr-app do space.new --name "$2" --folder "$1" >/dev/null
  fi
}

# Splits started with argv may leave a shell behind, so close our own pane.
close_self() {
  local p
  p=$(herdr-app ls | jq -r --arg t "$HC_TERMINAL_ID" '.. | objects | select(.terminal? == $t) | .pane' | head -1)
  [[ -n $p ]] && herdr-app do pane.close --pane "$p" >/dev/null
}
