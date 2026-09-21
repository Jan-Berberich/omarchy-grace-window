// Grace Window — hide windows to a "grace" workspace with a reopen grace.
//
// IPC target: "grace-window"
//   hide(workspace, period, rounding, roundingPower, opacityFactor)
//              Move the focused window silently to `workspace` and start its
//              `period`-seconds grace: force it to plain tiling (no floating,
//              no fullscreen, no pin) and capture its look, mode and geometry
//              so reopen can restore them, then apply the grace look — corners
//              cut by `rounding` (at `roundingPower`) and opacity scaled by
//              `opacityFactor`. In a tabbed group only the focused window is
//              pulled out; the rest stays. The grace timer pauses while the
//              hidden window keeps focus. Returns "requested" when the
//              operation is handed off, "busy" while another is in flight.
//   reopen(workspace)
//              Bring a window hidden into `workspace` back and focus it,
//              cancel its auto-close and restore its captured state. It lands
//              on the focused monitor's active special workspace (the
//              scratchpad) when one is shown, and on the active workspace
//              otherwise. The focused window is preferred when hidden;
//              otherwise the most recently hidden is reopened. A tiled
//              reopened window joins the tabbed group that currently has
//              focus. Returns "none" when nothing is pending, "requested"/
//              "busy" otherwise.
//   status()   "idle", or "pending <N>s" for the most recent hidden window.
//   cancel()   Forget every pending window without closing it, restoring its
//              grace look in place (the window stays on the grace workspace).
//              Teardown also does this, so a stopped service never leaves
//              pending windows behind with the grace look.
//
// The pending state is persisted across service lifecycles: teardown saves the
// pending buffers to the runtime dir, and startup restores them for the windows
// that still exist on their saved grace workspace (with their grace look and
// remaining time, so the pre-teardown state continues). Windows moved or closed
// while the service was down are left alone (see "state persistence").
//   result()   Signal (not a call): the truthful final verdict of each hide or
//              reopen — "ok" when it did something, "none" when it could not
//              (empty desktop, missing look properties, no reopenable entry).
//              IPC functions run synchronously, so a call can only report the
//              handoff; the outcome is emitted on this signal, observable with
//              `qs ipc wait grace-window result`.
//
// Every hide target keeps its own FIFO of hidden windows — the `workspace`
// argument is both the destination and the buffer key, and hide()/reopen()
// only touch the buffer of the workspace they are called with. The keybindings
// therefore carry the whole configuration (workspace, grace period and grace
// look); see the managed block in hypr/bindings.lua for the default workflow.
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

