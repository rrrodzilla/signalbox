#!/usr/bin/env bash
# Self-contained test runner for bin/terminal-record.sh. No framework; every
# fixture is built in its own mktemp -d and removed by an EXIT trap. Deliberately
# omits set -e so expected subject failures can be captured and asserted.
# Prints PASS/FAIL per case and exits non-zero when any case failed.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUBJECT="$ROOT/bin/terminal-record.sh"
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
    FIXTURE_PATH="$DIR"
}

run_subject() {
    local INPUT_FILE="$1"
    local STDOUT_FILE="$2"
    local STDERR_FILE="$3"
    shift 3
    "$SUBJECT" "$@" <"$INPUT_FILE" >"$STDOUT_FILE" 2>"$STDERR_FILE"
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
INPUT="$(mktemp)"
FIXTURES+=("$OUT" "$ERR" "$INPUT")

# 1. A complete terminal carries all scalar fields and forces outcome to null.
fixture
DIR="$FIXTURE_PATH"
printf '%s' \
    '{"issue":4,"phase":"promote","parked":true,"reason":"merged","correlation_id":"c1"}' \
    >"$INPUT"
run_subject "$INPUT" "$OUT" "$ERR" complete "$DIR"
ACTUAL="$(jq -r \
    '[.terminal, (.issue | tostring), .phase, (.parked | tostring),
      (.outcome | tostring), .reason, .correlation_id] | @tsv' \
    "$DIR/state/complete.json" 2>/dev/null)"
EXPECTED=$'complete\t4\tpromote\ttrue\tnull\tmerged\tc1'
OK=1
if [ "$RUN_STATUS" -eq 0 ] && [ "$ACTUAL" = "$EXPECTED" ]; then
    OK=0
fi
report_case "complete records carried fields and parked true" "$OK" \
    "status=$RUN_STATUS actual=$ACTUAL"

# 2. A missing parked key defaults to false.
fixture
DIR="$FIXTURE_PATH"
printf '%s' \
    '{"issue":4,"phase":"promote","reason":"merged","correlation_id":"c2"}' \
    >"$INPUT"
run_subject "$INPUT" "$OUT" "$ERR" complete "$DIR"
ACTUAL="$(jq -r '.parked' "$DIR/state/complete.json" 2>/dev/null)"
OK=1
if [ "$RUN_STATUS" -eq 0 ] && [ "$ACTUAL" = "false" ]; then
    OK=0
fi
report_case "complete defaults missing parked to false" "$OK" \
    "status=$RUN_STATUS parked=$ACTUAL"

# 3. A halted terminal carries outcome and always records parked false.
fixture
DIR="$FIXTURE_PATH"
printf '%s' \
    '{"issue":4,"phase":"review","outcome":"TIMEOUT","reason":"stale CR","correlation_id":"c3"}' \
    >"$INPUT"
run_subject "$INPUT" "$OUT" "$ERR" halted "$DIR"
ACTUAL="$(jq -r \
    '[.terminal, (.issue | tostring), .phase, (.parked | tostring),
      .outcome, .reason, .correlation_id] | @tsv' \
    "$DIR/state/halted.json" 2>/dev/null)"
EXPECTED=$'halted\t4\treview\tfalse\tTIMEOUT\tstale CR\tc3'
OK=1
if [ "$RUN_STATUS" -eq 0 ] && [ "$ACTUAL" = "$EXPECTED" ]; then
    OK=0
fi
report_case "halted records outcome and parked false" "$OK" \
    "status=$RUN_STATUS actual=$ACTUAL"

# 4. The complete input object is retained without dropping extra fields.
fixture
DIR="$FIXTURE_PATH"
printf '%s' \
    '{"issue":9,"phase":"review","parked":true,"reason":"approval","correlation_id":"c4","extra":{"nested":[1,2]},"flag":false}' \
    >"$INPUT"
run_subject "$INPUT" "$OUT" "$ERR" complete "$DIR"
ACTUAL="$(jq -r \
    '.payload == {
        issue: 9,
        phase: "review",
        parked: true,
        reason: "approval",
        correlation_id: "c4",
        extra: {nested: [1, 2]},
        flag: false
    }' \
    "$DIR/state/complete.json" 2>/dev/null)"
OK=1
if [ "$RUN_STATUS" -eq 0 ] && [ "$ACTUAL" = "true" ]; then
    OK=0
fi
report_case "full original payload is preserved" "$OK" \
    "status=$RUN_STATUS payload-equal=$ACTUAL"

# 5. Malformed input still produces terminal evidence with safe scalar defaults.
fixture
DIR="$FIXTURE_PATH"
printf '%s' 'not json at all' >"$INPUT"
run_subject "$INPUT" "$OUT" "$ERR" halted "$DIR"
ACTUAL="$(jq -r \
    '[.terminal, (.issue | tostring), (.phase | tostring),
      (.parked | tostring), (.outcome | tostring), (.reason | tostring),
      (.correlation_id | tostring), .payload.raw] | @tsv' \
    "$DIR/state/halted.json" 2>/dev/null)"
EXPECTED=$'halted\tnull\tnull\tfalse\tnull\tnull\tnull\tnot json at all'
OK=1
if [ "$RUN_STATUS" -eq 0 ] && [ "$ACTUAL" = "$EXPECTED" ]; then
    OK=0
fi
report_case "malformed input is preserved and exits zero" "$OK" \
    "status=$RUN_STATUS actual=$ACTUAL"

