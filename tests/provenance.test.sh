#!/usr/bin/env bash
# Self-contained test runner for artifact provenance stamping, status joining,
# and dashboard rendering. No framework; each fixture lives under mktemp -d,
# and the end-to-end cases use an unused high port. Prints PASS/FAIL per case
# and exits non-zero when any case failed.
#
# Deliberately no -e: cases capture subject statuses that may be non-zero.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROVENANCE_SOURCE="$ROOT/bin/_provenance.sh"
SINK_SUBJECT="$ROOT/bin/sink-serve.sh"
FIXTURES=()
TESTS_RUN=0
TESTS_PASSED=0
SERVICE_PID=""
FIXTURE_ROOT=""
RUN_DIR=""
SINK_PORT=""
SINK_STATE=""
SINK_STDOUT=""
SINK_STDERR=""
PORT_STATUS=0

# shellcheck source=../bin/_provenance.sh
source "$PROVENANCE_SOURCE"

stop_service() {
    if [ -n "$SERVICE_PID" ]; then
        kill -TERM "$SERVICE_PID" 2>/dev/null || true
        wait "$SERVICE_PID" 2>/dev/null || true
        SERVICE_PID=""
    fi
}

cleanup() {
    local FIXTURE
    # Stop only the exact sink process launched by this runner. Never use
    # pkill: another repository may own the real machine-wide sink.
    stop_service
    for FIXTURE in "${FIXTURES[@]}"; do
        rm -rf -- "$FIXTURE"
    done
}
trap cleanup EXIT

pick_port() {
    python3 - <<'PYEOF'
import socket

for _ in range(100):
    with socket.socket() as candidate:
        candidate.bind(("127.0.0.1", 0))
        port = candidate.getsockname()[1]
    if port >= 20000:
        print(port)
        break
else:
    raise SystemExit("could not select an unused high port")
PYEOF
}

fixture() {
    FIXTURE_ROOT="$(mktemp -d)"
    FIXTURES+=("$FIXTURE_ROOT")
    RUN_DIR="$FIXTURE_ROOT/run"
    SINK_PORT="$(pick_port 2>"$FIXTURE_ROOT/port.stderr")"
    PORT_STATUS=$?
    if [ "$PORT_STATUS" -ne 0 ] || [ -z "$SINK_PORT" ]; then
        # Never fall through to the machine service's default port.
        SINK_PORT=65534
    fi
    SINK_STATE="$FIXTURE_ROOT/sink/instances.json"
    SINK_STDOUT="$FIXTURE_ROOT/sink.stdout"
    SINK_STDERR="$FIXTURE_ROOT/sink.stderr"
    mkdir -p "$RUN_DIR"
}

start_service() {
    local ATTEMPT
    if [ "$PORT_STATUS" -ne 0 ]; then
        return 1
    fi
    SIGNALBOX_SINK_PORT="$SINK_PORT" \
        SIGNALBOX_SINK_STATE="$SINK_STATE" \
        "$SINK_SUBJECT" >"$SINK_STDOUT" 2>"$SINK_STDERR" &
    SERVICE_PID=$!

    for ATTEMPT in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        if curl -fsS --max-time 1 \
            "http://127.0.0.1:$SINK_PORT/healthz" >/dev/null 2>&1; then
            return 0
        fi
        if ! kill -0 "$SERVICE_PID" 2>/dev/null; then
            return 1
        fi
        sleep 0.05
    done
    return 1
}

report_case() {
    local NAME="$1" OK="$2" DETAIL="${3:-}"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$OK" -eq 0 ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        printf 'PASS %s\n' "$NAME"
    else
        printf 'FAIL %s%s\n' "$NAME" "${DETAIL:+ — $DETAIL}"
    fi
}

# 1. Stamps create, merge, and replace map entries. Empty effort is omitted.
fixture
stamp_provenance "plan.json" "claude" "opus" "" \
    2>>"$FIXTURE_ROOT/provenance.stderr"
