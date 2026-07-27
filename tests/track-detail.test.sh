#!/usr/bin/env bash
# Self-contained test runner for the dashboard's track-detail renderers: the
# review-loop round indicator and the implement-phase shard sidings. No
# framework; the end-to-end cases run the sink on an unused high port. Prints
# PASS/FAIL per case and exits non-zero when any case failed.
#
# Deliberately no -e: cases capture subject statuses that may be non-zero.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SINK_SUBJECT="$ROOT/bin/sink-serve.sh"
FIXTURES=()
TESTS_RUN=0
TESTS_PASSED=0
SERVICE_PID=""
FIXTURE_ROOT=""
SINK_PORT=""
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
    SINK_PORT="$(pick_port 2>"$FIXTURE_ROOT/port.stderr")"
    PORT_STATUS=$?
    if [ "$PORT_STATUS" -ne 0 ] || [ -z "$SINK_PORT" ]; then
        # Never fall through to the machine service's default port.
        SINK_PORT=65534
    fi
}

start_service() {
    local ATTEMPT
    if [ "$PORT_STATUS" -ne 0 ]; then
        return 1
    fi
    SIGNALBOX_SINK_PORT="$SINK_PORT" \
        SIGNALBOX_SINK_STATE="$FIXTURE_ROOT/sink/instances.json" \
        "$SINK_SUBJECT" >"$FIXTURE_ROOT/sink.stdout" 2>"$FIXTURE_ROOT/sink.stderr" &
    SERVICE_PID=$!

    for ATTEMPT in $(seq 1 20); do
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

# 1. The served page carries both track-detail renderers: shard sidings
#    (CSS classes plus the yard state machine) and the review-loop rounds.
fixture
OK=1
if start_service \
    && curl -fsS --max-time 2 \
        "http://127.0.0.1:$SINK_PORT/" >"$FIXTURE_ROOT/page.html" 2>/dev/null \
    && grep -q '^[.]shard-lamp ' "$FIXTURE_ROOT/page.html" \
    && grep -q '[.]shard-lamp[.]s-fixing' "$FIXTURE_ROOT/page.html" \
    && grep -q 'class="sidings"' "$FIXTURE_ROOT/page.html" \
    && grep -q 'const reviewLoop' "$FIXTURE_ROOT/page.html" \
    && grep -q 'const shardYard' "$FIXTURE_ROOT/page.html" \
    && grep -q 'shard[.]built' "$FIXTURE_ROOT/page.html" \
    && grep -q 'fix[.]requested' "$FIXTURE_ROOT/page.html" \
    && grep -q 'stage[.]item' "$FIXTURE_ROOT/page.html"; then
    OK=0
fi
report_case "dashboard serves shard-siding and review-loop renderers" "$OK" \
    "see $FIXTURE_ROOT"

# 2. The sink accepts the implement fan-out and review-cycle topics and
#    replays them on /events, so a freshly opened dashboard can rebuild the
#    cycle state it missed.
INGEST_OK=1
for TOPIC in stage.item shard.built shard.review.raw shard.fix.requested \
    shard.done fix.requested review.requested; do
    ENGINE="implement"
    case "$TOPIC" in fix.requested|review.requested) ENGINE="review";; esac
    STATUS="$(jq -cn --arg t "$TOPIC" --arg e "$ENGINE" \
        '{type: $t, engine_label: $e,
          instance: {key: "repo/issue-0@tracktest"},
          payload: {stage: "stage-1", round: 2,
                    current: {shard: "alpha", branch: "shard/x/stage-1-alpha"},
                    id: "stage-1", shards: [{id: "alpha"}, {id: "beta"}],
                    pending: [{shard: "beta"}], done: ["alpha"],
                    verdict: "REQUEST_CHANGES"}}' \
        | curl -sS -o /dev/null -w '%{http_code}' --max-time 2 \
            -X POST -H "Content-Type: application/json" \
            --data-binary @- \
            "http://127.0.0.1:$SINK_PORT/ingest" 2>/dev/null)"
    if [ "$STATUS" != "204" ]; then
        INGEST_OK=1
        break
    fi
    INGEST_OK=0
done
REPLAY_OK=1
if [ "$INGEST_OK" -eq 0 ]; then
    curl -sN --max-time 2 "http://127.0.0.1:$SINK_PORT/events" \
        >"$FIXTURE_ROOT/events.out" 2>/dev/null || true
    if grep -q 'event: shard[.]fix[.]requested' "$FIXTURE_ROOT/events.out" \
        && grep -q 'event: fix[.]requested' "$FIXTURE_ROOT/events.out" \
        && grep -q '"round":2' "$FIXTURE_ROOT/events.out"; then
        REPLAY_OK=0
    fi
fi
report_case "sink ingests and replays fan-out and review-cycle topics" \
    "$((INGEST_OK || REPLAY_OK))" "see $FIXTURE_ROOT"
stop_service

printf '%d/%d cases passed\n' "$TESTS_PASSED" "$TESTS_RUN"
[ "$TESTS_PASSED" -eq "$TESTS_RUN" ]
