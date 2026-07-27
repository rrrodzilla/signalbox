#!/usr/bin/env bash
# Self-contained test runner for sink artifact age gating and stale dashboard
# rendering. No framework; fixtures live under mktemp -d and the sink uses an
# unused high port. Prints PASS/FAIL per case and exits non-zero on failure.
#
# Deliberately no -e: cases capture subject statuses that may be non-zero.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SINK_SUBJECT="$ROOT/bin/sink-serve.sh"
FIXTURE_ROOT="$(mktemp -d)"
RUN_ROOT="$FIXTURE_ROOT/runs"
SINK_STATE="$FIXTURE_ROOT/sink/instances.json"
SINK_STDOUT="$FIXTURE_ROOT/sink.stdout"
SINK_STDERR="$FIXTURE_ROOT/sink.stderr"
SERVICE_PID=""
SINK_PORT=""
PORT_STATUS=0
TESTS_RUN=0
TESTS_PASSED=0

stop_service() {
    if [ -n "$SERVICE_PID" ]; then
        kill -TERM "$SERVICE_PID" 2>/dev/null || true
        wait "$SERVICE_PID" 2>/dev/null || true
        SERVICE_PID=""
    fi
}

cleanup() {
    # Stop only the exact sink process launched by this runner. Never use
    # pkill: another repository may own the real machine-wide sink.
    stop_service
    rm -rf -- "$FIXTURE_ROOT"
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

register_instance() {
    local KEY="$1" RUN_DIR="$2"
    jq -n \
        --arg key "$KEY" \
        --arg run_dir "$RUN_DIR" \
        '{
            type: "fixture.ready",
            engine_label: "test",
            payload: {},
            instance: {
                key: $key,
                repo: "fixture",
                run_dir: $run_dir
            }
        }' \
        | curl -fsS --max-time 2 -o /dev/null \
            -H "Content-Type: application/json" --data-binary @- \
            "http://127.0.0.1:$SINK_PORT/ingest"
}

