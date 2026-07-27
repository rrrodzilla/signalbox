#!/usr/bin/env bash
# Self-contained test runner for bin/pipeline-seed.sh. Each case copies bin/
# into a miniature harness under mktemp -d so _env.sh resolves fixture-local
# run paths and never writes into this repository. Prints PASS/FAIL per case
# and exits non-zero when any case failed.
#
# Deliberately no -e: cases capture subject statuses that may be non-zero.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES=()
TESTS_RUN=0
TESTS_PASSED=0
FIXTURE_PATH=""
RUN_PATH=""
STDOUT_PATH=""
STDERR_PATH=""
RUN_STATUS=0

cleanup() {
    local FIXTURE
    for FIXTURE in "${FIXTURES[@]}"; do
        rm -rf -- "$FIXTURE"
    done
}
trap cleanup EXIT

fixture() {
    local WITH_DOCS="${1:-yes}"
    local DIR
    DIR="$(mktemp -d)"
    FIXTURES+=("$DIR")
    cp -r "$ROOT/bin" "$DIR/bin"
    if [ "$WITH_DOCS" = "yes" ]; then
        mkdir -p "$DIR/.claude/docs"
        printf '%s\n' "# Fixture architecture" >"$DIR/.claude/docs/ARCHI.md"
    fi
    FIXTURE_PATH="$DIR"
    RUN_PATH="$DIR/runs/issue-9"
    STDOUT_PATH="$DIR/stdout"
    STDERR_PATH="$DIR/stderr"
}

run_subject() {
    SIGNALBOX_ISSUE=9 SIGNALBOX_RUN_SLUG=issue-9 \
        "$FIXTURE_PATH/bin/pipeline-seed.sh" \
        >"$STDOUT_PATH" 2>"$STDERR_PATH"
    RUN_STATUS=$?
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

seed_output_matches_state() {
    local OUTPUT="$1"
    local PIPELINE_STATE="$2"
    local OUTPUT_CID
    OUTPUT_CID="$(jq -r -s '.[0].correlation_id // empty' "$OUTPUT" 2>/dev/null)"
    jq -e -s '
        length == 1
        and .[0].phase == "plan"
        and .[0].issue == 9
        and (.[0].correlation_id | startswith("pipe-9-"))
    ' "$OUTPUT" >/dev/null 2>&1 \
        && jq -e \
            --arg cid "$OUTPUT_CID" '
                .correlation_id == $cid
                and .issue == 9
                and (.started | test(
                    "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"
                ))
            ' "$PIPELINE_STATE" >/dev/null 2>&1
}

# 1. A clean run emits one event and records its pipeline identity without
# creating an empty archive directory below logs/.
fixture
run_subject
OK=1
FIRST_ARCHIVE="$(
    find "$RUN_PATH/logs" -mindepth 1 -maxdepth 1 -type d -print -quit \
        2>/dev/null
)"
if [ "$RUN_STATUS" -eq 0 ] \
    && seed_output_matches_state "$STDOUT_PATH" "$RUN_PATH/state/pipeline.json" \
    && [ -z "$FIRST_ARCHIVE" ]; then
    OK=0
fi
report_case "clean run records identity without an empty archive" "$OK" \
    "status=$RUN_STATUS archive=${FIRST_ARCHIVE:-none} stdout=$(head -c 180 "$STDOUT_PATH")"

# 2. Every allowlisted singleton moves under the prior correlation ID while
# launch/config/PID/direct-log files from the current run remain untouched.
fixture
mkdir -p "$RUN_PATH/results" "$RUN_PATH/state/stages" "$RUN_PATH/logs"
printf '%s\n' '{"issue":3,"feature":"old-feature"}' >"$RUN_PATH/plan.json"
printf '%s\n' "old review" >"$RUN_PATH/results/CR.md"
for STATE_NAME in run gate pending escalated docs-sync worktree provenance; do
    printf '%s\n' "$STATE_NAME-old" >"$RUN_PATH/state/$STATE_NAME.json"
