#!/usr/bin/env bash
# Promotion executor: stdin = phase.request {issue, phase: "promote", correlation_id}
# stdout = phase.done (input + {outcome, log})
#
# Headless Fable performs the outward-facing promotion — push, PR, CI watch,
# squash merge, cleanup — under its own judgment (prompts/promote.md). This
# is the delegation boundary the human chose: PR-and-merge after green CI is
# the workflow's job; releases stay human. NO_GO leaves everything in a safe
# state for one human look.
set -euo pipefail
# shellcheck source=_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/_env.sh"

PAYLOAD="$(cat)"
[ "$(jq -r '.phase' <<<"$PAYLOAD")" = "promote" ] || exit 0

ISSUE="$(jq -r '.issue' <<<"$PAYLOAD")"
FEATURE="$(jq -r '.feature // "unknown"' "$ROOT/plan.json" 2>/dev/null || echo unknown)"

mkdir -p "$ROOT/logs"
LOG="$ROOT/logs/promote-$ISSUE.md"

PROMPT="$(cat "$ROOT/prompts/promote.md")

## This promotion

- issue: #$ISSUE
- feature branch: $INT_BRANCH
- base branch: $BASE_BRANCH
- repo root: $REPO_ROOT
- integration worktree: $INT_WT
- harness root (plan.json, results/CR.md live here): $ROOT

## CR (already gate-approved)

$(cat "$ROOT/results/CR.md" 2>/dev/null || echo "(CR.md MISSING — that is a NO_GO)")

## Plan scope notes

$(jq -r '.scope_notes // "(none)"' "$ROOT/plan.json" 2>/dev/null || echo "(plan.json missing)")"

cd "$REPO_ROOT"
env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT \
    claude -p "$PROMPT" \
    --model claude-fable-5 \
    --permission-mode bypassPermissions \
    >"$LOG" 2>"$LOG.stderr" || true

RESULT_LINE="$(grep -E '^\{.*"result".*\}[[:space:]]*$' "$LOG" | tail -1 || true)"

OUTCOME="NO_GO"
if [ -n "$RESULT_LINE" ] && jq -e . >/dev/null 2>&1 <<<"$RESULT_LINE"; then
    R="$(jq -r '.result // ""' <<<"$RESULT_LINE")"
    [ "$R" = "MERGED" ] && OUTCOME="ARTIFACT"
fi

jq -c --arg outcome "$OUTCOME" --arg log "$LOG" \
    '. + {outcome: $outcome, log: $log}' <<<"$PAYLOAD"
