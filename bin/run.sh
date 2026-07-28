#!/usr/bin/env bash
# Per-run launcher:
#   bin/run.sh <issue> [--phase pipeline|plan|implement|review|promote]
#   bin/run.sh --list
# This is an operator entry point with no stdin/stdout event contract; stdout
# is human narration and diagnostics go to stderr.
#
# Launches one Emergent engine as a child, records its run metadata, and remains
# its foreground supervisor. Every launcher mode claims the run exclusively
# first (see claim_run_ownership), so a run has exactly one launcher of any
# mode at a time. Startup — from inspecting existing run state until
# launch.json records the engine — then holds the harness lock shared, so a
# concurrent install.sh --reinstall cannot refresh the tree around a run its
# liveness scan never saw. Because the run directory is reused across launches
# of the same issue, it also removes the previous launch's terminal evidence
# (state/complete.json, state/halted.json, state/park.json) before the engine
# starts.
#
# Standalone plan, implement, and review launches stamp their phase, supervise
# fresh disk artifacts rather than buffered engine narration, stop only their
# own child PID, and publish normalized complete/halted terminal evidence whose
# correlation ID is read from the fresh artifact that settled the terminal. A
# parked review transfers that child to a bounded detached reaper instead, so
# the announced approval webhook remains live. The pipeline launch deliberately
# keeps the original bare wait contract: its topology owns phase stamps,
# artifact supervision, operator verification, and terminal records.
#
# Promote is a non-engine recovery path. It first fails closed on the existing
# review CR (an exact PROMOTION_READY line), correlation ID, and review stamp,
# then claims the run — only one launcher may ever push and merge a given run —
# and records this launcher as the live owner without leasing a port, rendering
# templates, spawning Emergent, or fabricating a promote/review stamp. It
# invokes bin/promote-exec.sh with the normal phase.request shape and records
# the result as a standalone terminal. No standalone terminal claims operator
# verification: bin/operator.sh runs only inside the pipeline topology.
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
    # 8>&- keeps this launcher's run ownership out of the detached child, which
    # may outlive the launcher; an inherited copy would hold the run claimed
    # after exit. Closing an unopened fd is a no-op if the claim was never made.
    printf '%s\n' "$PAYLOAD" \
        | "$ROOT/bin/sse-forward.sh" pipeline "$TOPIC" \
            >/dev/null 2>&1 8>&- &
}

