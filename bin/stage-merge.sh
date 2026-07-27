#!/usr/bin/env bash
# Fan-in merge: stdin = stage.done payload {stage, done, branches}.
# Rebases each shard branch onto the integration tip, fast-forwards the
# integration branch, and removes the shard worktree — a single clean linear
# history, never a merge commit (shards touch disjoint files by plan design,
# so the rebases are conflict-free). Emits the ack that releases the
# stream-runner's next stage.
set -euo pipefail
# shellcheck source=_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/_env.sh"

PAYLOAD="$(cat)"
STAGE_ID="$(jq -r '.stage' <<<"$PAYLOAD")"

for BRANCH in $(jq -r '.branches[]' <<<"$PAYLOAD"); do
    WT="$WT_BASE/${BRANCH#shard/}"
    {
        git -C "$WT" rebase "$INT_BRANCH"
        git -C "$INT_WT" merge --ff-only "$BRANCH"
        git -C "$ROOT" worktree remove "$WT"
        # -d from the integration worktree: merged-ness is judged against the
        # branch we merged into, not whatever the primary checkout has as HEAD.
        git -C "$INT_WT" branch -d "$BRANCH"
    } >&2
done

jq -c --arg stage "$STAGE_ID" \
    '{stage: $stage, merged: .branches, tip: "", correlation_id: .correlation_id}' <<<"$PAYLOAD" |
    jq -c --arg tip "$(git -C "$INT_WT" rev-parse --short HEAD)" '.tip = $tip'
