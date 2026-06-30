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

Two workspace actions:

- **Worktree: switch / create** — opens an fzf picker over your worktree
  branches. Press `Enter` on a match to switch to it, or type a new name and
  press `Enter` to create it. Worktrunk's lifecycle hooks run in either
  presentation mode, and the checkout opens as a tab or a native worktree
  workspace according to plugin configuration.
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

The config file is read each time the picker runs, so changing the mode does not
require reinstalling or reloading the plugin.

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

Trigger the actions from herdr's workspace action menu:

- **Worktree: switch / create**
- **Worktree: remove**

Each opens a split picker pane rooted at your current repo.

## Keybindings

To drive the plugin from the keyboard, add `[[keys.command]]` entries to
`~/.config/herdr/config.toml` with `type = "plugin_action"`. The `command` is the
plugin's action id qualified with the plugin id (`worktrunk.<action>`; run
`herdr plugin action list` to see the ids):

```toml
# Override herdr's built-in "new worktree" key (prefix+shift+g) with worktrunk's
# switch/create picker:
[[keys.command]]
key = "prefix+shift+g"
type = "plugin_action"
command = "worktrunk.open"
description = "Worktree: switch / create"

[[keys.command]]
key = "prefix+shift+d"
type = "plugin_action"
command = "worktrunk.remove"
description = "Worktree: remove"
```

**Recommended:** override herdr's built-in worktree management with these. herdr
binds `prefix+shift+g` to "new worktree" by default, and a custom keybinding takes
precedence over the built-in on the same key — so mapping `worktrunk.open` to
`prefix+shift+g` replaces it with worktrunk's switch/create picker, hooks included.
Pick a matching key (e.g. `prefix+shift+d`) for `worktrunk.remove` to round out the
workflow.

Reload the config after editing it:

```bash
herdr server reload-config
```

## Development

The plugin is a manifest plus small bash scripts:

- `herdr-plugin.toml` — actions and panes
- `config.sh` — worktree presentation configuration
- `picker.sh` — the switch / create picker
- `remove.sh` — the remove picker + orphaned-pane cleanup
- `tests/config_test.sh` — configuration parser checks

herdr caches the manifest when a plugin is linked, so after editing
`herdr-plugin.toml` you must relink for changes to take effect:

```bash
herdr plugin unlink worktrunk && herdr plugin link "$PWD"
```

Edits to the bash scripts are picked up on the next run — no relink needed.

## License

[MIT](LICENSE.md) © Devashish Chandra
