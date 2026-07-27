#!/usr/bin/env bash
# Self-contained test runner for clearing the dashboard's latched HALTED and
# COMPLETE verdicts when a run re-enters through either pipeline or direct
# phase launch events. Fixtures live under mktemp -d and the sink uses an
# unused high port. Prints PASS/FAIL per case and exits non-zero on failure.
#
# Deliberately no -e: cases capture subject statuses that may be non-zero.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SINK_SUBJECT="$ROOT/bin/sink-serve.sh"
FIXTURE_ROOT="$(mktemp -d)"
RUN_DIR="$FIXTURE_ROOT/run"
SINK_STATE="$FIXTURE_ROOT/sink/instances.json"
SINK_STDOUT="$FIXTURE_ROOT/sink.stdout"
SINK_STDERR="$FIXTURE_ROOT/sink.stderr"
PAGE_FILE="$FIXTURE_ROOT/page.html"
STATUS_FILE="$FIXTURE_ROOT/status.json"
HARNESS_FILE="$FIXTURE_ROOT/reentry-harness.js"
HARNESS_OUTPUT="$FIXTURE_ROOT/reentry-harness.out"
KEY="fixture/issue-31@reentry"
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

mkdir -p "$RUN_DIR/state"
jq -n '{issue: 31, phase: "review", started: "1970-01-01T01:23:20Z"}' \
    >"$RUN_DIR/launch.json"
jq -n '{feature: "issue-31", stages: []}' >"$RUN_DIR/plan.json"
jq -n '{verdict: "GREEN", tip: "deadbee"}' >"$RUN_DIR/state/gate.json"
: >"$RUN_DIR/state/pipeline-plan.stamp"
: >"$RUN_DIR/state/pipeline-implement.stamp"
: >"$RUN_DIR/state/pipeline-review.stamp"
touch -d "@5000" "$RUN_DIR/launch.json"
touch -d "@8000" \
    "$RUN_DIR/state/pipeline-plan.stamp" \
    "$RUN_DIR/state/pipeline-implement.stamp"
touch -d "@9000" \
    "$RUN_DIR/plan.json" \
    "$RUN_DIR/state/gate.json" \
    "$RUN_DIR/state/pipeline-review.stamp"

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
    && grep -Fq 'delete haltInfo[' "$PAGE_FILE" \
    && grep -Fq 'delete completeInfo[' "$PAGE_FILE" \
    && grep -Fq 'system.started.' "$PAGE_FILE" \
    && grep -Fq 'function applyRunState' "$PAGE_FILE"; then
    OK=0
fi
report_case "dashboard serves the terminal re-entry reset" "$OK" \
    "ready=$READY_STATUS fetch=$PAGE_STATUS"

HARNESS_CASES=(
    "halted-verdict"
    "phase-request-reentry"
    "direct-phase-reentry"
    "complete-reentry"
    "promote-ordering"
)
CASE_LABELS=(
    "halted review is pinned in Attention"
    "phase.request clears a halted terminal latch"
    "system.started clears a direct-phase halted latch"
    "re-entry clears COMPLETE and releases promote state"
    "promote phase.request remains active after reset"
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
    register_instance "$KEY" "$RUN_DIR"
    REGISTER_STATUS=$?
    fetch_status >"$STATUS_FILE"
    STATUS_FETCH=$?
else
    REGISTER_STATUS=1
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
const KEY = "fixture/issue-31@reentry";
const run = status.instances.find(instance => instance.key === KEY);
if (!run) {
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

function currentVerdict() {
  return verdictFor(run, derive(run));
}

applyRunState(
  "pipeline.halted",
  KEY,
  { phase: "review", reason: "operator halt" },
  "pipeline"
);
let verdict = currentVerdict();
check(
  "halted-verdict",
  verdict.label.startsWith("HALTED AT REVIEW") &&
    groupFor(run, derive(run), verdict) === 0,
  "expected HALTED AT REVIEW in Attention, got " + verdict.label
);

applyRunState("phase.request", KEY, { phase: "review" }, "pipeline");
verdict = currentVerdict();
check(
  "phase-request-reentry",
  verdict.label === "REVIEW IN PROGRESS" &&
    groupFor(run, derive(run), verdict) !== 0,
  "expected active review outside Attention, got " + verdict.label
);

applyRunState(
  "pipeline.halted",
  KEY,
  { phase: "review", reason: "operator halt" },
  "pipeline"
);
applyRunState(
  "system.started.review-seed",
  KEY,
  { name: "review-seed" },
  "review"
);
verdict = currentVerdict();
check(
  "direct-phase-reentry",
  verdict.label === "REVIEW IN PROGRESS",
  "expected direct phase launch to restore review, got " + verdict.label
);

applyRunState(
  "pipeline.complete",
  KEY,
  { parked: false, reason: "merged" },
  "pipeline"
);
let states = derive(run);
verdict = verdictFor(run, states);
const completed = verdict.label === "COMPLETE" && states.promote === "done";
applyRunState("phase.request", KEY, { phase: "review" }, "pipeline");
states = derive(run);
verdict = verdictFor(run, states);
check(
  "complete-reentry",
  completed && verdict.label === "REVIEW IN PROGRESS" &&
    states.promote === "pending",
  "expected COMPLETE/done then REVIEW IN PROGRESS/pending, got " +
    verdict.label + "/" + states.promote
);

applyRunState("phase.request", KEY, { phase: "promote" }, "pipeline");
check(
  "promote-ordering",
  derive(run).promote === "active",
  "expected promote phase to remain active"
);
JSEOF

if [ "$REGISTER_STATUS" -eq 0 ] \
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
        "register=$REGISTER_STATUS fetch=$STATUS_FETCH node=$HARNESS_STATUS"
done

printf '%d/%d cases passed (%d skipped)\n' \
    "$TESTS_PASSED" "$TESTS_RUN" "$TESTS_SKIPPED"
[ "$TESTS_PASSED" -eq "$TESTS_RUN" ]
