#!/usr/bin/env bash
# Self-contained test runner for bin/shard-review.sh's plan-declared scope gate.
# No framework; every fixture is a copied harness tree rooted below mktemp -d
# and removed by an EXIT trap. Deliberately omits set -e so expected subject
# failures can be captured and asserted.
#
# Codex and Claude are replaced by PATH stubs that append their argv to a log.
# Prints PASS/FAIL per case and exits non-zero when any case failed.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES=()
TESTS_RUN=0
TESTS_PASSED=0
RUN_STATUS=0
TMP=""
FIXTURE_PATH=""
STUB_BIN=""
ARGV_LOG=""
OUT=""
ERR=""
WT=""
FEATURE="probe-feature"
STAGE="core"
SHARD="one"
BRANCH="shard/probe-feature/core-one"

cleanup() {
    local FIXTURE
    for FIXTURE in "${FIXTURES[@]}"; do
        rm -rf -- "$FIXTURE"
    done
}
trap cleanup EXIT

# _env.sh derives ROOT from this copied bin/ directory. Keeping the harness in
# $TMP/harness also places its sibling signalbox-wt directory below $TMP.
fixture() {
    TMP="$(mktemp -d)"
    FIXTURES+=("$TMP")
    FIXTURE_PATH="$TMP/harness"
    STUB_BIN="$TMP/stub-bin"
    ARGV_LOG="$TMP/argv.log"
    OUT="$TMP/stdout"
    ERR="$TMP/stderr"
    WT="$TMP/signalbox-wt/$FEATURE-$STAGE-$SHARD"

    mkdir -p "$FIXTURE_PATH" "$STUB_BIN" \
        "$FIXTURE_PATH/runs/probe/logs" \
        "$FIXTURE_PATH/runs/probe/state"
    cp -a "$ROOT/bin" "$FIXTURE_PATH/bin"
    cp -a "$ROOT/prompts" "$FIXTURE_PATH/prompts"
    : >"$ARGV_LOG"

    cat >"$STUB_BIN/codex" <<'STUB'
#!/usr/bin/env bash
printf 'ARG=%s\n' "$@" >>"$STUB_ARGV_LOG"
OUT=""
while [ "$#" -gt 0 ]; do
    if [ "$1" = "-o" ]; then
        OUT="$2"
        shift
    fi
    shift
done
[ -z "$OUT" ] || printf 'stub review\n\nAPPROVED\n' >"$OUT"
printf '{"type":"thread.started","thread_id":"stub-thread"}\n'
STUB

    cat >"$STUB_BIN/claude" <<'STUB'
#!/usr/bin/env bash
printf 'ARG=%s\n' "$@" >>"$STUB_ARGV_LOG"
STUB
    chmod +x "$STUB_BIN/codex" "$STUB_BIN/claude"

    mkdir -p "$WT/src" "$WT/docs"
    git init -q -b integration/stream-demo "$WT"
    printf 'owned base\n' >"$WT/src/owned.txt"
    printf 'declared base\n' >"$WT/docs/declared.md"
    printf 'extra base\n' >"$WT/src/extra file.txt"
    git -C "$WT" add .
    git -C "$WT" \
        -c user.name=t \
        -c user.email=t@example.com \
        -c commit.gpgsign=false \
        commit -qm "base"
    git -C "$WT" checkout -qb "$BRANCH"
}

write_plan() {
    local PLAN_SHARD="${1:-$SHARD}"
    local FILES="${2:-[\"src/owned.txt\"]}"
    jq -n \
        --arg feature "$FEATURE" \
        --arg stage "$STAGE" \
        --arg shard "$PLAN_SHARD" \
        --argjson files "$FILES" \
        '{
            feature: $feature,
            stages: [{
                id: $stage,
                shards: [{id: $shard, files: $files}]
            }]
        }' >"$FIXTURE_PATH/runs/probe/plan.json"
}

commit_subject() {
    git -C "$WT" add .
    git -C "$WT" \
        -c user.name=t \
        -c user.email=t@example.com \
        -c commit.gpgsign=false \
        commit -qm "subject"
}

payload() {
    jq -nc \
        --arg feature "$FEATURE" \
        --arg stage "$STAGE" \
        --arg shard "$SHARD" \
        --arg branch "$BRANCH" \
        '{
            feature: $feature,
            stage: $stage,
            expected: 3,
            worker: "0",
            pending: [{shard: "two", branch: "shard/probe-feature/core-two"}],
            done: ["prior"],
            branches: ["shard/probe-feature/prior"],
            current: {shard: $shard, branch: $branch},
            round: 2,
            thread_id: "thread-inbound",
            feedback: "prior finding",
            provenance: {agent: "claude", model: "stub-fixer", effort: "high"}
        }'
}

