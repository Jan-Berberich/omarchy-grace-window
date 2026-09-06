-- Grace Window plugin (jam.grace-window) keybindings.
-- SUPER+W hides the focused window to workspace 10 with a one-minute
-- reopen grace; SUPER+SHIFT+W reopens it; on expiry it is closed for real.
-- SUPER+SHIFT+CTRL+W also closes the window for real, immediately.
-- Requires the plugin to be installed and enabled (see README.md).

-- SUPER+W was: Close window.
hl.unbind("SUPER + W")
o.bind("SUPER + W", "Close window gracefully", "omarchy-shell grace-window hide")

-- SUPER+SHIFT+W was: Omawrite.
hl.unbind("SUPER + SHIFT + W")
o.bind("SUPER + SHIFT + W", "Reopen closed window", "omarchy-shell grace-window reopen")

-- SUPER+SHIFT+CTRL+W keeps the old "Close window" behaviour.
o.bind("SUPER + SHIFT + CTRL + W", "Close window", hl.dsp.window.close())
