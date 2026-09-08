#!/usr/bin/env bash
set -euo pipefail

# Grace Window — Omarchy shell plugin uninstaller.
#
# Disables and removes the plugin, then removes ONLY the marked block of
# keybindings that install.sh wrote (BLOCK_START..BLOCK_END). Every
# pre-existing binding is left untouched.
#
# If the marked block is missing or malformed, the script fails closed with
# manual instructions instead of guessing at the file's contents.

PLUGIN_ID="jam.grace-window"
PLUGINS_DIR="$HOME/.config/omarchy/plugins"
DEST="$PLUGINS_DIR/$PLUGIN_ID"
HYPR_BINDINGS="$HOME/.config/hypr/bindings.lua"

# Lua comment markers delimiting the plugin-owned keybinding block.
BLOCK_START='-- BEGIN Grace Window (jam.grace-window) managed block - do not edit'
BLOCK_END='-- END Grace Window (jam.grace-window) managed block'

# 1. Disable the plugin in the running shell, then remove its folder.
omarchy-shell -q shell disablePlugin "$PLUGIN_ID" || true
rm -rf "$DEST"

# 2. Remove only the plugin-owned marked block from the bindings file.
if [[ ! -f $HYPR_BINDINGS ]]; then
  echo "uninstall: bindings file not found: $HYPR_BINDINGS (nothing to clean)." >&2
  exit 0
fi

starts=$(grep -cF -e "$BLOCK_START" "$HYPR_BINDINGS" || true)
ends=$(grep -cF -e "$BLOCK_END" "$HYPR_BINDINGS" || true)

if (( starts == 0 )) || (( ends == 0 )) || (( starts != ends )); then
  echo "uninstall: Grace Window managed block was not found intact in $HYPR_BINDINGS;" >&2
  echo "leaving the file untouched to avoid removing any pre-existing bindings." >&2
  echo "Remove the lines between these markers manually, then run 'hyprctl reload':" >&2
  echo "  $BLOCK_START" >&2
  echo "  $BLOCK_END" >&2
  exit 1
fi

cp "$HYPR_BINDINGS" "$HYPR_BINDINGS.bak.$(date +%s)"
tmpfile="${TMPDIR:-/tmp}/grace-window-bindings.$$"
awk -v s="$BLOCK_START" -v e="$BLOCK_END" '
  $0 == s { skip++ }
  !skip { print }
  $0 == e { if (skip > 0) skip-- }
' "$HYPR_BINDINGS" >"$tmpfile"
mv "$tmpfile" "$HYPR_BINDINGS"

hyprctl reload >/dev/null 2>&1 || true

echo "Grace Window plugin removed. Plugin-managed keybinding block removed;"
echo "pre-existing bindings were preserved."