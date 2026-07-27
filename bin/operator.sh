#!/usr/bin/env bash
# Pipeline operator: stdin = phase.done {issue, phase, outcome, log, correlation_id}
# stdout = phase.verified (input + {verdict, reason, parked, provenance})
#
# Headless Fable applies the phantom-run discipline as topology: never trust
# the runner's outcome, verify the phase's disk artifacts first-hand, then
# PROCEED or HALT. Review and promote prompts include harness-captured live
# integration-worktree evidence; implement prompts include the harness-captured
# live branch comparison. Fail-safe: an unparseable verdict is a HALT
# — when the operator can't be understood, the pipeline stops.
set -euo pipefail
# shellcheck source=_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/_env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/_provenance.sh"

PAYLOAD="$(cat)"
PHASE="$(jq -r '.phase' <<<"$PAYLOAD")"
OUTCOME="$(jq -r '.outcome' <<<"$PAYLOAD")"
ISSUE="$(jq -r '.issue' <<<"$PAYLOAD")"
LOG="$(jq -r '.log' <<<"$PAYLOAD")"

mkdir -p "$RUN_DIR/logs"
OUT="$RUN_DIR/logs/operator-$PHASE.md"
RUN_DISPLAY="$RUN_SLUG"
[ -n "$RUN_DISPLAY" ] || RUN_DISPLAY="(single-run)"

PROMPT="$(cat "$ROOT/prompts/operator.md")

## This phase

- phase: $PHASE
- issue: #$ISSUE
- runner-reported outcome: $OUTCOME (verify it — do not trust it)
- harness root: $ROOT
- run root: $RUN_DIR
- run slug: $RUN_DISPLAY
- repo root: $REPO_ROOT
- worktree home: $WT_BASE
- integration worktree: $INT_WT
- base branch: $BASE_BRANCH
- engine log: $LOG

## Engine log tail (runner's view, last 30 lines)

$(tail -30 "$LOG" 2>/dev/null || echo "(log unreadable)")"

# The harness shell can inspect the integration worktree without model-tool
# permission mediation, so this is the live evidence route that cannot be
# denied. Keep recorder failure non-fatal: unavailable evidence must become
# explicit operator input rather than aborting the pipeline handler.
if [ "$PHASE" = "review" ] || [ "$PHASE" = "promote" ]; then
    WORKTREE_EVIDENCE="(worktree evidence unavailable)"
    if CAPTURED_WORKTREE_EVIDENCE="$(
        "$(dirname "${BASH_SOURCE[0]}")/worktree-evidence.sh" "$INT_WT"
    )" && [ -n "$CAPTURED_WORKTREE_EVIDENCE" ]; then
        WORKTREE_EVIDENCE="$CAPTURED_WORKTREE_EVIDENCE"
    fi
    CAPTURED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    PROMPT="$PROMPT

## Worktree evidence (harness-captured live at operator time)

- integration worktree: $INT_WT
- captured: $CAPTURED_AT
$WORKTREE_EVIDENCE"
fi

# The worktrees this operator must inspect are siblings of REPO_ROOT, so the
# session's default allowed directory cannot reach them and every check of the
# integration worktree was permission-denied (issue #12). WT_BASE rather than
# INT_WT so shard worktrees stay visible to future checks. Guarded because the
# worktree home does not exist until bin/plan-seed.sh creates it during the
# first implement phase — handing claude a nonexistent --add-dir path would
# break the plan-phase operator instead of unblocking it.
ADD_DIR=()
if [ -d "$WT_BASE" ]; then
    ADD_DIR=(--add-dir "$WT_BASE")
fi

# A path grant only makes the worktree visible; acceptEdits still denies Bash
# commands unless the invocation is allowed. Every rule below is one whole
# command with no trailing wildcard: a `:*` suffix admits arbitrary trailing
# arguments, so `git log`/`git diff`/`git show` would gain `--output=<file>`
# and `symbolic-ref`/`branch` their write modes (ref updates, -d/-D deletion,
# -m renaming). Exact forms keep the operator unable to mutate any state.
#
# The ref-bearing forms prompts/operator.md asks for at implement cannot be
# written as constants, so they are spelled out from this run's own plan and
# from the configured base branch. Both refs are validated first: a rule is an
# exact command string, and git permits branch names carrying `;`, `&`, or
# `$(...)`, which would be parsed as shell syntax inside the rule. Anything
# that is not a plain ref token simply yields no rule bearing that ref rather
# than an unbounded or command-injecting one.
#
# The slug is accepted only when it is a kebab-case token — anything else
# (missing, unreadable, or carrying shell or path characters) simply yields
# no ref-bearing rules rather than an unbounded one.
FEATURE_BRANCH=""
if [ -r "$RUN_DIR/plan.json" ]; then
    FEATURE_SLUG="$(jq -r '.feature // ""' "$RUN_DIR/plan.json" 2>/dev/null || true)"
    case "$FEATURE_SLUG" in
        "" | -* | *- | *[!a-z0-9-]*) ;;
        *) FEATURE_BRANCH="feat/$FEATURE_SLUG" ;;
    esac
