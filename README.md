# Grace Window (jam.grace-window)

![](preview.png)

An Omarchy shell plugin to reopen "closed" windows with <kbd>SUPER</kbd>+<kbd>SHIFT</kbd>+<kbd>W</kbd>. It rebinds <kbd>SUPER</kbd>+<kbd>W</kbd> to move the focused window silently to **workspace 10**
with a one-minute reopen grace period:

- <kbd>SUPER</kbd>+<kbd>W</kbd>: close window gracefully: silently move the selected window to workspace 10 and start
  the 60s grace timer. Focus stays where it was.
- <kbd>SUPER</kbd>+<kbd>SHIFT</kbd>+<kbd>W</kbd>: reopen the most recently "closed" window: bring it back to the current workspace, focus it, and cancel its auto-close.
- <kbd>SUPER</kbd>+<kbd>SHIFT</kbd>+<kbd>CTRL</kbd>+<kbd>W</kbd>: closes the window for real, immediately.
- **Grace expiry**: if a hidden window is never reopened, it is closed for real when the timer runs out.

The feature is a *service* plugin: the state lives in the long-lived
`omarchy-shell` process, and the keybindings drive it over Quickshell IPC
(`omarchy-shell grace-window hide` / `reopen`), so there is no standalone
background script.

## Files

| File | Purpose |
|------|---------|
| `manifest.json` | Omarchy plugin manifest (schema v1, kind `service`) |
| `Service.qml` | The service: IPC handlers, hyprctl dispatch queue, grace sweep, auto-wires the keybindings on start |
| `hypr/bindings.lua` | The keybindings, wrapped in the managed block the service copies on start |
| `uninstall.sh` | Reverts the plugin and its managed bindings, preserving pre-existing bindings |

## Install

```bash
omarchy plugin add https://github.com/Jan-Berberich/omarchy-grace-window.git --enable
```

When the service starts it appends the managed
keybinding block from its own `hypr/bindings.lua` to
`~/.config/hypr/bindings.lua` and reloads Hyprland, but only if the block is
not already present, so it is safe across shell restarts and plugin
hot-reloads. Every line it adds lives inside a `-- BEGIN Grace Window ...`
/ `-- END Grace Window ...` managed block pair; nothing outside that block is
ever modified.

## Uninstall

```bash
~/.config/omarchy/plugins/jam.grace-window/uninstall.sh
```

`uninstall.sh` removes the plugin, then strips exactly the plugin's managed
binding block from `~/.config/hypr/bindings.lua`. Every binding that was
already present before the plugin was installed is preserved unchanged. If
the managed block cannot be located intact, the uninstaller fails closed and
prints manual instructions.

**Important:** Do not use `omarchy plugin remove` for uninstall,
otherwise you need to remove the plugins managed block from
`~/.config/hypr/bindings.lua` manually.

## Usage without the keybindings

Talk to the service directly from Hyprland bindings (or a terminal):

```bash
omarchy-shell grace-window hide       # hide focused window, start grace
omarchy-shell grace-window reopen     # bring the newest hidden window back
omarchy-shell grace-window status     # idle / pending Ns
omarchy-shell grace-window cancel     # forget pendings without closing
```

## Configuration

The grace period is hard-coded to 60 seconds in `Service.qml` (`graceMs`).
Edit it there, or change the keybindings in `hypr/bindings.lua`.

## Notes

- Multiple windows can be hidden in sequence; each one keeps its own grace
  timer, and `reopen` restores the most recent.
- Auto-close uses Hyprland's Lua dispatcher syntax
  (`hl.dsp.window.close({ window = "address:..." })`), which needs Hyprland
  >= 0.55 (Omarchy 4.x ships 0.56).
- Validated with `omarchy plugin validate`.