FIRST_STATUS=$?
stamp_provenance "results/CR.md" "codex" "gpt-5.6-sol" "high" \
    2>>"$FIXTURE_ROOT/provenance.stderr"
SECOND_STATUS=$?
MERGE_OK=1
if [ "$FIRST_STATUS" -eq 0 ] \
    && [ "$SECOND_STATUS" -eq 0 ] \
    && jq -e '
        length == 2
        and .["plan.json"].agent == "claude"
        and .["plan.json"].model == "opus"
        and (.["plan.json"] | has("effort") | not)
        and .["results/CR.md"].agent == "codex"
        and .["results/CR.md"].model == "gpt-5.6-sol"
        and .["results/CR.md"].effort == "high"
    ' "$RUN_DIR/state/provenance.json" >/dev/null 2>&1; then
    MERGE_OK=0
fi
stamp_provenance "plan.json" "codex" "gpt-5.6-sol" "max" \
    2>>"$FIXTURE_ROOT/provenance.stderr"
REPLACE_STATUS=$?
OK=1
if [ "$MERGE_OK" -eq 0 ] \
    && [ "$REPLACE_STATUS" -eq 0 ] \
    && jq -e '
        length == 2
        and .["plan.json"].agent == "codex"
        and .["plan.json"].model == "gpt-5.6-sol"
        and .["plan.json"].effort == "max"
        and (.["plan.json"].ts | type) == "string"
        and has("results/CR.md")
    ' "$RUN_DIR/state/provenance.json" >/dev/null 2>&1; then
    OK=0
fi
report_case "stamps create, merge, replace, and omit empty effort" "$OK" \
    "first=$FIRST_STATUS second=$SECOND_STATUS replace=$REPLACE_STATUS"

# 2. Invalid stamps are diagnostic no-ops, return zero, and are set -e safe.
fixture
stamp_provenance "../escape" "codex" "gpt-5.6-sol" "high" \
    2>>"$FIXTURE_ROOT/provenance.stderr"
TRAVERSAL_STATUS=$?
stamp_provenance "/absolute" "codex" "gpt-5.6-sol" "high" \
    2>>"$FIXTURE_ROOT/provenance.stderr"
ABSOLUTE_STATUS=$?
stamp_provenance "plan.json" "other" "model" "high" \
    2>>"$FIXTURE_ROOT/provenance.stderr"
AGENT_STATUS=$?
stamp_provenance "plan.json" "codex" "model" "extreme" \
    2>>"$FIXTURE_ROOT/provenance.stderr"
EFFORT_STATUS=$?
SET_E_OUTPUT="$(
    bash -c '
        set -euo pipefail
        RUN_DIR="$1"
        source "$2"
        stamp_provenance "../escape" codex model high
        printf survived
    ' _ "$RUN_DIR" "$PROVENANCE_SOURCE" 2>"$FIXTURE_ROOT/set-e.stderr"
)"
SET_E_STATUS=$?
OK=1
if [ "$TRAVERSAL_STATUS" -eq 0 ] \
    && [ "$ABSOLUTE_STATUS" -eq 0 ] \
    && [ "$AGENT_STATUS" -eq 0 ] \
    && [ "$EFFORT_STATUS" -eq 0 ] \
    && [ "$SET_E_STATUS" -eq 0 ] \
    && [ "$SET_E_OUTPUT" = "survived" ] \
    && [ ! -e "$RUN_DIR/state/provenance.json" ]; then
    OK=0
fi
report_case "invalid stamps write nothing and remain set -e safe" "$OK" \
    "traversal=$TRAVERSAL_STATUS absolute=$ABSOLUTE_STATUS agent=$AGENT_STATUS effort=$EFFORT_STATUS set-e=$SET_E_STATUS"

