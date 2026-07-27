#!/usr/bin/env bash
# Completion sink: stdin = plan.done payload. Runs the gate command from
# _env.sh (GATE_CMD, detected at install time) in the integration worktree
# and reports the integrated history.
set -euo pipefail
# shellcheck source=_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/_env.sh"

PAYLOAD="$(cat)"
# plan.done only carries {count}; the run manifest has the correlation id.
CID="$(jq -r '.correlation_id // empty' <<<"$PAYLOAD" 2>/dev/null || true)"
[ -n "$CID" ] || CID="$(jq -r '.correlation_id // empty' "$RUN_DIR/state/run.json" 2>/dev/null || true)"

echo "ALL STAGES MERGED — running gate in $GATE_DIR: ${GATE_CMD:-}"
cd "$GATE_DIR"

if [ -z "${GATE_CMD:-}" ]; then
    VERDICT="RED"
    echo "GATE CONFIGURATION ERROR: no GATE_CMD in bin/_env.sh — reinstall the harness or add one; install.sh --gate '<command>' sets it" >&2
    echo "GATE RED — inspect $INT_WT"
else
    # -o pipefail: a pipeline gate ("tests | tee log") must fail on the
    # producer's failure, not just the last stage's. bash -c starts a fresh
    # shell, so the set -euo above does not carry into it.
    if GATE_OUTPUT="$(bash -o pipefail -c "$GATE_CMD" 2>&1)"; then
        GATE_STATUS=0
    else
        GATE_STATUS=$?
    fi
    [ -z "$GATE_OUTPUT" ] || printf '%s\n' "$GATE_OUTPUT" | tail -n 20 >&2

    if [ "$GATE_STATUS" -eq 0 ]; then
        VERDICT="GREEN"
        echo "GATE GREEN on $INT_BRANCH:"
        git log --oneline "$BASE_BRANCH".."$INT_BRANCH" | sed 's/^/  /'
    else
        VERDICT="RED"
        echo "GATE RED — inspect $INT_WT"
    fi
fi

# The verdict as a DISK ARTIFACT (issue #1): engine stdout is buffered when
# redirected, so narration can sit unflushed until shutdown — anything that
# supervises this phase must watch the run's state/gate.json, never the banner.
mkdir -p "$RUN_DIR/state"
jq -n \
    --arg verdict "$VERDICT" \
    --arg branch "$INT_BRANCH" \
    --arg tip "$(git rev-parse --short HEAD)" \
    --arg cid "$CID" \
    '{verdict: $verdict, branch: $branch, tip: $tip, correlation_id: $cid}' \
    >"$RUN_DIR/state/gate.json"

[ -z "$CID" ] || echo "feature trail: bin/audit.sh $CID"
