#!/usr/bin/env bash
# Self-contained end-to-end test runner for the shared SSE push path. No
# framework and no dependencies beyond coreutils + jq + curl + python3; every
# fixture is built under its own mktemp -d fake harness tree, and every sink
# uses an unused high port rather than the machine service's port. Prints
# PASS/FAIL per case and exits non-zero when any case failed.
#
# Deliberately no -e: several cases must capture and assert a subject exit
# status that is expected to be non-zero.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORWARD_SOURCE="$ROOT/bin/sse-forward.sh"
ENV_SOURCE="$ROOT/bin/_env.sh"
SINK_SUBJECT="$ROOT/bin/sink-serve.sh"
FIXTURES=()
TESTS_RUN=0
TESTS_PASSED=0
SERVICE_PID=""
FIXTURE_ROOT=""
HARNESS_ROOT=""
RUN_DIR=""
FORWARD_SUBJECT=""
SINK_PORT=""
SINK_STATE=""
SINK_STDOUT=""
SINK_STDERR=""
FORWARD_STDOUT=""
FORWARD_STDERR=""
FORWARD_STATUS=0
PORT_STATUS=0

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
    HARNESS_ROOT="$FIXTURE_ROOT/example-repo"
    RUN_DIR="$HARNESS_ROOT/runs/issue-14"
    FORWARD_SUBJECT="$HARNESS_ROOT/bin/sse-forward.sh"
    SINK_PORT="$(pick_port 2>"$FIXTURE_ROOT/port.stderr")"
    PORT_STATUS=$?
    if [ "$PORT_STATUS" -ne 0 ] || [ -z "$SINK_PORT" ]; then
        # Never let a failed probe collapse to sink-serve.sh's real 8099
        # default. The case will fail on PORT_STATUS before starting a server.
        SINK_PORT=65534
    fi
    SINK_STATE="$FIXTURE_ROOT/sink/instances.json"
    SINK_STDOUT="$FIXTURE_ROOT/sink.stdout"
    SINK_STDERR="$FIXTURE_ROOT/sink.stderr"
    FORWARD_STDOUT="$FIXTURE_ROOT/forward.stdout"
    FORWARD_STDERR="$FIXTURE_ROOT/forward.stderr"

    mkdir -p "$HARNESS_ROOT/bin" "$RUN_DIR/state" "$RUN_DIR/results"
    ln -s "$FORWARD_SOURCE" "$FORWARD_SUBJECT"
    ln -s "$ENV_SOURCE" "$HARNESS_ROOT/bin/_env.sh"

    jq -n \
        --arg engine "signalbox-implement-stream-issue-14" \
        --arg start_id "0:0" \
        --argjson pid "$$" \
        '{
            issue: 14,
            slug: "issue-14",
            engines: {implement: $engine},
            pid: $pid,
            start_id: $start_id
        }' >"$RUN_DIR/launch.json"
    jq -n \
        '{issue: 14, feature: "shared-sink-service", stages: []}' \
        >"$RUN_DIR/plan.json"
    jq -n '{verdict: "GREEN"}' >"$RUN_DIR/state/gate.json"
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

