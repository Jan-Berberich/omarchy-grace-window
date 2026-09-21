-- Grace Window plugin (jam.grace-window) keybindings.
-- SUPER+W hides the focused window to workspace 10 with 60s grace period
-- SUPER+SHIFT+W reopens it (if not already expired and closed for real)
-- SUPER+SHIFT+CTRL+W closes the window for real, immediately.
-- Requires the plugin to be installed and enabled (see README.md).
--
-- The whole configuration is the arguments of the managed commands below:
--   omarchy-shell grace-window hide <workspace> <period> <rounding> <rounding_power> <opacity_factor>
--   omarchy-shell grace-window reopen <workspace>
-- with <period> in seconds.
-- Each workspace can run its own workflow. The default args below are:
-- workspace: 10, period: 60s, rounding: 30 at power: 1, opacity: 90%
--
-- On service start the plugin copies the block below into your
-- ~/.config/hypr/bindings.lua, exactly once. This file is the source of the
-- managed block.
-- On service teardown the plugin removes only that block and never touches any
-- other binding.

-- BEGIN Grace Window (jam.grace-window) managed block - do not edit this comment
hl.unbind("SUPER + W")
o.bind("SUPER + W", "Close window gracefully (jam.grace-window)", "omarchy-shell grace-window hide '10' 60 30 1 0.9")
hl.unbind("SUPER + SHIFT + W")
o.bind("SUPER + SHIFT + W", "Reopen closed window (jam.grace-window)", "omarchy-shell grace-window reopen '10'")
-- for "minimize/recover" workflow on workspace 9 with no timeout: uncomment the following 4 lines
-- hl.unbind("SUPER + ALT + W")
-- o.bind("SUPER + ALT + W", "Minimize window (jam.grace-window)", "omarchy-shell grace-window hide '9' 9e9 9 1 1")
-- hl.unbind("SUPER + ALT + SHIFT + W")
-- o.bind("SUPER + ALT + SHIFT + W", "Recover window (jam.grace-window)", "omarchy-shell grace-window reopen '9'")
hl.unbind("SUPER + SHIFT + CTRL + W")
o.bind("SUPER + SHIFT + CTRL + W", "Close window (jam.grace-window)", hl.dsp.window.close())
-- END Grace Window (jam.grace-window) managed block - do not edit this comment
