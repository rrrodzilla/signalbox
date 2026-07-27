#!/usr/bin/env bash
# Seed source for the implement stream: reset any prior run's worktrees and
# branches, create the integration branch + worktree from main, clear the
# fan-in state, then emit the plan JSON (becomes plan.load downstream).
set -euo pipefail
# shellcheck source=_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/_env.sh"

mkdir -p "$ROOT/state"
# Keep this lock scoped to each worktree command: concurrent runs share one
# repository's worktree admin state.
WORKTREE_LOCK="$ROOT/state/worktree.lock"

{
    # Idempotent cleanup of THIS plan's artifacts only. The worktree home is
    # shared with human TRIP worktrees in target mode — never glob it; every
    # path and branch we remove is derived from the plan itself.
    for wt in "$INT_WT" $(jq -r --arg base "$WT_BASE" --arg feature "$FEATURE" \
        '.stages[] | .id as $s | .shards[] | "\($base)/\($feature)-\($s)-\(.id)"' "$RUN_DIR/plan.json"); do
        if [ -d "$wt" ]; then
            ( flock -x 9; git -C "$ROOT" worktree remove --force "$wt" 2>/dev/null ) 9>"$WORKTREE_LOCK" || true
        fi
    done
    ( flock -x 9; git -C "$ROOT" worktree prune ) 9>"$WORKTREE_LOCK"
    for br in "$INT_BRANCH" $(jq -r --arg feature "$FEATURE" \
        '.stages[] | .id as $s | .shards[] | "shard/\($feature)/\($s)-\(.id)"' "$RUN_DIR/plan.json"); do
        git -C "$ROOT" branch -D "$br" 2>/dev/null || true
    done
    rm -rf "$RUN_DIR/state/stages"
    mkdir -p "$RUN_DIR/state/stages" "$WT_BASE"

    ( flock -x 9; git -C "$ROOT" worktree add -b "$INT_BRANCH" "$INT_WT" "$BASE_BRANCH" ) 9>"$WORKTREE_LOCK"

    # TRIP convention: symlink .claude from the primary checkout so the vault
    # docs (ARCHI.md etc.) resolve inside the worktree — shared notes for
    # every agent that works here. The exclude entry keeps it out of git.
    if [ -e "$REPO_ROOT/.claude" ] && [ ! -e "$INT_WT/.claude" ]; then
        ln -s "$REPO_ROOT/.claude" "$INT_WT/.claude"
    fi
} >&2

# Stamp the run's correlation_id: <feature>-<timestamp>, on the plan AND on
# every stage item (stream-runner emits stage items verbatim, so the id must
# already be inside each one). Everything downstream carries it in-payload —
# the audit trail is reconstructable from the event store by this one key.
CID="$(jq -r '.feature // "feature"' "$RUN_DIR/plan.json")-$(date +%Y%m%d-%H%M%S)"
echo "[plan-seed] correlation_id: $CID" >&2
# Run manifest: plan.done (stream-runner's end event) carries only {count},
# so the finisher reads the run's id from here to cite the audit trail.
jq -n --arg cid "$CID" '{correlation_id: $cid}' >"$RUN_DIR/state/run.json"
jq -c --arg cid "$CID" \
    '.correlation_id = $cid | .stages = [.stages[] | . + {correlation_id: $cid}]' \
    "$RUN_DIR/plan.json"
