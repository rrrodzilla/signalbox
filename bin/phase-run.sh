#!/usr/bin/env bash
# Phase runner: stdin = phase.request {issue, phase, correlation_id}
# stdout = phase.done (input + {outcome, log})
#
# Runs ONE phase engine as a child process, watches DISK ARTIFACTS (never
# engine claims) for the phase's terminal condition, then stops the child
# gracefully (SIGTERM by PID — never pkill by name, other engines may be
# alive) so its event trail flushes. The runner reports what it OBSERVED;
# judging whether the phase actually succeeded is the operator's job.
set -euo pipefail
# shellcheck source=_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/_env.sh"

PAYLOAD="$(cat)"
PHASE="$(jq -r '.phase' <<<"$PAYLOAD")"
ISSUE="$(jq -r '.issue' <<<"$PAYLOAD")"

case "$PHASE" in
    plan)      CFG="plan.toml";      TIMEOUT=2400 ;;
    implement) CFG="implement.toml"; TIMEOUT=5400 ;;
    review)    CFG="emergent.toml";  TIMEOUT=3600 ;;
    promote)   exit 0 ;;  # not an engine — promote-exec.sh owns this topic
    *) echo "unknown phase: $PHASE" >&2; exit 64 ;;
esac

mkdir -p "$ROOT/state" "$ROOT/logs"
STAMP="$ROOT/state/pipeline-$PHASE.stamp"
LOG="$ROOT/logs/pipeline-$PHASE.log"
touch "$STAMP"

SIGNALBOX_ISSUE="$ISSUE" emergent --config "$ROOT/$CFG" >"$LOG" 2>&1 &
PID=$!
echo "[pipeline] $PHASE engine up (pid $PID), watching artifacts" >&2

OUTCOME="TIMEOUT"
SECS=0
while [ "$SECS" -lt "$TIMEOUT" ]; do
    kill -0 "$PID" 2>/dev/null || { OUTCOME="ENGINE_DIED"; break; }
    case "$PHASE" in
        plan)
            [ "$ROOT/plan.json" -nt "$STAMP" ] && { OUTCOME="ARTIFACT"; break; }
            grep -q "ESCALATED" "$LOG" && { OUTCOME="ESCALATED"; break; }
            ;;
        implement)
            grep -q "GATE GREEN" "$LOG" && { OUTCOME="ARTIFACT"; break; }
            grep -qiE "escalated" "$LOG" && { OUTCOME="ESCALATED"; break; }
            ;;
        review)
            [ -f "$ROOT/results/CR.md" ] && [ "$ROOT/results/CR.md" -nt "$STAMP" ] \
                && { OUTCOME="ARTIFACT"; break; }
            [ -f "$ROOT/state/pending.json" ] && [ "$ROOT/state/pending.json" -nt "$STAMP" ] \
                && { OUTCOME="PARKED"; break; }
            grep -q "ESCALATED" "$LOG" && { OUTCOME="ESCALATED"; break; }
            ;;
    esac
    sleep 5
    SECS=$((SECS + 5))
done

# Let in-flight sinks finish narrating, then stop ONLY our child, gracefully.
if kill -0 "$PID" 2>/dev/null; then
    sleep 5
    kill -TERM "$PID" 2>/dev/null || true
    for _ in $(seq 1 30); do
        kill -0 "$PID" 2>/dev/null || break
        sleep 2
    done
    kill -0 "$PID" 2>/dev/null && kill -KILL "$PID" 2>/dev/null
fi
wait "$PID" 2>/dev/null || true
echo "[pipeline] $PHASE engine stopped, outcome: $OUTCOME" >&2

jq -c --arg outcome "$OUTCOME" --arg log "$LOG" \
    '. + {outcome: $outcome, log: $log}' <<<"$PAYLOAD"