forward_event() {
    printf '%s' \
        '{"correlation_id":"cid-14","stage":"s1","nested":{"ok":true}}' \
        | SIGNALBOX_RUN_SLUG="issue-14" \
            SIGNALBOX_SINK_PORT="$SINK_PORT" \
            EMERGENT_CORRELATION_ID="cor_01kyk5bd3xfcgbvh2tacztktzb" \
            "$FORWARD_SUBJECT" implement shard.built \
            >"$FORWARD_STDOUT" 2>"$FORWARD_STDERR"
    FORWARD_STATUS=$?
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

# 1. The real forwarder registers the fake harness instance with its launch
#    metadata and the engine selected by the forwarder's label.
fixture
start_service
READY_STATUS=$?
if [ "$READY_STATUS" -eq 0 ]; then
    forward_event
    curl -fsS --max-time 2 \
        "http://127.0.0.1:$SINK_PORT/status" >"$FIXTURE_ROOT/status.json"
    STATUS_FETCH=$?
else
    FORWARD_STATUS=1
    STATUS_FETCH=1
fi
OK=1
if [ "$READY_STATUS" -eq 0 ] \
    && [ "$FORWARD_STATUS" -eq 0 ] \
    && [ "$STATUS_FETCH" -eq 0 ] \
    && [ ! -s "$FORWARD_STDOUT" ] \
    && jq -e '
        .instances | length == 1
        and (.[0].key | startswith("example-repo/issue-14@"))
        and .[0].repo == "example-repo"
        and .[0].slug == "issue-14"
        and .[0].issue == 14
        and .[0].engines.implement
            == "signalbox-implement-stream-issue-14"
    ' "$FIXTURE_ROOT/status.json" >/dev/null 2>&1; then
    OK=0
fi
report_case "forwarded event registers the complete instance identity" "$OK" \
    "ready=$READY_STATUS forward=$FORWARD_STATUS status=$STATUS_FETCH sink=$(head -c 160 "$SINK_STDERR" 2>/dev/null)"
stop_service

# 2. /status derives artifact truth from disk on every request. A new artifact
#    must appear without another event being narrated.
fixture
start_service
READY_STATUS=$?
if [ "$READY_STATUS" -eq 0 ]; then
    forward_event
    curl -fsS --max-time 2 \
        "http://127.0.0.1:$SINK_PORT/status" >"$FIXTURE_ROOT/status-before.json"
    BEFORE_FETCH=$?
    PLAN_SIZE="$(wc -c <"$RUN_DIR/plan.json" | tr -d ' ')"
    GATE_SIZE="$(wc -c <"$RUN_DIR/state/gate.json" | tr -d ' ')"
    jq -n '{action: "promote"}' >"$RUN_DIR/state/pending.json"
    PENDING_SIZE="$(wc -c <"$RUN_DIR/state/pending.json" | tr -d ' ')"
    curl -fsS --max-time 2 \
        "http://127.0.0.1:$SINK_PORT/status" >"$FIXTURE_ROOT/status-after.json"
    AFTER_FETCH=$?
else
    FORWARD_STATUS=1
    BEFORE_FETCH=1
    AFTER_FETCH=1
    PLAN_SIZE=0
    GATE_SIZE=0
    PENDING_SIZE=0
fi
OK=1
if [ "$READY_STATUS" -eq 0 ] \
    && [ "$FORWARD_STATUS" -eq 0 ] \
    && [ "$BEFORE_FETCH" -eq 0 ] \
    && [ "$AFTER_FETCH" -eq 0 ] \
    && jq -e \
        --argjson plan_size "$PLAN_SIZE" \
        --argjson gate_size "$GATE_SIZE" \
        '
        .instances[0].artifacts["plan.json"].exists == true
        and .instances[0].artifacts["plan.json"].size == $plan_size
        and .instances[0].artifacts["state/gate.json"].exists == true
        and .instances[0].artifacts["state/gate.json"].size == $gate_size
        and .instances[0].artifacts["state/pending.json"].exists == false
        ' "$FIXTURE_ROOT/status-before.json" >/dev/null 2>&1 \
    && jq -e \
        --argjson pending_size "$PENDING_SIZE" \
        '
        .instances[0].artifacts["state/pending.json"].exists == true
        and .instances[0].artifacts["state/pending.json"].size == $pending_size
        ' "$FIXTURE_ROOT/status-after.json" >/dev/null 2>&1; then
    OK=0
fi
report_case "/status re-stats disk artifacts without a new event" "$OK" \
    "ready=$READY_STATUS forward=$FORWARD_STATUS before=$BEFORE_FETCH after=$AFTER_FETCH"
stop_service

# 3. A client connecting after ingestion receives the ring replay as one SSE
#    frame with both the topic line and the complete envelope data line.
fixture
start_service
READY_STATUS=$?
if [ "$READY_STATUS" -eq 0 ]; then
    forward_event
    curl -sN --max-time 1 \
        "http://127.0.0.1:$SINK_PORT/events" >"$FIXTURE_ROOT/events.txt"
    EVENTS_STATUS=$?
else
    FORWARD_STATUS=1
    EVENTS_STATUS=1
fi
sed -n 's/^data: //p' "$FIXTURE_ROOT/events.txt" 2>/dev/null \
    | head -n 1 >"$FIXTURE_ROOT/event-data.json"
OK=1
if [ "$READY_STATUS" -eq 0 ] \
    && [ "$FORWARD_STATUS" -eq 0 ] \
    && { [ "$EVENTS_STATUS" -eq 0 ] || [ "$EVENTS_STATUS" -eq 28 ]; } \
    && grep -qx 'event: shard.built' "$FIXTURE_ROOT/events.txt" \
    && jq -e '
        .type == "shard.built"
        and .engine_label == "implement"
        and .correlation_id == "cor_01kyk5bd3xfcgbvh2tacztktzb"
        and .payload == {
            correlation_id: "cid-14",
            stage: "s1",
            nested: {ok: true}
        }
        and (.instance.key | startswith("example-repo/issue-14@"))
        and .instance.repo == "example-repo"
        and .instance.slug == "issue-14"
        and .instance.issue == 14
        and .instance.engine == "signalbox-implement-stream-issue-14"
        and (.instance.pid | type) == "number"
        and .instance.start_id == "0:0"
    ' "$FIXTURE_ROOT/event-data.json" >/dev/null 2>&1; then
    OK=0
fi
report_case "/events replays the topic and complete envelope" "$OK" \
    "ready=$READY_STATUS forward=$FORWARD_STATUS curl=$EVENTS_STATUS frame=$(head -c 180 "$FIXTURE_ROOT/events.txt" 2>/dev/null)"
stop_service

# 4. A malformed ingest is isolated to its request handler; the shared service
#    remains healthy for every other instance.
fixture
start_service
READY_STATUS=$?
if [ "$READY_STATUS" -eq 0 ]; then
    HTTP_CODE="$(
        printf '%s' '{"broken":' \
            | curl -sS --max-time 2 \
                -o "$FIXTURE_ROOT/malformed-body" \
                -w '%{http_code}' \
                -H "Content-Type: application/json" \
                --data-binary @- \
                "http://127.0.0.1:$SINK_PORT/ingest"
    )"
    MALFORMED_STATUS=$?
    curl -fsS --max-time 2 \
        "http://127.0.0.1:$SINK_PORT/healthz" >"$FIXTURE_ROOT/health.json"
    HEALTH_STATUS=$?
