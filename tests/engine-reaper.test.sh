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

start_victim() {
    sleep 300 &
    VICTIM_PID=$!
}

finish_victim() {
    kill -TERM "$VICTIM_PID" 2>/dev/null || true
    wait "$VICTIM_PID" 2>/dev/null || true
    VICTIM_PID=""
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
run_subject "$OUT" "$ERR" "$VICTIM_PID" "$PID_FILE" "$WATCH" "$STAMP" 10
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
run_subject "$OUT" "$ERR" "$VICTIM_PID" "$PID_FILE" "$WATCH" "$STAMP" 2
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
run_subject "$OUT" "$ERR" "$VICTIM_PID" "$PID_FILE" "$WATCH" "$STAMP" 1
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
kill -TERM "$DEAD_PID" 2>/dev/null || true
wait "$DEAD_PID" 2>/dev/null || true
VICTIM_PID=""
printf '%s\n' "$DEAD_PID" >"$PID_FILE"
run_subject "$OUT" "$ERR" "$DEAD_PID" "$PID_FILE" "$WATCH" "$STAMP" 1
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
run_subject "$OUT" "$ERR" 1 "$DIR/pid" "$DIR/watch" "$DIR/stamp"
S4=$RUN_STATUS
OK=1
[ "$S0" -eq 64 ] && [ "$S4" -eq 64 ] && OK=0
report_case "wrong argument count exits 64" "$OK" "zero-args=$S0 four-args=$S4"

# 6. A non-numeric PID is invalid invocation.
fixture
DIR="$FIXTURE_PATH"
OUT="$DIR/stdout"
ERR="$DIR/stderr"
run_subject "$OUT" "$ERR" nope "$DIR/pid" "$DIR/watch" "$DIR/stamp" 1
OK=1
[ "$RUN_STATUS" -eq 64 ] && OK=0
report_case "non-numeric pid exits 64" "$OK" "status=$RUN_STATUS"

# 7. A non-numeric deadline is invalid invocation.
fixture
DIR="$FIXTURE_PATH"
OUT="$DIR/stdout"
ERR="$DIR/stderr"
run_subject "$OUT" "$ERR" 1 "$DIR/pid" "$DIR/watch" "$DIR/stamp" nope
OK=1
[ "$RUN_STATUS" -eq 64 ] && OK=0
report_case "non-numeric deadline exits 64" "$OK" "status=$RUN_STATUS"

printf '%d/%d cases passed\n' "$TESTS_PASSED" "$TESTS_RUN"
[ "$TESTS_PASSED" -eq "$TESTS_RUN" ]
