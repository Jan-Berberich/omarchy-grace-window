// Grace Window — hide a window to workspace 10 with a one-minute reopen grace.
//
// IPC target: "grace-window"
//   hide()     Move the focused window silently to workspace 10 and start its
//              grace period: force it to plain tiling (no floating, no
//              fullscreen, no pin) and capture its look, mode and geometry so
//              reopen can restore them. In a tabbed group only the focused
//              window is pulled out; the rest stays. The grace timer pauses
//              while the hidden window keeps focus. Returns "requested" when
//              the operation starts, "busy" while another is in flight.
//   reopen()   Bring a hidden window back to the current workspace, focus it,
//              cancel its auto-close and restore its captured state. The
//              focused window is preferred when hidden; otherwise the most
//              recently hidden is reopened. A tiled reopened window joins the
//              tabbed group that currently has focus. Returns "none" when
//              nothing is pending.
//   status()   "idle", or "pending Ns" for the most recent hidden window.
//   cancel()   Forget every pending window (does not close them).
//
// Grace expiry closes the window through Hyprland's Lua dispatcher (>= 0.55).
// A dispatch expression is evaluated in Hyprland's config Lua VM as
// `return hl.dispatch(<expr>)`, so it must evaluate to a dispatcher. The
// plugin dispatches through scripts/grace-window.lua — the single file
// holding every hl.dsp call — whose functions return their dispatcher.
//
// The service is a thin state machine over scripts/: one shell script answers
// the hide and reopen queries with ready-to-use JSON, and the other shell
// operations (binding wiring, grouping) are its subcommands. On start the
// plugin's managed keybinding block from hypr/bindings.lua is appended to
// ~/.config/hypr/bindings.lua (when missing); on teardown it is removed.

// TODO:
// IMPLEMENT: Reopen in scratchpad does not work yet
// IMPLEMENT: Cancel should remove grace look? (and run on teardown?)

