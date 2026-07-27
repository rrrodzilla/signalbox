#!/usr/bin/env bash
# Review-loop seed: emit the initial review.requested payload from _env.sh —
# the feature worktree in target mode, the demo crate in the prototype.
# The feature name feeds the correlation_id stamp in unwrap-seed.
set -euo pipefail
# shellcheck source=_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/_env.sh"

FEATURE="${SEED_FEATURE:-$(jq -r '.feature // "feature"' "$ROOT/plan.json" 2>/dev/null || echo feature)}"

jq -n --arg f "$FEATURE" --arg wd "$SEED_WORKDIR" \
    '{feature: $f, workdir: $wd, round: 1, feedback: ""}'