else
    HTTP_CODE=000
    MALFORMED_STATUS=1
    HEALTH_STATUS=1
fi
OK=1
if [ "$READY_STATUS" -eq 0 ] \
    && [ "$MALFORMED_STATUS" -eq 0 ] \
    && [ "$HTTP_CODE" -ge 400 ] 2>/dev/null \
    && [ "$HTTP_CODE" -lt 500 ] 2>/dev/null \
    && [ "$HEALTH_STATUS" -eq 0 ] \
    && jq -e '.ok == true' "$FIXTURE_ROOT/health.json" >/dev/null 2>&1; then
    OK=0
fi
report_case "malformed ingest returns 4xx and leaves the sink healthy" "$OK" \
    "ready=$READY_STATUS post=$MALFORMED_STATUS http=$HTTP_CODE health=$HEALTH_STATUS"
stop_service

# 5. Once the exact service process is stopped, delivery remains best-effort:
#    the forwarder exits zero and its bounded curl cannot stall the pipeline.
fixture
start_service
READY_STATUS=$?
stop_service
START_MS="$(date +%s%3N)"
forward_event
END_MS="$(date +%s%3N)"
ELAPSED_MS=$((END_MS - START_MS))
OK=1
if [ "$READY_STATUS" -eq 0 ] \
    && [ "$FORWARD_STATUS" -eq 0 ] \
    && [ "$ELAPSED_MS" -lt 3000 ]; then
    OK=0
