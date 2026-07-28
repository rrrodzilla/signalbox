#!/usr/bin/env bash
# Plan seed: fetch the target issue and its blockers, emit the plan request.
# The issue number comes from SIGNALBOX_ISSUE at engine launch:
#   SIGNALBOX_ISSUE=56 emergent --config plan.toml
# Deterministic context assembly happens HERE (gh calls, blocker states) so
# the planner downstream needs no network and no gh — event-carried context.
set -euo pipefail
# shellcheck source=_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/_env.sh"
# shellcheck source=_correlation.sh
source "$(dirname "${BASH_SOURCE[0]}")/_correlation.sh"

ISSUE="${SIGNALBOX_ISSUE:?set SIGNALBOX_ISSUE=<issue-number> when launching the engine}"

cd "$REPO_ROOT"
CONTEXT="$(gh issue view "$ISSUE" --json number,title,body,labels,state)"

STATE="$(jq -r '.state' <<<"$CONTEXT")"
if [ "$STATE" != "OPEN" ]; then
    echo "error: issue #$ISSUE is $STATE — nothing to plan" >&2
    exit 1
fi

# Blockers: "Blocked by: #N" / "**Blocked by:** #N" style references in the body.
BLOCKERS="[]"
for n in $(jq -r '.body' <<<"$CONTEXT" | grep -oiE 'blocked by[^#]*#[0-9]+' | grep -oE '[0-9]+' | sort -u); do
    B="$(gh issue view "$n" --json number,title,state)"
    BLOCKERS="$(jq -c --argjson b "$B" '. + [$b]' <<<"$BLOCKERS")"
done

# Use the pipeline's id when the phase runner supplied one; a direct launch
# mints its own plan-prefixed UTC id.
CID="$(resolve_correlation_id plan "$ISSUE")"
echo "[plan-request] issue #$ISSUE, $(jq 'length' <<<"$BLOCKERS") blocker(s), correlation_id: $CID" >&2

jq -n \
    --argjson issue "$CONTEXT" \
    --argjson blockers "$BLOCKERS" \
    --arg cid "$CID" \
    '{issue: $issue.number, title: $issue.title, body: $issue.body,
      labels: [$issue.labels[].name], blockers: $blockers,
      round: 1, feedback: "", correlation_id: $cid}'
