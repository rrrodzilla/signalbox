#!/usr/bin/env bash
# Pipeline seed: validate preconditions and emit the first phase request.
#   SIGNALBOX_ISSUE=<n> emergent --config pipeline.toml
# stdout = phase.request {issue, phase, correlation_id}; run setup resets provenance.
# The pipeline assumes init has already filled the vault (once per repo);
# it chains the per-feature phases: plan -> implement -> review.
set -euo pipefail
# shellcheck source=_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/_env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/_provenance.sh"

ISSUE="${SIGNALBOX_ISSUE:?set SIGNALBOX_ISSUE=<issue-number> when launching the engine}"

DOCS="$REPO_ROOT/.claude/docs"
if [ ! -d "$DOCS" ] || [ ! -f "$DOCS/ARCHI.md" ]; then
    echo "error: vault docs missing at $DOCS — run bin/init-run.sh first" >&2
    exit 1
fi

CID="pipe-$ISSUE-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR/state" "$RUN_DIR/logs" "$RUN_DIR/results"
reset_provenance
echo "[pipeline] issue #$ISSUE, run: $RUN_DIR, correlation_id: $CID" >&2

jq -n --arg issue "$ISSUE" --arg cid "$CID" \
    '{issue: ($issue | tonumber), phase: "plan", correlation_id: $cid}'