write_park_record() {
    local HELD_VALUE="$1" PID_VALUE="$2" START_ID_VALUE="$3"
    local DEADLINE_VALUE="$4" LEASE_VALUE="$5" REASON_VALUE="$6"
    local PARK_FILE="$RUN_DIR/state/park.json"
    local PARK_TEMP="$PARK_FILE.tmp.$$"
    local PENDING="$RUN_DIR/state/pending.json"
    local WATCH="$RUN_DIR/state/docs-sync.json"
    local APPROVE_URL="http://127.0.0.1:$PORT_APPROVAL/approve"
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
        --arg holder "standalone" \
        --argjson port "$PORT_APPROVAL" \
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
            if [ "${PARK_HELD:-false}" = true ]; then
                printf 'a fresh state/pending.json artifact, and the review engine is deliberately held open so its approval webhook stays live'
            else
                printf 'a fresh state/pending.json artifact, but the approval window is already closed'
            fi
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
            if [ "${PARK_HELD:-false}" = true ]; then
                # Same single-shell-word requirement as the recorded command in
                # write_park_record: the operator pastes this line as-is.
                printf "curl -s -X POST http://127.0.0.1:%s/approve -H 'Content-Type: application/json' --data @%s; the webhook stays live until that POST or the %ss park deadline; abandoning the park means SIGTERMing recorded engine pid %s" \
                    "$PORT_APPROVAL" "$(printf '%q' "$RUN_DIR/state/pending.json")" \
                    "$PARK_DEADLINE" "$PARK_ENGINE_PID"
            else
                printf 'inspect state/pending.json, then relaunch bin/run.sh %s --phase review' "$ISSUE"
            fi
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

# Correlation from a JSON artifact, but only while that artifact is fresh for
# this launch; a stale one contributes nothing.
fresh_json_correlation() {
    local ARTIFACT="$1"

    fresh "$ARTIFACT" || return 0
    jq -r '
        if type == "object"
            and (.correlation_id | type) == "string"
        then .correlation_id
        else ""
        end
    ' "$ARTIFACT" 2>/dev/null || true
}

fresh_cr_correlation() {
    local ARTIFACT="$RUN_DIR/results/CR.md"

    fresh "$ARTIFACT" || return 0
    cr_correlation_id "$ARTIFACT" 2>/dev/null || true
}

# The terminal's correlation ID comes from the artifact that actually settled
# it, keyed on the observed outcome — never from the phase alone. A run
# directory is reused across launches, so plan.json, state/gate.json and
# results/CR.md all survive from the previous attempt: reading results/CR.md
# for every review terminal would stamp a fresh PARKED or ESCALATED record with
# the *previous* review's identity, while the current ID sits unread in
# state/pending.json or state/escalated.json. Outcomes with no artifact of
# their own (TIMEOUT, ENGINE_DIED) resolve to empty, which record_terminal
# writes as null: no correlation is truthful, borrowed correlation is not.
resolve_correlation_id() {
    local CORRELATION=""

    case "$PHASE:$OUTCOME" in
        promote:*)
            CORRELATION="${PROMOTE_CORRELATION_ID:-}"
            ;;
        *:ESCALATED)
            CORRELATION="$(fresh_json_correlation "$RUN_DIR/state/escalated.json")"
            ;;
        plan:ARTIFACT)
            CORRELATION="$(fresh_json_correlation "$RUN_DIR/plan.json")"
            ;;
        implement:ARTIFACT | implement:GATE_RED)
            CORRELATION="$(fresh_json_correlation "$RUN_DIR/state/gate.json")"
            ;;
        review:ARTIFACT)
            CORRELATION="$(fresh_cr_correlation)"
            ;;
        review:PARKED)
            CORRELATION="$(fresh_json_correlation "$RUN_DIR/state/pending.json")"
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
    local NOW AGE PARK_FILE PARK_RECORD PARK_HELD_VALUE PARK_PID_VALUE
    local PARK_START_VALUE PARK_URL_VALUE PARK_SINCE_VALUE PARK_REASON_VALUE
    local PARK_DETAIL
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

        PARK_DETAIL=""
        PARK_FILE="$RUN_PATH/state/park.json"
        if [ -f "$PARK_FILE" ]; then
            if ! PARK_RECORD="$(jq -er '
                def nullable_text($name):
                    .[$name] as $value
                    | if $value == null or $value == "" then "-"
                      elif ($value | type) == "string" then $value
                      else error("\($name) is not text")
                      end;
                def park_pid:
                    .pid as $value
                    | if $value == null then "-"
                      elif ($value | type) == "number"
                          and ($value | floor) == $value
                          and $value > 0
                      then ($value | floor | tostring)
                      else error("pid is not a positive whole number or null")
                      end;
                if type != "object" then error("record is not an object") else . end
                | if (.held | type) != "boolean"
                    then error("held is not boolean") else . end
                | if (.approve_url | type) != "string"
                    then error("approve_url is not text") else . end
                | if (.since | type) != "string"
                    then error("since is not text") else . end
                | [
                    (.held | tostring),
                    park_pid,
                    nullable_text("start_id"),
                    .approve_url,
                    .since,
                    nullable_text("reason")
                ]
                | @tsv
            ' "$PARK_FILE" 2>/dev/null)"; then
                echo "warning: invalid park metadata: $PARK_FILE" >&2
            else
                IFS=$'\t' read -r \
                    PARK_HELD_VALUE PARK_PID_VALUE PARK_START_VALUE \
                    PARK_URL_VALUE PARK_SINCE_VALUE PARK_REASON_VALUE \
                    <<<"$PARK_RECORD"
                [ "$PARK_PID_VALUE" != "-" ] || PARK_PID_VALUE=""
                [ "$PARK_START_VALUE" != "-" ] || PARK_START_VALUE=""
                [ "$PARK_REASON_VALUE" != "-" ] || PARK_REASON_VALUE=""
                if [ "$PARK_HELD_VALUE" = true ] \
                    && owner_live "$PARK_PID_VALUE" "$PARK_START_VALUE"; then
                    STATUS="parked"
                    PARK_DETAIL="awaiting approval — POST $PARK_URL_VALUE (engine pid $PARK_PID_VALUE, held since $PARK_SINCE_VALUE)"
                else
                    [ -n "$PARK_REASON_VALUE" ] || PARK_REASON_VALUE="engine gone"
                    PARK_DETAIL="park window closed ($PARK_REASON_VALUE) — relaunch bin/run.sh $ISSUE_VALUE --phase review"
                fi
            fi
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
        if [ -n "$PARK_DETAIL" ]; then
            printf '  park:    %s\n' "$PARK_DETAIL"
        fi
    done
}

