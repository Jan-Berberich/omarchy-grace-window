# Grace Window (jam.grace-window)

![](preview.png)

An Omarchy shell plugin to reopen a recently closed window,
including its content with
<kbd>SUPER</kbd>+<kbd>SHIFT</kbd>+<kbd>W</kbd>. The plugin rebinds
<kbd>SUPER</kbd>+<kbd>W</kbd> to move the focused window silently to
**workspace 10** with a one-minute reopen grace period until it gets
closed for real:

- <kbd>SUPER</kbd>+<kbd>W</kbd>: close window gracefully: silently move the
  focused window to **workspace 10** and start the one-minute reopen grace
  period. Active workspace stays where it was.
- <kbd>SUPER</kbd>+<kbd>SHIFT</kbd>+<kbd>W</kbd>: reopen closed window:
  bring it back, focus it, and cancel its grace period. If the focused window
  is itself a gracefully closed window, that one is reopened instead.
  Otherwise reopens the most recent gracefully closed window.
- <kbd>SUPER</kbd>+<kbd>SHIFT</kbd>+<kbd>CTRL</kbd>+<kbd>W</kbd>: close window,
  for real, immediately. It can not be reopened again.
- **Grace period**: time to reopen gracefully closed window before it gets
  closed for real. Pauses if gracefully closed window is focused.
- **Grace look**: a gracefully closed window gets a distinctive look so you
  can tell it will close soon: a 10% lower opacity, cut corners and always in 
  *tiling* mode.
- **Grace groups**: the behaviour is as you would expect in omarchy:
  Only the focused window of a tabbed group get gracefully closed, the rest of
  the group stays in place. On reopen the window (if in tiling mode) joins the
  group that currently has focus.

The Plugin also can be used nicely to reoder windows on your workspace, as
they will reopen predictably to the right or bottom of the focused window,
depending on its aspect ratio.

The feature is a *service* plugin: the state lives in the long-lived
`omarchy-shell` process, and the keybindings drive it over Quickshell IPC
(`omarchy-shell grace-window hide` / `reopen`), so there is no standalone
background script.

## Files

| File | Purpose |
|------|---------|
| `manifest.json` | Omarchy plugin manifest (schema v1, kind `service`) |
| `Service.qml` | The service: IPC handlers, hyprctl dispatch queue, grace sweep, auto-wires the keybindings on start and unwires them on teardown |
| `hypr/bindings.lua` | The keybindings, wrapped in the managed block the service copies on start |

## Install

```bash
omarchy plugin add https://github.com/Jan-Berberich/omarchy-grace-window.git --enable
```

When the service starts it appends the managed
keybinding block from its own `hypr/bindings.lua` to
`~/.config/hypr/bindings.lua` and reloads Hyprland, but only if the block is
not already present, so it is safe across shell restarts and plugin
hot-reloads. Every line it adds lives inside a `-- BEGIN Grace Window ...`
/ `-- END Grace Window ...` managed block pair. Nothing outside that block is
ever modified.

## Uninstall

```bash
omarchy plugin remove jam.grace-window
```

Removing the plugin shuts down its service, and the service first strips
exactly the plugin's managed binding block from
`~/.config/hypr/bindings.lua` and reloads Hyprland. Every binding that was
already present before the plugin was installed is preserved unchanged. If
the managed block cannot be located intact, the service fails closed and
leaves the file untouched.

## Usage without the keybindings

Talk to the service directly from Hyprland bindings (or a terminal):

```bash
omarchy-shell grace-window hide       # hide focused window, start grace
omarchy-shell grace-window reopen     # bring the newest hidden window back
omarchy-shell grace-window status     # idle / pending Ns
omarchy-shell grace-window cancel     # forget pendings without closing
```

## Configuration
The plugin gets installed to `~/.config/omarchy/plugins/jam.grace-window`.
Here you can change what you want. Just disable and enable the plugin again
for changes to take effect.
- **Keybindings** should be edited in the plugins `hypr/bindings.lua` for them
  to persist `Service.qml` restarts.
- **Grace period** in `Service.qml` can be edited: `graceMs`.
- **Grace look** (workspace, cut corners, opacity reduction) can be tuned in
  `Service.qml` too: `graceWorkspace`, `graceRounding`,
  `graceRoundingPower`, `graceOpacityFactor`.
- If you experience graphical glitches for some apps when using the
  **Grace groups** feature, try to increase `groupingDelay`, or refresh the
  graphics manually (e.g. by toggling fullscreen and back). Note that this
  plugin exposes these glitches, rather then being the root cause of them.

## Notes

- Multiple windows can be closed gracefully in sequence. Each one keeps its
  own grace period, and `reopen` restores the most recent one if not focused
  on a gracefully closed window.
- Uses Hyprland's Lua dispatcher syntax
  (e.g. `hl.dsp.window.close({ window = "address:..." })`),
  which needs Hyprland >= 0.55 (present in Omarchy 4.x).
- Validated with `omarchy plugin validate`.