fetch_status() {
    curl -fsS --max-time 2 \
        "http://127.0.0.1:$SINK_PORT/status"
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

mkdir -p "$RUN_ROOT"
SINK_PORT="$(pick_port 2>"$FIXTURE_ROOT/port.stderr")"
PORT_STATUS=$?
if [ "$PORT_STATUS" -ne 0 ] || [ -z "$SINK_PORT" ]; then
    # Never fall through to the machine service's default port.
    SINK_PORT=65534
fi
start_service
READY_STATUS=$?

# 1. Without a launch record the producer-phase gate applies alone: old
# artifacts and artifacts whose producing phase has not started are marked
# stale, while every phase stamp remains a reference clock.
LEFTOVERS_DIR="$RUN_ROOT/leftovers"
mkdir -p "$LEFTOVERS_DIR/state" "$LEFTOVERS_DIR/results"
jq -n '{feature: "old-plan", stages: []}' >"$LEFTOVERS_DIR/plan.json"
jq -n '{verdict: "GREEN"}' >"$LEFTOVERS_DIR/state/gate.json"
printf '%s\n' "PROMOTION_READY" >"$LEFTOVERS_DIR/results/CR.md"
: >"$LEFTOVERS_DIR/state/pipeline-plan.stamp"
touch -d "@1000" "$LEFTOVERS_DIR/plan.json"
touch -d "@1400" "$LEFTOVERS_DIR/state/gate.json" "$LEFTOVERS_DIR/results/CR.md"
touch -d "@1600" "$LEFTOVERS_DIR/state/pipeline-plan.stamp"
if [ "$READY_STATUS" -eq 0 ]; then
    register_instance "fixture/leftovers@one" "$LEFTOVERS_DIR"
    LEFTOVERS_POST=$?
    fetch_status >"$FIXTURE_ROOT/leftovers-status.json"
    LEFTOVERS_FETCH=$?
else
    LEFTOVERS_POST=1
    LEFTOVERS_FETCH=1
fi
OK=1
if [ "$READY_STATUS" -eq 0 ] \
    && [ "$LEFTOVERS_POST" -eq 0 ] \
    && [ "$LEFTOVERS_FETCH" -eq 0 ] \
    && jq -e '
        .instances[]
        | select(.key == "fixture/leftovers@one")
        | .artifacts as $a
        | $a["plan.json"].stale == true
          and $a["state/gate.json"].stale == true
          and $a["results/CR.md"].stale == true
          and ([
            $a["state/pipeline-plan.stamp"],
            $a["state/pipeline-implement.stamp"],
            $a["state/pipeline-review.stamp"]
          ] | all(.stale == false))
    ' "$FIXTURE_ROOT/leftovers-status.json" >/dev/null 2>&1; then
    OK=0
fi
report_case "leftovers without a launch record are stale by producing phase" "$OK" \
    "ready=$READY_STATUS post=$LEFTOVERS_POST fetch=$LEFTOVERS_FETCH"

# 2. Artifacts newer than both the current launch and their producing phase
# stamp are current.
CURRENT_DIR="$RUN_ROOT/current"
mkdir -p "$CURRENT_DIR/state"
jq -n '{feature: "current-plan", stages: []}' >"$CURRENT_DIR/plan.json"
jq -n '{verdict: "GREEN"}' >"$CURRENT_DIR/state/gate.json"
jq -n '{issue: 1, phase: "pipeline", started: "1970-01-01T00:31:40Z"}' \
    >"$CURRENT_DIR/launch.json"
: >"$CURRENT_DIR/state/pipeline-plan.stamp"
: >"$CURRENT_DIR/state/pipeline-implement.stamp"
touch -d "@1900" "$CURRENT_DIR/launch.json"
touch -d "@2000" \
    "$CURRENT_DIR/state/pipeline-plan.stamp" \
    "$CURRENT_DIR/state/pipeline-implement.stamp"
touch -d "@2100" "$CURRENT_DIR/plan.json" "$CURRENT_DIR/state/gate.json"
if [ "$READY_STATUS" -eq 0 ]; then
    register_instance "fixture/current@one" "$CURRENT_DIR"
    CURRENT_POST=$?
    fetch_status >"$FIXTURE_ROOT/current-status.json"
    CURRENT_FETCH=$?
else
    CURRENT_POST=1
    CURRENT_FETCH=1
fi
OK=1
if [ "$CURRENT_POST" -eq 0 ] \
    && [ "$CURRENT_FETCH" -eq 0 ] \
    && jq -e '
        .instances[]
        | select(.key == "fixture/current@one")
        | .artifacts["plan.json"].stale == false
          and .artifacts["state/gate.json"].stale == false
    ' "$FIXTURE_ROOT/current-status.json" >/dev/null 2>&1; then
    OK=0
fi
report_case "current plan and gate artifacts are not stale" "$OK" \
    "post=$CURRENT_POST fetch=$CURRENT_FETCH"

# 3. The served page includes the muted stale row and previous-run badge.
if [ "$READY_STATUS" -eq 0 ]; then
    curl -fsS --max-time 2 \
        "http://127.0.0.1:$SINK_PORT/" >"$FIXTURE_ROOT/page.html"
    PAGE_FETCH=$?
else
    PAGE_FETCH=1
fi
OK=1
if [ "$PAGE_FETCH" -eq 0 ] \
    && grep -q '^[.]stale { color:var(--faint);' "$FIXTURE_ROOT/page.html" \
    && grep -q 'class="badge-stale"' "$FIXTURE_ROOT/page.html" \
    && grep -q 'previous run' "$FIXTURE_ROOT/page.html"; then
    OK=0
fi
report_case "dashboard serves the stale renderer and previous-run badge" "$OK" \
    "fetch=$PAGE_FETCH"

# 4. A missing gate and an entirely empty run directory both yield normal
# status entries; the present ungated artifact fails conservatively.
ABSENT_GATE_DIR="$RUN_ROOT/absent-gate"
EMPTY_DIR="$RUN_ROOT/empty"
mkdir -p "$ABSENT_GATE_DIR/state" "$EMPTY_DIR"
jq -n '{correlation_id: "leftover-correlation"}' \
    >"$ABSENT_GATE_DIR/state/run.json"
touch -d "@3000" "$ABSENT_GATE_DIR/state/run.json"
if [ "$READY_STATUS" -eq 0 ]; then
    register_instance "fixture/absent-gate@one" "$ABSENT_GATE_DIR"
    ABSENT_POST=$?
    register_instance "fixture/empty@one" "$EMPTY_DIR"
    EMPTY_POST=$?
    fetch_status >"$FIXTURE_ROOT/empty-status.json"
    EMPTY_FETCH=$?
else
    ABSENT_POST=1
    EMPTY_POST=1
    EMPTY_FETCH=1
fi
OK=1
if [ "$ABSENT_POST" -eq 0 ] \
    && [ "$EMPTY_POST" -eq 0 ] \
    && [ "$EMPTY_FETCH" -eq 0 ] \
    && jq -e '
        ([.instances[] | select(.key == "fixture/absent-gate@one")]
          | length == 1)
        and ([.instances[] | select(.key == "fixture/empty@one")]
          | length == 1)
        and (.instances[]
          | select(.key == "fixture/absent-gate@one")
          | .artifacts["state/run.json"].stale == true)
        and (.instances[]
          | select(.key == "fixture/empty@one")
          | [.artifacts[] | .exists] | any | not)
    ' "$FIXTURE_ROOT/empty-status.json" >/dev/null 2>&1; then
    OK=0
fi
report_case "missing phase clocks and empty run directories stay well formed" "$OK" \
    "absent-post=$ABSENT_POST empty-post=$EMPTY_POST fetch=$EMPTY_FETCH"

# 5. A rerun under a harness that does not archive keeps the previous launch's
# artifacts AND its stamps, so each artifact still leads its own producing
# stamp. The launch boundary is what makes them stale — stamps included.
RETAINED_DIR="$RUN_ROOT/retained"
mkdir -p "$RETAINED_DIR/state" "$RETAINED_DIR/results"
jq -n '{feature: "prior-plan", stages: []}' >"$RETAINED_DIR/plan.json"
jq -n '{verdict: "RED", tip: "prior"}' >"$RETAINED_DIR/state/gate.json"
printf '%s\n' "PROMOTION_READY" >"$RETAINED_DIR/results/CR.md"
jq -n '{issue: 1, phase: "pipeline", started: "1970-01-01T01:23:20Z"}' \
    >"$RETAINED_DIR/launch.json"
: >"$RETAINED_DIR/state/pipeline-plan.stamp"
: >"$RETAINED_DIR/state/pipeline-implement.stamp"
: >"$RETAINED_DIR/state/pipeline-review.stamp"
touch -d "@4000" \
    "$RETAINED_DIR/state/pipeline-plan.stamp" \
    "$RETAINED_DIR/state/pipeline-implement.stamp" \
    "$RETAINED_DIR/state/pipeline-review.stamp"
touch -d "@4100" "$RETAINED_DIR/plan.json" "$RETAINED_DIR/state/gate.json" \
    "$RETAINED_DIR/results/CR.md"
touch -d "@5000" "$RETAINED_DIR/launch.json"
if [ "$READY_STATUS" -eq 0 ]; then
    register_instance "fixture/retained@one" "$RETAINED_DIR"
    RETAINED_POST=$?
    fetch_status >"$FIXTURE_ROOT/retained-status.json"
    RETAINED_FETCH=$?
else
    RETAINED_POST=1
    RETAINED_FETCH=1
fi
OK=1
if [ "$RETAINED_POST" -eq 0 ] \
    && [ "$RETAINED_FETCH" -eq 0 ] \
    && jq -e '
        .instances[]
        | select(.key == "fixture/retained@one")
        | .artifacts as $a
        | $a["plan.json"].stale == true
          and $a["state/gate.json"].stale == true
          and $a["results/CR.md"].stale == true
          and ([
            $a["state/pipeline-plan.stamp"],
            $a["state/pipeline-implement.stamp"],
            $a["state/pipeline-review.stamp"]
          ] | all(.stale == true))
    ' "$FIXTURE_ROOT/retained-status.json" >/dev/null 2>&1; then
    OK=0
fi
report_case "retained prior stamps do not make prior artifacts current" "$OK" \
    "post=$RETAINED_POST fetch=$RETAINED_FETCH"

# 6. A bin/run.sh --phase launch writes no pipeline stamp: its own output is
# current and only what predates the launch is stale. The launch record's
# mtime is deliberately later than the instant it records, proving the
# recorded start — not the rewritten file — sets the boundary.
PHASE_ONLY_DIR="$RUN_ROOT/phase-only"
mkdir -p "$PHASE_ONLY_DIR/state" "$PHASE_ONLY_DIR/results"
jq -n '{feature: "prior-plan", stages: []}' >"$PHASE_ONLY_DIR/plan.json"
jq -n '{verdict: "GREEN", tip: "fresh"}' >"$PHASE_ONLY_DIR/state/gate.json"
printf '%s\n' "PROMOTION_READY" >"$PHASE_ONLY_DIR/results/CR.md"
jq -n '{issue: 1, phase: "review", started: "1970-01-01T01:23:20Z"}' \
    >"$PHASE_ONLY_DIR/launch.json"
touch -d "@1000" "$PHASE_ONLY_DIR/plan.json"
touch -d "@5100" "$PHASE_ONLY_DIR/state/gate.json" "$PHASE_ONLY_DIR/results/CR.md"
touch -d "@9000" "$PHASE_ONLY_DIR/launch.json"
if [ "$READY_STATUS" -eq 0 ]; then
    register_instance "fixture/phase-only@one" "$PHASE_ONLY_DIR"
    PHASE_ONLY_POST=$?
    fetch_status >"$FIXTURE_ROOT/phase-only-status.json"
    PHASE_ONLY_FETCH=$?
else
    PHASE_ONLY_POST=1
    PHASE_ONLY_FETCH=1
fi
OK=1
if [ "$PHASE_ONLY_POST" -eq 0 ] \
    && [ "$PHASE_ONLY_FETCH" -eq 0 ] \
    && jq -e '
        .instances[]
        | select(.key == "fixture/phase-only@one")
        | .artifacts as $a
        | $a["state/gate.json"].stale == false
          and $a["results/CR.md"].stale == false
          and $a["plan.json"].stale == true
    ' "$FIXTURE_ROOT/phase-only-status.json" >/dev/null 2>&1; then
    OK=0
fi
report_case "phase-only launches keep their stampless output current" "$OK" \
    "post=$PHASE_ONLY_POST fetch=$PHASE_ONLY_FETCH"

stop_service

printf '%d/%d cases passed\n' "$TESTS_PASSED" "$TESTS_RUN"
[ "$TESTS_PASSED" -eq "$TESTS_RUN" ]
