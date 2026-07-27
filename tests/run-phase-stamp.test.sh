#!/usr/bin/env bash
# Self-contained test runner for bin/run.sh direct-phase stamps. No framework;
# fixtures live under mktemp -d, and cleanup targets only launcher PIDs created
# by this runner. Prints PASS/FAIL per case and exits non-zero on failure.
#
# Deliberately no -e: cases capture subject statuses that may be non-zero.
# Fixture creation and setup are therefore checked explicitly and abort the
# runner, so a broken fixture can never pass as an empty (0/0) success.
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
SUBJECT_PID=""
SUBJECT_STATUS=0
OUT=""
ERR=""

cleanup() {
    local PID_VALUE
    # Stop only launchers started by this runner. Each launcher owns and
    # terminates its exact Emergent child; never use pkill here.
    for PID_VALUE in "${CHILD_PIDS[@]}"; do
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
        "review stamp is current at launch"
        "review relaunch refreshes a stale stamp"
        "implement launch stamps only implement"
        "plan launch stamps only plan"
        "pipeline launch does not pre-stamp phases"
        "invalid phase remains a usage error"
    )

    for NAME in "${NAMES[@]}"; do
        printf 'SKIP %s — %s\n' "$NAME" "$REASON"
        TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
    done
    printf '%d/%d cases passed (%d skipped)\n' \
        "$TESTS_PASSED" "$TESTS_RUN" "$TESTS_SKIPPED"
    exit 0
}

start_subject() {
    local ISSUE_VALUE="$1" PHASE_VALUE="${2:-}"
    local CASE_DIR="$FIX/case-$ISSUE_VALUE"

    mkdir -p "$CASE_DIR"
    OUT="$CASE_DIR/stdout"
    ERR="$CASE_DIR/stderr"
    if [ -n "$PHASE_VALUE" ]; then
        PATH="$STUB_BIN:$PATH" \
            SIGNALBOX_LEASE_REGISTRY="$LEASE_REGISTRY" \
            "$SUBJECT" "$ISSUE_VALUE" --phase "$PHASE_VALUE" \
            >"$OUT" 2>"$ERR" &
    else
        PATH="$STUB_BIN:$PATH" \
            SIGNALBOX_LEASE_REGISTRY="$LEASE_REGISTRY" \
            "$SUBJECT" "$ISSUE_VALUE" >"$OUT" 2>"$ERR" &
    fi
    SUBJECT_PID=$!
    CHILD_PIDS+=("$SUBJECT_PID")
}

await_launch() {
    local LAUNCH_FILE="$1" ATTEMPT

    for ATTEMPT in {1..100}; do
        if [ -f "$LAUNCH_FILE" ] \
            && jq -e '.pid | type == "number" and . > 0' \
                "$LAUNCH_FILE" >/dev/null 2>&1; then
            return 0
        fi
        if ! kill -0 "$SUBJECT_PID" 2>/dev/null; then
            return 1
        fi
        sleep 0.05
    done
    return 1
}

await_stamp() {
    local STAMP_FILE="$1" ATTEMPT

    for ATTEMPT in {1..100}; do
        [ -e "$STAMP_FILE" ] && return 0
        if ! kill -0 "$SUBJECT_PID" 2>/dev/null; then
            return 1
        fi
        sleep 0.05
    done
    return 1
}

