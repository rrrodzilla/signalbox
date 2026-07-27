#!/usr/bin/env bash
# Promotion sink: stdin = review.approved payload.
# Writes the approved review to results/CR.md under the PROMOTION_READY
# sentinel — the same artifact TRIP-3's promote-review.sh consumes.
set -euo pipefail
# shellcheck source=_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/_env.sh"

PAYLOAD="$(cat)"

ROUND="$(jq -r '.round' <<<"$PAYLOAD")"
DECISION="$(jq -r '.decision // "unconditional"' <<<"$PAYLOAD")"
LEVEL="$(jq -r '.readiness // empty' <<<"$PAYLOAD")"
CID="$(jq -r '.correlation_id // empty' <<<"$PAYLOAD")"
FLOOR="$(jq -r '.floor // empty' <<<"$PAYLOAD")"
RATIONALE="$(jq -r '.rationale // empty' <<<"$PAYLOAD")"
mkdir -p "$RUN_DIR/results"

if [ -n "$RUN_SLUG" ]; then
    RESULT_PATH="runs/$RUN_SLUG/results/CR.md"
else
    RESULT_PATH="results/CR.md"
fi

{
    echo "PROMOTION_READY"
    [ -z "$CID" ] || echo "correlation_id: $CID"
    [ -z "$FLOOR" ] || echo "gate: $DECISION at R$LEVEL vs floor R$FLOOR — $RATIONALE"
    echo
    jq -r '.review' <<<"$PAYLOAD"
} >"$RUN_DIR/results/CR.md"

echo "PROMOTION_READY — approved on round $ROUND (${DECISION} approval${LEVEL:+ at R$LEVEL}${FLOOR:+, floor R$FLOOR}) -> $RESULT_PATH${CID:+ | trail: bin/audit.sh $CID}"
