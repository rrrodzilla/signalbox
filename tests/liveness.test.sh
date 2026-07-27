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

# 13. Well-formed JSON carrying wrong field types or values is invalid
# metadata, not something to coerce into a plausible-looking row.
fixture
TYPED_RUNS="$FIXTURE_PATH/runs"
OBJECT_SLUG="$TYPED_RUNS/a-object-slug/launch.json"
ARRAY_PHASE="$TYPED_RUNS/b-array-phase/launch.json"
TEXT_PID="$TYPED_RUNS/c-text-pid/launch.json"
ZERO_PID="$TYPED_RUNS/d-zero-pid/launch.json"
NUMBER_START="$TYPED_RUNS/e-number-start/launch.json"
LIST_RECORD="$TYPED_RUNS/f-list-record/launch.json"
mkdir -p \
    "$(dirname "$OBJECT_SLUG")" "$(dirname "$ARRAY_PHASE")" \
    "$(dirname "$TEXT_PID")" "$(dirname "$ZERO_PID")" \
    "$(dirname "$NUMBER_START")" "$(dirname "$LIST_RECORD")"
jq -n --argjson pid "$LIVE_PID" \
    '{slug: {name: "live-run"}, pid: $pid, start_id: "", phase: "pipeline"}' \
    >"$OBJECT_SLUG"
jq -n --argjson pid "$LIVE_PID" \
    '{slug: "live-run", pid: $pid, start_id: "", phase: ["pipeline"]}' \
    >"$ARRAY_PHASE"
jq -n '{slug: "live-run", pid: "not-a-pid", start_id: "", phase: "pipeline"}' \
    >"$TEXT_PID"
jq -n '{slug: "live-run", pid: 0, start_id: "", phase: "pipeline"}' \
    >"$ZERO_PID"
jq -n --argjson pid "$LIVE_PID" \
    '{slug: "live-run", pid: $pid, start_id: 12345, phase: "pipeline"}' \
    >"$NUMBER_START"
jq -n --argjson pid "$LIVE_PID" \
    '[{slug: "live-run", pid: $pid, start_id: "", phase: "pipeline"}]' \
    >"$LIST_RECORD"
run_function "$OUT" "$ERR" live_runs "$TYPED_RUNS"
# Pathname expansion is sorted, so the warnings follow the directory names.
EXPECTED_WARNINGS="$(printf 'warning: invalid launch metadata: %s\n' \
    "$OBJECT_SLUG" "$ARRAY_PHASE" "$TEXT_PID" "$ZERO_PID" "$NUMBER_START" \
    "$LIST_RECORD")"
ACTUAL_WARNING="$(<"$ERR")"
OK=1
if [ "$RUN_STATUS" -eq 0 ] \
    && [ ! -s "$OUT" ] \
    && [ "$ACTUAL_WARNING" = "$EXPECTED_WARNINGS" ]; then
    OK=0
fi
report_case "live_runs warns about wrong field types instead of coercing" "$OK" \
    "status=$RUN_STATUS stdout=$(head -c 200 "$OUT") stderr=$(head -c 200 "$ERR")"

# 14. Validation stays tolerant of the shapes real metadata takes: a PID
# recorded as a digit string, and a record predating the start_id field.
fixture
TOLERANT_RUNS="$FIXTURE_PATH/runs"
STRING_PID="$TOLERANT_RUNS/string-pid/launch.json"
mkdir -p "$(dirname "$STRING_PID")"
jq -n --arg pid "$LIVE_PID" \
    '{slug: "live-run", pid: $pid, phase: "pipeline"}' >"$STRING_PID"
run_function "$OUT" "$ERR" live_runs "$TOLERANT_RUNS"
EXPECTED_OUTPUT=$'live-run\t'"$LIVE_PID"$'\tpipeline'
ACTUAL_OUTPUT="$(<"$OUT")"
OK=1
if [ "$RUN_STATUS" -eq 0 ] \
    && [ "$ACTUAL_OUTPUT" = "$EXPECTED_OUTPUT" ] \
    && [ ! -s "$ERR" ]; then
    OK=0
fi
report_case "live_runs accepts a string pid and absent start_id" "$OK" \
    "status=$RUN_STATUS stdout=$(head -c 200 "$OUT") stderr=$(head -c 200 "$ERR")"

# 15. A whole-number PID written in decimal or exponent form is normalised to
# plain digits: jq preserves the original literal, so an unfloored pid would
# reach pid_alive as "1234.0" and silently drop a live run.
fixture
NUMERIC_RUNS="$FIXTURE_PATH/runs"
DECIMAL_PID="$NUMERIC_RUNS/a-decimal-pid/launch.json"
EXPONENT_PID="$NUMERIC_RUNS/b-exponent-pid/launch.json"
mkdir -p "$(dirname "$DECIMAL_PID")" "$(dirname "$EXPONENT_PID")"
# Written literally rather than through jq, so the on-disk representation is
# the one under test rather than whatever jq would choose to emit.
printf '{"slug": "live-run", "pid": %s.0, "phase": "pipeline"}\n' \
    "$LIVE_PID" >"$DECIMAL_PID"
printf '{"slug": "live-run", "pid": %se0, "phase": "pipeline"}\n' \
    "$LIVE_PID" >"$EXPONENT_PID"
