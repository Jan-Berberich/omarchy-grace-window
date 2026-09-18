-- Grace Window — every Hyprland Lua dispatcher call the plugin makes.
--
-- A dispatch expression evaluates in Hyprland's persistent config VM, wrapped
-- as `return hl.dispatch(<expr>)`, so an expression must evaluate <expr> to a
-- dispatcher function. Every function here therefore RETURNS its hl.dsp call;
-- dispatch expressions become:
--
--   hyprctl dispatch "dofile('<path>/grace-window.lua').window_<fn>(<args>)"
--
-- Kept to one file so none of the hl.dsp syntax leaks into Service.qml or the
-- shell scripts.

local gw = {}

function gw.window_set_prop(address, prop, value)
  return hl.dsp.window.set_prop({ window = "address:" .. address, prop = prop, value = value })
end

function gw.window_float(address, enabled)
  return hl.dsp.window.float({ window = "address:" .. address, action = enabled and "on" or "off" })
end

function gw.window_pin(address, enabled)
  return hl.dsp.window.pin({ window = "address:" .. address, action = enabled and "on" or "off" })
end

function gw.window_fullscreen(address, internal, client)
  return hl.dsp.window.fullscreen_state({
    window = "address:" .. address,
    internal = tonumber(internal),
    client = tonumber(client),
    action = "set",
  })
end

function gw.window_to_workspace(address, workspace)
  return hl.dsp.window.move({ window = "address:" .. address, workspace = workspace })
end

function gw.window_to_grace_workspace(address, workspace)
  return hl.dsp.window.move({ window = "address:" .. address, workspace = workspace, follow = false })
end

function gw.window_to_position(address, x, y)
  return hl.dsp.window.move({ window = "address:" .. address, x = tonumber(x), y = tonumber(y) })
end

function gw.window_resize(address, width, height)
  return hl.dsp.window.resize({ window = "address:" .. address, x = tonumber(width), y = tonumber(height) })
end

function gw.window_close(address)
  return hl.dsp.window.close({ window = "address:" .. address })
end

function gw.window_out_of_group(address)
  return hl.dsp.window.move({ window = "address:" .. address, out_of_group = true })
end

function gw.window_into_group(address, direction)
  return hl.dsp.window.move({ window = "address:" .. address, into_group = direction })
end

-- Startup probe: a harmless dispatcher that proves this file loaded and that
-- Hyprland accepts what one of its functions returns. A failure here means the
-- whole file is unreadable or broken, which the service reports at start.
function gw.check()
  return hl.dsp.exec_cmd("true")
end

return gw