stop_subject() {
    kill -TERM "$SUBJECT_PID" 2>/dev/null || true
    wait "$SUBJECT_PID" 2>/dev/null
    SUBJECT_STATUS=$?
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
printf '# fixture architecture\n' >"$HARNESS/.claude/docs/ARCHI.md" \
    || fatal 'the fixture ARCHI.md could not be written'

for TEMPLATE in pipeline plan implement emergent init; do
    printf 'name = "fixture__SIGNALBOX_RUN_SUFFIX__"\napproval = __SIGNALBOX_PORT_APPROVAL__\n' \
        >"$HARNESS/templates/$TEMPLATE.toml" \
        || fatal "the fixture template $TEMPLATE.toml could not be written"
done

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'exec sleep 120' >"$STUB_BIN/emergent" \
    || fatal 'the emergent stub could not be written'
chmod +x "$STUB_BIN/emergent" \
    || fatal 'the emergent stub could not be made executable'

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

# 1. A direct review launch writes a stamp that is current at its recorded
# whole-second launch boundary.
ISSUE=3401
RUN_DIR="$HARNESS/runs/issue-$ISSUE"
LAUNCH="$RUN_DIR/launch.json"
STAMP="$RUN_DIR/state/pipeline-review.stamp"
start_subject "$ISSUE" review
await_launch "$LAUNCH"
LAUNCH_READY=$?
await_stamp "$STAMP"
STAMP_READY=$?
stop_subject
STARTED_VALUE="$(jq -r '.started // empty' "$LAUNCH" 2>/dev/null)"
STARTED_STATUS=$?
BOUNDARY="$(date -d "$STARTED_VALUE" +%s 2>/dev/null)"
BOUNDARY_STATUS=$?
STAMP_EPOCH="$(stat -c %Y "$STAMP" 2>/dev/null)"
STAMP_STATUS=$?
OK=1
if [ "$LAUNCH_READY" -eq 0 ] \
    && [ "$STAMP_READY" -eq 0 ] \
    && [ "$STARTED_STATUS" -eq 0 ] \
    && [ "$BOUNDARY_STATUS" -eq 0 ] \
    && [ "$STAMP_STATUS" -eq 0 ] \
    && [ "$STAMP_EPOCH" -ge "$BOUNDARY" ]; then
    OK=0
fi
report_case "review stamp is current at launch" "$OK" \
    "launcher=$SUBJECT_STATUS launch=$LAUNCH_READY stamp=$STAMP_EPOCH boundary=$BOUNDARY"

# 2. Relaunching review refreshes a previous run's clearly stale stamp.
ISSUE=3402
RUN_DIR="$HARNESS/runs/issue-$ISSUE"
LAUNCH="$RUN_DIR/launch.json"
STAMP="$RUN_DIR/state/pipeline-review.stamp"
mkdir -p "$RUN_DIR/state"
touch -d '@1000000000' "$STAMP"
start_subject "$ISSUE" review
await_launch "$LAUNCH"
LAUNCH_READY=$?
await_stamp "$STAMP"
STAMP_READY=$?
stop_subject
STARTED_VALUE="$(jq -r '.started // empty' "$LAUNCH" 2>/dev/null)"
STARTED_STATUS=$?
BOUNDARY="$(date -d "$STARTED_VALUE" +%s 2>/dev/null)"
BOUNDARY_STATUS=$?
STAMP_EPOCH="$(stat -c %Y "$STAMP" 2>/dev/null)"
STAMP_STATUS=$?
OK=1
if [ "$LAUNCH_READY" -eq 0 ] \
    && [ "$STAMP_READY" -eq 0 ] \
    && [ "$STARTED_STATUS" -eq 0 ] \
    && [ "$BOUNDARY_STATUS" -eq 0 ] \
    && [ "$STAMP_STATUS" -eq 0 ] \
    && [ "$STAMP_EPOCH" -gt 1000000000 ] \
    && [ "$STAMP_EPOCH" -ge "$BOUNDARY" ]; then
    OK=0
fi
report_case "review relaunch refreshes a stale stamp" "$OK" \
    "launcher=$SUBJECT_STATUS launch=$LAUNCH_READY stamp=$STAMP_EPOCH boundary=$BOUNDARY"

# 3. Implement stamps only its own phase.
ISSUE=3403
RUN_DIR="$HARNESS/runs/issue-$ISSUE"
LAUNCH="$RUN_DIR/launch.json"
STAMP="$RUN_DIR/state/pipeline-implement.stamp"
start_subject "$ISSUE" implement
await_launch "$LAUNCH"
LAUNCH_READY=$?
await_stamp "$STAMP"
STAMP_READY=$?
stop_subject
OK=1
if [ "$LAUNCH_READY" -eq 0 ] \
    && [ "$STAMP_READY" -eq 0 ] \
    && [ -e "$STAMP" ] \
    && [ ! -e "$RUN_DIR/state/pipeline-plan.stamp" ] \
    && [ ! -e "$RUN_DIR/state/pipeline-review.stamp" ]; then
    OK=0
fi
report_case "implement launch stamps only implement" "$OK" \
    "launcher=$SUBJECT_STATUS launch=$LAUNCH_READY stamp=$STAMP_READY"

# 4. Plan stamps only its own phase.
ISSUE=3404
RUN_DIR="$HARNESS/runs/issue-$ISSUE"
LAUNCH="$RUN_DIR/launch.json"
STAMP="$RUN_DIR/state/pipeline-plan.stamp"
start_subject "$ISSUE" plan
await_launch "$LAUNCH"
LAUNCH_READY=$?
await_stamp "$STAMP"
STAMP_READY=$?
stop_subject
OK=1
if [ "$LAUNCH_READY" -eq 0 ] \
    && [ "$STAMP_READY" -eq 0 ] \
    && [ -e "$STAMP" ] \
    && [ ! -e "$RUN_DIR/state/pipeline-implement.stamp" ] \
    && [ ! -e "$RUN_DIR/state/pipeline-review.stamp" ]; then
    OK=0
fi
report_case "plan launch stamps only plan" "$OK" \
    "launcher=$SUBJECT_STATUS launch=$LAUNCH_READY stamp=$STAMP_READY"

# 5. Pipeline launch leaves phase stamping to pipeline-seed.sh/phase-run.sh.
ISSUE=3405
RUN_DIR="$HARNESS/runs/issue-$ISSUE"
LAUNCH="$RUN_DIR/launch.json"
start_subject "$ISSUE"
await_launch "$LAUNCH"
LAUNCH_READY=$?
stop_subject
OK=1
if [ "$LAUNCH_READY" -eq 0 ] \
    && [ ! -e "$RUN_DIR/state/pipeline-plan.stamp" ] \
    && [ ! -e "$RUN_DIR/state/pipeline-implement.stamp" ] \
    && [ ! -e "$RUN_DIR/state/pipeline-review.stamp" ]; then
    OK=0
fi
report_case "pipeline launch does not pre-stamp phases" "$OK" \
    "launcher=$SUBJECT_STATUS launch=$LAUNCH_READY"

# 6. Invalid phase validation still exits before the launch path.
ISSUE=3406
RUN_DIR="$HARNESS/runs/issue-$ISSUE"
OUT="$FIX/case-$ISSUE.stdout"
ERR="$FIX/case-$ISSUE.stderr"
PATH="$STUB_BIN:$PATH" \
    SIGNALBOX_LEASE_REGISTRY="$LEASE_REGISTRY" \
    "$SUBJECT" "$ISSUE" --phase bogus >"$OUT" 2>"$ERR"
INVALID_STATUS=$?
OK=1
if [ "$INVALID_STATUS" -eq 64 ] \
    && [ ! -e "$RUN_DIR/state/pipeline-plan.stamp" ] \
    && [ ! -e "$RUN_DIR/state/pipeline-implement.stamp" ] \
    && [ ! -e "$RUN_DIR/state/pipeline-review.stamp" ]; then
    OK=0
fi
report_case "invalid phase remains a usage error" "$OK" \
    "status=$INVALID_STATUS stderr=$(head -c 200 "$ERR")"

printf '%d/%d cases passed (%d skipped)\n' \
    "$TESTS_PASSED" "$TESTS_RUN" "$TESTS_SKIPPED"
[ "$TESTS_PASSED" -eq "$TESTS_RUN" ]
