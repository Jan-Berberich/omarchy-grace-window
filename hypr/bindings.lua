-- Grace Window plugin (jam.grace-window) keybindings.
-- SUPER+W hides the focused window to workspace 10 with a one-minute
-- reopen grace; SUPER+SHIFT+W reopens it; on expiry it is closed for real.
-- SUPER+SHIFT+CTRL+W also closes the window for real, immediately.
-- Requires the plugin to be installed and enabled (see README.md).
--
-- This file documents the bindings for hand-rolled setups. Merge the block
-- below into your existing bindings.lua; it is exactly the managed block
-- install.sh appends. uninstall.sh removes only this block and never
-- touches any other binding, so add only the lines you want to keep.

-- BEGIN Grace Window (jam.grace-window) managed block - do not edit
hl.unbind("SUPER + W")
o.bind("SUPER + W", "Close window gracefully", "omarchy-shell grace-window hide")
hl.unbind("SUPER + SHIFT + W")
o.bind("SUPER + SHIFT + W", "Reopen closed window", "omarchy-shell grace-window reopen")
hl.unbind("SUPER + SHIFT + CTRL + W")
o.bind("SUPER + SHIFT + CTRL + W", "Close window", hl.dsp.window.close())
-- END Grace Window (jam.grace-window) managed block