module { "name": "grace-window" };

# Grace Window — every jq filter the plugin needs, in one file.
#
# Invoked as  jq -L <scripts dir> <filters> 'include "grace-window"; <entry>(<args>)'.

# The hide-path capture from an activewindow JSON, with the per-window look
# values passed in as arguments.
def hideQuery($opacity; $opacityInactive; $rounding; $roundingPower):
  {
    address: .address,
    opacity: $opacity,
    opacityInactive: $opacityInactive,
    rounding: $rounding,
    roundingPower: $roundingPower,
    floating: .floating,
    fullscreen: .fullscreen,
    fullscreenClient: .fullscreenClient,
    pinned: .pinned,
    x: (.at[0] // 0),
    y: (.at[1] // 0),
    w: (.size[0] // 0),
    h: (.size[1] // 0),
    grouped: .grouped
  };

# The reopen-path answer ({ aw, ws }) from the two queried documents.
def reopenQuery($aw; $ws): { aw: $aw, ws: $ws };

# Regroup direction: from the clients array and the focused ($f) and reopened
# ($a) addresses, the direction ("l", "r", "u" or "d") in which the reopened
# window should join the focused window's tabbed group. Nothing when the
# focused window is not in a tabbed group on the same workspace.
def regroupDirection($a; $f):
  def cx: .at[0] + (.size[0] / 2);
  def cy: .at[1] + (.size[1] / 2);
  (map(select(.address == $f)) | first // null) as $fwin
  | select($fwin != null and ($fwin.grouped | length) > 0)
  | (map(select(.address == $a)) | first // null) as $tgt
  | select($tgt != null and ($tgt.grouped | length) == 0 and $fwin.workspace.id == $tgt.workspace.id)
  | (($fwin | cx) - ($tgt | cx)) as $dx
  | (($fwin | cy) - ($tgt | cy)) as $dy
  | if (($dx | fabs) >= ($dy | fabs)) then (if $dx > 0 then "r" else "l" end) else (if $dy > 0 then "d" else "u" end) end;
