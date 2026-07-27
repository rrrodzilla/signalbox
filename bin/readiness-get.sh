#!/usr/bin/env bash
# Effective readiness: bin/readiness-get.sh <action>  ->  prints R-level 1-4.
#
# Readiness goes stale: levels above the R2 default decay one step per idle
# DECAY_DAYS (default 7) since the ladder last moved them, floored at R2 —
# mirroring TRIP-2's reset toward R2 on thread reset. Decay is observed
# lazily at read time (no daemon; staleness is a property of the moment of
# use) and never persisted here — only the ladder writes state. R1 does not
# heal by waiting: distrust is earned back through track record, not time.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="${1:?usage: readiness-get.sh <action>}"
DECAY_DAYS="${DECAY_DAYS:-7}"
STATE="$ROOT/state/readiness.json"

if [ ! -f "$STATE" ]; then
    echo 2
    exit 0
fi

# stored<TAB>effective; legacy bare-number entries have no timestamp, so they
# are treated as fresh (the next ladder write upgrades them to {level, updated}).
IFS=$'\t' read -r STORED EFFECTIVE <<<"$(jq -r --arg a "$ACTION" --argjson dd "$DECAY_DAYS" '
    .[$a]
    | if . == null then [2, 2]
      elif type == "number" then [., .]
      else
        .level as $l
        | (((now - (.updated | fromdateiso8601)) / 86400 / $dd) | floor) as $steps
        | [$l, (if $l > 2 then ([$l - $steps, 2] | max) else $l end)]
      end
    | @tsv' "$STATE")"

if [ "$EFFECTIVE" -lt "$STORED" ]; then
    echo "[readiness] $ACTION: stored R$STORED decayed to R$EFFECTIVE (idle)" >&2
fi

echo "$EFFECTIVE"
