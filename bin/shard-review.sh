#!/usr/bin/env bash
# Per-shard delta reviewer: bin/shard-review.sh <worker-index>
# stdin = shard.review.requested payload
#   {stage, expected, worker, pending, done, branches,
#    current: {shard, branch}, round, thread_id, feedback}
# stdout = shard.review.raw payload (input + {verdict, review, thread_id})
#
# Reviews ONLY this shard's delta — the diff of its branch against the
# integration tip — with the same thread continuity as the code-review loop:
# round 1 starts a fresh Codex thread, rounds 2+ resume it, so the re-review
# remembers its own findings. Worker-tagged so the two reviewer instances
# split the load exactly like the workers do (the non-matching instance
# exits silently and publishes nothing).
set -euo pipefail
# shellcheck source=_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/_env.sh"

ME="${1:?worker index}"
PAYLOAD="$(cat)"
[ "$(jq -r '.worker' <<<"$PAYLOAD")" = "$ME" ] || exit 0

STAGE_ID="$(jq -r '.stage' <<<"$PAYLOAD")"
SHARD_ID="$(jq -r '.current.shard' <<<"$PAYLOAD")"
BRANCH="$(jq -r '.current.branch' <<<"$PAYLOAD")"
ROUND="$(jq -r '.round' <<<"$PAYLOAD")"
THREAD_ID="$(jq -r '.thread_id // ""' <<<"$PAYLOAD")"
# The run's git namespace, derived exactly as in shard-worker.sh and
# stage-merge.sh so this resolves the worktree shard-worker.sh created:
# branch shard/<feature>/<stage>-<shard> lives in <wt-base>/<feature>-<stage>-<shard>.
FEATURE="$(jq -r '.feature // "feature"' "$RUN_DIR/plan.json" 2>/dev/null || echo feature)"
export FEATURE
WT="$WT_BASE/$FEATURE-${BRANCH##*/}"

mkdir -p "$RUN_DIR/logs"
LAST="$RUN_DIR/logs/shard-review-$STAGE_ID-$SHARD_ID-r$ROUND.md"
EVENTS="$RUN_DIR/logs/shard-review-$STAGE_ID-$SHARD_ID-r$ROUND.jsonl"

DIFF="$(git -C "$WT" diff "$INT_BRANCH"...HEAD)"

cd "$WT"

if [ -z "$THREAD_ID" ]; then
    PROMPT="$(cat "$ROOT/prompts/shard-review.md")

## Diff under review ($BRANCH vs $INT_BRANCH)

\`\`\`diff
$DIFF
\`\`\`"

    codex exec \
        --json \
        --skip-git-repo-check \
        --sandbox read-only \
        --color never \
        -c model="${CODEX_MODEL:-gpt-5.6-sol}" \
        -c model_reasoning_effort="${CODEX_EFFORT:-high}" \
        -o "$LAST" \
        "$PROMPT" \
        </dev/null \
        >"$EVENTS" \
        2>"$EVENTS.stderr"

    THREAD_ID="$(jq -r 'select(.type == "thread.started") | .thread_id' "$EVENTS" 2>/dev/null | head -1)"
    [ "$THREAD_ID" != "null" ] || THREAD_ID=""
else
    # Resume: the thread already holds the prior findings, so the prompt only
    # asks to verify. --sandbox / --color are not accepted here (inherited).
    PROMPT="$(cat "$ROOT/prompts/shard-re-review.md")

## Current diff after the fix ($BRANCH vs $INT_BRANCH)

\`\`\`diff
$DIFF
\`\`\`"

    codex exec resume "$THREAD_ID" \
        --json \
        --skip-git-repo-check \
        -c model="${CODEX_MODEL:-gpt-5.6-sol}" \
        -c model_reasoning_effort="${CODEX_EFFORT:-high}" \
        -o "$LAST" \
        "$PROMPT" \
        </dev/null \
        >"$EVENTS" \
        2>"$EVENTS.stderr"
fi

VERDICT="$(grep -oE '^(APPROVED|REQUEST_CHANGES)[[:space:]]*$' "$LAST" | tail -1 | tr -d '[:space:]' || true)"
[ -n "$VERDICT" ] || VERDICT="UNKNOWN"

jq -c \
    --arg verdict "$VERDICT" \
    --rawfile review "$LAST" \
    --arg thread_id "$THREAD_ID" \
    '. + {verdict: $verdict, review: $review, thread_id: $thread_id}' <<<"$PAYLOAD"
