// Grace Window — hide windows to a "grace" workspace with a reopen grace.
//
// IPC target "grace-window":
//   hide(workspace, period, rounding, roundingPower, opacityFactor)
//     Move the focused window silently to `workspace` and start its grace:
//     force plain tiling, capture look/mode/geometry, apply the grace look.
//     Returns "requested" while in flight, "busy" while another op runs,
//     "none" for unusable arguments.
//   reopen(workspace)  Bring the window back, cancel its auto-close and
//     restore its captured state, rejoining the focused tabbed group. It lands
//     on the active workspace (or an open scratchpad on the focused monitor),
//     and a floating window keeps its place within the monitor it lands on.
//   cancel()  Forget every pending window, restoring its grace look in place.
//   status()  "idle", or "pending <N>s" for the most recent live hidden window.
//   result()  Signal with the real verdict of each hide/reopen — "ok" or
//     "none" — since the calls themselves only report the handoff.
//
// The `workspace` argument is both the destination and the key of a window's
// private FIFO buffer; the keybindings carry the whole configuration (see the
// managed block in hypr/bindings.lua). Expiry closes windows through
// scripts/grace-window.lua, the single file holding every hl.dsp call. Pending
// state survives service lifecycles (saved on teardown, restored on start);
// the managed keybinding block is wired into ~/.config/hypr/bindings.lua on
// start and removed on teardown, a block customized there captured to
// hypr/bindings-custom.lua first and preferred over the plugin's default on
// the next start.
//
// Focus, liveness and workspace moves are tracked from Hyprland's event socket
// (Quickshell's Hyprland rawEvent) instead of polling, so the grace timer only
// counts down and never queries the compositor; the one startup focus query
// seeds it because events only fire on changes.

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland

