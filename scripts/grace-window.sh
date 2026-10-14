#!/usr/bin/env bash
# Grace Window — every shell operation the plugin needs, in one file.
#
# hide-query / reopen-query    Capture focused-window / workspace state (JSON).
# leave-group ADDR DELAY       Pull ADDR out of its tabbed group (+ delay).
# regroup ADDR FOCUS DELAY     Move ADDR into FOCUS's tabbed group.
# close ADDR                   Close ADDR and verify it is gone: exit 0 only
#                              when the address no longer exists (retryable
#                              otherwise, never a success on a broken query).
# wire SRC TARGET S E [CUSTOM REF]
#                              Append the managed block to TARGET (markers S/E),
#                              atomically; a no-op when one intact block exists,
#                              fail-closed otherwise. SRC is the shipped default;
#                              an intact block in CUSTOM (the captured
#                              customization) is preferred over it. REF records
#                              the block this run wired, for unwire.
# unwire TARGET S E [CUSTOM REF]
#                              Remove exactly the managed block again, first
#                              capturing it to CUSTOM when it differs from REF.
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
# so a checked path cannot be swapped for another one behind our back - and no
# name is ever opened in a way that could wait for something (a fifo, say) to
# happen, so a swap can cost at most a failed command, never a wedged service.
set -u

# Physical path of this script's directory: a plugin directory reached through a
# symlink (a dotfile checkout, say) is used as the real directory it points at,
# so the no-follow check below sees no symlink of our own making.
phys_dir() { (cd -- "$1" 2>/dev/null && pwd -P); }

