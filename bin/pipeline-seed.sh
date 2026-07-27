#!/usr/bin/env bash
# Pipeline seed: validate preconditions and emit the first phase request.
#   SIGNALBOX_ISSUE=<n> emergent --config pipeline.toml
# The pipeline assumes init has already filled the vault (once per repo);
# it chains the per-feature phases: plan -> implement -> review.
set -euo pipefail
# shellcheck source=_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/_env.sh"

ISSUE="${SIGNALBOX_ISSUE:?set SIGNALBOX_ISSUE=<issue-number> when launching the engine}"

DOCS="$REPO_ROOT/.claude/docs"
if [ ! -d "$DOCS" ] || [ ! -f "$DOCS/ARCHI.md" ]; then
    echo "error: vault docs missing at $DOCS — run init.toml first" >&2
    exit 1
fi

CID="pipe-$ISSUE-$(date +%Y%m%d-%H%M%S)"
echo "[pipeline] issue #$ISSUE, correlation_id: $CID" >&2

jq -n --arg issue "$ISSUE" --arg cid "$CID" \
    '{issue: ($issue | tonumber), phase: "plan", correlation_id: $cid}'
