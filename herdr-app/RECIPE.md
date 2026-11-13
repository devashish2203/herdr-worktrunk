# Worktrunk

Switch, create and remove git worktrees with [worktrunk](https://github.com/max-sixty/worktrunk)
(`wt`) from the keyboard. A key opens an fzf picker in a split below the focused
pane; pick a branch or type a new name, worktrunk makes the checkout and runs its
hooks, and the worktree opens as its own space (or as a tab in the current space).
Another key removes a worktree and closes the spaces and panes that were in it.

![Worktrunk](preview.png)

## What you see

- **Picker split**: a terminal pane opened below the focused pane
  (`terminal.open`, `place: "down"`) running fzf with a rounded border, the
  prompt `worktree ❯ ` (or `remove worktree ❯ `), the list at the top
  (`--reverse`) and a one-line header with the keys. Nothing else: the mod
  draws no UI of its own.
- **Worktrunk output**: after a pick, `wt`'s own progress lines and hook output
  print in the same split. On failure, a red `wt switch failed (see above).` /
  `wt remove failed (see above).` and `press any key`.
- **Result**: a space named after the branch whose folder is the worktree, or
  (with `open_mode: "tab"`) a new tab with that name and folder in the current
  space. The split closes itself.

## How it behaves

- `cmd-alt-g`: picker over local branches and worktree branches (plus
  remote-tracking branches with `show_remote_branches`). `↵` on a match
  switches to it; a typed new name + `↵` creates it from worktrunk's default
  branch; `alt-↵` forces the typed name even when it fuzzy-matches a branch;
  `esc` cancels. Worktrunk shortcuts (`^`, `-`, `pr:N`, `mr:N`, URLs) pass
  through to `wt switch` as typed.
- `cmd-alt-f`: the same picker, but new branches are created from the current
  branch (`wt switch --create <name> --base @`); the header names it.
- `cmd-alt-r`: picker over worktrees other than the main one. `↵` runs
  `wt remove --foreground`, which asks for confirmation and refuses unmerged
  work itself. On success it closes every pane whose folder is in the removed
  worktree and every space whose folder is, without asking.
- Switching to a worktree that already has a space selects that space instead
  of making a second one.
- Without fzf, the pickers fall back to a plain `read` prompt (remove needs fzf).

### Config: `mods/worktrunk/config.json`

Read with jq on every run; a missing key or file means its default.

| Key | Default | Effect |
|---|---|---|
| `show_remote_branches` | `false` | Also list `refs/remotes` (minus `origin/HEAD`). Run `git fetch` yourself to refresh them. |
| `slugify_new_branches` | `false` | Turn a typed new name like `Fix Login Bug` into `fix-login-bug`. Existing branches and shortcuts are never changed. |
| `open_mode` | `"space"` | `"space"`: own space (selected if one already has that folder). `"tab"`: new tab in the current space, folder = worktree. Anything else warns and uses `"space"`. |
| `hold_on_create` | `false` | After `wt switch` created a worktree, wait for a key before the split closes. |
| `hold_on_switch` | `false` | Same, after switching to an existing worktree. |
| `hold_on_remove` | `false` | Same, after `wt remove` succeeded. |

A failure always waits for a key.

### Dropped from the old herdr plugin

- `picker_placement`, `popup_width`, `popup_height`: a popup picker would need a
  JS floating window; where the split opens is the `place` in `keys.json`.
- `hold_on_success` (the catch-all hold): use the three `hold_on_*` keys.
- `merge_flags` and the merge actions: no merge key is ported yet.
- The "with remotes" action: set `show_remote_branches` instead.
- `worktrunk_bin` and the PowerShell scripts: Windows isn't covered.
- Tab mode no longer types `wt switch` into the new tab's shell: the picker runs
  `wt` itself and opens the tab in the worktree folder, so no shell
  integration is needed.

## Built from

- `mods/worktrunk/main.js`: a no-op `View` (a mod must have one);
  `mod.json` is `{"place":"none"}`, so it never docks.
- `mods/worktrunk/lib.sh`: loads mise's environment, `cfg KEY DEFAULT` (jq on
  `config.json`), `hold`, `focus_or_new_space`, `close_self`.
- `mods/worktrunk/wt-pick.sh default|current` and `mods/worktrunk/wt-remove.sh`.
- `keys.json`: three `global` keys, each
  `{"command":"terminal.open","args":{"argv":["bash","-c","exec bash ~/.config/herdr-app/mods/worktrunk/<script> <args>"],"place":"down"}}`.
- Commands: `space.select {id}`, `space.new {name, folder}`, `tab.new {name, folder}`,
  `pane.close {pane}`, `space.close {id, confirmed: true}`, all through `herdr-app do`.
- **Runs programs**: `wt`, `git`, `jq`, `fzf`, `herdr-app` (`ls`, `do`), `hc`
  (`ls --json`) and `mise` when present. It reads only its own `config.json`
  and the git repo of the focused pane; no network beyond what `wt` and its
  hooks do.
- **Requires**: [worktrunk](https://github.com/max-sixty/worktrunk) >= 0.74,
  fzf, jq, bash.

## Watch out

- Splits from `terminal.open` don't load shell rc files, so tools installed via
  mise aren't on PATH; `lib.sh` runs `mise env -s bash` when mise exists.
  Without it fzf may be missing and the split closes at once.
- worktrunk v0.74 `wt list --format=json` is `{items:[{branch, worktree:{path, main}}]}`;
  `wt switch --format=json` has top-level `.path`, `.branch`, `.action`
  (`created` / `existing`). Older worktrunk shapes aren't handled.
- Splits started with argv may leave a shell behind; the scripts close their own
  pane on exit: `HC_TERMINAL_ID` to the pane found in `herdr-app ls`.
- Pane folders come from `hc ls --json` (`.terminals[].cwd`), not `herdr-app ls`.
- Paths in `keys.json` go through `bash -c` so `~` expands for any user. If the
  mod is renamed on install, change the `mods/worktrunk/` paths there.
- Don't bind `cmd-alt-d`: macOS takes it for Dock hiding.
- The picker works in the focused pane's folder; outside a git repo the list is
  empty and `wt` fails with its own message.

## Done when

- `herdr-app check ~/.config/herdr-app/mods/worktrunk` passes.
- In a repo, `cmd-alt-g`, typing a new name and `↵` creates the worktree, runs
  its hooks in the split, and opens a space named after the branch; the split
  closes.
- `cmd-alt-g` again and picking that branch selects the same space, no new one.
- `cmd-alt-f` shows `create from current branch (<branch>)` in the header.
- With `"open_mode": "tab"`, a pick opens a new tab in the current space whose
  terminal is in the worktree.
- With `"show_remote_branches": true`, `origin/...` branches are listed and
  `origin/HEAD` / `origin` is not.
- `cmd-alt-r`, picking a worktree and confirming removes it and closes its space.
- With a `hold_on_*` key true, the split waits for a key after that action.
