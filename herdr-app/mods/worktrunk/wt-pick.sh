# Switch to or create a worktree. Arg: "default" (new branches from the default
# branch) or "current" (new branches from the current branch, wt --base @).
source "$(dirname "$0")/lib.sh"
trap close_self EXIT

base=() label="default branch"
if [[ ${1:-} == current ]]; then
  base=(--base @)
  if b=$(git branch --show-current 2>/dev/null) && [[ -n $b ]]; then
    label="current branch ($b)"
  elif c=$(git rev-parse --short HEAD 2>/dev/null); then
    label="current HEAD ($c)"
  else
    label="current branch"
  fi
fi

refs=(refs/heads)
[[ $(cfg show_remote_branches false) == true ]] && refs+=(refs/remotes)

if command -v fzf >/dev/null; then
  # Refs first (instant), then `wt list` (slow on many worktrees); dedupe while streaming.
  # Drop origin/HEAD by its full refname, since its short name is bare "origin".
  choice=$(
    { git for-each-ref --format='%(refname) %(refname:short)' "${refs[@]}" 2>/dev/null \
        | awk '$1 !~ /\/HEAD$/ {print $2}'
      wt list --format=json 2>/dev/null | jq -r '.items[] | select(.branch != null) | .branch'
    } | awk '!seen[$0]++ { print; fflush() }' \
      | fzf --print-query --reverse --info=inline --border=rounded --prompt='worktree ❯ ' \
            --bind=alt-enter:print-query \
            --header="↵ match → switch · new name + ↵ → create from $label · alt-↵ → force typed name · esc → cancel"
  )
  [[ $? -gt 1 ]] && exit 0
  name=${choice##*$'\n'}
else
  read -rp "Branch (existing → switch · new → create from $label): " name
fi
[[ -z $name ]] && exit 0

exists() { git show-ref --quiet --verify "refs/heads/$1" || git show-ref --quiet --verify "refs/remotes/$1"; }
shortcut() { [[ $1 == '^' || $1 == '-' || $1 == *:* ]]; }

# Turn free text ("Fix Login Bug") into a branch name; existing refs and wt shortcuts stay as typed.
if [[ $(cfg slugify_new_branches false) == true ]] && ! shortcut "$name" && ! exists "$name"; then
  slug=$(printf '%s' "$name" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C sed -E '
    s#[^a-z0-9._/]+#-#g
    s#-*/+-*#/#g
    s#\.{2,}#.#g
    s#/\.+#/#g
    s#^[-/.]+##
    s#[-/.]+$##')
  if [[ -z $slug ]] || ! git check-ref-format "refs/heads/$slug"; then
    printf '\033[31mno valid branch name in: %s\033[0m press any key' "$name"; read -rn1; exit 1
  fi
  name=$slug
fi

if shortcut "$name" || exists "$name"; then
  args=(switch "$name")
else
  args=(switch --create "$name" "${base[@]}")
fi

if ! result=$(wt "${args[@]}" --no-cd --format=json); then
  printf '\n\033[31mwt switch failed (see above).\033[0m press any key'; read -rn1; exit 1
fi
path=$(jq -r '.path // empty' <<<"$result")
branch=$(jq -r '.branch // empty' <<<"$result")
[[ -z $path ]] && path=$(wt list --format=json | jq -r --arg b "$name" '.items[] | select(.branch == $b) | .worktree.path // empty' | head -1)
[[ -z $path ]] && { echo "worktrunk returned no path for $name"; sleep 2; exit 1; }

if [[ $(jq -r '.action // empty' <<<"$result") == created ]]; then
  hold create "created worktree ${branch:-$name}."
else
  hold switch "switched to worktree ${branch:-$name}."
fi

case $(cfg open_mode space) in
  tab) herdr-app do tab.new --name "${branch:-$name}" --folder "$path" >/dev/null ;;
  space) focus_or_new_space "$path" "${branch:-$name}" ;;
  *) printf '\033[33munsupported open_mode in %s; using space\033[0m\n' "$config"; sleep 1
     focus_or_new_space "$path" "${branch:-$name}" ;;
esac
