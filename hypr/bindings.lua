-- Grace Window plugin (jam.grace-window) keybindings.
-- SUPER+W hides the focused window to workspace 10 with a one-minute
-- reopen grace; SUPER+SHIFT+W reopens it; on expiry it is closed for real.
-- SUPER+SHIFT+CTRL+W also closes the window for real, immediately.
-- Requires the plugin to be installed and enabled (see README.md).
--
-- On service start the plugin copies the block below into your
-- ~/.config/hypr/bindings.lua, exactly once. This file is the source of the
-- managed block; uninstall.sh removes only that block and never touches any
-- other binding.

-- BEGIN Grace Window (jam.grace-window) managed block - do not edit this comment
hl.unbind("SUPER + W")
o.bind("SUPER + W", "Close window gracefully (jam.grace-window)", "omarchy-shell grace-window hide")
hl.unbind("SUPER + SHIFT + W")
o.bind("SUPER + SHIFT + W", "Reopen closed window (jam.grace-window)", "omarchy-shell grace-window reopen")
hl.unbind("SUPER + SHIFT + CTRL + W")
o.bind("SUPER + SHIFT + CTRL + W", "Close window (jam.grace-window)", hl.dsp.window.close())
-- END Grace Window (jam.grace-window) managed block - do not edit this comment
