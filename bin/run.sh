#!/usr/bin/env bash
# Per-run launcher: bin/run.sh <issue> [--phase pipeline|plan|implement|review]
# or bin/run.sh --list. This is an operator entry point with no stdin/stdout
# event contract; stdout is human narration and diagnostics go to stderr.
#
# Launches one Emergent engine as a child, records its run metadata, and remains
# its foreground supervisor. On exit it stops only that child PID, gracefully
# with SIGTERM before bounded escalation, removes the PID file only if it wrote
# one, and releases the run's port lease.
set -euo pipefail

usage() {
    echo "usage: bin/run.sh <issue> [--phase pipeline|plan|implement|review] | --list" >&2
}

pid_alive() {
    local PID_VALUE="$1"
    [[ "$PID_VALUE" =~ ^[1-9][0-9]*$ ]] && kill -0 "$PID_VALUE" 2>/dev/null
}

# Exact process start identity: "<boot epoch>:<start time in clock ticks>",
# both read from /proc. Recorded in launch.json at spawn so bin/watch.sh can
# tell this engine apart from a later, unrelated process that merely inherited
# its PID — a PID alone is not an identity. Pairing the tick count with btime
# keeps it exact across reboots, which reset both. Prints nothing and returns 1
# when /proc cannot answer.
proc_identity() {
    local PID_VALUE="$1" STAT_LINE BTIME
    local -a FIELDS

    [[ "$PID_VALUE" =~ ^[1-9][0-9]*$ ]] || return 1
    STAT_LINE="$(cat "/proc/$PID_VALUE/stat" 2>/dev/null)" || return 1
    # comm (field 2) may hold spaces and parens; fields 3+ follow the LAST ')',
    # so starttime (field 22) is the 20th field of the remainder.
    read -ra FIELDS <<<"${STAT_LINE##*)}"
    [ "${#FIELDS[@]}" -ge 20 ] || return 1
    [[ "${FIELDS[19]}" =~ ^[0-9]+$ ]] || return 1
    BTIME="$(awk '/^btime /{print $2; exit}' /proc/stat 2>/dev/null)" || return 1
    [[ "$BTIME" =~ ^[0-9]+$ ]] || return 1
    printf '%s:%s\n' "$BTIME" "${FIELDS[19]}"
}

# A launched engine still runs only when its PID is alive AND still names the
# same process. No recorded identity, or no readable /proc, leaves liveness as
# the only available evidence.
launch_owner_live() {
    local PID_VALUE="$1" RECORDED="$2" CURRENT

    pid_alive "$PID_VALUE" || return 1
    [ -n "$RECORDED" ] || return 0
    CURRENT="$(proc_identity "$PID_VALUE" || true)"
    [ -n "$CURRENT" ] || return 0
    [ "$CURRENT" = "$RECORDED" ]
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

        if launch_owner_live "$PID_VALUE" "$START_VALUE"; then
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
    pipeline|plan|implement|review) ;;
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

PID_FILE="$RUN_DIR/state/engine.pid"
if [ -f "$PID_FILE" ]; then
    EXISTING_PID="$(head -n 1 "$PID_FILE" 2>/dev/null || true)"
    if pid_alive "$EXISTING_PID"; then
        echo "error: run $RUN_SLUG is already active with pid $EXISTING_PID; choose a different issue" >&2
        exit 1
    fi
fi

mkdir -p "$RUN_DIR/state" "$RUN_DIR/logs" "$RUN_DIR/results"

CHILD_PID=""
CHILD_REAPED=0
LEASED=0
PID_FILE_OWNED=0
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

BASE="$(SIGNALBOX_LEASE_PID="$$" "$ROOT/bin/ports.sh" lease "$RUN_SLUG")"
LEASED=1
PORT_PIPELINE="$BASE"
PORT_PLAN="$((BASE + 1))"
PORT_IMPLEMENT="$((BASE + 2))"
PORT_REVIEW="$((BASE + 3))"
PORT_INIT="$((BASE + 4))"
PORT_APPROVAL="$((BASE + 5))"

