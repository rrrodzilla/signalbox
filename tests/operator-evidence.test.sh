#!/usr/bin/env bash
# Self-contained test runner for bin/operator.sh's worktree-evidence seam and
# read-only git grants. Every harness and git repository lives in its own
# mktemp -d; the model is always a local stub, so no repository or network
# state is touched. Prints PASS/FAIL per case and exits non-zero on failure.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES=()
TESTS_RUN=0
TESTS_PASSED=0
RUN_STATUS=0
FIXTURE_PATH=""
CASE_ROOT=""
SUBJECT=""
REPO_ROOT_PATH=""
WT_BASE_PATH=""
INT_WT_PATH=""
RUN_DIR_PATH=""
STUB_BIN=""
ARGV_CAPTURE=""
PROMPT_CAPTURE=""
SUBJECT_STDOUT=""
SUBJECT_STDERR=""

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

setup_harness() {
    fixture
    CASE_ROOT="$FIXTURE_PATH"
    SUBJECT="$CASE_ROOT/bin/operator.sh"
    REPO_ROOT_PATH="$CASE_ROOT/repo"
    WT_BASE_PATH="$CASE_ROOT/worktrees"
    INT_WT_PATH="$WT_BASE_PATH/integration"
    RUN_DIR_PATH="$CASE_ROOT/run"
    STUB_BIN="$CASE_ROOT/claude-stub.sh"
    ARGV_CAPTURE="$CASE_ROOT/model.argv"
    PROMPT_CAPTURE="$CASE_ROOT/model.prompt"
    SUBJECT_STDOUT="$CASE_ROOT/subject.stdout"
    SUBJECT_STDERR="$CASE_ROOT/subject.stderr"

    mkdir -p \
        "$CASE_ROOT/bin" \
        "$CASE_ROOT/prompts" \
        "$REPO_ROOT_PATH" \
        "$RUN_DIR_PATH/logs" \
        "$RUN_DIR_PATH/state" \
        "$CASE_ROOT/ledger"
    cp "$ROOT/bin/operator.sh" "$CASE_ROOT/bin/operator.sh"
    cp "$ROOT/bin/worktree-evidence.sh" "$CASE_ROOT/bin/worktree-evidence.sh"
    cp "$ROOT/bin/_provenance.sh" "$CASE_ROOT/bin/_provenance.sh"

    cat >"$CASE_ROOT/bin/_env.sh" <<EOF
# Fixture-local constants. Sourced, not executed.
ROOT="$CASE_ROOT"
RUN_SLUG="fixture-run"
RUN_DIR="$RUN_DIR_PATH"
LEDGER_DIR="$CASE_ROOT/ledger"
REPO_ROOT="$REPO_ROOT_PATH"
WT_BASE="$WT_BASE_PATH"
INT_WT="$INT_WT_PATH"
BASE_BRANCH="main"
INT_BRANCH="integration/fixture"
GATE_DIR="$INT_WT_PATH"
GATE_CMD="true"
ENGINE_PREFIX="fixture"
SEED_WORKDIR="$REPO_ROOT_PATH"
SEED_FEATURE="fixture"
APPROVAL_PORT="8105"
export ROOT RUN_SLUG RUN_DIR LEDGER_DIR REPO_ROOT WT_BASE INT_WT
export BASE_BRANCH INT_BRANCH GATE_DIR GATE_CMD ENGINE_PREFIX
export SEED_WORKDIR SEED_FEATURE APPROVAL_PORT
EOF

    printf '%s\n' 'Fixture operator instructions.' >"$CASE_ROOT/prompts/operator.md"
    cat >"$STUB_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

: "${STUB_ARGV_FILE:?}"
: "${STUB_PROMPT_FILE:?}"
: "${STUB_MODEL_OUTPUT:?}"

printf '%s\n' "$@" >"$STUB_ARGV_FILE"
PROMPT_VALUE=""
while [ "$#" -gt 0 ]; do
    if [ "$1" = "-p" ] && [ "$#" -ge 2 ]; then
        PROMPT_VALUE="$2"
        break
    fi
    shift
done
printf '%s' "$PROMPT_VALUE" >"$STUB_PROMPT_FILE"
printf '%s\n' "$STUB_MODEL_OUTPUT"
EOF
    chmod +x "$SUBJECT" "$CASE_ROOT/bin/worktree-evidence.sh" "$STUB_BIN"
}

init_integration() {
    local BRANCH="$1"
    mkdir -p "$INT_WT_PATH"
    git_fixture "$INT_WT_PATH" init -q -b "$BRANCH"
    printf '%s\n' "tracked" >"$INT_WT_PATH/tracked.txt"
    git_fixture "$INT_WT_PATH" add tracked.txt
    git_fixture "$INT_WT_PATH" commit -q -m initial
}

