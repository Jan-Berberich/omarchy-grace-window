#!/usr/bin/env bash
# Grace Window — every shell operation the plugin needs, in one file.
#
# Subcommands:
#   hide-query                Capture the focused window for the hide path.
#   reopen-query              Query the state the reopen path needs.
#   leave-group ADDR DELAY    Pull a window out of its tabbed group before it
#                             is hidden (applies the grouping delay).
#   regroup ADDR FOCUS DELAY  Move a reopened window into the focused window's
#                             tabbed group.
#   wire SRC TARGET S E       Append the managed keybinding block from SRC to
#                             TARGET between markers S and E (owner-checked,
#                             atomic, no-op when already present).
#   unwire TARGET S E         Remove exactly the managed block again (fails
#                             closed when the markers are not intact).
#   install-unwire DIR        Copy this script and its awk partner into DIR,
#                             creating it first. Teardown later runs the copy,
#                             when the plugin directory is already gone.
#
# The heavy lifting lives next to this file: grace-window.lua carries every
# hl.dsp dispatch, grace-window.jq every jq filter and grace-window.awk the
# unwire stripper. "unwire" also runs after the plugin directory is gone, so it
# must not depend on anything but its arguments and this file's directory.
set -u

self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmpfile=""

say() { echo "grace-window: $*"; }
die() {
  if [[ -n "$tmpfile" ]]; then rm -f "$tmpfile"; fi
  say "ERROR: $*"
  exit 1
}

# A dispatch expression evaluates to a dispatcher in Hyprland's config VM, so
# it loads grace-window.lua and calls one of its functions. hyprctl exits
# nonzero (and prints the error) when the file is missing or broken, so surface
# that instead of losing the dispatch silently.
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

cmd_hide_query() {
  local win addr opacity opacity_inactive rounding rounding_power
  win=$(hyprctl -j activewindow 2>/dev/null) || exit 0
  addr=$(jq -r '.address // empty' <<<"$win") || true
  if [[ -z "$addr" || "$addr" == "0x0" ]]; then
    echo "{}"
    exit 0
  fi
  opacity=$(hyprctl getprop "address:$addr" opacity | tail -n 1) || true
  opacity_inactive=$(hyprctl getprop "address:$addr" opacity_inactive | tail -n 1) || true
  rounding=$(hyprctl getprop "address:$addr" rounding | tail -n 1) || true
  rounding_power=$(hyprctl getprop "address:$addr" rounding_power | tail -n 1) || true
  jq -L "$self" -c \
    --arg opacity "$opacity" \
    --arg opacityInactive "$opacity_inactive" \
    --arg rounding "$rounding" \
    --arg roundingPower "$rounding_power" \
    'include "grace-window"; hideQuery($opacity; $opacityInactive; $rounding; $roundingPower)' \
    <<<"$win"
}

cmd_reopen_query() {
  local aw ws
  aw=$(hyprctl -j activewindow 2>/dev/null || true)
  ws=$(hyprctl -j activeworkspace 2>/dev/null || true)
  [[ -n "$aw" ]] || aw="{}"
  [[ -n "$ws" ]] || ws="{}"
  jq -L "$self" -c -n \
    --argjson aw "$aw" \
    --argjson ws "$ws" \
    'include "grace-window"; reopenQuery($aw; $ws)'
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

cmd_wire() {
  local src="$1" target="$2" start="$3" end="$4" orig_mode l0 l1
  if [[ ! -f "$src" ]]; then say "source bindings missing: $src"; return; fi
  if [[ ! -f "$target" ]]; then say "hyprland bindings file not found: $target"; return; fi
  if grep -qFs -- "$start" "$target"; then say "keybindings already wired; nothing to do"; return; fi
  l0=$(grep -nFs -- "$start" "$src" | head -n 1 | cut -d: -f1)
  l1=$(grep -nFs -- "$end" "$src" | head -n 1 | cut -d: -f1)
  if [[ -z "$l0" || -z "$l1" ]]; then die "managed block not found in $src"; fi
  if (( l0 > l1 )); then die "managed block markers out of order in $src"; fi
  check_target "$target"
  tmpfile=$(mktemp "$(dirname "$target")/bindings.lua.tmp.XXXXXX") || die "could not create temporary file"
  orig_mode=$(stat -c "%a" "$target")
  {
    cat "$target"
    echo ""
    sed -n "${l0},${l1}p" "$src"
  } > "$tmpfile" || die "could not write temporary file"
  chmod "$orig_mode" "$tmpfile" || die "could not set permissions on temporary file"
  mv -f "$tmpfile" "$target" || die "could not atomically replace $target"
  tmpfile=""
  if ! grep -qFs -- "$start" "$target"; then die "failed to wire keybindings into $target"; fi
  hyprctl reload >/dev/null 2>&1 || true
  say "keybindings wired into $target and hyprland reloaded"
}

cmd_unwire() {
  local target="$1" start="$2" end="$3" orig_mode starts ends
  if [[ ! -f "$target" ]]; then say "bindings file not found: $target; nothing to clean"; return; fi
  starts=$(grep -cFs -- "$start" "$target" || true)
  ends=$(grep -cFs -- "$end" "$target" || true)
  if (( starts == 0 )) || (( ends == 0 )) || (( starts != ends )); then
    say "managed block markers not found intact in $target; leaving file untouched"
    return
  fi
  check_target "$target"
  tmpfile=$(mktemp "${target}.tmp.XXXXXX") || die "could not create temporary file"
  orig_mode=$(stat -c "%a" "$target")
  awk -v s="$start" -v e="$end" -f "$self/grace-window.awk" "$target" > "$tmpfile" \
    || die "could not write temporary file"
  chmod "$orig_mode" "$tmpfile" || die "could not set permissions on temporary file"
  mv -f "$tmpfile" "$target" || die "could not atomically replace $target"
  tmpfile=""
  if grep -qFs -- "$start" "$target"; then die "failed to remove managed block from $target"; fi
  hyprctl reload >/dev/null 2>&1 || true
  say "managed keybinding block removed from $target and hyprland reloaded"
}

cmd_install_unwire() {
  local dir="$1"
  mkdir -p "$dir" || die "cannot create runtime dir: $dir"
  cp "$self/grace-window.sh" "$self/grace-window.awk" "$dir/" || die "cannot copy unwire scripts to $dir"
}

case "${1:-}" in
  hide-query) shift; cmd_hide_query "$@" ;;
  reopen-query) shift; cmd_reopen_query "$@" ;;
  leave-group) shift; cmd_leave_group "$@" ;;
  regroup) shift; cmd_regroup "$@" ;;
  wire) shift; cmd_wire "$@" ;;
  unwire) shift; cmd_unwire "$@" ;;
  install-unwire) shift; cmd_install_unwire "$@" ;;
  *) say "unknown subcommand: ${1:-}"; exit 1 ;;
esac