Item {
  id: root

  // ------------------------------------------------------------ configuration
  // The values below are the shipped defaults. On first start the service writes
  // them to config.json next to this file (untracked and gitignored) and reads
  // that file on every start, so they can be edited there without touching the
  // plugin. A later edit is picked up live (see reloadConfig). Every entry is
  // validated; an absent, mistyped or out-of-range value falls back to its
  // default here. See README.md.

  // Delay after (un)grouping so apps refresh their graphics, in milliseconds;
  // 0 is snappier, higher values prevent glitches after (un)grouping.
  property int groupingDelayMs: 100

  // Failed close attempts before giving up; the look is then restored in place
  // so the window is not left stranded looking pending.
  property int closeRetryMax: 3

  // A runner command is aborted after this; a hung hyprctl must not wedge the
  // single executor queue and lock the plugin into "busy" forever.
  property int queryTimeoutMs: 10000

  // Startup retries, each after loadRetryIntervalMs, waiting for the keybinding
  // wiring to finish before the saved state is loaded (see loadState).
  property int loadWaitLimit: 40

  // Grace countdown tick rate, and the cadence of the startup-load retry.
  property int sweepIntervalMs: 500
  property int loadRetryIntervalMs: 500

  // How long the shell script may wait for one bounded read-only open, in
  // milliseconds. Passed to the script through the environment (see
  // scriptEnvironment).
  property int openWaitMs: 5000

  // ------------------------------------------------------------ the plugin dir
  // Source path wired by the shell via `manifest`; falls back to the standard
  // install location.
  property var manifest: null
  readonly property string sourceDir:
    root.manifest && root.manifest.__sourceDir
      ? root.manifest.__sourceDir
      : Quickshell.env("HOME") + "/.config/omarchy/plugins/jam.grace-window"

  readonly property string scriptsDir: root.sourceDir + "/scripts"
  readonly property string bashScript: root.scriptsDir + "/grace-window.sh"
  readonly property string luaScript: root.scriptsDir + "/grace-window.lua"

  // The user-editable configuration, next to the shipped files. Untracked and
  // gitignored, so `omarchy plugin update` neither commits nor trips over it.
  // Written with the shipped defaults on first start and read on every start
  // (see applyConfig).
  readonly property string configFile: root.sourceDir + "/config.json"

  // ------------------------------------------------------------ pending state
  // Pending hidden windows, newest last. `workspace` groups them into private
  // FIFO buffers that hide()/reopen() touch. `state` is one of:
  //   counting   grace counting down (paused while focused),
  //   expiring   grace ran out; the close is queued but a reopen can still win,
  //   closing    the close dispatch runs; the entry leaves on success,
  //   restoring  held in `restoring` while its reopen dispatches run.
  // Windows gone from Hyprland are pruned by its closewindow event. `closeFails`
  // counts consecutive failed closes; past closeRetryMax the look is restored
  // in place and the entry is dropped instead of stranded.
  property var pending: []

  // Entries being reopened, keyed by address: set when a reopen splices one
  // out of `pending`, cleared once its last restore dispatch settles.
  property var restoring: ({})

  // Addresses whose restore was voided (cancel(), or a re-hide mid-reopen), so
  // a late restore failure never resurrects them into pending or a saved state.
  property var cancelled: new Set()

  // Bumped by cancel() so in-flight ops see the bump and abort instead of
  // applying their effect afterwards.
  property int epoch: 0

  // Last sweep tick and focused window's address; the grace timer pauses while
  // a hidden window holds focus.
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
  // startup focus query — runs through ONE serial FIFO drained by one Process.
  // A command must run in the order it was asked for, so the queue is strict
  // FIFO and the operational queries all share it, which removes the separate
  // opBusy/opToken machinery and the class of races between parallel runners
  // entirely.
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
  // exit of the aborted one. A hung hyprctl can therefore never block the
  // queue forever — modulo the one case no watchdog can fix: an OS that never
  // reaps the SIGKILLed process holds the FIFO until it (eventually) does.
  property var queue: []
  property var runningItem: null
  property bool abortPending: false

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
    // Settle a reopen once its last tagged dispatch completes, not just when
    // the single `regroup` item's onDone fires: the trailing focus dispatch
    // carries the same tag and is still queued at that moment, so the one
    // settle attempt would bail on the queue scan and never be called again —
    // leaving every reopened window tracked in `restoring` until teardown.
    const tag = item.tag || ""
    if (tag.indexOf("restore:") === 0 && !item.onDone) {
      root.settleRestore(tag, !failed)
    }
  }

  Process {
    id: runnerProc
    running: false
    stdout: StdioCollector {
      id: runnerOut
      waitForEnd: true
    }
    // Drain here — the one signal guaranteed to fire for every command exactly
    // once — so the outcome is attributed before the next command starts.
    // Deferred one loop turn so it never depends on the order in which
    // Quickshell flips `running` around this signal.
    onRunningChanged: {
      if (runnerProc.running) {
        runnerTimeout.interval = root.queryTimeoutMs
        runnerTimeout.restart()
      } else {
        runnerTimeout.stop()
        // A process that never started (its binary is missing) reports no
        // `exited` — Quickshell's Process has no QML error signal for it — only
        // this running=false. A normal finish emits `exited` first, which has
        // already cleared runningItem, so an item still unattributed here is a
        // failed start: attribute it so its promise settles and opInFlight
        // clears, instead of the queue silently advancing past it forever.
        if (root.runningItem && !root.runningItem.done) {
          console.warn("grace-window: command failed to start; attributing it as failed")
          const item = root.runningItem
          root.runningItem = null
          root.abortPending = false
          root.attributeItem(item, true, null)
        }
        // onExited normally pumps; this self-heals the late-ghost abort case,
        // where the fallback already attributed the item and the delayed
        // onExited early-returns without queueing a pump.
        Qt.callLater(root.pump)
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

  // Watchdog for a hung command: SIGKILL the process and attribute the item as
  // a failure so the queue drains. A catchable SIGTERM can be held off by an
  // in-D-state hyprctl, and its delayed onExited could be attributed to the
  // next command that already started. The one lasting wedge left is the OS
  // never reaping the killed process: `running` tracks the process handle and
  // only clears on its finish, so no userland watchdog can drain past it.
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

  // Safety net if a SIGKILLed process's onExited never arrives: attribute the
  // item as failed so its promise resolves and opInFlight clears, instead of
  // leaving it raised forever. Only acts while the abort is unattributed,
  // since onExited clears abortPending. It is deliberately not disarmed by the
  // abort itself: `running = false` only asks the process to terminate, so
  // `running` stays true (and the queue held) until the child is actually
  // reaped, and the timer stays armed until onExited stops it on the real
  // exit, or it fires once and drops the item.
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

  // Runs one command, resolving its stdout from the item's onDone. On abort it
  // resolves "null", which the defensive parsers bail out on like any empty
  // answer.
  function runOpQuery(args) {
    return new Promise(function (resolve) {
      root.run(args, {
        onDone: function (ok, text) { resolve(text === null ? "null" : text) },
      })
    })
  }

  // ----------------------------------------------------------- hide path
  // The call hands off synchronously; the real verdict surfaces on the `result`
  // signal. Unusable arguments are rejected up front: a NaN or negative period
  // would count down forever, a NaN look argument would dispatch a "NaN" prop.
  function hide(workspace, period, rounding, roundingPower, opacityFactor) {
    if (root.opInFlight > 0) return "busy"
    const args = [period, rounding, roundingPower, opacityFactor]
    for (let i = 0; i < args.length; i++) {
      // == first: isFinite(null) coerces to 0 and would let it slip through as
      // an instant-expiry hide.
      if (args[i] == null || !isFinite(args[i])) {
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

  // Hide/reopen/load operations in flight (query phases only). Their restore
  // dispatches queue behind them in the same FIFO, so nothing interleaves.
  property int opInFlight: 0

  // Enforces the grace look. `fullscreenClient` is the fullscreen state the
  // client believes in, passed through so it is NEVER reset: telling a client
  // it left fullscreen makes it exit its own fullscreen (e.g. a browser's DOM
  // fullscreen), and re-forcing client fullscreen on reopen cannot re-enter it
  // — the app's own fullscreen key (YouTube's F) is then ignored and the window
  // stays stuck in fullscreen until the compositor resets it. Only the internal
  // state (how Hyprland lays the window out) is reset, forcing it back to
  // tiling; the client's belief survives the hide and reopens in sync.
  function graceState(addr, fullscreenClient, graceOpacity, graceOpacityInactive, rounding, roundingPower) {
    root.setWindowFloat(addr, "off")
    root.setWindowFullscreen(addr, 0, fullscreenClient)
    root.setWindowProp(addr, "opacity", graceOpacity)
    root.setWindowProp(addr, "opacity_inactive", graceOpacityInactive)
    root.setWindowProp(addr, "rounding", rounding)
    root.setWindowProp(addr, "rounding_power", roundingPower)
  }

  // Verdict: "ok" when a window was hidden, "none" when there was no focused
  // window, one already closing, or a look that could not be captured exactly.
  function classifyHide(raw, workspace, graceMs, rounding, roundingPower, opacityFactor) {
    const rec = root.parseJson(raw)
    if (!rec) return "none"
    const addr = rec.address || ""
    if (!addr) return "none"
    // Re-hiding a window mid-reopen supersedes that restore: cancel its
    // queued restore dispatches and drop the restoring entry — unless a reopen
    // re-keyed the address meanwhile (identity check). A dispatch already
    // handed to the Process settles against the removed entry and does nothing.
    const wasRestoring = root.restoring[addr]
    if (wasRestoring) {
      root.cancelRestore(addr)
      if (root.restoring[addr] === wasRestoring) delete root.restoring[addr]
    }
    const existing = root.findPending(addr)
    if (existing && existing.state === "closing") return "none"
    if (existing) {
      // Re-hide restarts a full grace period: grants this call's time, cancels
      // any queued auto-close, un-expires an already-expired window and resets
      // its close-failure count. The captured restore data is untouched.
      if (existing.closeTag) {
        root.cancelQueuedClose(existing.closeTag)
        existing.closeTag = ""
      }
      existing.state = "counting"
      existing.closeFails = 0
      existing.remaining = graceMs
      // A re-hide that switches buffers (another workspace's workflow) sends the
      // window on a fresh move, so its settled flag resets like a fresh hide;
      // the movewindowv2 event of that move re-arms it once it lands on the new
      // grace workspace.
      const rebuffered = existing.workspace !== workspace
      root.rebuffer(existing, workspace)
      if (rebuffered) existing.settled = false
      // The client-side fullscreen is captured fresh too: it must mirror the
      // state the window believes in right now (it is never reset while it
      // hides), so a hidden window whose client changed its own fullscreen is
      // captured as it is.
      existing.fullscreenClient = rec.fullscreenClient || 0
      // As in a fresh hide: pull it out of any tabbed group so the whole group
      // is not dragged to the grace workspace.
      const grouped = Array.isArray(rec.grouped) ? rec.grouped : []
      if (grouped.length > 0) {
        root.dispatchOps(["bash", root.bashScript, "leave-group", addr, String(root.groupingDelayMs)])
      }
      // Reapply the look from this call's args (real opacity scaled by the new
      // opacityFactor, corners cut by the new rounding/power).
      const graceOpacity = existing.opacity * opacityFactor
      const graceOpacityInactive = existing.opacityInactive * opacityFactor
      if (existing.floating) root.setWindowPin(addr, "off")
      existing.graceOpacity = graceOpacity
      existing.graceOpacityInactive = graceOpacityInactive
      existing.graceRounding = rounding
      existing.graceRoundingPower = roundingPower
      root.hideMove(existing, workspace)
      root.graceState(addr, existing.fullscreenClient, graceOpacity, graceOpacityInactive, rounding, roundingPower)
      return "ok"
    }
    // Never hide a window whose look cannot be restored faithfully on reopen.
    const opacity = rec.opacity || ""
    const opacityInactive = rec.opacityInactive || ""
    const capturedRounding = rec.rounding || ""
    const capturedRoundingPower = rec.roundingPower || ""
    if (opacity === "" || opacityInactive === "" || capturedRounding === "" || capturedRoundingPower === "") return "none"
    // A non-numeric getprop value would otherwise dispatch a bare "NaN" prop.
    const graceOpacity = Number(opacity) * opacityFactor
    const graceOpacityInactive = Number(opacityInactive) * opacityFactor
    if (isNaN(graceOpacity) || isNaN(graceOpacityInactive)) return "none"
    // Restore unsets rounding rather than re-setting it, so the originals are
    // never dispatched; they are still captured and validated only so a broken
    // getprop answer fails this hide instead of silently skipping the guard.
    const capturedRoundingValue = Number(capturedRounding)
    const capturedRoundingPowerValue = Number(capturedRoundingPower)
    if (isNaN(capturedRoundingValue) || isNaN(capturedRoundingPowerValue)) return "none"
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
      // The origin of the monitor the position was captured on (null when the
      // monitors answer did not name it). restorePosition translates x/y from
      // it to the monitor a reopen lands on, so a floating window keeps its
      // place within the monitor instead of moving to another one's
      // coordinates.
      monitorX: typeof rec.monitorX === "number" ? rec.monitorX : null,
      monitorY: typeof rec.monitorY === "number" ? rec.monitorY : null,
      w: rec.w || 0,
      h: rec.h || 0,
      // The applied grace look (dimmed, corners cut) — what a startup restore
      // must re-apply, unlike the captured originals above, which reopen undoes.
      graceOpacity: graceOpacity,
      graceOpacityInactive: graceOpacityInactive,
      graceRounding: rounding,
      graceRoundingPower: roundingPower,
      state: "counting",
      closeFails: 0,
      closeTag: "",
      // False until the window is observed on its grace workspace: straight
      // from the capture when it already sits there, otherwise from the
      // movewindowv2 event of the hide's own move dispatch. While false an
      // away move is ignored only while that dispatch is still queued (it then
      // is the hide migration, not a user relocation); a move without one in
      // flight means the hide never took (see onWindowMoved).
      settled: root.onGracePosition(rec, workspace),
    }
    root.pending.push(entry)
    const grouped = Array.isArray(rec.grouped) ? rec.grouped : []
    if (grouped.length > 0) {
      root.dispatchOps(["bash", root.bashScript, "leave-group", addr, String(root.groupingDelayMs)])
    }
    if (entry.floating) root.setWindowPin(addr, "off")
    root.hideMove(entry, workspace)
    root.graceState(addr, entry.fullscreenClient, graceOpacity, graceOpacityInactive, rounding, roundingPower)
    return "ok"
  }

  // Verdict of an async hide/reopen; no-ops warn so "requested" never silently
  // means nothing.
  function reportOperation(op, verdict) {
    if (verdict !== "ok") {
      console.warn(`grace-window: ${op} finished with no effect (${verdict})`)
    }
    ipc.result(verdict)
  }

  // --------------------------------------------------------- reopen path
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

  // Verdict: "ok" when a window was restored, "none" when the buffer held no
  // reopenable entry or the query answer was too broken to act on. The focused
  // window wins when it is in grace in `workspace`'s buffer, else the newest
  // entry.
  function classifyReopen(raw, workspace) {
    const data = root.parseJson(raw)
    if (!data) return "none"
    const win = data.aw || {}
    const addr = win.address || ""
    // Resolve the reopen target (an open special workspace — the scratchpad,
    // addressed as "special:<name>" — or the plain active-workspace id) before
    // touching any entry: a broken answer must not drop the chosen one, whose
    // queued close would be cancelled while the window stays hidden and
    // untracked forever. A missing focused window (empty desktop) is normal.
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
    // The monitor the window lands on is the focused one: `target` is its
    // active workspace, or the special workspace shown on it. Its origin
    // translates a captured position, so a floating window reopens at the same
    // place within that monitor. Null when the monitors answer named none (a
    // broken answer), and restorePosition then falls back to the captured
    // absolute position.
    const monitorX = typeof data.mx === "number" ? data.mx : null
    const monitorY = typeof data.my === "number" ? data.my : null
    // Prefer the focused window when it is in grace here; else take the newest
    // reopenable entry. Windows already `closing` are lost either way.
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
    // If the sweep already queued its close, cancel it now — it would otherwise
    // fire right after the restore. A close already running cannot be undone.
    // On a failed restore the state re-derives from `remaining` (≤ 0 ⇒
    // expiring).
    if (entry.closeTag) {
      root.cancelQueuedClose(entry.closeTag)
      entry.closeTag = ""
    }
    // Hold the entry in `restoring` while its tagged dispatches run: the sweep
    // cannot expire it, Hyprland's closewindow event cannot prune it and
    // reopen cannot
    // pick it again until the last tagged dispatch settles.
    const restoreTag = "restore:" + entry.address
    entry.state = "restoring"
    entry.restoreFailed = false
    root.restoring[entry.address] = entry
    root.restoreWindow(entry, target, restoreTag, monitorX, monitorY)
    // Join the group that had focus when reopening was triggered.
    root.dispatchRestore([
      "bash", root.bashScript, "regroup",
      entry.address, win.address || "", String(root.groupingDelayMs),
    ], restoreTag)
    // End with the window focused, so the reopen lands the user where they left
    // off.
    root.focusWindow(entry.address, restoreTag)
    return "ok"
  }

  // A restore dispatch carries the reopen's "restore:<address>" tag; settle
  // only once no tagged command stays queued.
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
    // Undo only the grace look — opacity back to the captured originals and
    // rounding/rounding_power unset. Rounding is unset rather than re-set: a
    // captured literal would override the dynamic rules (like the pop tag rule)
    // for the rest of the window's life, while the pre-hide rounding was
    // rule-derived in the first place. Modes (float/fullscreen) and geometry
    // are left untouched: only a reopen — which moves the window back — may
    // restore them; an in-place restore (cancel / give-up close / teardown)
    // never changes what the hide forced, so the window just sits where it is,
    // looking normal again.
    root.setWindowProp(entry.address, "opacity", entry.opacity, tag)
    root.setWindowProp(entry.address, "opacity_inactive", entry.opacityInactive, tag)
    root.unsetWindowProp(entry.address, "rounding", tag)
    root.unsetWindowProp(entry.address, "rounding_power", tag)
    root.resetWindowRules(entry.address, tag)
  }

  function restoreWindow(entry, workspaceId, tag, monitorX, monitorY) {
    // Undo the grace look, restore mode and size, move onto the target
    // workspace, then position and pin. A known target position is applied
    // after the workspace move: Hyprland's move-to-workspace preserves a
    // floating window's monitor-relative position, so an absolute move applied
    // first would be translated a second time and land at the wrong place.
    // Nothing gets pinned mid-flight while a moved window is still on its way.
    root.undoGraceState(entry, tag)
    if (entry.fullscreen > 0 || entry.fullscreenClient > 0) {
      // Restore the internal fullscreen. `fullscreenClient` was never reset by
      // the plugin (the hide only forces internal back to tiling), so it still
      // mirrors what the client believes and is restored unchanged — the app's
      // own fullscreen toggle (e.g. a browser's F) stays in sync and works.
      root.setWindowFullscreen(entry.address, entry.fullscreen, entry.fullscreenClient, tag)
    }
    if (entry.floating) {
      root.setWindowFloat(entry.address, "on", tag)
      if (entry.w > 0 && entry.h > 0) root.resizeWindow(entry.address, entry.w, entry.h, tag)
    }
    const position = entry.floating ? root.restorePosition(entry, monitorX, monitorY) : null
    // Without known monitor origins the position is absolute for whatever
    // monitor the window was captured on, so it must go before the workspace
    // move, where Hyprland translates it relative to the monitor it leaves
    // (the pre-capture-origin behaviour).
    if (position && !position.known) root.moveWindowTo(entry.address, position.x, position.y, tag)
    root.moveWindowToWorkspace(entry.address, workspaceId, tag)
    if (position && position.known) root.moveWindowTo(entry.address, position.x, position.y, tag)
    if (entry.pinned) root.setWindowPin(entry.address, "on", tag)
  }

  // The absolute position a floating window reopens at: its captured position
  // translated from the monitor it was hidden on to the monitor it reopens on,
  // so it keeps the same place within the monitor. `known` is false when
  // either monitor origin is unknown — an older saved state, or a monitors
  // answer that did not name the monitor — and x/y are the captured absolute
  // position then.
  function restorePosition(entry, monitorX, monitorY) {
    if (typeof entry.monitorX !== "number" || typeof entry.monitorY !== "number"
        || typeof monitorX !== "number" || typeof monitorY !== "number") {
      return { x: entry.x, y: entry.y, known: false }
    }
    return {
      x: monitorX + (entry.x - entry.monitorX),
      y: monitorY + (entry.y - entry.monitorY),
      known: true,
    }
  }

  // In-place restore for cancel / give-up close / teardown: only the grace look
  // goes away. No moves, no pin, and no mode or geometry changes — the window
  // stays exactly where the hide left it (on the grace workspace), just looking
  // normal again. Ending the auto-close is the caller's job (cancelScheduledCloses);
  // a pinned window is never re-pinned here because it would silently move to
  // the focused workspace instead of staying on the grace one.
  function restoreInPlace(entry) {
    root.undoGraceState(entry)
  }

  // Full reopen minus every move: for a pending window that left its grace
  // workspace on its own (see onWindowMoved) — the user already relocated it,
  // so unlike restoreInPlace this also gives back the window's captured mode,
  // size and pin (the force-tiling of grace goes away again), but unlike
  // restoreWindow it never moves it to the workspace it was hidden from and
  // never repositions it: the window stays exactly where the user put it.
  function reopenInPlace(entry) {
    root.undoGraceState(entry)
    if (entry.fullscreen > 0 || entry.fullscreenClient > 0) {
      root.setWindowFullscreen(entry.address, entry.fullscreen, entry.fullscreenClient)
    }
    if (entry.floating) {
      root.setWindowFloat(entry.address, "on")
      if (entry.w > 0 && entry.h > 0) root.resizeWindow(entry.address, entry.w, entry.h)
    }
    if (entry.pinned) root.setWindowPin(entry.address, "on")
  }

  // Settles the in-flight reopen of the entry in `restoring[address]`. Success
  // keeps the entry out for good (the window is back); a failure verifies
  // where the window actually is before re-queuing, so one that did land (only
  // a trailing dispatch failed) is never closed by a stale expiry. Failures
  // accumulate on the shared entry across the tagged dispatches as they settle
  // one by one, so any failed restore dispatch — not just the last one to
  // settle — decides whether the reopen really landed the window.
  function settleRestore(tag, success) {
    if (tag.indexOf("restore:") !== 0) return
    const address = tag.slice("restore:".length)
    const entry = root.restoring[address]
    if (!entry) return
    // Record the failure before the early return, so a bad move is not masked
    // by the next dispatch settling successfully.
    if (!success) entry.restoreFailed = true
    for (let i = 0; i < root.queue.length; i++) {
      if (root.queue[i].tag === tag) return  // more restore dispatches queued; keep waiting
    }
    delete root.restoring[address]
    if (!entry.restoreFailed) {
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

  // A failed reopen is re-checked with a clients probe before re-queuing: only
  // a window still on its saved grace workspace counts as pending again (its
  // close is re-armed); one that made it back elsewhere — or is gone — drops
  // the entry, so a near-successful reopen is never followed by closing the
  // window the user just saw land. Held in `restoring` until the probe answers.
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
      entry.restoreFailed = false
      entry.settled = true
      // The restore already undid the grace look, so re-apply it — a pending
      // window must not look normal while its auto-close is armed.
      if (entry.floating) root.setWindowPin(entry.address, "off")
      root.graceState(entry.address, entry.fullscreenClient, entry.graceOpacity, entry.graceOpacityInactive,
        entry.graceRounding, entry.graceRoundingPower)
    } else {
      // Not on its grace workspace anymore — untracked, so no close is armed.
      console.warn(`grace-window: reopen of ${entry.address} failed but it is not on its grace workspace; dropping its pending entry`)
    }
  }

  // ------------------------------------------------------ dispatch helpers
  // Thin dispatches into grace-window.lua, the single file holding every hl.dsp
  // call. A dispatch expression must evaluate to a dispatcher, so each lua
  // function returns its hl.dsp call.
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

  // Escapes a value for a Lua single-quoted literal so a quote or backslash in
  // a workspace name can never break the dispatch into a silent no-op. Only
  // strings need this; numeric props were validated finite up front.
  function luaString(value) {
    return String(value).replace(/\\/g, "\\\\").replace(/'/g, "\\'")
  }

  function setWindowProp(addr, prop, value, tag) {
    root.luaDispatch(`window_set_prop('${root.luaString(addr)}', '${prop}', ${value})`, tag)
  }

  // Removes a per-window setprop override again, so the window returns to the
  // look its (dynamic) window rules derive — e.g. re-applying Omarchy's
  // rounding=8 pop rule when SUPER+O tags a window. Re-setting the captured
  // value instead would pin the property and quiet any rule that has to react
  // to future state changes. `unset` is only accepted for the numeric props;
  // opacity has no unset path, so it is restored by value.
  function unsetWindowProp(addr, prop, tag) {
    root.luaDispatch(`window_set_prop('${root.luaString(addr)}', '${prop}', 'unset')`, tag)
  }

  // Re-runs a window's dynamic window rules. A setprop on a numeric prop (like
  // rounding) writes through COverridableVar's operator=, which also discards
  // the window-rule copy of the value; our "unset" alone therefore leaves rule
  // look (e.g. a popped window's rounding=8) missing until a tag change forces
  // a re-evaluation. Cycling a throwaway static tag makes Hyprland re-apply the
  // matching rules, then removes itself, so no tag remains.
  function resetWindowRules(addr, tag) {
    root.luaDispatch(`window_tag('${root.luaString(addr)}', '+grace-window-recheck')`, tag)
    root.luaDispatch(`window_tag('${root.luaString(addr)}', '-grace-window-recheck')`, tag)
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

  // The hide's own move to its grace workspace, tagged so liveness can tell a
  // queued migration from a real relocation (see onWindowMoved). Its failure is
  // attributed: a hide whose move failed before the window was ever observed on
  // the grace workspace means the hide did not happen, so the grace look is
  // restored in place and the entry dropped — never a force-close on the
  // workspace the window actually sits on.
  function hideMove(entry, workspace) {
    root.run(["hyprctl", "dispatch", `dofile('${root.luaScript}').window_to_grace_workspace('${root.luaString(entry.address)}', '${root.luaString(workspace)}')`], {
      tag: "hidemove:" + entry.address,
      onDone: function (ok) {
        if (ok) return
        if (root.hideMovePending(entry.address)) return  // a fresh move is still coming
        if (root.findPending(entry.address) !== entry) return  // superseded meanwhile
        if (entry.settled) return  // observed on the grace workspace; the move was redundant
        root.hidePlaceFailed(entry)
      },
    })
  }

  // Whether a hide-move for `address` is still queued or running: the window is
  // on its way to its grace workspace and an away event is the migration.
  function hideMovePending(address) {
    const tag = "hidemove:" + address
    if (root.runningItem && root.runningItem.tag === tag) return true
    for (let i = 0; i < root.queue.length; i++) {
      if (root.queue[i].tag === tag) return true
    }
    return false
  }

  // A hide never reached its grace workspace (failed move dispatch, or a
  // movewindowv2 away with no hide-move in flight). Undo the grace look in
  // place, cancel any queued close and drop the entry — the window stays where
  // it is, looking normal, untracked and unarmed.
  function hidePlaceFailed(entry) {
    for (let i = 0; i < root.pending.length; i++) {
      if (root.pending[i] !== entry) continue
      if (entry.closeTag) {
        root.cancelQueuedClose(entry.closeTag)
        entry.closeTag = ""
      }
      console.warn(`grace-window: ${entry.address} never reached its grace workspace; restoring its grace look in place and dropping its pending entry`)
      root.restoreInPlace(entry)
      root.pending.splice(i, 1)
      return
    }
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
  // The sweep queues a window_close when a window's grace ran out. A reopen or
  // re-hide cancels it while it still waits in the queue; once handed to the
  // process the entry becomes `closing` and the outcome is attributed by tag.
  function queueClose(entry, tag) {
    root.run(["bash", root.bashScript, "close", entry.address], {
      tag: tag,
      onDone: function (ok, text) {
        if (!ok) console.warn(`grace-window: close dispatch failed: ${(text || "").trim() || "non-zero exit"}`)
        // A re-hide may have replaced the entry since; re-find it by tag.
        if (ok) root.closeStarted(tag)
        else root.closeAborted(tag)
      },
    })
  }

  // A tagged window_close just got handed to the Process — the window can no
  // longer be reopened from here on — so flag the entry `closing`.
  function markClosing(tag) {
    for (let i = 0; i < root.pending.length; i++) {
      if (root.pending[i].closeTag !== tag) continue
      root.pending[i].state = "closing"
      return
    }
  }

  // A tagged window_close reported success: the window is gone — drop its entry.
  function closeStarted(tag) {
    for (let i = 0; i < root.pending.length; i++) {
      if (root.pending[i].closeTag !== tag) continue
      root.pending.splice(i, 1)
      return
    }
  }

  // A tagged window_close failed while the window is still alive (the close
  // command only reports failure for a live address), so hand it back to the
  // sweep for a retry. Past closeRetryMax the window is left alone: its look
  // is restored in place and the entry dropped.
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
    id: sweepTimer
    interval: root.sweepIntervalMs
    repeat: true
    running: true
    onTriggered: root.sweep()
  }

  function sweep() {
    const now = Date.now()
    if (root.pending.length === 0) {
      // Keep the anchor fresh so the first countdown after a new hide starts
      // from a full grace period.
      root.lastTick = now
      return
    }
    const delta = now - root.lastTick
    root.lastTick = now
    // Snapshot: a completing close splices the live array while this runs.
    const snapshot = root.pending.slice()
    for (let i = 0; i < snapshot.length; i++) {
      const entry = snapshot[i]
      // A close already handed to the process owns the entry's fate; one
      // expired but still queued stays expiring until a reopen or a
      // movewindow-away rescues it before the close dispatches.
      if (entry.state === "expiring" || entry.state === "closing") continue
      // The timer pauses while the hidden window holds focus.
      if (entry.address === root.focusedAddress) continue
      entry.remaining -= delta
      if (entry.remaining > 0) continue
      // Grace ran out: flag for closing. A reopen landing within a sweep
      // interval still wins — the close is only submitted on a later tick.
      entry.state = "expiring"
    }
    // Queue each expiring auto-close. A reopen or a movewindow-away still
    // cancels one while it waits; `closing` only marks when pump() hands the
    // close to the process, so the queued close stays cancellable its whole
    // wait. Liveness and workspace tracking come from Hyprland's events, so
    // the sweep itself never queries the compositor.
    for (let i = 0; i < root.pending.length; i++) {
      const entry = root.pending[i]
      if (entry.state !== "expiring" || entry.closeTag) continue
      entry.closeTag = `close:${entry.address}`
      root.queueClose(entry, entry.closeTag)
    }
  }

  // ------------------------------------------------------- Hyprland events
  // Focus, liveness and workspace moves arrive as push events from Quickshell's
  // Hyprland socket, so the sweep no longer samples the compositor every tick.
  Connections {
    target: Hyprland
    function onRawEvent(event) { root.onHyprEvent(event) }
  }

  function onHyprEvent(event) {
    const name = event && event.name ? String(event.name) : ""
    if (name === "activewindowv2") {
      root.focusedAddress = root.eventAddress(event)
    } else if (name === "closewindow") {
      root.onWindowClosed(root.eventAddress(event))
    } else if (name === "movewindowv2") {
      // Only movewindowv2, never the legacy movewindow: both fire per move, but
      // movewindow carries (address, workspaceName) while this handler reads
      // (address, workspaceId, workspaceName), which would misplace the name in
      // the id slot for custom-named workspaces. movewindowv2 is the disambiguated
      // form and has existed since before Hyprland 0.55.
      root.onWindowMoved(event)
    }
  }

  // Hyprland's event socket sends addresses as bare lowercase hex
  // (e.g. "5fba0c5f"), while hyprctl's JSON answers embed the same address
  // with a "0x" prefix. Normalize so the two always compare equal.
  function eventAddress(event) {
    let addr = ""
    try {
      if (event && event.parse) {
        const parts = event.parse(1)
        if (parts && parts.length > 0) addr = parts[0]
      }
    } catch (e) { }
    return root.normalizeAddress(addr)
  }

  function normalizeAddress(address) {
    address = String(address || "").trim()
    if (address === "" || address === "0" || address === "0x0") return ""
    if (address.indexOf("0x") === 0 || address.indexOf("0X") === 0) return address.toLowerCase()
    return /^[0-9a-f]+$/.test(address) ? "0x" + address : address
  }

  // A window vanished (closed in any way) — no close of ours is needed, drop
  // its pending entry and any close we still have queued for it.
  function onWindowClosed(address) {
    if (address === "") return
    for (let i = 0; i < root.pending.length; i++) {
      if (root.pending[i].address !== address) continue
      const entry = root.pending[i]
      if (entry.closeTag) {
        root.cancelQueuedClose(entry.closeTag)
        entry.closeTag = ""
      }
      console.warn(`grace-window: ${address} no longer exists in Hyprland; dropping its pending entry`)
      root.pending.splice(i, 1)
      return
    }
  }

  // A hidden window changed workspace (movewindowv2: address, id, name). Landing
  // on its grace workspace settles it (re-armed like a fresh hide after a
  // re-buffer); leaving it once settled means the user took it back — reopen it
  // in place (mode, size and look restored, but where it now sits untouched),
  // cancel any queued close, and drop the entry, never force-closing it on the
  // workspace the user put it on. A window never observed on its grace workspace
  // is usually still on its way there (the hide's own move dispatch is in
  // flight), so only a move after settling counts as a relocation. But if no
  // hide-move for it is queued or running anymore, the away-move is ground
  // truth: the hide never took — undo its grace look in place and drop the
  // entry instead of force-closing the window later on the workspace it is
  // actually on.
  function onWindowMoved(event) {
    let parts = []
    try {
      if (event && event.parse) parts = event.parse(3)
    } catch (e) { }
    const address = root.normalizeAddress(parts[0] || "")
    if (address === "") return
    const wsId = String(parts[1] || "")
    const wsName = String(parts[2] || "")
    for (let i = 0; i < root.pending.length; i++) {
      const entry = root.pending[i]
      if (entry.address !== address) continue
      // A close already handed to the process cannot be undone; only `closing`
      // is exempt, a queued close is still cancellable.
      if (entry.state === "closing") return
      if (root.onGracePosition({ workspaceId: wsId, workspaceName: wsName }, entry.workspace)) {
        entry.settled = true
        return
      }
      if (!entry.settled) {
        // An away-move while the hide's own move dispatch is still queued or
        // running is the migration itself, about to be overridden the moment it
        // lands on the grace workspace — ignore it. Without a pending hide-move
        // the window is not on (and will not get to) its grace workspace.
        if (root.hideMovePending(address)) return
        root.hidePlaceFailed(entry)
        return
      }
      if (entry.closeTag) {
        root.cancelQueuedClose(entry.closeTag)
        entry.closeTag = ""
      }
      console.warn(`grace-window: ${address} left its grace workspace; reopening it in place and dropping its pending entry`)
      root.reopenInPlace(entry)
      root.pending.splice(i, 1)
      return
    }
  }

  // Whether the window is on `workspace`'s id or name, be it a hyprctl capture
  // ({ workspaceId, workspaceName }) or the movewindowv2 event ({ workspaceId,
  // workspaceName }). Mirrors the invariant used everywhere: pending ⇔ still on
  // its grace workspace.
  function onGracePosition(rec, workspace) {
    return (rec.workspaceId !== undefined && rec.workspaceId !== null && String(rec.workspaceId) === String(workspace)) ||
           (rec.workspaceName !== undefined && rec.workspaceName !== null && String(rec.workspaceName) === String(workspace))
  }

  // ---------------------------------------------------------------- cancel
  // Forget every pending window (of every workspace's buffer) without closing
  // it, restoring only its grace look in place. The windows stay on the grace
  // workspace untouched otherwise; only reopen moves them back and restores
  // their mode and geometry. Queued auto-closes are cancelled; the now-empty
  // pending state is persisted too, so a restart can never resurrect a
  // cancelled (or given-up) window and re-arm its close.
  function cancel() {
    // Bump the epoch so in-flight ops report "none" instead of applying after
    // the cancellation.
    root.epoch++
    root.cancelScheduledCloses()
    for (let i = 0; i < root.pending.length; i++) {
      root.restoreInPlace(root.pending[i])
    }
    // Record in-flight restores: their settle must not re-queue them after
    // the cancellation.
    for (const address of Object.keys(root.restoring)) {
      root.cancelled.add(address)
    }
    // Windows being reopened are left to their restores; the service simply
    // forgets them.
    root.pending = []
    // Persist the now-empty pending state (clears a stale grace-window.json).
    root.saveStateDetached()
    return "ok"
  }

  // Removes every queued command carrying tag. Used to drop a window_close the
  // sweep queued but the Process has not picked up yet; one already running
  // cannot be undone (an avoidable race only a few milliseconds wide).
  function cancelQueuedClose(tag) {
    for (let i = root.queue.length - 1; i >= 0; i--) {
      if (root.queue[i].tag === tag) root.queue.splice(i, 1)
    }
  }

  // Cancels every queued "restore:<address>" command, used when the window a
  // reopen is restoring gets re-hidden: its pending restore dispatches would
  // otherwise still pull it back to the workspace it is being moved away from.
  function cancelRestore(address) {
    const tag = "restore:" + address
    for (let i = root.queue.length - 1; i >= 0; i--) {
      if (root.queue[i].tag === tag) root.queue.splice(i, 1)
    }
  }

  // Used by cancel() and teardown so a window whose look is restored in place
  // really stays open instead of still being killed by its queued close.
  // Entries whose close is already running are left to the dispatch outcome.
  function cancelScheduledCloses() {
    for (let i = 0; i < root.pending.length; i++) {
      const entry = root.pending[i]
      if (entry.state === "closing" || !entry.closeTag) continue
      root.cancelQueuedClose(entry.closeTag)
      entry.closeTag = ""
    }
  }

  // ------------------------------------------------------------- helpers
  // The pending entry for addr, or null. Defensive JSON parsing keeps a
  // malformed query answer from leaving an operation stuck or crashing.
  function findPending(addr) {
    for (let i = 0; i < root.pending.length; i++) {
      if (root.pending[i].address === addr) return root.pending[i]
    }
    return null
  }

  // Count of pending windows hidden into `workspace` — its FIFO buffer length.
  function bufferLength(workspace) {
    let length = 0
    for (let i = 0; i < root.pending.length; i++) {
      if (root.pending[i].workspace === workspace) length++
    }
    return length
  }

  // Moves a pending entry into `workspace`'s FIFO buffer — used when a re-hide
  // targets a different workspace than the window was hiding in, so a reopen
  // finds it under the right key.
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

  // Removes and returns the newest reopenable entry of `workspace`'s buffer
  // (not one whose close is running), or null.
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

  // ------------------------------------------------------------- configuration
  // The environment every invocation of the shell script gets, so the script's
  // own bounded-open deadline matches the configured value. Set on the shared
  // executor and the wiring processes; the detached teardown commands carry it
  // as an `env` prefix instead (see teardownCommand).
  function scriptEnvironment() {
    return { GRACE_WINDOW_OPEN_WAIT: String(root.openWaitMs) }
  }

  // Apply the effective configuration the script printed (the defaults it
  // writes on first start, merged with the user's edits). The script already
  // validated and completed every entry, so this only guards the shape: a
  // missing or non-numeric field keeps the default, and an answer that is not
  // an object at all leaves the defaults untouched.
  function applyConfig(raw) {
    const cfg = root.parseJson(raw)
    if (!cfg || typeof cfg !== "object") {
      console.warn("grace-window: configuration could not be read; using the defaults")
      return
    }
    if (typeof cfg.groupingDelayMs === "number") root.groupingDelayMs = cfg.groupingDelayMs
    if (typeof cfg.closeRetryMax === "number") root.closeRetryMax = cfg.closeRetryMax
    if (typeof cfg.queryTimeoutMs === "number") root.queryTimeoutMs = cfg.queryTimeoutMs
    if (typeof cfg.loadWaitLimit === "number") root.loadWaitLimit = cfg.loadWaitLimit
    if (typeof cfg.sweepIntervalMs === "number") root.sweepIntervalMs = cfg.sweepIntervalMs
    if (typeof cfg.loadRetryIntervalMs === "number") root.loadRetryIntervalMs = cfg.loadRetryIntervalMs
    if (typeof cfg.openWaitMs === "number") root.openWaitMs = cfg.openWaitMs
    root.propagateScriptEnvironment()
  }

  // Push the configured script environment onto the long-lived processes. Set
  // once after the config is read, before any of them starts; the detached
  // teardown commands read root.openWaitMs directly (teardownCommand).
  function propagateScriptEnvironment() {
    const env = root.scriptEnvironment()
    runnerProc.environment = env
    wireProc.environment = env
    unwireCopy.environment = env
  }

  // Re-read the configuration after config.json changes on disk, so an edit
  // takes effect without a plugin restart. FileView watches the file and its
  // directory through inotify, so both an in-place save and an atomic
  // rename-over are seen. The events a single save (or our own atomic write)
  // emits are coalesced by the timer, and re-running the `config` subcommand
  // keeps the same validation as startup — it only rewrites the file when it is
  // missing, so this never feeds back into another change.
  Timer {
    id: configReloadTimer
    interval: 250
    onTriggered: root.reloadConfig()
  }

  FileView {
    id: configWatcher
    path: root.configFile
    watchChanges: true
    printErrors: false
    onFileChanged: configReloadTimer.restart()
  }

  function reloadConfig() {
    root.runOpQuery(["bash", root.bashScript, "config", root.configFile]).then(function (raw) {
      root.applyConfig(raw)
      console.log("grace-window: configuration reloaded from " + root.configFile)
    })
  }

  // The status string: most recent live hidden window across all buffers. An
  // expired window still counts — until its close runs it can be reopened.
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
  // On start the managed block is appended to ~/.config/hypr/bindings.lua when
  // not already present, then Hyprland is reloaded — idempotent across restarts
  // and hot-reloads. Teardown removes it.
  //
  // The block comes from the captured custom bindings when they hold one, and
  // from the plugin's shipped hypr/bindings.lua otherwise. Teardown first
  // captures the live block there (only when it differs from the one this start
  // wired), so a block customized in ~/.config/hypr/bindings.lua round-trips
  // across disable/enable — and since the captured file is untracked and
  // gitignored, customizing it never gets in the way of `omarchy plugin update`,
  // whose fast-forward would otherwise be blocked by local changes to the
  // plugin's own bindings.lua.
  readonly property string bindingsBlockBgn:
    "-- BEGIN Grace Window (jam.grace-window) managed block - do not edit this comment"
  readonly property string bindingsBlockEnd:
    "-- END Grace Window (jam.grace-window) managed block - do not edit this comment"

  // The captured customization, next to the shipped block inside the plugin
  // directory. Untracked and gitignored, so it is neither committed nor seen as
  // a local change by `omarchy plugin update` (which fast-forwards and can
  // reset --hard); keep it a regular file — `omarchy plugin update` re-validates
  // the folder and refuses any symlink in it. Its presence means the live block
  // differs from the shipped default.
  readonly property string customBindingsFile: root.sourceDir + "/hypr/bindings-custom.lua"

  function wireBindings() {
    wireProc.command = ["bash", root.bashScript, "wire",
      root.sourceDir + "/hypr/bindings.lua",
      Quickshell.env("HOME") + "/.config/hypr/bindings.lua",
      root.bindingsBlockBgn,
      root.bindingsBlockEnd,
      root.customBindingsFile,
      root.wiredBindingsFile]
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
  // line before it). Runs detached from Component.onDestruction, where a child
  // Process could not outlive the service objects being torn down.
  //
  // Teardown cannot depend on the plugin's own files — omarchy removes them on
  // disable — so at startup the shell script and its awk partner are copied to
  // a stable per-user path (installUnwireScript); teardown runs that copy,
  // falling back to the plugin's own script if the copy has not completed yet.
  readonly property string unwireRuntimeDir:
    Quickshell.env("XDG_RUNTIME_DIR") || Quickshell.env("HOME") + "/.cache/grace-window"
  readonly property string unwireRuntimeScript: root.unwireRuntimeDir + "/grace-window.sh"
  // Where teardown saves the pending state and startup loads it again (see
  // "state persistence"): the pre-teardown buffers survive a shell restart or
  // hot-reload, restored for the windows that still exist on their saved grace
  // workspace. Lives next to the runtime scripts, which persist for the whole
  // user session.
  readonly property string stateFile: root.unwireRuntimeDir + "/grace-window.json"
  // The block the last wire put in place, next to the state file. Teardown
  // compares the live block against it: while the two agree nothing was
  // customized and no custom file is written; once they differ the live block
  // is captured (see customBindingsFile). It therefore also captures an edit
  // that was made while running, once the next start has wired it.
  readonly property string wiredBindingsFile: root.unwireRuntimeDir + "/bindings-wired.lua"
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

  // A detached teardown invocation of the script, carrying the configured
  // bounded-open deadline. execDetached takes no environment, so it is passed
  // with an `env` prefix; `env` execs into bash, so the command stays a single
  // process that a signal reaches as a whole.
  function teardownCommand(args) {
    return ["env", "GRACE_WINDOW_OPEN_WAIT=" + String(root.openWaitMs),
      "bash", root.teardownScript()].concat(args)
  }

  // The capture of the live block into customBindingsFile rides along with the
  // strip, in the same command: a separate one could run after the block is
  // already gone, or not at all.
  function unwireBindings() {
    const target = Quickshell.env("HOME") + "/.config/hypr/bindings.lua"
    if (!root.unwireInstalled) {
      console.warn("grace-window: unwire script not installed; using plugin script as fallback")
    }
    Quickshell.execDetached(root.teardownCommand(["unwire",
      target,
      root.bindingsBlockBgn,
      root.bindingsBlockEnd,
      root.customBindingsFile,
      root.wiredBindingsFile]))
  }

  // Teardown variant of cancel(): restores the grace look of every pending and
  // half-restored (restoring) window in place. Detached, like unwireBindings:
  // on Component.onDestruction a child Process could not outlive the service
  // objects being torn down, and the plugin directory may already be gone.
  function cancelDetached() {
    const all = root.teardownEntries()
    if (all.length === 0) return
    if (!root.unwireInstalled) {
      console.warn("grace-window: unwire script not installed; using plugin script as fallback")
    }
    Quickshell.execDetached(root.teardownCommand(["undo-grace",
      JSON.stringify(all)]))
  }

  // ------------------------------------------------------- state persistence
  // Teardown saves the pending state to the runtime dir; startup loads it, so a
  // restart or hot-reload keeps hidden windows in grace instead of forgetting
  // them. Only windows still existing on the workspace they were hidden into
  // are restored — anything moved or closed while the service was down is
  // dropped by the startup probe. Entries already closing cannot be saved, and
  // cancelled scheduled closes re-queue from the restored `remaining` (≤ 0 ⇒
  // `expiring`). An empty pending set clears the file: a window forgotten by
  // cancel() (or given up after closeRetryMax) must never be resurrected into
  // pending with a re-armed auto-close on the next start.

  // Every entry teardown must account for: pending windows plus those being
  // reopened. A restoring entry is not fully restored, so it is treated exactly
  // like a pending one — its look undone and its state saved — and the next
  // start either reclaims it (still on the grace workspace) or drops it.
  function teardownEntries() {
    const all = []
    for (let i = 0; i < root.pending.length; i++) all.push(root.pending[i])
    for (const address of Object.keys(root.restoring)) all.push(root.restoring[address])
    return all
  }

  // The persistable subset of teardownEntries: entries with a live window (not
  // closing) that cancel() did not forget. The service-only transients
  // (closeTag, closeFails, `state`) are derived anew on load, so the file is a
  // stable snapshot of the captured state.
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
        monitorX: e.monitorX,
        monitorY: e.monitorY,
        w: e.w,
        h: e.h,
      })
    }
    return out
  }

  // Saves the pending state for the next startup, atomically, through the
  // runtime script. Detached, like cancelDetached (a child Process could not
  // outlive teardown). An empty state clears the file — a stale save must
  // never resurrect forgotten windows or re-arm their auto-close.
  // `entries` is passed in by the teardown path, which has already worked out
  // whether it may publish at all (see Component.onDestruction).
  function saveStateDetached(entries) {
    const saveable = entries || root.saveableEntries()
    Quickshell.execDetached(root.teardownCommand(["save-state",
      root.unwireRuntimeDir, JSON.stringify(saveable)]))
  }

  // How the startup load ended, and whether publishing the in-memory pending
  // list is therefore safe. An empty pending list means "nothing to restore"
  // only once the load has actually finished: while it is in flight, or if it
  // was cut short (an aborted query, an unreadable file), pending is merely
  // incomplete, and the empty state is indistinguishable from "forget
  // everything" — which is what the state file records when it is written
  // empty, so those windows would be lost for good.
  //   pending      the load has not finished
  //   complete     it finished and the saved state was fully accounted for
  //   incomplete   it was cut short; pending is not the whole truth
  property string loadVerdict: "pending"
  // How often loadState has deferred itself while the wire was still running,
  // bounded by the configured loadWaitLimit.
  property int loadWaits: 0

  // Bounded retry for loadState while another op is in flight, instead of a busy
  // Qt.callLater spin.
  Timer {
    id: loadRetryTimer
    interval: root.loadRetryIntervalMs
    repeat: false
    onTriggered: root.loadState()
  }

  // Startup restore: read the saved state, probe which saved windows still
  // exist on their grace workspace, and restore those. Runs through the shared
  // executor (serialized with hide/reopen, under the same watchdog). A missing
  // state file reads as empty (no-op); a cancel landing mid-load aborts via the
  // epoch check.
  function loadState() {
    // Wait for the wiring reload first. `hyprctl reload` holds the Hyprland
    // socket for seconds, and the probe behind it would queue on the shared
    // runner for exactly that long — stretching the window in which a teardown
    // would see an empty pending list and wipe the state (see loadVerdict) from
    // a few milliseconds to several seconds. Bounded by the same retry timer,
    // so a wire that never finishes is not waited for forever: the load is
    // merely late then, and loadVerdict stays "pending" so nothing is lost.
    if (wireProc.running) {
      root.loadWaits++
      if (root.loadWaits >= root.loadWaitLimit) {
        console.warn(`grace-window: keybinding wiring still running after ${(root.loadWaitLimit * loadRetryTimer.interval) / 1000}s; loading the saved state anyway`)
        root.loadWaits = 0
      } else {
        loadRetryTimer.restart()
        return
      }
    }
    if (root.opInFlight > 0) {
      // Another query is in flight (e.g. a hot-reload landed mid-operation);
      // retry on the next sweep tick instead of spinning each event loop turn.
      loadRetryTimer.restart()
      return
    }
    root.opInFlight++
    root.loadWaits = 0
    const myEpoch = root.epoch
    root.loadVerdict = "pending"
    root.runOpQuery(["cat", root.stateFile]).then(
      function (raw) {
        const saved = root.parseJson(raw)
        if (myEpoch !== root.epoch) {
          root.opInFlight--
          console.warn("grace-window: startup state load aborted before it read anything")
          return
        }
        if (!Array.isArray(saved)) {
          root.opInFlight--
          root.loadVerdict = "incomplete"
          console.warn(`grace-window: could not read ${root.stateFile}; leaving the saved state untouched`)
          return
        }
        if (saved.length === 0) {
          // Nothing was saved: the windows of the previous lifetime are all gone
          // or were all cancelled. A teardown may publish an empty pending.
          root.opInFlight--
          root.loadVerdict = "complete"
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
  // probe reports as still alive on the workspace they were hidden into, and
  // re-applies their grace state so the desktop matches pre-teardown. The
  // countdown resumes where it left off; downtime is not charged.
  function restorePending(saved, probeRaw) {
    const probe = root.parseJson(probeRaw)
    if (!Array.isArray(probe)) {
      // The probe died, was watchdoged, or answered something that is not a
      // list. pending does not yet know about the saved windows, so a teardown
      // must not take this for "nothing pending".
      root.loadVerdict = "incomplete"
      console.warn(`grace-window: state probe for ${root.stateFile} failed; ${saved.length} saved window(s) left unrestored`)
      return
    }
    const whereabouts = new Map()
    for (let i = 0; i < probe.length; i++) {
      const p = probe[i]
      if (!p || !p.address) continue
      whereabouts.set(p.address, { id: p.workspace, name: p.name || "" })
    }
    const restored = []
    const dropped = []
    for (let i = 0; i < saved.length; i++) {
      const e = saved[i]
      if (!e || !e.address || !whereabouts.has(e.address)) {
        dropped.push(e && e.address ? e.address : "?")
        continue
      }
      const ws = String(e.workspace)
      const loc = whereabouts.get(e.address)
      if (ws !== String(loc.id) && ws !== loc.name) {
        // The window is alive but no longer on the workspace it was hidden
        // into — the user moved it while the service was down. Naming it here
        // is the only trace this ever leaves.
        dropped.push(`${e.address} (left workspace ${ws}, now on ${loc.id})`)
        continue
      }
      restored.push(e)
    }
    if (dropped.length > 0) {
      console.warn(`grace-window: not restoring ${dropped.length} saved window(s): ${dropped.join(", ")}`)
    }
    // Whether or not anything came back, the load itself has now been fully
    // accounted for, so a teardown may publish what this instance is tracking.
    root.loadVerdict = "complete"
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
        // An older saved state predates the monitor origin: null, so a reopen
        // falls back to the saved absolute position.
        monitorX: typeof e.monitorX === "number" ? e.monitorX : null,
        monitorY: typeof e.monitorY === "number" ? e.monitorY : null,
        w: Number(e.w) || 0,
        h: Number(e.h) || 0,
        // The applied grace look, if saved; fall back to the (un-dimmed)
        // original so a stale file never injects NaN props.
        graceOpacity: root.savedLook(e, "graceOpacity", "opacity"),
        graceOpacityInactive: root.savedLook(e, "graceOpacityInactive", "opacityInactive"),
        graceRounding: root.savedLook(e, "graceRounding", "rounding"),
        graceRoundingPower: root.savedLook(e, "graceRoundingPower", "roundingPower"),
        state: remaining <= 0 ? "expiring" : "counting",
        closeFails: 0,
        closeTag: "",
        // The state probe already verified this window sits on its saved grace
        // workspace, so no hide migration is in flight; the settled flag is
        // armed so a movewindow away counts as a relocation right away.
        settled: true,
      }
      root.pending.push(entry)
      // Re-hide in place: it already sits on the grace workspace, so only its
      // look and mode need restoring, exactly like a fresh hide.
      if (entry.floating) root.setWindowPin(entry.address, "off")
      root.graceState(entry.address, entry.fullscreenClient, entry.graceOpacity, entry.graceOpacityInactive,
        entry.graceRounding, entry.graceRoundingPower)
    }
  }

  // Saved applied grace value, or the fallback property when the state file
  // predates grace-look persistence. Always a number; NaN never dispatches.
  function savedLook(entry, prop, fallback) {
    const value = Number(entry[prop])
    if (!isNaN(value) && entry[prop] !== undefined && entry[prop] !== null) return value
    return Number(entry[fallback]) || 0
  }

  // One harmless dispatch through grace-window.lua at startup, so an unreadable
  // or broken file is reported up front instead of at the first keybinding.
  function selfCheck() {
    root.luaDispatch("check()")
  }

  // One-shot query through the executor: Hyprland only pushes activewindowv2
  // on focus *changes*, so a restored window that already holds focus (and its
  // grace countdown, which pauses while focused) must be checked at start.
  function hydrateFocus() {
    root.runOpQuery(["hyprctl", "-j", "activewindow"]).then(function (raw) {
      const win = root.parseJson(raw)
      root.focusedAddress = win && win.address ? root.normalizeAddress(win.address) : ""
    })
  }

  // ---------------------------------------------------------------- startup
  Component.onCompleted: {
    // Seed the sweep clock before any window can be hidden: a hide that lands
    // before the first tick would otherwise measure the whole epoch since 1970
    // and expire at once.
    root.lastTick = Date.now()
    // The shell assigns root.manifest after creating this service, so defer the
    // whole startup until it is set.
    Qt.callLater(root.bootstrap)
  }

  // Load config.json first — writing it with the defaults on first start — so
  // every startup step below runs with the configured values, then wire the
  // keybindings, install the teardown copy, seed focus and self-check, and
  // finally restore the saved state (which waits for the wiring to finish).
  function bootstrap() {
    root.runOpQuery(["bash", root.bashScript, "config", root.configFile]).then(function (raw) {
      root.applyConfig(raw)
      root.wireBindings()
      root.installUnwireScript()
      root.hydrateFocus()
      root.selfCheck()
      root.loadState()
    })
  }

  // Fires on plugin disable/remove and shell shutdown. Cancels pending windows
  // in place (including mid-reopen ones, whose queued restore dispatches die
  // with the executor), saves the state for the next start, and unwires the
  // managed block — plugin removal then leaves nothing behind. The next start
  // re-wires the block and restores any window still on its grace workspace.
  Component.onDestruction: {
    // Drop queued auto-closes first, so the detached look undo below is not
    // followed by the windows being closed for real. Expiry is re-derived on
    // load (remaining ≤ 0 ⇒ expiring).
    root.cancelScheduledCloses()
    const saveable = root.saveableEntries()
    if (saveable.length === 0 && root.loadVerdict !== "complete") {
      // The startup load has not finished, or was cut short, so this instance
      // has not seen the saved windows yet and an empty pending list says
      // nothing about them. Publishing it would clear grace-window.json (an empty
      // state is how the file is emptied), and the windows still sitting on
      // their grace workspaces would be lost with no way to tell they existed.
      // The file on disk is the last complete truth: leave it alone.
      console.warn("grace-window: torn down before the startup state load finished; the saved state is left untouched")
    } else {
      root.saveStateDetached(saveable)
    }
    root.cancelDetached()
    root.unwireBindings()
  }
}