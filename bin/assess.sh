#!/usr/bin/env bash
# Situational assessor: stdin = review.approved payload.
# stdout = gate.assessed payload (input + {action, readiness, floor, rationale}).
#
# The LLM — not a hand-authored policy table — sets the readiness floor for
# the action at hand. It is handed the action's mechanics (facts) and the
# live context (round, change scope, reviewer's summary) and decides what
# floor this instance deserves: blast radius, reversibility, and visibility
# to others push it up; small, local, easily-undone work pulls it down. The
# comparison against earned readiness stays in the topology (a jq handler);
# only the judgment lives here. Fail-safe: an unparseable assessment means
# floor 4 — when the leader can't be understood, a human decides.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PAYLOAD="$(cat)"

ACTION="${TRIP_ACTION:-promote}"

# Mechanics of each known action, stated as fact — the LLM turns facts into
# a floor. Unknown actions get no comfort.
case "$ACTION" in
    promote)
        WHAT="Write the PROMOTION_READY code-review artifact (results/CR.md). Downstream tooling treats it as the signal that the change may be merged and its issue closed. A local file, reversible until something consumes it."
        ;;
    push-remote)
        WHAT="git push the integration branch to the shared remote. Immediately visible to every collaborator; undoing it requires revert commits or a force-push on a shared ref."
        ;;
    delete-branch)
        WHAT="Delete a local, already-merged shard branch. Recoverable from the reflog for weeks; invisible to collaborators."
        ;;
    *)
        WHAT="No mechanics on file for '$ACTION'. Treat unknown actions conservatively."
        ;;
esac

ROUND="$(jq -r '.round // 1' <<<"$PAYLOAD")"
CID="$(jq -r '.correlation_id // ""' <<<"$PAYLOAD")"
REVIEW_HEAD="$(jq -r '.review // ""' <<<"$PAYLOAD" | head -c 700)"
WORKDIR="$(jq -r '.workdir // ""' <<<"$PAYLOAD")"

SCOPE=""
if [ -n "$WORKDIR" ] && [ -d "$WORKDIR" ]; then
    SCOPE="$(git -C "$WORKDIR" diff --stat 2>/dev/null | tail -4 || true)"
fi

LEVEL="$("$ROOT/bin/readiness-get.sh" "$ACTION")"

PROMPT="You are the leader in a Situational Leadership arrangement with an
autonomous development workflow. One transition is requested, and you must set
the minimum readiness level (the floor) at which the workflow may perform it
WITHOUT human pre-approval.

Readiness scale: R1 novice (always needs approval) through R4 proven (acts
alone). A floor of 1 lets anyone act autonomously; a floor of 4 demands a
proven R4 track record. Weigh blast radius, reversibility, visibility to
others, and the specific context below — riskier, harder-to-undo, more
outward-facing actions deserve higher floors; small local reversible ones
deserve lower.

Action: $ACTION
Mechanics: $WHAT
Context: review approved on round $ROUND.
Change scope:
$SCOPE
Reviewer's closing summary:
$REVIEW_HEAD

Reply with STRICT JSON only — no prose, no code fences:
{\"floor\": <integer 1-4>, \"rationale\": \"<one sentence>\"}"

mkdir -p "$ROOT/logs" "$ROOT/state"

RAW="$(env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT \
    claude -p "$PROMPT" --model opus \
    2>>"$ROOT/logs/assess.stderr" || true)"

VERDICT_JSON="$(printf '%s' "$RAW" | tr '\n' ' ' | grep -oE '\{[^{}]*\}' | head -1 || true)"
FLOOR="$(jq -r '.floor | select(type == "number")' <<<"$VERDICT_JSON" 2>/dev/null || true)"
RATIONALE="$(jq -r '.rationale // ""' <<<"$VERDICT_JSON" 2>/dev/null || true)"

case "$FLOOR" in
    1 | 2 | 3 | 4) : ;;
    *)
        FLOOR=4
        RATIONALE="assessment unparseable; defaulting to the most conservative floor"
        ;;
esac

# Append-only assessment ledger — every determination the leader ever made,
# with its reasoning, greppable next to the event store.
jq -nc \
    --arg action "$ACTION" \
    --argjson floor "$FLOOR" \
    --arg rationale "$RATIONALE" \
    --arg cid "$CID" \
    '{ts: (now | todate), action: $action, floor: $floor, rationale: $rationale, correlation_id: $cid}' \
    >>"$ROOT/state/assessments.jsonl"

jq -c \
    --arg action "$ACTION" \
    --argjson readiness "$LEVEL" \
    --argjson floor "$FLOOR" \
    --arg rationale "$RATIONALE" \
    '. + {action: $action, readiness: $readiness, floor: $floor, rationale: $rationale}' <<<"$PAYLOAD"
