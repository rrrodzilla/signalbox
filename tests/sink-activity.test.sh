#!/usr/bin/env bash
# Self-contained test runner for the dashboard's live phase-activity state.
# Fixtures live under mktemp -d and the sink uses an unused high port. Prints
# PASS/FAIL per case and exits non-zero on failure.
#
# Deliberately no -e: cases capture subject statuses that may be non-zero.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SINK_SUBJECT="$ROOT/bin/sink-serve.sh"
FIXTURE_ROOT="$(mktemp -d)"
RUN_A="$FIXTURE_ROOT/run-a"
RUN_B="$FIXTURE_ROOT/run-b"
RUN_C="$FIXTURE_ROOT/run-c"
SINK_STATE="$FIXTURE_ROOT/sink/instances.json"
SINK_STDOUT="$FIXTURE_ROOT/sink.stdout"
SINK_STDERR="$FIXTURE_ROOT/sink.stderr"
PAGE_FILE="$FIXTURE_ROOT/page.html"
STATUS_FILE="$FIXTURE_ROOT/status.json"
HARNESS_FILE="$FIXTURE_ROOT/activity-harness.js"
HARNESS_OUTPUT="$FIXTURE_ROOT/activity-harness.out"
KEY_A="fixture/issue-34@relaunch"
KEY_B="fixture/issue-34@terminal-artifact"
KEY_C="fixture/issue-34@escalated"
SERVICE_PID=""
SINK_PORT=""
PORT_STATUS=0
TESTS_RUN=0
TESTS_PASSED=0
TESTS_SKIPPED=0

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
    local INSTANCE_KEY="$1" INSTANCE_RUN_DIR="$2"
    jq -n \
        --arg key "$INSTANCE_KEY" \
        --arg run_dir "$INSTANCE_RUN_DIR" \
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

mkdir -p "$RUN_A/state" "$RUN_A/results" "$RUN_B/state" "$RUN_C/state"

# Run A models a direct review relaunch over artifacts from the prior launch.
jq -n '{issue: 34, phase: "review", started: "1970-01-01T02:46:40Z"}' \
    >"$RUN_A/launch.json"
jq -n '{feature: "issue-34", stages: []}' >"$RUN_A/plan.json"
jq -n '{verdict: "RED", tip: "oldbeef"}' >"$RUN_A/state/gate.json"
printf '%s\n' 'PROMOTION_READY' >"$RUN_A/results/CR.md"
: >"$RUN_A/state/pipeline-plan.stamp"
: >"$RUN_A/state/pipeline-review.stamp"
touch -d "@10000" "$RUN_A/launch.json"
touch -d "@9000" \
    "$RUN_A/plan.json" \
    "$RUN_A/results/CR.md" \
    "$RUN_A/state/gate.json" \
    "$RUN_A/state/pipeline-plan.stamp" \
    "$RUN_A/state/pipeline-review.stamp"

# Run B has current terminal artifacts but no pipeline boundary stamps.
jq -n '{issue: 34, phase: "implement", started: "1970-01-01T02:46:40Z"}' \
    >"$RUN_B/launch.json"
jq -n '{feature: "issue-34", stages: []}' >"$RUN_B/plan.json"
jq -n '{verdict: "GREEN", tip: "deadbee"}' >"$RUN_B/state/gate.json"
touch -d "@10000" "$RUN_B/launch.json"
touch -d "@11000" "$RUN_B/plan.json" "$RUN_B/state/gate.json"

# Run C proves the artifact escalation overlay remains authoritative.
jq -n '{issue: 34, phase: "review", started: "1970-01-01T02:46:40Z"}' \
    >"$RUN_C/launch.json"
jq -n '{escalated_phase: "review", reason: "round 4 rejected"}' \
    >"$RUN_C/state/escalated.json"
touch -d "@10000" "$RUN_C/launch.json"
touch -d "@11000" "$RUN_C/state/escalated.json"

SINK_PORT="$(pick_port 2>"$FIXTURE_ROOT/port.stderr")"
PORT_STATUS=$?
if [ "$PORT_STATUS" -ne 0 ] || [ -z "$SINK_PORT" ]; then
    # Never fall through to the machine service's default port.
    SINK_PORT=65534
fi
start_service
READY_STATUS=$?

