#!/usr/bin/env bash
set -euo pipefail

# Grace Window — Omarchy shell plugin installer.
#
# Installs the plugin (Service.qml + manifest.json) into the user plugin
# directory, enables it in the running shell, and rewires SUPER+W /
# SUPER+SHIFT+W to drive it. Safe to re-run: existing lines are left alone.

PLUGIN_ID="jam.grace-window"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGINS_DIR="$HOME/.config/omarchy/plugins"
DEST="$PLUGINS_DIR/$PLUGIN_ID"
HYPR_BINDINGS="$HOME/.config/hypr/bindings.lua"

BIND_0='o.bind("SUPER + SHIFT + CTRL + W", "Close window", hl.dsp.window.close())'
BIND_1='o.bind("SUPER + W", "Close window gracefully", "omarchy-shell grace-window hide")'
BIND_2='o.bind("SUPER + SHIFT + W", "Reopen closed window", "omarchy-shell grace-window reopen")'
UNBIND_1='hl.unbind("SUPER + W")'
UNBIND_2='hl.unbind("SUPER + SHIFT + W")'

fail() {
  echo "install: $*" >&2
  exit 1
}

[[ -f $SRC/manifest.json && -f $SRC/Service.qml ]] || fail "plugin files not found in $SRC"
omarchy plugin validate "$SRC" >/dev/null || fail "plugin folder failed validation"
[[ -f $HYPR_BINDINGS ]] || fail "hyprland bindings file not found: $HYPR_BINDINGS"

# 1. Install the plugin folder.
mkdir -p "$PLUGINS_DIR"
rm -rf "$DEST"
mkdir -p "$DEST"
cp -r "$SRC/manifest.json" "$SRC/Service.qml" "$DEST"

# 2. Tell the running shell about it and enable it. The rescan happens
# asynchronously, so wait until the plugin is known before enabling it.
omarchy-shell -q shell rescanPlugins
for _ in {1..20}; do
  omarchy-shell -q shell listPlugins | grep -qF "\"$PLUGIN_ID\"" && break
  sleep 0.25
done
result=$(omarchy-shell shell enablePlugin "$PLUGIN_ID" '{}') || true
[[ $result == "ok" || -z $result ]] || fail "could not enable plugin: $result"

# 3. Wire the keybindings (idempotent).
if ! grep -qF "$BIND_1" "$HYPR_BINDINGS" || ! grep -qF "$BIND_0" "$HYPR_BINDINGS"; then
  cp "$HYPR_BINDINGS" "$HYPR_BINDINGS.bak.$(date +%s)"
  # Drop the previous standalone-script implementation, if present.
  sed -i '/omarchy-grace-window hide/d;/omarchy-grace-window reopen/d' "$HYPR_BINDINGS"
  {
    echo ""
    echo "-- Grace Window plugin keybindings (jam.grace-window)."
    echo "$UNBIND_1"
    echo "$BIND_1"
    echo "$UNBIND_2"
    echo "$BIND_2"
    grep -qF "$BIND_0" "$HYPR_BINDINGS" || echo "$BIND_0"
  } >>"$HYPR_BINDINGS"
fi

hyprctl reload >/dev/null 2>&1 || true

echo "Grace Window plugin installed and enabled ($PLUGIN_ID)."
echo "SUPER+W hides to workspace 10; SUPER+SHIFT+W reopens within 60s."
echo "SUPER+SHIFT+CTRL+W closes for real, immediately."
