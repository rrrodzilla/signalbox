#!/usr/bin/env bash
# Usage: bin/check-placeholders.sh <rendered-dir>
#
# Checks every top-level TOML file in a rendered run directory for unresolved
# __SIGNALBOX_ placeholders. Whole-line comments are excluded because templates
# legitimately name the placeholder tokens in their own prose; only a live
# (non-comment) occurrence is evidence of a rendering failure.
#
# Exits 0 when no live placeholders remain, 64 on invalid invocation, and 1
# when the directory is unusable or a live placeholder remains.
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "usage: bin/check-placeholders.sh <rendered-dir>" >&2
    exit 64
fi

RENDERED_DIR="$1"
if [ ! -d "$RENDERED_DIR" ]; then
    echo "error: rendered directory does not exist: $RENDERED_DIR" >&2
    exit 1
fi

shopt -s nullglob
TOML_FILES=("$RENDERED_DIR"/*.toml)
shopt -u nullglob

if [ "${#TOML_FILES[@]}" -eq 0 ]; then
    echo "error: rendered directory contains no TOML files: $RENDERED_DIR" >&2
    exit 1
fi

OFFENDING="$(
    awk '
        /^[[:space:]]*#/ { next }
        /__SIGNALBOX_/ { print FILENAME ":" FNR ":" $0 }
    ' "${TOML_FILES[@]}"
)"

if [ -n "$OFFENDING" ]; then
    printf '%s\n' "$OFFENDING" >&2
    echo "error: unresolved __SIGNALBOX_ placeholder in rendered run config" >&2
    exit 1
fi
