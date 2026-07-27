#!/usr/bin/env bash
# Per-run launcher:
#   bin/run.sh <issue> [--phase pipeline|plan|implement|review|promote]
#   bin/run.sh --list
# This is an operator entry point with no stdin/stdout event contract; stdout
# is human narration and diagnostics go to stderr.
#
# Launches one Emergent engine as a child, records its run metadata, and remains
# its foreground supervisor. Startup — from inspecting existing run state until
# launch.json records the engine — holds the harness lock shared, so a
# concurrent install.sh --reinstall cannot refresh the tree around a run its
# liveness scan never saw. Because the run directory is reused across launches
# of the same issue, it also removes the previous launch's terminal evidence
# (state/complete.json, state/halted.json) before the engine starts.
#
# Standalone plan, implement, and review launches stamp their phase, supervise
# fresh disk artifacts rather than buffered engine narration, stop only their
# own child PID, and publish normalized complete/halted terminal evidence. The
# pipeline launch deliberately keeps the original bare wait contract: its
# topology owns phase stamps, artifact supervision, operator verification, and
# terminal records.
#
# Promote is a non-engine recovery path. It first fails closed on the existing
# review CR, correlation ID, and review stamp, then records this launcher as the
# live owner without leasing a port, rendering templates, spawning Emergent, or
# fabricating a promote/review stamp. It invokes bin/promote-exec.sh with the
# normal phase.request shape and records the result as a standalone terminal.
# No standalone terminal claims operator verification: bin/operator.sh runs
# only inside the pipeline topology.
set -euo pipefail
# shellcheck source=_liveness.sh
source "$(dirname "${BASH_SOURCE[0]}")/_liveness.sh"

usage() {
    echo "usage: bin/run.sh <issue> [--phase pipeline|plan|implement|review|promote] | --list" >&2
}

cr_correlation_id() {
    local CR_PATH="$1"

    awk '
        /^correlation_id:[[:space:]]*/ {
            sub(/^correlation_id:[[:space:]]*/, "")
            sub(/[[:space:]]*$/, "")
            if (length($0) > 0) {
                print
                exit
            }
        }
    ' "$CR_PATH"
}

forward_event() {
    local TOPIC="$1" PAYLOAD="$2"

    # Dashboard delivery is parity-only. Detach all output and do not wait:
    # an unavailable or wedged shared sink must never stall this launcher.
    printf '%s\n' "$PAYLOAD" \
        | "$ROOT/bin/sse-forward.sh" pipeline "$TOPIC" \
            >/dev/null 2>&1 &
}

terminal_observation() {
    case "$PHASE:$OUTCOME" in
        plan:ARTIFACT)
            printf 'a fresh plan.json artifact'
            ;;
        implement:ARTIFACT)
            printf 'a fresh state/gate.json artifact with verdict GREEN'
            ;;
        implement:GATE_RED)
            printf 'a fresh state/gate.json artifact with a non-GREEN verdict'
            ;;
        review:ARTIFACT)
            printf 'a fresh results/CR.md artifact'
            ;;
        review:PARKED)
            printf 'a fresh state/pending.json artifact'
            ;;
        promote:ARTIFACT)
            printf 'an ARTIFACT phase.done result from bin/promote-exec.sh'
            ;;
        *:ESCALATED)
            printf 'a fresh state/escalated.json artifact'
            ;;
        *:ENGINE_DIED)
            printf 'the standalone engine exit before a terminal artifact'
            ;;
        *:TIMEOUT)
            printf 'the standalone artifact deadline elapse'
            ;;
        promote:NO_GO)
            printf '%s' "${PROMOTE_FAILURE_REASON:-a NO_GO phase.done result from bin/promote-exec.sh}"
            ;;
        *)
            printf 'outcome %s' "$OUTCOME"
            ;;
    esac
}

terminal_next_step() {
    case "$PHASE:$OUTCOME" in
        plan:ARTIFACT)
            printf 'verify the plan first-hand, then run bin/run.sh %s --phase implement' "$ISSUE"
            ;;
        implement:ARTIFACT)
            printf 'verify the gate and implementation first-hand, then run bin/run.sh %s --phase review' "$ISSUE"
            ;;
        review:ARTIFACT)
            printf 'verify the review artifacts first-hand, then run bin/run.sh %s --phase promote' "$ISSUE"
            ;;
        review:PARKED)
            printf 'inspect state/pending.json, resolve the approval, then run bin/run.sh %s --phase review' "$ISSUE"
            ;;
        promote:ARTIFACT)
            printf 'inspect the merge evidence and run bin/run.sh --list'
            ;;
        promote:*)
            printf 'fix the reported promotion failure, then run bin/run.sh %s --phase promote' "$ISSUE"
            ;;
        *)
            printf 'inspect the recorded evidence, fix the failure, then run bin/run.sh %s --phase %s' \
                "$ISSUE" "$PHASE"
            ;;
    esac
}

