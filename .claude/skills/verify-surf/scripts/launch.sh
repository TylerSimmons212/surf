#!/bin/bash
# Launch one isolated Surf instance for verification and wait until it proves
# it is up.
#
#   scripts/launch.sh <run-name> <url> [wait-pattern] [timeout-seconds]
#
# Environment passed through to Surf: SURF_FOCUS, SURF_SILENT, SURF_DEVTOOLS.
# SURF_STATE_DIR is set to a scratch directory so the run never touches
# ~/Library/Application Support/Surf (session.json, favicons, filter lists,
# voices). Overriding HOME does not do this: FileManager resolves Application
# Support from the account, not the environment.
#
# Writes .verify/<run-name>/{stderr.log,pid,state} under the repo root and
# prints the evidence directory. Exit 1 if the wait pattern never appears.
set -u
export PATH="/usr/bin:/bin:/usr/sbin:/opt/homebrew/bin:$PATH"

NAME="${1:?run name}"; URL="${2:?url}"
PATTERN="${3:-\\[surf\\] loaded }"; TIMEOUT="${4:-30}"

ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
EVID="$ROOT/.verify/$NAME"
mkdir -p "$EVID"

if [ -f "$EVID/pid" ] && kill -0 "$(cat "$EVID/pid")" 2>/dev/null; then
  echo "launch: run '$NAME' already has a live instance (pid $(cat "$EVID/pid")); stop it first" >&2
  exit 2
fi

BIN="$(swift build --package-path "$ROOT" --show-bin-path)/Surf"
[ -x "$BIN" ] || { echo "launch: no binary at $BIN — run: swift build" >&2; exit 1; }

STATE="$(mktemp -d /tmp/surf-verify-state.XXXXXX)"
echo "$STATE" > "$EVID/state"
: > "$EVID/stderr.log"

SURF_STATE_DIR="$STATE" SURF_URL="$URL" \
  SURF_FOCUS="${SURF_FOCUS:-}" SURF_SILENT="${SURF_SILENT:-1}" SURF_DEVTOOLS="${SURF_DEVTOOLS:-}" \
  "$BIN" 2>"$EVID/stderr.log" &
PID=$!
echo "$PID" > "$EVID/pid"

deadline=$(( $(date +%s) + TIMEOUT ))
until grep -Eq "$PATTERN" "$EVID/stderr.log"; do
  if ! kill -0 "$PID" 2>/dev/null; then
    echo "launch: Surf exited before '$PATTERN' appeared; see $EVID/stderr.log" >&2; exit 1
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "launch: timed out after ${TIMEOUT}s waiting for '$PATTERN'; see $EVID/stderr.log" >&2; exit 1
  fi
  sleep 0.5
done
echo "$EVID"
