#!/usr/bin/env bash
# Shard worker: bin/shard-worker.sh <worker-index> <worker-count>
# stdin = stage.item payload {id, title, shards: [...]}
# stdout = shard.built payload {stage, expected, worker, pending: [...], done: [], branches: []}
# Built shards enter as a PENDING queue — nothing reaches the collector until
# the per-shard delta review has approved each one.
#
# Fan-out is by subscription: every worker receives the SAME stage event and
# takes the shards whose index % worker-count == its own index. An empty
# slice exits silently (no event). Each shard gets its own worktree branched
# from the integration tip, a Codex implementation pass (workspace-write),
# and a signed conventional commit — concurrency is free because the workers
# are separate processes and the worktrees are disjoint checkouts.
set -euo pipefail
# shellcheck source=_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/_env.sh"

ME="${1:?worker index}"
COUNT="${2:?worker count}"
PAYLOAD="$(cat)"

STAGE_ID="$(jq -r '.id' <<<"$PAYLOAD")"
EXPECTED="$(jq -r '.shards | length' <<<"$PAYLOAD")"
CID="$(jq -r '.correlation_id // ""' <<<"$PAYLOAD")"
MINE="$(jq -c --argjson me "$ME" --argjson n "$COUNT" \
    '[.shards | to_entries[] | select(.key % $n == $me) | .value]' <<<"$PAYLOAD")"

[ "$(jq 'length' <<<"$MINE")" -gt 0 ] || exit 0

mkdir -p "$ROOT/logs"
PENDING="[]"

for i in $(seq 0 $(($(jq 'length' <<<"$MINE") - 1))); do
    SHARD_ID="$(jq -r ".[$i].id" <<<"$MINE")"
    PROMPT="$(jq -r ".[$i].prompt" <<<"$MINE")"
    BRANCH="shard/$STAGE_ID-$SHARD_ID"
    WT="$WT_BASE/$STAGE_ID-$SHARD_ID"

    git -C "$ROOT" worktree add -b "$BRANCH" "$WT" "$INT_BRANCH" >&2
    if [ -e "$REPO_ROOT/.claude" ] && [ ! -e "$WT/.claude" ]; then
        ln -s "$REPO_ROOT/.claude" "$WT/.claude"
    fi

    # Shared notes: the vault docs are the repo's architecture memory —
    # every implementer reads them before writing a line.
    if [ -e "$WT/.claude/docs/ARCHI.md" ]; then
        PROMPT="Before writing any code, read .claude/docs/ARCHI.md and, if present, .claude/docs/ARCHI-rules.md and .claude/docs/TESTING.md — your changes must conform to them.

$PROMPT"
    fi

    (
        cd "$WT"
        codex exec \
            --json \
            --skip-git-repo-check \
            --sandbox workspace-write \
            --color never \
            -c model="${CODEX_MODEL:-gpt-5.6-sol}" \
            -c model_reasoning_effort="${CODEX_EFFORT:-high}" \
            -o "$ROOT/logs/shard-$STAGE_ID-$SHARD_ID.md" \
            "$PROMPT" \
            </dev/null \
            >"$ROOT/logs/shard-$STAGE_ID-$SHARD_ID.jsonl" \
            2>"$ROOT/logs/shard-$STAGE_ID-$SHARD_ID.jsonl.stderr"

        git add -A
        git commit -S -m "feat: $STAGE_ID/$SHARD_ID shard" >&2
    )

    PENDING="$(jq -c --arg s "$SHARD_ID" --arg b "$BRANCH" \
        '. + [{shard: $s, branch: $b}]' <<<"$PENDING")"
done

jq -n \
    --arg stage "$STAGE_ID" \
    --argjson expected "$EXPECTED" \
    --argjson worker "$ME" \
    --argjson pending "$PENDING" \
    --arg cid "$CID" \
    '{stage: $stage, expected: $expected, worker: $worker, pending: $pending, done: [], branches: [], correlation_id: $cid}'
