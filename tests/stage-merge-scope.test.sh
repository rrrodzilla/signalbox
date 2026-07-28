#!/usr/bin/env bash
# Self-contained regression runner for bin/stage-merge.sh's shard-scope
# pre-flight. Every case builds a copied harness as a real Git repository under
# mktemp -d, with its integration and shard worktrees outside the harness
# checkout. No Git command targets this repository. Deliberately omits set -e
# so expected subject failures can be captured and inspected.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES=()
TESTS_RUN=0
TESTS_PASSED=0
RUN_STATUS=0
TMP=""
HARNESS=""
WT_BASE=""
OUT=""
ERR=""
FEATURE="probe-feature"
STAGE="build"
LAST_BRANCH=""
LAST_WT=""
CASE_BRANCHES=()
CASE_WORKTREES=()

cleanup() {
    local FIXTURE
    for FIXTURE in "${FIXTURES[@]}"; do
        rm -rf -- "$FIXTURE"
    done
}
trap cleanup EXIT

git_fixture() {
    local DIR="$1"
    shift
    git \
        -c user.name=t \
        -c user.email=t@example.com \
        -c commit.gpgsign=false \
        -C "$DIR" "$@"
}

fixture() {
    TMP="$(mktemp -d)"
    FIXTURES+=("$TMP")
    HARNESS="$TMP/harness"
    WT_BASE="$TMP/signalbox-wt"
    mkdir -p "$HARNESS" "$WT_BASE"
    cp -a "$ROOT/bin" "$HARNESS/"

    git \
        -c user.name=t \
        -c user.email=t@example.com \
        -c commit.gpgsign=false \
        init -q -b main "$HARNESS"
    git -C "$HARNESS" config user.name t
    git -C "$HARNESS" config user.email t@example.com
    git -C "$HARNESS" config commit.gpgsign false
    git -C "$HARNESS" config tag.gpgsign false

    printf 'base one\n' >"$HARNESS/one.txt"
    printf 'base two\n' >"$HARNESS/two.txt"
    printf 'base shared\n' >"$HARNESS/shared.txt"
    printf 'base rogue\n' >"$HARNESS/rogue.txt"
    git_fixture "$HARNESS" add bin one.txt two.txt shared.txt rogue.txt
    git_fixture "$HARNESS" commit -q -m "fixture base"
    git_fixture "$HARNESS" branch integration/stream-demo
    git_fixture "$HARNESS" worktree add -q \
        "$WT_BASE/integration" integration/stream-demo

    mkdir -p "$HARNESS/runs/probe"
    CASE_BRANCHES=()
    CASE_WORKTREES=()
}

write_plan() {
    local FIRST_FILE="$1"
    local SECOND_FILE="$2"
    jq -n \
        --arg feature "$FEATURE" \
        --arg stage "$STAGE" \
        --arg first "$FIRST_FILE" \
        --arg second "$SECOND_FILE" \
        '{
            feature: $feature,
            stages: [{
                id: $stage,
                shards: [
                    {id: "one", files: [$first]},
                    {id: "two", files: [$second]}
                ]
            }]
        }' >"$HARNESS/runs/probe/plan.json"
}

add_shard() {
    local SHARD_ID="$1"
    local FILE="$2"
    local CONTENT="$3"
    local BRANCH="${4:-shard/$FEATURE/$STAGE-$SHARD_ID}"
    local WT_NAME="${5:-$FEATURE-$STAGE-$SHARD_ID}"

    LAST_BRANCH="$BRANCH"
    LAST_WT="$WT_BASE/$WT_NAME"
    git_fixture "$HARNESS" branch "$LAST_BRANCH" integration/stream-demo
    git_fixture "$HARNESS" worktree add -q "$LAST_WT" "$LAST_BRANCH"
    printf '%s\n' "$CONTENT" >"$LAST_WT/$FILE"
    git_fixture "$LAST_WT" add -A
    git_fixture "$LAST_WT" commit -q -m "fixture shard $SHARD_ID"
    CASE_BRANCHES+=("$LAST_BRANCH")
    CASE_WORKTREES+=("$LAST_WT")
}

stage_payload() {
    jq -nc \
        --arg stage "$STAGE" \
        --arg first "${CASE_BRANCHES[0]}" \
        --arg second "${CASE_BRANCHES[1]}" \
        '{
            stage: $stage,
            expected: 2,
            done: ["one", "two"],
            branches: [$first, $second]
        }'
}

run_subject() {
    local PAYLOAD="$1"
    SIGNALBOX_RUN_SLUG=probe \
        "$HARNESS/bin/stage-merge.sh" <<<"$PAYLOAD" >"$OUT" 2>"$ERR"
    RUN_STATUS=$?
}