resolve_correlation_id() {
    local CORRELATION=""

    case "$PHASE" in
        plan)
            CORRELATION="$(
                jq -r '
                    if type == "object"
                        and (.correlation_id | type) == "string"
                    then .correlation_id
                    else ""
                    end
                ' "$RUN_DIR/plan.json" 2>/dev/null || true
            )"
            ;;
        implement)
            CORRELATION="$(
                jq -r '
                    if type == "object"
                        and (.correlation_id | type) == "string"
                    then .correlation_id
                    else ""
                    end
                ' "$RUN_DIR/state/run.json" 2>/dev/null || true
            )"
            ;;
        review)
            if [ -f "$RUN_DIR/results/CR.md" ]; then
                CORRELATION="$(cr_correlation_id "$RUN_DIR/results/CR.md" 2>/dev/null || true)"
            fi
            ;;
        promote)
            CORRELATION="${PROMOTE_CORRELATION_ID:-}"
            ;;
    esac

    printf '%s' "$CORRELATION"
}

record_terminal() {
    local TERMINAL_KIND="$1"
    local PARKED_VALUE="$2"
    local CORRELATION_VALUE OBSERVATION NEXT_STEP REASON PAYLOAD TOPIC ARTIFACT

    CORRELATION_VALUE="$(resolve_correlation_id)"
    OBSERVATION="$(terminal_observation)"
    NEXT_STEP="$(terminal_next_step)"
    REASON="Standalone launcher terminal: observed $OBSERVATION. No operator verification ran; bin/operator.sh runs only in the pipeline topology. Next step: $NEXT_STEP."

    PAYLOAD="$(
        jq -n \
            --arg issue "$ISSUE" \
            --arg phase "$PHASE" \
            --argjson parked "$PARKED_VALUE" \
            --arg outcome "$OUTCOME" \
            --arg reason "$REASON" \
            --arg correlation_id "$CORRELATION_VALUE" \
            '{
                issue: ($issue | tonumber),
                phase: $phase,
                parked: $parked,
                outcome: $outcome,
                reason: $reason,
                correlation_id: (
                    if $correlation_id == "" then null else $correlation_id end
                )
            }'
    )"

    printf '%s\n' "$PAYLOAD" \
        | "$ROOT/bin/terminal-record.sh" "$TERMINAL_KIND" "$RUN_DIR"
    TOPIC="pipeline.$TERMINAL_KIND"
    forward_event "$TOPIC" "$PAYLOAD"

    ARTIFACT="$RUN_DIR/state/$TERMINAL_KIND.json"
    printf 'terminal:  %s\n' "$TERMINAL_KIND"
    printf 'phase:     %s\n' "$PHASE"
    printf 'outcome:   %s\n' "$OUTCOME"
    printf 'artifact:  %s\n' "$ARTIFACT"
    printf 'next:      %s\n' "$NEXT_STEP"
}

format_age() {
    local AGE_SECONDS="$1"

    if [ "$AGE_SECONDS" -lt 60 ]; then
        printf '%ss' "$AGE_SECONDS"
    elif [ "$AGE_SECONDS" -lt 3600 ]; then
        printf '%sm' "$((AGE_SECONDS / 60))"
    elif [ "$AGE_SECONDS" -lt 86400 ]; then
        printf '%sh' "$((AGE_SECONDS / 3600))"
    else
        printf '%sd' "$((AGE_SECONDS / 86400))"
    fi
}

