#!/usr/bin/env bash
# Plan writer: stdin = plan.approved payload, writes $RUN_DIR/plan.json and
# emits the summary. Dumb by design — all judgment lives upstream in the
# planner, all enforcement in the validator; only approved plans reach here
# (topological gate: this is the sole subscriber that persists anything).
set -euo pipefail
# shellcheck source=_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/_env.sh"

PAYLOAD="$(cat)"

mkdir -p "$RUN_DIR"
jq '.plan' <<<"$PAYLOAD" >"$RUN_DIR/plan.json"

if [ -n "$RUN_SLUG" ]; then
    PLAN_PATH="runs/$RUN_SLUG/plan.json"
else
    PLAN_PATH="plan.json"
fi

jq -c --arg path "$PLAN_PATH" '{
  feature: .plan.feature,
  issue: .plan.issue,
  stages: (.plan.stages | length),
  shards: ([.plan.stages[].shards | length] | add),
  scope_notes: (.plan.scope_notes // ""),
  path: $path,
  round: .round
}' <<<"$PAYLOAD"