fixture_is_unmutated() {
    local BEFORE_TIP="$1"
    local INDEX

    [ "$(git_fixture "$HARNESS" rev-parse integration/stream-demo)" = "$BEFORE_TIP" ] \
        || return 1
    for INDEX in "${!CASE_BRANCHES[@]}"; do
        git_fixture "$HARNESS" show-ref --verify --quiet \
            "refs/heads/${CASE_BRANCHES[$INDEX]}" || return 1
        [ -d "${CASE_WORKTREES[$INDEX]}" ] || return 1
        git_fixture "${CASE_WORKTREES[$INDEX]}" rev-parse \
            --is-inside-work-tree >/dev/null || return 1
    done
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

# 1. Disjoint, in-scope shards pass pre-flight and merge linearly.
fixture
write_plan one.txt two.txt
add_shard one one.txt "shard one"
FIRST_BRANCH="$LAST_BRANCH"
add_shard two two.txt "shard two"
SECOND_BRANCH="$LAST_BRANCH"
BEFORE_TIP="$(git_fixture "$HARNESS" rev-parse integration/stream-demo)"
run_subject "$(stage_payload)"
AFTER_TIP="$(git_fixture "$HARNESS" rev-parse integration/stream-demo)"
OK=1
if [ "$RUN_STATUS" -eq 0 ] \
    && jq -e \
        --arg stage "$STAGE" \
        --arg first "$FIRST_BRANCH" \
        --arg second "$SECOND_BRANCH" \
        '.stage == $stage
            and .merged == [$first, $second]
            and (.tip | type == "string" and length > 0)' "$OUT" >/dev/null \
    && [ "$AFTER_TIP" != "$BEFORE_TIP" ]; then
    OK=0
fi
report_case "disjoint in-scope shards merge and emit an ack" "$OK" \
    "status=$RUN_STATUS stdout=$(head -c 200 "$OUT") stderr=$(head -c 200 "$ERR")"

# 2. One undeclared path stops the whole stage before any branch is consumed.
fixture
write_plan one.txt two.txt
add_shard one one.txt "shard one"
FIRST_BRANCH="$LAST_BRANCH"
printf 'out of lane\n' >"$LAST_WT/rogue.txt"
git_fixture "$LAST_WT" add rogue.txt
git_fixture "$LAST_WT" commit -q -m "fixture undeclared path"
add_shard two two.txt "shard two"
BEFORE_TIP="$(git_fixture "$HARNESS" rev-parse integration/stream-demo)"
run_subject "$(stage_payload)"
OK=1
if [ "$RUN_STATUS" -eq 1 ] \
    && [ ! -s "$OUT" ] \
    && grep -Fq "## Shard scope violation" "$ERR" \
    && grep -Fq "$FIRST_BRANCH" "$ERR" \
    && grep -Fq "rogue.txt" "$ERR" \
    && grep -Fq "per-shard review gate should have caught" "$ERR" \
    && fixture_is_unmutated "$BEFORE_TIP"; then
    OK=0
fi
report_case "an undeclared path fails with no stage mutation" "$OK" \
    "status=$RUN_STATUS stdout=$(head -c 100 "$OUT") stderr=$(head -c 300 "$ERR")"

# 3. Declarations do not excuse two stage branches touching the same path.
fixture
write_plan shared.txt shared.txt
add_shard one shared.txt "shared from one"
FIRST_BRANCH="$LAST_BRANCH"
add_shard two shared.txt "shared from two"
SECOND_BRANCH="$LAST_BRANCH"
BEFORE_TIP="$(git_fixture "$HARNESS" rev-parse integration/stream-demo)"
run_subject "$(stage_payload)"
OK=1
if [ "$RUN_STATUS" -eq 1 ] \
    && [ ! -s "$OUT" ] \
    && grep -Fq "## Cross-branch shard overlap" "$ERR" \
    && grep -Fq "shared.txt" "$ERR" \
    && grep -Fq "$FIRST_BRANCH" "$ERR" \
    && grep -Fq "$SECOND_BRANCH" "$ERR" \
    && fixture_is_unmutated "$BEFORE_TIP"; then
    OK=0
fi
report_case "declared cross-branch overlap fails with no stage mutation" "$OK" \
    "status=$RUN_STATUS stdout=$(head -c 100 "$OUT") stderr=$(head -c 300 "$ERR")"

# 4. A branch whose last segment lacks the stage prefix fails closed.
fixture
write_plan one.txt two.txt
add_shard one one.txt "shard one" \
    "shard/$FEATURE/wrong-one" "$FEATURE-wrong-one"
BAD_BRANCH="$LAST_BRANCH"
add_shard two two.txt "shard two"
BEFORE_TIP="$(git_fixture "$HARNESS" rev-parse integration/stream-demo)"
run_subject "$(stage_payload)"
OK=1
if [ "$RUN_STATUS" -eq 1 ] \
    && [ ! -s "$OUT" ] \
    && grep -Fq "$BAD_BRANCH" "$ERR" \
    && grep -Fq "required stage prefix $STAGE-" "$ERR" \
    && fixture_is_unmutated "$BEFORE_TIP"; then
    OK=0
fi
report_case "an unrecognizable branch fails with no stage mutation" "$OK" \
    "status=$RUN_STATUS stdout=$(head -c 100 "$OUT") stderr=$(head -c 300 "$ERR")"

# 5. A plan with no matching shard declarations also fails before mutation.
fixture
jq -n \
    --arg feature "$FEATURE" \
    --arg stage "$STAGE" \
    '{feature: $feature, stages: [{id: $stage, shards: []}]}' \
    >"$HARNESS/runs/probe/plan.json"
add_shard one one.txt "shard one"
add_shard two two.txt "shard two"
BEFORE_TIP="$(git_fixture "$HARNESS" rev-parse integration/stream-demo)"
run_subject "$(stage_payload)"
OK=1
if [ "$RUN_STATUS" -eq 1 ] \
    && [ ! -s "$OUT" ] \
    && grep -Fq "plan declaration could not be resolved" "$ERR" \
    && grep -Fq "${CASE_BRANCHES[0]}" "$ERR" \
    && grep -Fq "${CASE_BRANCHES[1]}" "$ERR" \
    && fixture_is_unmutated "$BEFORE_TIP"; then
    OK=0
fi
report_case "a shard-less plan fails with no stage mutation" "$OK" \
    "status=$RUN_STATUS stdout=$(head -c 100 "$OUT") stderr=$(head -c 300 "$ERR")"

printf '%d/%d cases passed\n' "$TESTS_PASSED" "$TESTS_RUN"
[ "$TESTS_PASSED" -eq "$TESTS_RUN" ]