fi
report_case "stopped sink cannot fail or stall the forwarder" "$OK" \
    "ready=$READY_STATUS status=$FORWARD_STATUS elapsed=${ELAPSED_MS}ms"

# 6. No system.stopped.* event is needed: an impossible start identity for a
#    live PID is enough for /proc-based liveness to reject the instance.
fixture
start_service
READY_STATUS=$?
if [ "$READY_STATUS" -eq 0 ]; then
    forward_event
    curl -fsS --max-time 2 \
        "http://127.0.0.1:$SINK_PORT/status" >"$FIXTURE_ROOT/liveness.json"
    STATUS_FETCH=$?
else
    FORWARD_STATUS=1
    STATUS_FETCH=1
fi
OK=1
if [ "$READY_STATUS" -eq 0 ] \
    && [ "$FORWARD_STATUS" -eq 0 ] \
    && [ "$STATUS_FETCH" -eq 0 ] \
    && jq -e \
        --argjson pid "$$" \
        '
        .instances[0].pid == $pid
        and .instances[0].start_id == "0:0"
        and .instances[0].state == "stopped"
        ' "$FIXTURE_ROOT/liveness.json" >/dev/null 2>&1; then
    OK=0
fi
report_case "/proc identity alone marks a mismatched instance stopped" "$OK" \
    "ready=$READY_STATUS forward=$FORWARD_STATUS status=$STATUS_FETCH state=$(jq -r '.instances[0].state // "missing"' "$FIXTURE_ROOT/liveness.json" 2>/dev/null)"
stop_service

# 7. system.stopped.<primitive> names one component, not the run. An instance
#    without launch identity must stay unknown when a component stops, because
#    its engine may still be running.
fixture
rm -f "$RUN_DIR/launch.json"
start_service
READY_STATUS=$?
if [ "$READY_STATUS" -eq 0 ]; then
    printf '%s' '{"name":"forward-shard-built"}' \
        | SIGNALBOX_RUN_SLUG="issue-14" \
            SIGNALBOX_SINK_PORT="$SINK_PORT" \
            "$FORWARD_SUBJECT" implement "system.stopped.forward-shard-built" \
            >"$FORWARD_STDOUT" 2>"$FORWARD_STDERR"
    FORWARD_STATUS=$?
    curl -fsS --max-time 2 \
        "http://127.0.0.1:$SINK_PORT/status" >"$FIXTURE_ROOT/component-stop.json"
    STATUS_FETCH=$?
else
    FORWARD_STATUS=1
    STATUS_FETCH=1
fi
OK=1
if [ "$READY_STATUS" -eq 0 ] \
    && [ "$FORWARD_STATUS" -eq 0 ] \
    && [ "$STATUS_FETCH" -eq 0 ] \
    && jq -e '
        .instances | length == 1
        and .[0].pid == null
        and .[0].state == "unknown"
        ' "$FIXTURE_ROOT/component-stop.json" >/dev/null 2>&1; then
    OK=0
fi
report_case "a component stop leaves an unidentified instance unknown" "$OK" \
    "ready=$READY_STATUS forward=$FORWARD_STATUS status=$STATUS_FETCH state=$(jq -r '.instances[0].state // "missing"' "$FIXTURE_ROOT/component-stop.json" 2>/dev/null)"
stop_service

printf '%d/%d cases passed\n' "$TESTS_PASSED" "$TESTS_RUN"
[ "$TESTS_PASSED" -eq "$TESTS_RUN" ]