# Physical path of the longest existing prefix of a directory path, with the
# components that do not exist yet left on the end. A component the user created
# as a symlink (a dotfiles-managed ~/.config/omarchy, say) is therefore entered
# as the real directory it points at — the same treatment the plugin's own path
# and a source block's directory already get — while a directory that has to be
# created is created inside the resolved prefix, so a symlink cannot make the
# creation land somewhere else. Requires an absolute path; fails when even the
# existing prefix cannot be resolved.
phys_prefix() {
  local path="$1" rest="" phys
  [[ "$path" == /* ]] || return 1
  while [[ "$path" != "/" && ! -d "$path" ]]; do
    rest="/$(basename -- "$path")$rest"
    path="$(dirname -- "$path")"
  done
  phys="$(phys_dir "$path")" || return 1
  printf '%s%s' "$phys" "$rest"
}
script_path="${BASH_SOURCE[0]}"
self="$(phys_dir "$(dirname -- "$script_path")")"
tmpfile=""
me_uid=""
proc_seen=""
# How long a read-only open in a child (open_file_in_child) may take before it
# counts as stuck. Comfortably under the service's own 10s watchdog, so a name
# that blocks is reported as an error by this script instead of the whole
# command being killed from the outside.
open_wait=5
# The children holding a descriptor open on our behalf, killed and reaped by
# release_holders on every way out.
declare -a holder_pids=()
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
# Three properties make the binding work:
#   * Components are entered one at a time, each relative to the descriptor of
#     the one before it, and the object a new descriptor resolves to must be
#     the very inode the check just saw (same device, same inode). A component
#     replaced between check and enter is thus either caught or has no effect.
#   * The descriptors stay open in this shell and every child inherits them, so
#     /proc/self/fd/N names the same open file here and in grep, awk, sed, cat,
#     mktemp or mv. Those paths only exist while we hold the descriptor and are
#     never passed to a process that outlives this command.
#   * No name is opened in a way that can wait. bash opens read-only or
#     read-write and nothing else, and of the two exactly one returns at once
#     whatever the name resolves to: a fifo opened read-write does not wait for
#     a writer, the same fifo opened read-only does. A fifo swapped in for
#     bindings.lua, or for a directory in its path, would therefore wedge this
#     script inside open() - before the inode check could run at all, and with
#     the state the checks exist to protect not yet touched. Nothing here may
#     wait, because nothing here is waited for: a wedged script wedges the
#     service with it, and the teardown that unwires the keybindings runs with
#     no watchdog left to kill it. So a directory is entered with cd (which
#     answers ENOTDIR for a fifo instead of waiting for one) and pinned through
#     /proc/self/cwd, and a file is opened read-write - or, when it may not be
#     written at all, in a child that is waited for with a bound and killed when
#     it does not come back. A name that turns out to be a fifo is then a failed
#     command, which the callers already report and recover from, and never a
#     service that stops answering.
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

# Enter a directory and pin it, without ever opening its name. `builtin cd` is
# the only way into a directory that cannot block: chdir(2) fails on a fifo with
# ENOTDIR instead of waiting for a writer, and the descriptor is then taken from
# /proc/self/cwd, which names the directory the shell is sitting in rather than
# the name it walked - so whatever replaced that name in the meantime has no say
# in the open at all. The way back is an inode as well: the working directory
# this shell started in is pinned the same way and entered again through its own
# descriptor, which is what keeps several pins independent of each other and of
# every name in the path. PWD and OLDPWD are put back by hand afterwards, since
# the round trip goes through /proc and would otherwise leave the shell sitting
# in /proc/self/fd/7.
#
# Sets DIR_FD and DIR_PATH to the new descriptor. Returns 1 when PATH is not a
# directory to operate on at all (missing, or a fifo or anything else that is
# not a directory) and 2 when it is one but cannot be opened for reading.
pin_entered_dir() {
  local path="$1" back saved_pwd saved_oldpwd fd
  ensure_proc
  # Nothing is pinned until the dance below succeeds, so a failure cannot leave
  # a caller holding the previous call's descriptor.
  DIR_FD=""
  DIR_PATH=""
  # /proc/self/cwd is a magic link to the current directory, so this open names
  # an inode directly: it cannot be redirected, and it cannot block either.
  exec {back}</proc/self/cwd || return 2
  saved_pwd=$PWD
  saved_oldpwd=${OLDPWD-}
  # cd's own complaint is dropped: there is nothing to add to it, and this
  # function reports what happened in the caller's words.
  if ! builtin cd -- "$path" 2>/dev/null; then
    eval "exec ${back}>&-"
    return 1
  fi
  if ! exec {fd}</proc/self/cwd; then
    builtin cd -- "/proc/self/fd/$back" 2>/dev/null
    eval "exec ${back}>&-"
    return 2
  fi
  builtin cd -- "/proc/self/fd/$back" || die "cannot return to the working directory"
  eval "exec ${back}>&-"
  PWD=$saved_pwd
  if [[ -n "$saved_oldpwd" ]]; then OLDPWD=$saved_oldpwd; else unset OLDPWD; fi
  DIR_FD=$fd
  DIR_PATH="/proc/self/fd/$fd"
}

# One component of a directory chain: check CUR/COMP without following it, enter
# and pin it, and prove the descriptor is the object that was checked. Sets
# DIR_FD and DIR_PATH to the new descriptor. Returns 1 when there is no
# directory there to operate on (missing, or not a directory at all), and dies
# on a path that is refused: a symlinked component, a foreign or group/other
# writable owner, a directory that cannot be opened for reading, or a component
# that changed between the check and the enter.
#
# No component may be a symlink, not even one the user put there: the whole
# point is that a name cannot be pointed somewhere else between the check and
# the operation. A directory the user reached through a symlink still works —
# the two arguments that name such a directory (this script's own, and the
# source block's) are resolved to their physical path first.
open_dir_at() {
  local cur="$1" comp="$2" info finfo dev ino uid mode typebits fd
  local fdev fino fuid fmode ftype
  # A missing component is an ordinary answer here (return 1, quietly): the
  # callers decide whether that means "nothing to do" or "refuse".
  info=$(lstat_info "$cur$comp" 2>/dev/null) || return 1
  read -r dev ino uid mode typebits <<< "$info"
  if is_symlink_mode "$typebits"; then
    die "refusing to write: $cur$comp is a symlink"
  fi
  is_dir_mode "$typebits" || return 1
  pin_entered_dir "$cur$comp"
  case $? in
    0) ;;
    1) return 1 ;;
    *) die "cannot open directory $cur$comp" ;;
  esac
  fd=$DIR_FD
  # The descriptor must resolve to the object that was just checked, not to
  # whatever replaced it in the meantime.
  finfo=$(fstat_info "$fd") || die "cannot inspect directory $cur$comp"
  read -r fdev fino fuid fmode ftype <<< "$finfo"
  if [[ "$fdev" != "$dev" || "$fino" != "$ino" ]] || ! is_dir_mode "$ftype"; then
    eval "exec ${fd}>&-"
    die "refusing to write: $cur$comp changed while it was being opened"
  fi
  refuse_unless_safe "$cur$comp" "$fuid" "$fmode" "directory"
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

# Open a plain file in a pinned directory and keep a descriptor on it, so the
# reads that follow address the inode that was checked and not whatever the name
# points at afterwards.
#   DIR   the pinned directory   NAME entry in it   WHAT the same entry is
#         called for in messages
# Returns 1 when there is no such entry; dies when the entry exists but may not
# be touched (a symlink, a directory, a device node, a foreign owner) or when it
# is not the object it was checked to be. Sets FILE_FD (empty when a child holds
# the descriptor instead), FILE_PATH and that inode's FILE_DEV / FILE_INO /
# FILE_MODE.
#
# The open cannot block, which is the whole reason it is written this way round.
# Check-then-open leaves a window in which a name can be replaced; the check that
# follows the open is what catches that, and it only ever runs if the open
# returned. Opening read-only would not return for a fifo: open(2) waits for a
# writer that a service nobody is serving will never see, so the window would
# not be a rejected open but a script that stops existing mid-command. So:
#   * a file that may be written is opened read-write, which returns at once
#     whatever it finds; a fifo that replaced it is then refused by the fstat
#     below, and a directory that replaced it fails the open outright
#   * a file that may not be written can only be opened read-only, so its open
#     is delegated to a child that is waited for with a bound (open_file_in_child)
# [[ -w ]] only picks between the two, so a file whose permissions change in
# between costs a slower open or a failed one, never a wrong decision about
# safety: the descriptor is checked either way.
open_file_at() {
  local dir="$1" name="$2" what="${3:-$2}" path
  local info finfo dev ino uid mode typebits fd
  local fdev fino fuid fmode ftype
  # Built separately: a word on a `local` line is expanded before the builtin
  # runs, so "$dir/$name" there would still be the caller's directory.
  path="$dir/$name"
  ensure_proc
  FILE_FD=""
  FILE_PATH=""
  FILE_DEV=""
  FILE_INO=""
  FILE_MODE=""
  info=$(lstat_info "$path" 2>/dev/null) || return 1
  read -r dev ino uid mode typebits <<< "$info"
  is_symlink_mode "$typebits" && die "refusing to write: $what is a symlink"
  is_regular_mode "$typebits" || die "refusing to write: $what is not a regular file"
  if [[ -w "$path" ]]; then
    exec {fd}<>"$path" || die "cannot open $what"
    finfo=$(fstat_info "$fd") || die "cannot inspect $what"
    read -r fdev fino fuid fmode ftype <<< "$finfo"
    if [[ "$fdev" != "$dev" || "$fino" != "$ino" ]] || ! is_regular_mode "$ftype"; then
      eval "exec ${fd}>&-"
      die "refusing to write: $what changed while it was being opened"
    fi
    refuse_unless_safe "$what" "$fuid" "$fmode" "regular file"
    FILE_FD=$fd
    FILE_PATH="/proc/self/fd/$fd"
    FILE_DEV=$fdev
    FILE_INO=$fino
    FILE_MODE=$fmode
    return 0
  fi
  open_file_in_child "$path" "$what" "$dev" "$ino"
}

# Open PATH read-only in a child, for the files open_file_at cannot open
# read-write. The child reports what it got and then parks, so the descriptor it
# opened stays open for us as /proc/PID/fd/9 for as long as we hold the pipe
# that keeps it parked.
#
# This is the one place where a name is opened the way that can wait, so the
# wait for it is ours and it is bounded: a name that never finishes opening costs
# open_wait seconds and a clear error, instead of a service that has stopped.
# The child is given the path by variable, never on its standard input, which it
# is busy reading; what it reports is compared against the inode that was checked
# before it is used for anything.
#
# want_dev/want_ino are the inode the name resolved to when it was checked: the
# child may well be looking at a different object by now, and that is the
# question the child exists to answer.
open_file_in_child() {
  local path="$1" what="$2" want_dev="$3" want_ino="$4"
  local pid out report rc fdev fino fuid fmode ftype
  coproc GW_HOLDER {
    # The child's own open error would land in our output and be read as a
    # report; dropping it leaves the parent with an empty read, which is a
    # failure it can tell apart from a success.
    { exec 9<"$path"; } 2>/dev/null || exit 1
    stat -L -c "%d %i %u %a %f" /proc/self/fd/9 2>/dev/null || exit 1
    # Park on stdin: it is the pipe this shell holds the other end of, so the
    # child lives as long as we need it and sees eof (and leaves) when this
    # command is done, rather than outliving the script that spawned it.
    read -r _ || :
  }
  # Coproc state is per-name and the next coproc would take it over, so the
  # child's pid and pipe are taken out of it at once.
  pid=${GW_HOLDER_PID:-}
  out=${GW_HOLDER[0]:-}
  [[ -n "$pid" && -n "$out" ]] || die "cannot open $what"
  holder_pids+=("$pid")
  rc=0
  # The read is wrapped so that a pipe bash has already closed (the child gone)
  # fails quietly instead of printing a shell diagnostic into the output.
  { IFS= read -r -t "$open_wait" report <&"$out"; } 2>/dev/null || rc=$?
  if (( rc != 0 )); then
    release_holder "$pid"
    # A timed-out read is how a blocked open shows up here; a plain failure is
    # a child that could not open the name at all and did say so.
    if (( rc > 128 )); then
      die "refusing to write: $what did not open within ${open_wait}s; left untouched (a fifo in place of a file?)"
    fi
    die "cannot open $what"
  fi
  read -r fdev fino fuid fmode ftype <<< "$report"
  if [[ "$fdev" != "$want_dev" || "$fino" != "$want_ino" ]] || ! is_regular_mode "$ftype"; then
    release_holder "$pid"
    die "refusing to write: $what changed while it was being opened"
  fi
  # The child reports the object it opened, so the ownership and mode are those
  # of the inode we are about to read, not of a name that may since have moved.
  refuse_unless_safe "$what" "$fuid" "$fmode" "regular file"
  FILE_PATH="/proc/$pid/fd/9"
  FILE_DEV=$fdev
  FILE_INO=$fino
  FILE_MODE=$fmode
}

# open_file_in_dir NAME [WHAT]: open_file_at in the directory pinned by the
# current command.
open_file_in_dir() {
  open_file_at "$DIR_PATH" "$1" "${2:-$1}"
}

# Stop a holder child. Killing it closes the descriptor it was holding for us —
# /proc/PID/fd/9 goes with it, so the caller must be done with FILE_PATH first —
# and waiting reaps it. The child is our own and is still parked when we get
# here, so the pid is the child's and not a stranger's.
release_holder() {
  local pid="$1"
  [[ -n "$pid" ]] || return 0
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

# Stop every holder child on the way out, so none of them outlives the command
# that needed the file — including when this script is killed rather than
# returning, which is the case that matters most: the teardown path has no
# watchdog behind it to clean up after a wedged process.
release_holders() {
  local pid
  for pid in "${holder_pids[@]:-}"; do
    release_holder "$pid"
  done
  holder_pids=()
}
trap release_holders EXIT
trap 'exit 1' HUP INT TERM

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

# Print the intact managed block of FILE — the start-marker line through the
# end-marker line — read through the descriptor-bound helpers, so the block is
# taken from the inode that was checked and a swapped-in name cannot redirect
# it. Returns 3 when FILE (or a directory in its path) is simply not there, so
# an optional source can fall back to another; otherwise it dies like every
# other reader when the file is present but may not be used — a symlinked
# component, a refused owner or mode, a non-regular file, or a file without one
# clean marker pair in order.
#
# Callers use it in a command substitution: that subshell is what turns a die()
# into a failed read they can report and recover from rather than a dead
# command, so an unreadable *optional* file never stops the run.
read_managed_block() {
  local file="$1" start="$2" end="$3" dir name l0 l1
  dir="$(phys_dir "$(dirname -- "$file")")"
  name="$(basename -- "$file")"
  if [[ -z "$dir" ]] || ! open_dir_chain "$dir" || ! open_file_in_dir "$name" "$file"; then
    return 3
  fi
  l0=$(grep -nFs -- "$start" "$FILE_PATH" | head -n 1 | cut -d: -f1)
  l1=$(grep -nFs -- "$end" "$FILE_PATH" | head -n 1 | cut -d: -f1)
  if [[ -z "$l0" || -z "$l1" ]]; then die "managed block not found in $file"; fi
  if (( l0 > l1 )); then die "managed block markers out of order in $file"; fi
  sed -n "${l0},${l1}p" "$FILE_PATH"
}

# Publish BLOCK as FILE, atomically, inside a pinned directory: the file's own
# mode is kept when it exists, a new one is created mode 644, and a file that
# already holds exactly BLOCK is left alone — an unchanged capture is not
# rewritten, so it costs no churn and no inode change. A symlinked component in
# the path is entered as the real directory (like the plugin's own path), so a
# dotfiles-managed config tree still works, while a directory that has to be
# created is created inside the resolved one.
#
# Best-effort by design: its callers run it in a subshell, where its die() skips
# that one sidecar write with a warning instead of taking down the whole command
# — the wiring, or the strip that has to follow a capture.
write_block_file() {
  local block="$1" file="$2" what="$3"
  local dir name mode=644 existing="" want_dev="" want_ino="" tmp
  dir="$(phys_prefix "$(dirname -- "$file")")" || die "cannot resolve the directory of $what"
  ensure_dir_chain "$dir" || die "cannot open or create the directory of $what: $dir"
  name="$(basename -- "$file")"
  if open_file_in_dir "$name" "$file"; then
    existing="$(cat -- "$FILE_PATH")" || die "cannot read $what"
    if [[ "$existing" == "$block" ]]; then
      say "$what is already up to date; not rewritten"
      return 0
    fi
    want_dev="$FILE_DEV"
    want_ino="$FILE_INO"
    mode="$FILE_MODE"
  fi
  tmp="$(mktemp "$DIR_PATH/$name.tmp.XXXXXX")" || die "could not create a temporary file for $what"
  tmpfile="$tmp"
  printf '%s\n' "$block" > "$tmp" || die "could not write $what"
  chmod "$mode" "$tmp" || die "could not set permissions on $what"
  if [[ -n "$want_dev" ]]; then
    replace_in_dir "$tmp" "$name" "$what" inode "$want_dev" "$want_ino"
  else
    replace_in_dir "$tmp" "$name" "$what" absent
  fi
  tmpfile=""
}

# Capture the live managed block of a teardown into the custom bindings file, so
# a customization survives the disable and is wired back on the next start
# instead of being replaced by the shipped default. REF holds the block this
# run's wire put in place: while the live block still matches it nothing was
# customized, so nothing is written and no custom file appears — the file's very
# existence means "this differs from the shipped default". A custom file already
# holding exactly the live block is left alone too.
#
# Runs in a subshell of cmd_unwire: re-pinning the directory descriptors here
# cannot disturb the strip that follows, and a die() is a skipped capture with a
# warning, never a strip that did not happen.
capture_custom() {
  local block="$1" custom="$2" ref="$3"
  local ref_dir ref_name wired=""
  ref_dir="$(phys_dir "$(dirname -- "$ref")")"
  ref_name="$(basename -- "$ref")"
  if [[ -z "$ref_dir" ]] || ! open_dir_chain "$ref_dir" || ! open_file_in_dir "$ref_name" "$ref"; then
    say "warning: no wired-bindings reference at $ref; leaving the custom bindings untouched"
    return 0
  fi
  wired="$(cat -- "$FILE_PATH")"
  if [[ "$block" == "$wired" ]]; then
    say "managed block unchanged since it was wired; nothing captured"
    return 0
  fi
  write_block_file "$block" "$custom" "the custom bindings"
}

cmd_wire() {
  local src="$1" target="$2" start="$3" end="$4" custom="${5-}" ref="${6-}"
  local orig_mode starts ends target_dir target_name
  local default_block custom_block block rc crc
  # The block to wire is the captured custom block when there is an intact one —
  # the user's customization carried over from the last teardown — and the
  # shipped default otherwise. Both are read through pinned descriptors: the
  # block ends up as executable Hyprland config, so it is never read by
  # pathname. A custom file that cannot be read is not fatal — it is an optional
  # sidecar, and the shipped default keeps the plugin working — but it is
  # reported, so a customization that can no longer be honored is not dropped
  # silently.
  default_block="$(read_managed_block "$src" "$start" "$end")"; rc=$?
  if (( rc == 3 )); then
    say "source bindings missing: $src"
    return
  fi
  if (( rc != 0 )); then
    say "source bindings unusable: $src"
    return 1
  fi
  block="$default_block"
  if [[ -n "$custom" ]]; then
    custom_block="$(read_managed_block "$custom" "$start" "$end")"; crc=$?
    if (( crc == 0 )); then
      block="$custom_block"
    elif (( crc != 3 )); then
      say "warning: ignoring unusable custom bindings at $custom; keeping the shipped default"
    fi
  fi
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
  if [[ -n "$FILE_PATH" ]]; then
    # Appending to an existing file: its mode, and the exact bytes we counted
    # the markers in, come from the inode we hold open.
    orig_mode="$FILE_MODE"
    cat "$FILE_PATH" > "$tmpfile" || die "could not write temporary file"
    echo "" >> "$tmpfile" || die "could not write temporary file"
  else
    orig_mode=644
  fi
  printf '%s\n' "$block" >> "$tmpfile" || die "could not write temporary file"
  chmod "$orig_mode" "$tmpfile" || die "could not set permissions on temporary file"
  if [[ -n "$FILE_PATH" ]]; then
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
  # Record the block this run actually put in place, so teardown can tell an
  # edited live block from an untouched one (see cmd_unwire). Only here, after
  # the block is confirmed written: on a no-op the reference is deliberately
  # left as the earlier wire set it, so an edit made to the live block (or a
  # hand-edit of the custom file) while the service was up is not mistaken for
  # "already wired" and dropped. Best-effort: a reference that cannot be written
  # costs only the next capture, never the wiring.
  if [[ -n "$ref" ]]; then
    ( tmpfile=""; write_block_file "$block" "$ref" "the wired-bindings reference" ) \
      || say "warning: could not write the wired-bindings reference at $ref; an edited block will not be captured on teardown"
  fi
  if hyprctl reload >/dev/null 2>&1; then
    say "keybindings wired into $target and hyprland reloaded"
  else
    say "warning: keybindings wired into $target, but hyprland reload failed"
  fi
}

cmd_unwire() {
  local target="$1" start="$2" end="$3" custom="${4-}" ref="${5-}"
  local starts ends target_dir target_name
  local target_path target_dev target_ino target_mode stripper_path l0 l1 live
  # The stripper comes from the pinned script directory, the target is opened
  # through its own pinned directory, and both stay bound while the result is
  # built and renamed: a symlink swapped in for bindings.lua, or a replaced
  # ~/.config/hypr, cannot redirect the strip onto another file. Both are opened
  # rather than named, so neither can be a fifo that stops the command opening.
  bind_self_dir
  target_dir="$(dirname -- "$target")"
  target_name="$(basename -- "$target")"
  if ! open_dir_chain "$target_dir" || ! open_file_in_dir "$target_name" "$target"; then
    say "bindings file not found: $target; nothing to clean"
    return
  fi
  # Keep the target's descriptor state: opening the stripper below replaces it.
  target_path=$FILE_PATH
  target_dev=$FILE_DEV
  target_ino=$FILE_INO
  target_mode=$FILE_MODE
  starts=$(count_marker "$target_path" "$start") || die "cannot read $target"
  ends=$(count_marker "$target_path" "$end") || die "cannot read $target"
  # Only an intact, single managed block is ever unwired; duplicates or bare
  # markers mean the file is not in a state this plugin created, so refuse to
  # guess. Markers are single-line comments, so line counts cannot be confounded.
  if (( starts != 1 )) || (( ends != 1 )); then
    say "managed block markers not intact in $target ($starts start, $ends end); leaving file untouched"
    return
  fi
  # Capture the live block before it is stripped, so a customized block is
  # wired back on the next start. It runs in a subshell (it re-pins the
  # directory descriptors and may die) so a capture that cannot be written
  # leaves the block intact for the next run but never stops this strip.
  if [[ -n "$custom" && -n "$ref" ]]; then
    l0=$(grep -nFs -- "$start" "$target_path" | head -n 1 | cut -d: -f1)
    l1=$(grep -nFs -- "$end" "$target_path" | head -n 1 | cut -d: -f1)
    if [[ -n "$l0" && -n "$l1" ]] && (( l0 <= l1 )); then
      live="$(sed -n "${l0},${l1}p" "$target_path")"
      ( tmpfile=""; capture_custom "$live" "$custom" "$ref" ) \
        || say "warning: could not capture the live keybinding block to $custom"
    else
      say "managed block markers are out of order in $target; not capturing it"
    fi
  fi
  tmpfile=$(mktemp "$DIR_PATH/$target_name.tmp.XXXXXX") || die "could not create temporary file"
  # Strip into a temp file in the same (pinned) directory, and only rename over
  # the target once the result is produced and verified, so a failure never
  # leaves a half-stripped bindings file behind.
  open_file_at "$SELF_PATH" grace-window.awk "$self/grace-window.awk" \
    || die "stripper not found: $self/grace-window.awk"
  stripper_path=$FILE_PATH
  if ! awk -v s="$start" -v e="$end" -f "$stripper_path" "$target_path" > "$tmpfile"; then
    die "unwire (awk) failed; $target left untouched"
  fi
  if grep -qFs -- "$start" "$tmpfile"; then
    die "unwire produced a malformed result (marker still present); $target left untouched"
  fi
  chmod "$target_mode" "$tmpfile" || die "could not set permissions on temporary file"
  replace_in_dir "$tmpfile" "$target_name" "$target" inode "$target_dev" "$target_ino"
  tmpfile=""
  if hyprctl reload >/dev/null 2>&1; then
    say "managed keybinding block removed from $target and hyprland reloaded"
  else
    say "warning: managed keybinding block removed from $target, but hyprland reload failed"
  fi
}

cmd_install_unwire() {
  local dir="$1" f tmp src_path
  # This copy is what the service runs on teardown, so the runtime directory is
  # opened, checked and kept open like the bindings directory, and every file is
  # written and renamed inside it. The temporary names are no longer predictable
  # — "$f.tmp.$$" let a name planted in its place redirect a copy onto another
  # file — and the rename replaces the destination name itself, so even a
  # symlink sitting there is overwritten rather than written through. The source
  # files are read through a checked descriptor too: cp opening a name read-only
  # would wait on a fifo planted in the plugin directory.
  bind_self_dir
  ensure_dir_chain "$dir" || die "cannot open or create runtime directory: $dir"
  for f in grace-window.sh grace-window.awk grace-window.lua; do
    open_file_at "$SELF_PATH" "$f" "$self/$f" || die "cannot read $f from the plugin directory"
    src_path=$FILE_PATH
    tmp=$(mktemp "$DIR_PATH/$f.tmp.XXXXXX") || die "could not create temporary file for $f"
    tmpfile=$tmp
    cp -- "$src_path" "$tmp" || die "cannot copy $f to $dir"
    replace_in_dir "$tmp" "$f" "$dir/$f" any
    tmpfile=""
  done
  # The teardown subcommands must exist in the copy — a stale script would
  # strand the grace look on stop and lose the pending state on restart. Read
  # through a descriptor, like every other file here.
  open_file_at "$DIR_PATH" grace-window.sh "$dir/grace-window.sh" \
    || die "installed unwire script is missing"
  src_path=$FILE_PATH
  grep -q 'undo-grace' "$src_path" || die "installed unwire script lacks undo-grace"
  grep -q 'save-state' "$src_path" || die "installed unwire script lacks save-state"
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