run_operator() {
    local PHASE="$1"
    local MODEL_OUTPUT="$2"
    local LOG_FILE="$CASE_ROOT/engine.log"
    local PAYLOAD

    printf '%s\n' "fixture engine log" >"$LOG_FILE"
    PAYLOAD="$(
        jq -nc \
            --argjson issue 25 \
            --arg phase "$PHASE" \
            --arg outcome "ARTIFACT" \
            --arg log "$LOG_FILE" \
            --arg correlation_id "fixture-correlation" \
            '{
                issue: $issue,
                phase: $phase,
                outcome: $outcome,
                log: $log,
                correlation_id: $correlation_id
            }'
    )"

    SIGNALBOX_OPERATOR_CLAUDE="$STUB_BIN" \
        STUB_ARGV_FILE="$ARGV_CAPTURE" \
        STUB_PROMPT_FILE="$PROMPT_CAPTURE" \
        STUB_MODEL_OUTPUT="$MODEL_OUTPUT" \
        "$SUBJECT" >"$SUBJECT_STDOUT" 2>"$SUBJECT_STDERR" <<<"$PAYLOAD"
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

argv_has_pair() {
    local FILE="$1"
    local FIRST="$2"
    local SECOND="$3"
    awk -v first="$FIRST" -v second="$SECOND" '
        PREVIOUS == first && $0 == second { FOUND = 1 }
        { PREVIOUS = $0 }
        END { exit FOUND ? 0 : 1 }
    ' "$FILE"
}

evidence_line() {
    awk '
        FOUND && /^\{/ { print; exit }
        $0 == "## Worktree evidence (harness-captured live at operator time)" {
            FOUND = 1
        }
    ' "$PROMPT_CAPTURE"
}

valid_proceed_payload() {
    [ "$RUN_STATUS" -eq 0 ] \
        && [ "$(wc -l <"$SUBJECT_STDOUT")" -eq 1 ] \
        && jq -e \
            '.verdict == "PROCEED"
                and .reason == "stub"
                and .parked == false
                and (.provenance.agent == "claude")' \
            "$SUBJECT_STDOUT" >/dev/null
}

narrow_git_rules() {
    local FILE="$1"
    local WORKTREE="$2"
    local EXPECT_WORKTREE_RULES="$3"
    local RULE
    local OK=0

    while IFS= read -r RULE; do
        case "$RULE" in
            "Bash(git status:*)" \
            | "Bash(git log:*)" \
            | "Bash(git diff:*)" \
            | "Bash(git show:*)" \
            | "Bash(git rev-parse:*)" \
            | "Bash(git symbolic-ref --short HEAD)" \
            | "Bash(git branch --show-current)" \
            | "Bash(git branch --list)" \
            | "Bash(git worktree list:*)")
                ;;
            "Bash(git -C $WORKTREE status --porcelain)" \
            | "Bash(git -C $WORKTREE status --porcelain:*)")
                if [ "$EXPECT_WORKTREE_RULES" -ne 1 ]; then
                    OK=1
                fi
                ;;
            *)
                OK=1
                ;;
        esac
    done < <(grep '^Bash(git ' "$FILE")

    # `symbolic-ref` and `branch` have write modes, so any trailing-argument
    # wildcard on them escapes the read-only contract no matter what else the
    # rule list contains.
    if grep -Fx 'Bash(git -C:*)' "$FILE" >/dev/null \
        || grep -E '^Bash\(git (-C [^ )]+ )?(symbolic-ref|branch)( [^)]*)?:\*\)$' \
            "$FILE" >/dev/null; then
        OK=1
    fi
    return "$OK"
}

PROCEED_OUTPUT="$(
    jq -nc \
        --arg verdict "PROCEED" \
        --arg reason "stub" \
        --argjson parked false \
        '{verdict: $verdict, reason: $reason, parked: $parked}'
)"

# 1. Review with a clean integration worktree injects matching live evidence
# and grants both exact porcelain variants alongside the existing path grant.
setup_harness
init_integration "integration-clean"
EXPECTED_BRANCH="$(git_fixture "$INT_WT_PATH" symbolic-ref --short HEAD)"
EXPECTED_TIP="$(git_fixture "$INT_WT_PATH" rev-parse --short HEAD)"
run_operator "review" "$PROCEED_OUTPUT"
EVIDENCE="$(evidence_line)"
OK=1
if grep -Fx \
        '## Worktree evidence (harness-captured live at operator time)' \
        "$PROMPT_CAPTURE" >/dev/null \
    && grep -E '^- captured: [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' \
        "$PROMPT_CAPTURE" >/dev/null \
    && jq -e \
        --arg branch "$EXPECTED_BRANCH" \
        --arg tip "$EXPECTED_TIP" \
        '.exists == true
            and .clean == true
            and .branch == $branch
            and .tip == $tip' \
        <<<"$EVIDENCE" >/dev/null \
    && argv_has_pair "$ARGV_CAPTURE" "--add-dir" "$WT_BASE_PATH" \
    && grep -Fx \
        "Bash(git -C $INT_WT_PATH status --porcelain)" \
        "$ARGV_CAPTURE" >/dev/null \
    && grep -Fx \
        "Bash(git -C $INT_WT_PATH status --porcelain:*)" \
        "$ARGV_CAPTURE" >/dev/null \
    && valid_proceed_payload; then
    OK=0
