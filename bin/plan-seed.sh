#!/usr/bin/env bash
# Seed source for the implement stream: reset any prior run's worktrees and
# branches, create the integration branch + worktree from main, clear the
# fan-in state, then emit the plan JSON (becomes plan.load downstream).
set -euo pipefail
# shellcheck source=_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/_env.sh"

{
    # Idempotent cleanup of THIS plan's artifacts only. The worktree home is
    # shared with human TRIP worktrees in target mode — never glob it; every
    # path and branch we remove is derived from the plan itself.
    for wt in "$INT_WT" $(jq -r --arg base "$WT_BASE" \
        '.stages[] | .id as $s | .shards[] | "\($base)/\($s)-\(.id)"' "$ROOT/plan.json"); do
        [ -d "$wt" ] && git -C "$ROOT" worktree remove --force "$wt" 2>/dev/null || true
    done
    git -C "$ROOT" worktree prune
    for br in "$INT_BRANCH" $(jq -r \
        '.stages[] | .id as $s | .shards[] | "shard/\($s)-\(.id)"' "$ROOT/plan.json"); do
        git -C "$ROOT" branch -D "$br" 2>/dev/null || true
    done
    rm -rf "$ROOT/state/stages"
    mkdir -p "$ROOT/state/stages" "$WT_BASE"

    git -C "$ROOT" worktree add -b "$INT_BRANCH" "$INT_WT" "$BASE_BRANCH"

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
CID="$(jq -r '.feature // "feature"' "$ROOT/plan.json")-$(date +%Y%m%d-%H%M%S)"
echo "[plan-seed] correlation_id: $CID" >&2
# Run manifest: plan.done (stream-runner's end event) carries only {count},
# so the finisher reads the run's id from here to cite the audit trail.
jq -n --arg cid "$CID" '{correlation_id: $cid}' >"$ROOT/state/run.json"
jq -c --arg cid "$CID" \
    '.correlation_id = $cid | .stages = [.stages[] | . + {correlation_id: $cid}]' \
    "$ROOT/plan.json"
