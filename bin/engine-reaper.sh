#!/usr/bin/env bash
# Deferred engine reaper:
#   bin/engine-reaper.sh <pid> <pid-file> <watch-file> <stamp-file> <deadline-secs>
#
# stdin: ignored. stdout: none. Diagnostics are written to stderr.
# Polls a transferred engine PID until it exits, the watch file lands fresh, or
# the deadline elapses. Then performs the phase runner's PID-targeted graceful
# shutdown and removes the transferred PID file. This process is not the
# engine's parent, so liveness is observed only with kill -0, never wait.
set -euo pipefail

usage() {
    echo "usage: bin/engine-reaper.sh <pid> <pid-file> <watch-file> <stamp-file> <deadline-secs>" >&2
    exit 64
}

[ "$#" -eq 5 ] || usage

PID="$1"
PID_FILE="$2"
WATCH="$3"
STAMP="$4"
DEADLINE="$5"

[[ "$PID" =~ ^[1-9][0-9]*$ ]] || usage
[[ "$DEADLINE" =~ ^[1-9][0-9]*$ ]] || usage

# A dead engine on entry is already reaped from this process's perspective.
# Keep this path quiet: there is no deferred work to narrate.
if ! kill -0 "$PID" 2>/dev/null; then
    rm -f "$PID_FILE" || true
    exit 0
fi

ELAPSED=0
REASON=""
while :; do
    if ! kill -0 "$PID" 2>/dev/null; then
        REASON="engine-exited"
        break
    fi
    if [ -f "$WATCH" ] && { [ ! -e "$STAMP" ] || [ "$WATCH" -nt "$STAMP" ]; }; then
        REASON="watch-landed"
        break
    fi
    if [ "$ELAPSED" -ge "$DEADLINE" ]; then
        REASON="deadline"
        break
    fi

    SLEEP_SECS=5
    REMAINING=$((DEADLINE - ELAPSED))
    if [ "$REMAINING" -lt "$SLEEP_SECS" ]; then
        SLEEP_SECS="$REMAINING"
    fi
    sleep "$SLEEP_SECS"
    ELAPSED=$((ELAPSED + SLEEP_SECS))
done

case "$REASON" in
    watch-landed)
        echo "[reaper] watch file landed: $WATCH" >&2
        ;;
    deadline)
        echo "[reaper] deadline elapsed after ${DEADLINE}s waiting for $WATCH" >&2
        ;;
    engine-exited)
        echo "[reaper] engine pid $PID exited before the watch file landed or deadline elapsed" >&2
        ;;
esac

if kill -0 "$PID" 2>/dev/null; then
    kill -TERM "$PID" 2>/dev/null || true
    COUNT=0
    while [ "$COUNT" -lt 30 ]; do
        kill -0 "$PID" 2>/dev/null || break
        sleep 2
        COUNT=$((COUNT + 1))
    done
    if kill -0 "$PID" 2>/dev/null; then
        kill -KILL "$PID" 2>/dev/null || true
    fi
fi

rm -f "$PID_FILE" || true
echo "[reaper] engine stopped (pid $PID)" >&2
exit 0
