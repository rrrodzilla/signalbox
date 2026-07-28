#!/usr/bin/env bash
# Self-contained test runner for bin/operator.sh's harness-captured worktree,
# branch, and park-hold evidence plus read-only git grants. Every harness and
# git repository lives in its own mktemp -d; the model is always a local stub,
# so no repository or network state is touched. Prints PASS/FAIL per case and
# exits non-zero on failure.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# An object id is as long as the repository's hash — 40 hex characters under
# SHA-1, 64 under SHA-256 — so every assertion about a pinned read accepts
# either length rather than failing correct output from a SHA-256 repository.
OID_RE='[0-9a-fA-F]{40}|[0-9a-fA-F]{64}'
FIXTURES=()
CHILD_PIDS=()
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
SPAWNED_PID=""
ZOMBIE_PID=""
APPROVE_URL="http://127.0.0.1:8240/approve"
APPROVE_COMMAND="curl -s -X POST $APPROVE_URL -H 'Content-Type: application/json' --data @/fixture/state/pending.json"

cleanup() {
    local FIXTURE PID_VALUE
    for PID_VALUE in ${CHILD_PIDS[@]+"${CHILD_PIDS[@]}"}; do
        kill "$PID_VALUE" 2>/dev/null || true
        wait "$PID_VALUE" 2>/dev/null || true
    done
    for FIXTURE in "${FIXTURES[@]}"; do
        rm -rf -- "$FIXTURE"
    done
}
trap cleanup EXIT

# The park cases assert on a hold the operator re-checks against /proc and the
# clock, so they need real processes rather than invented pids: a live child
# whose start identity can be recorded exactly, and one that has exited.
# shellcheck source=../bin/_liveness.sh
source "$ROOT/bin/_liveness.sh"

spawn_child() {
    sleep 300 &
    SPAWNED_PID=$!
    CHILD_PIDS+=("$SPAWNED_PID")
}

# The state character from /proc/<pid>/stat, read the same way the subject does:
# fields 3+ follow the LAST ')', because comm may itself hold spaces and parens.
proc_state_of() {
    local STAT_LINE=""
    local -a FIELDS=()

    STAT_LINE="$(cat "/proc/$1/stat" 2>/dev/null)" || return 1
    read -ra FIELDS <<<"${STAT_LINE##*)}"
    printf '%s\n' "${FIELDS[0]:-}"
}

# A process that has exited but has not been reaped: it still answers kill(0)
# and keeps its start identity, which is precisely the case the state check
# exists for. The parent execs `sleep` — a process that never waits — so the
# corpse persists for the whole case, and killing that parent (via CHILD_PIDS)
# hands the zombie to init, which reaps it. Returns 1 if no zombie could be
# staged, so a case can fail loudly instead of passing vacuously.
spawn_zombie() {
    local PID_FILE="$1"
    local WAITED=0

    ZOMBIE_PID=""
    bash -c 'sleep 0.2 & printf "%s\n" "$!" >"$1"; exec sleep 300' _ "$PID_FILE" &
    CHILD_PIDS+=("$!")
    while [ "$WAITED" -lt 200 ]; do
        if [ -s "$PID_FILE" ]; then
            ZOMBIE_PID="$(<"$PID_FILE")"
            if [ "$(proc_state_of "$ZOMBIE_PID")" = "Z" ]; then
                return 0
            fi
        fi
        sleep 0.05
        WAITED=$((WAITED + 1))
    done
    return 1
}

# A park record as the supervisor writes one, dated now so the deadline it
# carries has not elapsed.
park_record() {
    local HELD="$1" PID_VALUE="$2" START_VALUE="$3" DEADLINE="$4"

    jq -n \
        --argjson held "$HELD" \
        --arg approve_url "$APPROVE_URL" \
        --arg approve_command "$APPROVE_COMMAND" \
        --argjson pid "${PID_VALUE:-null}" \
        --arg start_id "$START_VALUE" \
        --argjson deadline "$DEADLINE" \
        --arg since "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{
            held: $held,
            approve_url: $approve_url,
            approve_command: $approve_command,
            pid: $pid,
            start_id: $start_id,
            deadline: $deadline,
            since: $since,
            lease_transferred: $held,
            reason: null
        }' >"$RUN_DIR_PATH/state/park.json"
}

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
        -c tag.gpgsign=false \
        -C "$DIR" "$@"
}

