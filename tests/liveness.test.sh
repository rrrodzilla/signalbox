#!/usr/bin/env bash
# Self-contained test runner for bin/_liveness.sh. No framework; every file
# fixture lives under mktemp -d, and every helper process is registered for
# cleanup. Prints PASS/FAIL per case and exits non-zero when any case failed.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUBJECT="$ROOT/bin/_liveness.sh"
FIXTURES=()
CHILD_PIDS=()
TESTS_RUN=0
TESTS_PASSED=0
RUN_STATUS=0
FIXTURE_PATH=""
SPAWNED_PID=""

cleanup() {
    local PID_VALUE FIXTURE
    for PID_VALUE in "${CHILD_PIDS[@]}"; do
        kill "$PID_VALUE" 2>/dev/null || true
        wait "$PID_VALUE" 2>/dev/null || true
    done
    for FIXTURE in "${FIXTURES[@]}"; do
        rm -rf -- "$FIXTURE"
    done
}
trap cleanup EXIT

fixture() {
    local DIR
    DIR="$(mktemp -d)"
    FIXTURES+=("$DIR")
    FIXTURE_PATH="$DIR"
}

spawn_child() {
    sleep 60 &
    SPAWNED_PID=$!
    CHILD_PIDS+=("$SPAWNED_PID")
}