fi

# The base branch comes from _env.sh, not from a per-run artifact, but the
# installer imposes no narrower contract than git's own ref rules, so it is
# validated on the same terms as the slug: a plain ref token (letters, digits,
# `.`, `_`, `/`, `-`), never leading `-`, never `..`, never a trailing `/`.
SAFE_BASE=""
case "$BASE_BRANCH" in
    "" | -* | */ | *..* | *[!A-Za-z0-9._/-]*) ;;
    *) SAFE_BASE="$BASE_BRANCH" ;;
esac

# The implement terminal's two mandatory checks — at least one shard commit,
# and a diff confined to plan.json's declared files — are both ref-bearing, and
# a rule is one exact command string. A base branch spelled with `;`, `&`, or
# `$(...)` is legal to git but has no safe spelling inside a rule, so those two
# rules are simply omitted; without a second route such a repository could
# never complete implement verification. The harness shell has no such limit:
# it passes every ref as an argv word that no shell ever parses, so it captures
# the same two facts itself. Both names are resolved inside refs/heads
# explicitly: gitrevisions prefers refs/tags for a bare name, so a tag sharing
# a branch's name would otherwise substitute its history while the evidence
# still reads `resolved: true`. Ranges are built from the resolved object ids,
# not the ref names, so a ref git might read as an option cannot reach a range
# argument. Failure is non-fatal and explicit: unusable evidence must reach the
# operator as a stated error, never abort the pipeline handler.
branch_evidence() {
    local BASE="$1"
    local BRANCH="$2"
    local BASE_TIP=""
    local BRANCH_TIP=""
    local BRANCH_SHORT=""
    local COMMITS=""
    local FILES=""
    local DIFFSTAT=""

    if ! BASE_TIP="$(
        git -C "$REPO_ROOT" rev-parse --verify --quiet \
            "refs/heads/$BASE^{commit}" 2>/dev/null
    )"; then
        jq -nc \
            --arg base "$BASE" \
            --arg branch "$BRANCH" \
            --argjson resolved false \
            --arg error "base branch does not resolve to a commit" \
            '{base: $base, branch: $branch, resolved: $resolved, error: $error}'
        return 0
    fi
    if ! BRANCH_TIP="$(
        git -C "$REPO_ROOT" rev-parse --verify --quiet \
            "refs/heads/$BRANCH^{commit}" 2>/dev/null
    )"; then
        jq -nc \
            --arg base "$BASE" \
            --arg branch "$BRANCH" \
            --argjson resolved false \
            --arg error "feature branch does not resolve to a commit" \
            '{base: $base, branch: $branch, resolved: $resolved, error: $error}'
        return 0
    fi
    if ! COMMITS="$(
        git -C "$REPO_ROOT" log --oneline "$BASE_TIP..$BRANCH_TIP" 2>/dev/null
    )" || ! FILES="$(
        git -C "$REPO_ROOT" diff --name-only "$BASE_TIP...$BRANCH_TIP" 2>/dev/null
    )" || ! DIFFSTAT="$(
        git -C "$REPO_ROOT" diff --stat "$BASE_TIP...$BRANCH_TIP" 2>/dev/null
    )"; then
        jq -nc \
            --arg base "$BASE" \
            --arg branch "$BRANCH" \
            --argjson resolved false \
            --arg error "git could not compare the branches" \
            '{base: $base, branch: $branch, resolved: $resolved, error: $error}'
        return 0
    fi
    # gate.json records the short tip, so the evidence carries that form too.
    BRANCH_SHORT="$(
        git -C "$REPO_ROOT" rev-parse --short "$BRANCH_TIP" 2>/dev/null || true
    )"

    jq -nc \
        --arg base "$BASE" \
        --arg branch "$BRANCH" \
        --argjson resolved true \
        --arg base_tip "$BASE_TIP" \
        --arg branch_tip "$BRANCH_TIP" \
        --arg branch_tip_short "$BRANCH_SHORT" \
        --arg commits "$COMMITS" \
        --arg files "$FILES" \
        --arg diffstat "$DIFFSTAT" \
        '{
            base: $base,
            branch: $branch,
            resolved: $resolved,
            base_tip: $base_tip,
            branch_tip: $branch_tip,
            branch_tip_short: $branch_tip_short,
            commits: ($commits | split("\n") | map(select(length > 0))),
            files: ($files | split("\n") | map(select(length > 0))),
            diffstat: $diffstat
        }'
}

