#!/usr/bin/env bash
# Self-contained test runner for bin/check-placeholders.sh. No framework, no
# dependencies beyond coreutils; every fixture is built in its own mktemp -d
# (never the repository's own TOMLs, whose templates legitimately carry live
# __SIGNALBOX_ROOT__ tokens and would correctly fail). Prints PASS/FAIL per
# case and exits non-zero when any case failed.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUBJECT="$ROOT/bin/check-placeholders.sh"
FIXTURES=()
TESTS_RUN=0
TESTS_PASSED=0
RUN_STATUS=0

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
    printf '%s\n' "$DIR"
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

OUT="$(mktemp)" ERR="$(mktemp)"
FIXTURES+=("$OUT" "$ERR")

# 1. Pristine rendered dir: prose comment mentions the tokens, values rendered.
DIR="$(fixture)"
cat >"$DIR/pipeline.toml" <<'EOF'
# same __SIGNALBOX_PORT_*__ placeholders. dev.sh renders 8100-8104.
[[sinks]]
args = ["--port", "8203"]
EOF
run_subject "$OUT" "$ERR" "$DIR"
OK=1
[ "$RUN_STATUS" -eq 0 ] && [ ! -s "$OUT" ] && [ ! -s "$ERR" ] && OK=0
report_case "pristine dir with mentioning comment exits 0, silent" "$OK" \
    "status=$RUN_STATUS stderr=$(head -c 120 "$ERR")"

# 2. Same, but the mentioning comment is indented.
DIR="$(fixture)"
cat >"$DIR/plan.toml" <<'EOF'
[[handlers]]
    # indented prose naming __SIGNALBOX_PORT_PLAN__ stays a comment
args = ["--port", "8201"]
EOF
run_subject "$OUT" "$ERR" "$DIR"
OK=1
[ "$RUN_STATUS" -eq 0 ] && [ ! -s "$OUT" ] && [ ! -s "$ERR" ] && OK=0
report_case "indented mentioning comment exits 0" "$OK" "status=$RUN_STATUS"

# 3. Genuine leftover in a non-comment position: the regression the guard exists for.
DIR="$(fixture)"
cat >"$DIR/pipeline.toml" <<'EOF'
# harmless prose about __SIGNALBOX_PORT_*__ tokens
[[sinks]]
args = ["--port", "__SIGNALBOX_PORT_PIPELINE__"]
EOF
run_subject "$OUT" "$ERR" "$DIR"
OK=1
if [ "$RUN_STATUS" -eq 1 ] \
    && grep -q "$DIR/pipeline.toml:3:" "$ERR" \
    && grep -q "error: unresolved __SIGNALBOX_ placeholder in rendered run config" "$ERR"; then
    OK=0
fi
report_case "live leftover exits 1 with file:line and summary error" "$OK" \
    "status=$RUN_STATUS stderr=$(head -c 200 "$ERR")"

# 4. Several files, only one dirty: diagnostics name it and not the clean ones.
DIR="$(fixture)"
for NAME in plan implement init; do
    cat >"$DIR/$NAME.toml" <<'EOF'
# clean file; prose mentions __SIGNALBOX_PORT_*__ only in this comment
args = ["--port", "8202"]
EOF
done
cat >"$DIR/review.toml" <<'EOF'
# prose mention of __SIGNALBOX_PORT_*__
args = ["--port", "__SIGNALBOX_PORT_REVIEW__"]
EOF
run_subject "$OUT" "$ERR" "$DIR"
OK=1
if [ "$RUN_STATUS" -eq 1 ] \
    && grep -q "$DIR/review.toml:2:" "$ERR" \
    && ! grep -q "plan.toml:" "$ERR" \
    && ! grep -q "implement.toml:" "$ERR" \
    && ! grep -q "init.toml:" "$ERR"; then
    OK=0
fi
report_case "mixed dir reports only the offending file" "$OK" \
    "status=$RUN_STATUS stderr=$(head -c 200 "$ERR")"

# 5. Wrong argument count: zero and two arguments both exit 64.
run_subject "$OUT" "$ERR"
S0=$RUN_STATUS
DIR="$(fixture)"
run_subject "$OUT" "$ERR" "$DIR" extra
S2=$RUN_STATUS
OK=1
[ "$S0" -eq 64 ] && [ "$S2" -eq 64 ] && OK=0
report_case "wrong argument count exits 64" "$OK" "zero-args=$S0 two-args=$S2"

# 6. Existing directory with no *.toml at all.
DIR="$(fixture)"
run_subject "$OUT" "$ERR" "$DIR"
OK=1
[ "$RUN_STATUS" -eq 1 ] && OK=0
report_case "directory without TOMLs exits 1" "$OK" "status=$RUN_STATUS"

printf '%d/%d cases passed\n' "$TESTS_PASSED" "$TESTS_RUN"
[ "$TESTS_PASSED" -eq "$TESTS_RUN" ]
