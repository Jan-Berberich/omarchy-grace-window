module { "name": "grace-window" };

# Grace Window — every jq filter the plugin needs, in one file.
#
# Invoked as  jq -L <scripts dir> <filters> 'include "grace-window"; <entry>(<args>)'.

# The first element of a filter's output, or null when it produced nothing.
# Note that `first // null` does NOT do this: for an empty stream the whole
# expression also stays empty, so a "null fallback" call site would lose its
# input. `firstOrNull` genuinely materializes the null fallback.
def firstOrNull: if length == 0 then null else .[0] end;

# The hide-path capture from an activewindow JSON, with the per-window look
# values passed in as arguments.
def hideQuery($opacity; $opacityInactive; $rounding; $roundingPower):
  {
    address: .address,
    workspaceId: ((.workspace.id // 0) | tostring),
    workspaceName: (.workspace.name // ""),
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

# The reopen-path answer ({ aw, ws, sp }) from the three queried documents.
# sp is the special workspace shown on the focused monitor (the scratchpad),
# or null when no special workspace is up — the signal that lets a reopen land
# on an active scratchpad instead of the regular workspace under its overlay.
def reopenQuery($aw; $ws; $mn):
  ({ aw: $aw, ws: $ws,
     sp: (( $mn | map(select(.focused)) | firstOrNull ) as $m
          | if $m != null and (($m.specialWorkspace.id // 0) != 0)
            then $m.specialWorkspace else null end) });

# Restore-state probe: from every client, its address, the workspace it is on
# (id as a string) and that workspace's name. A startup load keeps only saved
# windows whose address still exists AND still sits on their saved grace
# workspace, so stale state never resurrects a window that moved or died while
# the service was down.
def stateProbe:
  map(
    (.workspace.id? // .workspace // "") as $wid
    | { address: (.address | tostring),
        workspace: ($wid | tostring),
        name: (.workspace.name? // "") }
  );

# Regroup direction: from the clients array and the focused ($f) and reopened
# ($a) addresses, the direction ("l", "r", "u" or "d") in which the reopened
# window should join the focused window's tabbed group. Nothing when the
# focused window is not in a tabbed group on the same workspace.
def regroupDirection($a; $f):
  def cx: .at[0] + (.size[0] / 2);
  def cy: .at[1] + (.size[1] / 2);
  (map(select(.address == $f)) | firstOrNull) as $fwin
  | select($fwin != null and ($fwin.grouped | length) > 0)
  | (map(select(.address == $a)) | firstOrNull) as $tgt
  | select($tgt != null and ($tgt.grouped | length) == 0 and $fwin.workspace.id == $tgt.workspace.id)
  | (($fwin | cx) - ($tgt | cx)) as $dx
  | (($fwin | cy) - ($tgt | cy)) as $dy
  | if (($dx | fabs) >= ($dy | fabs)) then (if $dx > 0 then "r" else "l" end) else (if $dy > 0 then "d" else "u" end) end;

# ---------------------------------------------------------------- configuration
# The plugin's tunables and their shipped defaults. config.json, written next to
# this plugin on first start, overrides any of them. readConfig coerces and
# range-checks every value, so a hand-edited file can never inject a negative
# timeout, a fractional retry count, or a string where a number belongs: a value
# that is absent, mistyped or out of range falls back to its own default —
# independently of the others, so one bad entry never discards the rest.
def configDefaults:
  {
    groupingDelayMs: 100,
    closeRetryMax: 3,
    queryTimeoutMs: 10000,
    loadWaitLimit: 40,
    sweepIntervalMs: 500,
    loadRetryIntervalMs: 500,
    openWaitMs: 5000
  };

# A number >= $min, or $def otherwise. JSON numbers are always finite, so only
# the type and the lower bound need checking.
def numOr($v; $def; $min):
  if ($v | type) == "number" and $v >= $min then $v else $def end;

# Like numOr, but the value must also be a whole number.
def intOr($v; $def; $min):
  if ($v | type) == "number" and $v == ($v | floor) and $v >= $min then $v else $def end;

# The effective configuration: the defaults, overridden by the user's object
# wherever an entry is present and usable. Any input that is not an object
# (a missing file, a bare string, an array) leaves every default in place.
def readConfig($user):
  (if ($user | type) == "object" then $user else {} end) as $u
  | configDefaults as $d
  | {
      groupingDelayMs: intOr($u.groupingDelayMs; $d.groupingDelayMs; 0),
      closeRetryMax: intOr($u.closeRetryMax; $d.closeRetryMax; 0),
      queryTimeoutMs: intOr($u.queryTimeoutMs; $d.queryTimeoutMs; 1),
      loadWaitLimit: intOr($u.loadWaitLimit; $d.loadWaitLimit; 0),
      sweepIntervalMs: intOr($u.sweepIntervalMs; $d.sweepIntervalMs; 1),
      loadRetryIntervalMs: intOr($u.loadRetryIntervalMs; $d.loadRetryIntervalMs; 1),
      openWaitMs: intOr($u.openWaitMs; $d.openWaitMs; 1)
    };