list_runs() {
    local LAUNCH RUN_PATH RECORD ISSUE_VALUE SLUG_VALUE PHASE_VALUE
    local PID_VALUE START_VALUE STATUS ENGINES PORTS NEWEST NEWEST_PATH NEWEST_EPOCH
    local NOW AGE
    local -a LAUNCH_FILES

    shopt -s nullglob
    LAUNCH_FILES=("$ROOT"/runs/*/launch.json)
    shopt -u nullglob
    if [ "${#LAUNCH_FILES[@]}" -eq 0 ]; then
        echo "no runs found under $ROOT/runs"
        return 0
    fi

    NOW="$(date +%s)"
    for LAUNCH in "${LAUNCH_FILES[@]}"; do
        RUN_PATH="$(dirname "$LAUNCH")"
        if ! RECORD="$(jq -r '[
            (.issue | tostring),
            .slug,
            .phase,
            ((.pid // "none") | tostring),
            (if (.start_id // "") == "" then "-" else .start_id end),
            ([.engines | to_entries[] | "\(.key)=\(.value)"] | join(", ")),
            ([.ports | to_entries[] | "\(.key)=\(.value)"] | join(", "))
        ] | @tsv' "$LAUNCH" 2>/dev/null)"; then
            echo "warning: invalid launch metadata: $LAUNCH" >&2
            continue
        fi
        IFS=$'\t' read -r ISSUE_VALUE SLUG_VALUE PHASE_VALUE PID_VALUE START_VALUE ENGINES PORTS <<<"$RECORD"
        # Tab is IFS whitespace, so an empty column would collapse into its
        # neighbour: the jq above emits "-" for "no recorded identity".
        if [ "$START_VALUE" = "-" ]; then
            START_VALUE=""
        fi

        if owner_live "$PID_VALUE" "$START_VALUE"; then
            STATUS="alive"
        else
            STATUS="dead"
        fi

        NEWEST="$(
            find "$RUN_PATH" -type f \
                ! -path "$RUN_PATH/logs/*" \
                ! -name launch.json \
                ! -name engine.pid \
                ! -name '*.toml' \
                -printf '%T@ %p\n' 2>/dev/null \
                | sort -nr | head -n 1 || true
        )"
        if [ -n "$NEWEST" ]; then
            NEWEST_EPOCH="${NEWEST%%.*}"
            NEWEST_PATH="${NEWEST#* }"
            AGE=$((NOW - NEWEST_EPOCH))
            [ "$AGE" -ge 0 ] || AGE=0
            NEWEST_PATH="${NEWEST_PATH#"$RUN_PATH"/}"
            NEWEST="$NEWEST_PATH ($(format_age "$AGE") ago)"
        else
            NEWEST="none"
        fi

        printf '%s  issue=%s  phase=%s  pid=%s (%s)\n' \
            "$SLUG_VALUE" "$ISSUE_VALUE" "$PHASE_VALUE" "${PID_VALUE:-none}" "$STATUS"
        printf '  engines: %s\n' "$ENGINES"
        printf '  ports:   %s\n' "$PORTS"
        printf '  newest:  %s\n' "$NEWEST"
    done
}

stop_child() {
    if [ -z "$CHILD_PID" ] || [ "$CHILD_REAPED" -eq 1 ]; then
        return 0
    fi

    if kill -0 "$CHILD_PID" 2>/dev/null; then
        kill -TERM "$CHILD_PID" 2>/dev/null || true
        for ((STOP_TICK = 0; STOP_TICK < 30; STOP_TICK++)); do
            kill -0 "$CHILD_PID" 2>/dev/null || break
            sleep 2
        done
        # Either command can lose the benign race with a child exiting.
        { kill -0 "$CHILD_PID" 2>/dev/null \
            && kill -KILL "$CHILD_PID" 2>/dev/null; } || true
    fi
    wait "$CHILD_PID" 2>/dev/null || true
    CHILD_REAPED=1
}

cleanup() {
    local STATUS_VALUE=$?

    trap - EXIT INT TERM
    stop_child
    # Remove the PID file only if this launcher wrote it, and before the lease
    # is released: a concurrent same-issue launcher that never got the lease
    # must not delete the active launcher's PID file.
    if [ "${PID_FILE_OWNED:-0}" -eq 1 ]; then
        rm -f "$PID_FILE" || true
    fi
    if [ "$LEASED" -eq 1 ]; then
        "$ROOT/bin/ports.sh" release "$RUN_SLUG" || true
    fi
    exit "$STATUS_VALUE"
}

if [ "${1:-}" = "--list" ]; then
    if [ $# -ne 1 ]; then
        usage
        exit 64
    fi
    # shellcheck source=_env.sh
    source "$(dirname "${BASH_SOURCE[0]}")/_env.sh"
    list_runs
    exit 0
fi

if [ $# -ne 1 ] && [ $# -ne 3 ]; then
    usage
    exit 64
fi
ISSUE="${1:-}"
PHASE="pipeline"
if [ $# -eq 3 ]; then
    if [ "$2" != "--phase" ]; then
        usage
        exit 64
    fi
    PHASE="$3"
fi
if ! [[ "$ISSUE" =~ ^[0-9]+$ ]]; then
    usage
    exit 64
fi
case "$PHASE" in
    pipeline|plan|implement|review|promote) ;;
    *)
        usage
        exit 64
        ;;
esac

export SIGNALBOX_ISSUE="$ISSUE"
export SIGNALBOX_RUN_SLUG="issue-$ISSUE"
# Source only after exporting run identity: _env.sh owns RUN_DIR derivation.
# shellcheck source=_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/_env.sh"

PIPELINE_ENGINE="$ENGINE_PREFIX-pipeline-$RUN_SLUG"
PLAN_ENGINE="$ENGINE_PREFIX-plan-$RUN_SLUG"
IMPLEMENT_ENGINE="$ENGINE_PREFIX-implement-stream-$RUN_SLUG"
REVIEW_ENGINE="$ENGINE_PREFIX-review-loop-$RUN_SLUG"
INIT_ENGINE="$ENGINE_PREFIX-init-$RUN_SLUG"

if [ "$PHASE" = "promote" ]; then
    CR="$RUN_DIR/results/CR.md"
    REVIEW_STAMP="$RUN_DIR/state/pipeline-review.stamp"
    if [ ! -f "$CR" ]; then
        echo "error: promotion evidence missing $CR; run bin/run.sh $ISSUE --phase review" >&2
        exit 1
    fi
    if ! grep -q 'PROMOTION_READY' "$CR"; then
        echo "error: promotion evidence missing PROMOTION_READY in $CR; run bin/run.sh $ISSUE --phase review" >&2
        exit 1
    fi
    PROMOTE_CORRELATION_ID="$(cr_correlation_id "$CR" 2>/dev/null || true)"
    if [ -z "$PROMOTE_CORRELATION_ID" ]; then
        echo "error: promotion evidence missing correlation_id in $CR; run bin/run.sh $ISSUE --phase review" >&2
        exit 1
    fi
    if [ ! -f "$REVIEW_STAMP" ]; then
        echo "error: promotion evidence missing review stamp $REVIEW_STAMP; run bin/run.sh $ISSUE --phase review" >&2
        exit 1
    fi

    install_lock "$ROOT" shared || exit 1

    PID_FILE="$RUN_DIR/state/engine.pid"
    if [ -f "$PID_FILE" ]; then
        EXISTING_PID="$(head -n 1 "$PID_FILE" 2>/dev/null || true)"
        if pid_alive "$EXISTING_PID"; then
            echo "error: run $RUN_SLUG is already active with pid $EXISTING_PID; choose a different issue" >&2
            exit 1
        fi
    fi

    mkdir -p "$RUN_DIR/state" "$RUN_DIR/logs" "$RUN_DIR/results"
    rm -f -- "$RUN_DIR/state/complete.json" "$RUN_DIR/state/halted.json"

    CHILD_PID=""
    CHILD_REAPED=0
    LEASED=0
    PID_FILE_OWNED=0
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    printf '%s\n' "$$" >"$PID_FILE"
    PID_FILE_OWNED=1

    LOG="$RUN_DIR/logs/promote-$ISSUE.md"
    STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    START_ID="$(proc_identity "$$" || true)"
    LAUNCH="$RUN_DIR/launch.json"
    LAUNCH_TEMP="$LAUNCH.tmp.$$"

    if [ -f "$LAUNCH" ] \
        && jq -e 'type == "object"' "$LAUNCH" >/dev/null 2>&1; then
        jq \
            --arg phase "$PHASE" \
            --argjson pid "$$" \
            --arg start_id "$START_ID" \
            --arg log "$LOG" \
            '. + {
                phase: $phase,
                pid: $pid,
                start_id: $start_id,
                log: $log
            }' "$LAUNCH" >"$LAUNCH_TEMP"
    else
        jq -n \
            --arg issue "$ISSUE" \
            --arg slug "$RUN_SLUG" \
            --arg phase "$PHASE" \
            --arg engine_prefix "$ENGINE_PREFIX" \
            --arg pipeline_engine "$PIPELINE_ENGINE" \
            --arg plan_engine "$PLAN_ENGINE" \
            --arg implement_engine "$IMPLEMENT_ENGINE" \
            --arg review_engine "$REVIEW_ENGINE" \
            --arg init_engine "$INIT_ENGINE" \
            --arg log "$LOG" \
            --arg started "$STARTED" \
            --argjson pid "$$" \
            --arg start_id "$START_ID" \
            '{
                issue: ($issue | tonumber),
                slug: $slug,
                phase: $phase,
                engine_prefix: $engine_prefix,
                engines: {
                    pipeline: $pipeline_engine,
                    plan: $plan_engine,
                    implement: $implement_engine,
                    review: $review_engine,
                    init: $init_engine
                },
                ports: {},
                log: $log,
                started: $started,
                pid: $pid,
                start_id: $start_id
            }' >"$LAUNCH_TEMP"
    fi
    mv "$LAUNCH_TEMP" "$LAUNCH"
    install_unlock

    printf 'run:       %s\n' "$RUN_SLUG"
    printf 'issue:     %s\n' "$ISSUE"
    printf 'phase:     promote (non-engine recovery)\n'
    printf 'log:       %s\n' "$LOG"
    printf 'run dir:   %s\n' "$RUN_DIR"
    printf 'watch:     http://127.0.0.1:%s/\n' "${SIGNALBOX_SINK_PORT:-8099}"

    REQUEST_PAYLOAD="$(
        jq -n \
            --arg issue "$ISSUE" \
            --arg phase "promote" \
            --arg correlation_id "$PROMOTE_CORRELATION_ID" \
            '{
                issue: ($issue | tonumber),
                phase: $phase,
                correlation_id: $correlation_id
            }'
    )"
    forward_event "phase.request" "$REQUEST_PAYLOAD"

    PROMOTE_STATUS=0
    if PROMOTE_OUTPUT="$(
        printf '%s\n' "$REQUEST_PAYLOAD" | "$ROOT/bin/promote-exec.sh"
    )"; then
        :
    else
        PROMOTE_STATUS=$?
    fi

    PROMOTE_FAILURE_REASON=""
    PHASE_DONE=""
    if [ "$PROMOTE_STATUS" -ne 0 ]; then
        OUTCOME="NO_GO"
        PROMOTE_FAILURE_REASON="bin/promote-exec.sh exited with status $PROMOTE_STATUS"
    elif [ -z "$PROMOTE_OUTPUT" ]; then
        OUTCOME="NO_GO"
        PROMOTE_FAILURE_REASON="bin/promote-exec.sh printed no phase.done payload"
    elif ! PHASE_DONE="$(
        jq -c -s \
            'if length == 1 and (.[0] | type == "object")
             then .[0]
             else error("expected one JSON object")
             end' <<<"$PROMOTE_OUTPUT" 2>/dev/null
    )"; then
        OUTCOME="NO_GO"
        PROMOTE_FAILURE_REASON="bin/promote-exec.sh printed a malformed phase.done payload"
    elif ! OUTCOME="$(
        jq -er '
            if (.outcome | type) == "string" and .outcome != ""
            then .outcome
            else error("missing string outcome")
            end
        ' <<<"$PHASE_DONE" 2>/dev/null
    )"; then
        OUTCOME="NO_GO"
        PROMOTE_FAILURE_REASON="bin/promote-exec.sh returned phase.done without a string outcome"
    else
        forward_event "phase.done" "$PHASE_DONE"
    fi

    if [ "$OUTCOME" = "ARTIFACT" ]; then
        record_terminal complete false
        exit 0
    fi

    record_terminal halted false
    exit 1
fi

case "$PHASE" in
    pipeline) TEMPLATE_NAME="pipeline"; CONFIG_NAME="pipeline"; ENGINE_NAME="$ENGINE_PREFIX-pipeline-$RUN_SLUG" ;;
    plan) TEMPLATE_NAME="plan"; CONFIG_NAME="plan"; ENGINE_NAME="$ENGINE_PREFIX-plan-$RUN_SLUG" ;;
    implement) TEMPLATE_NAME="implement"; CONFIG_NAME="implement"; ENGINE_NAME="$ENGINE_PREFIX-implement-stream-$RUN_SLUG" ;;
    review) TEMPLATE_NAME="emergent"; CONFIG_NAME="emergent"; ENGINE_NAME="$ENGINE_PREFIX-review-loop-$RUN_SLUG" ;;
esac

if [ ! -d "$ROOT/templates" ]; then
    echo "error: templates missing at $ROOT/templates — reinstall the harness; install.sh renders templates/" >&2
    exit 1
fi
if [ ! -f "$ROOT/templates/$TEMPLATE_NAME.toml" ]; then
    echo "error: $PHASE template missing at $ROOT/templates/$TEMPLATE_NAME.toml — reinstall the harness" >&2
    exit 1
fi
DOCS="$REPO_ROOT/.claude/docs"
if [ ! -f "$DOCS/ARCHI.md" ]; then
    echo "error: vault docs missing at $DOCS — run bin/init-run.sh first" >&2
    exit 1
fi

# Startup window: everything from here until launch.json carries this engine's
# pid runs under the shared harness lock, which install.sh --reinstall takes
# exclusively across its liveness scan and refresh. Holding it shared means
# concurrent launchers still start freely, while a reinstall either sees this
# run recorded and refuses, or waits for it to be recorded. Released as soon as
# the metadata is on disk — a run must not block a later reinstall's lock, only
# its liveness scan.
install_lock "$ROOT" shared || exit 1

PID_FILE="$RUN_DIR/state/engine.pid"
if [ -f "$PID_FILE" ]; then
    EXISTING_PID="$(head -n 1 "$PID_FILE" 2>/dev/null || true)"
    if pid_alive "$EXISTING_PID"; then
        echo "error: run $RUN_SLUG is already active with pid $EXISTING_PID; choose a different issue" >&2
        exit 1
    fi
fi

mkdir -p "$RUN_DIR/state" "$RUN_DIR/logs" "$RUN_DIR/results"

# A run directory is reused across launches of the same issue, so terminal
# evidence from the previous launch would otherwise be read as this one's.
# Invalidate both files here — after the "already active" check, before the
# engine starts — so a supervisor that finds state/complete.json or
# state/halted.json is always looking at evidence this launch produced.
rm -f -- "$RUN_DIR/state/complete.json" "$RUN_DIR/state/halted.json"

CHILD_PID=""
CHILD_REAPED=0
LEASED=0
PID_FILE_OWNED=0
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

BASE="$(SIGNALBOX_LEASE_PID="$$" "$ROOT/bin/ports.sh" lease "$RUN_SLUG")"
LEASED=1
PORT_APPROVAL="$BASE"

for TEMPLATE_NAME in pipeline plan implement emergent init; do
    if [ ! -f "$ROOT/templates/$TEMPLATE_NAME.toml" ]; then
        echo "error: template missing at $ROOT/templates/$TEMPLATE_NAME.toml — reinstall the harness" >&2
        exit 1
    fi
    sed \
        -e "s|__SIGNALBOX_RUN_SUFFIX__|-$RUN_SLUG|g" \
        -e "s|__SIGNALBOX_PORT_APPROVAL__|$PORT_APPROVAL|g" \
        "$ROOT/templates/$TEMPLATE_NAME.toml" >"$RUN_DIR/$TEMPLATE_NAME.toml"
done

# Comment lines in the templates legitimately name these placeholders;
# bin/check-placeholders.sh reports only live, unrendered occurrences.
"$ROOT/bin/check-placeholders.sh" "$RUN_DIR" || exit 1

LOG="$RUN_DIR/logs/engine-$PHASE.log"
STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
LAUNCH="$RUN_DIR/launch.json"
LAUNCH_TEMP="$LAUNCH.tmp.$$"

# launch.json is launcher metadata; state/run.json separately carries the
# implementation engine's correlation_id.
jq -n \
    --arg issue "$ISSUE" \
    --arg slug "$RUN_SLUG" \
    --arg phase "$PHASE" \
    --arg engine_prefix "$ENGINE_PREFIX" \
    --arg pipeline_engine "$PIPELINE_ENGINE" \
    --arg plan_engine "$PLAN_ENGINE" \
    --arg implement_engine "$IMPLEMENT_ENGINE" \
    --arg review_engine "$REVIEW_ENGINE" \
    --arg init_engine "$INIT_ENGINE" \
    --argjson approval_port "$PORT_APPROVAL" \
    --arg log "$LOG" \
    --arg started "$STARTED" \
    '{
        issue: ($issue | tonumber),
        slug: $slug,
        phase: $phase,
        engine_prefix: $engine_prefix,
        engines: {
            pipeline: $pipeline_engine,
            plan: $plan_engine,
            implement: $implement_engine,
            review: $review_engine,
            init: $init_engine
        },
        ports: {
            approval: $approval_port
        },
        log: $log,
        started: $started
    }' >"$LAUNCH_TEMP"
mv "$LAUNCH_TEMP" "$LAUNCH"

# STARTED is captured before launch.json is written and truncated to whole
# seconds; /status prefers that recorded instant as the launch boundary. A
# stamp written before the record could compare older even within that second
# and be discarded as the previous run's leftover, so touch a direct phase's
# stamp only after the record exists to guarantee its mtime is at least the
# boundary. Pipeline phases stamp themselves as they actually start.
case "$PHASE" in
    plan|implement|review) touch "$RUN_DIR/state/pipeline-$PHASE.stamp" ;;
esac

# 9>&- keeps the harness lock out of the engine: an inherited copy would hold
# it for the whole run, so a later reinstall would block on the lock instead of
# refusing with the live run named.
SIGNALBOX_ISSUE="$ISSUE" SIGNALBOX_RUN_SLUG="$RUN_SLUG" \
    emergent --config "$RUN_DIR/$CONFIG_NAME.toml" >"$LOG" 2>&1 9>&- &
CHILD_PID=$!
printf '%s\n' "$CHILD_PID" >"$PID_FILE"
PID_FILE_OWNED=1
# Read the identity as early as possible; an engine that dies instantly leaves
# it empty, which every consumer reads as "identity unknown", never as "alive".
CHILD_START="$(proc_identity "$CHILD_PID" || true)"
jq --argjson pid "$CHILD_PID" --arg start "$CHILD_START" \
    '. + {pid: $pid, start_id: $start}' "$LAUNCH" >"$LAUNCH_TEMP"
mv "$LAUNCH_TEMP" "$LAUNCH"
# The engine is on disk with its identity: a reinstall scan can see it now, so
# the startup window is over.
install_unlock

printf 'run:       %s\n' "$RUN_SLUG"
printf 'issue:     %s\n' "$ISSUE"
printf 'engine:    %s\n' "$ENGINE_NAME"
printf 'ports:     approval webhook %s\n' "$PORT_APPROVAL"
printf 'log:       %s\n' "$LOG"
printf 'run dir:   %s\n' "$RUN_DIR"
printf 'watch:     http://127.0.0.1:%s/\n' "${SIGNALBOX_SINK_PORT:-8099}"

# The pipeline topology owns its own stamps, artifact supervision, operator
# verification, and terminal records. Preserve its launcher contract exactly:
# remain the foreground parent and return only the engine's exit status.
if [ "$PHASE" = "pipeline" ]; then
    if wait "$CHILD_PID"; then
        CHILD_STATUS=0
    else
        CHILD_STATUS=$?
    fi
    CHILD_REAPED=1
    exit "$CHILD_STATUS"
fi

# Direct phase engines have the same artifact discipline as bin/phase-run.sh.
# The engine's redirected stdout is buffered, so its narration is never a
# terminal signal. Freshness is relative to this launch's phase stamp.
STAMP="$RUN_DIR/state/pipeline-$PHASE.stamp"
fresh() {
    [ -f "$1" ] && [ "$1" -nt "$STAMP" ]
}

case "$PHASE" in
    plan) TIMEOUT=2400 ;;
    implement) TIMEOUT=5400 ;;
    review) TIMEOUT=3600 ;;
esac

# One scan of this phase's terminal artifacts. Sets OUTCOME and returns 0 when
# fresh evidence settles the run, leaves OUTCOME untouched and returns 1 when
# nothing terminal is on disk yet.
scan_artifacts() {
    if fresh "$RUN_DIR/state/escalated.json"; then
        OUTCOME="ESCALATED"
        return 0
    fi
    case "$PHASE" in
        plan)
            if fresh "$RUN_DIR/plan.json"; then
                OUTCOME="ARTIFACT"
                return 0
            fi
            ;;
        implement)
            if fresh "$RUN_DIR/state/gate.json"; then
                VERDICT="$(
                    jq -r '.verdict // empty' \
                        "$RUN_DIR/state/gate.json" 2>/dev/null || true
                )"
                if [ "$VERDICT" = "GREEN" ]; then
                    OUTCOME="ARTIFACT"
                else
                    OUTCOME="GATE_RED"
                fi
                return 0
            fi
            ;;
        review)
            if fresh "$RUN_DIR/results/CR.md"; then
                OUTCOME="ARTIFACT"
                return 0
            fi
            if fresh "$RUN_DIR/state/pending.json"; then
                OUTCOME="PARKED"
                return 0
            fi
            ;;
    esac
    return 1
}

printf '[standalone] %s engine up (pid %s), watching fresh artifacts\n' \
    "$PHASE" "$CHILD_PID" >&2
OUTCOME="TIMEOUT"
ELAPSED=0
while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
    # Artifacts before liveness: an engine that writes its terminal artifact and
    # exits immediately is a finished phase, not a death.
    if scan_artifacts; then
        break
    fi
    if ! kill -0 "$CHILD_PID" 2>/dev/null; then
        OUTCOME="ENGINE_DIED"
        break
    fi
    sleep 2
    ELAPSED=$((ELAPSED + 2))
done

# An artifact can land between the last scan and the child's exit, or during the
# final sleep before the deadline. Rescan once so neither is lost to a death or
# timeout verdict; a real death or timeout leaves OUTCOME as it stands.
case "$OUTCOME" in
    ENGINE_DIED|TIMEOUT) scan_artifacts || true ;;
esac

if [ "$PHASE" = "review" ] \
    && [ "$OUTCOME" = "ARTIFACT" ] \
    && ! fresh "$RUN_DIR/state/docs-sync.json"; then
    DOCS_SYNC_GRACE="${SIGNALBOX_DOCS_SYNC_GRACE:-960}"
    [[ "$DOCS_SYNC_GRACE" =~ ^[0-9]+$ ]] || DOCS_SYNC_GRACE=960
    DOCS_SYNC_ELAPSED=0
    DOCS_SYNC_RESULT="grace deadline elapsed without fresh docs-sync evidence"
    printf '[standalone] review artifact reached; waiting up to %ss for fresh docs-sync evidence required by bin/promote-exec.sh\n' \
        "$DOCS_SYNC_GRACE" >&2
    while [ "$DOCS_SYNC_ELAPSED" -lt "$DOCS_SYNC_GRACE" ]; do
        if fresh "$RUN_DIR/state/docs-sync.json"; then
            DOCS_SYNC_RESULT="fresh docs-sync evidence arrived"
            break
        fi
        if ! kill -0 "$CHILD_PID" 2>/dev/null; then
            DOCS_SYNC_RESULT="review engine exited before fresh docs-sync evidence arrived"
            break
        fi
        DOCS_SYNC_SLEEP=2
        if [ "$((DOCS_SYNC_GRACE - DOCS_SYNC_ELAPSED))" -lt "$DOCS_SYNC_SLEEP" ]; then
            DOCS_SYNC_SLEEP=$((DOCS_SYNC_GRACE - DOCS_SYNC_ELAPSED))
        fi
        sleep "$DOCS_SYNC_SLEEP"
        DOCS_SYNC_ELAPSED=$((DOCS_SYNC_ELAPSED + DOCS_SYNC_SLEEP))
    done
    if fresh "$RUN_DIR/state/docs-sync.json"; then
        DOCS_SYNC_RESULT="fresh docs-sync evidence arrived"
    fi
    printf '[standalone] review docs-sync wait finished: %s\n' \
        "$DOCS_SYNC_RESULT" >&2
fi

# Unlike bin/phase-run.sh, this operator entry point remains in the foreground
# for the entire standalone run. It therefore waits for review docs-sync itself
# instead of detaching engine-reaper.sh: promote-exec.sh requires docs-sync
# evidence newer than the review stamp. After that seam, let in-flight sinks
# narrate briefly, then stop only this launcher's exact child PID.
if kill -0 "$CHILD_PID" 2>/dev/null; then
    sleep 5
fi
stop_child
printf '[standalone] %s engine stopped, outcome: %s\n' \
    "$PHASE" "$OUTCOME" >&2

case "$OUTCOME" in
    ARTIFACT)
        record_terminal complete false
        exit 0
        ;;
    PARKED)
        record_terminal complete true
        exit 0
        ;;
    ESCALATED|GATE_RED|TIMEOUT|ENGINE_DIED)
        record_terminal halted false
        exit 1
        ;;
esac

# OUTCOME is assigned only from the closed set above. Keep an explicit
# fail-closed fallback in case a future edit adds a terminal without routing it.
OUTCOME="NO_GO"
record_terminal halted false
exit 1
