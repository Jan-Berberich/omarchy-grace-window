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
#
# Every read, write and replacement of a file is done relative to an open
# directory descriptor rather than to a pathname (see "descriptor-bound paths"),
# so a checked path cannot be swapped for another one behind our back.
set -u

# Physical path of this script's directory: a plugin directory reached through a
# symlink (a dotfile checkout, say) is used as the real directory it points at,
# so the no-follow check below sees no symlink of our own making.
phys_dir() { (cd -- "$1" 2>/dev/null && pwd -P); }
script_path="${BASH_SOURCE[0]}"
self="$(phys_dir "$(dirname -- "$script_path")")"
tmpfile=""
me_uid=""
proc_seen=""
# Descriptor state, filled in by the helpers below and used by the commands.
# DIR_PATH is the pinned directory ("/proc/self/fd/$DIR_FD"), FILE_PATH the
# pinned file in it, SELF_PATH this script's own directory.
DIR_FD=""
DIR_PATH=""
FILE_FD=""
FILE_PATH=""
FILE_DEV=""
FILE_INO=""
FILE_MODE=""
SELF_FD=""
SELF_PATH="$self"

say() { echo "grace-window: $*"; }
die() {
  if [[ -n "$tmpfile" ]]; then rm -f "$tmpfile"; fi
  say "ERROR: $*"
  exit 1
}

# hyprctl exits nonzero when the file is missing or broken; surface that
# instead of losing the dispatch silently. The dofile path is the one place a
# real pathname is unavoidable: Hyprland's Lua VM resolves it in its own
# process, where our descriptors do not exist.
lua_call() {
  local out
  if ! out=$(hyprctl dispatch "dofile('$self/grace-window.lua').$1" 2>&1); then
    say "dispatch failed: $out"
    return 1
  fi
}

# ---------------------------------------------------------- descriptor-bound paths
# Every read, write and replacement below addresses its file through an open
# directory descriptor instead of through a pathname: the directory is opened
# once, checked, and then kept open for the rest of the command, and every
# operation runs relative to that descriptor through /proc/self/fd. A name that
# passed the checks therefore stays bound to the object it was checked as — a
# symlink swapped in for bindings.lua, or an ancestor directory replaced
# altogether, can no longer redirect the read, the write or the rename.
#
# Two properties make the binding work:
#   * Components are opened one at a time, each relative to the descriptor of
#     the one before it, and the object a new descriptor resolves to must be
#     the very inode the check just saw (same device, same inode). A component
#     replaced between check and open is thus either caught or has no effect.
#   * The descriptors stay open in this shell and every child inherits them, so
#     /proc/self/fd/N names the same open file here and in grep, awk, sed, cat,
#     mktemp or mv. Those paths only exist while we hold the descriptor and are
#     never passed to a process that outlives this command.
#
# Opening a directory needs read permission on it (O_RDONLY); every directory
# involved here — $HOME, ~/.config, ~/.config/hypr, the runtime dir — is.
#
# stat shapes: of a path, without following a final symlink (so a symlinked
# component or entry shows up as one), and of the object a descriptor refers to.
#
# The kind is taken from stat's raw mode (%f) rather than from its human-readable
# %F, which coreutils translates: under a German or Dutch locale %F says
# "Verzeichnis" or "map" where the C locale says "directory", and every string
# comparison against it would then fail. The type bits are a fixed part of the
# mode, so testing them is locale-independent.
lstat_info() { stat -c "%d %i %u %a %f" -- "$1"; }
fstat_info() { stat -L -c "%d %i %u %a %f" -- "/proc/self/fd/$1"; }

# The file kind, from the type bits of a raw mode (%f prints it hex, no 0x).
# is_regular_mode covers regular empty files too: they are regular files, unlike
# the separate "regular empty file" kind %F reports for them.
is_dir_mode() { (( (0x$1 & 0xf000) == 0x4000 )); }
is_regular_mode() { (( (0x$1 & 0xf000) == 0x8000 )); }
is_symlink_mode() { (( (0x$1 & 0xf000) == 0xa000 )); }

# /proc/self/fd is how a descriptor is named as a path, so without it none of
# this works. Checked once per command (proc_seen) and reported plainly instead
# of failing later on an unreadable descriptor.
ensure_proc() {
  [[ -n "$proc_seen" ]] && return 0
  [[ -d /proc/self/fd ]] || die "/proc/self/fd is missing; is /proc mounted?"
  proc_seen=1
}

