// Grace Window — hide windows to a "grace" workspace with a reopen grace.
//
// IPC target: "grace-window"
//   hide(workspace, period, rounding, roundingPower, opacityFactor)
//              Move the focused window silently to `workspace` and start its
//              `period`-seconds grace: force it to plain tiling (no floating,
//              no fullscreen, no pin) and capture its look, mode and geometry
//              so reopen can restore them, then apply the grace look. In a
//              tabbed group only the focused window is pulled out. The grace
//              timer pauses while the hidden window keeps focus. Returns
//              "requested" when the operation is handed off, "busy" while
//              another hide/reopen/load is in flight, "none" when the
//              arguments are unusable (non-finite or negative period / grace
//              look values).
//   reopen(workspace)
//              Bring a window hidden into `workspace` back and focus it,
//              cancel its auto-close and restore its captured state. It lands
//              on the focused monitor's active special workspace (the
//              scratchpad) when one is shown, and on the active workspace
//              otherwise. The focused window is preferred when hidden;
//              otherwise the most recently hidden is reopened. A tiled
//              reopened window joins the group that currently has focus.
//              Returns "none" when nothing is pending, "requested"/"busy"
//              otherwise.
//   status()   "idle", or "pending <N>s" for the most recent live hidden
//              window.
//   cancel()   Forget every pending window without closing it, restoring its
//              grace look in place (the window stays on the grace workspace).
//              Teardown also does this, so a stopped service never leaves
//              pending windows behind with the grace look.
//   result()   Signal (not a call): the truthful final verdict of each hide or
//              reopen — "ok" when it did something, "none" when it could not.
//              IPC functions run synchronously, so a call can only report the
//              handoff; the outcome is emitted on this signal.
//
// Every hide target keeps its own FIFO of hidden windows — the `workspace`
// argument is both the destination and the buffer key. The keybindings carry
// the whole configuration (workspace, grace period and grace look); see the
// managed block in hypr/bindings.lua.
//
// Grace expiry closes the window through Hyprland's Lua dispatcher (>= 0.55)
// via scripts/grace-window.lua — the single file holding every hl.dsp call.
// The pending state is persisted across service lifecycles (teardown saves it
// to the runtime dir, startup restores the windows that still exist on their
// saved grace workspace). On start the managed keybinding block from
// hypr/bindings.lua is appended to ~/.config/hypr/bindings.lua (when missing);
// on teardown it is removed and the grace look of every pending window is
// restored in place. Scripts also answer hide()/reopen() queries with
// ready-to-use JSON and move windows in/out of tabbed groups.

