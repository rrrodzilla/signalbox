#!/usr/bin/env bash
# Self-contained test runner for bin/_scope.sh. Every plan and Git fixture is
# built under mktemp -d, never in or against this repository. Prints PASS/FAIL
# per case and exits non-zero when any case failed.
#
# Deliberately no -e: cases capture non-zero function statuses for assertions.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTS_RUN=0
TESTS_PASSED=0
RUN_STATUS=0
FIXTURE_ROOT="$(mktemp -d)"
OUT="$FIXTURE_ROOT/stdout"
ERR="$FIXTURE_ROOT/stderr"

# shellcheck source=../bin/_scope.sh
source "$ROOT/bin/_scope.sh"

cleanup() {
    if [ -n "$FIXTURE_ROOT" ] && [ -d "$FIXTURE_ROOT" ]; then
        rm -rf -- "$FIXTURE_ROOT"
    fi
}
trap cleanup EXIT

run_subject() {
    local STDOUT_FILE="$1"
    local STDERR_FILE="$2"
    shift 2
    "$@" >"$STDOUT_FILE" 2>"$STDERR_FILE"
    RUN_STATUS=$?
}

report_case() {
    local NAME="$1"
    local OK="$2"
    local DETAIL="${3:-}"

    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$OK" -eq 0 ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        printf 'PASS %s\n' "$NAME"
    else
        printf 'FAIL %s%s\n' "$NAME" "${DETAIL:+ -- $DETAIL}"
    fi
}

git_fixture() {
    local GIT_DIR="$1"
    shift
    git \
        -c user.name=scope-test \
        -c user.email=scope-test@example.com \
        -c commit.gpgsign=false \
        -C "$GIT_DIR" "$@"
}

PLAN="$FIXTURE_ROOT/plan.json"
jq -n \
    '{
        feature: "scope-test",
        issue: 51,
        stages: [
            {
                id: "build",
                shards: [
                    {
                        id: "helper",
                        files: [
                            "bin/_scope.sh",
                            "tests/shard scope.test.sh"
                        ],
                        prompt: "Build the scope helper."
                    }
                ]
            }
        ]
    }' >"$PLAN"

# 1. A well-formed plan preserves the exact declaration order.
run_subject "$OUT" "$ERR" \
    shard_declared_files "$PLAN" build helper
DECLARED_OUTPUT="$(<"$OUT")"
EXPECTED_DECLARED=$'bin/_scope.sh\ntests/shard scope.test.sh'
OK=1
if [ "$RUN_STATUS" -eq 0 ] \
    && [ "$DECLARED_OUTPUT" = "$EXPECTED_DECLARED" ] \
    && [ ! -s "$ERR" ]; then
    OK=0
fi
report_case "well-formed plan returns declared files in order" "$OK" \
    "status=$RUN_STATUS output=$DECLARED_OUTPUT"

# 2. Missing and malformed plans fail closed with no stdout.
run_subject "$OUT" "$ERR" \
    shard_declared_files "$FIXTURE_ROOT/missing.json" build helper
MISSING_STATUS=$RUN_STATUS
MISSING_STDOUT_SIZE="$(wc -c <"$OUT")"
MISSING_DIAGNOSTIC="$(<"$ERR")"
MALFORMED="$FIXTURE_ROOT/malformed.json"
printf '%s\n' '{"stages": [' >"$MALFORMED"
run_subject "$OUT" "$ERR" \
    shard_declared_files "$MALFORMED" build helper
MALFORMED_STATUS=$RUN_STATUS
MALFORMED_STDOUT_SIZE="$(wc -c <"$OUT")"
MALFORMED_DIAGNOSTIC="$(<"$ERR")"
OK=1
if [ "$MISSING_STATUS" -eq 1 ] \
    && [ "$MISSING_STDOUT_SIZE" -eq 0 ] \
    && [[ "$MISSING_DIAGNOSTIC" == "[scope]"* ]] \
    && [ "$MALFORMED_STATUS" -eq 1 ] \
    && [ "$MALFORMED_STDOUT_SIZE" -eq 0 ] \
    && [[ "$MALFORMED_DIAGNOSTIC" == "[scope]"* ]]; then
    OK=0
fi
report_case "missing and malformed plans fail closed" "$OK" \
    "missing=$MISSING_STATUS malformed=$MALFORMED_STATUS"

