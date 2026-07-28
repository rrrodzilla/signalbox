#!/usr/bin/env bash
# Self-contained test runner for bin/shard-fix.sh's plan-declared ownership
# guidance and unchanged shard.review.requested payload contract.
# No framework; each fixture copies bin/ and prompts/ beneath its own mktemp -d
# and is removed by an EXIT trap. Deliberately omits set -e so expected lookup
# failures can be captured and asserted.
#
# Claude is never invoked: a PATH stub records one line per argument, keeping
# each multi-line prompt available to grep while allowing the fixer to finish.
# Prints PASS/FAIL per case and exits non-zero when any case failed.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES=()
TESTS_RUN=0
TESTS_PASSED=0
RUN_STATUS=0
FIXTURE_PATH=""
STUB_BIN=""
ARGV_LOG=""
OUT=""
ERR=""

cleanup() {
    local FIXTURE
    for FIXTURE in "${FIXTURES[@]}"; do
        rm -rf -- "$FIXTURE"
    done
}
trap cleanup EXIT

# Build the copied harness as a child of the temp directory. _env.sh therefore
# derives ROOT inside the fixture, and its sibling signalbox-wt path also stays
# beneath the same temp directory.
fixture() {
    local TEMP_ROOT
    TEMP_ROOT="$(mktemp -d)"
    FIXTURES+=("$TEMP_ROOT")

    FIXTURE_PATH="$TEMP_ROOT/harness"
    STUB_BIN="$TEMP_ROOT/stub-bin"
    ARGV_LOG="$TEMP_ROOT/claude-argv.log"
    OUT="$TEMP_ROOT/stdout"
    ERR="$TEMP_ROOT/stderr"

    mkdir -p "$FIXTURE_PATH" "$STUB_BIN" \
        "$FIXTURE_PATH/runs/probe/logs" \
        "$FIXTURE_PATH/runs/probe/state" \
        "$FIXTURE_PATH/runs/probe/results"
    cp -a "$ROOT/bin" "$FIXTURE_PATH/bin"
    cp -a "$ROOT/prompts" "$FIXTURE_PATH/prompts"
    : >"$ARGV_LOG"

    cat >"$STUB_BIN/claude" <<'STUB'
#!/usr/bin/env bash
printf 'ARG=%s\n' "$@" >>"$STUB_ARGV_LOG"
printf '%s\n' "stub fixer ran"
STUB
    chmod +x "$STUB_BIN/claude"
}

write_plan() {
    jq -n \
        '{
            feature: "scope-feature",
            stages: [{
                id: "build",
                shards: [
                    {
                        id: "alpha",
                        files: [
                            "bin/shard-fix.sh",
                            "tests/shard-fix-scope.test.sh"
                        ]
                    },
                    {
                        id: "beta",
                        files: ["prompts/operator.md"]
                    }
                ]
            }]
        }' >"$FIXTURE_PATH/runs/probe/plan.json"
}

make_worktree() {
    local FEATURE="$1"
    local SHARD_SUFFIX="$2"
    local WT_DIR
    WT_DIR="$(dirname "$FIXTURE_PATH")/signalbox-wt/$FEATURE-$SHARD_SUFFIX"
    mkdir -p "$WT_DIR"
    git init -q "$WT_DIR"
}

payload() {
    local SHARD_ID="$1"
    local ROUND="$2"
    local SESSION_ID="${3:-}"
    jq -nc \
        --arg shard "$SHARD_ID" \
        --argjson round "$ROUND" \
        --arg session "$SESSION_ID" \
        '{
            worker: "0",
            stage: "build",
            current: {
                shard: $shard,
                branch: ("shard/scope-feature/build-" + $shard)
            },
            round: $round,
            verdict: "REQUEST_CHANGES",
            review: "keep the shard inside its declared scope",
            feature: "scope-feature",
            thread_id: "review-thread",
            sentinel: "preserved"
        }
        | if $session == "" then . else .fix_session_id = $session end'
}

run_handler() {
    local INPUT="$1"
    PATH="$STUB_BIN:$PATH" \
        STUB_ARGV_LOG="$ARGV_LOG" \
        SIGNALBOX_RUN_SLUG="probe" \
        "$FIXTURE_PATH/bin/shard-fix.sh" 0 \
        <<<"$INPUT" >"$OUT" 2>"$ERR"
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
        printf 'FAIL %s%s\n' "$NAME" "${DETAIL:+ — $DETAIL}"
    fi
}

# 1. A fresh session receives every declared path, the authoritative rule, and
#    the leave-to-restore exception the scope report depends on, without
#    retaining the old circular ownership phrase.
fixture
write_plan
make_worktree scope-feature build-alpha
run_handler "$(payload alpha 1)"
OK=1
if [ "$RUN_STATUS" -eq 0 ] \
    && grep -Fq "## Complete set of files this shard may change" "$ARGV_LOG" \
    && grep -Fq -- "- bin/shard-fix.sh" "$ARGV_LOG" \
    && grep -Fq -- "- tests/shard-fix-scope.test.sh" "$ARGV_LOG" \
    && grep -Fq "Edit only the files in the complete ownership list above" "$ARGV_LOG" \
    && grep -Fq "restore it to its state at the integration tip" "$ARGV_LOG" \
    && ! grep -Fq "the files it created or changed" "$ARGV_LOG"; then
    OK=0
