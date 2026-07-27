#!/usr/bin/env bash
# Approval-request sink: stdin = approval.requested payload.
# Leader-directed path: park the pending payload and tell the human how to
# grant approval. The webhook POST body becomes the approval.granted event,
# so approving is replaying the parked payload back into the fabric.
set -euo pipefail
# shellcheck source=_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/_env.sh"

mkdir -p "$RUN_DIR/state"

jq '.' >"$RUN_DIR/state/pending.json"

ROUND="$(jq -r '.round' "$RUN_DIR/state/pending.json")"
LEVEL="$(jq -r '.readiness' "$RUN_DIR/state/pending.json")"
ACTION="$(jq -r '.action // "promote"' "$RUN_DIR/state/pending.json")"
FLOOR="$(jq -r '.floor // "?"' "$RUN_DIR/state/pending.json")"
RATIONALE="$(jq -r '.rationale // ""' "$RUN_DIR/state/pending.json")"

echo "APPROVAL REQUIRED — $ACTION assessed at floor R$FLOOR, readiness is R$LEVEL. ${RATIONALE}"
echo "Review approved on round $ROUND."
echo "Inspect: $RUN_DIR/state/pending.json"
echo "Approve: curl -s -X POST http://127.0.0.1:$APPROVAL_PORT/approve -H 'Content-Type: application/json' --data @$RUN_DIR/state/pending.json"