run_function() {
    local STDOUT_FILE="$1"
    local STDERR_FILE="$2"
    shift 2
    "$@" >"$STDOUT_FILE" 2>"$STDERR_FILE"
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

# shellcheck source=../bin/_liveness.sh
source "$SUBJECT"

fixture
CAPTURE_DIR="$FIXTURE_PATH"
OUT="$CAPTURE_DIR/stdout"
ERR="$CAPTURE_DIR/stderr"

spawn_child
LIVE_PID="$SPAWNED_PID"
spawn_child
DEAD_PID="$SPAWNED_PID"
kill "$DEAD_PID" 2>/dev/null || true
wait "$DEAD_PID" 2>/dev/null || true

# 1. A running child is alive.
run_function "$OUT" "$ERR" pid_alive "$LIVE_PID"
OK=1
[ "$RUN_STATUS" -eq 0 ] && [ ! -s "$OUT" ] && [ ! -s "$ERR" ] && OK=0
report_case "pid_alive accepts a live child" "$OK" \
    "status=$RUN_STATUS stdout=$(head -c 200 "$OUT") stderr=$(head -c 200 "$ERR")"

# 2. A child that has exited and been reaped is dead.
run_function "$OUT" "$ERR" pid_alive "$DEAD_PID"
OK=1
[ "$RUN_STATUS" -eq 1 ] && [ ! -s "$OUT" ] && [ ! -s "$ERR" ] && OK=0
report_case "pid_alive rejects a reaped child" "$OK" \
    "status=$RUN_STATUS stdout=$(head -c 200 "$OUT") stderr=$(head -c 200 "$ERR")"

# 3. A non-numeric argument is malformed.
run_function "$OUT" "$ERR" pid_alive "not-a-pid"
OK=1
[ "$RUN_STATUS" -eq 1 ] && [ ! -s "$OUT" ] && [ ! -s "$ERR" ] && OK=0
report_case "pid_alive rejects a non-numeric argument" "$OK" \
    "status=$RUN_STATUS stdout=$(head -c 200 "$OUT") stderr=$(head -c 200 "$ERR")"

# 4. PID zero is not a valid process subject.
run_function "$OUT" "$ERR" pid_alive 0
OK=1
[ "$RUN_STATUS" -eq 1 ] && [ ! -s "$OUT" ] && [ ! -s "$ERR" ] && OK=0
report_case "pid_alive rejects zero" "$OK" \
    "status=$RUN_STATUS stdout=$(head -c 200 "$OUT") stderr=$(head -c 200 "$ERR")"

# 5. A live child has a boot-and-start identity made only of digits.
run_function "$OUT" "$ERR" proc_identity "$LIVE_PID"
LIVE_ID="$(<"$OUT")"
OK=1
if [ "$RUN_STATUS" -eq 0 ] \
    && [[ "$LIVE_ID" =~ ^[0-9]+:[0-9]+$ ]] \
    && [ ! -s "$ERR" ]; then
    OK=0
fi
report_case "proc_identity prints a live child's identity" "$OK" \
    "status=$RUN_STATUS stdout=$(head -c 200 "$OUT") stderr=$(head -c 200 "$ERR")"

# 6. A PID above Linux's supported range cannot be answered by /proc.
run_function "$OUT" "$ERR" proc_identity 99999999
OK=1
[ "$RUN_STATUS" -eq 1 ] && [ ! -s "$OUT" ] && [ ! -s "$ERR" ] && OK=0
report_case "proc_identity rejects a bogus pid without output" "$OK" \
    "status=$RUN_STATUS stdout=$(head -c 200 "$OUT") stderr=$(head -c 200 "$ERR")"

# 7. Matching PID and start identity name the same live owner.
run_function "$OUT" "$ERR" owner_live "$LIVE_PID" "$LIVE_ID"
OK=1
[ "$RUN_STATUS" -eq 0 ] && [ ! -s "$OUT" ] && [ ! -s "$ERR" ] && OK=0
report_case "owner_live accepts a matching live identity" "$OK" \
    "status=$RUN_STATUS stdout=$(head -c 200 "$OUT") stderr=$(head -c 200 "$ERR")"

# 8. Missing historical identity conservatively falls back to PID liveness.
run_function "$OUT" "$ERR" owner_live "$LIVE_PID" ""
OK=1
[ "$RUN_STATUS" -eq 0 ] && [ ! -s "$OUT" ] && [ ! -s "$ERR" ] && OK=0
report_case "owner_live accepts a live pid with empty identity" "$OK" \
    "status=$RUN_STATUS stdout=$(head -c 200 "$OUT") stderr=$(head -c 200 "$ERR")"

# 9. A deliberately different start identity rejects PID reuse.
run_function "$OUT" "$ERR" owner_live "$LIVE_PID" "${LIVE_ID}9"
OK=1
[ "$RUN_STATUS" -eq 1 ] && [ ! -s "$OUT" ] && [ ! -s "$ERR" ] && OK=0
report_case "owner_live rejects a wrong live identity" "$OK" \
    "status=$RUN_STATUS stdout=$(head -c 200 "$OUT") stderr=$(head -c 200 "$ERR")"

# 10. Identity cannot make a dead PID live.
run_function "$OUT" "$ERR" owner_live "$DEAD_PID" ""
OK=1
[ "$RUN_STATUS" -eq 1 ] && [ ! -s "$OUT" ] && [ ! -s "$ERR" ] && OK=0
report_case "owner_live rejects a dead pid" "$OK" \
    "status=$RUN_STATUS stdout=$(head -c 200 "$OUT") stderr=$(head -c 200 "$ERR")"

# 11. The run scan emits only live metadata and skips malformed JSON.
fixture
RUNS_DIR="$FIXTURE_PATH/runs"
LIVE_LAUNCH="$RUNS_DIR/live/launch.json"
DEAD_LAUNCH="$RUNS_DIR/dead/launch.json"
BAD_LAUNCH="$RUNS_DIR/bad/launch.json"
mkdir -p "$(dirname "$LIVE_LAUNCH")" "$(dirname "$DEAD_LAUNCH")" "$(dirname "$BAD_LAUNCH")"
jq -n \
    --arg slug "live-run" \
    --argjson pid "$LIVE_PID" \
    --arg start_id "$LIVE_ID" \
    --arg phase "pipeline" \
    '{slug: $slug, pid: $pid, start_id: $start_id, phase: $phase}' >"$LIVE_LAUNCH"
jq -n \
    --arg slug "dead-run" \
    --argjson pid "$DEAD_PID" \
    --arg start_id "" \
    --arg phase "review" \
    '{slug: $slug, pid: $pid, start_id: $start_id, phase: $phase}' >"$DEAD_LAUNCH"
printf '{invalid json\n' >"$BAD_LAUNCH"
run_function "$OUT" "$ERR" live_runs "$RUNS_DIR"
EXPECTED_OUTPUT=$'live-run\t'"$LIVE_PID"$'\tpipeline'
EXPECTED_WARNING="warning: invalid launch metadata: $BAD_LAUNCH"
ACTUAL_OUTPUT="$(<"$OUT")"
ACTUAL_WARNING="$(<"$ERR")"
OK=1
if [ "$RUN_STATUS" -eq 0 ] \
    && [ "$ACTUAL_OUTPUT" = "$EXPECTED_OUTPUT" ] \
    && [ "$ACTUAL_WARNING" = "$EXPECTED_WARNING" ]; then
    OK=0
fi
report_case "live_runs emits one live run and warns about bad metadata" "$OK" \
    "status=$RUN_STATUS stdout=$(head -c 200 "$OUT") stderr=$(head -c 200 "$ERR")"

# 12. A missing runs directory is an empty successful scan.
fixture
MISSING_RUNS="$FIXTURE_PATH/missing"
run_function "$OUT" "$ERR" live_runs "$MISSING_RUNS"
OK=1
[ "$RUN_STATUS" -eq 0 ] && [ ! -s "$OUT" ] && [ ! -s "$ERR" ] && OK=0
report_case "live_runs treats a nonexistent directory as empty" "$OK" \
    "status=$RUN_STATUS stdout=$(head -c 200 "$OUT") stderr=$(head -c 200 "$ERR")"

printf '%d/%d cases passed\n' "$TESTS_PASSED" "$TESTS_RUN"
[ "$TESTS_PASSED" -eq "$TESTS_RUN" ]
