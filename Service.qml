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
//     on the active workspace (or an open scratchpad on the focused monitor).
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
// start and removed on teardown.

import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  // ------------------------------------------------------------ configuration
  // Delay after (un)grouping so apps refresh their graphics; 0.0 is snappier,
  // higher values prevent glitches after (un)grouping.
  readonly property double groupingDelay: 0.1

  // Failed close attempts before giving up; the look is then restored in place
  // so the window is not left stranded looking pending.
  readonly property int closeRetryMax: 3

  // A runner command is aborted after this; a hung hyprctl must not wedge the
  // single executor queue and lock the plugin into "busy" forever.
  readonly property int queryTimeoutMs: 10000

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

  // ------------------------------------------------------------ pending state
  // Pending hidden windows, newest last. `workspace` groups them into private
  // FIFO buffers that hide()/reopen() touch. `state` is one of:
  //   counting   grace counting down (paused while focused),
  //   expiring   grace ran out; the close is queued but a reopen can still win,
  //   closing    the close dispatch runs; the entry leaves on success,
  //   restoring  held in `restoring` while its reopen dispatches run.
  // Windows gone from Hyprland are pruned by the liveness probe. `closeFails`
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
  // exit of the aborted one. A hung hyprctl can therefore never block the
  // queue forever — modulo the one case no watchdog can fix: an OS that never
  // reaps the SIGKILLed process holds the FIFO until it (eventually) does.
  property var queue: []
  property var runningItem: null
  property bool abortPending: false
  // Sweep probes never stack: only one queued/running probe per key, so a
  // slow hyprctl cannot pile up probes behind the queue.
  property var probeInFlight: ({})

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
  // since onExited clears abortPending. Not stopped here: onRunningChanged
  // already disarmed it when the abort flipped `running` back to false, and it
  // re-arms for whichever command the drain starts.
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

  // One-shot probe, keyed so it never stacks; failures keep the last good
  // state.
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
      root.rebuffer(existing, workspace)
      // The client-side fullscreen is captured fresh too: it must mirror the
      // state the window believes in right now (it is never reset while it
      // hides), so a hidden window whose client changed its own fullscreen is
      // captured as it is.
      existing.fullscreenClient = rec.fullscreenClient || 0
      // As in a fresh hide: pull it out of any tabbed group so the whole group
      // is not dragged to the grace workspace.
      const grouped = Array.isArray(rec.grouped) ? rec.grouped : []
      if (grouped.length > 0) {
        root.dispatchOps(["bash", root.bashScript, "leave-group", addr, String(root.groupingDelay)])
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
      root.moveToGraceWorkspace(addr, workspace)
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
    }
    root.pending.push(entry)
    const grouped = Array.isArray(rec.grouped) ? rec.grouped : []
    if (grouped.length > 0) {
      root.dispatchOps(["bash", root.bashScript, "leave-group", addr, String(root.groupingDelay)])
    }
    if (entry.floating) root.setWindowPin(addr, "off")
    root.moveToGraceWorkspace(addr, workspace)
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
    // cannot expire it, the liveness probe cannot prune it and reopen cannot
    // pick it again until the last tagged dispatch settles.
    const restoreTag = "restore:" + entry.address
    entry.state = "restoring"
    root.restoring[entry.address] = entry
    root.restoreWindow(entry, target, restoreTag)
    // Join the group that had focus when reopening was triggered.
    root.dispatchRestore([
      "bash", root.bashScript, "regroup",
      entry.address, win.address || "", String(root.groupingDelay),
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

  function restoreWindow(entry, workspaceId, tag) {
    // Undo the grace look, restore mode and geometry, then pin — nothing gets
    // pinned mid-flight while a moved window is still on its way.
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
      root.moveWindowTo(entry.address, entry.x, entry.y, tag)
    }
    root.moveWindowToWorkspace(entry.address, workspaceId, tag)
    if (entry.pinned) root.setWindowPin(entry.address, "on", tag)
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

  // Settles the in-flight reopen of the entry in `restoring[address]`. Success
  // keeps the entry out for good (the window is back); a failure verifies
  // where the window actually is before re-queuing, so one that did land (only
  // a trailing dispatch failed) is never closed by a stale expiry.
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
    interval: 500
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
      // Expired windows close for real, regardless of focus. Queue the close
      // now; the extra sweep interval is the window in which a reopen can
      // cancel before the dispatch is ever submitted.
      if (entry.state === "expiring") {
        if (!entry.closeTag) {
          entry.closeTag = `close:${entry.address}`
          root.queueClose(entry, entry.closeTag)
        }
        continue
      }
      // The timer pauses while the hidden window holds focus.
      if (entry.address === root.focusedAddress) continue
      entry.remaining -= delta
      if (entry.remaining > 0) continue
      // Grace ran out: flag for closing. A reopen landing within a sweep
      // interval still wins — the close is only submitted on a later tick.
      entry.state = "expiring"
    }
    // Sample the focused window and whether hidden windows still exist, so one
    // closed by other means leaves pending without waiting out its grace.
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
    // An empty clients answer is far more likely a query hiccup than a desktop
    // with no windows at all; never prune on it.
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
    // Persist the now-empty pending state (clears a stale state.json).
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
  // On start the managed block from hypr/bindings.lua is appended to
  // ~/.config/hypr/bindings.lua when not already present, then Hyprland is
  // reloaded — idempotent across restarts and hot-reloads. Teardown removes it.
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
  // half-restored (restoring) window in place. Detached, like unwireBindings:
  // on Component.onDestruction a child Process could not outlive the service
  // objects being torn down, and the plugin directory may already be gone.
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
  function saveStateDetached() {
    const saveable = root.saveableEntries()
    Quickshell.execDetached(["bash", root.teardownScript(), "save-state",
      root.unwireRuntimeDir, JSON.stringify(saveable)])
  }

  // Bounded retry for loadState while another op is in flight, instead of a busy
  // Qt.callLater spin.
  Timer {
    id: loadRetryTimer
    interval: 500
    repeat: false
    onTriggered: root.loadState()
  }

  // Startup restore: read the saved state, probe which saved windows still
  // exist on their grace workspace, and restore those. Runs through the shared
  // executor (serialized with hide/reopen, under the same watchdog). A missing
  // state file reads as empty (no-op); a cancel landing mid-load aborts via the
  // epoch check.
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
  // probe reports as still alive on the workspace they were hidden into, and
  // re-applies their grace state so the desktop matches pre-teardown. The
  // countdown resumes where it left off; downtime is not charged.
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
        // The applied grace look, if saved; fall back to the (un-dimmed)
        // original so a stale file never injects NaN props.
        graceOpacity: root.savedLook(e, "graceOpacity", "opacity"),
        graceOpacityInactive: root.savedLook(e, "graceOpacityInactive", "opacityInactive"),
        graceRounding: root.savedLook(e, "graceRounding", "rounding"),
        graceRoundingPower: root.savedLook(e, "graceRoundingPower", "roundingPower"),
        state: remaining <= 0 ? "expiring" : "counting",
        closeFails: 0,
        closeTag: "",
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

  // ---------------------------------------------------------------- startup
  Component.onCompleted: {
    // The shell assigns root.manifest after creating this service, so defer
    // the wiring, unwire-copy, state restore and self-check until it is set.
    root.lastTick = Date.now()
    Qt.callLater(root.wireBindings)
    Qt.callLater(root.installUnwireScript)
    Qt.callLater(root.loadState)
    Qt.callLater(root.selfCheck)
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
    root.saveStateDetached()
    root.cancelDetached()
    root.unwireBindings()
  }
}