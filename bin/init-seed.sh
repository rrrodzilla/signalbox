#!/usr/bin/env bash
# Init seed: validate the TRIP vault wiring and emit the research request.
# The vault (.claude/docs -> Obsidian) is TRIP-init's contract; this topology
# fills it, it does not create it — run TRIP-init's setup script first if the
# symlink is missing.
set -euo pipefail
# shellcheck source=_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/_env.sh"
# shellcheck source=_correlation.sh
source "$(dirname "${BASH_SOURCE[0]}")/_correlation.sh"

DOCS="$REPO_ROOT/.claude/docs"
if [ ! -d "$DOCS" ]; then
    echo "error: $DOCS missing — run TRIP-init's vault setup first" >&2
    exit 1
fi

CID="$(correlation_id)" || {
    echo "error: no correlation on the envelope; init-seed's source needs --correlate" >&2
    exit 78
}
echo "[init-seed] correlation_id: $CID" >&2

jq -n \
    --arg repo "$(basename "$REPO_ROOT")" \
    --arg vault "$(readlink -f "$DOCS")" \
    '{repo: $repo, vault: $vault}'
