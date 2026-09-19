// Grace Window — hide a window to workspace 10 with a one-minute reopen grace.
//
// IPC target: "grace-window"
//   hide()     Move the focused window silently to workspace 10 and start its
//              grace period: force it to plain tiling (no floating, no
//              fullscreen, no pin) and capture its look, mode and geometry so
//              reopen can restore them. In a tabbed group only the focused
//              window is pulled out; the rest stays. The grace timer pauses
//              while the hidden window keeps focus. Returns "requested" when
//              the operation is handed off, "busy" while another is in flight.
//   reopen()   Bring a hidden window back to the current workspace, focus it,
//              cancel its auto-close and restore its captured state. The
//              focused window is preferred when hidden; otherwise the most
//              recently hidden is reopened. A tiled reopened window joins the
//              tabbed group that currently has focus. Returns "none" when
//              nothing is pending, "requested"/"busy" otherwise.
//   status()   "idle", or "pending Ns" for the most recent hidden window.
//   cancel()   Forget every pending window without closing it, restoring its
//              grace look in place (the window stays on the grace workspace).
//              Teardown also does this, so a stopped service never leaves
//              pending windows behind with the grace look.
//   result()   Signal (not a call): the truthful final verdict of each hide or
//              reopen — "ok" when it did something, "none" when it could not
//              (empty desktop, missing look properties, no reopenable entry).
//              IPC functions run synchronously, so a call can only report the
//              handoff; the outcome is emitted on this signal, observable with
//              `qs ipc wait grace-window result`.
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
// ~/.config/hypr/bindings.lua (when missing); on teardown it is removed and
// the grace look of every pending window is restored in place.