# 6. Empty stdin follows the same recoverable fallback path.
fixture
DIR="$FIXTURE_PATH"
: >"$INPUT"
run_subject "$INPUT" "$OUT" "$ERR" complete "$DIR"
ACTUAL="$(jq -r \
    '[.terminal, (.issue | tostring), (.phase | tostring),
      (.parked | tostring), (.outcome | tostring), (.reason | tostring),
      (.correlation_id | tostring), (.payload.raw == "")] | @tsv' \
    "$DIR/state/complete.json" 2>/dev/null)"
EXPECTED=$'complete\tnull\tnull\tfalse\tnull\tnull\tnull\ttrue'
OK=1
if [ "$RUN_STATUS" -eq 0 ] && [ "$ACTUAL" = "$EXPECTED" ]; then
    OK=0
fi
report_case "empty stdin is preserved and exits zero" "$OK" \
    "status=$RUN_STATUS actual=$ACTUAL"

# 7. Zero and three arguments are rejected before anything is written.
fixture
DIR="$FIXTURE_PATH"
: >"$INPUT"
(
    cd "$DIR" || exit 1
    "$SUBJECT" <"$INPUT" >"$OUT" 2>"$ERR"
)
ZERO_STATUS=$?
run_subject "$INPUT" "$OUT" "$ERR" complete "$DIR" extra
THREE_STATUS=$RUN_STATUS
shopt -s dotglob nullglob
ENTRIES=("$DIR"/*)
shopt -u dotglob nullglob
OK=1
if [ "$ZERO_STATUS" -eq 64 ] \
    && [ "$THREE_STATUS" -eq 64 ] \
    && [ "${#ENTRIES[@]}" -eq 0 ]; then
    OK=0
fi
report_case "wrong argument counts exit 64 without writing" "$OK" \
    "zero-args=$ZERO_STATUS three-args=$THREE_STATUS entries=${#ENTRIES[@]}"

# 8. Unknown enum-like terminal kinds are rejected without writing.
fixture
DIR="$FIXTURE_PATH"
printf '%s' '{}' >"$INPUT"
run_subject "$INPUT" "$OUT" "$ERR" finished "$DIR"
shopt -s dotglob nullglob
ENTRIES=("$DIR"/*)
shopt -u dotglob nullglob
OK=1
if [ "$RUN_STATUS" -eq 64 ] && [ "${#ENTRIES[@]}" -eq 0 ]; then
    OK=0
fi
report_case "unknown terminal kind exits 64 without writing" "$OK" \
    "status=$RUN_STATUS entries=${#ENTRIES[@]}"

# 9. The recorder creates a missing state directory.
fixture
DIR="$FIXTURE_PATH"
printf '%s' \
    '{"issue":5,"phase":"promote","parked":false,"reason":"merged","correlation_id":"c5"}' \
    >"$INPUT"
run_subject "$INPUT" "$OUT" "$ERR" complete "$DIR"
ACTUAL="$(jq -r '.terminal' "$DIR/state/complete.json" 2>/dev/null)"
OK=1
if [ "$RUN_STATUS" -eq 0 ] \
    && [ -d "$DIR/state" ] \
    && [ "$ACTUAL" = "complete" ]; then
    OK=0
fi
report_case "missing state directory is created" "$OK" \
    "status=$RUN_STATUS terminal=$ACTUAL"

# 10. Atomic replacement leaves only the final artifact and no temp files.
fixture
DIR="$FIXTURE_PATH"
printf '%s' \
    '{"issue":6,"phase":"review","parked":false,"reason":"first","correlation_id":"c6"}' \
    >"$INPUT"
run_subject "$INPUT" "$OUT" "$ERR" complete "$DIR"
FIRST_STATUS=$RUN_STATUS
printf '%s' \
    '{"issue":6,"phase":"promote","parked":false,"reason":"second","correlation_id":"c6"}' \
    >"$INPUT"
run_subject "$INPUT" "$OUT" "$ERR" complete "$DIR"
SECOND_STATUS=$RUN_STATUS
shopt -s dotglob nullglob
ENTRIES=("$DIR/state"/*)
shopt -u dotglob nullglob
ACTUAL="$(jq -r '[.phase, .reason] | @tsv' \
    "$DIR/state/complete.json" 2>/dev/null)"
OK=1
if [ "$FIRST_STATUS" -eq 0 ] \
    && [ "$SECOND_STATUS" -eq 0 ] \
    && [ "${#ENTRIES[@]}" -eq 1 ] \
    && [ "${ENTRIES[0]}" = "$DIR/state/complete.json" ] \
    && [ "$ACTUAL" = $'promote\tsecond' ]; then
    OK=0
fi
report_case "rerun atomically replaces without temp files" "$OK" \
    "statuses=$FIRST_STATUS/$SECOND_STATUS entries=${#ENTRIES[@]} actual=$ACTUAL"

# 11. A successful sink invocation never writes narration to stdout.
fixture
DIR="$FIXTURE_PATH"
printf '%s' \
    '{"issue":7,"phase":"promote","parked":false,"reason":"merged","correlation_id":"c7"}' \
    >"$INPUT"
run_subject "$INPUT" "$OUT" "$ERR" complete "$DIR"
OK=1
if [ "$RUN_STATUS" -eq 0 ] && [ ! -s "$OUT" ]; then
    OK=0
fi
report_case "success path leaves stdout empty" "$OK" \
    "status=$RUN_STATUS stdout-bytes=$(wc -c <"$OUT")"

printf '%d/%d cases passed\n' "$TESTS_PASSED" "$TESTS_RUN"
[ "$TESTS_PASSED" -eq "$TESTS_RUN" ]
