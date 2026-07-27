#!/usr/bin/env bash
# Escalation sink: bin/escalate-mark.sh <phase-label>
# stdin = the escalation payload from any topology.
#
# Persists the escalation as a DISK ARTIFACT (state/escalated.json) and then
# narrates. Issue #1: engine stdout is buffered when redirected to a file,
# so narration alone is invisible to supervisors until the engine exits —
# the file is the signal, the printed line is a courtesy for humans on a TTY.
set -euo pipefail
# shellcheck source=_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/_env.sh"

LABEL="${1:-escalation}"
PAYLOAD="$(cat)"

mkdir -p "$RUN_DIR/state"
jq -c --arg phase "$LABEL" '. + {escalated_phase: $phase}' <<<"$PAYLOAD" \
    >"$RUN_DIR/state/escalated.json"

if [ -n "$RUN_SLUG" ]; then
    ESCALATED_PATH="runs/$RUN_SLUG/state/escalated.json"
else
    ESCALATED_PATH="state/escalated.json"
fi

jq -r --arg phase "$LABEL" --arg path "$ESCALATED_PATH" \
    '"[\($phase)] ESCALATED (round \(.round // "?")) — human required; details: \($path)"' \
    <<<"$PAYLOAD"