import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  // ------------------------------------------------------------ configuration
  // Some apps need a beat to refresh their graphics after (un)grouping.
  // set to 0.0 for faster animations (may glitch graphics after (un)grouping)
  // set to 0.1 or higher for slower animations (prevent graphical glitches)
  readonly property double groupingDelay: 0.1

  // Auto-close attempts before giving up on a window whose close keeps failing
  // while it is still alive. Its grace look is then restored in place so it is
  // not left stranded looking pending.
  readonly property int closeRetryMax: 3

  // Time a runner command (hyprctl query, dispatch, probe) may take before it
  // is aborted. Without a watchdog a hung hyprctl would wedge the single
  // executor queue and lock the plugin into "busy" forever.
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

  // ------------------------------------------------------------ pending state
  // Pending hidden windows, newest last. Every entry names the workspace it
  // was hidden into (`workspace`); the entries of one workspace form its
  // private FIFO buffer, and hide()/reopen() only ever touch the buffer of the
  // workspace they are called with. A window's lifecycle is a small state
  // machine; `state` is one of:
  //   counting  grace counting down (paused while focused),
  //   expiring  grace ran out; its close is queued (or will be on the next
  //             sweep tick) and can still be cancelled by a reopen,
  //   closing   the close dispatch was handed to the executor; the window is
  //             no longer reopenable and leaves the list when the close
  //             reports success,
  //   restoring the entry is spliced out and held in `restoring` while its
  //             reopen dispatches run — the sweep cannot expire it and reopen
  //             cannot pick it again.
  // A pending window that is gone from Hyprland for any other reason is pruned
  // by the liveness probe, so status only ever counts grace windows that still
  // exist. `closeFails` counts consecutive failed close dispatches; after
  // closeRetryMax the graceful look is restored in place and the entry is
  // dropped instead of being stranded.
  property var pending: []

  // Entries currently being reopened, keyed by window address. Set when
  // classifyReopen splices an entry out of `pending`, cleared by settleRestore
  // once its last restore dispatch reported (or by finishRestoreVerify for a
  // failed restore being re-checked).
  property var restoring: {}

  // Addresses of entries whose restore was voided — by cancel(), or by a hide
  // superseding a window mid-reopen — so a late restore failure must never
  // resurrect them into pending (or onto a saved state). Grown deliberately
  // for the session: a few strings per event is nothing, pruning would only
  // race with straggler dispatches, and a reused address is only affected if
  // that new window also fails a restore while still covered (i.e. never in
  // practice).
  property var cancelled: new Set()

  // Bumped by cancel(); hide()/reopen()/loadState finish handlers compare the
  // epoch they captured at start so a cancellation landing mid-operation
  // aborts the operation instead of applying its effect afterwards.
  property int epoch: 0

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

    function hide(workspace: string, period: real, rounding: real, roundingPower: real, opacityFactor: real): string {
      return root.hide(workspace, period, rounding, roundingPower, opacityFactor)
    }

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

  // ------------------------------------------------------- the single executor
  // Every hyprctl call — window dispatch, hide/reopen query, startup load,
  // sweep probe — runs through ONE serial FIFO drained by one Process. A
  // command must run in the order it was asked for, so the queue is strict
  // FIFO; the sweep's sample probes and the operational queries all share it,
  // which removes the separate opBusy/opToken machinery and the class of races
  // between parallel runners entirely.
  //
  // Each item is { args, tag, onDone, done }. Tags let a reopen's restore be
  // attributed as a whole and the sweep's queued close be cancelled by a
  // reopen before it runs. onDone(ok, text) is the per-item outcome callback,
  // invoked exactly once (guarded by `done`); queries use it to resolve their
  // stdout, closes to report success/failure, restores to settle.
  //
  // A command that hangs is aborted by runnerTimeout: the process is killed
  // and the queue is held until the outcome is attributed — by the killed
  // process's own onExited, or by runnerAbortFallback (a safety net for the
  // case the killed process lingers without ever reporting). Only then does
  // the queue drain, so the newly started command can never inherit a stale
  // exit of the aborted one. A hung hyprctl therefore can never block the
  // queue forever.
  property var queue: []
  property var runningItem: null
  property bool abortPending: false
  // Sweep probes never stack: only one queued/running probe per key, so a
  // slow hyprctl cannot pile up probes behind the queue.
  property var probeInFlight: {}

  function run(args, opts) {
    const tag = (opts && opts.tag) || ""
    root.queue.push({
      args: args,
      tag: tag,
      onDone: opts && opts.onDone ? opts.onDone : null,
      done: false,
    })
    root.pump()
  }

  function pump() {
    // Hold the queue while an aborted command's outcome is still unattributed,
    // so the next command can never start — and overwrite runningItem — before
    // the aborted one is accounted for.
    if (runnerProc.running || root.abortPending || root.queue.length === 0) return
    const item = root.queue.shift()
    root.runningItem = item
    runnerProc.command = item.args
    // Only window_close dispatches gate a pending entry's transition to
    // `closing`: the mark must happen at the moment the close is handed to the
    // process, so a reopen can still cancel it while it waits in the queue.
    if (item.tag.indexOf("close:") === 0) root.markClosing(item.tag)
    runnerProc.running = true
  }

  // Attributes one item's outcome, at most once. No-op for the fire-and-forget
  // window ops (their failure is logged), which is what originally let an
  // opProc/dispatchProc separation be dropped.
  function attributeItem(item, failed, text) {
    if (!item || item.done) return
    item.done = true
    if (item.onDone) {
      item.onDone(!failed, text)
    } else if (failed) {
      const detail = (text || "").trim()
      console.warn(`grace-window: dispatch failed: ${detail || "non-zero exit"}`)
    }
  }

  Process {
    id: runnerProc
    running: false
    stdout: StdioCollector {
      id: runnerOut
      waitForEnd: true
    }
    // The queue is drained here, not via onRunningChanged: the outcome must be
    // attributed before the next command starts, and this signal is the one
    // place guaranteed to see each command's outcome exactly once. The drain is
    // deferred one event-loop turn so it never depends on the order in which
    // Quickshell flips `running` back to false around this signal.
    onRunningChanged: {
      if (runnerProc.running) {
        runnerTimeout.interval = root.queryTimeoutMs
        runnerTimeout.restart()
      } else {
        runnerTimeout.stop()
      }
    }
    onExited: function(exitCode, exitStatus) {
      if (!root.runningItem || root.runningItem.done) return
      runnerTimeout.stop()
      runnerAbortFallback.stop()
      const item = root.runningItem
      root.runningItem = null
      root.abortPending = false
      const text = (runnerOut.text || "").trim()
      const failed = exitCode !== 0 || text.indexOf("error") === 0
      root.attributeItem(item, failed, text)
      Qt.callLater(root.pump)
    }
  }

  // Watchdog for a hung command: the process is killed and the outcome is
  // attributed as a failure, so a close gets retried and the queue drains
  // again. Without this a stuck hyprctl would leave runnerProc.running true,
  // stranding the FIFO and every later dispatch, probe and regroup behind it.
  // pump() holds the queue while the outcome is unattributed (abortPending),
  // so runningItem stays the stalled command until attribute time.
  //
  // The kill is SIGKILL (signal 9), not just flipping `running` (which only
  // sends a catchable SIGTERM): an in-D-state hyprctl can otherwise hold off a
  // term for longer than the fallback window below, and its delayed onExited
  // would then attribute the next command that already started. SIGKILL dies
  // promptly and its onExited lands well inside the fallback window, so a
  // stale exit can no longer be mistaken for a later command's.
  Timer {
    id: runnerTimeout
    repeat: false
    onTriggered: {
      if (!runnerProc.running) return
      console.warn("grace-window: command timed out; aborting it")
      root.abortPending = true
      runnerProc.signal(9)
      runnerProc.running = false
      runnerAbortFallback.interval = Math.max(1000, root.queryTimeoutMs)
      runnerAbortFallback.restart()
    }
  }

  // Last-resort safety net for an aborted command whose onExited still never
  // arrives: attribute the running item as failed and drain the queue, so a
  // stuck dispatch can never block the FIFO forever. The onExited handler
  // clears abortPending when it does fire, so this only acts while the abort is
  // still unattributed. Keeping this fence as long as the command timeout gives
  // the SIGKILLed process (which exits in milliseconds) ample slack, making a
  // late ghost exit effectively impossible. The watchdog is not stopped here:
  // onRunningChanged already disarmed it when the abort flipped running back to
  // false, and it arms itself fresh for whichever command this drain starts.
  Timer {
    id: runnerAbortFallback
    repeat: false
    onTriggered: {
      if (!root.abortPending) return
      console.warn("grace-window: aborted command did not finish; discarding it")
      root.abortPending = false
      const item = root.runningItem
      root.runningItem = null
      root.attributeItem(item, true, null)
      Qt.callLater(root.pump)
    }
  }

  // Runs one command and resolves its stdout when it finishes. The promise is
  // settled from the item's onDone — never from the watchdog alone: on abort
  // the item resolves the JSON literal "null", which the defensive parsers in
  // the finish handlers bail out on exactly like an empty answer. Because the
  // queue is held until the abort is attributed, a query issued in the
  // meantime reports "busy" instead of silently receiving the aborted run's
  // stale output.
  function runOpQuery(args) {
    return new Promise(function (resolve) {
      root.run(args, {
        onDone: function (ok, text) { resolve(text === null ? "null" : text) },
      })
    })
  }

  // A one-shot probe, keyed so only one instance is queued at a time. The
  // parser runs on success; failure (or abort) is a silent no-op that keeps
  // whatever state the last successful probe produced.
  function enqueueProbe(key, args, parser) {
    if (root.probeInFlight[key]) return
    root.probeInFlight[key] = true
    root.run(args, {
      tag: "probe:" + key,
      onDone: function (ok, text) {
        delete root.probeInFlight[key]
        if (ok) parser(text)
      },
    })
  }

  // ----------------------------------------------------------- hide path
  // The IPC call hands off synchronously ("requested"), so the operation's
  // actual verdict is reported when the async query settles: classifyHide
  // classifies every outcome and reportOperation surfaces it on the `result`
  // IPC signal (and as a warning when nothing was hidden). An unusable call is
  // rejected up front with "none": a non-finite period (an NaN grace interval
  // would count down forever) or grace-look argument (a "NaN" prop value), or
  // a negative period, can only produce a window that never expires or a
  // malformed dispatch, so nothing is handed off for those.
  function hide(workspace, period, rounding, roundingPower, opacityFactor) {
    if (root.opInFlight > 0) return "busy"
    const args = [period, rounding, roundingPower, opacityFactor]
    for (let i = 0; i < args.length; i++) {
      if (!isFinite(args[i])) {
        console.warn("grace-window: hide rejected: non-finite argument")
        return "none"
      }
    }
    if (period < 0) {
      console.warn("grace-window: hide rejected: negative grace period")
      return "none"
    }
    root.opInFlight++
    const myEpoch = root.epoch
    // The IPC period is given in seconds; the sweep counts in milliseconds.
    const graceMs = period * 1000
    root.runOpQuery(["bash", root.bashScript, "hide-query"]).then(
      function (raw) {
        root.opInFlight--
        if (myEpoch !== root.epoch) {
          root.reportOperation("hide", "none")
          return
        }
        root.reportOperation("hide", root.classifyHide(
          raw, workspace, graceMs, rounding, roundingPower, opacityFactor))
      })
    return "requested"
  }

  // Number of hide/reopen/state-load operations currently in flight, counting
  // only their query phases (both the read and its dependent restore phase for
  // a load). Their restore dispatches queue behind them in the same FIFO, so
  // nothing can interleave.
  property int opInFlight: 0

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
    // A window that is currently being reopened (mid-restore) is superseded by
    // this hide: cancel its still-queued restore dispatches and drop the
    // restoring entry — but only while it is still the same object, so a
    // reopen that landed in between (re-keying the address to a fresh entry)
    // is never torn down. The pending entry created below captures the state
    // from here on; a restore dispatch already handed to the Process settles
    // later against the removed entry and does nothing.
    const wasRestoring = root.restoring[addr]
    if (wasRestoring) {
      root.cancelRestore(addr)
      if (root.restoring[addr] === wasRestoring) delete root.restoring[addr]
    }
    const existing = root.findPending(addr)
    if (existing && existing.state === "closing") return "none"
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
      existing.state = "counting"
      existing.closeFails = 0
      existing.remaining = graceMs
      root.rebuffer(existing, workspace)
      // Pull the window out of any tabbed group first, just like a fresh
      // hide, so re-hiding a window that has been regrouped doesn't drag the
      // whole group to the grace workspace.
      const grouped = Array.isArray(rec.grouped) ? rec.grouped : []
      if (grouped.length > 0) {
        root.dispatchOps(["bash", root.bashScript, "leave-group", addr, String(root.groupingDelay)])
      }
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
    // The captured originals get the same guard: a bogus rounding power would
    // otherwise flow into restore dispatches as a bare "NaN" Lua token.
    const capturedRoundingValue = Number(capturedRounding)
    const capturedRoundingPowerValue = Number(capturedRoundingPower)
    if (isNaN(capturedRoundingValue) || isNaN(capturedRoundingPowerValue)) return "none"
    // Capture look, mode and geometry so reopen can restore them exactly.
    const entry = {
      address: addr,
      workspace: workspace,
      remaining: graceMs,
      opacity: Number(opacity),
      opacityInactive: Number(opacityInactive),
      rounding: capturedRoundingValue,
      roundingPower: capturedRoundingPowerValue,
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
      state: "counting",
      closeFails: 0,
      closeTag: "",
    }
    root.pending.push(entry)
    // Pull the window out of any tabbed group first, so only it is hidden.
    const grouped = Array.isArray(rec.grouped) ? rec.grouped : []
    if (grouped.length > 0) {
      root.dispatchOps(["bash", root.bashScript, "leave-group", addr, String(root.groupingDelay)])
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
    if (root.opInFlight > 0) return "busy"
    root.opInFlight++
    const myEpoch = root.epoch
    root.runOpQuery(["bash", root.bashScript, "reopen-query"]).then(
      function (raw) {
        root.opInFlight--
        if (myEpoch !== root.epoch) {
          root.reportOperation("reopen", "none")
          return
        }
        root.reportOperation("reopen", root.classifyReopen(raw, workspace))
      })
    return "requested"
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
    // empty desktop, where hyprctl reports no window at all) is a normal case.
    // The reopen target must be resolvable before any pending entry is
    // disturbed: an unparseable answer must not drop the chosen entry, whose
    // queued close would then be cancelled while the window stays hidden and
    // untracked forever.
    //
    // Target workspace: an active special workspace (the scratchpad, shown on
    // the focused monitor) is addressed by its "special:<name>" reference; a
    // regular workspace keeps using its plain string id.
    const ws = data.ws || {}
    const special = data.sp || {}
    const specialName = special.name || ""
    const id = ws.id !== undefined && ws.id !== null ? ws.id : ""
    let target = ""
    if (specialName.indexOf("special:") === 0) {
      target = specialName
    } else if (id !== "") {
      target = id
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
        if (entry.address !== addr || entry.state === "closing" || entry.workspace !== workspace) continue
        index = i
        break
      }
    }
    const entry = index !== -1 ? root.pending.splice(index, 1)[0] : root.popReopenable(workspace)
    if (!entry) return "none"
    // If the chosen window's grace expired and the sweep already queued its
    // close, cancel that close now — otherwise it would fire right after the
    // restore dispatches and close the window just brought back. A close that
    // is already running cannot be undone (inherent). On a failed restore the
    // re-queued entry re-derives its state from `remaining` (≤ 0 ⇒ expiring).
    if (entry.closeTag) {
      root.cancelQueuedClose(entry.closeTag)
      entry.closeTag = ""
    }
    // Hold the entry out of the pending list while the restore runs, tagging
    // every restore dispatch "restore:<address>" so settleRestore can settle
    // once the queue holds no further command with the tag. While held, the
    // sweep cannot expire it, the liveness probe cannot prune it and reopen
    // cannot pick it again.
    const restoreTag = "restore:" + entry.address
    entry.state = "restoring"
    root.restoring[entry.address] = entry
    root.restoreWindow(entry, target, restoreTag)
    // Join the group that had focus when reopening was triggered.
    root.dispatchRestore([
      "bash", root.bashScript, "regroup",
      entry.address, win.address || "", String(root.groupingDelay),
    ], restoreTag)
    // Landed, regrouped (with its delay), look restored — end on the window
    // being focused, so the reopen lands the user where they left off.
    root.focusWindow(entry.address, restoreTag)
    return "ok"
  }

  // Queues one dispatch that is part of a reopen's restore: every such
  // dispatch carries the same "restore:<address>" tag and settles the reopen
  // when it completes. settleRestore runs for each of them, but only settles
  // once the queue holds no remaining command with the tag.
  function dispatchRestore(args, tag) {
    root.run(args, {
      tag: tag,
      onDone: function (ok, text) {
        if (!ok) console.warn(`grace-window: a restore dispatch failed: ${(text || "").trim() || "non-zero exit"}`)
        root.settleRestore(tag, ok)
      },
    })
  }

  function undoGraceState(entry, tag) {
    // Undo what hide() did to the window's look — the lower opacity and the
    // cut corners — and the forced tiling/fullscreen/float mode changes. Never
    // restores the pin: hide() may have dropped it, but pinning is the last
    // step of a restore and must follow the move, so the callers handle it.
    // Never touches the workspace, so the window stays where it is.
    root.setWindowProp(entry.address, "opacity", entry.opacity, tag)
    root.setWindowProp(entry.address, "opacity_inactive", entry.opacityInactive, tag)
    root.setWindowProp(entry.address, "rounding", entry.rounding, tag)
    root.setWindowProp(entry.address, "rounding_power", entry.roundingPower, tag)
    if (entry.fullscreen > 0 || entry.fullscreenClient > 0) {
      root.setWindowFullscreen(entry.address, entry.fullscreen, entry.fullscreenClient, tag)
    }
    if (entry.floating) root.setWindowFloat(entry.address, "on", tag)
  }

  function restoreWindow(entry, workspaceId, tag) {
    // Undo the grace look, then restore the captured mode and geometry. The
    // pin is restored last, only after the window sits on its target
    // workspace: a moved window must never be pinned mid-flight.
    root.undoGraceState(entry, tag)
    if (entry.floating) {
      if (entry.w > 0 && entry.h > 0) root.resizeWindow(entry.address, entry.w, entry.h, tag)
      root.moveWindowTo(entry.address, entry.x, entry.y, tag)
    }
    root.moveWindowToWorkspace(entry.address, workspaceId, tag)
    if (entry.pinned) root.setWindowPin(entry.address, "on", tag)
  }

  // In-place restore for a window that stays where it is (cancel, give-up
  // close): undo the grace look and re-pin it, mirroring restoreWindow where
  // the pin always ends the restore. Untagged dispatches; the operations all
  // share the executor FIFO.
  function restoreInPlace(entry) {
    root.undoGraceState(entry)
    if (entry.pinned) root.setWindowPin(entry.address, "on")
  }

  // Settles the in-flight reopen of the entry in `restoring[address]`. A
  // success keeps the entry out for good (the window is back); a failure
  // verifies where the window actually is before the entry is re-queued, so a
  // window that did land (only a trailing dispatch failed) is never closed by
  // a stale expiry.
  function settleRestore(tag, success) {
    if (tag.indexOf("restore:") !== 0) return
    const address = tag.slice("restore:".length)
    const entry = root.restoring[address]
    if (!entry) return
    for (let i = 0; i < root.queue.length; i++) {
      if (root.queue[i].tag === tag) return  // more restore dispatches queued; keep waiting
    }
    delete root.restoring[address]
    if (success) {
      console.log(`grace-window: reopened ${entry.address}`)
      return
    }
    // A re-hide of the same window since the reopen started supersedes this
    // entry: classifyHide captured it fresh, so dropping this one is right.
    if (root.findPending(entry.address)) return
    // A cancelled service must not resurrect the entry, and a window that
    // actually left its grace workspace must not be re-armed for closing.
    if (root.cancelled.has(entry.address)) return
    console.warn(`grace-window: reopen of ${entry.address} failed; verifying where it is`)
    root.startRestoreVerify(entry)
  }

  // A failed reopen is re-checked with a clients probe before the entry is
  // re-queued: only a window that is still on its saved grace workspace counts
  // as still pending (its close is re-armed). A window that made it back
  // somewhere else — or is gone — drops the entry, so a near-successful reopen
  // is never followed by the sweep closing the very window the user just saw
  // land. The entry is held in `restoring` (keyed by address, checked by
  // identity) until the probe answers.
  function startRestoreVerify(entry) {
    root.restoring[entry.address] = entry
    root.run(["hyprctl", "-j", "clients"], {
      tag: "verify:" + entry.address,
      onDone: function (ok, text) { root.finishRestoreVerify(entry, ok ? text : null) },
    })
  }

  function finishRestoreVerify(entry, text) {
    if (root.restoring[entry.address] !== entry) return  // superseded meanwhile
    delete root.restoring[entry.address]
    if (root.cancelled.has(entry.address)) return
    if (root.findPending(entry.address)) return
    let onGrace = false
    const list = root.parseJson(text)
    if (Array.isArray(list)) {
      for (let i = 0; i < list.length; i++) {
        const win = list[i]
        if (!win || win.address !== entry.address) continue
        const wid = win.workspace && win.workspace.id !== undefined && win.workspace.id !== null
          ? String(win.workspace.id) : (win.workspace || "")
        const name = win.workspace && win.workspace.name ? String(win.workspace.name) : ""
        if (wid === String(entry.workspace) || name === String(entry.workspace)) onGrace = true
        break
      }
    }
    if (onGrace) {
      console.warn(`grace-window: reopen of ${entry.address} failed; window still on its grace workspace; keeping it pending`)
      root.pending.push(entry)
      entry.state = entry.remaining <= 0 ? "expiring" : "counting"
      entry.closeTag = ""
      entry.closeFails = 0
    } else {
      // Someone still in grace or not on it anymore — untracked either way,
      // so no pending close is armed for it.
      console.warn(`grace-window: reopen of ${entry.address} failed but it is not on its grace workspace; dropping its pending entry`)
    }
  }

  // ------------------------------------------------------ dispatch helpers
  // Thin dispatches into grace-window.lua, the single file holding every
  // hl.dsp call. A dispatch expression must evaluate to a dispatcher, so the
  // lua functions return their hl.dsp call.
  function dispatchOps(args) {
    root.run(args)
  }

  function luaDispatch(body, tag) {
    if (tag) {
      root.run(["hyprctl", "dispatch", `dofile('${root.luaScript}').${body}`], { tag: tag })
    } else {
      root.dispatchOps(["hyprctl", "dispatch", `dofile('${root.luaScript}').${body}`])
    }
  }

  // Quotes a value for interpolation into a Lua single-quoted string literal,
  // so a workspace name (or any other string) containing a quote or backslash
  // can never break the dispatch expression into a syntax error that silently
  // no-ops the operation. Only string values need this; the numeric prop values
  // are validated to be finite before they reach a dispatch.
  function luaString(value) {
    return String(value).replace(/\\/g, "\\\\").replace(/'/g, "\\'")
  }

  function setWindowProp(addr, prop, value, tag) {
    root.luaDispatch(`window_set_prop('${root.luaString(addr)}', '${prop}', ${value})`, tag)
  }

  function setWindowFloat(addr, action, tag) {
    root.luaDispatch(`window_float('${root.luaString(addr)}', '${action}')`, tag)
  }

  function setWindowPin(addr, action, tag) {
    root.luaDispatch(`window_pin('${root.luaString(addr)}', '${action}')`, tag)
  }

  function setWindowFullscreen(addr, internal, client, tag) {
    root.luaDispatch(`window_fullscreen('${root.luaString(addr)}', ${internal}, ${client})`, tag)
  }

  function moveWindowToWorkspace(addr, workspace, tag) {
    root.luaDispatch(`window_to_workspace('${root.luaString(addr)}', '${root.luaString(workspace)}')`, tag)
  }

  function moveToGraceWorkspace(addr, workspace, tag) {
    root.luaDispatch(`window_to_grace_workspace('${root.luaString(addr)}', '${root.luaString(workspace)}')`, tag)
  }

  function moveWindowTo(addr, x, y, tag) {
    root.luaDispatch(`window_to_position('${root.luaString(addr)}', ${x}, ${y})`, tag)
  }

  function resizeWindow(addr, w, h, tag) {
    root.luaDispatch(`window_resize('${root.luaString(addr)}', ${w}, ${h})`, tag)
  }

  function focusWindow(addr, tag) {
    root.luaDispatch(`window_focus('${root.luaString(addr)}')`, tag)
  }

  // ------------------------------------------------------------- close path
  // The sweep queues a window_close when a window's grace ran out. The tagged
  // command can be cancelled by a reopen (or re-hide) while it still waits in
  // the queue; once handed to the process the entry becomes `closing` and the
  // outcome is attributed by tag when the command reports.
  function queueClose(entry, tag) {
    root.run(["bash", root.bashScript, "close", entry.address], {
      tag: tag,
      onDone: function (ok, text) {
        if (!ok) console.warn(`grace-window: close dispatch failed: ${(text || "").trim() || "non-zero exit"}`)
        // The entry may have been replaced by a re-hide since (a fresh entry
        // carries a fresh closeTag), so re-find it by tag.
        if (ok) root.closeStarted(tag)
        else root.closeAborted(tag)
      },
    })
  }

  // A tagged window_close has just been handed to the Process. The window can
  // not be reopened anymore from here on (the cancel race is only the few
  // milliseconds the dispatch itself takes), so flag the entry `closing`.
  function markClosing(tag) {
    for (let i = 0; i < root.pending.length; i++) {
      if (root.pending[i].closeTag !== tag) continue
      root.pending[i].state = "closing"
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
      entry.closeTag = ""
      entry.state = "expiring"
      entry.closeFails = (entry.closeFails || 0) + 1
      if (entry.closeFails >= root.closeRetryMax) {
        console.warn(`grace-window: giving up closing ${entry.address} after ${entry.closeFails} attempts; restoring its look in place`)
        root.restoreInPlace(entry)
        root.pending.splice(i, 1)
        return
      }
      return
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
    // Iterate over a snapshot: queueing a close inside the loop hands the
    // command to the executor, which marks live entries and a completing
    // dispatch splices them, shifting the live array's indices.
    const snapshot = root.pending.slice()
    for (let i = 0; i < snapshot.length; i++) {
      const entry = snapshot[i]
      // An expired window is closed for real regardless of focus. If its close
      // is not queued yet, queue it now — the extra sweep interval between
      // flagging it and this dispatch is the window in which a reopen can
      // cancel before the close is ever submitted.
      if (entry.state === "expiring") {
        if (!entry.closeTag) {
          entry.closeTag = `close:${entry.address}`
          root.queueClose(entry, entry.closeTag)
        }
        continue
      }
      // While the hidden window keeps focus its grace timer is paused.
      if (entry.address === root.focusedAddress) continue
      entry.remaining -= delta
      if (entry.remaining > 0) continue
      // Grace ran out: flag the window for real closing. A reopen that lands
      // within the next sweep interval still wins — the close is only
      // submitted on a later tick, and once submitted it starts promptly.
      entry.state = "expiring"
    }
    // Sample the focused window for the next tick's pause decisions, and probe
    // whether the hidden windows still exist, so a window that closed for real
    // by any means leaves the pending list without waiting for its grace to
    // run out. Both are fire-and-forget; they never stack.
    root.enqueueProbe("focus", ["hyprctl", "-j", "activewindow"], function (text) {
      root.onFocusRead(text)
    })
    if (root.pending.some(entry => entry.state === "counting")) {
      root.enqueueProbe("clients", ["hyprctl", "-j", "clients"], function (text) {
        root.onClientsRead(text)
      })
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
      if (entry.state === "closing" || entry.state === "expiring") continue
      if (alive.has(entry.address)) continue
      console.warn(`grace-window: ${entry.address} no longer exists in Hyprland; dropping its pending entry`)
      root.pending.splice(i, 1)
    }
  }

  // ---------------------------------------------------------------- cancel
  // Forget every pending window (of every workspace's buffer) without closing
  // it, restoring its grace look (and pin) in place. The windows stay on the
  // grace workspace; only reopen moves them back. Queued auto-closes are
  // cancelled so the windows really are left alone. The now-empty pending
  // state is persisted too, so a later restart cannot resurrect a cancelled
  // (or close-given-up) window from a stale state file and re-arm its close.
  function cancel() {
    // Invalidate every operation that is still in flight so its finish
    // handler reports "none" instead of applying after the cancellation.
    root.epoch++
    root.cancelScheduledCloses()
    for (let i = 0; i < root.pending.length; i++) {
      root.restoreInPlace(root.pending[i])
    }
    // A restore already in flight would otherwise settle back into pending
    // after the cancellation — record its address so settleRestore and the
    // verify probe drop it instead of resurrecting it with an auto-close.
    for (const address of Object.keys(root.restoring)) {
      root.cancelled.add(address)
    }
    // The windows currently being reopened are left to their restores; the
    // service simply forgets them.
    root.pending = []
    // Persist the (now empty) pending state, clearing any stale state.json,
    // while the restoring entries are recorded in `cancelled`.
    root.saveStateDetached()
    return "ok"
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

  // Cancels every queued "restore:<address>" command, used when the window a
  // reopen is restoring gets re-hidden: its pending restore dispatches would
  // otherwise still pull it back to the workspace it is being moved away from.
  // A restore dispatch already handed to the Process cannot be undone, but it
  // settles against the already-removed `restoring` entry and drops harmlessly.
  function cancelRestore(address) {
    const tag = "restore:" + address
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
      if (entry.state === "closing" || !entry.closeTag) continue
      root.cancelQueuedClose(entry.closeTag)
      entry.closeTag = ""
    }
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
      if (entry.state === "closing" || entry.workspace !== workspace) continue
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

  // Reports the most recent live hidden window across every workspace's
  // buffer. An expired window still counts as pending: until its close
  // actually runs it can still be reopened (and cancel its own close).
  function status() {
    for (let i = root.pending.length - 1; i >= 0; i--) {
      const entry = root.pending[i]
      if (entry.state === "closing") continue
      const remaining = Math.ceil(entry.remaining / 1000)
      return `pending ${remaining > 0 ? remaining : 0}s`
    }
    return "idle"
  }

  // --------------------------------------------------------- keybinding wiring
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
  // teardown runs that copy, falling back to the plugin's own script when the
  // copy has not completed yet (see teardownScript).
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

  // The teardown commands (unwire, undo-grace, save-state, and the restart's
  // own reload of the bindings) prefer this stable runtime copy of the scripts,
  // which survives omarchy removing the plugin directory on disable. Before
  // installUnwireScript ran to completion — the service can be torn down within
  // a second of starting — the plugin's own script is used as a best-effort
  // fallback instead of failing closed: better to clean up with the original
  // than to leave the managed block and grace looks behind.
  function teardownScript() {
    return root.unwireInstalled ? root.unwireRuntimeScript : root.bashScript
  }

  function unwireBindings() {
    const target = Quickshell.env("HOME") + "/.config/hypr/bindings.lua"
    if (!root.unwireInstalled) {
      console.warn("grace-window: unwire script not installed; using plugin script as fallback")
    }
    Quickshell.execDetached(["bash", root.teardownScript(), "unwire",
      target,
      root.bindingsBlockBgn,
      root.bindingsBlockEnd])
  }

  // Teardown variant of cancel(): restores the grace look of every pending and
  // half-restored (restoring) window in place (they stay where they are). Runs
  // detached through the cleaned-up teardown script, for the same reason as
  // unwireBindings: on Component.onDestruction a child Process could not outlive
  // the service objects being torn down, and the plugin directory may already
  // be gone.
  function cancelDetached() {
    const all = root.teardownEntries()
    if (all.length === 0) return
    if (!root.unwireInstalled) {
      console.warn("grace-window: unwire script not installed; using plugin script as fallback")
    }
    Quickshell.execDetached(["bash", root.teardownScript(), "undo-grace",
      JSON.stringify(all)])
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
  // are simply re-queued from the restored `remaining` (≤ 0 ⇒ `expiring`). An
  // empty pending set is saved as an empty state, which clears the file: a
  // window forgotten by cancel() (or given up after closeRetryMax) must never
  // be resurrected into pending with a re-armed auto-close on the next start.

  // Every entry teardown must account for: the pending windows plus the windows
  // currently being reopened (`restoring`). A restoring entry is by definition
  // not fully restored (its dispatches never ran to completion), so teardown
  // treats it exactly like a pending one: its look is undone in place and its
  // state saved, so the next startup either reclaims it (the window still sits
  // on its grace workspace) or drops it (its reopen had already moved it back).
  function teardownEntries() {
    const all = []
    for (let i = 0; i < root.pending.length; i++) all.push(root.pending[i])
    for (const address of Object.keys(root.restoring)) all.push(root.restoring[address])
    return all
  }

  // The persistable subset of teardownEntries: every entry whose window is
  // still reopenable (not closing) and was not forgotten by cancel() (its
  // address is in `cancelled`). The transients that only mean something
  // inside a running service (closeTag, closeFails, the state flag) are derived
  // anew on load, so the file stays a stable snapshot of the captured state.
  function saveableEntries() {
    const out = []
    const all = root.teardownEntries()
    for (let i = 0; i < all.length; i++) {
      const e = all[i]
      if (e.state === "closing") continue
      if (root.cancelled.has(e.address)) continue
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

  // Saves the pending state for the next startup, atomically, through the
  // runtime script. Runs detached, mirroring cancelDetached: on
  // Component.onDestruction a child Process could not outlive the service
  // objects being torn down. An empty state (nothing pending, or a cancel()
  // that forgot everything) sends the empty array so the script clears (or
  // keeps cleared) state.json — a stale save must never resurrect forgotten
  // windows or re-arm their auto-close on the next start.
  function saveStateDetached() {
    const saveable = root.saveableEntries()
    Quickshell.execDetached(["bash", root.teardownScript(), "save-state",
      root.unwireRuntimeDir, JSON.stringify(saveable)])
  }

  // Retries loadState while another op is in flight; a bounded tick instead of
  // a busy Qt.callLater spin.
  Timer {
    id: loadRetryTimer
    interval: 500
    repeat: false
    onTriggered: root.loadState()
  }

  // Startup: read the saved state and restore it for the windows that still
  // exist on their saved grace workspace. Runs through the shared executor,
  // so the read, the clients probe and the restore dispatches are serialized
  // with every hide/reopen and carried by the same watchdog. A missing state
  // file reads as empty and is a no-op. If a cancel lands mid-load the epoch
  // test drops the rest silently.
  function loadState() {
    if (root.opInFlight > 0) {
      // Another query is in flight (e.g. a hot-reload landed mid-operation);
      // retry on the next sweep tick instead of spinning each event loop turn.
      loadRetryTimer.restart()
      return
    }
    root.opInFlight++
    const myEpoch = root.epoch
    root.runOpQuery(["cat", root.stateFile]).then(
      function (raw) {
        const saved = root.parseJson(raw)
        if (myEpoch !== root.epoch || !Array.isArray(saved) || saved.length === 0) {
          root.opInFlight--
          return
        }
        // Probe which saved windows still exist on their grace workspace.
        root.runOpQuery(["bash", root.bashScript, "state-probe"]).then(
          function (probeRaw) {
            root.opInFlight--
            if (myEpoch !== root.epoch) return
            root.restorePending(saved, probeRaw)
          })
      })
  }

  // Rebuilds the pending list from the saved entries, keeping only windows the
  // probe reports as still alive on the workspace they were hidden into, then
  // re-applies their grace state (look, tiling, float/pin mode) so the desktop
  // matches the pre-teardown state. The grace countdown resumes where it left
  // off: the service's downtime is not charged to the windows.
  function restorePending(saved, probeRaw) {
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
        state: remaining <= 0 ? "expiring" : "counting",
        closeFails: 0,
        closeTag: "",
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
  // so teardown cancels pending windows in place (restores their grace look —
  // including windows that were mid-reopen, whose queued restore dispatches die
  // with the executor), saves the pending state for the next startup to
  // restore, and unwires the managed block — omarchy's plugin remove then
  // leaves nothing behind. It also fires on shell shutdown; the next start
  // re-wires the block (a no-op when already present) and restores the saved
  // state, reclaiming any window that is still on its grace workspace.
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