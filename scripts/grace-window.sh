#!/usr/bin/env bash
# Grace Window — every shell operation the plugin needs, in one file.
#
# hide-query / reopen-query    Capture focused-window / workspace state (JSON).
# leave-group ADDR DELAY       Pull ADDR out of its tabbed group (+ delay).
# regroup ADDR FOCUS DELAY     Move ADDR into FOCUS's tabbed group.
# close ADDR                   Close ADDR and verify it is gone: exit 0 only
#                              when the address no longer exists (retryable
#                              otherwise, never a success on a broken query).
# wire SRC TARGET S E          Append the managed block from SRC to TARGET
#                              (markers S/E), atomically; a no-op when one
#                              intact block exists, fail-closed otherwise.
# unwire TARGET S E            Remove exactly the managed block again.
# undo-grace JSON              Restore the grace look of JSON's entries in
#                              place (teardown, runtime copy).
# save-state DIR JSON          Write DIR/state.json atomically; empty clears it.
# state-probe                  Client address + workspace id/name JSON.
# install-unwire DIR           Copy this script and its awk/lua partners into
#                              DIR (atomically), for teardown.
#
# grace-window.lua holds every hl.dsp dispatch, grace-window.jq every jq
# filter, grace-window.awk the unwire stripper. "unwire" and "undo-grace" also
# run after the plugin directory is gone, so they must not depend on anything
# but their arguments and this file's directory.
set -u

self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmpfile=""

say() { echo "grace-window: $*"; }
die() {
  if [[ -n "$tmpfile" ]]; then rm -f "$tmpfile"; fi
  say "ERROR: $*"
  exit 1
}

# hyprctl exits nonzero when the file is missing or broken; surface that
# instead of losing the dispatch silently.
lua_call() {
  local out
  if ! out=$(hyprctl dispatch "dofile('$self/grace-window.lua').$1" 2>&1); then
    say "dispatch failed: $out"
    return 1
  fi
}

