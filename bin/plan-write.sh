#!/usr/bin/env bash
# Plan writer: stdin = plan.approved payload, writes $ROOT/plan.json and
# emits the summary. Dumb by design — all judgment lives upstream in the
# planner, all enforcement in the validator; only approved plans reach here
# (topological gate: this is the sole subscriber that persists anything).
set -euo pipefail
# shellcheck source=_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/_env.sh"

PAYLOAD="$(cat)"

jq '.plan' <<<"$PAYLOAD" >"$ROOT/plan.json"

jq -c '{
  feature: .plan.feature,
  issue: .plan.issue,
  stages: (.plan.stages | length),
  shards: ([.plan.stages[].shards | length] | add),
  scope_notes: (.plan.scope_notes // ""),
  path: "plan.json",
  round: .round,
  correlation_id
}' <<<"$PAYLOAD"
