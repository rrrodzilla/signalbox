#!/usr/bin/env bash
# Deferred engine reaper:
#   bin/engine-reaper.sh <pid> <pid-file> <watch-file> <stamp-file> <deadline-secs> <starttime>
#
# stdin: ignored. stdout: none. Diagnostics are written to stderr.
# Polls a transferred engine PID until it exits, the watch file lands fresh, or
# the deadline elapses. Then performs the phase runner's PID-targeted graceful
# shutdown and removes the transferred PID file. This process is not the
# engine's parent, so it can neither wait for the engine nor keep its PID
# reserved: a bare kill -0 would accept any process that inherits the number
# after the engine exits. <starttime> is field 22 of /proc/<pid>/stat as the
# phase runner read it while the engine was still its own unreaped child, and
# every liveness check and every signal here is gated on the PID still carrying
# it. Identity is transferred rather than sampled on entry for the same reason:
# by the time this process starts, the number may already be someone else's.
set -euo pipefail

usage() {
    echo "usage: bin/engine-reaper.sh <pid> <pid-file> <watch-file> <stamp-file> <deadline-secs> <starttime>" >&2
    exit 64
}

[ "$#" -eq 6 ] || usage

PID="$1"
PID_FILE="$2"
WATCH="$3"
STAMP="$4"
DEADLINE="$5"
STARTTIME="$6"

[[ "$PID" =~ ^[1-9][0-9]*$ ]] || usage
[[ "$DEADLINE" =~ ^[1-9][0-9]*$ ]] || usage
[[ "$STARTTIME" =~ ^[0-9]+$ ]] || usage

# Field 22 (starttime, in clock ticks since boot) of /proc/<pid>/stat. Field 2
# is the comm, parenthesized and free to contain spaces and parentheses, so the
# leading pid and comm are stripped through the LAST ") " — every field after
# it is numeric and cannot contain one. Prints nothing and fails when the
# process is gone or its stat line is unreadable.
proc_starttime() {
    local STAT_LINE
    local -a STAT_FIELDS
    STAT_LINE="$(cat "/proc/$1/stat" 2>/dev/null)" || return 1
    [ -n "$STAT_LINE" ] || return 1
    STAT_LINE="${STAT_LINE##*) }"
    read -r -a STAT_FIELDS <<<"$STAT_LINE"
    # The remainder starts at field 3 (state), so starttime is index 19.
    [ "${#STAT_FIELDS[@]}" -gt 19 ] || return 1
    printf '%s\n' "${STAT_FIELDS[19]}"
}

# True only when the PID is still the process that was handed over. A recycled
# PID reports a different start time and is treated as an exited engine, so it
# is never polled against and never signalled.
engine_alive() {
    local CURRENT
    CURRENT="$(proc_starttime "$PID")" || return 1
    [ "$CURRENT" = "$STARTTIME" ] || return 1
}

# A dead engine on entry is already reaped from this process's perspective.
# Keep this path quiet: there is no deferred work to narrate.
if ! engine_alive; then
    rm -f "$PID_FILE" || true
    exit 0
fi

ELAPSED=0
REASON=""
while :; do
    if ! engine_alive; then
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

# Identity is re-verified immediately before each signal, not just once before
# the sequence: the engine can exit and its PID be reused between the TERM and
# the KILL as easily as before either.
if engine_alive; then
    kill -TERM "$PID" 2>/dev/null || true
    COUNT=0
    while [ "$COUNT" -lt 30 ]; do
        engine_alive || break
        sleep 2
        COUNT=$((COUNT + 1))
    done
    if engine_alive; then
        kill -KILL "$PID" 2>/dev/null || true
    fi
fi

rm -f "$PID_FILE" || true
echo "[reaper] engine stopped (pid $PID)" >&2
exit 0
