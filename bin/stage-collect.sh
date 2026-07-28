#!/usr/bin/env bash
# Fan-in barrier: stdin = shard.done payload {stage, expected, done, branches}.
# Accumulates arrivals per stage under flock; emits stage.done only when every
# shard has reported. Anything less exits silently (exec-handler publishes
# nothing on empty stdout) — the barrier is the counter, not the topology.
set -euo pipefail
# shellcheck source=_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/_env.sh"

PAYLOAD="$(cat)"
STAGE_ID="$(jq -r '.stage' <<<"$PAYLOAD")"
EXPECTED="$(jq -r '.expected' <<<"$PAYLOAD")"

mkdir -p "$RUN_DIR/state/stages"
STATE="$RUN_DIR/state/stages/$STAGE_ID.json"
LOCK="$RUN_DIR/state/stages/$STAGE_ID.lock"

exec 9>"$LOCK"
flock -x 9

if [ -f "$STATE" ]; then
    MERGED="$(jq -c --argjson new "$PAYLOAD" \
        '{done: (.done + $new.done), branches: (.branches + $new.branches)}' "$STATE")"
else
    MERGED="$(jq -c '{done: .done, branches: .branches}' <<<"$PAYLOAD")"
fi
printf '%s\n' "$MERGED" >"$STATE"

ARRIVED="$(jq -r '.done | length' <<<"$MERGED")"
if [ "$ARRIVED" -ge "$EXPECTED" ]; then
    jq -c --arg stage "$STAGE_ID" '. + {stage: $stage}' <<<"$MERGED"
fi