import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  // ------------------------------------------------------------ configuration
  // The grace workspace, period and look travel as arguments of the hide()
  // IPC call and live in the keybindings (see hypr/bindings.lua), so each
  // workspace can have its own settings. Only the timing knobs stay here.

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
      ? root.manifest.__sourceDir
      : Quickshell.env("HOME") + "/.config/omarchy/plugins/jam.grace-window"

  readonly property string scriptsDir: root.sourceDir + "/scripts"
  readonly property string bashScript: root.scriptsDir + "/grace-window.sh"
  readonly property string luaScript: root.scriptsDir + "/grace-window.lua"

  // Pending hidden windows, newest last. Every entry names the workspace it
  // was hidden into (`workspace`); the entries of one workspace form its
  // private FIFO buffer, ordered by hide time, and hide()/reopen() only ever
  // touch the buffer of the workspace they are called with. Each entry keeps
  // its remaining grace time; the sweep pauses it while that window keeps
  // focus. An entry whose time ran out stays here, flagged `expiring`, until
  // its queued close actually succeeds — so a reopen can still cancel the
  // close and bring the window back before it is too late. While the close is
  // in flight the entry is `closing` and no longer reopenable. A pending window
  // that is gone from Hyprland for any other reason is pruned by the sweep's
  // clients probe, so status only ever counts grace windows that still exist.
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

    // Move the focused window to `workspace` with the given grace period (in
    // seconds) and grace look. Returns "requested"/"busy" now; the truthful
    // verdict is emitted on `result`.
    function hide(workspace: string, period: real, rounding: real, roundingPower: real, opacityFactor: real): string {
      return root.hide(workspace, period, rounding, roundingPower, opacityFactor)
    }

    // Bring the most recent window hidden into `workspace` back. Returns
    // "none"/"requested"/"busy" now; the verdict is emitted on `result`.
    function reopen(workspace: string): string {
      return root.reopen(workspace)
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
      const detail = (dispatchOut.text || "").trim()
      if (exitCode !== 0 || detail.indexOf("error") === 0) {
        console.warn(`grace-window: dispatch failed (exit ${exitCode}): ${detail}`)
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
  // Set by cancel() while a hide/reopen query is still in flight, so the
  // operation's finish handler aborts instead of applying after the
  // cancellation (hide() would otherwise resurrect a pending entry it already
  // cleared, reopen() would move a window back it just restored in place).
  property bool opCancelPending: false

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
  function hide(workspace, period, rounding, roundingPower, opacityFactor) {
    if (root.opBusy) return "busy"
    root.opBusy = true
    // The IPC period is given in seconds; the sweep counts in milliseconds.
    const graceMs = period * 1000
    root.runOpQuery(["bash", root.bashScript, "hide-query"]).then(
      function(raw) { root.finishHide(raw, workspace, graceMs, rounding, roundingPower, opacityFactor) },
      function(raw) { root.finishHide(raw, workspace, graceMs, rounding, roundingPower, opacityFactor) })
    return "requested"
  }

  function finishHide(raw, workspace, graceMs, rounding, roundingPower, opacityFactor) {
    if (root.opCancelPending) {
      root.opCancelPending = false
      root.opBusy = false
      root.reportOperation("hide", "none")
      return
    }
    const verdict = root.classifyHide(raw, workspace, graceMs, rounding, roundingPower, opacityFactor)
    root.opBusy = false
    root.reportOperation("hide", verdict)
  }

  function graceState(addr, graceOpacity, graceOpacityInactive, rounding, roundingPower) {
    root.setWindowFloat(addr, "off")
    root.setWindowFullscreen(addr, 0, 0)
    root.setWindowProp(addr, "opacity", graceOpacity)
    root.setWindowProp(addr, "opacity_inactive", graceOpacityInactive)
    root.setWindowProp(addr, "rounding", rounding)
    root.setWindowProp(addr, "rounding_power", roundingPower)
  }

  // Returns "ok" when a window was hidden, "none" when nothing was (no focused
  // window, a window already closing, or a window whose look could not be
  // captured exactly). The window lands on `workspace` — which also names the
  // FIFO buffer it is pushed onto — with the given grace period in
  // milliseconds and the given grace look.
  function classifyHide(raw, workspace, graceMs, rounding, roundingPower, opacityFactor) {
    const rec = root.parseJson(raw)
    if (!rec) return "none"
    const addr = rec.address || ""
    if (!addr) return "none"
    const existing = root.findPending(addr)
    if (existing && existing.closing) return "none"
    if (existing) {
      // Re-hiding restarts from a full grace period no matter the entry's
      // state: it always grants this call's time (so the pending seconds
      // status reports are this call's), cancels any queued auto-close,
      // un-expires a window that already ran out and resets its close-failure
      // count. The captured restore data is untouched.
      if (existing.closeTag) {
        root.cancelQueuedClose(existing.closeTag)
        existing.closeTag = ""
      }
      existing.expiring = false
      existing.closeFails = 0
      existing.remaining = graceMs
      root.rebuffer(existing, workspace)
      // Pull the window out of any tabbed group first, just like a fresh
      // hide, so re-hiding a window that has been regrouped doesn't drag the
      // whole group to the grace workspace.
      const grouped = Array.isArray(rec.grouped) ? rec.grouped : []
      if (grouped.length > 0) {
        root.dispatch(["bash", root.bashScript, "leave-group", addr, String(root.groupingDelay)])
      }
      // The window may be re-hidden into a different workspace than before:
      // move it — and its buffer entry — over to that workspace.
      // Reapply the grace look so a re-hide reflects this call's arguments:
      // the opacity is the captured (real) one scaled by the new
      // opacityFactor, and the corners are cut by the new rounding/power.
      const graceOpacity = existing.opacity * opacityFactor
      const graceOpacityInactive = existing.opacityInactive * opacityFactor
      if (existing.floating) root.setWindowPin(addr, "off")
      existing.graceOpacity = graceOpacity
      existing.graceOpacityInactive = graceOpacityInactive
      existing.graceRounding = rounding
      existing.graceRoundingPower = roundingPower
      root.moveToGraceWorkspace(addr, workspace)
      root.graceState(addr, graceOpacity, graceOpacityInactive, rounding, roundingPower)
      return "ok"
    }
    // Refuse windows that report no opacity or rounding values: the look
    // could not be restored faithfully on reopen, so better not hide at all.
    const opacity = rec.opacity || ""
    const opacityInactive = rec.opacityInactive || ""
    const capturedRounding = rec.rounding || ""
    const capturedRoundingPower = rec.roundingPower || ""
    if (opacity === "" || opacityInactive === "" || capturedRounding === "" || capturedRoundingPower === "") return "none"
    // A non-numeric getprop value would otherwise turn into a "NaN" prop value.
    const graceOpacity = Number(opacity) * opacityFactor
    const graceOpacityInactive = Number(opacityInactive) * opacityFactor
    if (isNaN(graceOpacity) || isNaN(graceOpacityInactive)) return "none"
    // Capture look, mode and geometry so reopen can restore them exactly.
    const entry = {
      address: addr,
      workspace: workspace,
      remaining: graceMs,
      opacity: Number(opacity),
      opacityInactive: Number(opacityInactive),
      rounding: Number(capturedRounding),
      roundingPower: Number(capturedRoundingPower),
      floating: rec.floating || false,
      fullscreen: rec.fullscreen || 0,
      fullscreenClient: rec.fullscreenClient || 0,
      pinned: rec.pinned || false,
      x: rec.x || 0,
      y: rec.y || 0,
      w: rec.w || 0,
      h: rec.h || 0,
      // The grace look actually applied at hide (dimmed opacity, cut corners).
      // Unlike the captured originals above — which reopen undoes — these are
      // what a startup restore must re-apply to bring the grace look back.
      graceOpacity: graceOpacity,
      graceOpacityInactive: graceOpacityInactive,
      graceRounding: rounding,
      graceRoundingPower: roundingPower,
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
    if (entry.floating) root.setWindowPin(addr, "off")
    root.moveToGraceWorkspace(addr, workspace)
    root.graceState(addr, graceOpacity, graceOpacityInactive, rounding, roundingPower)
    return "ok"
  }

  // Reports the final verdict of an asynchronous hide or reopen. No-ops are
  // the interesting ones: a "requested" handoff must not silently be a nothing.
  function reportOperation(op, verdict) {
    if (verdict !== "ok") {
      console.warn(`grace-window: ${op} finished with no effect (${verdict})`)
    }
    ipc.result(verdict)
  }

  // --------------------------------------------------------- reopen path
  // Reopen the most recent window hidden into `workspace` (its FIFO buffer).
  function reopen(workspace) {
    if (root.bufferLength(workspace) === 0) return "none"
    if (root.opBusy) return "busy"
    root.opBusy = true
    root.runOpQuery(["bash", root.bashScript, "reopen-query"]).then(
      function(raw) { root.finishReopen(raw, workspace) },
      function(raw) { root.finishReopen(raw, workspace) })
    return "requested"
  }

  function finishReopen(raw, workspace) {
    if (root.opCancelPending) {
      root.opCancelPending = false
      root.opBusy = false
      root.reportOperation("reopen", "none")
      return
    }
    const verdict = root.classifyReopen(raw, workspace)
    root.opBusy = false
    root.reportOperation("reopen", verdict)
  }

  // Returns "ok" when a window was reopened and restored, "none" when nothing
  // could be reopened (no reopenable entry in `workspace`'s buffer, or a query
  // answer too broken to act on). Applies to the FIFO buffer of the workspace
  // the windows were hidden into: the focused window is preferred when it is
  // in grace there; otherwise the most recently hidden one is reopened.
  function classifyReopen(raw, workspace) {
    const data = root.parseJson(raw)
    if (!data) return "none"
    const win = data.aw || {}
    const addr = win.address || ""
    // The focused window is only used below to prefer reopening it when it is
    // in grace and to pick the group to join on landing. Its absence (an
    // empty desktop, where hyprctl reports no window at all) is a normal case:
    // the newest hidden window is then reopened onto the active workspace (or
    // the active scratchpad when one is up).
    // The reopen target must be resolvable before any pending entry is
    // disturbed: an unparseable answer (e.g. a transient hyprctl failure
    // yielding an empty workspace) must not drop the chosen entry, whose
    // queued close would then be cancelled while the window stays hidden and
    // untracked forever.
    //
    // Target workspace: an active special workspace (the scratchpad, shown on
    // the focused monitor) is addressed by its "special:<name>" reference —
    // hyprctl activeworkspace keeps reporting the regular workspace underneath
    // the overlay, and a bare numeric special id does not resolve reliably. A
    // regular workspace keeps using its plain string id.
    const ws = data.ws || {}
    const special = data.sp || {}
    const specialName = special.name || ""
    let target = ""
    if (specialName.indexOf("special:") === 0) {
      target = specialName
    } else {
      const id = ws.id !== undefined && ws.id !== null ? ws.id : ""
      if (id !== "" && id !== null) target = id
    }
    if (target === "") return "none"
    // Prefer the focused window when it is in grace in `workspace`'s buffer;
    // otherwise reopen the most recently hidden one from there. Entries whose
    // close is already running (`closing`) are not reopened — their window is
    // lost either way.
    let index = -1
    if (addr) {
      for (let i = 0; i < root.pending.length; i++) {
        const entry = root.pending[i]
        if (entry.address !== addr || entry.closing || entry.workspace !== workspace) continue
        index = i
        break
      }
    }
    const entry = index !== -1 ? root.pending.splice(index, 1)[0] : root.popReopenable(workspace)
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
    root.restoreWindow(entry, target)
    // Join the group that had focus when reopening was triggered.
    root.dispatch([
      "bash", root.bashScript, "regroup",
      entry.address, win.address || "", String(root.groupingDelay),
    ])
    // Landed, regrouped (with its delay), look restored — end on the window
    // being focused, so the reopen lands the user where they left off.
    root.focusWindow(entry.address)
    return "ok"
  }

  function undoGraceState(entry) {
    // Undo what hide() did to the window's look — the lower opacity and the
    // cut corners — and the forced tiling/fullscreen/float mode changes. Never
    // restores the pin: hide() may have dropped it, but pinning is the last
    // step of a restore and must follow the move, so the callers handle it
    // (restoreWindow after the workspace move, restoreInPlace alongside the
    // in-place restore). Never touches the workspace, so the window stays
    // where it is (the grace workspace for a pending window, or the current
    // one when reopening).
    root.setWindowProp(entry.address, "opacity", entry.opacity)
    root.setWindowProp(entry.address, "opacity_inactive", entry.opacityInactive)
    root.setWindowProp(entry.address, "rounding", entry.rounding)
    root.setWindowProp(entry.address, "rounding_power", entry.roundingPower)
    if (entry.fullscreen > 0 || entry.fullscreenClient > 0) {
      root.setWindowFullscreen(entry.address, entry.fullscreen, entry.fullscreenClient)
    }
    if (entry.floating) root.setWindowFloat(entry.address, "on")
  }

  function restoreWindow(entry, workspaceId) {
    // Undo the grace look, then restore the captured mode and geometry. The
    // pin is restored last, only after the window sits on its target
    // workspace: a moved window must never be pinned mid-flight.
    root.undoGraceState(entry)
    if (entry.floating) {
      if (entry.w > 0 && entry.h > 0) root.resizeWindow(entry.address, entry.w, entry.h)
      root.moveWindowTo(entry.address, entry.x, entry.y)
    }
    root.moveWindowToWorkspace(entry.address, workspaceId)
    if (entry.pinned) root.setWindowPin(entry.address, "on")
  }

  // In-place restore for a window that stays where it is (cancel, give-up
  // close): undo the grace look and re-pin it, mirroring restoreWindow where
  // the pin always ends the restore. There is no move here, so it simply
  // follows the look undo.
  function restoreInPlace(entry) {
    root.undoGraceState(entry)
    if (entry.pinned) root.setWindowPin(entry.address, "on")
  }

  // ------------------------------------------------------ dispatch helpers
  // Thin dispatches into grace-window.lua, the single file holding every
  // hl.dsp call. A dispatch expression must evaluate to a dispatcher, so the
  // lua functions return their hl.dsp call.
  function luaDispatch(body, tag) {
    root.dispatch([
      "hyprctl", "dispatch",
      `dofile('${root.luaScript}').${body}`,
    ], tag)
  }

  function setWindowProp(addr, prop, value) {
    root.luaDispatch(`window_set_prop('${addr}', '${prop}', ${value})`)
  }

  function setWindowFloat(addr, action) {
    root.luaDispatch(`window_float('${addr}', '${action}')`)
  }

  function setWindowPin(addr, action) {
    root.luaDispatch(`window_pin('${addr}', '${action}')`)
  }

  function setWindowFullscreen(addr, internal, client) {
    root.luaDispatch(`window_fullscreen('${addr}', ${internal}, ${client})`)
  }

  function moveWindowToWorkspace(addr, workspace) {
    root.luaDispatch(`window_to_workspace('${addr}', '${workspace}')`)
  }

  function moveToGraceWorkspace(addr, workspace) {
    root.luaDispatch(`window_to_grace_workspace('${addr}', '${workspace}')`)
  }

  function moveWindowTo(addr, x, y) {
    root.luaDispatch(`window_to_position('${addr}', ${x}, ${y})`)
  }

  function resizeWindow(addr, w, h) {
    root.luaDispatch(`window_resize('${addr}', ${w}, ${h})`)
  }

  function focusWindow(addr) {
    root.luaDispatch(`window_focus('${addr}')`)
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

  // Count of pending windows hidden into `workspace` — the length of its FIFO
  // buffer. A reopen of a workspace with an empty buffer is a clean "none".
  function bufferLength(workspace) {
    let length = 0
    for (let i = 0; i < root.pending.length; i++) {
      if (root.pending[i].workspace === workspace) length++
    }
    return length
  }

  // Moves a pending entry into `workspace`'s FIFO buffer: it leaves its
  // previous buffer and lands at the newest end of the new one. Used when a
  // window is re-hidden into a different workspace than the one it was hiding
  // in, so a later reopen finds it under the right key.
  function rebuffer(entry, workspace) {
    if (entry.workspace === workspace) return
    for (let i = 0; i < root.pending.length; i++) {
      if (root.pending[i] !== entry) continue
      root.pending.splice(i, 1)
      break
    }
    entry.workspace = workspace
    root.pending.push(entry)
  }

  // Removes and returns the newest pending entry of `workspace`'s buffer that
  // is not having its close run right now, or null when none is reopenable.
  function popReopenable(workspace) {
    for (let i = root.pending.length - 1; i >= 0; i--) {
      const entry = root.pending[i]
      if (entry.closing || entry.workspace !== workspace) continue
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
        console.warn(`grace-window: giving up closing ${entry.address} after ${entry.closeFails} attempts; restoring its look in place`)
        root.restoreInPlace(entry)
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
          entry.closeTag = `close:${entry.address}`
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
    // Probe whether the hidden windows still exist, so a window that closed for
    // real by any means (not only through the sweep) leaves the pending list —
    // and stops crowding status — without waiting for its grace to run out.
    if (!livenessProc.running && root.pending.some(entry => !entry.closing && !entry.expiring)) {
      livenessProc.running = true
    }
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
    const addr = win.address || ""
    root.focusedAddress = addr === "0x0" ? "" : addr
  }

  // Every sweep lists all clients to learn which pending windows still exist.
  // A window that is gone (closed for real, crashed, closed elsewhere) can not
  // be reopened or closed by the sweep anymore — undoing its grace look is
  // meaningless since the window itself died with it — so its pending entry is
  // dropped and status keeps reporting only live grace windows.
  Process {
    id: livenessProc
    command: ["hyprctl", "-j", "clients"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onClientsRead(text)
    }
    // Arm the watchdog on every probe start and disarm it on completion, like
    // focusProc: a hung hyprctl must not wedge the probe so it never runs again.
    onRunningChanged: {
      if (livenessProc.running) {
        livenessTimeout.interval = root.queryTimeoutMs
        livenessTimeout.restart()
      } else {
        livenessTimeout.stop()
      }
    }
  }

  Timer {
    id: livenessTimeout
    interval: root.queryTimeoutMs
    repeat: false
    onTriggered: {
      console.warn("grace-window: clients probe timed out; aborting it")
      livenessProc.running = false
    }
  }

  function onClientsRead(raw) {
    const list = root.parseJson(raw)
    // Never trust an empty list to prune: an empty clients answer is far more
    // likely a transient query hiccup than a desktop with no windows at all.
    if (!Array.isArray(list) || list.length === 0) return
    const alive = new Set()
    for (const win of list) {
      if (win && win.address) alive.add(win.address)
    }
    for (let i = root.pending.length - 1; i >= 0; i--) {
      const entry = root.pending[i]
      if (entry.closing || entry.expiring) continue
      if (alive.has(entry.address)) continue
      console.warn(`grace-window: ${entry.address} no longer exists in Hyprland; dropping its pending entry`)
      root.pending.splice(i, 1)
    }
  }

  // ---------------------------------------------------------------- misc
  // Reports the most recent hidden window across every workspace's buffer.
  function status() {
    // An expired window still counts as pending: until its close actually
    // runs it can still be reopened (and cancel its own close).
    if (root.pending.length === 0) return "idle"
    const last = root.pending[root.pending.length - 1]
    const remaining = Math.ceil(last.remaining / 1000)
    return `pending ${remaining > 0 ? remaining : 0}s`
  }

  function cancel() {
    // Forget every pending window (of every workspace's buffer) without
    // closing it, restoring its grace look (and pin) in place. The windows
    // stay on the grace workspace; only reopen moves them back. Queued
    // auto-closes are cancelled so the windows really are left alone.
    root.cancelScheduledCloses()
    // A hide/reopen query already in flight would apply its effect after this
    // cancellation (classifyHide pushes a fresh pending entry, classifyReopen
    // moves a window). Flag it so the finish handler reports "none" instead.
    if (root.opBusy) root.opCancelPending = true
    for (let i = 0; i < root.pending.length; i++) {
      root.restoreInPlace(root.pending[i])
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
  // Where teardown saves the pending state and startup loads it again (see
  // "state persistence"): the pre-teardown buffers survive a shell restart or
  // hot-reload, restored for the windows that still exist on their saved grace
  // workspace. Lives next to the runtime scripts, which persist for the whole
  // user session.
  readonly property string stateFile: root.unwireRuntimeDir + "/state.json"
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

  // ------------------------------------------------------- state persistence
  // Teardown saves the pending state to the runtime dir; startup loads it to
  // restore the pre-teardown buffers. A shell restart or hot-reload therefore
  // keeps hidden windows in grace — their look, remaining time and the ability
  // to reopen them — instead of forgetting them. Only entries whose window
  // still exists AND still sits on the workspace it was hidden into are
  // restored: anything a user moved or closed while the service was down is
  // dropped by the startup probe. Entries already closing when teardown fires
  // cannot be saved (their close is in flight), and cancelled scheduled closes
  // are simply re-queued from the restored `remaining` (≤ 0 ⇒ `expiring`).

  // The persistable subset of pending: every entry whose window is still
  // reopenable (not closing). The transients that only mean something inside a
  // running service (closeTag, closeFails, the expiring flag) are derived anew
  // on load, so the file stays a stable snapshot of the captured state.
  function saveableEntries() {
    const out = []
    for (let i = 0; i < root.pending.length; i++) {
      const e = root.pending[i]
      if (e.closing) continue
      out.push({
        address: e.address,
        workspace: e.workspace,
        remaining: e.remaining,
        opacity: e.opacity,
        opacityInactive: e.opacityInactive,
        rounding: e.rounding,
        roundingPower: e.roundingPower,
        graceOpacity: e.graceOpacity,
        graceOpacityInactive: e.graceOpacityInactive,
        graceRounding: e.graceRounding,
        graceRoundingPower: e.graceRoundingPower,
        floating: e.floating,
        fullscreen: e.fullscreen,
        fullscreenClient: e.fullscreenClient,
        pinned: e.pinned,
        x: e.x,
        y: e.y,
        w: e.w,
        h: e.h,
      })
    }
    return out
  }

  // Saves the pending state for the next startup. Runs detached through the
  // runtime script, mirroring cancelDetached: on Component.onDestruction a
  // child Process could not outlive the service objects being torn down, and
  // the plugin directory may already be gone. No state is saved when nothing
  // is pending.
  function saveStateDetached() {
    const saveable = root.saveableEntries()
    if (saveable.length === 0) return
    const script = root.unwireInstalled ? root.unwireRuntimeScript : root.bashScript
    Quickshell.execDetached(["bash", script, "save-state",
      root.unwireRuntimeDir, JSON.stringify(saveable)])
  }

  // Startup: read the saved state and restore it for the windows that still
  // exist on their saved grace workspace. Reuses the op query machinery (via
  // opBusy) so the read, the clients probe and the restore dispatches cannot
  // interleave with a hide/reopen, and runOpQuery's watchdog covers the load
  // like any other query. A missing state file reads as empty and is a no-op.
  function loadState() {
    if (root.opBusy) {
      // Another query is in flight (e.g. a hot-reload landed mid-operation);
      // try again next turn instead of trampling it.
      Qt.callLater(root.loadState)
      return
    }
    root.opBusy = true
    root.opCancelPending = false
    root.runOpQuery(["cat", root.stateFile]).then(
      function(raw) { root.finishLoad(raw) },
      function(raw) { root.finishLoad(raw) })
  }

  // Parsed entries of the state file, held between the read query and the
  // deferred workspace probe so the latter can filter them.
  property var pendingSaved: []

  function finishLoad(raw) {
    root.pendingSaved = root.parseJson(raw)
    if (!Array.isArray(root.pendingSaved) || root.pendingSaved.length === 0) {
      // Nothing saved (or only with a close already running): stay empty.
      root.pendingSaved = []
      root.opCancelPending = false
      root.opBusy = false
      return
    }
    // Start the workspace probe on a fresh event-loop turn, so it never races
    // the just-finished read for the op process.
    Qt.callLater(root.loadStateProbe)
  }

  function loadStateProbe() {
    root.runOpQuery(["bash", root.bashScript, "state-probe"]).then(
      function(probeRaw) { root.restorePending(root.pendingSaved, probeRaw) },
      function(probeRaw) { root.restorePending(root.pendingSaved, probeRaw) })
  }

  // Rebuilds the pending list from the saved entries, keeping only windows the
  // probe reports as still alive on the workspace they were hidden into, then
  // re-applies their grace state (look, tiling, float/pin mode) so the desktop
  // matches the pre-teardown state. The grace countdown resumes where it left
  // off: the service's downtime is not charged to the windows.
  function restorePending(saved, probeRaw) {
    root.opCancelPending = false
    root.opBusy = false
    root.pendingSaved = []
    const probe = root.parseJson(probeRaw)
    if (!Array.isArray(probe)) return
    const whereabouts = new Map()
    for (let i = 0; i < probe.length; i++) {
      const p = probe[i]
      if (!p || !p.address) continue
      whereabouts.set(p.address, { id: p.workspace, name: p.name || "" })
    }
    const restored = []
    for (let i = 0; i < saved.length; i++) {
      const e = saved[i]
      if (!e || !e.address || !whereabouts.has(e.address)) continue
      const ws = String(e.workspace)
      const loc = whereabouts.get(e.address)
      if (ws !== String(loc.id) && ws !== loc.name) continue
      restored.push(e)
    }
    if (restored.length === 0) return
    console.log(`grace-window: restoring ${restored.length} pending window(s) in place from ${root.stateFile}`)
    for (let i = 0; i < restored.length; i++) {
      const e = restored[i]
      const remaining = Number(e.remaining) || 0
      const entry = {
        address: e.address,
        workspace: String(e.workspace),
        remaining: remaining,
        opacity: Number(e.opacity) || 0,
        opacityInactive: Number(e.opacityInactive) || 0,
        rounding: Number(e.rounding) || 0,
        roundingPower: Number(e.roundingPower) || 0,
        floating: !!e.floating,
        fullscreen: Number(e.fullscreen) || 0,
        fullscreenClient: Number(e.fullscreenClient) || 0,
        pinned: !!e.pinned,
        x: Number(e.x) || 0,
        y: Number(e.y) || 0,
        w: Number(e.w) || 0,
        h: Number(e.h) || 0,
        // The applied grace look, if the saved entry carries it; fall back to
        // the (un-dimmed) original so a stale file never injects NaN props.
        graceOpacity: root.savedLook(e, "graceOpacity", "opacity"),
        graceOpacityInactive: root.savedLook(e, "graceOpacityInactive", "opacityInactive"),
        graceRounding: root.savedLook(e, "graceRounding", "rounding"),
        graceRoundingPower: root.savedLook(e, "graceRoundingPower", "roundingPower"),
        closing: false,
        closeFails: 0,
        closeTag: "",
        expiring: remaining <= 0,
      }
      root.pending.push(entry)
      // Re-hide the window in place: it already sits on the grace workspace, so
      // only its look and mode need restoring, exactly like a fresh hide.
      if (entry.floating) root.setWindowPin(entry.address, "off")
      root.graceState(entry.address, entry.graceOpacity, entry.graceOpacityInactive,
        entry.graceRounding, entry.graceRoundingPower)
    }
  }

  // The saved applied grace value, or the fallback property when the state file
  // predates grace-look persistence (a number is always returned; NaN never
  // reaches the dispatching code).
  function savedLook(entry, prop, fallback) {
    const value = Number(entry[prop])
    if (!isNaN(value) && entry[prop] !== undefined && entry[prop] !== null) return value
    return Number(entry[fallback]) || 0
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
    // defer the wiring, the unwire-script copy, the state restore and the
    // dispatcher self-check until that property is set.
    root.lastTick = Date.now()
    Qt.callLater(root.wireBindings)
    Qt.callLater(root.installUnwireScript)
    Qt.callLater(root.loadState)
    Qt.callLater(root.selfCheck)
  }

  // The shell destroys this service when the plugin is disabled or removed,
  // so teardown cancels pending windows in place (restores their grace look),
  // saves the pending state for the next startup to restore, and unwires the
  // managed block — omarchy's plugin remove then leaves nothing behind. It also
  // fires on shell shutdown; the next start re-wires the block (a no-op when
  // already present) and restores the saved state.
  Component.onDestruction: {
    // Drop queued auto-closes first, so the detached grace-look undo below is
    // not immediately followed by the windows being closed for real. The saved
    // entries re-derive their expiry (remaining ≤ 0 ⇒ expiring) on load.
    root.cancelScheduledCloses()
    root.saveStateDetached()
    root.cancelDetached()
    root.unwireBindings()
  }
}