# The object we are about to read or replace must be ours (or root's) and, when
# it is a directory, must not be group/other writable — otherwise another user
# could swap things underneath us. Checked on the descriptor's object, not on a
# pathname that can still change before we use it.
refuse_unless_safe() {
  local what="$1" uid="$2" mode="$3" type="$4"
  if [[ -z "$me_uid" ]]; then me_uid=$(id -u); fi
  if [[ "$uid" != "$me_uid" && "$uid" != 0 ]]; then
    die "refusing to write: $what is owned by uid $uid, not you"
  fi
  if [[ "$type" == "directory" ]] && (( (8#$mode & 0022) != 0 )); then
    die "refusing to write: $what is group/other writable (mode $mode)"
  fi
}

# One component of a directory chain: check CUR/COMP without following it, open
# it, and prove the descriptor is the object that was checked. Sets DIR_FD and
# DIR_PATH to the new descriptor. Returns 1 when there is no directory there to
# operate on (missing, or not a directory at all), and dies on a path that is
# refused: a symlinked component, a foreign or group/other writable owner, or a
# component that changed between the check and the open.
#
# No component may be a symlink, not even one the user put there: the whole
# point is that a name cannot be pointed somewhere else between the check and
# the operation. A directory the user reached through a symlink still works —
# the two arguments that name such a directory (this script's own, and the
# source block's) are resolved to their physical path first.
open_dir_at() {
  local cur="$1" comp="$2" info finfo dev ino uid mode type
  local fdev fino fuid fmode ftype fd
  ensure_proc
  # A missing component is an ordinary answer here (return 1, quietly): the
  # callers decide whether that means "nothing to do" or "refuse".
  info=$(lstat_info "$cur$comp" 2>/dev/null) || return 1
  read -r dev ino uid mode typebits <<< "$info"
  if is_symlink_mode "$typebits"; then
    die "refusing to write: $cur$comp is a symlink"
  fi
  is_dir_mode "$typebits" || return 1
  exec {fd}<"$cur$comp" || die "cannot open directory $cur$comp"
  # The descriptor must resolve to the object that was just checked, not to
  # whatever replaced it in the meantime.
  finfo=$(fstat_info "$fd") || die "cannot inspect directory $cur$comp"
  read -r fdev fino fuid fmode ftypebits <<< "$finfo"
  if [[ "$fdev" != "$dev" || "$fino" != "$ino" ]] || ! is_dir_mode "$ftypebits"; then
    eval "exec ${fd}>&-"
    die "refusing to write: $cur$comp changed while it was being opened"
  fi
  refuse_unless_safe "$cur$comp" "$fuid" "$fmode" "directory"
  DIR_FD=$fd
  DIR_PATH="/proc/self/fd/$fd"
}

# Open a directory path component by component, each one relative to the
# descriptor of the one before it, and keep the deepest descriptor open: every
# later operation on files in it is relative to that descriptor. Returns 1 when
# the path is not a directory to operate on (see open_dir_at).
open_dir_chain() {
  local path="$1" comp cur prev
  local -a comps
  [[ "$path" == /* ]] || die "target is not absolute: $path"
  cur="/"
  prev=""
  DIR_FD=""
  IFS=/ read -r -a comps <<< "${path#/}"
  for comp in "${comps[@]}"; do
    [[ -n "$comp" ]] || continue
    open_dir_at "$cur" "$comp" || return 1
    # Only the deepest descriptor is needed; the one before it has done its job
    # (its component's entry in its own parent is what identified it).
    if [[ -n "$prev" ]]; then eval "exec ${prev}>&-"; fi
    prev=$DIR_FD
    cur="$DIR_PATH/"
  done
  [[ -n "$DIR_FD" ]] || return 1
}

# Like open_dir_chain, but a missing component is created instead of reported —
# inside the descriptor of its parent, so even the creation cannot land in a
# directory that was swapped in behind us. The leaf (a runtime directory holding
# the state file and the teardown copy) is created private; the ones above it
# keep the usual 755 so a shared ~/.cache is not made private by accident.
#
# DIR_FD and DIR_PATH are cleared up front, together: a chain that pins nothing
# must not leave the caller addressing whatever directory the previous call (or
# bind_self_dir) had pinned. The callers check the return value, so that
# degenerate path — "/" has no component to open — is reported, never mistaken
# for the directory that was actually bound.
ensure_dir_chain() {
  local path="$1" parent comp mode keep
  local -a comps
  local i last
  [[ "$path" == /* ]] || die "target is not absolute: $path"
  while [[ "$path" == */ && "$path" != "/" ]]; do path="${path%/}"; done
  IFS=/ read -r -a comps <<< "${path#/}"
  last=$((${#comps[@]} - 1))
  parent="/"
  keep=""
  DIR_FD=""
  DIR_PATH=""
  for i in "${!comps[@]}"; do
    comp="${comps[$i]}"
    [[ -n "$comp" ]] || continue
    if ! open_dir_at "$parent" "$comp"; then
      # A mkdir that loses a race with another process is not an error here:
      # the open below decides whether the name is a directory we may use.
      mode=755
      [[ "$i" -eq "$last" ]] && mode=700
      mkdir -m "$mode" "$DIR_PATH/$comp" 2>/dev/null || true
      open_dir_at "$DIR_PATH/" "$comp" || die "cannot create or open directory $path"
    fi
    [[ -n "$keep" ]] && eval "exec ${keep}>&-"
    keep=$DIR_FD
    parent="$DIR_PATH/"
  done
  [[ -n "$DIR_FD" ]]
}

# Open a plain file in the pinned directory and keep its descriptor, so the
# reads that follow address the inode that was checked. NAME is the entry in
# the pinned directory, WHAT the same entry is called for in messages.
# Returns 1 when there is no such entry; dies when the entry exists but may not
# be touched (a symlink, a directory, a device node, a foreign owner). Sets
# FILE_FD, FILE_PATH and the FILE_DEV / FILE_INO / FILE_MODE of that inode.
open_file_in_dir() {
  local name="$1" what="${2:-$1}" info finfo dev ino uid mode type fd
  local fdev fino fuid fmode ftype
  FILE_FD=""
  FILE_PATH=""
  FILE_DEV=""
  FILE_INO=""
  FILE_MODE=""
  info=$(lstat_info "$DIR_PATH/$name" 2>/dev/null) || return 1
  read -r dev ino uid mode typebits <<< "$info"
  is_symlink_mode "$typebits" && die "refusing to write: $what is a symlink"
  is_regular_mode "$typebits" || die "refusing to write: $what is not a regular file"
  exec {fd}<"$DIR_PATH/$name" || die "cannot open $what"
  finfo=$(fstat_info "$fd") || die "cannot inspect $what"
  read -r fdev fino fuid fmode ftypebits <<< "$finfo"
  if [[ "$fdev" != "$dev" || "$fino" != "$ino" ]] || ! is_regular_mode "$ftypebits"; then
    eval "exec ${fd}>&-"
    die "refusing to write: $what changed while it was being opened"
  fi
  refuse_unless_safe "$what" "$fuid" "$fmode" "regular file"
  FILE_FD=$fd
  FILE_PATH="/proc/self/fd/$fd"
  FILE_DEV=$fdev
  FILE_INO=$fino
  FILE_MODE=$fmode
}

# Before renaming over a name, the name must still be the entry we worked on:
# a file that appeared or was replaced while we were building the result is
# never clobbered silently. The rename itself is a single atomic step inside
# the pinned directory, so nothing can redirect it after this point.
#   NAME    entry in the pinned directory   WHAT the same entry is called for
#   MODE    absent  the name must still not exist (we are about to create it)
#           inode   the name must still resolve to DEV/INO (we read that one)
#           any     anything goes: the rename replaces the name itself
check_name_intact() {
  local name="$1" what="$2" mode="$3" want_dev="${4:-}" want_ino="${5:-}" info dev ino
  case "$mode" in
    absent)
      if lstat_info "$DIR_PATH/$name" >/dev/null 2>&1; then
        die "$what appeared while it was being created; left untouched"
      fi
      ;;
    inode)
      info=$(lstat_info "$DIR_PATH/$name") || die "$what disappeared while it was being processed; left untouched"
      read -r dev ino _ _ _ <<< "$info" # only the device and inode matter here
      if [[ "$dev" != "$want_dev" || "$ino" != "$want_ino" ]]; then
        die "$what was replaced while it was being processed; left untouched"
      fi
      ;;
  esac
}

# Publish a finished temporary file over NAME in the pinned directory. The data
# is flushed first (best effort), the name is re-checked, and the rename
# replaces the name itself — so even a symlink planted as NAME cannot redirect
# the write into another file.
replace_in_dir() {
  local tmp="$1" name="$2" what="$3" mode="$4" want_dev="${5:-}" want_ino="${6:-}"
  sync -d -- "$tmp" 2>/dev/null || true
  check_name_intact "$name" "$what" "$mode" "$want_dev" "$want_ino"
  mv -f -- "$tmp" "$DIR_PATH/$name" || die "could not atomically replace $what"
}

# Pin this script's own directory the same way, so the awk stripper, the lua
# dispatchers and the jq module are read from the checked directory even after
# the plugin path is swapped. Runs before the target's chain, and keeps its own
# descriptor (SELF_FD) open alongside it.
bind_self_dir() {
  [[ -n "$SELF_FD" ]] && return 0
  [[ -n "$self" ]] || die "plugin directory is not accessible: $script_path"
  open_dir_chain "$self" || die "cannot open plugin directory: $self"
  SELF_FD=$DIR_FD
  SELF_PATH=$DIR_PATH
}

# How many lines of FILE hold the fixed string MARKER. Fails — rather than
# reporting a zero that would look like "no markers" — when the file cannot be
# read at all, so a broken read is never mistaken for a clean file.
count_marker() {
  local out rc
  out=$(grep -cFs -- "$2" "$1" 2>/dev/null)
  rc=$?
  # grep exits 1 for "no match" (a legitimate zero) and >=2 for a read error.
  if [[ -z "$out" ]] || (( rc > 1 )); then return 1; fi
  printf '%s' "$out"
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
  bind_self_dir
  jq -L "$SELF_PATH" -c \
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
  bind_self_dir
  jq -L "$SELF_PATH" -c -n \
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
  bind_self_dir
  dir=$(printf "%s" "$clients" \
    | jq -r -L "$SELF_PATH" \
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
  local src="$1" target="$2" start="$3" end="$4"
  local l0 l1 orig_mode starts ends target_dir target_name src_dir src_name src_path
  # The managed block is read from the plugin's own bindings through a pinned
  # descriptor: it ends up as executable Hyprland config, so it is opened and
  # checked like any other file, not read by pathname.
  # The source directory is the plugin's own, so a symlinked one is resolved to
  # the real directory; the file itself is still taken exactly as named.
  src_dir="$(phys_dir "$(dirname -- "$src")")"
  src_name="$(basename -- "$src")"
  if [[ -z "$src_dir" ]] || ! open_dir_chain "$src_dir" || ! open_file_in_dir "$src_name" "$src"; then
    say "source bindings missing: $src"
    return
  fi
  src_path="$FILE_PATH"
  l0=$(grep -nFs -- "$start" "$src_path" | head -n 1 | cut -d: -f1)
  l1=$(grep -nFs -- "$end" "$src_path" | head -n 1 | cut -d: -f1)
  if [[ -z "$l0" || -z "$l1" ]]; then die "managed block not found in $src"; fi
  if (( l0 > l1 )); then die "managed block markers out of order in $src"; fi
  # Everything below happens inside the target's directory, which is opened,
  # checked and then kept open: the marker counts, the copy of the current file
  # and the replacement all address that directory, so nothing between the
  # check and the rename can point them at a different one.
  target_dir="$(dirname -- "$target")"
  target_name="$(basename -- "$target")"
  open_dir_chain "$target_dir" || die "target directory missing or not a directory: $target_dir"
  # The target must be either fully wired (exactly one intact start/end pair)
  # or free of the markers — any other state was not written by this plugin.
  # Appending a second block would corrupt it further, and the partial block is
  # never stripped automatically: content after a stray marker may be the user's.
  starts=0
  ends=0
  if open_file_in_dir "$target_name" "$target"; then
    starts=$(count_marker "$FILE_PATH" "$start") || die "cannot read $target"
    ends=$(count_marker "$FILE_PATH" "$end") || die "cannot read $target"
  fi
  if (( starts == 1 && ends == 1 )); then
    say "keybindings already wired; nothing to do"
    return
  fi
  if (( starts != 0 || ends != 0 )); then
    die "managed block markers in $target are not intact ($starts start, $ends end); remove them by hand, then restart the service to re-wire a clean block"
  fi
  tmpfile=$(mktemp "$DIR_PATH/$target_name.tmp.XXXXXX") || die "could not create temporary file"
  if [[ -n "$FILE_FD" ]]; then
    # Appending to an existing file: its mode, and the exact bytes we counted
    # the markers in, come from the inode we hold open.
    orig_mode="$FILE_MODE"
    cat "$FILE_PATH" > "$tmpfile" || die "could not write temporary file"
    echo "" >> "$tmpfile" || die "could not write temporary file"
  else
    orig_mode=644
  fi
  sed -n "${l0},${l1}p" "$src_path" >> "$tmpfile" || die "could not write temporary file"
  chmod "$orig_mode" "$tmpfile" || die "could not set permissions on temporary file"
  if [[ -n "$FILE_FD" ]]; then
    replace_in_dir "$tmpfile" "$target_name" "$target" inode "$FILE_DEV" "$FILE_INO"
  else
    replace_in_dir "$tmpfile" "$target_name" "$target" absent
  fi
  tmpfile=""
  # Read the block back through a fresh descriptor on the directory we just
  # wrote into, so even a name planted in the meantime cannot fake the check.
  if ! open_file_in_dir "$target_name" "$target" \
     || [[ "$(count_marker "$FILE_PATH" "$start")" != 1 ]]; then
    die "failed to wire keybindings into $target"
  fi
  if hyprctl reload >/dev/null 2>&1; then
    say "keybindings wired into $target and hyprland reloaded"
  else
    say "warning: keybindings wired into $target, but hyprland reload failed"
  fi
}

cmd_unwire() {
  local target="$1" start="$2" end="$3" starts ends target_dir target_name
  # The stripper comes from the pinned script directory, the target is opened
  # through its own pinned directory, and both stay bound while the result is
  # built and renamed: a symlink swapped in for bindings.lua, or a replaced
  # ~/.config/hypr, cannot redirect the strip onto another file.
  bind_self_dir
  target_dir="$(dirname -- "$target")"
  target_name="$(basename -- "$target")"
  if ! open_dir_chain "$target_dir" || ! open_file_in_dir "$target_name" "$target"; then
    say "bindings file not found: $target; nothing to clean"
    return
  fi
  starts=$(count_marker "$FILE_PATH" "$start") || die "cannot read $target"
  ends=$(count_marker "$FILE_PATH" "$end") || die "cannot read $target"
  # Only an intact, single managed block is ever unwired; duplicates or bare
  # markers mean the file is not in a state this plugin created, so refuse to
  # guess. Markers are single-line comments, so line counts cannot be confounded.
  if (( starts != 1 )) || (( ends != 1 )); then
    say "managed block markers not intact in $target ($starts start, $ends end); leaving file untouched"
    return
  fi
  tmpfile=$(mktemp "$DIR_PATH/$target_name.tmp.XXXXXX") || die "could not create temporary file"
  # Strip into a temp file in the same (pinned) directory, and only rename over
  # the target once the result is produced and verified, so a failure never
  # leaves a half-stripped bindings file behind.
  if ! awk -v s="$start" -v e="$end" -f "$SELF_PATH/grace-window.awk" "$FILE_PATH" > "$tmpfile"; then
    die "unwire (awk) failed; $target left untouched"
  fi
  if grep -qFs -- "$start" "$tmpfile"; then
    die "unwire produced a malformed result (marker still present); $target left untouched"
  fi
  chmod "$FILE_MODE" "$tmpfile" || die "could not set permissions on temporary file"
  replace_in_dir "$tmpfile" "$target_name" "$target" inode "$FILE_DEV" "$FILE_INO"
  tmpfile=""
  if hyprctl reload >/dev/null 2>&1; then
    say "managed keybinding block removed from $target and hyprland reloaded"
  else
    say "warning: managed keybinding block removed from $target, but hyprland reload failed"
  fi
}

cmd_install_unwire() {
  local dir="$1" f tmp
  # This copy is what the service runs on teardown, so the runtime directory is
  # opened, checked and kept open like the bindings directory, and every file is
  # written and renamed inside it. The temporary names are no longer predictable
  # — "$f.tmp.$$" let a name planted in its place redirect a copy onto another
  # file — and the rename replaces the destination name itself, so even a
  # symlink sitting there is overwritten rather than written through.
  bind_self_dir
  ensure_dir_chain "$dir" || die "cannot open or create runtime directory: $dir"
  for f in grace-window.sh grace-window.awk grace-window.lua; do
    tmp=$(mktemp "$DIR_PATH/$f.tmp.XXXXXX") || die "cannot create temporary file for $f"
    tmpfile=$tmp
    cp -- "$SELF_PATH/$f" "$tmp" || die "cannot copy $f to $dir"
    replace_in_dir "$tmp" "$f" "$dir/$f" any
    tmpfile=""
  done
  # The teardown subcommands must exist in the copy — a stale script would
  # strand the grace look on stop and lose the pending state on restart.
  grep -q 'undo-grace' "$DIR_PATH/grace-window.sh" || die "installed unwire script lacks undo-grace"
  grep -q 'save-state' "$DIR_PATH/grace-window.sh" || die "installed unwire script lacks save-state"
}

# Teardown variant of cancel(): drop the grace look of every pending window in
# place, from this runtime copy after the plugin directory may be gone. Windows
# stay exactly where the hide left them on the grace workspace — no pin, no
# mode or geometry changes, no moves; only a reopen restores those. The
# pending queue dies with the service, so no auto-close can fire afterwards.
# Best-effort per window — a vanished window or failed dispatch must not abort
# the rest.
cmd_undo_grace() {
  local data="$1" rec addr opacity opacity_inactive
  [[ -n "$data" ]] || return 0
  while read -r rec; do
    addr=$(jq -r '.address // empty' <<<"$rec")
    [[ -n "$addr" ]] || continue
    opacity=$(jq -r '.opacity // empty' <<<"$rec")
    opacity_inactive=$(jq -r '.opacityInactive // empty' <<<"$rec")
    # Opacity is restored by its captured value (setprop has no unset for it);
    # rounding/rounding_power are unset instead, so the window falls back to its
    # dynamic window rules (e.g. the rounding=8 pop tag rule) instead of being
    # stuck with a per-window override that mutes SUPER+O's rounding change.
    if [[ -z "$opacity" || -z "$opacity_inactive" ]]; then
      say "skipping $addr: captured grace look incomplete"
      continue
    fi
    lua_call "window_set_prop('$addr', 'opacity', $opacity)" || continue
    lua_call "window_set_prop('$addr', 'opacity_inactive', $opacity_inactive)" || continue
    lua_call "window_set_prop('$addr', 'rounding', 'unset')" || continue
    lua_call "window_set_prop('$addr', 'rounding_power', 'unset')" || continue
    # A setprop on a numeric prop discards the window-rule copy of its value,
    # so an "unset" alone would leave the rule look (a popped window's rounded
    # corners) off until a tag change re-evaluates the rules. Cycling a
    # throwaway static tag re-applies the dynamic rules and leaves nothing.
    lua_call "window_tag('$addr', '+grace-window-recheck')" || continue
    lua_call "window_tag('$addr', '-grace-window-recheck')" || continue
  done < <(jq -c '.[]?' <<<"$data")
}

# Persist the pending state as $dir/state.json for the next startup; atomic.
# An empty state removes any stale file, so a window that is no longer pending
# is never resurrected with a re-armed auto-close.
cmd_save_state() {
  local dir="$1" data="$2" want_dev want_ino
  # The state dir is bound for the whole command: removing a stale file,
  # writing the new one and renaming it over the old all address the directory
  # that was checked, and the temporary name is unpredictable, so nothing that
  # appears in the dir while we work can redirect or capture the write.
  ensure_dir_chain "$dir" || die "cannot open or create state directory: $dir"
  if [[ -z "$data" || "$data" == "[]" ]]; then
    rm -f -- "$DIR_PATH/state.json" || die "cannot remove stale state file"
    return 0
  fi
  # Keep the state file we are about to replace identified, so a state written
  # by anyone else while this one was built is never clobbered by it.
  want_dev=""
  want_ino=""
  if open_file_in_dir state.json "$dir/state.json"; then
    want_dev="$FILE_DEV"
    want_ino="$FILE_INO"
  fi
  tmpfile=$(mktemp "$DIR_PATH/state.json.tmp.XXXXXX") || die "cannot create temporary state file"
  printf '%s\n' "$data" > "$tmpfile" || die "cannot write state file"
  chmod 600 "$tmpfile" 2>/dev/null || true
  if [[ -n "$want_dev" ]]; then
    replace_in_dir "$tmpfile" state.json "$dir/state.json" inode "$want_dev" "$want_ino"
  else
    replace_in_dir "$tmpfile" state.json "$dir/state.json" absent
  fi
  tmpfile=""
}

# Startup restore probe: every client's address and workspace, to filter the
# saved state down to windows still on their grace workspace.
cmd_state_probe() {
  local clients
  clients=$(hyprctl -j clients 2>/dev/null || true)
  [[ -n "$clients" ]] || clients="[]"
  bind_self_dir
  jq -L "$SELF_PATH" -c 'include "grace-window"; stateProbe' <<<"$clients" || echo "[]"
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
