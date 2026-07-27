#!/usr/bin/env bash
# Fixer handler: stdin = fix.requested payload {verdict, review, round, workdir, thread_id}
# stdout = review.requested payload for the next round {workdir, round+1, feedback, thread_id}
#
# Runs headless Claude in $workdir to address the reviewer's feedback, then
# re-emits a review request carrying that feedback so the re-review can
# verify each point was addressed. The topic cycle IS the review loop.
set -euo pipefail
# shellcheck source=_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/_env.sh"

PAYLOAD="$(cat)"

WORKDIR="$(jq -r '.workdir' <<<"$PAYLOAD")"
ROUND="$(jq -r '.round' <<<"$PAYLOAD")"
REVIEW="$(jq -r '.review' <<<"$PAYLOAD")"
THREAD_ID="$(jq -r '.thread_id // ""' <<<"$PAYLOAD")"
CID="$(jq -r '.correlation_id // ""' <<<"$PAYLOAD")"

mkdir -p "$RUN_DIR/logs"

INTENT=""
if [ -f "$RUN_DIR/plan.json" ]; then
    INTENT="## Feature intent (from the validated plan — authoritative)

Issue #$(jq -r '.issue' "$RUN_DIR/plan.json"): feature \`$(jq -r '.feature' "$RUN_DIR/plan.json")\`

$(jq -r '.scope_notes // "(no scope notes)"' "$RUN_DIR/plan.json")

"
fi

PROMPT="You are the fix half of an automated review loop on the Rust crate in the current directory.

$INTENT## Reviewer feedback (round $ROUND)

$REVIEW

## Rules

- The feature intent above (if present) OUTRANKS the reviewer. If a feedback
  item asks you to undo, restore, deprecate, or version-gate something the
  plan declares deliberate, do NOT implement that item — leave the code as
  the plan intends and state the conflict plainly at the end of your reply.
  Silently reverting the feature to satisfy a reviewer is the worst outcome.

- If .claude/docs/ARCHI-rules.md exists here, your changes must conform to it.
- Address every issue the reviewer raised, with minimal correct changes.
- Library code must not use unwrap or expect; use proper error types.
- Do not refactor beyond what the feedback requires. Do not add features.
- Only edit Rust source files in this repository. Do not run cargo, git, or any other command.
- Keep doc comments accurate to the new behavior."

cd "$WORKDIR"
env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT \
    claude -p "$PROMPT" \
    --model opus \
    --permission-mode acceptEdits \
    >"$RUN_DIR/logs/fix-round-$ROUND.log" 2>&1

# Target mode ($WORKDIR = the integration worktree): fix edits must become
# commits on the feature branch — uncommitted worktree state is invisible to
# the merge and silently dies with the worktree.
if [ "$(git rev-parse --show-toplevel 2>/dev/null || true)" = "$INT_WT" ] \
    && [ -n "$(git status --porcelain)" ]; then
    git add -A
    git commit -S -m "fix: address review round $ROUND feedback" >&2
fi

NEXT=$((ROUND + 1))
jq -n \
    --arg workdir "$WORKDIR" \
    --argjson round "$NEXT" \
    --arg feedback "$REVIEW" \
    --arg thread_id "$THREAD_ID" \
    --arg cid "$CID" \
    '{workdir: $workdir, round: $round, feedback: $feedback, thread_id: $thread_id, correlation_id: $cid}'
