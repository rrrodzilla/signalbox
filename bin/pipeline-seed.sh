#!/usr/bin/env bash
# Pipeline seed: validate preconditions and emit the first phase request.
#   SIGNALBOX_ISSUE=<n> emergent --config pipeline.toml
# stdout = phase.request {issue, phase, correlation_id}.
# Before resetting provenance or emitting, archive only the explicit prior-run
# singleton allowlist under logs/<prior-correlation-id>/, preserving relative
# paths. Current-run launch/config/PID files, direct logs, and repo state stay put.
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

ARCHIVE_PATHS=(
    "plan.json"
    "results/CR.md"
    "state/run.json"
    "state/gate.json"
    "state/pending.json"
    "state/escalated.json"
    "state/docs-sync.json"
    "state/worktree.json"
    "state/provenance.json"
    "state/pipeline.json"
    "state/pipeline-plan.stamp"
    "state/pipeline-implement.stamp"
    "state/pipeline-review.stamp"
    "state/stages"
)
PRIOR_PATHS=()
for RELATIVE_PATH in "${ARCHIVE_PATHS[@]}"; do
    SOURCE_PATH="$RUN_DIR/$RELATIVE_PATH"
    if [ -e "$SOURCE_PATH" ] || [ -L "$SOURCE_PATH" ]; then
        PRIOR_PATHS+=("$RELATIVE_PATH")
    fi
done

if [ "${#PRIOR_PATHS[@]}" -gt 0 ]; then
    PRIOR_ID="$(
        jq -r '.correlation_id // empty | strings' \
            "$RUN_DIR/state/pipeline.json" 2>/dev/null || true
    )"
    if [ -z "$PRIOR_ID" ] || [[ ! "$PRIOR_ID" =~ ^[A-Za-z0-9._-]+$ ]]; then
        PRIOR_ID="prev-$(date -u +%Y%m%d-%H%M%S)"
    fi

    ARCHIVE_ID="$PRIOR_ID"
    ARCHIVE_DIR="$RUN_DIR/logs/$ARCHIVE_ID"
    ARCHIVE_ATTEMPT=1
    ARCHIVE_CREATED=0
    while [ "$ARCHIVE_ATTEMPT" -le 1000 ]; do
        if mkdir -- "$ARCHIVE_DIR" 2>/dev/null; then
            ARCHIVE_CREATED=1
            break
        fi
        if [ ! -e "$ARCHIVE_DIR" ] && [ ! -L "$ARCHIVE_DIR" ]; then
            echo "error: could not create archive for prior artifacts at $ARCHIVE_DIR" >&2
            exit 1
        fi
        ARCHIVE_ATTEMPT=$((ARCHIVE_ATTEMPT + 1))
        ARCHIVE_ID="$PRIOR_ID-$ARCHIVE_ATTEMPT"
        ARCHIVE_DIR="$RUN_DIR/logs/$ARCHIVE_ID"
    done
    if [ "$ARCHIVE_CREATED" -ne 1 ]; then
        echo "error: could not find an unused archive name for $PRIOR_ID" >&2
        exit 1
    fi

    for RELATIVE_PATH in "${PRIOR_PATHS[@]}"; do
        SOURCE_PATH="$RUN_DIR/$RELATIVE_PATH"
        DESTINATION_PATH="$ARCHIVE_DIR/$RELATIVE_PATH"
        if ! mkdir -p -- "$(dirname "$DESTINATION_PATH")"; then
            echo "error: failed to archive $RELATIVE_PATH" >&2
            exit 1
        fi
        if ! mv -- "$SOURCE_PATH" "$DESTINATION_PATH"; then
            echo "error: failed to archive $RELATIVE_PATH" >&2
            exit 1
        fi
    done
    echo "[pipeline] archived ${#PRIOR_PATHS[@]} prior artifact(s) to logs/$ARCHIVE_ID" >&2
fi

STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
jq -n \
    --arg cid "$CID" \
    --arg issue "$ISSUE" \
    --arg started "$STARTED" \
    '{correlation_id: $cid, issue: ($issue | tonumber), started: $started}' \
    >"$RUN_DIR/state/pipeline.json"

reset_provenance
echo "[pipeline] issue #$ISSUE, run: $RUN_DIR, correlation_id: $CID" >&2

jq -n --arg issue "$ISSUE" --arg cid "$CID" \
    '{issue: ($issue | tonumber), phase: "plan", correlation_id: $cid}'
