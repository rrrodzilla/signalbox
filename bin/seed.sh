#!/usr/bin/env bash
# Review-loop seed: emit the initial review.requested payload from _env.sh —
# the feature worktree in target mode, the demo crate in the prototype.
# This seed is the review loop's ONLY correlation-id generator (issue #42): it
# inherits the pipeline run's id from SIGNALBOX_CORRELATION_ID when the phase
# runner supplied one, otherwise mints review-<feature>-<UTC>. unwrap-seed in
# emergent.toml passes that id through untouched.
set -euo pipefail
# shellcheck source=_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/_env.sh"
# shellcheck source=_correlation.sh
source "$(dirname "${BASH_SOURCE[0]}")/_correlation.sh"

FEATURE="${SEED_FEATURE:-$(jq -r '.feature // "feature"' "$RUN_DIR/plan.json" 2>/dev/null || echo feature)}"
CID="$(resolve_correlation_id review "$FEATURE")"

jq -n --arg f "$FEATURE" --arg wd "$SEED_WORKDIR" --arg cid "$CID" \
    '{feature: $f, workdir: $wd, round: 1, feedback: "", correlation_id: $cid}'
