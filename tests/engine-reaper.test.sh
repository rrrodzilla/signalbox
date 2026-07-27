#!/usr/bin/env bash
# Self-contained test runner for bin/engine-reaper.sh. No framework; every
# fixture is built in its own mktemp -d and cleaned by the EXIT trap. Deliberately
# omits `-e` so expected subject failures can be captured and asserted. Prints
# one PASS/FAIL line per case and exits non-zero when any case failed.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUBJECT="$ROOT/bin/engine-reaper.sh"
FIXTURES=()
TESTS_RUN=0
TESTS_PASSED=0
RUN_STATUS=0
FIXTURE_PATH=""
VICTIM_PID=""
VICTIM_START=""

cleanup() {
    local FIXTURE
    if [ -n "$VICTIM_PID" ]; then
        kill -TERM "$VICTIM_PID" 2>/dev/null || true
        wait "$VICTIM_PID" 2>/dev/null || true
    fi
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

# Field 22 of /proc/<pid>/stat, read the same way the subject reads it: the
# leading pid and parenthesized comm are stripped through the last ") ".
proc_starttime() {
    awk '{ sub(/^.*\) /, ""); print $20 }' "/proc/$1/stat" 2>/dev/null
}

start_victim() {
    sleep 300 &
    VICTIM_PID=$!
    VICTIM_START="$(proc_starttime "$VICTIM_PID")"
}

finish_victim() {
    kill -TERM "$VICTIM_PID" 2>/dev/null || true
    wait "$VICTIM_PID" 2>/dev/null || true
    VICTIM_PID=""
    VICTIM_START=""
}

run_subject() {
    local STDOUT_FILE="$1"
    local STDERR_FILE="$2"
    shift 2
    "$SUBJECT" "$@" >"$STDOUT_FILE" 2>"$STDERR_FILE"
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

# 1. A fresh watch file ends polling and the live victim is terminated.
fixture
DIR="$FIXTURE_PATH"
OUT="$DIR/stdout"
ERR="$DIR/stderr"
STAMP="$DIR/stamp"
WATCH="$DIR/watch"
PID_FILE="$DIR/engine.pid"
touch "$STAMP"
start_victim
printf '%s\n' "$VICTIM_PID" >"$PID_FILE"
(sleep 1; touch "$WATCH") &
TOUCH_PID=$!
run_subject "$OUT" "$ERR" "$VICTIM_PID" "$PID_FILE" "$WATCH" "$STAMP" 10 "$VICTIM_START"
wait "$TOUCH_PID" 2>/dev/null || true
OK=1
if [ "$RUN_STATUS" -eq 0 ] \
    && ! kill -0 "$VICTIM_PID" 2>/dev/null \
    && [ ! -e "$PID_FILE" ] \
    && grep -q "watch file landed" "$ERR"; then
    OK=0
fi
report_case "fresh watch file terminates victim and removes pid file" "$OK" \
    "status=$RUN_STATUS stderr=$(head -c 200 "$ERR")"
finish_victim

# 2. A missing watch file reaches its short deadline without an unbounded wait.
fixture
DIR="$FIXTURE_PATH"
OUT="$DIR/stdout"
ERR="$DIR/stderr"
STAMP="$DIR/stamp"
WATCH="$DIR/watch"
PID_FILE="$DIR/engine.pid"
touch "$STAMP"
start_victim
printf '%s\n' "$VICTIM_PID" >"$PID_FILE"
START="$SECONDS"
run_subject "$OUT" "$ERR" "$VICTIM_PID" "$PID_FILE" "$WATCH" "$STAMP" 2 "$VICTIM_START"
ELAPSED=$((SECONDS - START))
OK=1
if [ "$RUN_STATUS" -eq 0 ] \
    && ! kill -0 "$VICTIM_PID" 2>/dev/null \
    && [ ! -e "$PID_FILE" ] \
    && [ "$ELAPSED" -ge 2 ] \
    && [ "$ELAPSED" -le 6 ] \
    && grep -q "deadline elapsed" "$ERR"; then
    OK=0
fi
report_case "missing watch file stops victim at deadline" "$OK" \
    "status=$RUN_STATUS elapsed=${ELAPSED}s stderr=$(head -c 200 "$ERR")"
finish_victim

# 3. An older watch file is not fresh and therefore waits for the deadline.
fixture
DIR="$FIXTURE_PATH"
OUT="$DIR/stdout"
ERR="$DIR/stderr"
STAMP="$DIR/stamp"
WATCH="$DIR/watch"
PID_FILE="$DIR/engine.pid"
touch "$WATCH"
sleep 1
touch "$STAMP"
start_victim
printf '%s\n' "$VICTIM_PID" >"$PID_FILE"
START="$SECONDS"
run_subject "$OUT" "$ERR" "$VICTIM_PID" "$PID_FILE" "$WATCH" "$STAMP" 1 "$VICTIM_START"
ELAPSED=$((SECONDS - START))
OK=1
if [ "$RUN_STATUS" -eq 0 ] \
    && ! kill -0 "$VICTIM_PID" 2>/dev/null \
    && [ ! -e "$PID_FILE" ] \
    && [ "$ELAPSED" -ge 1 ] \
    && grep -q "deadline elapsed" "$ERR" \
    && ! grep -q "watch file landed" "$ERR"; then
    OK=0
fi
report_case "older watch file follows deadline path" "$OK" \
    "status=$RUN_STATUS elapsed=${ELAPSED}s stderr=$(head -c 200 "$ERR")"
finish_victim

# 4. A victim already dead on entry is a quiet successful cleanup.
fixture
DIR="$FIXTURE_PATH"
OUT="$DIR/stdout"
ERR="$DIR/stderr"
WATCH="$DIR/watch"
STAMP="$DIR/stamp"
PID_FILE="$DIR/engine.pid"
start_victim
DEAD_PID="$VICTIM_PID"
DEAD_START="$VICTIM_START"
kill -TERM "$DEAD_PID" 2>/dev/null || true
wait "$DEAD_PID" 2>/dev/null || true
VICTIM_PID=""
VICTIM_START=""
printf '%s\n' "$DEAD_PID" >"$PID_FILE"
run_subject "$OUT" "$ERR" "$DEAD_PID" "$PID_FILE" "$WATCH" "$STAMP" 1 "$DEAD_START"
OK=1
if [ "$RUN_STATUS" -eq 0 ] \
    && [ ! -e "$PID_FILE" ] \
    && [ ! -s "$OUT" ] \
    && [ ! -s "$ERR" ]; then
    OK=0
fi
report_case "already-dead victim exits quietly and removes pid file" "$OK" \
    "status=$RUN_STATUS stderr=$(head -c 200 "$ERR")"

# 5. Wrong argument count is invalid invocation.
fixture
DIR="$FIXTURE_PATH"
OUT="$DIR/stdout"
ERR="$DIR/stderr"
run_subject "$OUT" "$ERR"
S0=$RUN_STATUS
run_subject "$OUT" "$ERR" 1 "$DIR/pid" "$DIR/watch" "$DIR/stamp" 1
S5=$RUN_STATUS
OK=1
[ "$S0" -eq 64 ] && [ "$S5" -eq 64 ] && OK=0
report_case "wrong argument count exits 64" "$OK" "zero-args=$S0 five-args=$S5"

# 6. A non-numeric PID is invalid invocation.
fixture
DIR="$FIXTURE_PATH"
OUT="$DIR/stdout"
ERR="$DIR/stderr"
run_subject "$OUT" "$ERR" nope "$DIR/pid" "$DIR/watch" "$DIR/stamp" 1 1
OK=1
[ "$RUN_STATUS" -eq 64 ] && OK=0
report_case "non-numeric pid exits 64" "$OK" "status=$RUN_STATUS"

# 7. A non-numeric deadline is invalid invocation.
fixture
DIR="$FIXTURE_PATH"
OUT="$DIR/stdout"
ERR="$DIR/stderr"
run_subject "$OUT" "$ERR" 1 "$DIR/pid" "$DIR/watch" "$DIR/stamp" nope 1
OK=1
[ "$RUN_STATUS" -eq 64 ] && OK=0
report_case "non-numeric deadline exits 64" "$OK" "status=$RUN_STATUS"

# 8. A non-numeric start time is invalid invocation: identity cannot be checked.
fixture
DIR="$FIXTURE_PATH"
OUT="$DIR/stdout"
ERR="$DIR/stderr"
run_subject "$OUT" "$ERR" 1 "$DIR/pid" "$DIR/watch" "$DIR/stamp" 1 nope
OK=1
[ "$RUN_STATUS" -eq 64 ] && OK=0
report_case "non-numeric start time exits 64" "$OK" "status=$RUN_STATUS"

# 9. A live PID whose start time does not match the transferred identity is a
# recycled number, not the engine: it must be left alone, not signalled.
fixture
DIR="$FIXTURE_PATH"
OUT="$DIR/stdout"
ERR="$DIR/stderr"
STAMP="$DIR/stamp"
WATCH="$DIR/watch"
PID_FILE="$DIR/engine.pid"
touch "$STAMP"
start_victim
printf '%s\n' "$VICTIM_PID" >"$PID_FILE"
run_subject "$OUT" "$ERR" "$VICTIM_PID" "$PID_FILE" "$WATCH" "$STAMP" 30 \
    $((VICTIM_START + 1))
OK=1
if [ "$RUN_STATUS" -eq 0 ] \
    && kill -0 "$VICTIM_PID" 2>/dev/null \
    && [ ! -e "$PID_FILE" ] \
    && [ ! -s "$OUT" ] \
    && [ ! -s "$ERR" ]; then
    OK=0
fi
report_case "recycled pid with a foreign start time is never signalled" "$OK" \
    "status=$RUN_STATUS stderr=$(head -c 200 "$ERR")"
finish_victim

printf '%d/%d cases passed\n' "$TESTS_PASSED" "$TESTS_RUN"
[ "$TESTS_PASSED" -eq "$TESTS_RUN" ]
