#!/usr/bin/env bash
# Phase runner: stdin = phase.request {issue, phase, correlation_id}
# stdout = phase.done (input + {outcome, log})
#
# Runs ONE phase engine from the run's config as a child process, records its
# PID in the run's state, and watches run-scoped DISK ARTIFACTS (never engine
# claims) for the phase's terminal condition. It then stops the child
# gracefully (SIGTERM by PID — never pkill by name, other engines may be alive)
# so its event trail flushes. Exception: at a review ARTIFACT terminal with
# docs-sync still in flight, ownership passes to bin/engine-reaper.sh so the
# sync can finish after the pipeline advances; the reaper performs the same
# graceful stop under a hard deadline, targeted at the engine's PID *and* the
# start time recorded here so a recycled PID is never signalled. The normal
# shutdown also runs from an EXIT/INT/TERM trap, so a runner killed mid-watch
# still reaps its engine and clears its PID file rather than orphaning both.
# The runner reports what it OBSERVED; judging whether the phase actually
# succeeded is the operator's job.
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

mkdir -p "$RUN_DIR/state" "$RUN_DIR/logs"
STAMP="$RUN_DIR/state/pipeline-$PHASE.stamp"
LOG="$RUN_DIR/logs/pipeline-$PHASE.log"
PID_FILE="$RUN_DIR/state/phase-$PHASE.pid"
touch "$STAMP"

if [ -f "$RUN_DIR/$CFG" ]; then
    CONFIG="$RUN_DIR/$CFG"
    echo "[pipeline] $PHASE config: $CONFIG" >&2
else
    CONFIG="$ROOT/$CFG"
    echo "[pipeline] $PHASE config: $CONFIG (run config missing; shared fallback)" >&2
fi

# Stop ONLY our child, gracefully, then reap it and drop its PID file.
# Idempotent: the normal shutdown path and the trap both call it.
PID=""
stop_engine() {
    [ -n "$PID" ] || return 0
    if kill -0 "$PID" 2>/dev/null; then
        kill -TERM "$PID" 2>/dev/null || true
        for _ in $(seq 1 30); do
            kill -0 "$PID" 2>/dev/null || break
            sleep 2
        done
        { kill -0 "$PID" 2>/dev/null \
            && kill -KILL "$PID" 2>/dev/null; } || true
    fi
    wait "$PID" 2>/dev/null || true
    rm -f "$PID_FILE"
    PID=""
}

# Termination before the normal path — operator Ctrl-C, a supervisor's SIGTERM,
# or any set -e abort — would otherwise leave the engine running behind a stale
# PID file that later readers mistake for a live phase.
on_signal() {
    trap - EXIT INT TERM
    stop_engine
    exit "$1"
}
trap stop_engine EXIT
trap 'on_signal 130' INT
trap 'on_signal 143' TERM

SIGNALBOX_ISSUE="$ISSUE" SIGNALBOX_RUN_SLUG="$RUN_SLUG" \
    emergent --config "$CONFIG" >"$LOG" 2>&1 &
PID=$!
printf '%s\n' "$PID" >"$PID_FILE"

# The engine's stable identity: field 22 (starttime) of /proc/<pid>/stat, read
# now, while the engine is still this runner's unreaped child and the kernel
# therefore cannot hand its number to anyone else. Only the deferred reaper
# needs it — it outlives the engine and would otherwise have no way to tell a
# recycled PID from the engine. The pid and comm are stripped through the LAST
# ") " because comm may itself contain spaces and parentheses.
ENGINE_STARTTIME="$(awk '{ sub(/^.*\) /, ""); print $20 }' \
    "/proc/$PID/stat" 2>/dev/null || true)"
[[ "$ENGINE_STARTTIME" =~ ^[0-9]+$ ]] || ENGINE_STARTTIME=""

echo "[pipeline] $PHASE engine up (pid $PID), watching artifacts" >&2

# Every terminal condition is a DISK ARTIFACT (issue #1): the engine's
# redirected stdout is buffered, so narration lines (GATE GREEN, ESCALATED)
# can sit unflushed until the engine exits — polling $LOG for them deadlocks
# a successful phase into its timeout. The log is kept for humans and the
# operator's tail; nothing here greps it.
fresh() { [ -f "$1" ] && [ "$1" -nt "$STAMP" ]; }

