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
# Prototype runs get the default port block (install.sh allocates per-repo).
sed -e "s|__SIGNALBOX_ROOT__|$ROOT|g" \
    -e "s|__SIGNALBOX_RUN_SUFFIX__||g" \
    -e "s|__SIGNALBOX_PORT_PIPELINE__|8100|g" \
    -e "s|__SIGNALBOX_PORT_PLAN__|8101|g" \
    -e "s|__SIGNALBOX_PORT_IMPLEMENT__|8102|g" \
    -e "s|__SIGNALBOX_PORT_REVIEW__|8103|g" \
    -e "s|__SIGNALBOX_PORT_INIT__|8104|g" \
    -e "s|__SIGNALBOX_PORT_APPROVAL__|8105|g" \
    "$ROOT/$CFG" >"$ROOT/rendered/$CFG"

exec emergent --config "$ROOT/rendered/$CFG" "$@"