done
printf '%s\n' "plan-stamp-old" >"$RUN_PATH/state/pipeline-plan.stamp"
printf '%s\n' "implement-stamp-old" >"$RUN_PATH/state/pipeline-implement.stamp"
printf '%s\n' "review-stamp-old" >"$RUN_PATH/state/pipeline-review.stamp"
printf '%s\n' "stage-old" >"$RUN_PATH/state/stages/s1.json"
jq -n --arg cid "pipe-3-20260726-194500" \
    '{correlation_id: $cid, issue: 3}' >"$RUN_PATH/state/pipeline.json"
printf '%s\n' "launch-current" >"$RUN_PATH/launch.json"
printf '%s\n' "config-current" >"$RUN_PATH/pipeline.toml"
printf '%s\n' "pid-current" >"$RUN_PATH/state/engine.pid"
printf '%s\n' "log-current" >"$RUN_PATH/logs/pipeline-plan.log"
run_subject

PRIOR_ID="pipe-3-20260726-194500"
ARCHIVE="$RUN_PATH/logs/$PRIOR_ID"
ARCHIVED_PATHS=(
    "plan.json"
    "results/CR.md"
    "state/run.json"
    "state/gate.json"
    "state/pending.json"
    "state/escalated.json"
    "state/docs-sync.json"
    "state/worktree.json"
    "state/provenance.json"
    "state/pipeline.json"
    "state/pipeline-plan.stamp"
    "state/pipeline-implement.stamp"
    "state/pipeline-review.stamp"
    "state/stages"
)
OK=0
for RELATIVE_PATH in "${ARCHIVED_PATHS[@]}"; do
    if [ ! -e "$ARCHIVE/$RELATIVE_PATH" ]; then
        OK=1
    fi
    if [ "$RELATIVE_PATH" != "state/pipeline.json" ] \
        && [ -e "$RUN_PATH/$RELATIVE_PATH" ]; then
        OK=1
    fi
done
if [ "$RUN_STATUS" -ne 0 ] \
    || ! seed_output_matches_state \
        "$STDOUT_PATH" "$RUN_PATH/state/pipeline.json" \
    || ! jq -e \
        --arg cid "$PRIOR_ID" '.correlation_id == $cid and .issue == 3' \
        "$ARCHIVE/state/pipeline.json" >/dev/null 2>&1 \
    || [ "$(cat "$RUN_PATH/launch.json" 2>/dev/null)" != "launch-current" ] \
    || [ "$(cat "$RUN_PATH/pipeline.toml" 2>/dev/null)" != "config-current" ] \
    || [ "$(cat "$RUN_PATH/state/engine.pid" 2>/dev/null)" != "pid-current" ] \
    || [ "$(cat "$RUN_PATH/logs/pipeline-plan.log" 2>/dev/null)" != "log-current" ] \
    || [ ! -d "$RUN_PATH/results" ]; then
    OK=1
fi
report_case "full prior run is archived and current-run files survive" "$OK" \
    "status=$RUN_STATUS stderr=$(head -c 220 "$STDERR_PATH")"

# 3. Both a missing and malformed old pipeline record use a safe prev-* name.
fixture
mkdir -p "$RUN_PATH"
printf '%s\n' "missing-id-plan" >"$RUN_PATH/plan.json"
run_subject
MISSING_STATUS=$RUN_STATUS
MISSING_ARCHIVE="$(
    find "$RUN_PATH/logs" -mindepth 1 -maxdepth 1 -type d -name 'prev-*' \
        -print -quit 2>/dev/null
)"
MISSING_OK=1
if [ "$MISSING_STATUS" -eq 0 ] \
    && [ -n "$MISSING_ARCHIVE" ] \
    && [[ "$(basename "$MISSING_ARCHIVE")" =~ ^prev-[0-9]{8}-[0-9]{6}$ ]] \
    && [ "$(cat "$MISSING_ARCHIVE/plan.json" 2>/dev/null)" = "missing-id-plan" ]; then
    MISSING_OK=0
fi

