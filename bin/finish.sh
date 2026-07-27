#!/usr/bin/env bash
# Completion sink: stdin = plan.done payload. Runs the testing gate in the
# integration worktree (clippy + nextest, mirroring TRIP-2's gate) and
# reports the integrated history.
set -euo pipefail
# shellcheck source=_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/_env.sh"

PAYLOAD="$(cat)"
# plan.done only carries {count}; the run manifest has the correlation id.
CID="$(jq -r '.correlation_id // empty' <<<"$PAYLOAD" 2>/dev/null || true)"
[ -n "$CID" ] || CID="$(jq -r '.correlation_id // empty' "$ROOT/state/run.json" 2>/dev/null || true)"

echo "ALL STAGES MERGED — running testing gate in $GATE_DIR"
cd "$GATE_DIR"

if cargo clippy --all-targets -q 2>&1 | tail -3 && cargo nextest run 2>&1 | tail -3; then
    echo "GATE GREEN on $INT_BRANCH:"
    git log --oneline "$BASE_BRANCH".."$INT_BRANCH" | sed 's/^/  /'
else
    echo "GATE RED — inspect $INT_WT"
fi
[ -z "$CID" ] || echo "feature trail: bin/audit.sh $CID"