if [ "$PHASE" = "implement" ] && [ -n "$FEATURE_BRANCH" ]; then
    BRANCH_EVIDENCE="$(branch_evidence "$BASE_BRANCH" "$FEATURE_BRANCH")"
    BRANCH_CAPTURED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    PROMPT="$PROMPT

## Branch evidence (harness-captured live at operator time)

- repo root: $REPO_ROOT
- base branch: $BASE_BRANCH
- feature branch: $FEATURE_BRANCH
- captured: $BRANCH_CAPTURED_AT
$BRANCH_EVIDENCE"
fi

GIT_TOOLS=(
    "Bash(git status --porcelain)"
    "Bash(git rev-parse --short HEAD)"
    "Bash(git symbolic-ref --short HEAD)"
    "Bash(git branch --show-current)"
    "Bash(git branch --list)"
    "Bash(git worktree list)"
)
if [ -n "$SAFE_BASE" ]; then
    GIT_TOOLS+=(
        "Bash(git log origin/$SAFE_BASE --oneline -20)"
        "Bash(git show --stat origin/$SAFE_BASE)"
    )
fi
if [ -n "$FEATURE_BRANCH" ]; then
    GIT_TOOLS+=("Bash(git rev-parse --short $FEATURE_BRANCH)")
    if [ -n "$SAFE_BASE" ]; then
        GIT_TOOLS+=(
            "Bash(git log $SAFE_BASE..$FEATURE_BRANCH --oneline)"
            "Bash(git diff --stat $SAFE_BASE...$FEATURE_BRANCH)"
        )
    fi
fi
if [ -d "$INT_WT" ]; then
    GIT_TOOLS+=("Bash(git -C $INT_WT status --porcelain)")
fi

# Test-only binary seam for tests/operator-evidence.test.sh; production keeps
# resolving the normal claude executable.
CLAUDE_BIN="${SIGNALBOX_OPERATOR_CLAUDE:-claude}"

cd "$REPO_ROOT"
# Read-only gh is explicitly allowed so the operator can confirm PR/issue/CI
# state itself instead of reporting "could not verify" — approved commands
# also run outside the sandbox, which is what blocked gh's network calls.
env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT \
    "$CLAUDE_BIN" -p "$PROMPT" \
    --model claude-fable-5 \
    --permission-mode acceptEdits \
    ${ADD_DIR[@]+"${ADD_DIR[@]}"} \
    --allowedTools \
        "Bash(gh pr view:*)" "Bash(gh pr checks:*)" "Bash(gh pr list:*)" \
        "Bash(gh issue view:*)" "Bash(gh issue list:*)" \
        "Bash(gh run view:*)" "Bash(gh run list:*)" \
        ${GIT_TOOLS[@]+"${GIT_TOOLS[@]}"} \
    >"$OUT" 2>"$OUT.stderr" || true
stamp_provenance "logs/operator-$PHASE.md" claude claude-fable-5 ""

VERDICT_LINE="$(grep -E '^\{.*"verdict".*\}[[:space:]]*$' "$OUT" | tail -1 || true)"

VERDICT="HALT"
REASON="operator output unparseable (see $OUT) — failing safe"
PARKED="false"
if [ -n "$VERDICT_LINE" ] && jq -e . >/dev/null 2>&1 <<<"$VERDICT_LINE"; then
    V="$(jq -r '.verdict // ""' <<<"$VERDICT_LINE")"
    if [ "$V" = "PROCEED" ] || [ "$V" = "HALT" ]; then
        VERDICT="$V"
        REASON="$(jq -r '.reason // ""' <<<"$VERDICT_LINE")"
        PARKED="$(jq -r 'if .parked == true then "true" else "false" end' <<<"$VERDICT_LINE")"
    fi
fi

PROVENANCE="$(provenance_object claude claude-fable-5 "")"
jq -c \
    --arg verdict "$VERDICT" \
    --arg reason "$REASON" \
    --argjson parked "$PARKED" \
    --argjson provenance "$PROVENANCE" \
    '. + {
        verdict: $verdict,
        reason: $reason,
        parked: $parked,
        provenance: $provenance
    }' <<<"$PAYLOAD"