// TODO:
// IMPLEMENT: Reopen in scratchpad does not work yet

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

  // Auto-close attempts before giving up on a window whose close keeps failing
  // while it is still alive. Its grace look is then restored in place so it is
  // not left stranded looking pending.
  readonly property int closeRetryMax: 3

  // Time a hide/reopen hyprctl query may take before it is aborted. Without a
  // watchdog a hung hyprctl would leave opBusy set, locking the plugin into
  // returning "busy" forever.
  readonly property int queryTimeoutMs: 10000

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
  // grace time; the sweep pauses it while that window keeps focus. An entry
  // whose time ran out stays here, flagged `expiring`, until its queued close
  // actually succeeds — so a reopen can still cancel the close and bring the
  // window back before it is too late. While the close is in flight the entry
  // is `closing` and no longer reopenable.
  property var pending: []

  // Timestamp of the last sweep tick and address of the currently focused
  // window, used to pause a window's grace timer while it is focused.
  property double lastTick: 0
  property string focusedAddress: ""

  // ---------------------------------------------------------------- IPC
  IpcHandler {
    id: ipc
    target: "grace-window"

    // A call returns the synchronous handoff status — "requested" when the
    // operation is in flight, "busy" while another one runs, "none" when there
    // is nothing to undo right now. The operation itself is asynchronous, so
    // its final verdict is emitted on this signal (observe it with
    // `qs ipc wait grace-window result`) rather than being claimed up front.
    signal result(result: string)

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
  // is pushed to one FIFO queue drained by a single Process. A command can
  // carry a tag so it can be cancelled again before it runs. The sweep tags
  // every window_close this way, letting a reopen (or re-hide) that lands
  // between the charge and the execution cancel the close. Once a tagged
  // command is handed to the Process the entry is flagged `closing` (no longer
  // reopenable); it leaves the pending list only when the close reports
  // success. A close reporting failure keeps the entry pending so the next
  // sweep retries it — up to closeRetryMax attempts, after which its grace
  // look is restored in place instead of the window being stranded. A dispatch
  // that hangs is aborted by dispatchTimeout, so a stuck hyprctl can never
  // block the queue forever; the abort counts as a failure and the close is
  // retried like any other.
  property var queue: []
  // Tag of the dispatch currently running in dispatchProc ("" when untagged),
  // so onExited can attribute the close's success or failure to the right
  // pending entry.
  property string runningTag: ""
  // Set while a hung dispatch has been aborted but its outcome is not yet
  // attributed, mirroring opAborted: dispatchAbortFallback acts only while it
  // stays set, so an onExited that arrives later never double-handles.
  property bool dispatchAborted: false

  function dispatch(args, tag) {
    root.queue.push({ args: args, tag: tag || "" })
    root.pump()
  }

  function pump() {
    if (dispatchProc.running || root.queue.length === 0) return
    const item = root.queue.shift()
    root.runningTag = item.tag
    dispatchProc.command = item.args
    if (item.tag) root.markClosing(item.tag)
    dispatchProc.running = true
  }

  Process {
    id: dispatchProc
    running: false
    stdout: StdioCollector {
      id: dispatchOut
      waitForEnd: true
    }
    // The queue is drained here, not via onRunningChanged: the running tag
    // must be consumed before the next command starts, and this signal is the
    // one place guaranteed to see each command's outcome exactly once.
    //
    // The drain is deferred to the next event-loop turn so it never depends on
    // the order in which Quickshell flips `running` back to false around this
    // signal. Calling pump() synchronously while dispatchProc.running may still
    // be true would early-return and strand the whole queue until another
    // dispatch happens to kick it.
    //
    // Arm the watchdog on every start and disarm it on completion. A hung
    // hyprctl must not leave dispatchProc.running true, because the queue
    // drains — and thereby every close, grace-look set and regroup — on that
    // flag alone.
    onRunningChanged: {
      if (dispatchProc.running) {
        dispatchTimeout.interval = root.queryTimeoutMs
        dispatchTimeout.restart()
      } else {
        dispatchTimeout.stop()
      }
    }
    onExited: function(exitCode, exitStatus) {
      const tag = root.runningTag
      root.runningTag = ""
      dispatchTimeout.stop()
      dispatchAbortFallback.stop()
      root.dispatchAborted = false
      const detail = String(dispatchOut.text || "").trim()
      if (exitCode !== 0 || detail.indexOf("error") === 0) {
        console.warn("grace-window: dispatch failed (exit " + exitCode + "): " + detail)
        if (tag) root.closeAborted(tag)
      } else if (tag) {
        root.closeStarted(tag)
      }
      Qt.callLater(root.pump)
    }
  }

  // Watchdog for a hung dispatch, mirroring focusProcTimeout: on timeout the
  // process is killed (running = false) and its outcome is attributed as a
  // failure, so a close gets retried and the queue drains again. Without this
  // a stuck hyprctl would leave dispatchProc.running true, stranding the FIFO
  // and every later close, grace-look set, regroup and leave-group behind it.
  Timer {
    id: dispatchTimeout
    repeat: false
    onTriggered: {
      if (!dispatchProc.running) return
      console.warn("grace-window: dispatch timed out; aborting it")
      root.dispatchAborted = true
      dispatchProc.running = false
      dispatchAbortFallback.interval = Math.max(1000, Math.round(root.queryTimeoutMs / 4))
      dispatchAbortFallback.restart()
    }
  }

  // Safety net for an aborted dispatch whose onExited never arrives (e.g. the
  // killed process lingers): attribute the running tag as a failure and drain
  // the queue, so a stuck dispatch can never block the FIFO forever. The
  // onExited handler clears dispatchAborted when it does fire, so this only
  // acts while the abort is still unattributed.
  Timer {
    id: dispatchAbortFallback
    repeat: false
    onTriggered: {
      if (!root.dispatchAborted) return
      console.warn("grace-window: aborted dispatch did not finish; discarding it")
      dispatchTimeout.stop()
      root.dispatchAborted = false
      const tag = root.runningTag
      root.runningTag = ""
      if (tag) root.closeAborted(tag)
      Qt.callLater(root.pump)
    }
  }

  // ------------------------------------------------------ hyprctl query
  // hide() and reopen() each ask Hyprland once, through a script that answers
  // in ready-to-use JSON. The promise resolves with the collected stdout; the
  // continuation parses defensively so a bad answer never leaves an operation
  // stuck. opBusy serializes operations: there is one opProc, and concurrent
  // hides could otherwise capture the same window twice.
  //
  // The promise is settled from the collector's onStreamFinished — never from
  // the watchdog alone. A timed-out run is aborted (the process is killed) but
  // its promise is resolved by that aborted run's own trailing stream finish,
  // and opBusy stays set until then. A query issued in the meantime therefore
  // answers "busy" instead of silently receiving the aborted run's stale
  // output. opAbortFallback settles the promise anyway if the finish never
  // arrives, so a kill that never lands cannot leave the plugin "busy" forever.
  property bool opBusy: false
  property var opToken: null
  property bool opAborted: false

  function runOpQuery(args) {
    return new Promise(function (resolve) {
      root.opToken = resolve
      root.opAborted = false
      opProc.command = args
      opProc.running = true
      // Abort a query that never finishes: without this the promise stays
      // pending and opBusy keeps every later hide/reopen answering "busy".
      opProcTimeout.interval = root.queryTimeoutMs
      opProcTimeout.restart()
    })
  }

  Process {
    id: opProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        opProcTimeout.stop()
        opAbortFallback.stop()
        const resolve = root.opToken
        root.opToken = null
        const aborted = root.opAborted
        root.opAborted = false
        // An aborted run resolves the JSON literal "null"; the defensive
        // parsers in the finish handlers then bail out exactly like an empty
        // answer, leaving opBusy cleared. A healthy run resolves its output.
        if (resolve) resolve(aborted ? "null" : text)
      }
    }
  }

  Timer {
    id: opProcTimeout
    repeat: false
    onTriggered: {
      if (!root.opToken) return
      console.warn("grace-window: hyprctl query timed out; aborting it")
      // Do not settle the promise here. Resolving eagerly (as a plain abort)
      // would release opBusy while the aborted run's process may still be
      // finishing, letting a query issued in that window be answered by this
      // run's stale output. The run's own trailing stream finish settles it;
      // opAbortFallback covers the case where that finish never comes.
      root.opAborted = true
      opProc.running = false
      opAbortFallback.interval = Math.max(1000, Math.round(root.queryTimeoutMs / 4))
      opAbortFallback.restart()
    }
  }

  // Safety net for an aborted run whose stream finish never arrives (e.g. the
  // killed process lingers): settle the outstanding promise with "null" so
  // opBusy is released and the plugin stays useable.
  Timer {
    id: opAbortFallback
    repeat: false
    onTriggered: {
      if (!root.opToken) return
      console.warn("grace-window: aborted hyprctl query did not finish; discarding it")
      const resolve = root.opToken
      root.opToken = null
      root.opAborted = false
      resolve("null")
    }
  }

  // ----------------------------------------------------------- hide path
  // The IPC call hands off synchronously ("requested"), so the operation's
  // actual verdict is reported when the async query settles: finishHide
  // classifies every outcome and reportOperation surfaces it on the `result`
  // IPC signal (and as a warning when nothing was hidden). opBusy is released
  // at the same moment.
  function hide() {
    if (root.opBusy) return "busy"
    root.opBusy = true
    root.runOpQuery(["bash", root.bashScript, "hide-query"]).then(root.finishHide, root.finishHide)
    return "requested"
  }

  function finishHide(raw) {
    const verdict = root.classifyHide(raw)
    root.opBusy = false
    root.reportOperation("hide", verdict)
  }

  // Returns "ok" when a window was hidden, "none" when nothing was (no focused
  // window, a window already closing, or a window whose look could not be
  // captured exactly).
  function classifyHide(raw) {
    const rec = root.parseJson(raw)
    if (!rec) return "none"
    const addr = String(rec.address || "")
    if (!addr) return "none"
    const existing = root.findPending(addr)
    if (existing && existing.closing) return "none"
    if (existing) {
      // Re-hiding a window whose grace already expired cancels its close —
      // whether already queued or not — and grants a fresh grace period.
      // Otherwise just relocate the window, keeping its look and remaining
      // grace time.
      if (existing.closeTag) {
        root.cancelQueuedClose(existing.closeTag)
        existing.closeTag = ""
      }
      if (existing.expiring) {
        existing.expiring = false
        existing.remaining = root.graceMs
      }
      root.moveToGraceWorkspace(addr)
      return "ok"
    }
    // Refuse windows that report no opacity or rounding values: the look
    // could not be restored faithfully on reopen, so better not hide at all.
    const opacity = String(rec.opacity || "")
    const opacityInactive = String(rec.opacityInactive || "")
    const rounding = String(rec.rounding || "")
    const roundingPower = String(rec.roundingPower || "")
    if (opacity === "" || opacityInactive === "" || rounding === "" || roundingPower === "") return "none"
    // A non-numeric getprop value would otherwise turn into a "NaN" prop value.
    const graceOpacity = Number(opacity) * root.graceOpacityFactor
    const graceOpacityInactive = Number(opacityInactive) * root.graceOpacityFactor
    if (isNaN(graceOpacity) || isNaN(graceOpacityInactive)) return "none"
    // Capture look, mode and geometry so reopen can restore them exactly.
    const entry = {
      address: addr,
      remaining: root.graceMs,
      opacity: opacity,
      opacityInactive: opacityInactive,
      rounding: rounding,
      roundingPower: roundingPower,
      floating: String(rec.floating === true),
      fullscreen: String(rec.fullscreen || 0),
      fullscreenClient: String(rec.fullscreenClient || 0),
      pinned: String(rec.pinned === true),
      x: String(rec.x || 0),
      y: String(rec.y || 0),
      w: String(rec.w || 0),
      h: String(rec.h || 0),
      closing: false,
      closeFails: 0,
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
    root.setWindowProp(addr, "opacity", String(graceOpacity))
    root.setWindowProp(addr, "opacity_inactive", String(graceOpacityInactive))
    root.setWindowProp(addr, "rounding", String(root.graceRounding))
    root.setWindowProp(addr, "rounding_power", String(root.graceRoundingPower))
    return "ok"
  }

  // Reports the final verdict of an asynchronous hide or reopen. No-ops are
  // the interesting ones: a "requested" handoff must not silently be a nothing.
  function reportOperation(op, verdict) {
    if (verdict !== "ok") {
      console.warn("grace-window: " + op + " finished with no effect (" + verdict + ")")
    }
    ipc.result(verdict)
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
    const verdict = root.classifyReopen(raw)
    root.opBusy = false
    root.reportOperation("reopen", verdict)
  }

  // Returns "ok" when a window was reopened and restored, "none" when nothing
  // could be reopened (no reopenable entry, or a query answer too broken to
  // act on). The focused window is preferred when it is in grace; otherwise
  // the most recently hidden one is reopened.
  function classifyReopen(raw) {
    const data = root.parseJson(raw)
    if (!data) return "none"
    const win = data.aw || {}
    const addr = String(win.address || "")
    // The focused window is only used below to prefer reopening it when it is
    // in grace and to pick the group to join on landing. Its absence (an
    // empty desktop, where hyprctl reports no window at all) is a normal case:
    // the newest hidden window is then reopened onto the active workspace.
    // The reopen target must be resolvable before any pending entry is
    // disturbed: an unparseable answer (e.g. a transient hyprctl failure
    // yielding an empty workspace) must not drop the chosen entry, whose
    // queued close would then be cancelled while the window stays hidden and
    // untracked forever.
    const workspace = data.ws || {}
    // Plain string id for the Lua arg (e.g. "4", never 4.0).
    const id = workspace.id !== undefined && workspace.id !== null ? String(workspace.id) : ""
    if (id === "" || id === "null") return "none"
    // Prefer the focused window when it is in grace; otherwise reopen the
    // most recently hidden one. Entries whose close is already running
    // (`closing`) are not reopened — their window is lost either way.
    let index = -1
    if (addr) {
      for (let i = 0; i < root.pending.length; i++) {
        if (root.pending[i].address !== addr || root.pending[i].closing) continue
        index = i
        break
      }
    }
    const entry = index !== -1 ? root.pending.splice(index, 1)[0] : root.popReopenable()
    if (!entry) return "none"
    // If the chosen window's grace expired and the sweep already queued its
    // close, cancel that close now — otherwise it would fire right after the
    // restore dispatches and close the window just brought back. A close that
    // is already running cannot be undone (inherent).
    if (entry.closeTag) {
      root.cancelQueuedClose(entry.closeTag)
      entry.closeTag = ""
      entry.expiring = false
    }
    root.restoreWindow(entry, id)
    // Join the group that had focus when reopening was triggered (the
    // reopened window gets focused right after landing).
    root.dispatch([
      "bash", root.bashScript, "regroup",
      entry.address, String(win.address || ""), String(root.groupingDelay),
    ])
    return "ok"
  }

  function undoGraceState(entry) {
    // Undo everything hide() did to the window's look and mode — the lower
    // opacity, the cut corners and the forced tiling. Never touches the
    // workspace, so the window stays where it is (the grace workspace for a
    // pending window, or the current one when reopening).
    root.setWindowProp(entry.address, "opacity", entry.opacity)
    root.setWindowProp(entry.address, "opacity_inactive", entry.opacityInactive)
    root.setWindowProp(entry.address, "rounding", entry.rounding)
    root.setWindowProp(entry.address, "rounding_power", entry.roundingPower)
    if (entry.floating === "true") root.setWindowFloat(entry.address, true)
    if (entry.pinned === "true") root.setWindowPin(entry.address, true)
    if (Number(entry.fullscreen) > 0 || Number(entry.fullscreenClient) > 0) {
      root.setWindowFullscreen(entry.address, entry.fullscreen, entry.fullscreenClient)
    }
  }

  function restoreWindow(entry, workspaceId) {
    // Undo the grace look, then restore the captured mode and geometry.
    root.undoGraceState(entry)
    if (entry.floating === "true") {
      const w = Number(entry.w)
      const h = Number(entry.h)
      if (w > 0 && h > 0) root.resizeWindow(entry.address, entry.w, entry.h)
      root.moveWindowTo(entry.address, entry.x, entry.y)
    }
    root.moveWindowToWorkspace(entry.address, workspaceId)
  }

  // ------------------------------------------------------ dispatch helpers
  // Thin dispatches into grace-window.lua, the single file holding every
  // hl.dsp call. A dispatch expression must evaluate to a dispatcher, so the
  // lua functions return their hl.dsp call.
  function luaDispatch(body, tag) {
    root.dispatch([
      "hyprctl", "dispatch",
      "dofile('" + root.luaScript + "')." + body,
    ], tag)
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

  // Removes and returns the newest pending entry that is not having its close
  // run right now, or null when every pending window is closing.
  function popReopenable() {
    for (let i = root.pending.length - 1; i >= 0; i--) {
      if (root.pending[i].closing) continue
      return root.pending.splice(i, 1)[0]
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

  // Removes every queued command carrying tag, used to drop a window_close the
  // sweep already queued but that has not been handed to the Process yet. A
  // close that is already running can not be undone — that unavoidable race is
  // only the few milliseconds the dispatch command itself takes.
  function cancelQueuedClose(tag) {
    for (let i = root.queue.length - 1; i >= 0; i--) {
      if (root.queue[i].tag === tag) root.queue.splice(i, 1)
    }
  }

  // Cancels the scheduled close of every pending window. Used by cancel() and
  // teardown so a window whose grace look is restored in place really stays
  // open instead of still being killed by its already-queued close. Entries
  // whose close is already running are left alone: only the dispatch outcome
  // can resolve them now.
  function cancelScheduledCloses() {
    for (let i = 0; i < root.pending.length; i++) {
      const entry = root.pending[i]
      if (entry.closing || !entry.closeTag) continue
      root.cancelQueuedClose(entry.closeTag)
      entry.closeTag = ""
      entry.expiring = false
    }
  }

  // ---------------------------------------------------------------- sweep
  Timer {
    interval: 500
    repeat: true
    running: true
    onTriggered: root.sweep()
  }

  // A tagged window_close has just been handed to the Process. The window can
  // not be reopened anymore from here on (the cancel race is only the few
  // milliseconds the dispatch itself takes), so flag the entry `closing`.
  function markClosing(tag) {
    for (let i = 0; i < root.pending.length; i++) {
      if (root.pending[i].closeTag !== tag) continue
      root.pending[i].closing = true
      return
    }
  }

  // A tagged window_close reported success: the window is gone for real, so
  // drop its pending entry.
  function closeStarted(tag) {
    for (let i = 0; i < root.pending.length; i++) {
      if (root.pending[i].closeTag !== tag) continue
      root.pending.splice(i, 1)
      return
    }
  }

  // A tagged window_close reported failure. The close command reports failure
  // only when the window is still alive (its address still exists in Hyprland),
  // so hand it back to the sweep for a retry. After closeRetryMax failed
  // attempts the window is left alone: its grace look is restored in place so
  // it is not stranded styled as pending, and its entry is dropped.
  function closeAborted(tag) {
    for (let i = 0; i < root.pending.length; i++) {
      const entry = root.pending[i]
      if (entry.closeTag !== tag) continue
      entry.closing = false
      entry.closeTag = ""
      entry.closeFails = (entry.closeFails || 0) + 1
      if (entry.closeFails >= root.closeRetryMax) {
        console.warn("grace-window: giving up closing " + entry.address + " after " +
          entry.closeFails + " attempts; restoring its look in place")
        root.undoGraceState(entry)
        root.pending.splice(i, 1)
        return
      }
      entry.expiring = true
      return
    }
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
    // Iterate over a snapshot: queueing a close inside the loop hands the
    // command to the Process synchronously, which flags live entries and a
    // completing dispatch splices them, shifting the live array's indices.
    const snapshot = root.pending.slice()
    for (let i = 0; i < snapshot.length; i++) {
      const entry = snapshot[i]
      // An expired window is closed for real regardless of focus. If its close
      // is not queued yet, queue it now — the extra sweep interval between
      // flagging it and this dispatch is the window in which a reopen can
      // cancel before the close is ever submitted.
      if (entry.expiring) {
        if (!entry.closeTag) {
          entry.closeTag = "close:" + entry.address
          root.dispatch(["bash", root.bashScript, "close", entry.address], entry.closeTag)
        }
        continue
      }
      // While the hidden window keeps focus its grace timer is paused.
      if (entry.address === root.focusedAddress) continue
      entry.remaining -= delta
      if (entry.remaining > 0) continue
      // Grace ran out: flag the window for real closing. A reopen that lands
      // within the next sweep interval still wins — the close is only
      // submitted on a later tick, and once submitted it starts promptly
      // (immediately when the queue is idle). Only while the tagged close
      // still waits in the queue can a reopen cancel it before it runs.
      entry.expiring = true
    }
    // Refresh the focused-window probe that decides the next tick's pauses.
    if (!focusProc.running) focusProc.running = true
  }

  Process {
    id: focusProc
    command: ["hyprctl", "-j", "activewindow"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        focusProcTimeout.stop()
        root.onFocusRead(text)
      }
    }
    // Arm the watchdog on every probe start and disarm it on completion. A
    // hung hyprctl must not leave focusProc.running true, because the sweep
    // gates its next probe (and thereby the focus-pause) on that flag.
    onRunningChanged: {
      if (focusProc.running) {
        focusProcTimeout.interval = root.queryTimeoutMs
        focusProcTimeout.restart()
      } else {
        focusProcTimeout.stop()
      }
    }
  }

  // Watchdog for the focus probe, mirroring opProcTimeout. On timeout the
  // hung probe is aborted and the last known focused address is kept:
  // clearing it would unpause a focused hidden window during the outage and
  // let the sweep close it out from under the user.
  Timer {
    id: focusProcTimeout
    interval: root.queryTimeoutMs
    repeat: false
    onTriggered: {
      console.warn("grace-window: focus probe timed out; aborting it")
      focusProc.running = false
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
    // An expired window still counts as pending: until its close actually
    // runs it can still be reopened (and cancel its own close).
    if (root.pending.length === 0) return "idle"
    const last = root.pending[root.pending.length - 1]
    const remaining = Math.ceil(last.remaining / 1000)
    return "pending " + (remaining > 0 ? remaining : 0) + "s"
  }

  function cancel() {
    // Forget every pending window without closing it, restoring its grace
    // look in place. The window stays on the grace workspace; only reopen
    // moves it back. Queued auto-closes are cancelled so the windows really
    // are left alone.
    root.cancelScheduledCloses()
    for (let i = 0; i < root.pending.length; i++) {
      root.undoGraceState(root.pending[i])
    }
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

  // Teardown variant of cancel(): restores the grace look of every pending
  // window in place (they stay on the grace workspace). Runs detached through
  // the copied runtime script, for the same reason as unwireBindings: on
  // Component.onDestruction a child Process could not outlive the service
  // objects being torn down, and the plugin directory may already be gone.
  function cancelDetached() {
    if (root.pending.length === 0) return
    if (!root.unwireInstalled) {
      console.warn("grace-window: unwire script not installed; leaving grace look in place")
      return
    }
    Quickshell.execDetached(["bash", root.unwireRuntimeScript, "undo-grace",
      JSON.stringify(root.pending)])
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
  // so teardown cancels pending windows in place (restores their grace look)
  // and unwires the managed block — omarchy's plugin remove then leaves nothing
  // behind. It also fires on shell shutdown; the next start re-wires the block
  // (a no-op when already present).
  Component.onDestruction: {
    // Drop queued auto-closes first, so the detached grace-look undo below is
    // not immediately followed by the windows being closed for real.
    root.cancelScheduledCloses()
    root.cancelDetached()
    root.unwireBindings()
  }
}
