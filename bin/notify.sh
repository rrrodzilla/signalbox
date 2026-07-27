#!/usr/bin/env bash
# Approval-request sink: stdin = approval.requested payload.
# Leader-directed path: park the pending payload and tell the human how to
# grant approval. The webhook POST body becomes the approval.granted event,
# so approving is replaying the parked payload back into the fabric.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$ROOT/state"

jq '.' >"$ROOT/state/pending.json"

ROUND="$(jq -r '.round' "$ROOT/state/pending.json")"
LEVEL="$(jq -r '.readiness' "$ROOT/state/pending.json")"
ACTION="$(jq -r '.action // "promote"' "$ROOT/state/pending.json")"
FLOOR="$(jq -r '.floor // "?"' "$ROOT/state/pending.json")"
RATIONALE="$(jq -r '.rationale // ""' "$ROOT/state/pending.json")"

echo "APPROVAL REQUIRED — $ACTION assessed at floor R$FLOOR, readiness is R$LEVEL. ${RATIONALE}"
echo "Review approved on round $ROUND."
echo "Inspect: $ROOT/state/pending.json"
echo "Approve: curl -s -X POST http://127.0.0.1:8095/approve -H 'Content-Type: application/json' --data @$ROOT/state/pending.json"