fixture
mkdir -p "$RUN_PATH/state"
printf '%s\n' "malformed-id-gate" >"$RUN_PATH/state/gate.json"
printf '%s\n' '{"correlation_id":' >"$RUN_PATH/state/pipeline.json"
run_subject
MALFORMED_STATUS=$RUN_STATUS
MALFORMED_ARCHIVE="$(
    find "$RUN_PATH/logs" -mindepth 1 -maxdepth 1 -type d -name 'prev-*' \
        -print -quit 2>/dev/null
)"
MALFORMED_OK=1
if [ "$MALFORMED_STATUS" -eq 0 ] \
    && [ -n "$MALFORMED_ARCHIVE" ] \
    && [[ "$(basename "$MALFORMED_ARCHIVE")" =~ ^prev-[0-9]{8}-[0-9]{6}$ ]] \
    && [ "$(cat "$MALFORMED_ARCHIVE/state/gate.json" 2>/dev/null)" = "malformed-id-gate" ] \
    && [ "$(cat "$MALFORMED_ARCHIVE/state/pipeline.json" 2>/dev/null)" = '{"correlation_id":' ]; then
    MALFORMED_OK=0
fi
OK=1
if [ "$MISSING_OK" -eq 0 ] && [ "$MALFORMED_OK" -eq 0 ]; then
    OK=0
fi
report_case "missing or malformed prior identity uses prev archive" "$OK" \
    "missing=$MISSING_STATUS malformed=$MALFORMED_STATUS"

# 4. An existing archive is never merged into or overwritten.
fixture
COLLISION_ID="pipe-3-20260726-194500"
mkdir -p "$RUN_PATH/state" "$RUN_PATH/logs/$COLLISION_ID"
printf '%s\n' "keep-marker" >"$RUN_PATH/logs/$COLLISION_ID/marker"
printf '%s\n' "collision-plan" >"$RUN_PATH/plan.json"
jq -n --arg cid "$COLLISION_ID" \
    '{correlation_id: $cid, issue: 3}' >"$RUN_PATH/state/pipeline.json"
run_subject
OK=1
if [ "$RUN_STATUS" -eq 0 ] \
    && [ "$(cat "$RUN_PATH/logs/$COLLISION_ID/marker" 2>/dev/null)" = "keep-marker" ] \
    && [ "$(cat "$RUN_PATH/logs/$COLLISION_ID-2/plan.json" 2>/dev/null)" = "collision-plan" ] \
    && jq -e --arg cid "$COLLISION_ID" \
        '.correlation_id == $cid' \
        "$RUN_PATH/logs/$COLLISION_ID-2/state/pipeline.json" \
        >/dev/null 2>&1; then
    OK=0
fi
report_case "archive name collision selects a distinct directory" "$OK" \
    "status=$RUN_STATUS stderr=$(head -c 220 "$STDERR_PATH")"

# 5. The vault precondition fails before any archival or run-state mutation.
fixture no
VAULT_PRIOR_ID="pipe-4-20260726-194500"
mkdir -p "$RUN_PATH/state" "$RUN_PATH/logs"
printf '%s\n' "vault-plan-old" >"$RUN_PATH/plan.json"
jq -n --arg cid "$VAULT_PRIOR_ID" \
    '{correlation_id: $cid, issue: 4}' >"$RUN_PATH/state/pipeline.json"
run_subject
ARCHIVE_AFTER_FAILURE="$(
    find "$RUN_PATH/logs" -mindepth 1 -maxdepth 1 -type d -print -quit \
        2>/dev/null
)"
OK=1
if [ "$RUN_STATUS" -eq 1 ] \
    && [ "$(cat "$RUN_PATH/plan.json" 2>/dev/null)" = "vault-plan-old" ] \
    && jq -e --arg cid "$VAULT_PRIOR_ID" \
        '.correlation_id == $cid and .issue == 4' \
        "$RUN_PATH/state/pipeline.json" >/dev/null 2>&1 \
    && [ -z "$ARCHIVE_AFTER_FAILURE" ] \
    && grep -q "vault docs missing" "$STDERR_PATH"; then
    OK=0
fi
report_case "missing vault docs fail before archival" "$OK" \
    "status=$RUN_STATUS archive=${ARCHIVE_AFTER_FAILURE:-none}"

printf '%d/%d cases passed\n' "$TESTS_PASSED" "$TESTS_RUN"
[ "$TESTS_PASSED" -eq "$TESTS_RUN" ]