run_reviewer() {
    local INPUT="$1"
    local WORKER="${2:-0}"
    PATH="$STUB_BIN:$PATH" \
        STUB_ARGV_LOG="$ARGV_LOG" \
        SIGNALBOX_RUN_SLUG=probe \
        "$FIXTURE_PATH/bin/shard-review.sh" "$WORKER" \
        <<<"$INPUT" >"$OUT" 2>"$ERR"
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

# 1. A clean shard reaches Codex and emits the stub's verdict.
fixture
write_plan
printf 'owned change\n' >"$WT/src/owned.txt"
commit_subject
CLEAN_PAYLOAD="$(payload)"
run_reviewer "$CLEAN_PAYLOAD"
OK=1
if [ "$RUN_STATUS" -eq 0 ] \
    && [ -s "$ARGV_LOG" ] \
    && [ "$(jq -r '.verdict' "$OUT" 2>/dev/null)" = "APPROVED" ]; then
    OK=0
fi
report_case "declared-only changes invoke Codex and use its verdict" "$OK" \
    "status=$RUN_STATUS verdict=$(jq -r '.verdict // empty' "$OUT" 2>/dev/null) stderr=$(head -c 160 "$ERR")"

# 2. An undeclared path short-circuits to a scope review without any model.
fixture
write_plan "$SHARD" '["src/owned.txt","docs/declared.md"]'
printf 'owned change\n' >"$WT/src/owned.txt"
printf 'extra change\n' >"$WT/src/extra file.txt"
commit_subject
VIOLATION_PAYLOAD="$(payload)"
run_reviewer "$VIOLATION_PAYLOAD"
LAST="$FIXTURE_PATH/runs/probe/logs/shard-review-$STAGE-$SHARD-r2.md"
EMITTED_REVIEW="$TMP/emitted-review"
jq -j '.review' "$OUT" >"$EMITTED_REVIEW" 2>/dev/null
OK=1
if [ "$RUN_STATUS" -eq 0 ] \
    && [ ! -s "$ARGV_LOG" ] \
    && [ "$(jq -r '.verdict' "$OUT" 2>/dev/null)" = "REQUEST_CHANGES" ] \
    && grep -Fq "## Shard scope violation" "$EMITTED_REVIEW" \
    && grep -Fq "src/extra file.txt" "$EMITTED_REVIEW" \
    && grep -Fq "src/owned.txt" "$EMITTED_REVIEW" \
    && grep -Fq "docs/declared.md" "$EMITTED_REVIEW" \
    && grep -Fq '```diff' "$EMITTED_REVIEW" \
    && grep -Fq "extra change" "$EMITTED_REVIEW" \
    && ! grep -Fq "owned change" "$EMITTED_REVIEW" \
    && [ -f "$LAST" ] \
    && cmp -s "$EMITTED_REVIEW" "$LAST" \
    && [ "$(jq -r '.thread_id' "$OUT" 2>/dev/null)" = "thread-inbound" ] \
    && jq -e '.provenance == {
        agent: "claude", model: "stub-fixer", effort: "high"
    }' "$OUT" >/dev/null 2>&1 \
    && [ ! -e "$FIXTURE_PATH/runs/probe/state/provenance.json" ]; then
    OK=0
fi
report_case "undeclared changes short-circuit with a persisted scope review" "$OK" \
    "status=$RUN_STATUS codex-argv=$(wc -l <"$ARGV_LOG") stderr=$(head -c 160 "$ERR")"

# 3. Every queue and shard identity field passes through the short circuit.
OK=1
if jq -e \
    --argjson input "$VIOLATION_PAYLOAD" \
    '{
        stage, expected, worker, pending, done, branches, current, round
    } == ($input | {
        stage, expected, worker, pending, done, branches, current, round
    })' "$OUT" >/dev/null 2>&1; then
    OK=0
fi
report_case "scope short-circuit preserves shard identity fields" "$OK"

# 4. A plan without the requested shard is an operational failure.
fixture
write_plan "other"
printf 'owned change\n' >"$WT/src/owned.txt"
commit_subject
MISSING_SHARD_PAYLOAD="$(payload)"
run_reviewer "$MISSING_SHARD_PAYLOAD"
OK=1
if [ "$RUN_STATUS" -eq 1 ] \
    && [ ! -s "$OUT" ] \
    && [ ! -s "$ARGV_LOG" ] \
    && grep -Fq "[shard-review]" "$ERR" \
    && grep -Fq "cannot resolve declared files" "$ERR"; then
    OK=0
fi
report_case "a missing shard declaration fails operationally" "$OK" \
    "status=$RUN_STATUS stdout=$(head -c 80 "$OUT") stderr=$(head -c 160 "$ERR")"

# 5. A missing plan is also an operational failure.
fixture
printf 'owned change\n' >"$WT/src/owned.txt"
commit_subject
MISSING_PLAN_PAYLOAD="$(payload)"
run_reviewer "$MISSING_PLAN_PAYLOAD"
OK=1
if [ "$RUN_STATUS" -eq 1 ] \
    && [ ! -s "$OUT" ] \
    && [ ! -s "$ARGV_LOG" ] \
    && grep -Fq "[shard-review]" "$ERR" \
    && grep -Fq "cannot resolve declared files" "$ERR"; then
    OK=0
fi
report_case "a missing plan fails operationally" "$OK" \
    "status=$RUN_STATUS stdout=$(head -c 80 "$OUT") stderr=$(head -c 160 "$ERR")"

# 6. Worker mismatch exits silently before trying to read the absent plan.
fixture
MISMATCH_PAYLOAD="$(payload | jq -c '.worker = "1"')"
run_reviewer "$MISMATCH_PAYLOAD" 0
OK=1
if [ "$RUN_STATUS" -eq 0 ] \
    && [ ! -s "$OUT" ] \
    && [ ! -s "$ERR" ] \
    && [ ! -s "$ARGV_LOG" ]; then
    OK=0
fi
report_case "worker mismatch stays silent before scope resolution" "$OK" \
    "status=$RUN_STATUS stdout=$(head -c 80 "$OUT") stderr=$(head -c 160 "$ERR")"

printf '%d/%d cases passed\n' "$TESTS_PASSED" "$TESTS_RUN"
[ "$TESTS_PASSED" -eq "$TESTS_RUN" ]
