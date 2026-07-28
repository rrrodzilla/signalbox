#!/usr/bin/env bash
# Phase runner: stdin = phase.request {issue, phase}
# stdout = phase.done (input + {outcome, log})
#
# Runs ONE phase engine from the run's config as a child process, records its
# PID in the run's state, and watches run-scoped DISK ARTIFACTS (never engine
# claims) for the phase's terminal condition. It then stops the child
# gracefully (SIGTERM by PID — never pkill by name, other engines may be alive)
# so its event trail flushes. Exception: at a parked review terminal, or at a
# review ARTIFACT terminal with docs-sync still in flight, ownership passes to
# bin/engine-reaper.sh. A park deliberately keeps the approval webhook live;
# the artifact handoff lets sync finish after the pipeline advances. The reaper
# performs the same graceful stop under a hard deadline, targeted at the
# engine's PID *and* the start time recorded here so a recycled PID is never
# signalled. The normal shutdown also runs from an EXIT/INT/TERM trap, so a
# runner killed mid-watch still reaps its engine and clears its PID file rather
# than orphaning both.
# The runner reports what it OBSERVED; judging whether the phase actually
# succeeded is the operator's job.
set -euo pipefail
# shellcheck source=_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/_env.sh"
# shellcheck source=_liveness.sh
source "$(dirname "${BASH_SOURCE[0]}")/_liveness.sh"
# shellcheck source=_correlation.sh
source "$(dirname "${BASH_SOURCE[0]}")/_correlation.sh"

PAYLOAD="$(cat)"
PHASE="$(jq -r '.phase' <<<"$PAYLOAD")"
ISSUE="$(jq -r '.issue' <<<"$PAYLOAD")"
# The pipeline's correlation reaches this handler on the envelope of the
# phase.request it is processing, which exec-handler exports as
# EMERGENT_CORRELATION_ID. Validate before forwarding: the child engine's
# exec-source rejects a malformed id outright rather than starting a competing
# trail, so a bad value here fails the phase loudly instead of quietly
# splitting the run.
CID="$(correlation_id_or_empty)"

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

# EMERGENT_CORRELATION_ID is the only channel that crosses an engine boundary:
# the envelope is a property of one engine's fabric, so the child's exec-source
# adopts the parent's id from its environment (clap reads the same variable)
# and stamps it on everything the phase publishes. One id, every engine, so
# `bin/audit.sh <id>` reconstructs the whole run (issue #42).
#
# A phase launched directly by bin/run.sh --phase inherits nothing; its seed
# mints its own id, and the trail covers that phase alone.
SIGNALBOX_ISSUE="$ISSUE" SIGNALBOX_RUN_SLUG="$RUN_SLUG" \
    EMERGENT_CORRELATION_ID="$CID" \
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
ENGINE_START_ID="$(proc_identity "$PID" || true)"

echo "[pipeline] $PHASE engine up (pid $PID), watching artifacts" >&2

# Every terminal condition is a DISK ARTIFACT (issue #1): the engine's
# redirected stdout is buffered, so narration lines (GATE GREEN, ESCALATED)
# can sit unflushed until the engine exits — polling $LOG for them deadlocks
# a successful phase into its timeout. The log is kept for humans and the
# operator's tail; nothing here greps it.
fresh() { [ -f "$1" ] && [ "$1" -nt "$STAMP" ]; }