# Refuse when any path component up to the file is a symlink or owned by
# another user, or a directory that is group/other writable.
check_target() {
  local target="$1" cur owner mode comp
  local -a comps
  [[ "$target" == /* ]] || die "target is not absolute: $target"
  cur="/"
  IFS=/ read -r -a comps <<< "${target#/}"
  for comp in "${comps[@]}"; do
    [[ -n "$comp" ]] || continue
    cur="${cur%/}/$comp"
    [[ -L "$cur" ]] && die "refusing to write: $cur is a symlink"
    owner=$(stat -c "%u" "$cur" 2>/dev/null) || die "cannot stat $cur"
    if [[ "$owner" != "$(id -u)" && "$owner" != 0 ]]; then die "refusing to write: $cur is owned by uid $owner, not you"; fi
    if [[ -d "$cur" ]]; then
      mode=$(stat -c "%a" "$cur")
      if (( (8#$mode & 0022) != 0 )); then die "refusing to write: $cur is group/other writable (mode $mode)"; fi
    fi
  done
}

# Read one window property's current value (empty when the query fails; the
# callers refuse to hide a window whose look cannot be captured faithfully).
window_prop() {
  hyprctl getprop "address:$1" "$2" 2>/dev/null | tail -n 1
}

cmd_hide_query() {
  local win addr opacity opacity_inactive rounding rounding_power
  win=$(hyprctl -j activewindow 2>/dev/null) || exit 0
  addr=$(jq -r '.address // empty' <<<"$win") || true
  if [[ -z "$addr" || "$addr" == "0x0" ]]; then
    echo "{}"
    exit 0
  fi
  opacity=$(window_prop "$addr" opacity)
  opacity_inactive=$(window_prop "$addr" opacity_inactive)
  rounding=$(window_prop "$addr" rounding)
  rounding_power=$(window_prop "$addr" rounding_power)
  jq -L "$self" -c \
    --arg opacity "$opacity" \
    --arg opacityInactive "$opacity_inactive" \
    --arg rounding "$rounding" \
    --arg roundingPower "$rounding_power" \
    'include "grace-window"; hideQuery($opacity; $opacityInactive; $rounding; $roundingPower)' \
    <<<"$win"
}

cmd_reopen_query() {
  local aw ws mn
  aw=$(hyprctl -j activewindow 2>/dev/null || true)
  ws=$(hyprctl -j activeworkspace 2>/dev/null || true)
  mn=$(hyprctl -j monitors 2>/dev/null || true)
  [[ -n "$aw" ]] || aw="{}"
  [[ -n "$ws" ]] || ws="{}"
  [[ -n "$mn" ]] || mn="[]"
  jq -L "$self" -c -n \
    --argjson aw "$aw" \
    --argjson ws "$ws" \
    --argjson mn "$mn" \
    'include "grace-window"; reopenQuery($aw; $ws; $mn)'
}

cmd_leave_group() {
  local addr="$1" delay="$2"
  lua_call "window_out_of_group('$addr')" || return 1
  sleep "$delay"
}

cmd_regroup() {
  local addr="$1" focus="$2" delay="$3" clients dir
  clients=$(hyprctl -j clients 2>/dev/null)
  dir=$(printf "%s" "$clients" \
    | jq -r -L "$self" \
      --arg a "$addr" \
      --arg f "$focus" \
      'include "grace-window"; regroupDirection($a; $f)')
  if [[ -n "$dir" ]]; then
    sleep "$delay"
    lua_call "window_into_group('$addr', '$dir')" || return 1
  fi
}

# Close for real and verify it took. The dispatch's own error output cannot
# tell a dead address from a failed dispatch, so the outcome is decided by
# whether the address still exists in Hyprland afterwards. A malformed or
# missing clients answer counts as a retryable failure, never a success — an
# outage must not look like a successful close.
cmd_close() {
  local addr="$1" clients
  hyprctl dispatch "dofile('$self/grace-window.lua').window_close('$addr')" >/dev/null 2>&1
  clients=$(hyprctl -j clients 2>/dev/null) || return 1
  if ! jq -e 'type == "array"' <<<"$clients" >/dev/null 2>&1; then
    say "clients query returned invalid JSON after close; treating as retryable failure"
    return 1
  fi
  if jq -e --arg a "$addr" 'any(.[]; .address == $a)' <<<"$clients" >/dev/null 2>&1; then
    return 1  # still alive → retryable failure
  fi
  return 0    # gone → closed for real
}

cmd_wire() {
  local src="$1" target="$2" start="$3" end="$4" orig_mode l0 l1 target_dir starts ends
  if [[ ! -f "$src" ]]; then say "source bindings missing: $src"; return; fi
  l0=$(grep -nFs -- "$start" "$src" | head -n 1 | cut -d: -f1)
  l1=$(grep -nFs -- "$end" "$src" | head -n 1 | cut -d: -f1)
  if [[ -z "$l0" || -z "$l1" ]]; then die "managed block not found in $src"; fi
  if (( l0 > l1 )); then die "managed block markers out of order in $src"; fi
  # The target must be either fully wired (exactly one intact start/end pair)
  # or free of the markers — any other state was not written by this plugin.
  # Appending a second block would corrupt it further, and the partial block is
  # never stripped automatically: content after a stray marker may be the user's.
  starts=$(grep -cFs -- "$start" "$target" 2>/dev/null || true)
  ends=$(grep -cFs -- "$end" "$target" 2>/dev/null || true)
  if (( starts == 1 && ends == 1 )); then
    say "keybindings already wired; nothing to do"
    return
  fi
  if (( starts != 0 || ends != 0 )); then
    die "managed block markers in $target are not intact ($starts start, $ends end); remove them by hand, then restart the service to re-wire a clean block"
  fi
  target_dir="$(dirname "$target")"
  if [[ ! -d "$target_dir" ]]; then die "target directory missing: $target_dir"; fi
  if [[ -f "$target" ]]; then
    # Appending to an existing file: verify the whole path.
    check_target "$target"
  else
    # No file yet: only the directory needs the owner/symlink checks.
    check_target "$target_dir"
  fi
  tmpfile=$(mktemp "$target_dir/bindings.lua.tmp.XXXXXX") || die "could not create temporary file"
  if [[ -f "$target" ]]; then
    orig_mode=$(stat -c "%a" "$target")
    {
      cat "$target"
      echo ""
      sed -n "${l0},${l1}p" "$src"
    } > "$tmpfile" || die "could not write temporary file"
  else
    orig_mode=644
    sed -n "${l0},${l1}p" "$src" > "$tmpfile" || die "could not write temporary file"
  fi
  chmod "$orig_mode" "$tmpfile" || die "could not set permissions on temporary file"
  mv -f "$tmpfile" "$target" || die "could not atomically replace $target"
  tmpfile=""
  if ! grep -qFs -- "$start" "$target"; then die "failed to wire keybindings into $target"; fi
  if hyprctl reload >/dev/null 2>&1; then
    say "keybindings wired into $target and hyprland reloaded"
  else
    say "warning: keybindings wired into $target, but hyprland reload failed"
  fi
}

cmd_unwire() {
  local target="$1" start="$2" end="$3" orig_mode starts ends tmpfile
  if [[ ! -f "$target" ]]; then say "bindings file not found: $target; nothing to clean"; return; fi
  starts=$(grep -cFs -- "$start" "$target" || true)
  ends=$(grep -cFs -- "$end" "$target" || true)
  # Only an intact, single managed block is ever unwired; duplicates or bare
  # markers mean the file is not in a state this plugin created, so refuse to
  # guess. Markers are single-line comments, so line counts cannot be confounded.
  if (( starts != 1 )) || (( ends != 1 )); then
    say "managed block markers not intact in $target ($starts start, $ends end); leaving file untouched"
    return
  fi
  check_target "$target"
  tmpfile=$(mktemp "${target}.tmp.XXXXXX") || die "could not create temporary file"
  orig_mode=$(stat -c "%a" "$target")
  # Strip into a temp file first, and only rename over the target once the
  # result is produced and verified, so a failure never leaves a half-stripped
  # bindings file behind.
  if ! awk -v s="$start" -v e="$end" -f "$self/grace-window.awk" "$target" > "$tmpfile"; then
    rm -f "$tmpfile"
    die "unwire (awk) failed; $target left untouched"
  fi
  if grep -qFs -- "$start" "$tmpfile"; then
    rm -f "$tmpfile"
    die "unwire produced a malformed result (marker still present); $target left untouched"
  fi
  chmod "$orig_mode" "$tmpfile" || { rm -f "$tmpfile"; die "could not set permissions on temporary file"; }
  mv -f "$tmpfile" "$target" || { rm -f "$tmpfile"; die "could not atomically replace $target"; }
  tmpfile=""
  if hyprctl reload >/dev/null 2>&1; then
    say "managed keybinding block removed from $target and hyprland reloaded"
  else
    say "warning: managed keybinding block removed from $target, but hyprland reload failed"
  fi
}

cmd_install_unwire() {
  local dir="$1" f tmp
  mkdir -p "$dir" || die "cannot create runtime dir: $dir"
  # Copy each file atomically (write next to it, then rename), so an
  # interrupted copy can never leave a truncated teardown script behind.
  for f in grace-window.sh grace-window.awk grace-window.lua; do
    tmp="$dir/$f.tmp.$$"
    cp "$self/$f" "$tmp" || die "cannot copy $f to $dir"
    mv -f "$tmp" "$dir/$f" || { rm -f "$tmp"; die "cannot replace $f in $dir"; }
  done
  # The teardown subcommands must exist in the copy — a stale script would
  # strand the grace look on stop and lose the pending state on restart.
  grep -q 'undo-grace' "$dir/grace-window.sh" || die "installed unwire script lacks undo-grace"
  grep -q 'save-state' "$dir/grace-window.sh" || die "installed unwire script lacks save-state"
}

# Teardown variant of cancel(): restore the grace look (and pin) of every
# pending window in place, from this runtime copy after the plugin directory may
# be gone. Best-effort per window — a vanished window or failed dispatch must
# not abort the rest.
cmd_undo_grace() {
  local data="$1" rec addr opacity opacity_inactive rounding rounding_power \
    floating fullscreen fullscreen_client pinned
  [[ -n "$data" ]] || return 0
  while read -r rec; do
    addr=$(jq -r '.address // empty' <<<"$rec")
    [[ -n "$addr" ]] || continue
    opacity=$(jq -r '.opacity // empty' <<<"$rec")
    opacity_inactive=$(jq -r '.opacityInactive // empty' <<<"$rec")
    rounding=$(jq -r '.rounding // empty' <<<"$rec")
    rounding_power=$(jq -r '.roundingPower // empty' <<<"$rec")
    # Look fields are always captured by hide-query; an incomplete record can't
    # be restored faithfully, so skip it rather than inject empty values (an
    # empty rounding_power would become a malformed dispatch).
    if [[ -z "$opacity" || -z "$opacity_inactive" || -z "$rounding" || -z "$rounding_power" ]]; then
      say "skipping $addr: captured grace look incomplete"
      continue
    fi
    floating=$(jq -r '.floating // "false"' <<<"$rec")
    pinned=$(jq -r '.pinned // "false"' <<<"$rec")
    fullscreen=$(jq -r '.fullscreen // 0' <<<"$rec")
    fullscreen_client=$(jq -r '.fullscreenClient // 0' <<<"$rec")
    lua_call "window_set_prop('$addr', 'opacity', $opacity)" || continue
    lua_call "window_set_prop('$addr', 'opacity_inactive', $opacity_inactive)" || continue
    lua_call "window_set_prop('$addr', 'rounding', $rounding)" || continue
    lua_call "window_set_prop('$addr', 'rounding_power', $rounding_power)" || continue
    if [[ "$floating" == "true" ]]; then
      lua_call "window_float('$addr', true)" || continue
    fi
    if (( fullscreen > 0 || fullscreen_client > 0 )); then
      lua_call "window_fullscreen('$addr', $fullscreen, $fullscreen_client)" || continue
    fi
    # Pin ends the restore, mirroring Service.qml restoreInPlace.
    if [[ "$pinned" == "true" ]]; then
      lua_call "window_pin('$addr', true)" || continue
    fi
  done < <(jq -c '.[]?' <<<"$data")
}

# Persist the pending state as $dir/state.json for the next startup; atomic.
# An empty state removes any stale file, so a window that is no longer pending
# is never resurrected with a re-armed auto-close.
cmd_save_state() {
  local dir="$1" data="$2" tmp
  mkdir -p "$dir" || die "cannot create state dir: $dir"
  check_target "$dir"
  if [[ -z "$data" || "$data" == "[]" ]]; then
    rm -f "$dir/state.json" || die "cannot remove stale state file"
    return 0
  fi
  tmp="$dir/state.json.tmp.$$"
  printf '%s\n' "$data" > "$tmp" || { rm -f "$tmp"; die "cannot write state file"; }
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$dir/state.json" || { rm -f "$tmp"; die "cannot replace state file"; }
}

# Startup restore probe: every client's address and workspace, to filter the
# saved state down to windows still on their grace workspace.
cmd_state_probe() {
  local clients
  clients=$(hyprctl -j clients 2>/dev/null || true)
  [[ -n "$clients" ]] || clients="[]"
  jq -L "$self" -c 'include "grace-window"; stateProbe' <<<"$clients" || echo "[]"
}

case "${1:-}" in
  hide-query) shift; cmd_hide_query "$@" ;;
  reopen-query) shift; cmd_reopen_query "$@" ;;
  leave-group) shift; cmd_leave_group "$@" ;;
  regroup) shift; cmd_regroup "$@" ;;
  close) shift; cmd_close "$@" ;;
  wire) shift; cmd_wire "$@" ;;
  unwire) shift; cmd_unwire "$@" ;;
  undo-grace) shift; cmd_undo_grace "$@" ;;
  save-state) shift; cmd_save_state "$@" ;;
  state-probe) shift; cmd_state_probe "$@" ;;
  install-unwire) shift; cmd_install_unwire "$@" ;;
  *) say "unknown subcommand: ${1:-}"; exit 1 ;;
esac
