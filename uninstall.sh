#!/usr/bin/env bash
set -euo pipefail

# Grace Window — Omarchy shell plugin uninstaller.
# Disables and removes the plugin, and reverts the SUPER+W / SUPER+SHIFT+W
# keybinding lines added by install.sh (replacing them with Omarchy defaults
# of "Close window" and "Omawrite").

PLUGIN_ID="jam.grace-window"
PLUGINS_DIR="$HOME/.config/omarchy/plugins"
DEST="$PLUGINS_DIR/$PLUGIN_ID"
HYPR_BINDINGS="$HOME/.config/hypr/bindings.lua"

BIND_0='o.bind("SUPER + SHIFT + CTRL + W", "Close window", hl.dsp.window.close())'
BIND_1='o.bind("SUPER + W", "Close window gracefully", "omarchy-shell grace-window hide")'
BIND_2='o.bind("SUPER + SHIFT + W", "Reopen closed window", "omarchy-shell grace-window reopen")'
UNBIND_1='hl.unbind("SUPER + W")'
UNBIND_2='hl.unbind("SUPER + SHIFT + W")'

# 1. Disable the plugin in the running shell, then remove its folder.
omarchy-shell -q shell disablePlugin "$PLUGIN_ID" || true
rm -rf "$DEST"

# 2. Strip the plugin keybinding block and restore defaults matching Omarchy.
if grep -qF "$BIND_1" "$HYPR_BINDINGS"; then
  cp "$HYPR_BINDINGS" "$HYPR_BINDINGS.bak.$(date +%s)"
  sed -i "/$UNBIND_1/d;/$BIND_1/d;/$UNBIND_2/d;/$BIND_2/d;/$BIND_0/d" "$HYPR_BINDINGS"
  # Restore the default bindings unless a replacement already exists.
  grep -qo 'o.bind("SUPER + W"' "$HYPR_BINDINGS" \
    || echo 'o.bind("SUPER + W", "Close window", hl.dsp.window.close())' >>"$HYPR_BINDINGS"
  grep -qo 'o.bind("SUPER + SHIFT + W"' "$HYPR_BINDINGS" \
    || echo 'o.bind("SUPER + SHIFT + W", "Omawrite", { launch = "omawrite" })' >>"$HYPR_BINDINGS"
fi

hyprctl reload >/dev/null 2>&1 || true

echo "Grace Window plugin removed. SUPER+W and SUPER+SHIFT+W restored to defaults."