write_park_record() {
    local HELD_VALUE="$1" PID_VALUE="$2" START_ID_VALUE="$3"
    local DEADLINE_VALUE="$4" LEASE_VALUE="$5" REASON_VALUE="$6"
    local PARK_FILE="$RUN_DIR/state/park.json"
    local PARK_TEMP="$PARK_FILE.tmp.$$"
    local PENDING="$RUN_DIR/state/pending.json"
    local WATCH="$RUN_DIR/state/docs-sync.json"
    local APPROVE_URL="http://127.0.0.1:$APPROVAL_PORT/approve"
    local APPROVE_COMMAND
    local SINCE

    # The recorded command is meant to be pasted and run verbatim, so the
    # pending path has to survive as a single shell word: a harness installed
    # under a path with a space would otherwise split `--data @` across
    # arguments and curl would post the wrong file (or none). printf %q yields
    # exactly one word for any path.
    APPROVE_COMMAND="curl -s -X POST $APPROVE_URL -H 'Content-Type: application/json' --data @$(printf '%q' "$PENDING")"
    SINCE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    jq -n \
        --argjson held "$HELD_VALUE" \
        --arg issue "$ISSUE" \
        --arg holder "phase-run" \
        --argjson port "$APPROVAL_PORT" \
        --arg approve_url "$APPROVE_URL" \
        --arg approve_command "$APPROVE_COMMAND" \
        --arg pending "$PENDING" \
        --argjson pid "$PID_VALUE" \
        --arg start_id "$START_ID_VALUE" \
        --arg pid_file "$PID_FILE" \
        --arg watch "$WATCH" \
        --argjson deadline "$DEADLINE_VALUE" \
        --arg since "$SINCE" \
        --argjson lease_transferred "$LEASE_VALUE" \
        --arg reason "$REASON_VALUE" \
        '{
            held: $held,
            issue: ($issue | tonumber),
            phase: "review",
            holder: $holder,
            port: $port,
            approve_url: $approve_url,
            approve_command: $approve_command,
            pending: $pending,
            pid: $pid,
            start_id: (if $held then $start_id else null end),
            pid_file: $pid_file,
            watch: $watch,
            deadline: $deadline,
            since: $since,
            lease_transferred: $lease_transferred,
            reason: (if $reason == "" then null else $reason end)
        }' >"$PARK_TEMP"
    mv "$PARK_TEMP" "$PARK_FILE"
}

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

