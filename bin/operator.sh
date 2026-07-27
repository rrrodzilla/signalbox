#!/usr/bin/env bash
# Pipeline operator: stdin = phase.done {issue, phase, outcome, log, correlation_id}
# stdout = phase.verified (input + {verdict, reason, parked, provenance})
#
# Headless Fable applies the phantom-run discipline as topology: never trust
# the runner's outcome, verify the phase's disk artifacts first-hand, then
# PROCEED or HALT. Fail-safe: an unparseable verdict is a HALT — when the
# operator can't be understood, the pipeline stops.
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

cd "$REPO_ROOT"
# Read-only gh is explicitly allowed so the operator can confirm PR/issue/CI
# state itself instead of reporting "could not verify" — approved commands
# also run outside the sandbox, which is what blocked gh's network calls.
env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT \
    claude -p "$PROMPT" \
    --model claude-fable-5 \
    --permission-mode acceptEdits \
    ${ADD_DIR[@]+"${ADD_DIR[@]}"} \
    --allowedTools \
        "Bash(gh pr view:*)" "Bash(gh pr checks:*)" "Bash(gh pr list:*)" \
        "Bash(gh issue view:*)" "Bash(gh issue list:*)" \
        "Bash(gh run view:*)" "Bash(gh run list:*)" \
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
