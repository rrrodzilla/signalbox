#!/usr/bin/env bash
# TRIP-1 planner: stdin = plan.requested payload {issue, title, body, labels,
# blockers, round, feedback, correlation_id}
# stdout = plan.candidate payload (input + {plan: <object|null>, parse_error?})
#
# Headless Claude (opus) explores the repo — vault docs first, then the actual
# source the issue touches — and emits the stage/shard DAG. Parsing failures
# don't kill the loop: plan=null flows to the validator, whose INVALID verdict
# bounces back here with feedback (round-capped in the topology).
set -euo pipefail
# shellcheck source=_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/_env.sh"

PAYLOAD="$(cat)"
ROUND="$(jq -r '.round' <<<"$PAYLOAD")"
FEEDBACK="$(jq -r '.feedback // ""' <<<"$PAYLOAD")"

mkdir -p "$RUN_DIR/logs"
LOG="$RUN_DIR/logs/plan-round-$ROUND.md"

PROMPT="$(cat "$ROOT/prompts/plan.md")

## Issue #$(jq -r '.issue' <<<"$PAYLOAD"): $(jq -r '.title' <<<"$PAYLOAD")

Labels: $(jq -r '.labels | join(", ")' <<<"$PAYLOAD")

$(jq -r '.body' <<<"$PAYLOAD")

## Blocking issues referenced above (current state)

$(jq -r 'if (.blockers | length) == 0 then "None." else [.blockers[] | "- #\(.number) [\(.state)] \(.title)"] | join("\n") end' <<<"$PAYLOAD")"

if [ "$ROUND" -gt 1 ] && [ -n "$FEEDBACK" ]; then
    PROMPT="$PROMPT

## Your previous plan was rejected (round $ROUND)

$FEEDBACK

Fix exactly what the rejection describes and output the corrected JSON object."
fi

cd "$REPO_ROOT"
env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT \
    claude -p "$PROMPT" \
    --model opus \
    >"$LOG" 2>"$LOG.stderr" || true

# Extract the JSON object: whole output, or from the first '{' line onward.
PLAN="null"
PARSE_ERROR=""
if jq -e . "$LOG" >/dev/null 2>&1; then
    PLAN="$(jq -c . "$LOG")"
elif sed -n '/^{/,$p' "$LOG" | jq -e . >/dev/null 2>&1; then
    PLAN="$(sed -n '/^{/,$p' "$LOG" | jq -c .)"
else
    PARSE_ERROR="planner output was not a single JSON object (see logs/plan-round-$ROUND.md)"
fi

jq -c \
    --argjson plan "$PLAN" \
    --arg err "$PARSE_ERROR" \
    '. + {plan: $plan} + (if $err == "" then {} else {parse_error: $err} end)' \
    <<<"$PAYLOAD"