# Claim this run for this launcher, atomically, across every launcher mode.
# Each mode writes the same shared run metadata — launch.json, state/engine.pid,
# the rendered configs — and promote additionally pushes a branch and merges a
# PR, so at most one launcher of any mode may own a run at a time. The
# state/engine.pid check cannot provide that: two launchers can both read the
# same stale PID file, or both pass it before either writes its own, and both
# proceed. Take an exclusive lock on the run first and hold it for this
# launcher's whole life. Non-blocking on purpose — a second launcher must
# refuse, not queue behind work that is already in flight. Callers must close
# fd 8 in any child that can outlive them, or the claim outlives the launcher.
claim_run_ownership() {
    if ! command -v flock >/dev/null 2>&1; then
        echo "error: flock is missing — reinstall; run ownership depends on it" >&2
        exit 1
    fi
    mkdir -p "$RUN_DIR/state"
    RUN_LOCK="$RUN_DIR/state/launcher.lock"
    if ! exec 8>>"$RUN_LOCK"; then
        echo "error: cannot create the run ownership lock: $RUN_LOCK" >&2
        exit 1
    fi
    if ! flock -n 8; then
        echo "error: run $RUN_SLUG is already owned by another bin/run.sh launcher; wait for it to finish" >&2
        exit 1
    fi
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
    # bin/promote.sh writes the sentinel on a line of its own. Match that line
    # exactly: a substring match would accept NOT_PROMOTION_READY or review
    # prose that merely names the token, opening the merge gate on evidence
    # that never approved anything.
    if ! grep -qx 'PROMOTION_READY' "$CR"; then
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

    # Promotion pushes a branch and merges a PR, so it must hold the run
    # exclusively against every other launcher mode, not just against another
    # promoter — a plan, implement, review, or pipeline launcher overwrites the
    # same launch.json and state/engine.pid this promotion depends on.
    claim_run_ownership

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
    rm -f -- \
        "$RUN_DIR/state/complete.json" \
        "$RUN_DIR/state/halted.json" \
        "$RUN_DIR/state/park.json"

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
        printf '%s\n' "$REQUEST_PAYLOAD" | "$ROOT/bin/promote-exec.sh" 8>&-
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

# Claim the run before anything reads or writes its shared metadata, so a
# concurrent launcher of any mode — including a promotion that may push and
# merge — refuses instead of racing this one.
claim_run_ownership

# Startup window: everything from here until launch.json carries this engine's
# pid runs under the shared harness lock, which install.sh --reinstall takes
# exclusively across its liveness scan and refresh. Holding it shared means
# concurrent launchers still start freely, while a reinstall either sees this
# run recorded and refuses, or waits for it to be recorded. Released as soon as
# the metadata is on disk — a run must not block a later reinstall's lock, only
# its liveness scan.
install_lock "$ROOT" shared || exit 1

PID_FILE="$RUN_DIR/state/engine.pid"
EXISTING_LIVE_PID=""
if [ -f "$PID_FILE" ]; then
    EXISTING_PID="$(head -n 1 "$PID_FILE" 2>/dev/null || true)"
    if pid_alive "$EXISTING_PID"; then
        EXISTING_LIVE_PID="$EXISTING_PID"
    fi
fi

mkdir -p "$RUN_DIR/state" "$RUN_DIR/logs" "$RUN_DIR/results"

PARK_FILE="$RUN_DIR/state/park.json"
if [ -f "$PARK_FILE" ]; then
    PARK_GUARD_RECORD="$(
        jq -er '
            if type == "object"
                and .held == true
                and (.pid | type) == "number"
                and (.pid | floor) == .pid
                and .pid > 0
                and (.start_id | type) == "string"
                and (.approve_url | type) == "string"
            then [(.pid | floor | tostring), .start_id, .approve_url] | @tsv
            else empty
            end
        ' "$PARK_FILE" 2>/dev/null || true
    )"
    if [ -n "$PARK_GUARD_RECORD" ]; then
        IFS=$'\t' read -r PARK_GUARD_PID PARK_GUARD_START PARK_GUARD_URL \
            <<<"$PARK_GUARD_RECORD"
        if owner_live "$PARK_GUARD_PID" "$PARK_GUARD_START"; then
            echo "error: run $RUN_SLUG is parked awaiting approval at $PARK_GUARD_URL with engine pid $PARK_GUARD_PID; the approval port is still leased — POST the pending approval or SIGTERM the recorded engine before relaunching" >&2
            exit 1
        fi
    fi
