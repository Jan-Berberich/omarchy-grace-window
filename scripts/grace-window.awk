# Grace Window — strip the managed keybinding block from Hyprland's bindings
# file, plus the blank line before it (dropped only while still present).
#
# Run by scripts/grace-window.sh "unwire" with -v s and -v e for the block's
# start and end markers. Reads the file given as the argument and writes the
# cleaned text to stdout.
{
  if (skip) {
    if (index($0, e) == 1) skip = 0
    next
  }
  if (index($0, s) == 1) {
    skip = 1
    if (prev_set && prev != "") print prev
    prev_set = 0
    next
  }
  if (prev_set) print prev
  prev = $0
  prev_set = 1
}
END { if (prev_set) print prev }