HOLD_REASON=""
HOLD_DEADLINE=""
PARK_HELD=false
if [ "$PHASE" = "review" ] && [ "$OUTCOME" = "PARKED" ]; then
    PARK_GRACE_DEFAULT=86400
    PARK_GRACE_MAX=86400
    PARK_GRACE_RAW="${SIGNALBOX_PARK_GRACE:-$PARK_GRACE_DEFAULT}"
    if [[ "$PARK_GRACE_RAW" =~ ^[0-9]{1,6}$ ]] \
        && [ "$((10#$PARK_GRACE_RAW))" -ge 1 ] \
        && [ "$((10#$PARK_GRACE_RAW))" -le "$PARK_GRACE_MAX" ]; then
        PARK_GRACE=$((10#$PARK_GRACE_RAW))
    else
        printf '[pipeline] ignoring invalid SIGNALBOX_PARK_GRACE=%s (expected 1-%s seconds); using %ss\n' \
            "$PARK_GRACE_RAW" "$PARK_GRACE_MAX" "$PARK_GRACE_DEFAULT" >&2
        PARK_GRACE=$PARK_GRACE_DEFAULT
    fi
    HOLD_REASON="park"
    HOLD_DEADLINE="$PARK_GRACE"
elif [ "$PHASE" = "review" ] \
    && [ "$OUTCOME" = "ARTIFACT" ] \
    && ! fresh "$RUN_DIR/state/docs-sync.json"; then
    HOLD_REASON="docs-sync"
    HOLD_DEADLINE=960
fi

HANDOFF_READY=false
if [ -n "$HOLD_REASON" ] \
    && [ -n "$ENGINE_STARTTIME" ] \
    && kill -0 "$PID" 2>/dev/null; then
    HANDOFF_READY=true
fi
if [ "$HOLD_REASON" = "park" ]; then
    ENGINE_PROC_STATE="$(awk '{ sub(/^.*\) /, ""); print $1 }' \
        "/proc/$PID/stat" 2>/dev/null || true)"
    if [ -z "$ENGINE_START_ID" ] || [ "$ENGINE_PROC_STATE" = "Z" ]; then
        HANDOFF_READY=false
    fi
fi

if [ "$HANDOFF_READY" = true ]; then
    TRANSFERRED_PID="$PID"
    # Keep the traps armed across the launch: clearing them first would open a
    # window where a signal kills this runner with the engine still unowned,
    # orphaning it behind a stale PID file. Both redirections are load-bearing:
    # stdin is the event payload pipe, so a detached descendant inheriting it
    # would hold EOF open and stall the exec-handler; all reaper narration
    # belongs in the phase log.
    setsid "$(dirname "${BASH_SOURCE[0]}")/engine-reaper.sh" \
        "$PID" "$PID_FILE" "$RUN_DIR/state/docs-sync.json" "$STAMP" "$HOLD_DEADLINE" \
        "$ENGINE_STARTTIME" \
        </dev/null >>"$LOG" 2>&1 &

    if [ "$HOLD_REASON" = "park" ]; then
        LEASE_TRANSFERRED=false
        if "$(dirname "${BASH_SOURCE[0]}")/ports.sh" transfer \
            "$RUN_SLUG" "$TRANSFERRED_PID" >/dev/null 2>&1; then
            LEASE_TRANSFERRED=true
        else
            echo "[pipeline] port lease could not be transferred to the held engine; the registry entry may be released while the webhook is still listening" >&2
        fi

        # Spawning the reaper and transferring the lease both take time, and the
        # engine can exit or be stopped inside that window — a transfer refused
        # for a dead target is one symptom of exactly that. The record and the
        # narration may only claim a live webhook if this exact process is still
        # running now; otherwise the park is a closed window and says so.
        if engine_running "$TRANSFERRED_PID" "$ENGINE_START_ID"; then
            PARK_HELD=true
            write_park_record true "$TRANSFERRED_PID" "$ENGINE_START_ID" \
                "$HOLD_DEADLINE" "$LEASE_TRANSFERRED" ""
        else
            PARK_REASON="The approval window is closed because the review engine exited while ownership of it was being transferred."
            write_park_record false null "" null "$LEASE_TRANSFERRED" \
                "$PARK_REASON"
            echo "[pipeline] $PARK_REASON" >&2
        fi
    fi

    # Ownership has passed to the reaper: emptying PID makes stop_engine a no-op,
    # so the still-armed traps can no longer terminate the transferred engine.
    PID=""
    if [ "$HOLD_REASON" = "park" ]; then
        if [ "$PARK_HELD" = true ]; then
            echo "[pipeline] review parked; deliberately leaving idle engine pid $TRANSFERRED_PID open at http://127.0.0.1:$APPROVAL_PORT/approve for approval (deadline: ${HOLD_DEADLINE}s)" >&2
        fi
    else
        echo "[pipeline] review terminal reached with docs-sync in flight; handed engine pid $TRANSFERRED_PID to deferred reaper (deadline: 960s)" >&2
    fi
else
    # Without a readable start time the reaper could not distinguish the engine
    # from a later process reusing its number, so the handoff is declined and
    # this runner reaps the engine itself — docs-sync loses the deferred window,
    # which the promotion precondition then reports as missing evidence.
    if [ "$PHASE" = "review" ] && [ "$OUTCOME" = "ARTIFACT" ] \
        && [ -z "$ENGINE_STARTTIME" ]; then
        echo "[pipeline] engine identity unreadable; declining the deferred docs-sync handoff" >&2
    fi
    if [ "$HOLD_REASON" = "park" ]; then
        if [ -z "$ENGINE_STARTTIME" ] || [ -z "$ENGINE_START_ID" ]; then
            PARK_REASON="The approval window is closed because the review engine identity was unreadable, so a safe deferred handoff was impossible."
        else
            PARK_REASON="The approval window is closed because the review engine exited before ownership could be transferred."
        fi
        write_park_record false null "" null false "$PARK_REASON"
        echo "[pipeline] $PARK_REASON" >&2
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
