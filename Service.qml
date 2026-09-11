// Grace Window — hide to workspace 10 with a reopen grace period.
//
// IPC target: "grace-window"
//   hide()     Move the focused window silently to workspace 10 and give it a
//              one-minute grace period. Returns "requested" when the address
//              query started, "busy" when a previous query is still in flight.
//              The grace timer pauses while the hidden window keeps focus.
//   reopen()   Bring a hidden window back to the current workspace and focus
//              it, cancelling its pending auto-close. When the focused window
//              is itself hidden it is preferred; otherwise the most recently
//              hidden window is reopened. Returns "none" when there is nothing
//              pending.
//   status()   "idle", or "pending Ns" for the most recent hidden window.
//   cancel()   Forget every pending window (does not close them).
//
// Window death on an expired grace period uses Hyprland's Lua dispatcher
// syntax (Hyprland >= 0.55): hyprctl dispatch 'hl.dsp.window.close(...)'.
//
// No install.sh: on service start the managed keybinding block from this
// plugin's own hypr/bindings.lua is appended to ~/.config/hypr/bindings.lua
// (when not already present) and Hyprland is reloaded, so enabling the plugin
// is all that is needed. uninstall.sh still removes that block cleanly.

import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  // Grace period in milliseconds before a hidden window is closed for real.
  readonly property int graceMs: 60000

  // Workspace to hide the window into
  readonly property string graceWorkspace: "10"
  // Cut corners mark the window as being in its grace period.
  readonly property double graceRounding: 30
  readonly property double graceRoundingPower: 1
  // Windows in grace period also fade to 90% of their normal opacity.
  readonly property double graceOpacityFactor: 0.9

  // The shell wires the enabled plugin's manifest (including its __sourceDir)
  // onto services that declare this property, so the service can find its own
  // hypr/bindings.lua without any install script.
  property var manifest: null

  // Pending hidden windows, newest last. Each entry keeps its remaining
  // grace time; the sweep pauses it while that window keeps focus.
  property var pending: []

  property bool queryBusy: false

  // Timestamp of the last sweep tick and address of the currently focused
  // window, used to pause a window's grace timer while it is focused.
  property double lastTick: 0
  property string focusedAddress: ""

  // ---------------------------------------------------------------- IPC
  IpcHandler {
    target: "grace-window"

    function hide(): string {
      return root.hide()
    }

    function reopen(): string {
      return root.reopen()
    }

    function status(): string {
      return root.status()
    }

    function cancel(): string {
      return root.cancel()
    }
  }

  // --------------------------------------------------- keybinding wiring
  //
  // install.sh used to append the plugin's keybindings to
  // ~/.config/hypr/bindings.lua. The service now owns that step: on start it
  // appends the managed block from its own hypr/bindings.lua when it is not
  // already present, then reloads Hyprland. Re-running is a safe no-op, so
  // shell restarts and plugin hot-reloads never duplicate the block.
  readonly property string bindingsBlockStart:
    "-- BEGIN Grace Window (jam.grace-window) managed block - do not edit"
  readonly property string bindingsBlockEnd:
    "-- END Grace Window (jam.grace-window) managed block"

  function wireBindings() {
    const manifestDir = root.manifest && root.manifest.__sourceDir
      ? String(root.manifest.__sourceDir) : ""
    // Fall back to the well-known install location in case a shell version
    // ever stops wiring the manifest property.
    const sourceDir = manifestDir
      || Quickshell.env("HOME") + "/.config/omarchy/plugins/jam.grace-window"
    // The block is installed with an owner-checked, symlink-resistant atomic
    // replace instead of an in-place append (">>"), which follows symlinks and
    // could strand a partially written block on failure. Every path component
    // of the target must be owned by the current user (or root), must not be a
    // symlink, and directories must not be group/other writable. The new
    // content is staged in a temp file in the same directory (so the rename is
    // atomic) and never touches anything outside the managed block.
    const script =
      'set -u\n' +
      'src="$1"; target="$2"; start="$3"; end="$4"\n' +
      'tmpfile=""\n' +
      'say() { echo "grace-window: $*"; }\n' +
      'fail() {\n' +
      '  if [[ -n "$tmpfile" ]]; then rm -f "$tmpfile"; fi\n' +
      '  say "ERROR: $*"\n' +
      '  exit 1\n' +
      '}\n' +
      'uid=$(id -u)\n' +
      '[[ "$target" == /* ]] || fail "target is not absolute: $target"\n' +
      'if [[ ! -f "$src" ]]; then say "source bindings missing: $src"; exit 0; fi\n' +
      'if [[ ! -f "$target" ]]; then say "hyprland bindings file not found: $target"; exit 0; fi\n' +
      'if grep -qFs -- "$start" "$target"; then say "keybindings already wired; nothing to do"; exit 0; fi\n' +
      'l0=$(grep -nFs -- "$start" "$src" | head -n1 | cut -d: -f1)\n' +
      'l1=$(grep -nFs -- "$end" "$src" | head -n1 | cut -d: -f1)\n' +
      'if [[ -z "$l0" || -z "$l1" ]]; then fail "managed block not found in $src"; fi\n' +
      'if (( l0 > l1 )); then fail "managed block markers out of order in $src"; fi\n' +
      'cur="/"\n' +
      'IFS=/ read -r -a comps <<< "${target#/}"\n' +
      'for comp in "${comps[@]}"; do\n' +
      '  [[ -n "$comp" ]] || continue\n' +
      '  cur="${cur%/}/$comp"\n' +
      '  [[ -L "$cur" ]] && fail "refusing to write: $cur is a symlink"\n' +
      '  owner=$(stat -c "%u" "$cur" 2>/dev/null) || fail "cannot stat $cur"\n' +
      '  if [[ "$owner" != "$uid" && "$owner" != 0 ]]; then fail "refusing to write: $cur is owned by uid $owner, not you"; fi\n' +
      '  if [[ -d "$cur" ]]; then\n' +
      '    mode=$(stat -c "%a" "$cur")\n' +
      '    if (( (8#$mode & 0022) != 0 )); then fail "refusing to write: $cur is group/other writable (mode $mode)"; fi\n' +
      '  fi\n' +
      'done\n' +
      'dir=$(dirname "$target")\n' +
      'tmpfile=$(mktemp "$dir/bindings.lua.tmp.XXXXXX") || fail "could not create temporary file"\n' +
      'orig_mode=$(stat -c "%a" "$target")\n' +
      '{\n' +
      '  cat "$target"\n' +
      '  echo ""\n' +
      '  sed -n "${l0},${l1}p" "$src"\n' +
      '} > "$tmpfile" || fail "could not write temporary file"\n' +
      'chmod "$orig_mode" "$tmpfile" || fail "could not set permissions on temporary file"\n' +
      'mv -f "$tmpfile" "$target" || fail "could not atomically replace $target"\n' +
      'tmpfile=""\n' +
      'if ! grep -qFs -- "$start" "$target"; then fail "failed to wire keybindings into $target"; fi\n' +
      'hyprctl reload >/dev/null 2>&1 || true\n' +
      'say "keybindings wired into $target and hyprland reloaded"'
    wireProc.command = ["bash", "-c", script, "--",
      sourceDir + "/hypr/bindings.lua",
      Quickshell.env("HOME") + "/.config/hypr/bindings.lua",
      root.bindingsBlockStart,
      root.bindingsBlockEnd]
    wireProc.running = true
  }

  Process {
    id: wireProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: console.log(text)
    }
  }

  // ------------------------------------------------------- dispatch queue
  // A Process cannot be re-run while it is running, so every hyprctl call
  // goes through one FIFO queue drained by a single Process.
  property var queue: []

  function dispatch(args) {
    root.queue.push(args)
    root.pump()
  }

  function pump() {
    if (dispatchProc.running || root.queue.length === 0) return
    dispatchProc.command = root.queue.shift()
    dispatchProc.running = true
  }

  Process {
    id: dispatchProc
    running: false
    onRunningChanged: {
      if (!running) root.pump()
    }
  }

  // ----------------------------------------------------------- hide path
  function hide() {
    if (root.queryBusy || activeProc.running) return "busy"
    root.queryBusy = true
    root._queryMode = "hide"
    activeProc.running = true
    return "requested"
  }

  property string _queryMode: "hide"

  Process {
    id: activeProc
    command: ["hyprctl", "-j", "activewindow"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onActiveRead(text)
    }
  }

  function onActiveRead(raw) {
    const resumingReopen = root._queryMode === "reopen"
    root.queryBusy = false
    let win
    try {
      win = JSON.parse(raw || "{}")
    } catch (e) {
      win = null
      root.queryBusy = false
      return
    }
    const addr = String(win && win.address || "")
    if (addr === "0x0") return
    if (resumingReopen) {
      // Prefer the focused window when it is the one in grace period; otherwise
      // reopen the most recently hidden one.
      let index = -1
      if (addr) {
        for (let i = 0; i < root.pending.length; i++) {
          if (root.pending[i].address !== addr) continue
          index = i
          break
        }
      }
      let entry
      if (index !== -1) entry = root.pending.splice(index, 1)[0]
      else entry = root.pending.pop()
      root._queryMode = "hide"
      if (!entry) return
      root._reopenAddress = entry.address
      root._reopenOpacity = String(entry.opacity)
      root._reopenOpacityInactive = String(entry.opacityInactive)
      root._reopenRounding = String(entry.rounding)
      root._reopenRoundingPower = String(entry.roundingPower)
      workspaceProc.running = true
      return
    }
    if (!addr) return
    // Already hidden: only relocate the window to the grace workspace.
    // Keep its captured look and grace period untouched.
    for (let i = 0; i < root.pending.length; i++) {
      if (root.pending[i].address !== addr) continue
      root.dispatch([
        "hyprctl", "dispatch",
        'hl.dsp.window.move({ window = "address:' + addr + '", workspace = "' + root.graceWorkspace + '", follow = false })',
      ])
      return
    }
    // Capture the window's current corners and opacity so they can be
    // restored exactly when it is reopened.
    if (propProc.running) return
    propProc.command = [
      "bash", "-c",
      "hyprctl getprop address:" + addr + " opacity; hyprctl getprop address:" + addr + " opacity_inactive; hyprctl getprop address:" + addr + " rounding; hyprctl getprop address:" + addr + " rounding_power",
    ]
    root._hideAddress = addr
    propProc.running = true
  }

  property string _hideAddress: ""

  Process {
    id: propProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onPropsRead(text)
    }
  }

  function onPropsRead(raw) {
    const addr = root._hideAddress
    root._hideAddress = ""
    if (!addr) return
    const values = String(raw || "").split("\n").map(function (line) {
      return line.trim()
    })
    const opacity = values[0] || ""
    const opacityInactive = values[1] || ""
    const rounding = values[2] || ""
    const roundingPower = values[3] || ""
    if (opacity === "" || opacityInactive === "" || rounding === "") return
    const graceOpacity = String(Number(opacity) * root.graceOpacityFactor)
    const graceOpacityInactive = String(Number(opacityInactive) * root.graceOpacityFactor)
    root.pending.push({
      address: addr,
      remaining: root.graceMs,
      opacity: opacity,
      opacityInactive: opacityInactive,
      rounding: rounding,
      roundingPower: roundingPower,
    })
    root.dispatch([
      "hyprctl", "dispatch",
      'hl.dsp.window.move({ window = "address:' + addr + '", workspace = "' + root.graceWorkspace + '", follow = false })',
    ])
    // Cut corners and a slight fade mark the window as being in its grace period.
    root.dispatch([
      "hyprctl", "dispatch",
      'hl.dsp.window.set_prop({ window = "address:' + addr + '", prop = "opacity", value = "' + graceOpacity + '" })',
    ])
    root.dispatch([
      "hyprctl", "dispatch",
      'hl.dsp.window.set_prop({ window = "address:' + addr + '", prop = "opacity_inactive", value = "' + graceOpacityInactive + '" })',
    ])
    root.dispatch([
      "hyprctl", "dispatch",
      'hl.dsp.window.set_prop({ window = "address:' + addr + '", prop = "rounding", value = "' + root.graceRounding + '" })',
    ])
    root.dispatch([
      "hyprctl", "dispatch",
      'hl.dsp.window.set_prop({ window = "address:' + addr + '", prop = "rounding_power", value = "' + root.graceRoundingPower + '" })',
    ])
  }

  // --------------------------------------------------------- reopen path
  function reopen() {
    if (root.pending.length === 0) return "none"
    if (root.queryBusy || workspaceProc.running || activeProc.running) return "busy"
    // Resolve the target (focused hidden window, else most recent) via the
    // active window query; the restore path continues in onActiveRead.
    root.queryBusy = true
    root._queryMode = "reopen"
    activeProc.running = true
    return "requested"
  }

  property string _reopenAddress: ""
  property string _reopenOpacity: ""
  property string _reopenOpacityInactive: ""
  property string _reopenRounding: ""
  property string _reopenRoundingPower: ""

  Process {
    id: workspaceProc
    command: ["hyprctl", "-j", "activeworkspace"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onWorkspaceRead(text)
    }
  }

  function onWorkspaceRead(raw) {
    const addr = root._reopenAddress
    root._reopenAddress = ""
    if (!addr) return
    let ws
    try {
      ws = JSON.parse(raw || "{}")
    } catch (e) {
      return
    }
    // preserveHyprlandIdEsque: keep the id as a plain string for the Lua arg.
    let id = ""
    if (ws && ws.id !== undefined && ws.id !== null) id = String(ws.id)
    if (id === "" || id === "null") return
    // Restore the values the window had before it was hidden.
    root.dispatch([
      "hyprctl", "dispatch",
      'hl.dsp.window.set_prop({ window = "address:' + addr + '", prop = "opacity", value = "' + root._reopenOpacity + '" })',
    ])
    root.dispatch([
      "hyprctl", "dispatch",
      'hl.dsp.window.set_prop({ window = "address:' + addr + '", prop = "opacity_inactive", value = "' + root._reopenOpacityInactive + '" })',
    ])
    root._reopenOpacity = ""
    root._reopenOpacityInactive = ""
    root.dispatch([
      "hyprctl", "dispatch",
      'hl.dsp.window.set_prop({ window = "address:' + addr + '", prop = "rounding", value = "' + root._reopenRounding + '" })',
    ])
    root.dispatch([
      "hyprctl", "dispatch",
      'hl.dsp.window.set_prop({ window = "address:' + addr + '", prop = "rounding_power", value = "' + root._reopenRoundingPower + '" })',
    ])
    root._reopenRounding = ""
    root._reopenRoundingPower = ""
    root.dispatch([
      "hyprctl", "dispatch",
      'hl.dsp.window.move({ window = "address:' + addr + '", workspace = "' + id + '" })',
    ])
    root.dispatch([
      "hyprctl", "dispatch",
      'hl.dsp.focus({ window = "address:' + addr + '" })',
    ])
  }

  // ---------------------------------------------------------------- sweep
  Timer {
    interval: 500
    repeat: true
    running: true
    onTriggered: root.sweep()
  }

  function sweep() {
    const now = Date.now()
    if (root.pending.length === 0) {
      // Keep the tick anchor fresh so the first countdown after a new hide
      // starts from a full grace period.
      root.lastTick = now
      return
    }
    const delta = now - root.lastTick
    root.lastTick = now
    const dead = []
    const alive = []
    for (let i = 0; i < root.pending.length; i++) {
      const entry = root.pending[i]
      // While the window itself keeps focus its grace timer is paused.
      if (entry.address === root.focusedAddress) {
        alive.push(entry)
        continue
      }
      entry.remaining -= delta
      if (entry.remaining <= 0) dead.push(entry)
      else alive.push(entry)
    }
    root.pending = alive
    for (let i = 0; i < dead.length; i++) {
      root.dispatch([
        "hyprctl", "dispatch",
        'hl.dsp.window.close({ window = "address:' + dead[i].address + '" })',
      ])
    }
    // Refresh the focused-window probe that decides the next tick's pauses.
    if (!focusProc.running) focusProc.running = true
  }

  Process {
    id: focusProc
    command: ["hyprctl", "-j", "activewindow"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onFocusRead(text)
    }
  }

  function onFocusRead(raw) {
    let win
    try {
      win = JSON.parse(raw || "{}")
    } catch (e) {
      root.focusedAddress = ""
      return
    }
    const addr = String(win && win.address || "")
    root.focusedAddress = addr === "0x0" ? "" : addr
  }

  // ---------------------------------------------------------------- misc
  function status() {
    if (root.pending.length === 0) return "idle"
    const last = root.pending[root.pending.length - 1]
    const remaining = Math.ceil(last.remaining / 1000)
    return "pending " + (remaining > 0 ? remaining : 0) + "s"
  }

  function cancel() {
    root.pending = []
    return "ok"
  }

  // ---------------------------------------------------------------- startup
  Component.onCompleted: {
    // The shell assigns root.manifest right after creating this service, so
    // defer the wiring until that property is populated.
    root.lastTick = Date.now()
    Qt.callLater(root.wireBindings)
  }
}