# 3. A corrupt old map cannot abort or discard the new valid stamp.
fixture
mkdir -p "$RUN_DIR/state"
printf '%s\n' '{"torn":' >"$RUN_DIR/state/provenance.json"
stamp_provenance "plan.json" "claude" "opus" "medium" \
    2>>"$FIXTURE_ROOT/provenance.stderr"
CORRUPT_STATUS=$?
OK=1
if [ "$CORRUPT_STATUS" -eq 0 ] \
    && jq -e '
        length == 1
        and .["plan.json"].agent == "claude"
        and .["plan.json"].model == "opus"
        and .["plan.json"].effort == "medium"
    ' "$RUN_DIR/state/provenance.json" >/dev/null 2>&1; then
    OK=0
fi
report_case "a corrupt map is replaced with the new entry" "$OK" \
    "status=$CORRUPT_STATUS map=$(head -c 180 "$RUN_DIR/state/provenance.json" 2>/dev/null)"

# 4. Concurrent writers serialize through the helper's flock.
fixture
PIDS=()
for INDEX in 0 1 2 3 4 5 6 7 8 9 10 11; do
    stamp_provenance "logs/concurrent-$INDEX.log" "codex" "model-$INDEX" "low" \
        2>>"$FIXTURE_ROOT/provenance.stderr" &
    PIDS+=("$!")
done
WAIT_OK=0
for CHILD_PID in "${PIDS[@]}"; do
    if ! wait "$CHILD_PID"; then
        WAIT_OK=1
    fi
done
OK=1
if [ "$WAIT_OK" -eq 0 ] \
    && jq -e '
        length == 12
        and ([keys[] | startswith("logs/concurrent-")] | all)
        and ([.[] | .agent == "codex" and .effort == "low"] | all)
    ' "$RUN_DIR/state/provenance.json" >/dev/null 2>&1; then
    OK=0
fi
report_case "concurrent stamps all land under flock" "$OK" \
    "wait=$WAIT_OK count=$(jq 'length' "$RUN_DIR/state/provenance.json" 2>/dev/null)"

# 5. Reset removes the map and remains a no-op when it is already absent.
fixture
stamp_provenance "plan.json" "codex" "gpt-5.6-sol" "high" \
    2>>"$FIXTURE_ROOT/provenance.stderr"
STAMP_STATUS=$?
reset_provenance 2>>"$FIXTURE_ROOT/provenance.stderr"
RESET_STATUS=$?
FIRST_ABSENT=1
if [ ! -e "$RUN_DIR/state/provenance.json" ]; then
    FIRST_ABSENT=0
fi
reset_provenance 2>>"$FIXTURE_ROOT/provenance.stderr"
SECOND_RESET_STATUS=$?
OK=1
if [ "$STAMP_STATUS" -eq 0 ] \
    && [ "$RESET_STATUS" -eq 0 ] \
    && [ "$FIRST_ABSENT" -eq 0 ] \
    && [ "$SECOND_RESET_STATUS" -eq 0 ] \
    && [ ! -e "$RUN_DIR/state/provenance.json" ]; then
    OK=0
fi
report_case "reset removes the map and tolerates an absent map" "$OK" \
    "stamp=$STAMP_STATUS reset=$RESET_STATUS second=$SECOND_RESET_STATUS"

