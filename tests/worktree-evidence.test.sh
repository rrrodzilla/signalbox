#!/usr/bin/env bash
# Self-contained test runner for bin/worktree-evidence.sh. No framework; every
# git fixture is built in its own mktemp -d with local identity and signing
# disabled, never against this repository. Prints PASS/FAIL per case and exits
# non-zero when any case failed.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUBJECT="$ROOT/bin/worktree-evidence.sh"
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

git_fixture() {
    local DIR="$1"
    shift
    git \
        -c user.name=t \
        -c user.email=t@example.com \
        -c commit.gpgsign=false \
        -C "$DIR" "$@"
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

# 1. Clean worktree: valid JSON with the expected branch, tip, and clean state.
fixture
DIR="$FIXTURE_PATH"
git_fixture "$DIR" init -q -b fixture-branch
printf 'tracked\n' >"$DIR/tracked.txt"
git_fixture "$DIR" add tracked.txt
git_fixture "$DIR" commit -q -m initial
EXPECTED_TIP="$(git_fixture "$DIR" rev-parse --short HEAD)"
EXPECTED_BRANCH="$(git_fixture "$DIR" symbolic-ref --short HEAD)"
run_subject "$OUT" "$ERR" "$DIR"
OK=1
if [ "$RUN_STATUS" -eq 0 ] \
    && jq -e \
        --arg worktree "$DIR" \
        --arg tip "$EXPECTED_TIP" \
        --arg branch "$EXPECTED_BRANCH" \
        '.worktree == $worktree
            and .exists == true
            and .clean == true
            and .porcelain == ""
            and .tip == $tip
            and .branch == $branch' "$OUT" >/dev/null; then
    OK=0
fi
report_case "clean worktree reports matching clean evidence" "$OK" \
    "status=$RUN_STATUS stdout=$(head -c 200 "$OUT")"

# 2. Dirty worktree: both a modified tracked path and an untracked path appear.
fixture
DIR="$FIXTURE_PATH"
git_fixture "$DIR" init -q -b dirty-branch
printf 'tracked\n' >"$DIR/tracked.txt"
git_fixture "$DIR" add tracked.txt
git_fixture "$DIR" commit -q -m initial
printf 'changed\n' >"$DIR/tracked.txt"
printf 'new\n' >"$DIR/untracked.txt"
run_subject "$OUT" "$ERR" "$DIR"
OK=1
if [ "$RUN_STATUS" -eq 0 ] \
    && jq -e \
        '.exists == true
            and .clean == false
            and (.porcelain | contains("tracked.txt"))
            and (.porcelain | contains("untracked.txt"))' "$OUT" >/dev/null; then
    OK=0
fi
report_case "dirty worktree reports tracked and untracked paths" "$OK" \
    "status=$RUN_STATUS stdout=$(head -c 200 "$OUT")"

# 3. A path that does not exist is valid negative evidence, not script failure.
fixture
DIR="$FIXTURE_PATH"
MISSING="$DIR/missing"
run_subject "$OUT" "$ERR" "$MISSING"
OK=1
if [ "$RUN_STATUS" -eq 0 ] \
    && jq -e --arg worktree "$MISSING" \
        '.worktree == $worktree and .exists == false and (.error | length > 0)' \
        "$OUT" >/dev/null; then
    OK=0
fi
report_case "missing path reports exists false" "$OK" \
    "status=$RUN_STATUS stdout=$(head -c 200 "$OUT")"

# 4. An existing non-git directory is also valid negative evidence.
fixture
DIR="$FIXTURE_PATH"
run_subject "$OUT" "$ERR" "$DIR"
OK=1
if [ "$RUN_STATUS" -eq 0 ] \
    && jq -e --arg worktree "$DIR" \
        '.worktree == $worktree and .exists == false and (.error | length > 0)' \
        "$OUT" >/dev/null; then
    OK=0
fi
report_case "non-git directory reports exists false" "$OK" \
    "status=$RUN_STATUS stdout=$(head -c 200 "$OUT")"

# 5. Wrong argument count: zero and two arguments both exit 64.
run_subject "$OUT" "$ERR"
S0=$RUN_STATUS
fixture
DIR="$FIXTURE_PATH"
run_subject "$OUT" "$ERR" "$DIR" extra
S2=$RUN_STATUS
OK=1
[ "$S0" -eq 64 ] && [ "$S2" -eq 64 ] && OK=0
report_case "wrong argument count exits 64" "$OK" "zero-args=$S0 two-args=$S2"

# 6. Several porcelain entries remain escaped inside exactly one output line.
fixture
DIR="$FIXTURE_PATH"
git_fixture "$DIR" init -q -b multiline-branch
printf 'one\n' >"$DIR/one.txt"
printf 'two\n' >"$DIR/two.txt"
git_fixture "$DIR" add one.txt two.txt
git_fixture "$DIR" commit -q -m initial
printf 'changed one\n' >"$DIR/one.txt"
printf 'changed two\n' >"$DIR/two.txt"
printf 'three\n' >"$DIR/three.txt"
run_subject "$OUT" "$ERR" "$DIR"
LINES="$(wc -l <"$OUT")"
OK=1
if [ "$RUN_STATUS" -eq 0 ] \
    && [ "$LINES" -eq 1 ] \
    && jq -e \
        '.clean == false
            and (.porcelain | contains("one.txt"))
            and (.porcelain | contains("two.txt"))
            and (.porcelain | contains("three.txt"))' "$OUT" >/dev/null; then
    OK=0
fi
report_case "multi-entry porcelain stays on one JSON line" "$OK" \
    "status=$RUN_STATUS lines=$LINES stdout=$(head -c 200 "$OUT")"

printf '%d/%d cases passed\n' "$TESTS_PASSED" "$TESTS_RUN"
[ "$TESTS_PASSED" -eq "$TESTS_RUN" ]