# This source-level case remains useful on machines where node is unavailable.
if [ "$READY_STATUS" -eq 0 ]; then
    curl -fsS --max-time 2 \
        "http://127.0.0.1:$SINK_PORT/" >"$PAGE_FILE"
    PAGE_STATUS=$?
else
    PAGE_STATUS=1
fi
OK=1
if [ "$PAGE_STATUS" -eq 0 ] \
    && grep -Fq 'phaseActivity' "$PAGE_FILE" \
    && grep -Fq 'function markPhaseActive' "$PAGE_FILE" \
    && grep -Fq 'function applyRunState' "$PAGE_FILE"; then
    OK=0
fi
report_case "dashboard serves live phase activity machinery" "$OK" \
    "ready=$READY_STATUS fetch=$PAGE_STATUS"

HARNESS_CASES=(
    "waiting-baseline"
    "review-event-activates"
    "phase-done-clears"
    "pipeline-request-resets"
    "implement-event-activates"
    "halt-clears-activity"
    "activity-never-shadows-artifact"
    "escalation-still-wins"
    "stopped-event-is-not-progress"
)
CASE_LABELS=(
    "stale relaunch begins in WAITING"
    "review event activates a relaunched review"
    "phase.done clears live review activity"
    "phase.request replaces the previous phase activity"
    "implement event activates before its gate exists"
    "pipeline halt clears all live phase activity"
    "live activity never shadows a terminal artifact"
    "artifact escalation still wins over live activity"
    "system.stopped is not treated as progress"
)

if ! command -v node >/dev/null 2>&1; then
    for NAME in "${CASE_LABELS[@]}"; do
        printf 'SKIP %s — node is unavailable; dashboard state machine was not executed\n' \
            "$NAME"
        TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
    done
    printf '%d/%d cases passed (%d skipped)\n' \
        "$TESTS_PASSED" "$TESTS_RUN" "$TESTS_SKIPPED"
    [ "$TESTS_PASSED" -eq "$TESTS_RUN" ]
    exit
fi

if [ "$READY_STATUS" -eq 0 ]; then
    register_instance "$KEY_A" "$RUN_A"
    REGISTER_A_STATUS=$?
    register_instance "$KEY_B" "$RUN_B"
    REGISTER_B_STATUS=$?
    register_instance "$KEY_C" "$RUN_C"
    REGISTER_C_STATUS=$?
    fetch_status >"$STATUS_FILE"
    STATUS_FETCH=$?
else
    REGISTER_A_STATUS=1
    REGISTER_B_STATUS=1
    REGISTER_C_STATUS=1
    STATUS_FETCH=1
fi

cat >"$HARNESS_FILE" <<'JSEOF'
"use strict";

const fs = require("fs");
const vm = require("vm");

const page = fs.readFileSync(process.argv[2], "utf8");
const scriptStart = page.indexOf("<script>");
const pollStart = page.lastIndexOf("\npoll();");
if (scriptStart < 0 || pollStart < 0 || pollStart <= scriptStart) {
  console.log("not ok harness-load — dashboard script boundaries were not found");
  process.exit(1);
}

const context = {
  document: { getElementById: () => ({}) },
  setTimeout,
  console
};
vm.createContext(context);
try {
  const source = page.slice(scriptStart + "<script>".length, pollStart) +
    "\nthis.dashboard = { applyRunState, derive, verdictFor, groupFor };";
  vm.runInContext(source, context);
} catch (error) {
  console.log("not ok harness-load — " + error.message);
  process.exit(1);
}

const { applyRunState, derive, verdictFor, groupFor } = context.dashboard;
const status = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));
const KEY_A = "fixture/issue-34@relaunch";
const KEY_B = "fixture/issue-34@terminal-artifact";
const KEY_C = "fixture/issue-34@escalated";
const runA = status.instances.find(instance => instance.key === KEY_A);
const runB = status.instances.find(instance => instance.key === KEY_B);
const runC = status.instances.find(instance => instance.key === KEY_C);
if (!runA || !runB || !runC) {
  console.log("not ok harness-load — fixture instance is missing from /status");
  process.exit(1);
}

function check(name, condition, detail) {
  if (!condition) {
    console.log("not ok " + name + " — " + detail);
    process.exit(1);
  }
  console.log("ok " + name);
}

function verdict(run) {
  return verdictFor(run, derive(run));
}

check(
  "waiting-baseline",
  verdict(runA).label === "WAITING",
  "expected WAITING, got " + verdict(runA).label
);

