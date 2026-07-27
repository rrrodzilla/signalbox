#!/usr/bin/env bash
# Feature audit trail:
#   bin/audit.sh [--run <slug>] [correlation_id ...]
# With no correlation ids, lists the ids present across all matching engines
# (or only the selected run's engines when --run is supplied).
#
# Reconstructs everything that happened to a feature across Emergent's
# per-engine JSON event logs. The correlation_id travels in every payload
# (event-carried state, like thread_id), so the trail is one jq filter over
# the store: no instrumentation, no extra bookkeeping, the fabric remembered.
set -euo pipefail

# shellcheck source=_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/_env.sh"
STORE="${EMERGENT_DATA:-$HOME/.local/share/emergent}"
TOPOLOGIES=("pipeline" "plan" "implement-stream" "review-loop" "init")
RUN_SLUG=""

if [ "${1:-}" = "--run" ]; then
    if [ $# -lt 2 ] || [ -z "$2" ]; then
        echo "usage: bin/audit.sh [--run <slug>] [correlation_id ...]" >&2
        exit 64
    fi
    RUN_SLUG="$2"
    shift 2
fi

ENGINES=()
if [ -d "$STORE" ]; then
    shopt -s nullglob
    for ENGINE_DIR in "$STORE"/*; do
        [ -d "$ENGINE_DIR" ] || continue
        ENGINE_NAME="${ENGINE_DIR##*/}"
        for TOPOLOGY in "${TOPOLOGIES[@]}"; do
            BASE="$ENGINE_PREFIX-$TOPOLOGY"
            if [ -n "$RUN_SLUG" ]; then
                [ "$ENGINE_NAME" = "$BASE-$RUN_SLUG" ] || continue
            elif [ "$ENGINE_NAME" != "$BASE" ] && [[ "$ENGINE_NAME" != "$BASE-"* ]]; then
                continue
            fi
            ENGINES+=("$ENGINE_DIR")
            break
        done
    done
    shopt -u nullglob
fi

logs() {
    for engine in "${ENGINES[@]}"; do
        cat "$engine/logs"/events-*.jsonl 2>/dev/null || true
    done
}

# -R + fromjson?: a crashed engine can leave a torn line in the JSONL; parse
# each line defensively instead of letting one bad record kill the trail.
if [ $# -eq 0 ]; then
    echo "correlation ids in the event store:"
    logs | jq -Rr 'fromjson? // empty | .message.payload | objects | .correlation_id // empty' |
        sort | uniq -c | sort -rn
    exit 0
fi

for CID in "$@"; do
    echo "=== $CID ==="
    logs | jq -Rr --arg cid "$CID" '
        fromjson? // empty
        | select((.message.payload | type) == "object"
               and .message.payload.correlation_id == $cid)
        | .message.payload as $p
        | [ .timestamp,
            .message.message_type,
            .message.source,
            ([ (if $p.stage    != null then "stage=\($p.stage)"           else empty end),
               (if $p.current  != null then "shard=\($p.current.shard)"   else empty end),
               (if $p.round    != null then "round=\($p.round)"           else empty end),
               (if $p.verdict  != null then "verdict=\($p.verdict)"       else empty end),
               (if $p.decision != null then "decision=\($p.decision)"     else empty end),
               (if $p.floor    != null then "floor=\($p.floor)"           else empty end),
               (if $p.tip      != null and $p.tip != "" then "tip=\($p.tip)" else empty end),
               (if $p.merged   != null then "merged=\($p.merged | join(","))" else empty end),
               (if ($p.done | if . == null then [] else . end | length) > 0
                    then "done=\($p.done | join(","))" else empty end)
             ] | join(" "))
          ] | @tsv' |
        sort |
        column -t -s "$(printf '\t')"
done
