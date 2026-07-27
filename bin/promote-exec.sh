#!/usr/bin/env bash
# Promotion executor: stdin = phase.request {issue, phase: "promote", correlation_id}
# stdout = phase.done (input + {outcome, log, provenance?})
#
# Headless Fable performs the outward-facing promotion — push, PR, CI watch,
# squash merge, cleanup — under its own judgment (prompts/promote.md). This
# is the delegation boundary the human chose: PR-and-merge after green CI is
# the workflow's job; releases stay human. NO_GO leaves everything in a safe
# state for one human look.
#
# Docs sync now runs in parallel with the CR terminal (see emergent.toml), so
# this executor enforces "no PR without a recorded docs-sync": it blocks on
# fresh, status "OK", correlation-matched evidence and returns NO_GO rather
# than promoting on unchecked vault docs.
set -euo pipefail
# shellcheck source=_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/_env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/_provenance.sh"

PAYLOAD="$(cat)"
[ "$(jq -r '.phase' <<<"$PAYLOAD")" = "promote" ] || exit 0

ISSUE="$(jq -r '.issue' <<<"$PAYLOAD")"
FEATURE="$(jq -r '.feature // "unknown"' "$RUN_DIR/plan.json" 2>/dev/null || echo unknown)"

mkdir -p "$RUN_DIR/logs"
LOG="$RUN_DIR/logs/promote-$ISSUE.md"

if ! WAIT_REASON="$("$(dirname "${BASH_SOURCE[0]}")/docs-sync-wait.sh" "$RUN_DIR" 900)"; then
    printf '%s\n' "$WAIT_REASON" >"$LOG"
    printf '[pipeline] promotion blocked: %s\n' "$WAIT_REASON" >&2
    jq -c \
        --arg outcome "NO_GO" \
        --arg log "$LOG" \
        'del(.provenance) | . + {
            outcome: $outcome,
            log: $log
        }' <<<"$PAYLOAD"
    exit 0
fi
printf '[pipeline] promotion precondition: %s\n' "$WAIT_REASON" >&2

PROMPT="$(cat "$ROOT/prompts/promote.md")

## This promotion

- issue: #$ISSUE
- feature branch: $INT_BRANCH
- base branch: $BASE_BRANCH
- repo root: $REPO_ROOT
- integration worktree: $INT_WT
- harness root: $ROOT
- run root (plan.json, results/CR.md live here): $RUN_DIR

## CR (already gate-approved)

$(cat "$RUN_DIR/results/CR.md" 2>/dev/null || echo "(CR.md MISSING — that is a NO_GO)")

## Plan scope notes

$(jq -r '.scope_notes // "(none)"' "$RUN_DIR/plan.json" 2>/dev/null || echo "(plan.json missing)")"

# The promotion role must reach INT_WT under WT_BASE, a sibling of REPO_ROOT,
# to verify the worktree is clean and remove it during cleanup (issue #12).
ADD_DIR=()
if [ -d "$WT_BASE" ]; then
    ADD_DIR=(--add-dir "$WT_BASE")
fi

cd "$REPO_ROOT"
env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT \
    claude -p "$PROMPT" \
    --model claude-fable-5 \
    --permission-mode bypassPermissions \
    ${ADD_DIR[@]+"${ADD_DIR[@]}"} \
    >"$LOG" 2>"$LOG.stderr" || true
stamp_provenance "logs/promote-$ISSUE.md" claude claude-fable-5 ""

RESULT_LINE="$(grep -E '^\{.*"result".*\}[[:space:]]*$' "$LOG" | tail -1 || true)"

OUTCOME="NO_GO"
if [ -n "$RESULT_LINE" ] && jq -e . >/dev/null 2>&1 <<<"$RESULT_LINE"; then
    R="$(jq -r '.result // ""' <<<"$RESULT_LINE")"
    [ "$R" = "MERGED" ] && OUTCOME="ARTIFACT"
fi

PROVENANCE="$(provenance_object claude claude-fable-5 "")"
jq -c \
    --arg outcome "$OUTCOME" \
    --arg log "$LOG" \
    --argjson provenance "$PROVENANCE" \
    '. + {
        outcome: $outcome,
        log: $log,
        provenance: $provenance
    }' <<<"$PAYLOAD"