# 3. Unknown stages and shards fail closed with no stdout.
run_subject "$OUT" "$ERR" \
    shard_declared_files "$PLAN" unknown helper
UNKNOWN_STAGE_STATUS=$RUN_STATUS
UNKNOWN_STAGE_STDOUT_SIZE="$(wc -c <"$OUT")"
run_subject "$OUT" "$ERR" \
    shard_declared_files "$PLAN" build unknown
UNKNOWN_SHARD_STATUS=$RUN_STATUS
UNKNOWN_SHARD_STDOUT_SIZE="$(wc -c <"$OUT")"
OK=1
if [ "$UNKNOWN_STAGE_STATUS" -eq 1 ] \
    && [ "$UNKNOWN_STAGE_STDOUT_SIZE" -eq 0 ] \
    && [ "$UNKNOWN_SHARD_STATUS" -eq 1 ] \
    && [ "$UNKNOWN_SHARD_STDOUT_SIZE" -eq 0 ]; then
    OK=0
fi
report_case "unknown stage and shard fail closed" "$OK" \
    "stage=$UNKNOWN_STAGE_STATUS shard=$UNKNOWN_SHARD_STATUS"

# 4. An absent files key and an empty files array both fail closed.
ABSENT_FILES="$FIXTURE_ROOT/absent-files.json"
EMPTY_FILES="$FIXTURE_ROOT/empty-files.json"
jq '.stages[0].shards[0] |= del(.files)' "$PLAN" >"$ABSENT_FILES"
jq '.stages[0].shards[0].files = []' "$PLAN" >"$EMPTY_FILES"
run_subject "$OUT" "$ERR" \
    shard_declared_files "$ABSENT_FILES" build helper
ABSENT_STATUS=$RUN_STATUS
ABSENT_STDOUT_SIZE="$(wc -c <"$OUT")"
run_subject "$OUT" "$ERR" \
    shard_declared_files "$EMPTY_FILES" build helper
EMPTY_STATUS=$RUN_STATUS
EMPTY_STDOUT_SIZE="$(wc -c <"$OUT")"
OK=1
if [ "$ABSENT_STATUS" -eq 1 ] \
    && [ "$ABSENT_STDOUT_SIZE" -eq 0 ] \
    && [ "$EMPTY_STATUS" -eq 1 ] \
    && [ "$EMPTY_STDOUT_SIZE" -eq 0 ]; then
    OK=0
fi
report_case "absent and empty file declarations fail closed" "$OK" \
    "absent=$ABSENT_STATUS empty=$EMPTY_STATUS"

# 5. Empty and newline-containing declared paths never produce partial output.
INVALID_PATHS="$FIXTURE_ROOT/invalid-paths.json"
jq '.stages[0].shards[0].files = ["valid.txt", "", "bad\npath.txt"]' \
    "$PLAN" >"$INVALID_PATHS"
run_subject "$OUT" "$ERR" \
    shard_declared_files "$INVALID_PATHS" build helper
INVALID_PATH_STATUS=$RUN_STATUS
INVALID_PATH_STDOUT_SIZE="$(wc -c <"$OUT")"
OK=1
if [ "$INVALID_PATH_STATUS" -eq 1 ] \
    && [ "$INVALID_PATH_STDOUT_SIZE" -eq 0 ] \
    && [[ "$(<"$ERR")" == "[scope]"* ]]; then
    OK=0
fi
report_case "invalid declared paths fail before printing" "$OK" \
    "status=$INVALID_PATH_STATUS stdout-bytes=$INVALID_PATH_STDOUT_SIZE"

# 6. Every helper rejects both missing and excess arguments with status 64.
OK=0
for FUNCTION in \
    shard_declared_files \
    shard_touched_files \
    scope_violations \
    scope_report; do
    run_subject "$OUT" "$ERR" "$FUNCTION"
    ZERO_STATUS=$RUN_STATUS
    run_subject "$OUT" "$ERR" "$FUNCTION" one two three four
    EXCESS_STATUS=$RUN_STATUS
    if [ "$ZERO_STATUS" -ne 64 ] || [ "$EXCESS_STATUS" -ne 64 ]; then
        OK=1
    fi
done
report_case "all helpers reject wrong argument counts with status 64" "$OK"