for TEMPLATE_NAME in pipeline plan implement emergent init; do
    if [ ! -f "$ROOT/templates/$TEMPLATE_NAME.toml" ]; then
        echo "error: template missing at $ROOT/templates/$TEMPLATE_NAME.toml — reinstall the harness" >&2
        exit 1
    fi
    sed \
        -e "s|__SIGNALBOX_RUN_SUFFIX__|-$RUN_SLUG|g" \
        -e "s|__SIGNALBOX_PORT_PIPELINE__|$PORT_PIPELINE|g" \
        -e "s|__SIGNALBOX_PORT_PLAN__|$PORT_PLAN|g" \
        -e "s|__SIGNALBOX_PORT_IMPLEMENT__|$PORT_IMPLEMENT|g" \
        -e "s|__SIGNALBOX_PORT_REVIEW__|$PORT_REVIEW|g" \
        -e "s|__SIGNALBOX_PORT_INIT__|$PORT_INIT|g" \
        -e "s|__SIGNALBOX_PORT_APPROVAL__|$PORT_APPROVAL|g" \
        "$ROOT/templates/$TEMPLATE_NAME.toml" >"$RUN_DIR/$TEMPLATE_NAME.toml"
done

# Comment lines in the templates legitimately name these placeholders;
# bin/check-placeholders.sh reports only live, unrendered occurrences.
"$ROOT/bin/check-placeholders.sh" "$RUN_DIR" || exit 1

PIPELINE_ENGINE="$ENGINE_PREFIX-pipeline-$RUN_SLUG"
PLAN_ENGINE="$ENGINE_PREFIX-plan-$RUN_SLUG"
IMPLEMENT_ENGINE="$ENGINE_PREFIX-implement-stream-$RUN_SLUG"
REVIEW_ENGINE="$ENGINE_PREFIX-review-loop-$RUN_SLUG"
INIT_ENGINE="$ENGINE_PREFIX-init-$RUN_SLUG"
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
    --argjson pipeline_port "$PORT_PIPELINE" \
    --argjson plan_port "$PORT_PLAN" \
    --argjson implement_port "$PORT_IMPLEMENT" \
    --argjson review_port "$PORT_REVIEW" \
    --argjson init_port "$PORT_INIT" \
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
            pipeline: $pipeline_port,
            plan: $plan_port,
            implement: $implement_port,
            review: $review_port,
            init: $init_port,
            approval: $approval_port
        },
        log: $log,
        started: $started
    }' >"$LAUNCH_TEMP"
mv "$LAUNCH_TEMP" "$LAUNCH"

SIGNALBOX_ISSUE="$ISSUE" SIGNALBOX_RUN_SLUG="$RUN_SLUG" \
    emergent --config "$RUN_DIR/$CONFIG_NAME.toml" >"$LOG" 2>&1 &
CHILD_PID=$!
printf '%s\n' "$CHILD_PID" >"$PID_FILE"
PID_FILE_OWNED=1
# Read the identity as early as possible; an engine that dies instantly leaves
# it empty, which every consumer reads as "identity unknown", never as "alive".
CHILD_START="$(proc_identity "$CHILD_PID" || true)"
jq --argjson pid "$CHILD_PID" --arg start "$CHILD_START" \
    '. + {pid: $pid, start_id: $start}' "$LAUNCH" >"$LAUNCH_TEMP"
mv "$LAUNCH_TEMP" "$LAUNCH"

printf 'run:       %s\n' "$RUN_SLUG"
printf 'issue:     %s\n' "$ISSUE"
printf 'engine:    %s\n' "$ENGINE_NAME"
printf 'ports:     %s-%s (watchtower %s-%s; approval %s)\n' \
    "$BASE" "$PORT_APPROVAL" "$BASE" "$PORT_INIT" "$PORT_APPROVAL"
printf 'log:       %s\n' "$LOG"
printf 'run dir:   %s\n' "$RUN_DIR"
printf 'watch:     %s/bin/watch.sh %s\n' "$ROOT" "$RUN_DIR"

if wait "$CHILD_PID"; then
    CHILD_STATUS=0
else
    CHILD_STATUS=$?
fi
CHILD_REAPED=1
exit "$CHILD_STATUS"
