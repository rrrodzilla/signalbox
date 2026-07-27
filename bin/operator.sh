#!/usr/bin/env bash
# Pipeline operator: stdin = phase.done {issue, phase, outcome, log, correlation_id}
# stdout = phase.verified (input + {verdict, reason, parked, provenance})
#
# Headless Fable applies the phantom-run discipline as topology: never trust
# the runner's outcome, verify the phase's disk artifacts first-hand, then
# PROCEED or HALT. Review and promote prompts include harness-captured live
# integration-worktree evidence. Fail-safe: an unparseable verdict is a HALT
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
# written as constants, so they are spelled out from this run's own plan.
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

GIT_TOOLS=(
    "Bash(git status --porcelain)"
    "Bash(git rev-parse --short HEAD)"
    "Bash(git symbolic-ref --short HEAD)"
    "Bash(git branch --show-current)"
    "Bash(git branch --list)"
    "Bash(git worktree list)"
    "Bash(git log origin/$BASE_BRANCH --oneline -20)"
    "Bash(git show --stat origin/$BASE_BRANCH)"
)
if [ -n "$FEATURE_BRANCH" ]; then
    GIT_TOOLS+=(
        "Bash(git rev-parse --short $FEATURE_BRANCH)"
        "Bash(git log $BASE_BRANCH..$FEATURE_BRANCH --oneline)"
        "Bash(git diff --stat $BASE_BRANCH...$FEATURE_BRANCH)"
    )
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