# 6. The complete disk-to-status join sanitizes and attaches matching entries.
fixture
mkdir -p "$RUN_DIR/state" "$RUN_DIR/logs"
jq -n '{feature: "provenance-pills", stages: []}' >"$RUN_DIR/plan.json"
jq -n '{verdict: "GREEN"}' >"$RUN_DIR/state/gate.json"
printf '%s\n' "fixture log" >"$RUN_DIR/logs/build.log"
jq -n '{
    "plan.json": {
        agent: "codex", model: "gpt-5.6-sol", effort: "high",
        ts: "2026-07-27T10:04:11Z", ignored: true
    },
    "logs/build.log": {
        agent: "claude", model: "opus", effort: "invalid",
        ts: "2026-07-27T10:05:12Z"
    },
    "results/missing.md": {
        agent: "codex", model: "unused", effort: "max"
    }
}' >"$RUN_DIR/state/provenance.json"
start_service
READY_STATUS=$?
if [ "$READY_STATUS" -eq 0 ]; then
    jq -n \
        --arg run_dir "$RUN_DIR" \
        '{
            type: "fixture.ready",
            engine_label: "test",
            payload: {
                provenance: {
                    agent: "codex", model: "gpt-5.6-sol", effort: "xhigh"
                }
            },
            instance: {
                key: "fixture/provenance@one",
                repo: "fixture",
                run_dir: $run_dir
            }
        }' \
        | curl -fsS --max-time 2 -o /dev/null \
            -H "Content-Type: application/json" --data-binary @- \
            "http://127.0.0.1:$SINK_PORT/ingest"
    POST_STATUS=$?
    curl -fsS --max-time 2 \
        "http://127.0.0.1:$SINK_PORT/status" >"$FIXTURE_ROOT/status.json"
    STATUS_FETCH=$?
    curl -fsS --max-time 2 \
        "http://127.0.0.1:$SINK_PORT/" >"$FIXTURE_ROOT/page.html"
    PAGE_FETCH=$?
else
    POST_STATUS=1
    STATUS_FETCH=1
    PAGE_FETCH=1
fi
OK=1
if [ "$READY_STATUS" -eq 0 ] \
    && [ "$POST_STATUS" -eq 0 ] \
    && [ "$STATUS_FETCH" -eq 0 ] \
    && [ "$PAGE_FETCH" -eq 0 ] \
    && jq -e '
        .instances | length == 1
        and .[0].artifacts["plan.json"].provenance
            == {agent: "codex", model: "gpt-5.6-sol", effort: "high"}
        and (.[0].logs[] | select(.file == "build.log") | .provenance)
            == {agent: "claude", model: "opus"}
        and (.[0].artifacts["state/gate.json"] | has("provenance") | not)
    ' "$FIXTURE_ROOT/status.json" >/dev/null 2>&1 \
    && grep -q '^[.]pill ' "$FIXTURE_ROOT/page.html" \
    && grep -q 'appendProvenancePills' "$FIXTURE_ROOT/page.html" \
    && grep -q 'event-provenance' "$FIXTURE_ROOT/page.html"; then
    OK=0
fi
report_case "/status joins sanitized provenance and the dashboard serves pill renderers" "$OK" \
    "ready=$READY_STATUS post=$POST_STATUS status=$STATUS_FETCH page=$PAGE_FETCH sink=$(head -c 160 "$SINK_STDERR" 2>/dev/null)"

# 7. A malformed map degrades to a normal status response with no provenance.
printf '%s\n' '{"plan.json":' >"$RUN_DIR/state/provenance.json"
if [ "$READY_STATUS" -eq 0 ]; then
    curl -fsS --max-time 2 \
        "http://127.0.0.1:$SINK_PORT/status" >"$FIXTURE_ROOT/malformed-status.json"
    MALFORMED_FETCH=$?
else
    MALFORMED_FETCH=1
fi
OK=1
if [ "$MALFORMED_FETCH" -eq 0 ] \
    && jq -e '
        .instances | length == 1
        and ([.[0].artifacts[] | has("provenance")] | any | not)
        and ([.[0].logs[] | has("provenance")] | any | not)
    ' "$FIXTURE_ROOT/malformed-status.json" >/dev/null 2>&1; then
    OK=0
fi
report_case "a malformed map leaves /status well formed and provenance-free" "$OK" \
    "fetch=$MALFORMED_FETCH body=$(head -c 180 "$FIXTURE_ROOT/malformed-status.json" 2>/dev/null)"
stop_service

printf '%d/%d cases passed\n' "$TESTS_PASSED" "$TESTS_RUN"
[ "$TESTS_PASSED" -eq "$TESTS_RUN" ]
