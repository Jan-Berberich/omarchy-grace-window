// Grace Window — hide to workspace 10 with a reopen grace period.
//
// IPC target: "grace-window"
//   hide()     Move the focused window silently to workspace 10 and give it a
//              one-minute grace period. Returns "requested" when the address
//              query started, "busy" when a previous query is still in flight.
//   reopen()   Bring the most recently hidden window back to the current
//              workspace and focus it, cancelling its pending auto-close.
//              Returns "none" when there is nothing pending.
//   status()   "idle", or "pending Ns" for the most recent hidden window.
//   cancel()   Forget every pending window (does not close them).
//
// Window death on an expired grace period uses Hyprland's Lua dispatcher
// syntax (Hyprland >= 0.55): hyprctl dispatch 'hl.dsp.window.close(...)'.

import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  // Grace period in milliseconds before a hidden window is closed for real.
  readonly property int graceMs: 60000

  // Pending hidden windows, newest last. Each entry keeps the absolute
  // deadline so the sweep can expire many windows independently.
  property var pending: []

  property bool queryBusy: false

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
    if (root.queryBusy) return "busy"
    root.queryBusy = true
    activeProc.running = true
    return "requested"
  }

  Process {
    id: activeProc
    command: ["hyprctl", "-j", "activewindow"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onActiveRead(text)
    }
  }

  function onActiveRead(raw) {
    root.queryBusy = false
    let win
    try {
      win = JSON.parse(raw || "{}")
    } catch (e) {
      return
    }
    const addr = String(win.address || "")
    if (!addr || addr === "0x0") return
    root.pending.push({ address: addr, deadline: Date.now() + root.graceMs })
    root.dispatch([
      "hyprctl", "dispatch",
      'hl.dsp.window.move({ window = "address:' + addr + '", workspace = "10", follow = false })',
    ])
  }

  // --------------------------------------------------------- reopen path
  function reopen() {
    if (root.pending.length === 0) return "none"
    if (root.queryBusy || workspaceProc.running) return "busy"
    const entry = root.pending[root.pending.length - 1]
    root.pending = root.pending.slice(0, -1)
    root._reopenAddress = entry.address
    workspaceProc.running = true
    return "requested"
  }

  property string _reopenAddress: ""

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
    if (root.pending.length === 0) return
    const now = Date.now()
    const dead = []
    const alive = []
    for (let i = 0; i < root.pending.length; i++) {
      if (root.pending[i].deadline <= now) dead.push(root.pending[i])
      else alive.push(root.pending[i])
    }
    if (dead.length === 0) return
    root.pending = alive
    for (let i = 0; i < dead.length; i++) {
      root.dispatch([
        "hyprctl", "dispatch",
        'hl.dsp.window.close({ window = "address:' + dead[i].address + '" })',
      ])
    }
  }

  // ---------------------------------------------------------------- misc
  function status() {
    if (root.pending.length === 0) return "idle"
    const last = root.pending[root.pending.length - 1]
    const remaining = Math.ceil((last.deadline - Date.now()) / 1000)
    return "pending " + (remaining > 0 ? remaining : 0) + "s"
  }

  function cancel() {
    root.pending = []
    return "ok"
  }
}