OUTCOME="TIMEOUT"
SECS=0
while [ "$SECS" -lt "$TIMEOUT" ]; do
    kill -0 "$PID" 2>/dev/null || { OUTCOME="ENGINE_DIED"; break; }
    if fresh "$RUN_DIR/state/escalated.json"; then OUTCOME="ESCALATED"; break; fi
    case "$PHASE" in
        plan)
            fresh "$RUN_DIR/plan.json" && { OUTCOME="ARTIFACT"; break; }
            ;;
        implement)
            if fresh "$RUN_DIR/state/gate.json"; then
                V="$(jq -r '.verdict // empty' "$RUN_DIR/state/gate.json" 2>/dev/null)"
                if [ "$V" = "GREEN" ]; then OUTCOME="ARTIFACT"; else OUTCOME="GATE_RED"; fi
                break
            fi
            ;;
        review)
            fresh "$RUN_DIR/results/CR.md" && { OUTCOME="ARTIFACT"; break; }
            fresh "$RUN_DIR/state/pending.json" && { OUTCOME="PARKED"; break; }
            ;;
    esac
    sleep 5
    SECS=$((SECS + 5))
done

if [ "$PHASE" = "review" ] \
    && [ "$OUTCOME" = "ARTIFACT" ] \
    && [ -n "$ENGINE_STARTTIME" ] \
    && kill -0 "$PID" 2>/dev/null \
    && ! fresh "$RUN_DIR/state/docs-sync.json"; then
    TRANSFERRED_PID="$PID"
    # Keep the traps armed across the launch: clearing them first would open a
    # window where a signal kills this runner with the engine still unowned,
    # orphaning it behind a stale PID file. Both redirections are load-bearing:
    # stdin is the event payload pipe, so a detached descendant inheriting it
    # would hold EOF open and stall the exec-handler; all reaper narration
    # belongs in the phase log.
    setsid "$(dirname "${BASH_SOURCE[0]}")/engine-reaper.sh" \
        "$PID" "$PID_FILE" "$RUN_DIR/state/docs-sync.json" "$STAMP" 960 \
        "$ENGINE_STARTTIME" \
        </dev/null >>"$LOG" 2>&1 &
    # Ownership has passed to the reaper: emptying PID makes stop_engine a no-op,
    # so the still-armed traps can no longer terminate the transferred engine.
    PID=""
    echo "[pipeline] review terminal reached with docs-sync in flight; handed engine pid $TRANSFERRED_PID to deferred reaper (deadline: 960s)" >&2
else
    # Without a readable start time the reaper could not distinguish the engine
    # from a later process reusing its number, so the handoff is declined and
    # this runner reaps the engine itself — docs-sync loses the deferred window,
    # which the promotion precondition then reports as missing evidence.
    if [ "$PHASE" = "review" ] && [ "$OUTCOME" = "ARTIFACT" ] \
        && [ -z "$ENGINE_STARTTIME" ]; then
        echo "[pipeline] engine identity unreadable; declining the deferred docs-sync handoff" >&2
    fi

    # Let in-flight sinks finish narrating, then stop ONLY our child, gracefully.
    if kill -0 "$PID" 2>/dev/null; then
        sleep 5
    fi
    stop_engine
    echo "[pipeline] $PHASE engine stopped, outcome: $OUTCOME" >&2
fi

# The operator's mandatory review check is `git status --porcelain` in the
# integration worktree, which lives OUTSIDE the operator session's checkout
# (issue #12). Record it here, at the review terminal, the same way every other
# terminal condition is a disk artifact: the operator then verifies recorded
# evidence, and a permission regression degrades to "evidence missing -> HALT"
# instead of halting every run. Never fatal — this runner reports what it
# observed; judging it is the operator's job.
if [ "$PHASE" = "review" ]; then
    "$(dirname "${BASH_SOURCE[0]}")/worktree-evidence.sh" "$INT_WT" \
        >"$RUN_DIR/state/worktree.json" \
        || echo "[pipeline] worktree evidence unavailable for $INT_WT" >&2
fi

jq -c --arg outcome "$OUTCOME" --arg log "$LOG" \
    '. + {outcome: $outcome, log: $log}' <<<"$PAYLOAD"
