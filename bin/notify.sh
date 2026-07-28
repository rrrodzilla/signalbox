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
echo "Approve, once the hold below is confirmed: curl -s -X POST http://127.0.0.1:$APPROVAL_PORT/approve -H 'Content-Type: application/json' --data @$RUN_DIR/state/pending.json"
echo "At this review park, the runner attempts to hold the review engine open so this webhook keeps listening on 127.0.0.1:$APPROVAL_PORT until that POST arrives or the park deadline elapses."
echo "That hold is still pending as this message prints: the handoff to the held engine can fail, and if it does the window closes and the command above is dead."
echo "So verify before trusting it — once the terminal is reached, $RUN_DIR/state/park.json is the authority: held true records the holding engine's pid and start identity, the live approve URL and command, and the deadline, while held false records why the window is closed and means a fresh webhook needs bin/run.sh <issue> --phase review."
echo "When the hold succeeds the pipeline reports PARKED and completes with one idle engine still running; that engine is the waiting gate, not a leak."
echo "A park survives its launcher's exit but not destruction of the launcher's terminal session; to outlive the terminal, launch the runner under nohup or setsid."
