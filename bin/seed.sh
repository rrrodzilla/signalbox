#!/usr/bin/env bash
# Review-loop seed: emit the initial review.requested payload from _env.sh —
# the feature worktree in target mode, the demo crate in the prototype.
# The run's correlation rides the envelope: exec-source --correlate adopts the
# pipeline's id when the phase runner exported one, and mints a fresh one for a
# standalone review loop (issue #42). Nothing downstream re-mints — every
# exec-handler copies the id forward on its own.
set -euo pipefail
# shellcheck source=_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/_env.sh"
# shellcheck source=_correlation.sh
source "$(dirname "${BASH_SOURCE[0]}")/_correlation.sh"

FEATURE="${SEED_FEATURE:-$(jq -r '.feature // "feature"' "$RUN_DIR/plan.json" 2>/dev/null || echo feature)}"
CID="$(correlation_id)" || {
    echo "error: no correlation on the envelope; seed's source needs --correlate" >&2
    exit 78
}
echo "[seed] correlation_id: $CID" >&2

jq -n --arg f "$FEATURE" --arg wd "$SEED_WORKDIR" \
    '{feature: $f, workdir: $wd, round: 1, feedback: ""}'
