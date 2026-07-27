#!/usr/bin/env bash
# Self-contained test runner for bin/docs-sync-wait.sh. No framework; every
# fixture is built in its own mktemp -d and removed by an EXIT trap. Deliberately
# omits set -e so expected subject failures can be captured and asserted.
# Prints PASS/FAIL per case and exits non-zero when any case failed.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUBJECT="$ROOT/bin/docs-sync-wait.sh"
FIXTURES=()
TESTS_RUN=0
TESTS_PASSED=0
RUN_STATUS=0
FIXTURE_PATH=""

cleanup() {
    local FIXTURE
    for FIXTURE in "${FIXTURES[@]}"; do
        rm -rf -- "$FIXTURE"
    done
}
trap cleanup EXIT

fixture() {
    local DIR
    DIR="$(mktemp -d)"
    FIXTURES+=("$DIR")
    mkdir -p "$DIR/state" "$DIR/results"
    FIXTURE_PATH="$DIR"
}

write_evidence() {
    local DIR="$1"
    local STATUS="$2"
    local NOTE="$3"
    local CID="$4"
    local UPDATED="$5"
    jq -n \
        --arg status "$STATUS" \
        --arg note "$NOTE" \
        --arg cid "$CID" \
        --argjson updated "$UPDATED" \
        '{
            updated: $updated,
            unchanged: [],
            status: $status,
            note: $note,
            vault: "/fixture/vault",
            feature: "fixture",
            issue: 23,
            correlation_id: $cid,
            ts: "2026-07-27T00:00:00Z"
        }' >"$DIR/state/docs-sync.json"
}

make_fresh() {
    local DIR="$1"
    touch -d '@1000000000' "$DIR/state/pipeline-review.stamp"
    touch -d '@1000000001' "$DIR/state/docs-sync.json"
}

run_subject() {
    local STDOUT_FILE="$1"
    local STDERR_FILE="$2"
    shift 2
    "$SUBJECT" "$@" >"$STDOUT_FILE" 2>"$STDERR_FILE"
    RUN_STATUS=$?
}