GIT_DIR="$FIXTURE_ROOT/git"
mkdir -p "$GIT_DIR"
git_fixture "$GIT_DIR" init -q -b main
printf '%s\n' "original" >"$GIT_DIR/modified.txt"
printf '%s\n' "unchanged" >"$GIT_DIR/unchanged.txt"
git_fixture "$GIT_DIR" add modified.txt unchanged.txt
git_fixture "$GIT_DIR" commit -q -m "initial"
git_fixture "$GIT_DIR" switch -q -c shard
printf '%s\n' "changed by shard" >"$GIT_DIR/modified.txt"
printf '%s\n' "new by shard" >"$GIT_DIR/new.txt"
printf '%s\n' "space survives" >"$GIT_DIR/path with space.txt"
git_fixture "$GIT_DIR" add modified.txt new.txt "path with space.txt"
git_fixture "$GIT_DIR" commit -q -m "shard change"
SHARD_TIP="$(git_fixture "$GIT_DIR" rev-parse HEAD)"
git_fixture "$GIT_DIR" switch -q main
printf '%s\n' "base only" >"$GIT_DIR/base-only.txt"
git_fixture "$GIT_DIR" add base-only.txt
git_fixture "$GIT_DIR" commit -q -m "base change"

# 7. Three-dot diff reports only the shard contribution, in Git's path order.
run_subject "$OUT" "$ERR" \
    shard_touched_files "$GIT_DIR" main "$SHARD_TIP"
TOUCHED_OUTPUT="$(<"$OUT")"
EXPECTED_TOUCHED=$'modified.txt\nnew.txt\npath with space.txt'
OK=1
if [ "$RUN_STATUS" -eq 0 ] \
    && [ "$TOUCHED_OUTPUT" = "$EXPECTED_TOUCHED" ] \
    && [[ "$TOUCHED_OUTPUT" != *"base-only.txt"* ]] \
    && [[ "$TOUCHED_OUTPUT" != *"unchanged.txt"* ]] \
    && [ ! -s "$ERR" ]; then
    OK=0
fi
report_case "three-dot diff reports only shard-touched paths" "$OK" \
    "status=$RUN_STATUS output=$TOUCHED_OUTPUT"

# 8. A path containing a space survives the NUL-delimited round trip.
SPACE_LINE_COUNT="$(grep -Fxc "path with space.txt" "$OUT")"
OK=1
if [ "$SPACE_LINE_COUNT" -eq 1 ]; then
    OK=0
fi
report_case "path containing a space survives intact" "$OK" \
    "matches=$SPACE_LINE_COUNT"

# 9. An unresolvable ref returns 1, no stdout, and a scope diagnostic.
run_subject "$OUT" "$ERR" \
    shard_touched_files "$GIT_DIR" main no-such-ref
BAD_REF_STDOUT_SIZE="$(wc -c <"$OUT")"
BAD_REF_DIAGNOSTIC="$(<"$ERR")"
OK=1
if [ "$RUN_STATUS" -eq 1 ] \
    && [ "$BAD_REF_STDOUT_SIZE" -eq 0 ] \
    && [[ "$BAD_REF_DIAGNOSTIC" == "[scope]"* ]]; then
    OK=0
fi
report_case "unresolvable ref fails with scope diagnostic" "$OK" \
    "status=$RUN_STATUS stdout-bytes=$BAD_REF_STDOUT_SIZE"

# 10. A newline in a Git path fails before any path is emitted.
git_fixture "$GIT_DIR" switch -q shard
NEWLINE_PATH=$'bad\npath.txt'
printf '%s\n' "newline path" >"$GIT_DIR/$NEWLINE_PATH"
git_fixture "$GIT_DIR" add "$NEWLINE_PATH"
git_fixture "$GIT_DIR" commit -q -m "newline path"
NEWLINE_TIP="$(git_fixture "$GIT_DIR" rev-parse HEAD)"
run_subject "$OUT" "$ERR" \
    shard_touched_files "$GIT_DIR" main "$NEWLINE_TIP"
NEWLINE_STDOUT_SIZE="$(wc -c <"$OUT")"
OK=1
if [ "$RUN_STATUS" -eq 1 ] \
    && [ "$NEWLINE_STDOUT_SIZE" -eq 0 ] \
    && [[ "$(<"$ERR")" == "[scope]"* ]]; then
    OK=0
