#!/usr/bin/env bash
# Self-contained test runner for bin/run.sh standalone phase supervision and
# promotion recovery. No framework; fixtures live under mktemp -d, network
# forwarding is stubbed, and cleanup targets only launcher PIDs created here.
# Prints PASS/FAIL/SKIP per case and exits non-zero when any case fails.
#
# Deliberately no -e: cases capture subject statuses that may be non-zero.
# Fixture creation and setup are checked explicitly with fatal, so a broken
# fixture can never pass as an empty success.
set -uo pipefail

fatal() {
    printf 'FATAL %s\n' "$1" >&2
    exit 1
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" \
    || fatal 'the repository root could not be resolved'
FIX="$(mktemp -d)" || fatal 'a fixture directory could not be created'
[ -n "$FIX" ] && [ -d "$FIX" ] \
    || fatal 'mktemp -d produced no usable fixture directory'
HARNESS="$FIX/harness"
SUBJECT="$HARNESS/bin/run.sh"
STUB_BIN="$FIX/stub-bin"
LEASE_REGISTRY="$FIX/leases.json"
CHILD_PIDS=()
TESTS_RUN=0
TESTS_PASSED=0
TESTS_SKIPPED=0
SUBJECT_STATUS=0
SUBJECT_PID=""
OUT=""
ERR=""
PROMOTE_MARKER=""
REAPER_PID_FILE=""

cleanup() {
    local PID_VALUE

    for PID_VALUE in "${CHILD_PIDS[@]}"; do
        [ -n "$PID_VALUE" ] || continue
        kill -TERM "$PID_VALUE" 2>/dev/null || true
        wait "$PID_VALUE" 2>/dev/null || true
    done
    rm -rf -- "$FIX"
}
trap cleanup EXIT

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

skip_all() {
    local REASON="$1" NAME
    local -a NAMES=(
        "plan artifact records complete"
        "review artifact records correlation"
        "review pending records parked"
        "park record holds detached engine"
        "park launcher leaves engine alive"
        "park launcher preserves engine pid file"
        "park terminal reason names approve URL"
        "park reaper exits after engine"
        "dead parked engine closes approval window"
        "live park refuses relaunch"
        "review docs-sync grace expires complete"
        "implement red gate records halted"
        "escalation records halted"
        "dead engine records halted"
        "promote refuses missing CR"
        "promote refuses missing review stamp"
        "promote artifact records complete payload"
        "promote NO_GO records halted"
        "promote executor failure records halted"
        "promote garbage records halted"
        "promote preserves launch start"
        "pipeline SIGTERM records no launcher terminal"
        "parked review ignores stale CR correlation"
        "promote refuses while another mode owns the run"
    )

    for NAME in "${NAMES[@]}"; do
        printf 'SKIP %s — %s\n' "$NAME" "$REASON"
        TESTS_RUN=$((TESTS_RUN + 1))
        TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
    done
    printf '%d/%d cases passed (%d skipped)\n' \
        "$TESTS_PASSED" "$TESTS_RUN" "$TESTS_SKIPPED"
    exit 0
}

run_subject() {
    local ISSUE_VALUE="$1"
    local PHASE_VALUE="$2"
    local ENGINE_MODE="${3:-idle}"
    local PROMOTE_MODE="${4:-artifact}"
    local DOCS_GRACE="${5:-}"
    local PARK_GRACE="${6:-4}"
    local CASE_DIR="$FIX/case-$ISSUE_VALUE-$PHASE_VALUE-$ENGINE_MODE-$PROMOTE_MODE"
    local PID_INDEX RUN_PATH HELD_PID REAPER_PID_VALUE

    mkdir -p "$CASE_DIR" || fatal "case directory could not be created: $CASE_DIR"
    OUT="$CASE_DIR/stdout"
    ERR="$CASE_DIR/stderr"
    PROMOTE_MARKER="$CASE_DIR/promote-invoked.json"
    REAPER_PID_FILE="$CASE_DIR/reaper.pid"

    PATH="$STUB_BIN:$PATH" \
        SIGNALBOX_LEASE_REGISTRY="$LEASE_REGISTRY" \
        SIGNALBOX_TEST_HARNESS="$HARNESS" \
        SIGNALBOX_TEST_MODE="$ENGINE_MODE" \
        SIGNALBOX_PROMOTE_MODE="$PROMOTE_MODE" \
        SIGNALBOX_PROMOTE_MARKER="$PROMOTE_MARKER" \
        SIGNALBOX_DOCS_SYNC_GRACE="$DOCS_GRACE" \
        SIGNALBOX_PARK_GRACE="$PARK_GRACE" \
        SIGNALBOX_REAPER_PID_FILE="$REAPER_PID_FILE" \
        "$SUBJECT" "$ISSUE_VALUE" --phase "$PHASE_VALUE" \
        >"$OUT" 2>"$ERR" &
    SUBJECT_PID=$!
    CHILD_PIDS+=("$SUBJECT_PID")
    PID_INDEX=$((${#CHILD_PIDS[@]} - 1))
    wait "$SUBJECT_PID" 2>/dev/null
    SUBJECT_STATUS=$?
    CHILD_PIDS[$PID_INDEX]=""

    RUN_PATH="$HARNESS/runs/issue-$ISSUE_VALUE"
    if jq -e '.held == true' "$RUN_PATH/state/park.json" >/dev/null 2>&1; then
        HELD_PID="$(jq -r '.pid // empty' "$RUN_PATH/state/park.json" 2>/dev/null)"
        [ -n "$HELD_PID" ] && CHILD_PIDS+=("$HELD_PID")
        await_file "$REAPER_PID_FILE"
        REAPER_PID_VALUE="$(head -n 1 "$REAPER_PID_FILE" 2>/dev/null || true)"
        [ -n "$REAPER_PID_VALUE" ] && CHILD_PIDS+=("$REAPER_PID_VALUE")
    fi
}

await_file() {
    local FILE_VALUE="$1" ATTEMPT

    for ATTEMPT in {1..100}; do
        [ -s "$FILE_VALUE" ] && return 0
        sleep 0.05
    done
    return 1
}

await_process_exit() {
    local PID_VALUE="$1" ATTEMPT

    for ATTEMPT in {1..200}; do
        kill -0 "$PID_VALUE" 2>/dev/null || return 0
        sleep 0.05
    done
    return 1
}

write_review_evidence() {
    local ISSUE_VALUE="$1" CORRELATION_VALUE="$2"
    local RUN_DIR="$HARNESS/runs/issue-$ISSUE_VALUE"

    mkdir -p "$RUN_DIR/state" "$RUN_DIR/results" \
        || fatal "review evidence directories could not be created for issue $ISSUE_VALUE"
    printf '# CR\ncorrelation_id: %s\nPROMOTION_READY\n' "$CORRELATION_VALUE" \
        >"$RUN_DIR/results/CR.md" \
        || fatal "CR.md could not be written for issue $ISSUE_VALUE"
    touch "$RUN_DIR/state/pipeline-review.stamp" \
        || fatal "review stamp could not be written for issue $ISSUE_VALUE"
}

await_launch() {
    local LAUNCH_FILE="$1" PID_VALUE="$2" ATTEMPT

    for ATTEMPT in {1..100}; do
        if [ -f "$LAUNCH_FILE" ] \
            && jq -e '.pid | type == "number" and . > 0' \
                "$LAUNCH_FILE" >/dev/null 2>&1; then
            return 0
        fi
        if ! kill -0 "$PID_VALUE" 2>/dev/null; then
            return 1
        fi
        sleep 0.05
    done
    return 1
}

for REQUIRED in jq flock; do
    if ! command -v "$REQUIRED" >/dev/null 2>&1; then
        skip_all "$REQUIRED is unavailable"
    fi
done

mkdir -p "$HARNESS" "$STUB_BIN" "$HARNESS/templates" \
    "$HARNESS/.claude/docs" \
    || fatal 'the fixture harness directories could not be created'
cp -r "$ROOT/bin" "$HARNESS/" \
    || fatal 'bin/ could not be copied into the fixture harness'
mv "$HARNESS/bin/engine-reaper.sh" "$HARNESS/bin/engine-reaper-real.sh" \
    || fatal 'the fixture reaper could not be wrapped'
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'printf '"'"'%s\n'"'"' "$$" >"$SIGNALBOX_REAPER_PID_FILE"' \
    'exec "$(dirname "${BASH_SOURCE[0]}")/engine-reaper-real.sh" "$@"' \
    >"$HARNESS/bin/engine-reaper.sh" \
    || fatal 'the fixture reaper wrapper could not be written'
chmod +x "$HARNESS/bin/engine-reaper.sh" \
    || fatal 'the fixture reaper wrapper could not be made executable'
[ -x "$SUBJECT" ] || fatal "the fixture subject $SUBJECT is missing"
[ -x "$HARNESS/bin/ports.sh" ] \
    || fatal 'the fixture harness is missing bin/ports.sh'
[ -x "$HARNESS/bin/terminal-record.sh" ] \
    || fatal 'the fixture harness is missing bin/terminal-record.sh'
printf '# fixture architecture\n' >"$HARNESS/.claude/docs/ARCHI.md" \
    || fatal 'the fixture ARCHI.md could not be written'

for TEMPLATE in pipeline plan implement emergent init; do
    printf 'name = "fixture__SIGNALBOX_RUN_SUFFIX__"\napproval = __SIGNALBOX_PORT_APPROVAL__\n' \
        >"$HARNESS/templates/$TEMPLATE.toml" \
        || fatal "the fixture template $TEMPLATE.toml could not be written"
done

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'RUN_DIR="$SIGNALBOX_TEST_HARNESS/runs/$SIGNALBOX_RUN_SLUG"' \
    'ENGINE_LIFETIME=120' \
    'mkdir -p "$RUN_DIR/state" "$RUN_DIR/results"' \
    'case "${SIGNALBOX_TEST_MODE:-idle}" in' \
    '    plan)' \
    '        jq -n --arg correlation_id plan-correlation '"'"'{correlation_id: $correlation_id}'"'"' >"$RUN_DIR/plan.json"' \
    '        ;;' \
    '    review-artifact)' \
    '        printf '"'"'# CR\ncorrelation_id: review-correlation\nPROMOTION_READY\n'"'"' >"$RUN_DIR/results/CR.md"' \
    '        jq -n --arg status OK --arg correlation_id review-correlation '"'"'{status: $status, correlation_id: $correlation_id}'"'"' >"$RUN_DIR/state/docs-sync.json"' \
    '        ;;' \
    '    review-parked)' \
    '        jq -n '"'"'{decision: "human"}'"'"' >"$RUN_DIR/state/pending.json"' \
    '        ENGINE_LIFETIME=3' \
    '        ;;' \
    '    review-parked-cid)' \
    '        jq -n --arg correlation_id pending-correlation '"'"'{decision: "human", correlation_id: $correlation_id}'"'"' >"$RUN_DIR/state/pending.json"' \
    '        ENGINE_LIFETIME=3' \
    '        ;;' \
    '    review-parked-dead)' \
    '        jq -n '"'"'{decision: "human"}'"'"' >"$RUN_DIR/state/pending.json"' \
    '        exit 0' \
    '        ;;' \
    '    review-no-sync)' \
    '        printf '"'"'# CR\ncorrelation_id: grace-correlation\nPROMOTION_READY\n'"'"' >"$RUN_DIR/results/CR.md"' \
    '        ;;' \
    '    gate-red)' \
    '        jq -n '"'"'{verdict: "RED"}'"'"' >"$RUN_DIR/state/gate.json"' \
    '        ;;' \
    '    escalated)' \
    '        jq -n '"'"'{reason: "fixture escalation"}'"'"' >"$RUN_DIR/state/escalated.json"' \
    '        ;;' \
    '    die)' \
    '        exit 7' \
    '        ;;' \
    '    idle)' \
    '        ;;' \
    '    *)' \
    '        exit 64' \
    '        ;;' \
    'esac' \
    'exec sleep "$ENGINE_LIFETIME"' >"$STUB_BIN/emergent" \
    || fatal 'the emergent stub could not be written'
chmod +x "$STUB_BIN/emergent" \
    || fatal 'the emergent stub could not be made executable'

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'cat >/dev/null' >"$HARNESS/bin/sse-forward.sh" \
    || fatal 'the SSE forwarder stub could not be written'
chmod +x "$HARNESS/bin/sse-forward.sh" \
    || fatal 'the SSE forwarder stub could not be made executable'

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'PAYLOAD="$(cat)"' \
    'printf '"'"'%s\n'"'"' "$PAYLOAD" >"$SIGNALBOX_PROMOTE_MARKER"' \
    'case "${SIGNALBOX_PROMOTE_MODE:-artifact}" in' \
    '    artifact)' \
    '        jq -c '"'"'. + {outcome: "ARTIFACT", log: "fixture-promote.log"}'"'"' <<<"$PAYLOAD"' \
    '        ;;' \
    '    no-go)' \
    '        jq -c '"'"'. + {outcome: "NO_GO", log: "fixture-promote.log"}'"'"' <<<"$PAYLOAD"' \
    '        ;;' \
    '    error)' \
    '        exit 9' \
    '        ;;' \
    '    garbage)' \
    '        printf '"'"'not-json\n'"'"'' \
    '        ;;' \
    '    *)' \
    '        exit 64' \
    '        ;;' \
    'esac' >"$HARNESS/bin/promote-exec.sh" \
    || fatal 'the promote executor stub could not be written'
chmod +x "$HARNESS/bin/promote-exec.sh" \
    || fatal 'the promote executor stub could not be made executable'

PATH="$STUB_BIN:$PATH" \
    SIGNALBOX_LEASE_REGISTRY="$LEASE_REGISTRY" \
    SIGNALBOX_LEASE_PID="$$" \
    "$HARNESS/bin/ports.sh" lease prerequisite \
    >"$FIX/lease.stdout" 2>"$FIX/lease.stderr"
LEASE_STATUS=$?
if [ "$LEASE_STATUS" -eq 0 ]; then
    PATH="$STUB_BIN:$PATH" \
        SIGNALBOX_LEASE_REGISTRY="$LEASE_REGISTRY" \
        "$HARNESS/bin/ports.sh" release prerequisite \
        >/dev/null 2>&1
    RELEASE_STATUS=$?
else
    RELEASE_STATUS=1
fi
if [ "$LEASE_STATUS" -ne 0 ] || [ "$RELEASE_STATUS" -ne 0 ]; then
    skip_all "an approval port cannot be leased in this environment"
fi

# 1. Plan completion is a fresh artifact terminal with no parking.
ISSUE=3201
RUN_DIR="$HARNESS/runs/issue-$ISSUE"
run_subject "$ISSUE" plan plan
OK=1
if [ "$SUBJECT_STATUS" -eq 0 ] \
    && jq -e '
        .terminal == "complete"
        and .phase == "plan"
        and .parked == false
        and .payload.outcome == "ARTIFACT"
    ' "$RUN_DIR/state/complete.json" >/dev/null 2>&1; then
    OK=0
fi
report_case "plan artifact records complete" "$OK" \
    "status=$SUBJECT_STATUS stderr=$(head -c 200 "$ERR")"

# 2. Review completion carries the CR correlation and no halted sibling.
ISSUE=3202
RUN_DIR="$HARNESS/runs/issue-$ISSUE"
run_subject "$ISSUE" review review-artifact
OK=1
if [ "$SUBJECT_STATUS" -eq 0 ] \
    && jq -e '
        .terminal == "complete"
        and .phase == "review"
        and .parked == false
        and .correlation_id == "review-correlation"
    ' "$RUN_DIR/state/complete.json" >/dev/null 2>&1 \
    && [ ! -e "$RUN_DIR/state/halted.json" ]; then
    OK=0
fi
report_case "review artifact records correlation" "$OK" \
    "status=$SUBJECT_STATUS stderr=$(head -c 200 "$ERR")"

# 3. Pending review evidence is a complete, parked terminal.
ISSUE=3203
RUN_DIR="$HARNESS/runs/issue-$ISSUE"
run_subject "$ISSUE" review review-parked
OK=1
if [ "$SUBJECT_STATUS" -eq 0 ] \
    && jq -e '
        .terminal == "complete"
        and .phase == "review"
        and .parked == true
        and .payload.outcome == "PARKED"
    ' "$RUN_DIR/state/complete.json" >/dev/null 2>&1; then
    OK=0
fi
report_case "review pending records parked" "$OK" \
    "status=$SUBJECT_STATUS stderr=$(head -c 200 "$ERR")"

# The held record names the still-live engine and the detached reaper.
PARK_PID="$(jq -r '.pid // empty' "$RUN_DIR/state/park.json" 2>/dev/null)"
PARK_START_ID="$(jq -r '.start_id // empty' "$RUN_DIR/state/park.json" 2>/dev/null)"
await_file "$REAPER_PID_FILE"
REAPER_READY=$?
REAPER_PID="$(head -n 1 "$REAPER_PID_FILE" 2>/dev/null || true)"
[ -n "$PARK_PID" ] && CHILD_PIDS+=("$PARK_PID")
[ -n "$REAPER_PID" ] && CHILD_PIDS+=("$REAPER_PID")

OK=1
if [ "$REAPER_READY" -eq 0 ] \
    && jq -e \
        --arg run_dir "$RUN_DIR" \
        '
        .held == true
        and .issue == 3203
        and .phase == "review"
        and .holder == "standalone"
        and (.port | type) == "number"
        and .approve_url == ("http://127.0.0.1:" + (.port | tostring) + "/approve")
        and .approve_command == (
            "curl -s -X POST " + .approve_url
            + " -H '\''Content-Type: application/json'\'' --data @"
            + $run_dir + "/state/pending.json"
        )
        and .pending == ($run_dir + "/state/pending.json")
        and (.pid | type) == "number"
        and (.start_id | type) == "string"
        and (.start_id | contains(":"))
        and .pid_file == ($run_dir + "/state/engine.pid")
        and .watch == ($run_dir + "/state/docs-sync.json")
        and .deadline == 4
        and (.lease_transferred | type) == "boolean"
        and .reason == null
        ' "$RUN_DIR/state/park.json" >/dev/null 2>&1; then
    OK=0
fi
report_case "park record holds detached engine" "$OK" \
    "record=$(jq -c . "$RUN_DIR/state/park.json" 2>/dev/null) reaper=$REAPER_PID"

OK=1
if [[ "$PARK_PID" =~ ^[1-9][0-9]*$ ]] \
    && kill -0 "$PARK_PID" 2>/dev/null; then
    OK=0
fi
report_case "park launcher leaves engine alive" "$OK" \
    "engine_pid=$PARK_PID status=$SUBJECT_STATUS"

OK=1
if [ -f "$RUN_DIR/state/engine.pid" ] \
    && [ "$(head -n 1 "$RUN_DIR/state/engine.pid" 2>/dev/null)" = "$PARK_PID" ]; then
    OK=0
fi
report_case "park launcher preserves engine pid file" "$OK" \
    "engine_pid=$PARK_PID pid_file=$(head -n 1 "$RUN_DIR/state/engine.pid" 2>/dev/null)"

APPROVE_URL="$(jq -r '.approve_url // empty' "$RUN_DIR/state/park.json" 2>/dev/null)"
OK=1
if jq -e \
    --arg approve_url "$APPROVE_URL" \
    '
    .reason
    | contains($approve_url)
      and contains("webhook stays live")
      and contains("SIGTERMing recorded engine pid")
    ' "$RUN_DIR/state/complete.json" >/dev/null 2>&1; then
    OK=0
fi
report_case "park terminal reason names approve URL" "$OK" \
    "reason=$(jq -r '.reason // empty' "$RUN_DIR/state/complete.json" 2>/dev/null)"

await_process_exit "$PARK_PID"
ENGINE_EXITED=$?
await_process_exit "$REAPER_PID"
REAPER_EXITED=$?
OK=1
if [ "$ENGINE_EXITED" -eq 0 ] \
    && [ "$REAPER_EXITED" -eq 0 ] \
    && [ ! -e "$RUN_DIR/state/engine.pid" ]; then
    OK=0
fi
report_case "park reaper exits after engine" "$OK" \
    "engine_exit=$ENGINE_EXITED reaper_exit=$REAPER_EXITED pid_file=$([ -e "$RUN_DIR/state/engine.pid" ] && printf present || printf absent)"

# A pending artifact written immediately before engine exit still records a
# complete parked terminal, but its approval window is explicitly closed.
ISSUE=3301
RUN_DIR="$HARNESS/runs/issue-$ISSUE"
run_subject "$ISSUE" review review-parked-dead
OK=1
if [ "$SUBJECT_STATUS" -eq 0 ] \
    && jq -e '
        .held == false
        and .pid == null
        and .start_id == null
        and .deadline == null
        and .lease_transferred == false
        and (.reason | contains("approval window is closed"))
    ' "$RUN_DIR/state/park.json" >/dev/null 2>&1 \
    && jq -e '
        .terminal == "complete"
        and .phase == "review"
        and .parked == true
        and (.reason | contains("approval window is already closed"))
    ' "$RUN_DIR/state/complete.json" >/dev/null 2>&1; then
    OK=0
fi
report_case "dead parked engine closes approval window" "$OK" \
    "status=$SUBJECT_STATUS record=$(jq -c . "$RUN_DIR/state/park.json" 2>/dev/null)"

# A live held record gets the actionable park refusal before leasing or
# overwriting any state for a new engine-backed launch.
ISSUE=3302
RUN_DIR="$HARNESS/runs/issue-$ISSUE"
mkdir -p "$RUN_DIR/state" \
    || fatal 'the live-park guard state directory could not be created'
sleep 15 &
GUARD_PID=$!
CHILD_PIDS+=("$GUARD_PID")
GUARD_INDEX=$((${#CHILD_PIDS[@]} - 1))
GUARD_START_ID="$(
    bash -c 'source "$1"; proc_identity "$2"' \
        fixture "$HARNESS/bin/_liveness.sh" "$GUARD_PID"
)" || fatal 'the live-park guard identity could not be read'
printf '%s\n' "$GUARD_PID" >"$RUN_DIR/state/engine.pid" \
    || fatal 'the live-park guard pid file could not be written'
jq -n \
    --arg issue "$ISSUE" \
    --argjson pid "$GUARD_PID" \
    --arg start_id "$GUARD_START_ID" \
    --arg approve_url "http://127.0.0.1:8240/approve" \
    '{
        held: true,
        issue: ($issue | tonumber),
        phase: "review",
        pid: $pid,
        start_id: $start_id,
        approve_url: $approve_url
    }' >"$RUN_DIR/state/park.json" \
    || fatal 'the live-park guard record could not be written'
run_subject "$ISSUE" plan idle
OK=1
if [ "$SUBJECT_STATUS" -eq 1 ] \
    && grep -q "run issue-$ISSUE is parked awaiting approval" "$ERR" \
    && grep -q 'http://127.0.0.1:8240/approve' "$ERR" \
    && grep -q "engine pid $GUARD_PID" "$ERR" \
    && grep -q 'port is still leased' "$ERR"; then
    OK=0
fi
kill -TERM "$GUARD_PID" 2>/dev/null || true
wait "$GUARD_PID" 2>/dev/null || true
CHILD_PIDS[$GUARD_INDEX]=""
report_case "live park refuses relaunch" "$OK" \
    "status=$SUBJECT_STATUS stderr=$(head -c 320 "$ERR")"

# 4. Missing docs-sync waits only for the injected grace and retains the
# already-observed CR terminal.
ISSUE=3204
RUN_DIR="$HARNESS/runs/issue-$ISSUE"
run_subject "$ISSUE" review review-no-sync artifact 1
OK=1
if [ "$SUBJECT_STATUS" -eq 0 ] \
    && jq -e '
        .terminal == "complete"
        and .phase == "review"
        and .payload.outcome == "ARTIFACT"
        and .correlation_id == "grace-correlation"
    ' "$RUN_DIR/state/complete.json" >/dev/null 2>&1 \
    && grep -q 'grace deadline elapsed' "$ERR"; then
    OK=0
fi
report_case "review docs-sync grace expires complete" "$OK" \
    "status=$SUBJECT_STATUS stderr=$(head -c 240 "$ERR")"

# 5. A non-GREEN implementation gate is a halted GATE_RED terminal.
ISSUE=3205
RUN_DIR="$HARNESS/runs/issue-$ISSUE"
run_subject "$ISSUE" implement gate-red
OK=1
if [ "$SUBJECT_STATUS" -eq 1 ] \
    && jq -e '
        .terminal == "halted"
        and .phase == "implement"
        and .outcome == "GATE_RED"
    ' "$RUN_DIR/state/halted.json" >/dev/null 2>&1; then
    OK=0
fi
report_case "implement red gate records halted" "$OK" \
    "status=$SUBJECT_STATUS stderr=$(head -c 200 "$ERR")"

# 6. Escalation wins as the cross-phase halted terminal.
ISSUE=3206
RUN_DIR="$HARNESS/runs/issue-$ISSUE"
run_subject "$ISSUE" plan escalated
OK=1
if [ "$SUBJECT_STATUS" -eq 1 ] \
    && jq -e '
        .terminal == "halted"
        and .phase == "plan"
        and .outcome == "ESCALATED"
    ' "$RUN_DIR/state/halted.json" >/dev/null 2>&1; then
    OK=0
fi
report_case "escalation records halted" "$OK" \
    "status=$SUBJECT_STATUS stderr=$(head -c 200 "$ERR")"

# 7. A child exiting without any artifact fails closed as ENGINE_DIED.
ISSUE=3207
RUN_DIR="$HARNESS/runs/issue-$ISSUE"
run_subject "$ISSUE" plan die
OK=1
if [ "$SUBJECT_STATUS" -eq 1 ] \
    && jq -e '
        .terminal == "halted"
        and .phase == "plan"
        and .outcome == "ENGINE_DIED"
    ' "$RUN_DIR/state/halted.json" >/dev/null 2>&1; then
    OK=0
fi
report_case "dead engine records halted" "$OK" \
    "status=$SUBJECT_STATUS stderr=$(head -c 200 "$ERR")"

# 8. Promotion without a CR is read-only refusal: no executor, terminal, lease
# artifact, or synthetic promote stamp.
ISSUE=3208
RUN_DIR="$HARNESS/runs/issue-$ISSUE"
run_subject "$ISSUE" promote idle artifact
OK=1
if [ "$SUBJECT_STATUS" -eq 1 ] \
    && [ ! -e "$PROMOTE_MARKER" ] \
    && [ ! -e "$RUN_DIR/state/complete.json" ] \
    && [ ! -e "$RUN_DIR/state/halted.json" ] \
    && [ ! -e "$RUN_DIR/state/pipeline-promote.stamp" ] \
    && grep -q 'promotion evidence missing' "$ERR" \
    && grep -q -- '--phase review' "$ERR"; then
    OK=0
fi
report_case "promote refuses missing CR" "$OK" \
    "status=$SUBJECT_STATUS stderr=$(head -c 240 "$ERR")"

# 9. A valid CR cannot compensate for a missing review stamp.
ISSUE=3209
RUN_DIR="$HARNESS/runs/issue-$ISSUE"
mkdir -p "$RUN_DIR/results" \
    || fatal 'missing-stamp results directory could not be created'
printf '# CR\ncorrelation_id: missing-stamp-correlation\nPROMOTION_READY\n' \
    >"$RUN_DIR/results/CR.md" \
    || fatal 'missing-stamp CR could not be written'
run_subject "$ISSUE" promote idle artifact
OK=1
if [ "$SUBJECT_STATUS" -eq 1 ] \
    && [ ! -e "$PROMOTE_MARKER" ] \
    && [ ! -e "$RUN_DIR/state/complete.json" ] \
    && [ ! -e "$RUN_DIR/state/halted.json" ] \
    && [ ! -e "$RUN_DIR/state/pipeline-promote.stamp" ] \
    && grep -q 'review stamp' "$ERR" \
    && grep -q -- '--phase review' "$ERR"; then
    OK=0
fi
report_case "promote refuses missing review stamp" "$OK" \
    "status=$SUBJECT_STATUS stderr=$(head -c 240 "$ERR")"

# 10. Valid promotion evidence produces the exact request shape and a complete
# terminal carrying the CR correlation.
ISSUE=3210
RUN_DIR="$HARNESS/runs/issue-$ISSUE"
write_review_evidence "$ISSUE" promote-correlation
run_subject "$ISSUE" promote idle artifact
OK=1
if [ "$SUBJECT_STATUS" -eq 0 ] \
    && jq -e '
        .terminal == "complete"
        and .phase == "promote"
        and .correlation_id == "promote-correlation"
        and .payload.outcome == "ARTIFACT"
    ' "$RUN_DIR/state/complete.json" >/dev/null 2>&1 \
    && jq -e '
        . == {
            issue: 3210,
            phase: "promote",
            correlation_id: "promote-correlation"
        }
    ' "$PROMOTE_MARKER" >/dev/null 2>&1 \
    && [ ! -e "$RUN_DIR/state/pipeline-promote.stamp" ]; then
    OK=0
fi
report_case "promote artifact records complete payload" "$OK" \
    "status=$SUBJECT_STATUS stderr=$(head -c 240 "$ERR")"

# 11. A normal NO_GO phase.done is a halted promotion.
ISSUE=3211
RUN_DIR="$HARNESS/runs/issue-$ISSUE"
write_review_evidence "$ISSUE" no-go-correlation
run_subject "$ISSUE" promote idle no-go
OK=1
if [ "$SUBJECT_STATUS" -eq 1 ] \
    && jq -e '
        .terminal == "halted"
        and .phase == "promote"
        and .outcome == "NO_GO"
    ' "$RUN_DIR/state/halted.json" >/dev/null 2>&1; then
    OK=0
fi
report_case "promote NO_GO records halted" "$OK" \
    "status=$SUBJECT_STATUS stderr=$(head -c 240 "$ERR")"

# 12. A non-zero executor is normalized to a reasoned NO_GO terminal.
ISSUE=3212
RUN_DIR="$HARNESS/runs/issue-$ISSUE"
write_review_evidence "$ISSUE" error-correlation
run_subject "$ISSUE" promote idle error
OK=1
if [ "$SUBJECT_STATUS" -eq 1 ] \
    && jq -e '
        .terminal == "halted"
        and .outcome == "NO_GO"
        and (.reason | contains("exited with status 9"))
    ' "$RUN_DIR/state/halted.json" >/dev/null 2>&1; then
    OK=0
fi
report_case "promote executor failure records halted" "$OK" \
    "status=$SUBJECT_STATUS stderr=$(head -c 240 "$ERR")"

# 13. Garbage stdout is likewise a fail-closed promotion terminal.
ISSUE=3213
RUN_DIR="$HARNESS/runs/issue-$ISSUE"
write_review_evidence "$ISSUE" garbage-correlation
run_subject "$ISSUE" promote idle garbage
OK=1
if [ "$SUBJECT_STATUS" -eq 1 ] \
    && jq -e '
        .terminal == "halted"
        and .outcome == "NO_GO"
        and (.reason | contains("malformed phase.done"))
    ' "$RUN_DIR/state/halted.json" >/dev/null 2>&1; then
    OK=0
fi
report_case "promote garbage records halted" "$OK" \
    "status=$SUBJECT_STATUS stderr=$(head -c 240 "$ERR")"

# 14. Promote merges liveness fields without moving the dashboard's original
# launch boundary.
ISSUE=3214
RUN_DIR="$HARNESS/runs/issue-$ISSUE"
STARTED_VALUE="2001-02-03T04:05:06Z"
write_review_evidence "$ISSUE" preserve-correlation
jq -n \
    --arg issue "$ISSUE" \
    --arg slug "issue-$ISSUE" \
    --arg phase review \
    --arg started "$STARTED_VALUE" \
    --arg custom keep-me \
    '{
        issue: ($issue | tonumber),
        slug: $slug,
        phase: $phase,
        started: $started,
        custom: $custom,
        engines: {},
        ports: {}
    }' >"$RUN_DIR/launch.json" \
    || fatal 'the pre-existing launch record could not be written'
run_subject "$ISSUE" promote idle artifact
OK=1
if [ "$SUBJECT_STATUS" -eq 0 ] \
    && jq -e \
        --arg started "$STARTED_VALUE" \
        '
        .started == $started
        and .phase == "promote"
        and (.pid | type) == "number"
        and .custom == "keep-me"
        ' "$RUN_DIR/launch.json" >/dev/null 2>&1; then
    OK=0
fi
report_case "promote preserves launch start" "$OK" \
    "status=$SUBJECT_STATUS launch=$(jq -c . "$RUN_DIR/launch.json" 2>/dev/null)"

# 15. Bare pipeline launch keeps terminal ownership inside its topology, even
# when this launcher is stopped mid-run.
ISSUE=3215
RUN_DIR="$HARNESS/runs/issue-$ISSUE"
CASE_DIR="$FIX/case-$ISSUE-pipeline"
mkdir -p "$CASE_DIR" || fatal 'the pipeline case directory could not be created'
OUT="$CASE_DIR/stdout"
ERR="$CASE_DIR/stderr"
PATH="$STUB_BIN:$PATH" \
    SIGNALBOX_LEASE_REGISTRY="$LEASE_REGISTRY" \
    SIGNALBOX_TEST_HARNESS="$HARNESS" \
    SIGNALBOX_TEST_MODE=idle \
    "$SUBJECT" "$ISSUE" >"$OUT" 2>"$ERR" &
SUBJECT_PID=$!
CHILD_PIDS+=("$SUBJECT_PID")
await_launch "$RUN_DIR/launch.json" "$SUBJECT_PID"
LAUNCH_READY=$?
kill -TERM "$SUBJECT_PID" 2>/dev/null || true
wait "$SUBJECT_PID" 2>/dev/null
SUBJECT_STATUS=$?
CHILD_PIDS[$((${#CHILD_PIDS[@]} - 1))]=""
OK=1
if [ "$LAUNCH_READY" -eq 0 ] \
    && [ "$SUBJECT_STATUS" -eq 143 ] \
    && [ ! -e "$RUN_DIR/state/complete.json" ] \
    && [ ! -e "$RUN_DIR/state/halted.json" ]; then
    OK=0
fi
report_case "pipeline SIGTERM records no launcher terminal" "$OK" \
    "status=$SUBJECT_STATUS launch=$LAUNCH_READY stderr=$(head -c 240 "$ERR")"

# 16. A reused run directory keeps the previous review's CR.md. A fresh PARKED
# terminal must carry the id from this launch's pending.json, never that
# leftover.
ISSUE=3216
RUN_DIR="$HARNESS/runs/issue-$ISSUE"
mkdir -p "$RUN_DIR/results" \
    || fatal 'the stale CR results directory could not be created'
printf '# CR\ncorrelation_id: stale-correlation\nPROMOTION_READY\n' \
    >"$RUN_DIR/results/CR.md" \
    || fatal 'the stale CR could not be written'
run_subject "$ISSUE" review review-parked-cid
OK=1
if [ "$SUBJECT_STATUS" -eq 0 ] \
    && jq -e '
        .terminal == "complete"
        and .payload.outcome == "PARKED"
        and .correlation_id == "pending-correlation"
    ' "$RUN_DIR/state/complete.json" >/dev/null 2>&1; then
    OK=0
fi
report_case "parked review ignores stale CR correlation" "$OK" \
    "status=$SUBJECT_STATUS correlation=$(jq -r '.correlation_id' "$RUN_DIR/state/complete.json" 2>/dev/null)"

# 17. Run ownership is exclusive across launcher modes, not just among
# promoters: a promotion refuses while a plan launcher owns the same run, and
# refuses on the ownership claim rather than on the PID file.
ISSUE=3217
RUN_DIR="$HARNESS/runs/issue-$ISSUE"
CASE_DIR="$FIX/case-$ISSUE-owner"
mkdir -p "$CASE_DIR" || fatal 'the ownership case directory could not be created'
write_review_evidence "$ISSUE" owner-correlation
PATH="$STUB_BIN:$PATH" \
    SIGNALBOX_LEASE_REGISTRY="$LEASE_REGISTRY" \
    SIGNALBOX_TEST_HARNESS="$HARNESS" \
    SIGNALBOX_TEST_MODE=idle \
    "$SUBJECT" "$ISSUE" --phase plan \
    >"$CASE_DIR/stdout" 2>"$CASE_DIR/stderr" &
OWNER_PID=$!
CHILD_PIDS+=("$OWNER_PID")
OWNER_INDEX=$((${#CHILD_PIDS[@]} - 1))
await_launch "$RUN_DIR/launch.json" "$OWNER_PID"
LAUNCH_READY=$?
run_subject "$ISSUE" promote idle artifact
OK=1
if [ "$LAUNCH_READY" -eq 0 ] \
    && [ "$SUBJECT_STATUS" -eq 1 ] \
    && [ ! -e "$PROMOTE_MARKER" ] \
    && grep -q 'already owned by another bin/run.sh launcher' "$ERR"; then
    OK=0
fi
kill -TERM "$OWNER_PID" 2>/dev/null || true
wait "$OWNER_PID" 2>/dev/null
CHILD_PIDS[$OWNER_INDEX]=""
report_case "promote refuses while another mode owns the run" "$OK" \
    "status=$SUBJECT_STATUS launch=$LAUNCH_READY stderr=$(head -c 240 "$ERR")"

printf '%d/%d cases passed (%d skipped)\n' \
    "$TESTS_PASSED" "$TESTS_RUN" "$TESTS_SKIPPED"
[ "$TESTS_PASSED" -eq "$TESTS_RUN" ]
