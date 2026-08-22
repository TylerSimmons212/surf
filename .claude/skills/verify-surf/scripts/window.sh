#!/bin/bash
# Evidence from the instance's window, without Accessibility permission.
#
#   scripts/window.sh <run-name> [shot-name]
#
# Appends the window's title and bounds to .verify/<run-name>/windows.txt
# (CoreGraphics window list, filtered to our pid) and tries a screenshot to
# .verify/<run-name>/<shot-name>.png. The screenshot needs Screen Recording
# permission for the process running this script; when macOS refuses it the
# script says so and exits 0, because the window record is still proof.
set -u
export PATH="/usr/bin:/bin:/usr/sbin:$PATH"
NAME="${1:?run name}"; SHOT="${2:-window}"
ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
EVID="$ROOT/.verify/$NAME"
PID="$(cat "$EVID/pid" 2>/dev/null)" || { echo "window: no pid for run '$NAME'" >&2; exit 1; }

INFO="$(swift - "$PID" <<'EOF'
import CoreGraphics
import Foundation
let pid = Int32(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid {
  guard let n = w[kCGWindowNumber as String] as? Int,
        let b = w[kCGWindowBounds as String] as? [String: Double],
        (b["Width"] ?? 0) > 300 else { continue }
  let title = w[kCGWindowName as String] as? String ?? ""
  print("\(n)\t\(Int(b["Width"]!))x\(Int(b["Height"]!))\t\(title)")
  break
}
EOF
)"
[ -n "$INFO" ] || { echo "window: no on-screen window for pid $PID" >&2; exit 1; }
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$SHOT" "$INFO" >> "$EVID/windows.txt"
echo "window: $INFO"

WID="${INFO%%	*}"
if screencapture -x -l "$WID" "$EVID/$SHOT.png" 2>/dev/null && [ -s "$EVID/$SHOT.png" ]; then
  echo "screenshot: $EVID/$SHOT.png"
else
  rm -f "$EVID/$SHOT.png"
  echo "screenshot: refused (grant Screen Recording to the terminal/host app); window record kept"
fi