fi
report_case "round 1 names the shard's complete declared ownership" "$OK" \
    "status=$RUN_STATUS stderr=$(head -c 200 "$ERR")"

# 2. A concurrent sibling's declared path is not exposed as this shard's.
fixture
write_plan
make_worktree scope-feature build-alpha
run_handler "$(payload alpha 1)"
OK=1
if [ "$RUN_STATUS" -eq 0 ] \
    && ! grep -Fq "prompts/operator.md" "$ARGV_LOG"; then
    OK=0
fi
report_case "round 1 excludes a sibling shard's declared path" "$OK" \
    "status=$RUN_STATUS sibling_matches=$(grep -c 'prompts/operator.md' "$ARGV_LOG")"

# 3. A resumed session receives the per-round declared list again.
fixture
write_plan
make_worktree scope-feature build-alpha
run_handler "$(payload alpha 2 fix-session-two)"
OK=1
if [ "$RUN_STATUS" -eq 0 ] \
    && grep -Fxq "ARG=--resume" "$ARGV_LOG" \
    && grep -Fxq "ARG=fix-session-two" "$ARGV_LOG" \
    && grep -Fq "## Complete set of files this shard may change" "$ARGV_LOG" \
    && grep -Fq -- "- bin/shard-fix.sh" "$ARGV_LOG" \
    && grep -Fq -- "- tests/shard-fix-scope.test.sh" "$ARGV_LOG" \
    && grep -Fq "Files outside this list are off limits, except to undo a change this branch" "$ARGV_LOG"; then
    OK=0
fi
report_case "rounds 2+ repeat declared ownership in the resume prompt" "$OK" \
    "status=$RUN_STATUS stderr=$(head -c 200 "$ERR")"

# 4. An unresolved shard warns and falls back without stalling or claiming a
#    declared ownership list.
fixture
write_plan
make_worktree scope-feature build-missing
run_handler "$(payload missing 1)"
OK=1
if [ "$RUN_STATUS" -eq 0 ] \
    && jq -e 'type == "object"' "$OUT" >/dev/null 2>&1 \
    && grep -Fq "[shard-fix] build/missing: ownership lookup failed: [scope]" "$ERR" \
    && ! grep -Fq "## Complete set of files this shard may change" "$ARGV_LOG" \
    && grep -Fq "this shard's own branch already created or changed" "$ARGV_LOG"; then
    OK=0
fi
report_case "a missing shard warns and continues with fallback guidance" "$OK" \
    "status=$RUN_STATUS stderr=$(head -c 200 "$ERR")"

# 5. A missing plan has the same non-stalling fallback. Without plan metadata,
#    shard-fix.sh uses its existing `feature` fallback for the worktree name.
fixture
make_worktree feature build-alpha
run_handler "$(payload alpha 1)"
OK=1
if [ "$RUN_STATUS" -eq 0 ] \
    && jq -e 'type == "object"' "$OUT" >/dev/null 2>&1 \
    && grep -Fq "[shard-fix] build/alpha: ownership lookup failed: [scope]" "$ERR" \
    && grep -Fq "plan file is missing or unreadable" "$ERR" \
    && ! grep -Fq "## Complete set of files this shard may change" "$ARGV_LOG" \
    && grep -Fq "this shard's own branch already created or changed" "$ARGV_LOG"; then
    OK=0
fi
report_case "a missing plan warns and continues with fallback guidance" "$OK" \
    "status=$RUN_STATUS stderr=$(head -c 200 "$ERR")"

# 6. The event contract remains the existing transform: remove verdict, move
#    review to feedback, increment round, retain carrier fields, and add fixer
#    provenance plus the per-shard session id.
fixture
write_plan
make_worktree scope-feature build-alpha
run_handler "$(payload alpha 1)"
OK=1
if [ "$RUN_STATUS" -eq 0 ] \
    && jq -e '
        (has("verdict") | not)
        and (has("review") | not)
        and .feedback == "keep the shard inside its declared scope"
        and .round == 2
        and .sentinel == "preserved"
        and .provenance.agent == "claude"
        and .provenance.model == "opus"
        and has("fix_session_id")
        and (.fix_session_id | type == "string" and length > 0)
    ' "$OUT" >/dev/null 2>&1; then
    OK=0
fi
report_case "the emitted shard.review.requested payload contract is unchanged" "$OK" \
    "status=$RUN_STATUS payload=$(head -c 300 "$OUT")"

printf '%d/%d cases passed\n' "$TESTS_PASSED" "$TESTS_RUN"
[ "$TESTS_PASSED" -eq "$TESTS_RUN" ]
