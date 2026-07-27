#!/usr/bin/env bash
# Reviewer handler: stdin = review.requested payload
#   {workdir, round, feedback, thread_id?, fix_session_id?}
# stdout = review.raw payload
#   {verdict, review, round, workdir, thread_id, fix_session_id,
#    correlation_id, provenance}
#
# Round 1 (no thread_id): fresh non-interactive Codex review of $workdir in a
# read-only sandbox; the thread id is captured from the thread.started event.
# Rounds 2+ (thread_id present): `codex exec resume` continues the SAME review
# thread, so the re-review has full context of its own prior findings — the
# thread id travels in the event payload, not in a state file.
#
# fix_session_id belongs to the fixer's own resumed session (bin/fix.sh) and is
# never read here; this handler only carries it across the round trip, exactly
# as fix.sh carries thread_id for this one. Dropping it would silently reset
# the fixer to a memoryless round every cycle (signalbox #39).
set -euo pipefail
# shellcheck source=_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/_env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/_provenance.sh"

PAYLOAD="$(cat)"

WORKDIR="$(jq -r '.workdir' <<<"$PAYLOAD")"
ROUND="$(jq -r '.round' <<<"$PAYLOAD")"
FEEDBACK="$(jq -r '.feedback // ""' <<<"$PAYLOAD")"
THREAD_ID="$(jq -r '.thread_id // ""' <<<"$PAYLOAD")"
FIX_SESSION_ID="$(jq -r '.fix_session_id // ""' <<<"$PAYLOAD")"
CID="$(jq -r '.correlation_id // ""' <<<"$PAYLOAD")"
CODEX_MODEL_RESOLVED="${CODEX_MODEL:-gpt-5.6-sol}"
CODEX_EFFORT_RESOLVED="${CODEX_EFFORT:-high}"

mkdir -p "$RUN_DIR/logs"

LAST="$RUN_DIR/logs/review-round-$ROUND.md"
EVENTS="$RUN_DIR/logs/review-round-$ROUND.jsonl"

cd "$WORKDIR"

if [ -z "$THREAD_ID" ]; then
    # Fresh session. If feedback is present (thread was lost), embed it so the
    # reviewer can still verify prior issues were addressed.
    PROMPT="$(cat "$ROOT/prompts/review.md")"
    # Target mode: the validated plan's intent is authoritative context —
    # without it, deliberate API removals read as compatibility defects.
    if [ -f "$RUN_DIR/plan.json" ]; then
        PROMPT="$PROMPT

## Feature intent (from the validated plan — authoritative)

Issue #$(jq -r '.issue' "$RUN_DIR/plan.json"): feature \`$(jq -r '.feature' "$RUN_DIR/plan.json")\`

$(jq -r '.scope_notes // "(no scope notes)"' "$RUN_DIR/plan.json")"
    fi
    if [ -n "$FEEDBACK" ]; then
        PROMPT="$PROMPT

## Previous round feedback (verify these were addressed)

$FEEDBACK"
    fi

    codex exec \
        --json \
        --skip-git-repo-check \
        --sandbox read-only \
        --color never \
        -c model="$CODEX_MODEL_RESOLVED" \
        -c model_reasoning_effort="$CODEX_EFFORT_RESOLVED" \
        -o "$LAST" \
        "$PROMPT" \
        </dev/null \
        >"$EVENTS" \
        2>"$EVENTS.stderr"

    THREAD_ID="$(jq -r 'select(.type == "thread.started") | .thread_id' "$EVENTS" 2>/dev/null | head -1)"
    [ "$THREAD_ID" != "null" ] || THREAD_ID=""
else
    # Resume: the thread already holds the prior review, so the prompt only
    # asks to verify. --sandbox / --color are not accepted here (inherited).
    PROMPT="$(cat "$ROOT/prompts/re-review.md")"

    codex exec resume "$THREAD_ID" \
        --json \
        --skip-git-repo-check \
        -c model="$CODEX_MODEL_RESOLVED" \
        -c model_reasoning_effort="$CODEX_EFFORT_RESOLVED" \
        -o "$LAST" \
        "$PROMPT" \
        </dev/null \
        >"$EVENTS" \
        2>"$EVENTS.stderr"
fi

stamp_provenance "logs/review-round-$ROUND.md" codex "$CODEX_MODEL_RESOLVED" "$CODEX_EFFORT_RESOLVED"
stamp_provenance "results/CR.md" codex "$CODEX_MODEL_RESOLVED" "$CODEX_EFFORT_RESOLVED"
PROVENANCE="$(provenance_object codex "$CODEX_MODEL_RESOLVED" "$CODEX_EFFORT_RESOLVED")"

VERDICT="$(grep -oE '^(APPROVED|REQUEST_CHANGES)[[:space:]]*$' "$LAST" | tail -1 | tr -d '[:space:]' || true)"
[ -n "$VERDICT" ] || VERDICT="UNKNOWN"

jq -n \
    --arg verdict "$VERDICT" \
    --rawfile review "$LAST" \
    --argjson round "$ROUND" \
    --arg workdir "$WORKDIR" \
    --arg thread_id "$THREAD_ID" \
    --arg fix_session_id "$FIX_SESSION_ID" \
    --arg cid "$CID" \
    --argjson provenance "$PROVENANCE" \
    '{verdict: $verdict, review: $review, round: $round, workdir: $workdir, thread_id: $thread_id, fix_session_id: $fix_session_id, correlation_id: $cid, provenance: $provenance}'
