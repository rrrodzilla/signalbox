#!/usr/bin/env bash
# Run a topology straight from this clone: dev.sh <config.toml> [engine args...]
#
# The tracked TOMLs carry a neutral __SIGNALBOX_ROOT__ placeholder instead of any
# machine's absolute path (emergent configs need absolute paths; baking a
# developer's home directory into tracked files leaks it and breaks every
# other clone). This renders the requested config against THIS clone's path
# into gitignored rendered/ and execs the engine on it. install.sh does the
# same rendering against the target repo's .claude/emergent.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="${1:?usage: dev.sh <config.toml> [emergent args...]}"
shift || true
[ -f "$ROOT/$CFG" ] || { echo "error: no $CFG in $ROOT" >&2; exit 64; }

mkdir -p "$ROOT/rendered"
# Prototype runs render only the approval port; SSE uses the shared sink service
# on ${SIGNALBOX_SINK_PORT:-8099}.
sed -e "s|__SIGNALBOX_ROOT__|$ROOT|g" \
    -e "s|__SIGNALBOX_RUN_SUFFIX__||g" \
    -e "s|__SIGNALBOX_PORT_APPROVAL__|8105|g" \
    "$ROOT/$CFG" >"$ROOT/rendered/$CFG"

exec emergent --config "$ROOT/rendered/$CFG" "$@"
