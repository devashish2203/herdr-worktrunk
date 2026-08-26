# Worktrunk

A [herdr](https://herdr.dev) plugin for switching, creating, and removing git
worktrees through [worktrunk](https://github.com/max-sixty/worktrunk). Pick (or
type) a branch in an fzf picker and open the worktree as a herdr tab or a native
worktree workspace — with worktrunk's hooks running along the way.

## Why this plugin

herdr already ships with its own worktree management (`herdr worktree
create/open/remove/list`), and it works fine. But worktrunk is a dedicated
worktree manager that does more — most importantly, **lifecycle hooks**: run
setup when a worktree is created (install deps, copy `.env` files, bootstrap
services) and teardown when it's removed, with template variables like
`{{ branch }}` and `{{ worktree_path }}`. herdr's built-in worktree commands
have no hook system.

Rather than reimplement hooks inside herdr, this plugin wires worktrunk's `wt`
into herdr: you get worktrunk's hook-driven workflow (plus its niceties — base
branch selection, PR shortcuts, live preview) while choosing whether the
resulting worktree opens as a tab or as a native linked-worktree workspace.

## What it does

Four workspace actions:

- **Worktree: switch / create from default branch** — opens an fzf picker over
  your existing worktrees and local branches without worktrees (remote-tracking
  branches too, if enabled — see [Remote branches in the picker](#remote-branches-in-the-picker)).
  Press `Enter` on a match to switch to it, or type a new name and press `Enter`
  to create it from worktrunk's default base branch. When the name you want
  fuzzy-matches an existing branch (e.g. you want `pgx` but `pgx-bump` exists),
  press `Alt+Enter` to force the typed name instead of the highlighted match.

- **Worktree: switch / create from current branch** — the same picker, but typed
  new branch names are created with `wt switch --create --base @`, i.e. from the
  currently checked-out branch/worktree.

- **Worktree: switch / create from local or remote branches** — the default-base
  picker with remote-tracking branches included for this invocation.

The pickers support [worktrunk syntax for PR/MR along with other shortcuts](https://worktrunk.dev/switch/#shortcuts).
Worktrunk's lifecycle hooks run in either presentation mode, and the checkout
opens as a tab or a native worktree workspace according to plugin configuration.

- **Worktree: remove** — opens an fzf picker over removable worktrees
  (everything except the main checkout). Pick one; worktrunk prompts for
  confirmation and gates unmerged branches / untracked files itself, then
  removes it. The native workspace or any legacy tab panes associated with the
  deleted worktree are closed automatically.

## Worktree presentation

By default the plugin organizes worktrees the same way as herdr's built-in
worktree support: each checkout becomes a nested worktree workspace in the
sidebar. To restore the original tab-based behavior, set `open_mode` to `"tab"`
in the plugin's managed configuration directory:

```bash
config_dir=$(herdr plugin config-dir worktrunk)
mkdir -p "$config_dir"
${EDITOR:-vi} "$config_dir/config.toml"
```

```toml
open_mode = "tab"
```

Supported values:

- `open_mode = "workspace"` — let Worktrunk create or switch the checkout and
  run its hooks, then register that checkout with `herdr worktree open`. Herdr
  displays it as a nested worktree workspace in the sidebar. This is the default.
- `open_mode = "tab"` — open a new tab in the current workspace and run `wt`
  there. This preserves the original plugin behavior.

The config file is read each time the picker runs, so changing the mode does
not require reinstalling or reloading the plugin.

## Remote branches in the picker

By default the picker lists only your worktrees and local branches. To also
offer remote-tracking branches (e.g. `origin/foo`; run `git fetch` yourself to
refresh these), set `show_remote_branches` to `true` in the same `config.toml`:

```toml
show_remote_branches = true
```

Local branches without worktrees always appear regardless of this setting.

## Post-create hook

To run setup whenever a pick actually **creates** a worktree — install
dependencies, copy `.env` files, bootstrap services — drop a `post-create.sh`
script into the plugin's managed config directory (alongside `config.toml`):

```bash
config_dir=$(herdr plugin config-dir worktrunk)
mkdir -p "$config_dir"
${EDITOR:-vi} "$config_dir/post-create.sh"
```

The script runs inside the new worktree — executed directly when it's
executable (honoring its shebang), otherwise with bash — with these variables
exported:

- `WORKTRUNK_WORKTREE_PATH` — the new worktree (also the working directory)
- `WORKTRUNK_BRANCH` — its checked-out branch (empty on detached HEAD)
- `WORKTRUNK_MAIN_PATH` — the repository's primary checkout

One script serves every repository, so filter per project inside it:

```bash
#!/usr/bin/env bash
set -euo pipefail

case $WORKTRUNK_MAIN_PATH in
  */my-app)
    cp "$WORKTRUNK_MAIN_PATH/.env" .
    npm install
    ;;
  */my-service)
    cargo fetch
    ;;
esac
```

The hook runs only when the switch created a checkout that didn't exist
before — picking an existing worktree never re-runs it, while creating a new
branch, checking out a branch without a worktree, or resolving a `pr:N`
shortcut to a fresh checkout all do. It works in both presentation modes: in
workspace mode its output shows in the picker pane before the workspace opens
(a failure pauses there but still opens the worktree); in tab mode it runs in
the new tab after the switch, so its output stays visible.

This is a plugin-level hook configured once in herdr, independent of any
repository. For per-repository setup shared with plain `wt` usage outside
herdr, prefer [worktrunk's own lifecycle hooks](https://worktrunk.dev/hook/) —
both run when a worktree is created.

## Post-open layout: pre-built tabs and panes

To shape the workspace a freshly created worktree opens into — split panes,
start the dev server, launch a coding agent, so the tab is ready for feature
work the moment it appears — drop a declarative `layout.toml` into the same
managed config directory:

```bash
config_dir=$(herdr plugin config-dir worktrunk)
mkdir -p "$config_dir"
${EDITOR:-vi} "$config_dir/layout.toml"
```

Like the post-create hook, a layout is applied only when the switch actually
**created** the worktree, and one file serves every repository — sections are
picked per project with a `match` glob against the primary checkout path. For
example: agent on the left, dev server and a spare shell stacked on the right,
plus a second tab for tests:

```toml
[[layout]]
match = "*/my-app"        # first matching section wins; omit match → every repo

[[layout.pane]]           # first pane = the tab's root pane (cwd: the worktree)
run = "claude"

[[layout.pane]]           # every further pane splits an earlier one
split = "right"           # right | down
ratio = 0.4               # optional; herdr's default when omitted
run = "npm run dev"

[[layout.pane]]
split = "down"            # splits the previous pane by default …
of = 2                    # … or name the pane to split (1-based, this tab)
run = "npm test -- --watch"
cwd = "packages/web"      # optional; relative to the worktree

[[layout.tab]]            # extra tabs after the main one
label = "scratch"

[[layout.tab.pane]]       # panes of an extra tab, same rules as above
run = "git status"

[[layout]]                # fallback for every other repo

[[layout.pane]]
run = "claude"
```

Per pane: `split` (required from the second pane of a tab), `ratio`, `of`,
`run` (a command typed into the pane's shell), and `cwd`. Values are quoted
strings or bare scalars, one per line — inline tables, arrays, and multi-line
values aren't supported. A `cwd` on the main tab's root pane becomes a `cd`
typed into its existing shell. The file is validated before anything is
applied, so a bad layout fails cleanly instead of leaving half a layout.

In workspace mode the layout lands in the new worktree workspace's root tab;
in tab mode it lands in the new tab in the current workspace (extra
`[[layout.tab]]` tabs open in that workspace too, after the post-create hook,
whose failure doesn't skip the layout). Picking an existing worktree
re-focuses it without re-applying, so layouts are never duplicated onto a
workspace that already has one.

### Post-open hook script: full control

When the declarative form isn't enough, drop a `post-open.sh` script into the
config directory instead — it **replaces** `layout.toml` (the script takes
full control) and follows the same rules as the post-create hook, but runs
*after* the worktree's workspace or tab is open, with the herdr ids of the
freshly opened surface exported on top of the post-create variables:

- `WORKTRUNK_WORKSPACE_ID` — the workspace the worktree opened into
- `WORKTRUNK_TAB_ID` — its tab
- `WORKTRUNK_PANE_ID` — the tab's root pane (cwd is the worktree)
- `HERDR_BIN_PATH` — the herdr binary to drive the layout with

Build the layout with `herdr pane split` / `herdr pane run` / `herdr tab
create`, branching per project on `WORKTRUNK_MAIN_PATH`:

```bash
#!/usr/bin/env bash
set -euo pipefail
herdr=${HERDR_BIN_PATH:-herdr}

case $WORKTRUNK_MAIN_PATH in
  */my-app)
    # Right column (40%): the dev server.
    right=$("$herdr" pane split --pane "$WORKTRUNK_PANE_ID" --direction right \
      --ratio 0.4 --cwd "$WORKTRUNK_WORKTREE_PATH" --no-focus \
      | jq -r '.result.pane.pane_id')
    "$herdr" pane run "$right" 'npm run dev'
    "$herdr" pane run "$WORKTRUNK_PANE_ID" 'claude'
    ;;
esac
```

## Picker presentation

The picker opens in a split pane below the workspace. To open it as a
session-modal popup over the current layout instead, set `picker_placement` in
the same `config.toml`:

```toml
picker_placement = "popup"
```

Supported values:

- `picker_placement = "split"` — a pane split below the workspace, closed when
  the picker exits. This is the default.
- `picker_placement = "popup"` — a floating terminal centered over the tab,
  leaving the tiled layout alone. Needs herdr ≥ 0.7.4.

A popup is half the window by default. Size it with `popup_width` and
`popup_height`, either as terminal cells or as a percentage of the window:

```toml
picker_placement = "popup"
popup_width = "70%"
popup_height = 24
```

In a split the picker draws its own rounded border and inset margin, which a
popup does not need, so the list fills the popup frame herdr already draws.

## Requirements

- [**herdr**](https://herdr.dev) ≥ 0.7.0
- [**worktrunk**](https://github.com/max-sixty/worktrunk) ≥ 0.60.0 — the `wt` CLI on your `PATH`
- **fzf** — the interactive picker
- **jq** — JSON parsing
- **bash** — the scripts run with `/bin/bash`

Platforms: macOS and Linux.

## Installation

From the herdr CLI:

```bash
herdr plugin install devashish2203/herdr-worktrunk
```

Or, for local development, clone and link:

```bash
git clone https://github.com/devashish2203/herdr-worktrunk
herdr plugin link /path/to/herdr-worktrunk
```

## Usage

### Create/Switch a worktree from the default branch

```
herdr plugin action invoke open --plugin worktrunk
```

### Create/Switch a worktree from the current branch

```
herdr plugin action invoke open-current --plugin worktrunk
```

### Create/Switch a worktree from local or remote branches

```
herdr plugin action invoke open-with-remotes --plugin worktrunk
```

### Remove Worktree

```
herdr plugin action invoke remove --plugin worktrunk
```

## Keybindings

To drive the plugin from the keyboard, add `[[keys.command]]` entries to
`~/.config/herdr/config.toml` with `type = "plugin_action"`. The `command` is the
plugin's action id qualified with the plugin id (`worktrunk.<action>`; run
`herdr plugin action list` to see the ids):

```toml
# Override herdr's built-in "new worktree" key (prefix+shift+g) with worktrunk's
# default-branch switch/create picker:
[[keys.command]]
key = "prefix+shift+g"
type = "plugin_action"
command = "worktrunk.open"
description = "Worktree: switch / create from default branch"

# Optional: bind current-branch creation separately.
[[keys.command]]
key = "prefix+shift+c"
type = "plugin_action"
command = "worktrunk.open-current"
description = "Worktree: switch / create from current branch"

# Optional: include remote-tracking branches for this picker.
[[keys.command]]
key = "prefix+shift+r"
type = "plugin_action"
command = "worktrunk.open-with-remotes"
description = "Worktree: switch / create from local or remote branches"

[[keys.command]]
key = "prefix+shift+d"
type = "plugin_action"
command = "worktrunk.remove"
description = "Worktree: remove"
```

**Recommended:** override herdr's built-in worktree management with these. herdr
binds `prefix+shift+g` to "new worktree" by default, and a custom keybinding takes
precedence over the built-in on the same key — so mapping `worktrunk.open`
to `prefix+shift+g` replaces it with worktrunk's switch/create picker, hooks
included. Pick matching keys for `worktrunk.open-current`,
`worktrunk.open-with-remotes`, and `worktrunk.remove`
to round out the workflow.

Reload the config after editing it:

```bash
herdr server reload-config
```

## Development

The plugin is a manifest plus small bash scripts:

- `herdr-plugin.toml` — actions and panes
- `config.sh` — worktree and picker presentation configuration
- `helpers.sh` — shared shell helpers (e.g. worktrunk shortcut detection)
- `open.sh` — the action entrypoint that opens a picker in its configured placement
- `picker.sh` — the switch / create picker
- `remove.sh` — the remove picker + orphaned-pane cleanup
- `run-hook.sh` — runs a user hook (post-create / post-open) in a freshly created worktree
- `apply-layout.sh` — applies the declarative layout.toml as the built-in post-open hook
- `tests/config_test.sh` — configuration parser checks
- `tests/helpers_test.sh` — helper function checks
- `tests/open_test.sh` — picker placement / open argument checks
- `tests/layout_test.sh` — layout.toml parsing / application checks
- `tests/run_hook_test.sh` — hook gating / env checks

herdr caches the manifest when a plugin is linked, so after editing
`herdr-plugin.toml` you must relink for changes to take effect:

```bash
herdr plugin unlink worktrunk && herdr plugin link "$PWD"
```

Edits to the bash scripts are picked up on the next run — no relink needed.

## License

[MIT](LICENSE.md) © Devashish Chandra
