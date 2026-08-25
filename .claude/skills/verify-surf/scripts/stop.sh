#!/bin/bash
# Tear down one verification instance. Kills only the pid this run started,
# deletes its scratch state directory, and leaves the evidence directory alone.
#
#   scripts/stop.sh <run-name>
set -u
export PATH="/usr/bin:/bin:$PATH"
NAME="${1:?run name}"
ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
EVID="$ROOT/.verify/$NAME"

if [ -f "$EVID/pid" ]; then
  PID="$(cat "$EVID/pid")"
  if kill -0 "$PID" 2>/dev/null; then
    kill "$PID" 2>/dev/null
    for _ in $(seq 1 20); do kill -0 "$PID" 2>/dev/null || break; sleep 0.25; done
    kill -9 "$PID" 2>/dev/null || true
  fi
  rm -f "$EVID/pid"
fi
if [ -f "$EVID/state" ]; then
  H="$(cat "$EVID/state")"
  # The run's own defaults suite, whose name the app wrote into the state
  # directory. Removing it is the whole reason that file exists: a suite is a
  # plist in Preferences like any other, and it outlives the process that
  # made it. Without this, isolating the defaults would just move the litter.
  if [ -f "$H/defaults-suite" ]; then
    SUITE="$(cat "$H/defaults-suite")"
    case "$SUITE" in
      surf.scratch.*)
        # `defaults delete` empties the domain, which is what matters, but
        # leaves the plist behind. Remove the file too, so a machine that has
        # run a hundred verifications does not carry a hundred empty
        # preference files around.
        defaults delete "$SUITE" 2>/dev/null || true
        rm -f "$HOME/Library/Preferences/$SUITE.plist" 2>/dev/null || true
        ;;
    esac
  fi
  case "$H" in /tmp/surf-verify-state.*) rm -rf "$H" ;; esac
  rm -f "$EVID/state"
fi
echo "stopped '$NAME'; evidence kept in $EVID"
