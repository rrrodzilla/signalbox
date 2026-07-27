#!/usr/bin/env bash
# Readiness ladder sink: bin/readiness.sh <up|down>, stdin = triggering payload.
#
# Mirrors TRIP-2's ladder, PER ACTION: a clean convergence (approved in <= 2
# rounds) promotes that action one R-level toward self-directed (R4); an
# escalation demotes it toward leader-directed (R1). Track record is earned
# per action — proven R4 on promote says nothing about push-remote, which
# starts at the R2 default like everything else.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIRECTION="${1:?usage: readiness.sh <up|down>}"
PAYLOAD="$(cat)"

ACTION="$(jq -r '.action // "promote"' <<<"$PAYLOAD")"

mkdir -p "$ROOT/state"

STATE="$ROOT/state/readiness.json"
# The ladder is the ONE artifact concurrent runs share: it is earned per repo,
# not per run. Read, compute and write are therefore one serialized
# transaction — two runs converging at the same moment must not both read R2
# and both write R3, and neither may observe a half-written file. The lock
# covers the whole transaction below; the write itself is a rename, so
# bin/readiness-get.sh (which takes no lock) can only ever see a complete file.
exec 9>"$STATE.lock"
flock -x 9

# The ladder moves from the EFFECTIVE (decayed) level — idle track record
# has already eroded before the next promotion builds on it.
LEVEL="$("$ROOT/bin/readiness-get.sh" "$ACTION")"

NEW="$LEVEL"
case "$DIRECTION" in
    up)
        ROUND="$(jq -r '.round // 99' <<<"$PAYLOAD")"
        if [ "$ROUND" -le 2 ] && [ "$LEVEL" -lt 4 ]; then
            NEW=$((LEVEL + 1))
        fi
        ;;
    down)
        if [ "$LEVEL" -gt 1 ]; then
            NEW=$((LEVEL - 1))
        fi
        ;;
    *)
        echo "usage: readiness.sh <up|down>" >&2
        exit 64
        ;;
esac

CURRENT="{}"
[ -f "$STATE" ] && CURRENT="$(cat "$STATE")"
TEMP="$STATE.tmp.$$"
jq --arg a "$ACTION" --argjson n "$NEW" --arg ts "$(date -u +%FT%TZ)" \
    '.[$a] = {level: $n, updated: $ts}' <<<"$CURRENT" >"$TEMP"
mv "$TEMP" "$STATE"

if [ "$NEW" -ne "$LEVEL" ]; then
    echo "[readiness] $ACTION: R$LEVEL -> R$NEW ($DIRECTION)"
else
    echo "[readiness] $ACTION: R$LEVEL unchanged ($DIRECTION)"
fi