fi
report_case "review injects clean live evidence and porcelain grants" "$OK" \
    "status=$RUN_STATUS evidence=$(printf '%.200s' "$EVIDENCE")"

# 2. Dirtiness is evidence for the model, not a reason for the handler to fail.
setup_harness
init_integration "integration-dirty"
printf '%s\n' "changed" >"$INT_WT_PATH/tracked.txt"
printf '%s\n' "new" >"$INT_WT_PATH/untracked.txt"
run_operator "review" "$PROCEED_OUTPUT"
EVIDENCE="$(evidence_line)"
OK=1
if jq -e \
        '.exists == true
            and .clean == false
            and (.porcelain | contains("tracked.txt"))
            and (.porcelain | contains("untracked.txt"))' \
        <<<"$EVIDENCE" >/dev/null \
    && valid_proceed_payload; then
    OK=0
fi
report_case "review carries dirty porcelain without failing" "$OK" \
    "status=$RUN_STATUS evidence=$(printf '%.200s' "$EVIDENCE")"

# 3. Plan runs before worktree creation and must receive neither a misleading
# negative evidence section nor worktree-specific command-line grants.
setup_harness
run_operator "plan" "$PROCEED_OUTPUT"
OK=1
if ! grep -Fx \
        '## Worktree evidence (harness-captured live at operator time)' \
        "$PROMPT_CAPTURE" >/dev/null \
    && ! grep -Fx -- "--add-dir" "$ARGV_CAPTURE" >/dev/null \
    && ! grep '^Bash(git -C ' "$ARGV_CAPTURE" >/dev/null \
    && [ ! -e "$WT_BASE_PATH" ] \
    && valid_proceed_payload; then
    OK=0
fi
report_case "plan omits pre-worktree evidence and grants" "$OK" \
    "status=$RUN_STATUS"

# 4. An existing non-git path becomes valid negative evidence and never
# crashes the operator.
setup_harness
mkdir -p "$INT_WT_PATH"
run_operator "review" "$PROCEED_OUTPUT"
EVIDENCE="$(evidence_line)"
OK=1
if grep -Fx \
        '## Worktree evidence (harness-captured live at operator time)' \
        "$PROMPT_CAPTURE" >/dev/null \
    && jq -e \
        '.exists == false and (.error | length > 0)' \
        <<<"$EVIDENCE" >/dev/null \
    && valid_proceed_payload; then
    OK=0
fi
report_case "review degrades non-git path to negative evidence" "$OK" \
    "status=$RUN_STATUS evidence=$(printf '%.200s' "$EVIDENCE")"

# 5. Preserve the operator's fail-safe default when the model returns prose.
setup_harness
run_operator "review" "This is not a machine-readable verdict."
OK=1
if [ "$RUN_STATUS" -eq 0 ] \
    && [ "$(wc -l <"$SUBJECT_STDOUT")" -eq 1 ] \
    && jq -e \
        '.verdict == "HALT"
            and (.reason | type == "string" and length > 0)
            and .parked == false' \
        "$SUBJECT_STDOUT" >/dev/null; then
    OK=0
fi
report_case "unparseable model output fails safe to HALT" "$OK" \
    "status=$RUN_STATUS stdout=$(head -c 200 "$SUBJECT_STDOUT")"

# 6. Repo-root read-only rules are invariant across all phases: the write-capable
# subcommands are granted only in their exact read-only forms, and the only
# optional git -C rules are the two exact integration porcelain forms.
RULES_OK=0
RULES_DETAIL=""
for TEST_PHASE in plan implement review promote; do
    setup_harness
    EXPECT_WORKTREE_RULES=0
    if [ "$TEST_PHASE" = "review" ] || [ "$TEST_PHASE" = "promote" ]; then
        init_integration "integration-$TEST_PHASE"
        EXPECT_WORKTREE_RULES=1
    fi
    run_operator "$TEST_PHASE" "$PROCEED_OUTPUT"
    if [ "$RUN_STATUS" -ne 0 ] \
        || ! grep -Fx 'Bash(git log:*)' "$ARGV_CAPTURE" >/dev/null \
        || ! grep -Fx 'Bash(git diff:*)' "$ARGV_CAPTURE" >/dev/null \
        || ! grep -Fx 'Bash(git symbolic-ref --short HEAD)' \
            "$ARGV_CAPTURE" >/dev/null \
        || ! grep -Fx 'Bash(git branch --show-current)' \
            "$ARGV_CAPTURE" >/dev/null \
        || ! grep -Fx 'Bash(git branch --list)' "$ARGV_CAPTURE" >/dev/null \
        || ! narrow_git_rules \
            "$ARGV_CAPTURE" "$INT_WT_PATH" "$EXPECT_WORKTREE_RULES"; then
        RULES_OK=1
        RULES_DETAIL="phase=$TEST_PHASE status=$RUN_STATUS"
        break
    fi
done
report_case "repo-root git grants stay read-only in every phase" "$RULES_OK" \
    "$RULES_DETAIL"

printf '%d/%d cases passed\n' "$TESTS_PASSED" "$TESTS_RUN"
[ "$TESTS_PASSED" -eq "$TESTS_RUN" ]