fi
report_case "newline-containing Git path fails before printing" "$OK" \
    "status=$RUN_STATUS stdout-bytes=$NEWLINE_STDOUT_SIZE"

# 11. Exact declared and touched lists produce no violations.
run_subject "$OUT" "$ERR" \
    scope_violations $'bin/_scope.sh\ntests/scope.sh' \
    $'bin/_scope.sh\ntests/scope.sh'
OK=1
if [ "$RUN_STATUS" -eq 0 ] && [ ! -s "$OUT" ] && [ ! -s "$ERR" ]; then
    OK=0
fi
report_case "exactly matched scope has no violations" "$OK" \
    "status=$RUN_STATUS output=$(<"$OUT")"

# 12. Mixed touched files return only undeclared paths in touched order.
run_subject "$OUT" "$ERR" \
    scope_violations $'owned/one.sh\nowned/two.sh' \
    $'owned/one.sh\noutside/first.sh\nowned/two.sh\noutside/second.sh'
MIXED_OUTPUT="$(<"$OUT")"
OK=1
if [ "$RUN_STATUS" -eq 0 ] \
    && [ "$MIXED_OUTPUT" = $'outside/first.sh\noutside/second.sh' ]; then
    OK=0
fi
report_case "mixed diff returns only undeclared paths in order" "$OK" \
    "status=$RUN_STATUS output=$MIXED_OUTPUT"

# 13. Duplicate touched paths collapse and blank lines are ignored.
run_subject "$OUT" "$ERR" \
    scope_violations $'\nowned.sh\n\n' \
    $'\nextra.sh\nextra.sh\n\nowned.sh\nextra.sh\n'
DUPLICATE_OUTPUT="$(<"$OUT")"
OK=1
if [ "$RUN_STATUS" -eq 0 ] && [ "$DUPLICATE_OUTPUT" = "extra.sh" ]; then
    OK=0
fi
report_case "violations collapse duplicates and ignore blank lines" "$OK" \
    "status=$RUN_STATUS output=$DUPLICATE_OUTPUT"

# 14. Directory siblings and path prefixes are not implicitly declared.
run_subject "$OUT" "$ERR" \
    scope_violations "bin/operator.sh" \
    $'bin/anything-else.sh\nbin/operator.sh.extra\nbin/operator.sh'
PREFIX_OUTPUT="$(<"$OUT")"
OK=1
if [ "$RUN_STATUS" -eq 0 ] \
    && [ "$PREFIX_OUTPUT" = $'bin/anything-else.sh\nbin/operator.sh.extra' ]; then
    OK=0
fi
report_case "scope comparison rejects siblings and prefix matches" "$OK" \
    "status=$RUN_STATUS output=$PREFIX_OUTPUT"

# 15. The Markdown report exposes every required scope-recovery instruction.
run_subject "$OUT" "$ERR" \
    scope_report helper \
    $'bin/_scope.sh\ntests/shard-scope.test.sh' \
    $'bin/stage-merge.sh\ninstall.sh'
REPORT_FIRST_LINE="$(head -n 1 "$OUT")"
OK=1
if [ "$RUN_STATUS" -eq 0 ] \
    && [ "$REPORT_FIRST_LINE" = "## Shard scope violation" ] \
    && grep -Fq 'Shard `helper`' "$OUT" \
    && grep -Fq -- '- bin/_scope.sh' "$OUT" \
    && grep -Fq -- '- tests/shard-scope.test.sh' "$OUT" \
    && grep -Fq -- '- bin/stage-merge.sh' "$OUT" \
    && grep -Fq -- '- install.sh' "$OUT" \
    && grep -Fq 'integration tip' "$OUT" \
    && grep -Fq 'fan-in merge' "$OUT" \
    && grep -Fq 'SCOPE-CONFLICT' "$OUT" \
    && grep -Fq 'one paragraph naming the decision required' "$OUT" \
    && [ ! -s "$ERR" ]; then
    OK=0
fi
report_case "scope report contains marker, paths, and recovery contract" "$OK" \
    "status=$RUN_STATUS first-line=$REPORT_FIRST_LINE"

printf '%d/%d cases passed\n' "$TESTS_PASSED" "$TESTS_RUN"
[ "$TESTS_PASSED" -eq "$TESTS_RUN" ]