run_function "$OUT" "$ERR" live_runs "$NUMERIC_RUNS"
EXPECTED_OUTPUT="$(printf 'live-run\t%s\tpipeline\n' "$LIVE_PID" "$LIVE_PID")"
ACTUAL_OUTPUT="$(<"$OUT")"
OK=1
if [ "$RUN_STATUS" -eq 0 ] \
    && [ "$ACTUAL_OUTPUT" = "$EXPECTED_OUTPUT" ] \
    && [ ! -s "$ERR" ]; then
    OK=0
fi
report_case "live_runs normalises decimal and exponent pids" "$OK" \
    "status=$RUN_STATUS stdout=$(head -c 200 "$OUT") stderr=$(head -c 200 "$ERR")"

# 16. An unrecognised mode is refused before any lock file is created.
fixture
LOCK_ROOT="$FIXTURE_PATH"
LOCK_FILE="$LOCK_ROOT/.install.lock"
run_function "$OUT" "$ERR" install_lock "$LOCK_ROOT" sideways
OK=1
if [ "$RUN_STATUS" -eq 1 ] \
    && [ ! -s "$OUT" ] \
    && [ ! -e "$LOCK_FILE" ] \
    && grep -q 'shared or exclusive' "$ERR"; then
    OK=0
fi
report_case "install_lock refuses an unknown mode without creating a file" "$OK" \
    "status=$RUN_STATUS stdout=$(head -c 200 "$OUT") stderr=$(head -c 200 "$ERR")"

# 17. An exclusive hold blocks a second acquirer: this is what keeps a launcher
# from starting an engine between a reinstall's liveness scan and its rebuild.
# Taking it must also leave state/ alone — reinstall preserves that directory,
# so the installer's own coordination file may not appear inside it.
run_function "$OUT" "$ERR" install_lock "$LOCK_ROOT" exclusive
HELD_STATUS=$RUN_STATUS
CONTENDED=0
( flock -x -w 1 9 ) 9>>"$LOCK_FILE" || CONTENDED=1
OK=1
if [ "$HELD_STATUS" -eq 0 ] \
    && [ "$CONTENDED" -eq 1 ] \
    && [ -e "$LOCK_FILE" ] \
    && [ ! -e "$LOCK_ROOT/state" ] \
    && [ ! -s "$OUT" ] \
    && [ ! -s "$ERR" ]; then
    OK=0
fi
report_case "install_lock exclusive excludes a second holder without touching state/" "$OK" \
    "status=$HELD_STATUS contended=$CONTENDED stderr=$(head -c 200 "$ERR")"

# 18. Releasing hands the lock straight over; a stale hold would wedge every
# later reinstall.
run_function "$OUT" "$ERR" install_unlock
RELEASE_STATUS=$RUN_STATUS
ACQUIRED=0
( flock -x -w 1 9 ) 9>>"$LOCK_FILE" && ACQUIRED=1
OK=1
if [ "$RELEASE_STATUS" -eq 0 ] \
    && [ "$ACQUIRED" -eq 1 ] \
    && [ ! -s "$OUT" ] \
    && [ ! -s "$ERR" ]; then
    OK=0
fi
report_case "install_unlock releases the lock for the next holder" "$OK" \
    "status=$RELEASE_STATUS acquired=$ACQUIRED stderr=$(head -c 200 "$ERR")"

# 19. Launchers take the lock shared, so they never serialize against each
# other — only against a reinstall's exclusive hold.
run_function "$OUT" "$ERR" install_lock "$LOCK_ROOT" shared
SHARED_STATUS=$RUN_STATUS
SECOND_SHARED=0
( flock -s -w 1 9 ) 9>>"$LOCK_FILE" && SECOND_SHARED=1
BLOCKED_EXCLUSIVE=0
( flock -x -w 1 9 ) 9>>"$LOCK_FILE" || BLOCKED_EXCLUSIVE=1
install_unlock
OK=1
if [ "$SHARED_STATUS" -eq 0 ] \
    && [ "$SECOND_SHARED" -eq 1 ] \
    && [ "$BLOCKED_EXCLUSIVE" -eq 1 ]; then
    OK=0
fi
report_case "install_lock shared admits launchers and blocks a reinstall" "$OK" \
    "status=$SHARED_STATUS second-shared=$SECOND_SHARED blocked=$BLOCKED_EXCLUSIVE"

# 20. A contended acquisition gives up after SIGNALBOX_LOCK_WAIT rather than
# hanging an operator's terminal for ever.
HOLDER_READY="$LOCK_ROOT/holder.ready"
( exec 9>>"$LOCK_FILE"; flock -x 9; : >"$HOLDER_READY"; sleep 60 ) &
HOLDER_PID=$!
CHILD_PIDS+=("$HOLDER_PID")
for _ in $(seq 1 100); do
    [ -e "$HOLDER_READY" ] && break
    sleep 0.1
done
SIGNALBOX_LOCK_WAIT=1 run_function "$OUT" "$ERR" install_lock "$LOCK_ROOT" exclusive
TIMEOUT_STATUS=$RUN_STATUS
install_unlock
OK=1
if [ "$TIMEOUT_STATUS" -eq 1 ] \
    && [ ! -s "$OUT" ] \
    && grep -q 'timed out' "$ERR"; then
    OK=0
fi
report_case "install_lock times out instead of waiting for ever" "$OK" \
    "status=$TIMEOUT_STATUS stderr=$(head -c 200 "$ERR")"
kill "$HOLDER_PID" 2>/dev/null || true
wait "$HOLDER_PID" 2>/dev/null || true

printf '%d/%d cases passed\n' "$TESTS_PASSED" "$TESTS_RUN"
[ "$TESTS_PASSED" -eq "$TESTS_RUN" ]