import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  // ------------------------------------------------------------ configuration
  // Grace period in milliseconds before a hidden window is closed for real.
  readonly property int graceMs: 60000

  // Workspace to hide the window into
  readonly property string graceWorkspace: "10"
  // Cut corners mark the window as being in its grace period.
  readonly property double graceRounding: 30
  readonly property double graceRoundingPower: 1
  // Windows in grace period also fade to 90% of their normal opacity.
  readonly property double graceOpacityFactor: 0.9

  // Some apps need a beat to refresh their graphics after (un)grouping.
  // set to 0.0 for faster animations (may glitch graphics after (un)grouping)
  // set to 0.1 or higher for slower animations (prevent graphical glitches)
  readonly property double groupingDelay: 0.1

  // ------------------------------------------------------------ the plugin dir
  // The shell wires the plugin manifest (with __sourceDir) onto services that
  // declare `manifest`, locating this plugin's hypr/ and scripts/ without an
  // install script. Falls back to the well-known install location if the
  // shell ever stops wiring it.
  property var manifest: null
  readonly property string sourceDir:
    root.manifest && root.manifest.__sourceDir
      ? String(root.manifest.__sourceDir)
      : Quickshell.env("HOME") + "/.config/omarchy/plugins/jam.grace-window"

  readonly property string scriptsDir: root.sourceDir + "/scripts"
  readonly property string bashScript: root.scriptsDir + "/grace-window.sh"
  readonly property string luaScript: root.scriptsDir + "/grace-window.lua"

  // Pending hidden windows, newest last. Each entry keeps its remaining
  // grace time; the sweep pauses it while that window keeps focus.
  property var pending: []

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

  // ------------------------------------------------------- dispatch queue
  // Commands must run in the order they were asked for, so every hyprctl call
  // is pushed to one FIFO queue drained by a single Process.
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
    stdout: StdioCollector {
      id: dispatchOut
      waitForEnd: true
    }
    onRunningChanged: {
      if (!running) root.pump()
    }
    // hyprctl reports a failed dispatch (missing or broken grace-window.lua, a
    // rejected expression) on stdout and exits nonzero; say so instead of
    // letting the queue fail silently.
    onExited: function(exitCode, exitStatus) {
      const detail = String(dispatchOut.text || "").trim()
      if (exitCode !== 0 || detail.indexOf("error") === 0) {
        console.warn("grace-window: dispatch failed (exit " + exitCode + "): " + detail)
      }
    }
  }

  // ------------------------------------------------------ hyprctl query
  // hide() and reopen() each ask Hyprland once, through a script that answers
  // in ready-to-use JSON. The promise resolves with the collected stdout; the
  // continuation parses defensively so a bad answer never leaves an operation
  // stuck. opBusy serializes operations: there is one opProc, and concurrent
  // hides could otherwise capture the same window twice.
  property bool opBusy: false
  property var opToken: null

  function runOpQuery(args) {
    return new Promise(function (resolve) {
      root.opToken = resolve
      opProc.command = args
      opProc.running = true
    })
  }

  Process {
    id: opProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        const resolve = root.opToken
        root.opToken = null
        if (resolve) resolve(text)
      }
    }
  }

  // ----------------------------------------------------------- hide path
  function hide() {
    if (root.opBusy) return "busy"
    root.opBusy = true
    root.runOpQuery(["bash", root.bashScript, "hide-query"]).then(root.finishHide, root.finishHide)
    return "requested"
  }

  function finishHide(raw) {
    root.opBusy = false
    const rec = root.parseJson(raw)
    if (!rec) return
    const addr = String(rec.address || "")
    if (!addr) return
    // Already hidden: just relocate it, keeping look and grace timer.
    if (root.findPending(addr)) {
      root.moveToGraceWorkspace(addr)
      return
    }
    // Refuse windows that report no opacity or rounding values.
    const opacity = String(rec.opacity || "")
    const opacityInactive = String(rec.opacityInactive || "")
    const rounding = String(rec.rounding || "")
    if (opacity === "" || opacityInactive === "" || rounding === "") return
    // Capture look, mode and geometry so reopen can restore them exactly.
    const entry = {
      address: addr,
      remaining: root.graceMs,
      opacity: opacity,
      opacityInactive: opacityInactive,
      rounding: rounding,
      roundingPower: String(rec.roundingPower || ""),
      floating: String(rec.floating === true),
      fullscreen: String(rec.fullscreen || 0),
      fullscreenClient: String(rec.fullscreenClient || 0),
      pinned: String(rec.pinned === true),
      x: String(rec.x || 0),
      y: String(rec.y || 0),
      w: String(rec.w || 0),
      h: String(rec.h || 0),
    }
    root.pending.push(entry)
    // Pull the window out of any tabbed group first, so only it is hidden.
    const grouped = Array.isArray(rec.grouped) ? rec.grouped : []
    if (grouped.length > 0) {
      root.dispatch(["bash", root.bashScript, "leave-group", addr, String(root.groupingDelay)])
    }
    // Hide the window: force tiling and apply the grace look.
    root.moveToGraceWorkspace(addr)
    root.setWindowFloat(addr, false)
    root.setWindowFullscreen(addr, "0", "0")
    root.setWindowPin(addr, false)
    const graceOpacity = String(Number(opacity) * root.graceOpacityFactor)
    const graceOpacityInactive = String(Number(opacityInactive) * root.graceOpacityFactor)
    root.setWindowProp(addr, "opacity", graceOpacity)
    root.setWindowProp(addr, "opacity_inactive", graceOpacityInactive)
    root.setWindowProp(addr, "rounding", String(root.graceRounding))
    root.setWindowProp(addr, "rounding_power", String(root.graceRoundingPower))
  }

  // --------------------------------------------------------- reopen path
  function reopen() {
    if (root.pending.length === 0) return "none"
    if (root.opBusy) return "busy"
    root.opBusy = true
    root.runOpQuery(["bash", root.bashScript, "reopen-query"]).then(root.finishReopen, root.finishReopen)
    return "requested"
  }

  function finishReopen(raw) {
    root.opBusy = false
    const data = root.parseJson(raw)
    if (!data) return
    const win = data.aw || {}
    const addr = String(win.address || "")
    // A desktop without a focused window has nothing to reopen.
    if (addr === "0x0") return
    // Prefer the focused window when it is in grace; otherwise reopen the
    // most recently hidden one.
    let index = -1
    if (addr) {
      for (let i = 0; i < root.pending.length; i++) {
        if (root.pending[i].address !== addr) continue
        index = i
        break
      }
    }
    const entry = index !== -1 ? root.pending.splice(index, 1)[0] : root.pending.pop()
    if (!entry) return
    const workspace = data.ws || {}
    // Plain string id for the Lua arg (e.g. "4", never 4.0).
    const id = workspace.id !== undefined && workspace.id !== null ? String(workspace.id) : ""
    if (id === "" || id === "null") return
    root.restoreWindow(entry, id)
    // Join the group that had focus when reopening was triggered (the
    // reopened window gets focused right after landing).
    root.dispatch([
      "bash", root.bashScript, "regroup",
      entry.address, String(win.address || ""), String(root.groupingDelay),
    ])
  }

  function restoreWindow(entry, workspaceId) {
    // Undo the grace look, then restore the captured mode and geometry.
    root.setWindowProp(entry.address, "opacity", entry.opacity)
    root.setWindowProp(entry.address, "opacity_inactive", entry.opacityInactive)
    root.setWindowProp(entry.address, "rounding", entry.rounding)
    root.setWindowProp(entry.address, "rounding_power", entry.roundingPower)
    if (entry.floating === "true") {
      root.setWindowFloat(entry.address, true)
      const w = Number(entry.w)
      const h = Number(entry.h)
      if (w > 0 && h > 0) root.resizeWindow(entry.address, entry.w, entry.h)
      root.moveWindowTo(entry.address, entry.x, entry.y)
    }
    if (entry.pinned === "true") root.setWindowPin(entry.address, true)
    if (Number(entry.fullscreen) > 0 || Number(entry.fullscreenClient) > 0) {
      root.setWindowFullscreen(entry.address, entry.fullscreen, entry.fullscreenClient)
    }
    root.moveWindowToWorkspace(entry.address, workspaceId)
  }

  // ------------------------------------------------------ dispatch helpers
  // Thin dispatches into grace-window.lua, the single file holding every
  // hl.dsp call. A dispatch expression must evaluate to a dispatcher, so the
  // lua functions return their hl.dsp call.
  function luaDispatch(body) {
    root.dispatch([
      "hyprctl", "dispatch",
      "dofile('" + root.luaScript + "')." + body,
    ])
  }

  function setWindowProp(addr, prop, value) {
    root.luaDispatch("window_set_prop('" + addr + "', '" + prop + "', '" + value + "')")
  }

  function setWindowFloat(addr, enabled) {
    root.luaDispatch("window_float('" + addr + "', " + (enabled ? "true" : "false") + ")")
  }

  function setWindowPin(addr, enabled) {
    root.luaDispatch("window_pin('" + addr + "', " + (enabled ? "true" : "false") + ")")
  }

  function setWindowFullscreen(addr, internal, client) {
    root.luaDispatch("window_fullscreen('" + addr + "', '" + internal + "', '" + client + "')")
  }

  function moveWindowToWorkspace(addr, workspace) {
    root.luaDispatch("window_to_workspace('" + addr + "', '" + workspace + "')")
  }

  function moveToGraceWorkspace(addr) {
    root.luaDispatch("window_to_grace_workspace('" + addr + "', '" + root.graceWorkspace + "')")
  }

  function moveWindowTo(addr, x, y) {
    root.luaDispatch("window_to_position('" + addr + "', '" + x + "', '" + y + "')")
  }

  function resizeWindow(addr, w, h) {
    root.luaDispatch("window_resize('" + addr + "', '" + w + "', '" + h + "')")
  }

  // ------------------------------------------------------------- helpers
  // Returns the pending entry for addr, or null. Defensive JSON parsing so a
  // malformed query answer never leaves an operation stuck or crashes.
  function findPending(addr) {
    for (let i = 0; i < root.pending.length; i++) {
      if (root.pending[i].address === addr) return root.pending[i]
    }
    return null
  }

  function parseJson(raw) {
    try {
      return JSON.parse(raw || "{}")
    } catch (e) {
      return null
    }
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
      // While the hidden window keeps focus its grace timer is paused.
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
      root.luaDispatch("window_close('" + dead[i].address + "')")
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
    const win = root.parseJson(raw)
    if (!win) {
      root.focusedAddress = ""
      return
    }
    const addr = String(win.address || "")
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

  // --------------------------------------------------- keybinding wiring
  // On start the managed keybinding block from hypr/bindings.lua is appended
  // to ~/.config/hypr/bindings.lua when not already present, then Hyprland is
  // reloaded — idempotent across shell restarts and hot-reloads. On teardown
  // the block is removed again, so disabling the plugin restores the previous
  // bindings.
  readonly property string bindingsBlockBgn:
    "-- BEGIN Grace Window (jam.grace-window) managed block - do not edit this comment"
  readonly property string bindingsBlockEnd:
    "-- END Grace Window (jam.grace-window) managed block - do not edit this comment"

  function wireBindings() {
    wireProc.command = ["bash", root.bashScript, "wire",
      root.sourceDir + "/hypr/bindings.lua",
      Quickshell.env("HOME") + "/.config/hypr/bindings.lua",
      root.bindingsBlockBgn,
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

  // Reverses wireBindings: removes exactly the managed block (plus the blank
  // line before it) from ~/.config/hypr/bindings.lua. Runs detached
  // (Quickshell.execDetached): it is triggered from Component.onDestruction,
  // where a child Process could not outlive the service objects being torn
  // down.
  //
  // Teardown cannot depend on the plugin's own files, which omarchy removes
  // when the plugin is disabled. So at startup the shell script and its awk
  // partner are copied to a stable per-user path (installUnwireScript);
  // teardown runs that copy. A failed copy fails closed and leaves the
  // bindings untouched.
  readonly property string unwireRuntimeDir:
    Quickshell.env("XDG_RUNTIME_DIR") || Quickshell.env("HOME") + "/.cache/grace-window"
  readonly property string unwireRuntimeScript: root.unwireRuntimeDir + "/grace-window.sh"
  property bool unwireInstalled: false

  function installUnwireScript() {
    unwireCopy.command = ["bash", root.bashScript, "install-unwire", root.unwireRuntimeDir]
    unwireCopy.running = true
  }

  Process {
    id: unwireCopy
    onExited: function(exitCode, exitStatus) {
      root.unwireInstalled = exitCode === 0
    }
  }

  function unwireBindings() {
    const target = Quickshell.env("HOME") + "/.config/hypr/bindings.lua"
    if (!root.unwireInstalled) {
      console.warn("grace-window: unwire script not installed; leaving bindings untouched")
      return
    }
    Quickshell.execDetached(["bash", root.unwireRuntimeScript, "unwire",
      target,
      root.bindingsBlockBgn,
      root.bindingsBlockEnd])
  }

  // Runs one harmless dispatch through grace-window.lua at startup, so an
  // unreadable or broken file is reported right away instead of at the first
  // keybinding press.
  function selfCheck() {
    root.luaDispatch("check()")
  }

  // ---------------------------------------------------------------- startup
  Component.onCompleted: {
    // The shell assigns root.manifest right after creating this service, so
    // defer the wiring, the unwire-script copy and the dispatcher self-check
    // until that property is set.
    root.lastTick = Date.now()
    Qt.callLater(root.wireBindings)
    Qt.callLater(root.installUnwireScript)
    Qt.callLater(root.selfCheck)
  }

  // The shell destroys this service when the plugin is disabled or removed,
  // so teardown unwires the managed block — omarchy's plugin remove then
  // leaves nothing behind. It also fires on shell shutdown; the next start
  // re-wires the block (a no-op when already present).
  Component.onDestruction: root.unwireBindings()
}
