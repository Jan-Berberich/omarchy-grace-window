import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import qs.Ui

// A letter for every special workspace that currently holds windows, shown
// beside the regular workspace numbers. This restores the old "0" marker the
// grace workspace had when it was a numbered workspace: special:grace reads
// "G", special:minimize "M", special:scratchpad "S", and so on.
BarWidget {
  id: root
  moduleName: "jam.grace-window"

  // The indicator can be switched off without disabling the plugin. The
  // service's config.json carries the switch; this file is watched, so an edit
  // applies without a plugin or shell restart.
  property bool showBarWidget: true

  FileView {
    path: Qt.resolvedUrl("config.json")
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.applyBarWidgetConfig(text())
  }

  // Only an explicit false disables the indicator. A missing, mistyped or
  // unreadable entry keeps it on, matching the service's config validation.
  function applyBarWidgetConfig(raw) {
    var cfg
    try {
      cfg = JSON.parse(String(raw || ""))
    } catch (e) {
      return
    }
    if (!cfg || typeof cfg !== "object") return
    root.showBarWidget = cfg.showBarWidget !== false
  }

  // Occupied special workspaces, ordered by name so the letters keep their
  // place while windows come and go. Hyprland drops an empty special workspace
  // from the model on its own; the window count is still checked so a stale
  // entry can never leave a letter behind.
  readonly property var occupiedSpecials: {
    var workspaces = Hyprland.workspaces ? Hyprland.workspaces.values : []
    var specials = []

    for (var i = 0; i < workspaces.length; i++) {
      var workspace = workspaces[i]
      var name = String(workspace.name || "")
      if (name.indexOf("special:") !== 0) continue

      var windows = workspace.toplevels && workspace.toplevels.values
        ? workspace.toplevels.values.length : 0
      if (windows < 1) continue

      specials.push({
        name: name,
        key: name.substring("special:".length),
        letter: root.letterFor(name),
        windows: windows
      })
    }

    specials.sort(function(left, right) {
      return left.key < right.key ? -1 : (left.key > right.key ? 1 : 0)
    })
    return specials
  }

  // The capital letter that stands for a special workspace: its first letter
  // after "special:". A name without one still gets a visible mark.
  function letterFor(name) {
    var key = String(name || "").substring("special:".length)
    if (key === "") return "?"
    return String.fromCodePoint(key.codePointAt(0)).toUpperCase()
  }

  function luaString(value) {
    return String(value).replace(/\\/g, "\\\\").replace(/"/g, "\\\"")
  }

  // A click toggles the workspace, the way SUPER + DELETE shows the grace
  // workspace and switching away hides it again.
  function toggleSpecial(name) {
    if (!root.bar) return
    var key = String(name || "").substring("special:".length)
    var expression = "hl.dsp.workspace.toggle_special(\"" + root.luaString(key) + "\")"
    root.bar.run("hyprctl dispatch " + Util.shellQuote(expression))
  }

  visible: root.showBarWidget && occupiedSpecials.length > 0
  implicitWidth: root.showBarWidget ? grid.implicitWidth : 0
  implicitHeight: root.showBarWidget ? grid.implicitHeight : 0

  GridLayout {
    id: grid
    anchors.fill: parent
    columns: root.vertical ? 1 : root.occupiedSpecials.length
    columnSpacing: root.vertical ? 0 : Style.space(1)
    rowSpacing: root.vertical ? Style.space(2) : 0

    Repeater {
      model: root.occupiedSpecials

      WidgetButton {
        required property var modelData

        bar: root.bar
        text: modelData.letter
        tooltipText: modelData.name + " (" + modelData.windows + ")"
        horizontalMargin: 6
        verticalPadding: 6
        fixedWidth: root.vertical ? root.barSize : Style.space(20)
        fixedHeight: root.barSize
        onPressed: function() { root.toggleSpecial(modelData.name) }
      }
    }
  }
}