setup_harness() {
    # The integration directory name is a parameter because a worktree path is
    # not a token: cases below name one with spaces and shell metacharacters.
    local INT_NAME="${1:-integration}"
    fixture
    CASE_ROOT="$FIXTURE_PATH"
    SUBJECT="$CASE_ROOT/bin/operator.sh"
    REPO_ROOT_PATH="$CASE_ROOT/repo"
    WT_BASE_PATH="$CASE_ROOT/worktrees"
    INT_WT_PATH="$WT_BASE_PATH/$INT_NAME"
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
    cp "$ROOT/bin/_liveness.sh" "$CASE_ROOT/bin/_liveness.sh"

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

init_repo_branches() {
    local BASE="$1"
    local BRANCH="$2"
    local SHARD_FILE="$3"
    git_fixture "$REPO_ROOT_PATH" init -q -b "$BASE"
    printf '%s\n' "base" >"$REPO_ROOT_PATH/base.txt"
    git_fixture "$REPO_ROOT_PATH" add base.txt
    git_fixture "$REPO_ROOT_PATH" commit -q -m base
    git_fixture "$REPO_ROOT_PATH" checkout -q -b "$BRANCH"
    printf '%s\n' "shard" >"$REPO_ROOT_PATH/$SHARD_FILE"
    git_fixture "$REPO_ROOT_PATH" add "$SHARD_FILE"
    git_fixture "$REPO_ROOT_PATH" commit -q -m "shard commit"
}

write_numbered_lines() {
    local FILE="$1"
    local COUNT="$2"

    awk -v count="$COUNT" \
        'BEGIN { for (line = 1; line <= count; line++) print "line " line }' \
        >"$FILE"
}

init_tip_content_fixture() {
    git_fixture "$REPO_ROOT_PATH" init -q -b main
    mkdir -p "$REPO_ROOT_PATH/bin"
    write_numbered_lines "$REPO_ROOT_PATH/bin/thing.sh" 2
    git_fixture "$REPO_ROOT_PATH" add bin/thing.sh
    git_fixture "$REPO_ROOT_PATH" commit -q -m base
    git_fixture "$REPO_ROOT_PATH" checkout -q -b feat/fixture-feature
    write_numbered_lines "$REPO_ROOT_PATH/bin/thing.sh" 20
    git_fixture "$REPO_ROOT_PATH" add bin/thing.sh
    git_fixture "$REPO_ROOT_PATH" commit -q -m "rewrite thing"
    git_fixture "$REPO_ROOT_PATH" checkout -q main
}

set_fixture_base_branch() {
    local BASE="$1"
    printf 'BASE_BRANCH=%s\nexport BASE_BRANCH\n' "$(printf '%q' "$BASE")" \
        >>"$CASE_ROOT/bin/_env.sh"
}

rules_mention() {
    grep '^Bash(' "$ARGV_CAPTURE" | grep -F -- "$1" >/dev/null
}

seed_plan() {
    local FEATURE="$1"
    jq -nc --argjson issue 25 --arg feature "$FEATURE" \
        '{issue: $issue, feature: $feature, stages: []}' \
        >"$RUN_DIR_PATH/plan.json"
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

branch_evidence_line() {
    awk '
        FOUND && /^\{/ { print; exit }
        $0 == "## Branch evidence (harness-captured live at operator time)" {
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

# Every granted git rule must be one whole read-only invocation. A `:*` suffix
# would admit arbitrary trailing arguments — `--output=<file>` on log/diff/show,
# the write modes of symbolic-ref and branch — so any suffix-capable git rule
# fails the case regardless of what else the list contains.
read_only_git_rules() {
    local FILE="$1"
    local WORKTREE="$2"
    local BASE="$3"
    local FEATURE_BRANCH="$4"
    local EXPECT_WORKTREE_RULES="$5"
    local EXPECT_FEATURE_RULES="$6"
    local EXPECT_PINNED_READ_RULES="$7"
    local RULE
    local OK=0
    local WORKTREE_RULES=0
    local FEATURE_RULES=0
    local PINNED_READ_RULES=0
    local PINNED_PATH=""
    local PINNED_RULE_RE="^Bash\(git show ($OID_RE):([A-Za-z0-9._/-]+)\)\$"

    while IFS= read -r RULE; do
        case "$RULE" in
            "Bash(git status --porcelain)" \
            | "Bash(git rev-parse --short HEAD)" \
            | "Bash(git symbolic-ref --short HEAD)" \
            | "Bash(git branch --show-current)" \
            | "Bash(git branch --list)" \
            | "Bash(git worktree list)" \
            | "Bash(git log origin/$BASE --oneline -20)" \
            | "Bash(git show --stat origin/$BASE)")
                ;;
            "Bash(git rev-parse --short $FEATURE_BRANCH)" \
            | "Bash(git log $BASE..$FEATURE_BRANCH --oneline)" \
            | "Bash(git diff --stat $BASE...$FEATURE_BRANCH)")
                if [ -z "$FEATURE_BRANCH" ]; then
                    OK=1
                else
                    FEATURE_RULES=$((FEATURE_RULES + 1))
                fi
                ;;
            "Bash(git -C $WORKTREE status --porcelain)")
                WORKTREE_RULES=$((WORKTREE_RULES + 1))
                ;;
            "Bash(git show "*)
                if [[ "$RULE" =~ $PINNED_RULE_RE ]]; then
                    PINNED_PATH="${BASH_REMATCH[2]}"
                    case "$PINNED_PATH" in
                        "" | -* | /* | *..*) OK=1 ;;
                        *) PINNED_READ_RULES=$((PINNED_READ_RULES + 1)) ;;
                    esac
                else
                    OK=1
                fi
                ;;
            *)
                OK=1
                ;;
        esac
    done < <(grep '^Bash(git' "$FILE")

    if grep -E '^Bash\(git.*:\*\)$' "$FILE" >/dev/null; then
        OK=1
    fi
    if [ "$WORKTREE_RULES" -ne "$EXPECT_WORKTREE_RULES" ] \
        || [ "$FEATURE_RULES" -ne "$EXPECT_FEATURE_RULES" ] \
        || [ "$PINNED_READ_RULES" -ne "$EXPECT_PINNED_READ_RULES" ]; then
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
    && ! grep -F \
        "Bash(git -C $INT_WT_PATH status --porcelain:*)" \
        "$ARGV_CAPTURE" >/dev/null \
    && valid_proceed_payload; then
    OK=0
fi
report_case "review injects clean live evidence and the exact porcelain grant" "$OK" \
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
    && ! grep -F 'feat/' "$ARGV_CAPTURE" >/dev/null \
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

# 6. Park hold evidence is captured by the harness at review time, not inferred
# from the engine log — and a hold is presented as live only when the recorded
# engine is still that exact running process and its deadline has time left.
# The live case exposes the exact endpoint, command, PID, and human-scaled
# deadline without adding any permission grant.
setup_harness
spawn_child
LIVE_PARK_PID="$SPAWNED_PID"
LIVE_PARK_ID="$(proc_identity "$LIVE_PARK_PID")"
park_record true "$LIVE_PARK_PID" "$LIVE_PARK_ID" 86400
run_operator "review" "$PROCEED_OUTPUT"
OK=1
if grep -Fx \
        '## Park hold evidence (harness-captured live at operator time)' \
        "$PROMPT_CAPTURE" >/dev/null \
    && grep -Fx -- '- held: true' "$PROMPT_CAPTURE" >/dev/null \
    && grep -Fx -- '- recorded_held: true' "$PROMPT_CAPTURE" >/dev/null \
    && grep -F -- '- hold_check: pid '"$LIVE_PARK_PID"' is running under its recorded start identity' \
        "$PROMPT_CAPTURE" >/dev/null \
    && grep -Fx -- "- approve_url: \"$APPROVE_URL\"" \
        "$PROMPT_CAPTURE" >/dev/null \
    && grep -Fx -- "- approve_command: \"$APPROVE_COMMAND\"" \
        "$PROMPT_CAPTURE" >/dev/null \
    && grep -Fx -- "- pid: $LIVE_PARK_PID" "$PROMPT_CAPTURE" >/dev/null \
    && grep -Fx -- "- start_id: \"$LIVE_PARK_ID\"" "$PROMPT_CAPTURE" >/dev/null \
    && grep -Fx -- '- deadline: 86400' "$PROMPT_CAPTURE" >/dev/null \
    && valid_proceed_payload; then
    OK=0
fi
report_case "review injects the live park hold record" "$OK" \
    "status=$RUN_STATUS prompt=$(tail -n 16 "$PROMPT_CAPTURE" | tr '\n' ' ')"

# 6a. A recorded hold whose engine has exited is a closed window, however
# confidently the record still claims otherwise: the recorded claim stays
# visible, but the presented hold is the harness's own re-check.
setup_harness
spawn_child
DEAD_PARK_PID="$SPAWNED_PID"
DEAD_PARK_ID="$(proc_identity "$DEAD_PARK_PID")"
kill "$DEAD_PARK_PID" 2>/dev/null || true
wait "$DEAD_PARK_PID" 2>/dev/null || true
park_record true "$DEAD_PARK_PID" "$DEAD_PARK_ID" 86400
run_operator "review" "$PROCEED_OUTPUT"
OK=1
if grep -Fx -- '- held: false' "$PROMPT_CAPTURE" >/dev/null \
    && grep -Fx -- '- recorded_held: true' "$PROMPT_CAPTURE" >/dev/null \
    && grep -F -- 'is no longer running, so the approval window is closed' \
        "$PROMPT_CAPTURE" >/dev/null \
    && valid_proceed_payload; then
    OK=0
fi
report_case "an exited engine is presented as a closed window" "$OK" \
    "status=$RUN_STATUS prompt=$(tail -n 16 "$PROMPT_CAPTURE" | tr '\n' ' ')"

# 6b. A live engine whose park deadline has already run out is equally closed:
# liveness alone never makes the approval webhook reachable.
setup_harness
spawn_child
EXPIRED_PARK_PID="$SPAWNED_PID"
EXPIRED_PARK_ID="$(proc_identity "$EXPIRED_PARK_PID")"
park_record true "$EXPIRED_PARK_PID" "$EXPIRED_PARK_ID" 0
run_operator "review" "$PROCEED_OUTPUT"
OK=1
if grep -Fx -- '- held: false' "$PROMPT_CAPTURE" >/dev/null \
    && grep -Fx -- '- recorded_held: true' "$PROMPT_CAPTURE" >/dev/null \
    && grep -F -- 'the park deadline elapsed' "$PROMPT_CAPTURE" >/dev/null \
    && valid_proceed_payload; then
    OK=0
fi
report_case "an elapsed deadline is presented as a closed window" "$OK" \
    "status=$RUN_STATUS prompt=$(tail -n 16 "$PROMPT_CAPTURE" | tr '\n' ' ')"

# 6c. A hold recorded without a start identity cannot be told apart from a
# recycled pid, so it is not presented as live even while that pid runs.
setup_harness
spawn_child
UNIDENTIFIED_PARK_PID="$SPAWNED_PID"
park_record true "$UNIDENTIFIED_PARK_PID" "" 86400
run_operator "review" "$PROCEED_OUTPUT"
OK=1
if grep -Fx -- '- held: false' "$PROMPT_CAPTURE" >/dev/null \
    && grep -F -- 'carries no start identity' "$PROMPT_CAPTURE" >/dev/null \
    && valid_proceed_payload; then
    OK=0
fi
report_case "a hold without a start identity is never called live" "$OK" \
    "status=$RUN_STATUS prompt=$(tail -n 16 "$PROMPT_CAPTURE" | tr '\n' ' ')"

# 6d. The exited-engine check cannot stop at kill(0). A process that has exited
# but has not been reaped answers it and still carries its recorded start
# identity, while its approval socket is already gone — so the recorded pid and
# the recorded identity both agree with a hold that no longer exists. Only the
# process state separates that corpse from the running engine.
setup_harness
ZOMBIE_CASE="an unreaped exited engine is presented as a closed window"
OK=1
if spawn_zombie "$CASE_ROOT/zombie.pid"; then
    ZOMBIE_ID="$(proc_identity "$ZOMBIE_PID")"
    park_record true "$ZOMBIE_PID" "$ZOMBIE_ID" 86400
    run_operator "review" "$PROCEED_OUTPUT"
    if grep -Fx -- '- held: false' "$PROMPT_CAPTURE" >/dev/null \
        && grep -Fx -- '- recorded_held: true' "$PROMPT_CAPTURE" >/dev/null \
        && grep -F -- 'has already exited (process state Z)' \
            "$PROMPT_CAPTURE" >/dev/null \
        && valid_proceed_payload; then
        OK=0
    fi
    report_case "$ZOMBIE_CASE" "$OK" \
        "status=$RUN_STATUS prompt=$(tail -n 16 "$PROMPT_CAPTURE" | tr '\n' ' ')"
else
    report_case "$ZOMBIE_CASE" "$OK" "no zombie process could be staged"
fi

# 7. A declined hold is still evidence: the operator must receive the recorded
# closed-window reason instead of repeating a dead endpoint from narration.
setup_harness
jq -n '{
    held: false,
    approve_url: "http://127.0.0.1:8240/approve",
    approve_command: "dead command",
    pid: null,
    start_id: null,
    deadline: null,
    since: "2026-07-27T23:42:35Z",
    lease_transferred: false,
    reason: "engine identity was unreadable"
}' >"$RUN_DIR_PATH/state/park.json"
run_operator "review" "$PROCEED_OUTPUT"
OK=1
if grep -Fx -- '- held: false' "$PROMPT_CAPTURE" >/dev/null \
    && grep -Fx -- '- recorded_held: false' "$PROMPT_CAPTURE" >/dev/null \
    && grep -Fx -- '- reason: "engine identity was unreadable"' \
        "$PROMPT_CAPTURE" >/dev/null \
    && valid_proceed_payload; then
    OK=0
fi
report_case "review injects a declined hold and its closed-window reason" \
    "$OK" "status=$RUN_STATUS"

# 8. A torn record must become explicit negative input while normal operator
# verdict parsing continues unaffected.
setup_harness
printf '%s\n' '{"held": true, "approve_url":' \
    >"$RUN_DIR_PATH/state/park.json"
run_operator "review" "$PROCEED_OUTPUT"
OK=1
if grep -Fx \
        '## Park hold evidence (harness-captured live at operator time)' \
        "$PROMPT_CAPTURE" >/dev/null \
    && grep -Fx '(park record unavailable or malformed)' \
        "$PROMPT_CAPTURE" >/dev/null \
    && valid_proceed_payload; then
    OK=0
fi
report_case "malformed park record is explicit and non-fatal" "$OK" \
    "status=$RUN_STATUS"

# 9. Absence means there was no park-hold record to inject; it must not create a
# misleading unavailable section.
setup_harness
run_operator "review" "$PROCEED_OUTPUT"
OK=1
if ! grep -Fx \
        '## Park hold evidence (harness-captured live at operator time)' \
        "$PROMPT_CAPTURE" >/dev/null \
    && valid_proceed_payload; then
    OK=0
fi
report_case "review without a park record omits the park section" "$OK" \
    "status=$RUN_STATUS"

# 10. Park state belongs only to the review seam. A stale file must never leak into
# another phase's operator prompt.
setup_harness
jq -n '{
    held: true,
    approve_url: "http://127.0.0.1:8240/approve",
    approve_command: "stale command",
    pid: 12345,
    deadline: 86400,
    since: "2026-07-27T23:42:35Z",
    lease_transferred: true,
    reason: null
}' >"$RUN_DIR_PATH/state/park.json"
run_operator "plan" "$PROCEED_OUTPUT"
OK=1
if ! grep -Fx \
        '## Park hold evidence (harness-captured live at operator time)' \
        "$PROMPT_CAPTURE" >/dev/null \
    && valid_proceed_payload; then
    OK=0
fi
report_case "non-review phase never receives park hold evidence" "$OK" \
    "status=$RUN_STATUS"

# 11. Read-only git rules are invariant across all phases: every granted git
# command is one exact read-only invocation with no trailing wildcard, the
# ref-bearing forms come from the run's own plan, and the only optional git -C
# rule is the exact integration porcelain form.
RULES_OK=0
RULES_DETAIL=""
for TEST_PHASE in plan implement review promote; do
    setup_harness
    seed_plan "fixture-feature"
    EXPECT_WORKTREE_RULES=0
    if [ "$TEST_PHASE" = "review" ] || [ "$TEST_PHASE" = "promote" ]; then
        init_integration "integration-$TEST_PHASE"
        EXPECT_WORKTREE_RULES=1
    fi
    run_operator "$TEST_PHASE" "$PROCEED_OUTPUT"
    EXPECT_BRANCH_SECTION=0
    if [ "$TEST_PHASE" = "implement" ] || [ "$TEST_PHASE" = "review" ]; then
        EXPECT_BRANCH_SECTION=1
    fi
    ACTUAL_BRANCH_SECTION=0
    if grep -Fx \
            '## Branch evidence (harness-captured live at operator time)' \
            "$PROMPT_CAPTURE" >/dev/null; then
        ACTUAL_BRANCH_SECTION=1
    fi
    if [ "$RUN_STATUS" -ne 0 ] \
        || [ "$ACTUAL_BRANCH_SECTION" -ne "$EXPECT_BRANCH_SECTION" ] \
        || ! grep -Fx 'Bash(git status --porcelain)' "$ARGV_CAPTURE" >/dev/null \
        || ! grep -Fx 'Bash(git symbolic-ref --short HEAD)' \
            "$ARGV_CAPTURE" >/dev/null \
        || ! grep -Fx 'Bash(git branch --show-current)' \
            "$ARGV_CAPTURE" >/dev/null \
        || ! grep -Fx 'Bash(git branch --list)' "$ARGV_CAPTURE" >/dev/null \
        || ! grep -Fx 'Bash(git log main..feat/fixture-feature --oneline)' \
            "$ARGV_CAPTURE" >/dev/null \
        || ! grep -Fx 'Bash(git diff --stat main...feat/fixture-feature)' \
            "$ARGV_CAPTURE" >/dev/null \
        || ! read_only_git_rules \
            "$ARGV_CAPTURE" "$INT_WT_PATH" "main" "feat/fixture-feature" \
            "$EXPECT_WORKTREE_RULES" 3 0; then
        RULES_OK=1
        RULES_DETAIL="phase=$TEST_PHASE status=$RUN_STATUS"
        break
    fi
done
report_case "git grants stay exact and read-only in every phase" "$RULES_OK" \
    "$RULES_DETAIL"

# 12. The ref-bearing rules are interpolated from plan.json, so a slug that is
# not a kebab-case token must yield no rule at all rather than an unbounded or
# argument-bearing one.
RULES_OK=0
RULES_DETAIL=""
for BAD_FEATURE in 'a b --output=/tmp/x' '../escape' 'Feature' '-lead' 'trail-'; do
    setup_harness
    seed_plan "$BAD_FEATURE"
    run_operator "implement" "$PROCEED_OUTPUT"
    if [ "$RUN_STATUS" -ne 0 ] \
        || grep -F 'feat/' "$ARGV_CAPTURE" >/dev/null \
        || ! read_only_git_rules \
            "$ARGV_CAPTURE" "$INT_WT_PATH" "main" "" 0 0 0; then
        RULES_OK=1
        RULES_DETAIL="feature=$BAD_FEATURE status=$RUN_STATUS"
        break
    fi
done
report_case "a non-slug plan feature grants no ref-bearing rule" "$RULES_OK" \
    "$RULES_DETAIL"

# 13. A rule is one exact command string, and git accepts branch names carrying
# shell metacharacters, so a base branch that is not a plain ref token must
# yield no rule bearing it — neither the origin/<base> forms nor the two
# feature rules built from it — instead of a rule parsed as shell syntax.
RULES_OK=0
RULES_DETAIL=""
for BAD_BASE in 'main;id' 'main --output=/tmp/x' 'main$(id)' '-main' 'a..b'; do
    setup_harness
    seed_plan "fixture-feature"
    set_fixture_base_branch "$BAD_BASE"
    run_operator "implement" "$PROCEED_OUTPUT"
    if [ "$RUN_STATUS" -ne 0 ] \
        || rules_mention "$BAD_BASE" \
        || rules_mention 'Bash(git log origin/' \
        || rules_mention 'Bash(git show --stat origin/' \
        || ! grep -Fx 'Bash(git rev-parse --short feat/fixture-feature)' \
            "$ARGV_CAPTURE" >/dev/null \
        || ! read_only_git_rules \
            "$ARGV_CAPTURE" "$INT_WT_PATH" "" "feat/fixture-feature" 0 1 0; then
        RULES_OK=1
        RULES_DETAIL="base=$BAD_BASE status=$RUN_STATUS"
        break
    fi
done
report_case "a non-token base branch grants no rule bearing it" "$RULES_OK" \
    "$RULES_DETAIL"

# 14. The implement terminal's commit and diff checks must stay completable for
# every base branch git accepts, including one no exact rule can spell. The
# harness compares the branches itself — refs as arguments, never shell words —
# and injects the same two facts, so the omitted rules cost no verification.
RULES_OK=0
RULES_DETAIL=""
for TEST_BASE in 'main' 'main;id' 'main$(id)'; do
    setup_harness
    seed_plan "fixture-feature"
    set_fixture_base_branch "$TEST_BASE"
    init_repo_branches "$TEST_BASE" "feat/fixture-feature" "shard.txt"
    run_operator "implement" "$PROCEED_OUTPUT"
    BRANCH_EVIDENCE="$(branch_evidence_line)"
    if [ "$RUN_STATUS" -ne 0 ] \
        || ! grep -Fx \
            '## Branch evidence (harness-captured live at operator time)' \
            "$PROMPT_CAPTURE" >/dev/null \
        || ! grep -E '^- captured: [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' \
            "$PROMPT_CAPTURE" >/dev/null \
        || ! jq -e \
            --arg base "$TEST_BASE" \
            '.resolved == true
                and .base == $base
                and .branch == "feat/fixture-feature"
                and (.commits | length) == 1
                and (.files == ["shard.txt"])
                and (.branch_tip_short | length > 0)
                and (.diffstat | contains("shard.txt"))' \
            <<<"$BRANCH_EVIDENCE" >/dev/null \
        || ! valid_proceed_payload; then
        RULES_OK=1
        RULES_DETAIL="base=$TEST_BASE status=$RUN_STATUS evidence=$(printf '%.200s' "$BRANCH_EVIDENCE")"
        break
    fi
done
report_case "implement carries harness-captured branch evidence for any base" \
    "$RULES_OK" "$RULES_DETAIL"

# 15. Branch evidence is honest about its own gaps: when the refs do not
# resolve the operator must still emit a verdict payload, carrying an explicit
# error rather than a silently empty commit list that reads as a clean diff.
setup_harness
seed_plan "fixture-feature"
git_fixture "$REPO_ROOT_PATH" init -q -b main
run_operator "implement" "$PROCEED_OUTPUT"
BRANCH_EVIDENCE="$(branch_evidence_line)"
OK=1
if jq -e \
        '.resolved == false
            and (.error | length > 0)
            and (has("commits") | not)
            and (has("tip_files") | not)
            and (has("tip_files_truncated") | not)
            and (has("tip_files_limit") | not)' \
        <<<"$BRANCH_EVIDENCE" >/dev/null \
    && ! grep -E "^Bash\(git show ($OID_RE):" \
        "$ARGV_CAPTURE" >/dev/null \
    && valid_proceed_payload; then
    OK=0
fi
report_case "unresolvable branches become explicit negative branch evidence" \
    "$OK" "status=$RUN_STATUS evidence=$(printf '%.200s' "$BRANCH_EVIDENCE")"

# 16. gitrevisions resolves a bare name through refs/tags before refs/heads,
# so a tag named after either configured branch would substitute its history
# while the evidence still reads resolved. The harness pins both names inside
# refs/heads: with the tags deliberately crossed (tag main at the feature tip,
# tag feat/... at the base tip), only branch resolution yields the shard commit.
setup_harness
seed_plan "fixture-feature"
init_repo_branches "main" "feat/fixture-feature" "shard.txt"
BASE_TIP_FULL="$(git_fixture "$REPO_ROOT_PATH" rev-parse refs/heads/main)"
FEATURE_TIP_FULL="$(
    git_fixture "$REPO_ROOT_PATH" rev-parse refs/heads/feat/fixture-feature
)"
git_fixture "$REPO_ROOT_PATH" tag main "$FEATURE_TIP_FULL"
git_fixture "$REPO_ROOT_PATH" tag feat/fixture-feature "$BASE_TIP_FULL"
run_operator "implement" "$PROCEED_OUTPUT"
BRANCH_EVIDENCE="$(branch_evidence_line)"
OK=1
if jq -e \
        --arg base_tip "$BASE_TIP_FULL" \
        --arg branch_tip "$FEATURE_TIP_FULL" \
        '.resolved == true
            and .base_tip == $base_tip
            and .branch_tip == $branch_tip
            and (.commits | length) == 1
            and (.files == ["shard.txt"])' \
        <<<"$BRANCH_EVIDENCE" >/dev/null \
    && valid_proceed_payload; then
    OK=0
fi
report_case "tags named after the branches cannot shadow branch evidence" \
    "$OK" "status=$RUN_STATUS evidence=$(printf '%.200s' "$BRANCH_EVIDENCE")"

# 17. A worktree path is not a token either — git accepts spaces and shell
# metacharacters in one — and a rule is an exact command string, so the path
# must be embedded already escaped. Unescaped, the granted text parses as
# several words (or as shell syntax) when run verbatim, while the quoting the
# operator would add stops matching the rule: the corroborating check is
# unavailable either way. The granted rule must therefore run verbatim against
# that exact worktree, and the prompt must publish the same string so the
# operator runs precisely what was granted.
RULES_OK=0
RULES_DETAIL=""
for INT_NAME in 'integration wt' "integration'wt" 'integration;id'; do
    setup_harness "$INT_NAME"
    init_integration "integration-escaped"
    EXPECTED_CMD="git -C $(printf '%q' "$INT_WT_PATH") status --porcelain"
    run_operator "review" "$PROCEED_OUTPUT"
    GRANTED_CMD="$(grep -m1 '^Bash(git -C ' "$ARGV_CAPTURE" || true)"
    GRANTED_CMD="${GRANTED_CMD#Bash(}"
    GRANTED_CMD="${GRANTED_CMD%)}"
    # Running the granted string verbatim is the whole claim: a clean fixture
    # worktree yields empty output, while a misparsed path yields a git error
    # or the output of whatever the metacharacters spawned.
    PORCELAIN_OUT="$(eval "$GRANTED_CMD" 2>&1)"
    if [ "$RUN_STATUS" -ne 0 ] \
        || [ "$GRANTED_CMD" != "$EXPECTED_CMD" ] \
        || [ -n "$PORCELAIN_OUT" ] \
        || ! grep -Fx -- \
            "- integration worktree status command: $EXPECTED_CMD" \
            "$PROMPT_CAPTURE" >/dev/null \
        || ! jq -e '.exists == true and .clean == true' \
            <<<"$(evidence_line)" >/dev/null \
        || ! valid_proceed_payload; then
        RULES_OK=1
        RULES_DETAIL="worktree=$INT_NAME status=$RUN_STATUS granted=$GRANTED_CMD"
        break
    fi
done
report_case "a worktree path carrying shell characters is granted escaped" \
    "$RULES_OK" "$RULES_DETAIL"

# 18. Regression for issue #36: the primary checkout remains on main, whose
# copy has 2 lines, while review evidence must describe the feature tip's
# 20-line blob instead of accidentally reading the working tree.
setup_harness
seed_plan "fixture-feature"
init_tip_content_fixture
EXPECTED_BLOB="$(
    git_fixture "$REPO_ROOT_PATH" \
        rev-parse refs/heads/feat/fixture-feature:bin/thing.sh
)"
WORKTREE_LINES="$(wc -l <"$REPO_ROOT_PATH/bin/thing.sh")"
run_operator "review" "$PROCEED_OUTPUT"
BRANCH_EVIDENCE="$(branch_evidence_line)"
OK=1
if grep -Fx \
        '## Branch evidence (harness-captured live at operator time)' \
        "$PROMPT_CAPTURE" >/dev/null \
    && [ "$WORKTREE_LINES" -eq 2 ] \
    && jq -e \
        --arg blob "$EXPECTED_BLOB" \
        '.tip_files[]
            | select(.path == "bin/thing.sh")
            | .present == true and .lines == 20 and .blob == $blob' \
        <<<"$BRANCH_EVIDENCE" >/dev/null \
    && valid_proceed_payload; then
    OK=0
fi
report_case "issue #36 review evidence reads the feature tip, not main" \
    "$OK" "status=$RUN_STATUS evidence=$(printf '%.240s' "$BRANCH_EVIDENCE")"

# 19. The evidence-published command is the granted command, and executing it
# from the operator's repo-root cwd reads the pinned feature blob.
setup_harness
seed_plan "fixture-feature"
init_tip_content_fixture
run_operator "review" "$PROCEED_OUTPUT"
BRANCH_EVIDENCE="$(branch_evidence_line)"
mapfile -t PINNED_READS < <(
    jq -r '.tip_files[]? | .pinned_read // empty' <<<"$BRANCH_EVIDENCE"
)
PINNED_RULES_OK=0
PINNED_OUTPUT=""
for PINNED_READ in "${PINNED_READS[@]}"; do
    if ! grep -Fx "Bash($PINNED_READ)" "$ARGV_CAPTURE" >/dev/null; then
        PINNED_RULES_OK=1
        break
    fi
done
if [ "${#PINNED_READS[@]}" -eq 1 ]; then
    PINNED_OUTPUT="$(
        cd "$REPO_ROOT_PATH" && bash -c "${PINNED_READS[0]}"
    )"
else
    PINNED_RULES_OK=1
fi
OK=1
if [ "$PINNED_RULES_OK" -eq 0 ] \
    && [ "$(wc -l <<<"$PINNED_OUTPUT")" -eq 20 ] \
    && [ "$(wc -l <"$REPO_ROOT_PATH/bin/thing.sh")" -eq 2 ] \
    && ! grep -E '^Bash\(git show .*\*.*\)$' "$ARGV_CAPTURE" >/dev/null \
    && read_only_git_rules \
        "$ARGV_CAPTURE" "$INT_WT_PATH" "main" "feat/fixture-feature" 0 3 1 \
    && valid_proceed_payload; then
    OK=0
fi
report_case "tip-pinned reads are granted exactly and read tip content" \
    "$OK" "status=$RUN_STATUS pinned=${PINNED_READS[*]:-none}"

# 20. Paths that cannot be one safe rule token remain visible as content
# evidence, but neither their published entries nor allowedTools grant a read.
# The quoted path also pins the listing format: git C-quotes a path carrying a
# double quote in line-delimited output, and that spelling names no tree entry,
# so an evidence list built from it would publish a path the branch does not
# contain and report the real file as absent.
setup_harness
seed_plan "fixture-feature"
SPACE_PATH="with space.txt"
COMMAND_PATH='$(id).txt'
QUOTE_PATH='say"quote.txt'
git_fixture "$REPO_ROOT_PATH" init -q -b main
printf '%s\n' base >"$REPO_ROOT_PATH/base.txt"
git_fixture "$REPO_ROOT_PATH" add base.txt
git_fixture "$REPO_ROOT_PATH" commit -q -m base
git_fixture "$REPO_ROOT_PATH" checkout -q -b feat/fixture-feature
printf '%s\n' spaced >"$REPO_ROOT_PATH/$SPACE_PATH"
printf '%s\n' literal >"$REPO_ROOT_PATH/$COMMAND_PATH"
printf '%s\n' quoted >"$REPO_ROOT_PATH/$QUOTE_PATH"
git_fixture "$REPO_ROOT_PATH" add "$SPACE_PATH" "$COMMAND_PATH" "$QUOTE_PATH"
git_fixture "$REPO_ROOT_PATH" commit -q -m "add non-token paths"
run_operator "implement" "$PROCEED_OUTPUT"
BRANCH_EVIDENCE="$(branch_evidence_line)"
OK=1
if jq -e \
        --arg space "$SPACE_PATH" \
        --arg command "$COMMAND_PATH" \
        --arg quote "$QUOTE_PATH" \
        '(.files | index($quote) != null)
            and ([.tip_files[].path] | index($space) != null)
            and ([.tip_files[].path] | index($command) != null)
            and ([.tip_files[].path] | index($quote) != null)
            and all(
                .tip_files[];
                if .path == $space
                    or .path == $command
                    or .path == $quote
                then
                    .present == true and (has("pinned_read") | not)
                else true
                end
            )' \
        <<<"$BRANCH_EVIDENCE" >/dev/null \
    && ! rules_mention "$SPACE_PATH" \
    && ! rules_mention "$COMMAND_PATH" \
    && ! rules_mention "$QUOTE_PATH" \
    && valid_proceed_payload; then
    OK=0
fi
report_case "non-token paths are described without granting a command" \
    "$OK" "status=$RUN_STATUS evidence=$(printf '%.240s' "$BRANCH_EVIDENCE")"

# 21. A path removed by the feature diff has no branch-tip blob to identify or
# read, so its evidence is the minimal exact negative object.
setup_harness
seed_plan "fixture-feature"
DELETED_PATH="deleted.txt"
git_fixture "$REPO_ROOT_PATH" init -q -b main
printf '%s\n' delete-me >"$REPO_ROOT_PATH/$DELETED_PATH"
git_fixture "$REPO_ROOT_PATH" add "$DELETED_PATH"
git_fixture "$REPO_ROOT_PATH" commit -q -m base
git_fixture "$REPO_ROOT_PATH" checkout -q -b feat/fixture-feature
git_fixture "$REPO_ROOT_PATH" rm -q "$DELETED_PATH"
git_fixture "$REPO_ROOT_PATH" commit -q -m "delete file"
run_operator "implement" "$PROCEED_OUTPUT"
BRANCH_EVIDENCE="$(branch_evidence_line)"
OK=1
if jq -e \
        --arg path "$DELETED_PATH" \
        'any(
            .tip_files[];
            . == {path: $path, present: false}
        )' \
        <<<"$BRANCH_EVIDENCE" >/dev/null \
    && ! rules_mention "$DELETED_PATH" \
    && valid_proceed_payload; then
    OK=0
fi
report_case "deleted feature files carry exact negative tip evidence" \
    "$OK" "status=$RUN_STATUS evidence=$(printf '%.240s' "$BRANCH_EVIDENCE")"

# 22. The cap is part of the evidence contract so a large diff cannot look
# complete after its content identities and grants are intentionally bounded.
setup_harness
seed_plan "fixture-feature"
git_fixture "$REPO_ROOT_PATH" init -q -b main
printf '%s\n' base >"$REPO_ROOT_PATH/base.txt"
git_fixture "$REPO_ROOT_PATH" add base.txt
git_fixture "$REPO_ROOT_PATH" commit -q -m base
git_fixture "$REPO_ROOT_PATH" checkout -q -b feat/fixture-feature
for INDEX in {1..45}; do
    printf -v MANY_PATH 'file-%02d.txt' "$INDEX"
    printf '%s\n' "$INDEX" >"$REPO_ROOT_PATH/$MANY_PATH"
done
git_fixture "$REPO_ROOT_PATH" add .
git_fixture "$REPO_ROOT_PATH" commit -q -m "add many files"
run_operator "implement" "$PROCEED_OUTPUT"
BRANCH_EVIDENCE="$(branch_evidence_line)"
PINNED_RULE_COUNT="$(
    grep -Ec "^Bash\(git show ($OID_RE):[A-Za-z0-9._/-]+\)\$" \
        "$ARGV_CAPTURE" || true
)"
OK=1
if jq -e \
        '.tip_files | length == 40' \
        <<<"$BRANCH_EVIDENCE" >/dev/null \
    && jq -e \
        '.tip_files_truncated == true and .tip_files_limit == 40' \
        <<<"$BRANCH_EVIDENCE" >/dev/null \
    && [ "$PINNED_RULE_COUNT" -le 40 ] \
    && valid_proceed_payload; then
    OK=0
fi
report_case "tip-file truncation is explicit and caps pinned grants" \
    "$OK" "status=$RUN_STATUS pinned_rules=$PINNED_RULE_COUNT"

# 23. A changed gitlink is a present tree entry whose target commit normally
# lives in the submodule's object store rather than this repository's, so the
# entry's own type — not what the object database can answer about the target —
# decides its evidence: present as a gitlink, with none of the blob claims
# (size, line count, pinned read) a submodule commit could ever support.
setup_harness
seed_plan "fixture-feature"
git_fixture "$REPO_ROOT_PATH" init -q -b main
printf '%s\n' base >"$REPO_ROOT_PATH/base.txt"
git_fixture "$REPO_ROOT_PATH" add base.txt
git_fixture "$REPO_ROOT_PATH" commit -q -m base
GITLINK_COMMIT="$(git_fixture "$REPO_ROOT_PATH" rev-parse refs/heads/main)"
git_fixture "$REPO_ROOT_PATH" checkout -q -b feat/fixture-feature
# An empty directory beside the index entry is the ordinary uninitialised
# submodule shape; the entry itself is what the evidence must describe.
mkdir -p "$REPO_ROOT_PATH/sub"
git_fixture "$REPO_ROOT_PATH" update-index --add \
    --cacheinfo "160000,$GITLINK_COMMIT,sub"
git_fixture "$REPO_ROOT_PATH" commit -q -m "add gitlink"
run_operator "implement" "$PROCEED_OUTPUT"
BRANCH_EVIDENCE="$(branch_evidence_line)"
OK=1
if jq -e \
        --arg commit "$GITLINK_COMMIT" \
        '(.files | index("sub") != null)
            and any(
                .tip_files[];
                . == {
                    path: "sub",
                    present: true,
                    type: "gitlink",
                    commit: $commit
                }
            )' \
        <<<"$BRANCH_EVIDENCE" >/dev/null \
    && ! rules_mention ":sub)" \
    && valid_proceed_payload; then
    OK=0
fi
report_case "a changed gitlink is present evidence without blob claims" \
    "$OK" "status=$RUN_STATUS evidence=$(printf '%.240s' "$BRANCH_EVIDENCE")"

# 24. Git imposes no encoding on a pathname, but JSON is UTF-8 and jq's --arg
# substitutes U+FFFD for every byte that is not part of a valid sequence. Two
# paths differing only in those bytes would then publish as one identical
# string: one real file described twice, the other not at all, under an
# exact-path claim. Each must instead stay reversible to its own exact bytes.
setup_harness
seed_plan "fixture-feature"
BYTES_PATH_A=$'invalid-\xff.txt'
BYTES_PATH_B=$'invalid-\xfe.txt'
EXPECTED_B64_A="$(printf '%s' "$BYTES_PATH_A" | base64 | tr -d '\n')"
EXPECTED_B64_B="$(printf '%s' "$BYTES_PATH_B" | base64 | tr -d '\n')"
git_fixture "$REPO_ROOT_PATH" init -q -b main
printf '%s\n' base >"$REPO_ROOT_PATH/base.txt"
git_fixture "$REPO_ROOT_PATH" add base.txt
git_fixture "$REPO_ROOT_PATH" commit -q -m base
git_fixture "$REPO_ROOT_PATH" checkout -q -b feat/fixture-feature
printf '%s\n' a >"$REPO_ROOT_PATH/$BYTES_PATH_A"
printf '%s\n' b >"$REPO_ROOT_PATH/$BYTES_PATH_B"
git_fixture "$REPO_ROOT_PATH" add -- "$BYTES_PATH_A" "$BYTES_PATH_B"
git_fixture "$REPO_ROOT_PATH" commit -q -m "add non-utf8 paths"
run_operator "implement" "$PROCEED_OUTPUT"
BRANCH_EVIDENCE="$(branch_evidence_line)"
OK=1
if jq -e \
        --arg a "$EXPECTED_B64_A" \
        --arg b "$EXPECTED_B64_B" \
        '([.files[] | .path_base64] | sort) == ([$a, $b] | sort)
            and all(
                .files[];
                .path_encoding == "base64" and (has("path") | not)
            )
            and ([.tip_files[] | .path_base64] | sort) == ([$a, $b] | sort)
            and all(
                .tip_files[];
                .present == true
                    and .path_encoding == "base64"
                    and (has("path") | not)
                    and (has("pinned_read") | not)
            )' \
        <<<"$BRANCH_EVIDENCE" >/dev/null \
    && read_only_git_rules \
        "$ARGV_CAPTURE" "$INT_WT_PATH" "main" "feat/fixture-feature" 0 3 0 \
    && valid_proceed_payload; then
    OK=0
fi
report_case "paths JSON cannot carry stay distinct and byte-reversible" \
    "$OK" "status=$RUN_STATUS evidence=$(printf '%.240s' "$BRANCH_EVIDENCE")"

printf '%d/%d cases passed\n' "$TESTS_PASSED" "$TESTS_RUN"
[ "$TESTS_PASSED" -eq "$TESTS_RUN" ]