run_subject_limited() {
    local STDOUT_FILE="$1"
    local STDERR_FILE="$2"
    local LIMIT="$3"
    shift 3
    timeout "$LIMIT" "$SUBJECT" "$@" >"$STDOUT_FILE" 2>"$STDERR_FILE"
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

OUT="$(mktemp)"
ERR="$(mktemp)"
FIXTURES+=("$OUT" "$ERR")

# 1. Fresh OK evidence with the same correlation id as CR.md passes.
fixture
DIR="$FIXTURE_PATH"
write_evidence "$DIR" "OK" "updated architecture" "cid-match" '["ARCHI.md"]'
printf 'PROMOTION_READY\ncorrelation_id: cid-match\n' >"$DIR/results/CR.md"
make_fresh "$DIR"
run_subject "$OUT" "$ERR" "$DIR" 0
OK=1
if [ "$RUN_STATUS" -eq 0 ] \
    && grep -Fq 'status "OK"' "$OUT" \
    && grep -Fq 'updated=["ARCHI.md"]' "$OUT" \
    && grep -Fq 'cid-match' "$OUT"; then
    OK=0
fi
report_case "fresh matching OK evidence passes" "$OK" \
    "status=$RUN_STATUS stdout=$(head -c 240 "$OUT")"

# 2. An empty updated array is a valid, explicitly narrated no-op.
fixture
DIR="$FIXTURE_PATH"
write_evidence "$DIR" "OK" "nothing changed" "cid-noop" '[]'
printf 'PROMOTION_READY\ncorrelation_id: cid-noop\n' >"$DIR/results/CR.md"
make_fresh "$DIR"
run_subject "$OUT" "$ERR" "$DIR" 0
OK=1
if [ "$RUN_STATUS" -eq 0 ] \
    && grep -Fq 'updated=[] (no-op)' "$OUT"; then
    OK=0
fi
report_case "fresh empty update list passes as a no-op" "$OK" \
    "status=$RUN_STATUS stdout=$(head -c 240 "$OUT")"

# 3. Fresh ERROR evidence fails immediately instead of consuming its timeout.
fixture
DIR="$FIXTURE_PATH"
write_evidence "$DIR" "ERROR" "vault write failed" "cid-error" '[]'
make_fresh "$DIR"
run_subject_limited "$OUT" "$ERR" 3 "$DIR" 30
OK=1
if [ "$RUN_STATUS" -eq 1 ] \
    && grep -Fq 'status "ERROR"' "$OUT" \
    && grep -Fq 'note "vault write failed"' "$OUT"; then
    OK=0
fi
report_case "fresh ERROR evidence fails without waiting out the clock" "$OK" \
    "status=$RUN_STATUS stdout=$(head -c 240 "$OUT")"

# 4. Fresh evidence from another correlation id is rejected with both values.
fixture
DIR="$FIXTURE_PATH"
write_evidence "$DIR" "OK" "updated architecture" "evidence-cid" '["ARCHI.md"]'
printf 'PROMOTION_READY\ncorrelation_id: cr-cid\n' >"$DIR/results/CR.md"
make_fresh "$DIR"
run_subject "$OUT" "$ERR" "$DIR" 0
OK=1
if [ "$RUN_STATUS" -eq 1 ] \
    && grep -Fq 'cr-cid' "$OUT" \
    && grep -Fq 'evidence-cid' "$OUT"; then
    OK=0
fi
report_case "correlation mismatch names both ids" "$OK" \
    "status=$RUN_STATUS stdout=$(head -c 240 "$OUT")"

# 5. With no CR.md there is nothing to correlate against, so promotion is blocked.
fixture
DIR="$FIXTURE_PATH"
write_evidence "$DIR" "OK" "updated testing" "cid-without-cr" '["TESTING.md"]'
make_fresh "$DIR"
run_subject "$OUT" "$ERR" "$DIR" 0
OK=1
if [ "$RUN_STATUS" -eq 1 ] \
    && grep -Fq 'missing review result' "$OUT" \
    && grep -Fq "$DIR/results/CR.md" "$OUT"; then
    OK=0
fi
report_case "missing CR fails closed" "$OK" \
    "status=$RUN_STATUS stdout=$(head -c 240 "$OUT")"

# 6. A CR.md that declares no correlation_id is equally unverifiable.
fixture
DIR="$FIXTURE_PATH"
write_evidence "$DIR" "OK" "updated testing" "cid-without-cr-id" '["TESTING.md"]'
printf 'PROMOTION_READY\n' >"$DIR/results/CR.md"
make_fresh "$DIR"
run_subject "$OUT" "$ERR" "$DIR" 0
OK=1
if [ "$RUN_STATUS" -eq 1 ] \
    && grep -Fq 'has no correlation_id' "$OUT"; then
    OK=0
fi
report_case "CR without correlation_id fails closed" "$OK" \
    "status=$RUN_STATUS stdout=$(head -c 240 "$OUT")"

# 7. Missing evidence times out as never having appeared.
fixture
DIR="$FIXTURE_PATH"
touch -d '@1000000000' "$DIR/state/pipeline-review.stamp"
run_subject "$OUT" "$ERR" "$DIR" 1
OK=1
if [ "$RUN_STATUS" -eq 1 ] \
    && grep -Fq 'timed out' "$OUT" \
    && grep -Fq 'never appeared' "$OUT"; then
    OK=0
fi
report_case "missing evidence times out distinctly" "$OK" \
    "status=$RUN_STATUS stdout=$(head -c 240 "$OUT")"

# 8. Evidence older than the review stamp remains stale until timeout.
fixture
DIR="$FIXTURE_PATH"
write_evidence "$DIR" "OK" "left over" "cid-stale" '["ARCHI.md"]'
touch -d '@1000000000' "$DIR/state/docs-sync.json"
touch -d '@1000000001' "$DIR/state/pipeline-review.stamp"
run_subject "$OUT" "$ERR" "$DIR" 1
OK=1
if [ "$RUN_STATUS" -eq 1 ] \
    && grep -Fq 'timed out' "$OUT" \
    && grep -Fq 'stale' "$OUT"; then
    OK=0
fi
report_case "stale evidence is not accepted" "$OK" \
    "status=$RUN_STATUS stdout=$(head -c 240 "$OUT")"

# 9. Fresh malformed evidence is rejected as invalid JSON.
fixture
DIR="$FIXTURE_PATH"
printf '{not-json\n' >"$DIR/state/docs-sync.json"
make_fresh "$DIR"
run_subject "$OUT" "$ERR" "$DIR" 30
OK=1
if [ "$RUN_STATUS" -eq 1 ] \
    && grep -Fq 'not valid JSON' "$OUT" \
    && grep -Fq "$DIR/state/docs-sync.json" "$OUT"; then
    OK=0
fi
report_case "invalid JSON evidence fails immediately" "$OK" \
    "status=$RUN_STATUS stdout=$(head -c 240 "$OUT")"

# 10. Without the review stamp there is no trustworthy freshness baseline.
fixture
DIR="$FIXTURE_PATH"
write_evidence "$DIR" "OK" "updated architecture" "cid-no-stamp" '["ARCHI.md"]'
run_subject "$OUT" "$ERR" "$DIR" 30
OK=1
if [ "$RUN_STATUS" -eq 1 ] \
    && grep -Fq 'missing review stamp' "$OUT" \
    && grep -Fq 'pipeline-review.stamp' "$OUT"; then
    OK=0
fi
report_case "missing review stamp fails closed" "$OK" \
    "status=$RUN_STATUS stdout=$(head -c 240 "$OUT")"

# 11. Wrong argument counts are invalid invocations.
run_subject "$OUT" "$ERR"
ZERO_STATUS=$RUN_STATUS
fixture
DIR="$FIXTURE_PATH"
run_subject "$OUT" "$ERR" "$DIR" 0 extra
THREE_STATUS=$RUN_STATUS
OK=1
if [ "$ZERO_STATUS" -eq 64 ] && [ "$THREE_STATUS" -eq 64 ]; then
    OK=0
fi
report_case "wrong argument count exits 64" "$OK" \
    "zero-args=$ZERO_STATUS three-args=$THREE_STATUS"

# 12. A timeout must be a non-negative integer.
fixture
DIR="$FIXTURE_PATH"
run_subject "$OUT" "$ERR" "$DIR" not-a-number
OK=1
if [ "$RUN_STATUS" -eq 64 ] && grep -Fq 'usage:' "$ERR"; then
    OK=0
fi
report_case "non-numeric timeout exits 64" "$OK" \
    "status=$RUN_STATUS stderr=$(head -c 240 "$ERR")"

printf '%d/%d cases passed\n' "$TESTS_PASSED" "$TESTS_RUN"
[ "$TESTS_PASSED" -eq "$TESTS_RUN" ]