applyRunState(
  "review.raw",
  KEY_A,
  { round: 2, verdict: "REQUEST_CHANGES" },
  "review"
);
check(
  "review-event-activates",
  derive(runA).review === "active" &&
    verdict(runA).label === "REVIEW IN PROGRESS",
  "expected active/REVIEW IN PROGRESS, got " +
    derive(runA).review + "/" + verdict(runA).label
);

applyRunState(
  "phase.done",
  KEY_A,
  { phase: "review", outcome: "ARTIFACT" },
  "pipeline"
);
check(
  "phase-done-clears",
  derive(runA).review === "pending" &&
    verdict(runA).label === "WAITING",
  "expected pending/WAITING, got " +
    derive(runA).review + "/" + verdict(runA).label
);

applyRunState("review.raw", KEY_A, { round: 2 }, "review");
applyRunState("phase.request", KEY_A, { phase: "implement" }, "pipeline");
check(
  "pipeline-request-resets",
  derive(runA).review === "pending" &&
    derive(runA).implement === "active",
  "expected review pending and implement active"
);

applyRunState(
  "stage.item",
  KEY_A,
  { id: "s1", shards: [] },
  "implement"
);
check(
  "implement-event-activates",
  derive(runA).implement === "active",
  "expected implement active, got " + derive(runA).implement
);

applyRunState(
  "pipeline.halted",
  KEY_A,
  { phase: "review", reason: "operator halt" },
  "pipeline"
);
let states = derive(runA);
let currentVerdict = verdictFor(runA, states);
check(
  "halt-clears-activity",
  currentVerdict.label.startsWith("HALTED AT REVIEW") &&
    groupFor(runA, states, currentVerdict) === 0 &&
    states.implement === "pending" &&
    states.review === "pending",
  "expected halted Attention verdict with pending implement/review"
);

applyRunState(
  "shard.built",
  KEY_B,
  { stage: "s1", pending: [], done: [] },
  "implement"
);
check(
  "activity-never-shadows-artifact",
  derive(runB).implement === "done",
  "expected current GREEN gate to remain done"
);

applyRunState(
  "review.raw",
  KEY_C,
  { round: 4, verdict: "REQUEST_CHANGES" },
  "review"
);
check(
  "escalation-still-wins",
  derive(runC).review === "escalated" &&
    verdict(runC).label.startsWith("ESCALATED IN REVIEW"),
  "expected escalated artifact verdict to win"
);

// Run A's pipeline terminal cleared every activity mark above. A phase.done
// keeps this stopped-only probe isolated if terminal handling changes later.
applyRunState("phase.done", KEY_A, { phase: "review" }, "pipeline");
applyRunState(
  "system.stopped.review-seed",
  KEY_A,
  { name: "review-seed" },
  "review"
);
check(
  "stopped-event-is-not-progress",
  derive(runA).review !== "active",
  "expected system.stopped.review-seed not to activate review"
);
JSEOF

if [ "$REGISTER_A_STATUS" -eq 0 ] \
    && [ "$REGISTER_B_STATUS" -eq 0 ] \
    && [ "$REGISTER_C_STATUS" -eq 0 ] \
    && [ "$STATUS_FETCH" -eq 0 ] \
    && [ "$PAGE_STATUS" -eq 0 ]; then
    node "$HARNESS_FILE" "$PAGE_FILE" "$STATUS_FILE" >"$HARNESS_OUTPUT" 2>&1
    HARNESS_STATUS=$?
else
    HARNESS_STATUS=1
    : >"$HARNESS_OUTPUT"
fi

for INDEX in "${!HARNESS_CASES[@]}"; do
    CASE_NAME="${HARNESS_CASES[$INDEX]}"
    OK=1
    if grep -Fxq "ok $CASE_NAME" "$HARNESS_OUTPUT"; then
        OK=0
    fi
    report_case "${CASE_LABELS[$INDEX]}" "$OK" \
        "register=$REGISTER_A_STATUS/$REGISTER_B_STATUS/$REGISTER_C_STATUS fetch=$STATUS_FETCH node=$HARNESS_STATUS"
done

printf '%d/%d cases passed (%d skipped)\n' \
    "$TESTS_PASSED" "$TESTS_RUN" "$TESTS_SKIPPED"
[ "$TESTS_PASSED" -eq "$TESTS_RUN" ]
