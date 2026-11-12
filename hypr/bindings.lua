-- Grace Window plugin (jam.grace-window) keybindings.
-- SUPER+W and SUPER+Q hide the focused window to the hidden special:grace
-- workspace with a 60s grace period
-- SUPER+SHIFT+W reopens it (if not already expired and closed for real)
-- SUPER+DELETE shows the grace workspace
-- SUPER+SHIFT+CTRL+W closes the window for real, immediately.
-- Requires the plugin to be installed and enabled (see README.md).
--
-- The whole configuration is the arguments of the managed commands below:
--   omarchy-shell grace-window hide <workspace> <period> <rounding> <rounding_power> <opacity_factor>
--   omarchy-shell grace-window reopen <workspace>
-- with <period> in seconds.
-- Each workspace can run its own workflow. The default args below are:
-- workspace: special:grace, period: 60s, rounding: 30 at power: 1, opacity: 50%
--
-- On service start the plugin copies the block below into your
-- ~/.config/hypr/bindings.lua, exactly once. This file is the source of the
-- managed block.
-- On service teardown the plugin removes only that block and never touches any
-- other binding.

-- BEGIN Grace Window (jam.grace-window) managed block - do not edit this comment
hl.unbind("SUPER + Q")
o.bind("SUPER + Q", "Close window gracefully (jam.grace-window)", "omarchy-shell grace-window hide special:grace 60 30 1 0.5")
hl.unbind("SUPER + W")
o.bind("SUPER + W", "Close window gracefully (jam.grace-window)", "omarchy-shell grace-window hide special:grace 60 30 1 0.5")
hl.unbind("SUPER + SHIFT + W")
o.bind("SUPER + SHIFT + W", "Reopen closed window (jam.grace-window)", "omarchy-shell grace-window reopen special:grace")
hl.unbind("SUPER + DELETE")
o.bind("SUPER + DELETE", "Switch to grace workspace (jam.grace-window)", hl.dsp.focus({ workspace = "special:grace" }))
-- for "minimize/recover" workflow with no timeout:
-- uncomment the following 6 lines in your live ~/.config/hypr/bindings.lua
-- hl.unbind("SUPER + ALT + W")
-- o.bind("SUPER + ALT + W", "Minimize window (jam.grace-window)", "omarchy-shell grace-window hide special:minimize 9e9 9 1 1")
-- hl.unbind("SUPER + ALT + SHIFT + W")
-- o.bind("SUPER + ALT + SHIFT + W", "Recover window (jam.grace-window)", "omarchy-shell grace-window reopen special:minimize")
-- hl.unbind("SUPER + ALT + DELETE")
-- o.bind("SUPER + ALT + DELETE", "Switch to minimize workspace (jam.grace-window)", hl.dsp.focus({ workspace = "special:minimize" }))
hl.unbind("SUPER + SHIFT + CTRL + W")
o.bind("SUPER + SHIFT + CTRL + W", "Close window (jam.grace-window)", hl.dsp.window.close())
-- END Grace Window (jam.grace-window) managed block - do not edit this comment