fi

if [ -n "$EXISTING_LIVE_PID" ]; then
    echo "error: run $RUN_SLUG is already active with pid $EXISTING_LIVE_PID; choose a different issue" >&2
    exit 1
fi

# A run directory is reused across launches of the same issue, so terminal and
# park evidence from the previous launch would otherwise be read as this one's.
# Invalidate all three files here — after the "already active" check, before the
# engine starts — so a supervisor that finds state/complete.json,
# state/halted.json, or state/park.json is always looking at evidence this
# launch produced.
rm -f -- \
    "$RUN_DIR/state/complete.json" \
    "$RUN_DIR/state/halted.json" \
    "$RUN_DIR/state/park.json"

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
# refusing with the live run named. 8>&- does the same for this launcher's run
# ownership: an engine that outlives its launcher must not keep the next
# launcher of any mode locked out of the run.
SIGNALBOX_ISSUE="$ISSUE" SIGNALBOX_RUN_SLUG="$RUN_SLUG" \
    emergent --config "$RUN_DIR/$CONFIG_NAME.toml" >"$LOG" 2>&1 9>&- 8>&- &
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
PARK_HELD=false
PARK_DEADLINE=""
PARK_ENGINE_PID=""
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
    # Parse the grace explicitly as bounded base-10 seconds before any
    # arithmetic uses it. A digit-only string is not automatically safe: "08"
    # is an invalid octal constant and an unbounded value can overflow, and
    # either aborts this loop under set -e — leaving the observed terminal
    # unrecorded. Reject anything outside the bound and narrate the fallback.
    DOCS_SYNC_GRACE_DEFAULT=960
    DOCS_SYNC_GRACE_MAX=86400
    DOCS_SYNC_GRACE_RAW="${SIGNALBOX_DOCS_SYNC_GRACE:-$DOCS_SYNC_GRACE_DEFAULT}"
    if [[ "$DOCS_SYNC_GRACE_RAW" =~ ^[0-9]{1,6}$ ]] \
        && [ "$((10#$DOCS_SYNC_GRACE_RAW))" -le "$DOCS_SYNC_GRACE_MAX" ]; then
        DOCS_SYNC_GRACE=$((10#$DOCS_SYNC_GRACE_RAW))
    else
        printf '[standalone] ignoring invalid SIGNALBOX_DOCS_SYNC_GRACE=%s (expected 0-%s seconds); using %ss\n' \
            "$DOCS_SYNC_GRACE_RAW" "$DOCS_SYNC_GRACE_MAX" "$DOCS_SYNC_GRACE_DEFAULT" >&2
        DOCS_SYNC_GRACE=$DOCS_SYNC_GRACE_DEFAULT
    fi
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

if [ "$PHASE" = "review" ] && [ "$OUTCOME" = "PARKED" ]; then
    PARK_GRACE_DEFAULT=86400
    PARK_GRACE_MAX=86400
    PARK_GRACE_RAW="${SIGNALBOX_PARK_GRACE:-$PARK_GRACE_DEFAULT}"
    if [[ "$PARK_GRACE_RAW" =~ ^[0-9]{1,6}$ ]] \
        && [ "$((10#$PARK_GRACE_RAW))" -ge 1 ] \
        && [ "$((10#$PARK_GRACE_RAW))" -le "$PARK_GRACE_MAX" ]; then
        PARK_GRACE=$((10#$PARK_GRACE_RAW))
    else
        printf '[standalone] ignoring invalid SIGNALBOX_PARK_GRACE=%s (expected 1-%s seconds); using %ss\n' \
            "$PARK_GRACE_RAW" "$PARK_GRACE_MAX" "$PARK_GRACE_DEFAULT" >&2
        PARK_GRACE=$PARK_GRACE_DEFAULT
    fi

    PARK_START_ID="$(proc_identity "$CHILD_PID" || true)"
    PARK_STARTTIME="${PARK_START_ID#*:}"
    [[ "$PARK_STARTTIME" =~ ^[0-9]+$ ]] || PARK_STARTTIME=""
    PARK_PROC_STATE="$(awk '{ sub(/^.*\) /, ""); print $1 }' \
        "/proc/$CHILD_PID/stat" 2>/dev/null || true)"

    if kill -0 "$CHILD_PID" 2>/dev/null \
        && [ "$PARK_PROC_STATE" != "Z" ] \
        && [ -n "$PARK_START_ID" ] \
        && [ -n "$PARK_STARTTIME" ]; then
        PARK_ENGINE_PID="$CHILD_PID"
        PARK_DEADLINE="$PARK_GRACE"
        # Both lock descriptors must be closed in a detached process that
        # outlives this launcher. Otherwise it would retain either this run's
        # exclusive launcher claim or the shared harness lock, blocking a later
        # launcher or install.sh --reinstall after this shell exits.
        setsid "$(dirname "${BASH_SOURCE[0]}")/engine-reaper.sh" \
            "$CHILD_PID" "$PID_FILE" "$RUN_DIR/state/docs-sync.json" "$STAMP" \
            "$PARK_DEADLINE" "$PARK_STARTTIME" \
            </dev/null >>"$LOG" 2>&1 8>&- 9>&- &

        LEASE_TRANSFERRED=false
        if "$(dirname "${BASH_SOURCE[0]}")/ports.sh" transfer \
            "$RUN_SLUG" "$PARK_ENGINE_PID" >/dev/null 2>&1; then
            LEASE_TRANSFERRED=true
        else
            echo "[standalone] port lease could not be transferred to the held engine; the registry entry may be released while the webhook is still listening" >&2
        fi

        # Spawning the reaper and transferring the lease both take time, and the
        # engine can exit or be stopped inside that window — a transfer refused
        # for a dead target is one symptom of exactly that. Only a process that
        # is still exactly this engine, and still running, may be recorded and
        # narrated as a held webhook; anything else is a closed park window,
        # which leaves PARK_HELD false so the launcher reaps below and cleanup
        # releases the lease it still owns.
        if engine_running "$PARK_ENGINE_PID" "$PARK_START_ID"; then
            if [ "$LEASE_TRANSFERRED" = true ]; then
                # The lease now names the held engine, so this launcher's
                # cleanup must no longer release it on the way out.
                LEASED=0
            fi
            write_park_record true "$PARK_ENGINE_PID" "$PARK_START_ID" \
                "$PARK_DEADLINE" "$LEASE_TRANSFERRED" ""

            CHILD_REAPED=1
            PID_FILE_OWNED=0
            # This prevents an interactive shell from HUPing the held child as
            # this launcher exits. The engine still shares its terminal session,
            # so a park that must outlive that terminal should be launched under
            # nohup/setsid, as the operator narration explains.
            disown "$CHILD_PID" 2>/dev/null || true
            PARK_HELD=true
            printf '[standalone] review parked; deliberately leaving idle engine pid %s open at http://127.0.0.1:%s/approve for approval (deadline: %ss); use nohup/setsid when the park must outlive this terminal\n' \
                "$PARK_ENGINE_PID" "$PORT_APPROVAL" "$PARK_DEADLINE" >&2
        else
            PARK_REASON="The approval window is closed because the review engine exited while ownership of it was being transferred."
            write_park_record false null "" null "$LEASE_TRANSFERRED" \
                "$PARK_REASON"
            printf '[standalone] %s\n' "$PARK_REASON" >&2
        fi
    else
        if [ -z "$PARK_START_ID" ] || [ -z "$PARK_STARTTIME" ]; then
            PARK_REASON="The approval window is closed because the review engine identity was unreadable, so a safe deferred handoff was impossible."
        else
            PARK_REASON="The approval window is closed because the review engine exited before ownership could be transferred."
        fi
        write_park_record false null "" null false "$PARK_REASON"
        printf '[standalone] %s\n' "$PARK_REASON" >&2
    fi
fi

if [ "$PARK_HELD" != true ]; then
    # Unlike bin/phase-run.sh, this operator entry point remains in the
    # foreground for an ARTIFACT terminal. It therefore waits for review
    # docs-sync itself instead of detaching engine-reaper.sh: promote-exec.sh
    # requires docs-sync evidence newer than the review stamp. After that seam,
    # let in-flight sinks narrate briefly, then stop only this launcher's exact
    # child PID.
    if kill -0 "$CHILD_PID" 2>/dev/null; then
        sleep 5
    fi
    stop_child
    printf '[standalone] %s engine stopped, outcome: %s\n' \
        "$PHASE" "$OUTCOME" >&2
fi

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
