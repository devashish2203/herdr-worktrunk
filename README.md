# Worktrunk

A [herdr](https://herdr.dev) plugin for switching, creating, and removing git
worktrees through [worktrunk](https://github.com/max-sixty/worktrunk). Pick (or
type) a branch in an fzf picker and the worktree opens as a herdr tab — with
worktrunk's hooks running along the way.

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
branch selection, PR shortcuts, live preview) while the resulting worktree opens
as a herdr tab in your current workspace.

## What it does

Two workspace actions:

- **Worktree: switch / create** — opens an fzf picker over your worktree
  branches. Press `Enter` on a match to switch to it, or type a new name and
  press `Enter` to create it. The worktree opens in a new herdr tab where `wt`
  runs, so worktrunk's create hooks execute in the pane you land in.
- **Worktree: remove** — opens an fzf picker over removable worktrees
  (everything except the main checkout). Pick one; worktrunk prompts for
  confirmation and gates unmerged branches / untracked files itself, then
  removes it. Any herdr panes left sitting inside the deleted worktree are
  closed automatically.

## Requirements

- [**herdr**](https://herdr.dev) ≥ 0.7.0
- [**worktrunk**](https://github.com/max-sixty/worktrunk) — the `wt` CLI on your `PATH`
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

The plugin is just a manifest plus two bash scripts:

- `herdr-plugin.toml` — actions and panes
- `picker.sh` — the switch / create picker
- `remove.sh` — the remove picker + orphaned-pane cleanup

herdr caches the manifest when a plugin is linked, so after editing
`herdr-plugin.toml` you must relink for changes to take effect:

```bash
herdr plugin unlink worktrunk && herdr plugin link "$PWD"
```

Edits to `picker.sh` / `remove.sh` are picked up on the next run — no relink
needed.

## License

[MIT](LICENSE.md) © Devashish Chandra
