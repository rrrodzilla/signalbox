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
    local CASE_DIR="$FIX/case-$ISSUE_VALUE-$PHASE_VALUE-$ENGINE_MODE-$PROMOTE_MODE"
    local PID_INDEX

    mkdir -p "$CASE_DIR" || fatal "case directory could not be created: $CASE_DIR"
    OUT="$CASE_DIR/stdout"
    ERR="$CASE_DIR/stderr"
    PROMOTE_MARKER="$CASE_DIR/promote-invoked.json"

    PATH="$STUB_BIN:$PATH" \
        SIGNALBOX_LEASE_REGISTRY="$LEASE_REGISTRY" \
        SIGNALBOX_TEST_HARNESS="$HARNESS" \
        SIGNALBOX_TEST_MODE="$ENGINE_MODE" \
        SIGNALBOX_PROMOTE_MODE="$PROMOTE_MODE" \
        SIGNALBOX_PROMOTE_MARKER="$PROMOTE_MARKER" \
        SIGNALBOX_DOCS_SYNC_GRACE="$DOCS_GRACE" \
        "$SUBJECT" "$ISSUE_VALUE" --phase "$PHASE_VALUE" \
        >"$OUT" 2>"$ERR" &
    SUBJECT_PID=$!
    CHILD_PIDS+=("$SUBJECT_PID")
    PID_INDEX=$((${#CHILD_PIDS[@]} - 1))
    wait "$SUBJECT_PID" 2>/dev/null
    SUBJECT_STATUS=$?
    CHILD_PIDS[$PID_INDEX]=""
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
    'exec sleep 120' >"$STUB_BIN/emergent" \
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

printf '%d/%d cases passed (%d skipped)\n' \
    "$TESTS_PASSED" "$TESTS_RUN" "$TESTS_SKIPPED"
[ "$TESTS_PASSED" -eq "$TESTS_RUN" ]
