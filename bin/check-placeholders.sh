#!/usr/bin/env bash
# Render-sanity guard: bin/check-placeholders.sh <rendered-dir>
#
# Scans every *.toml directly under <rendered-dir> for live occurrences of
# the literal __SIGNALBOX_ placeholder marker — evidence that bin/run.sh's
# sed render left a token unsubstituted. Whole-line comments (first
# non-whitespace character '#', leading whitespace allowed) are skipped:
# the templates legitimately name the placeholder tokens in their own
# prose, so only a non-comment occurrence is evidence of a rendering
# failure. Deliberately NOT a TOML parser: a trailing inline comment that
# mentions a token is still reported, because stripping from '#' anywhere
# on a line could hide a real leftover inside a string value, and tracking
# TOML string state to tell the difference costs far more defect surface
# than this tripwire is worth. Standalone on purpose (no _env.sh): usable
# and testable against any directory.
#
# Exit status:
#   0   no live placeholder occurrences
#   1   live occurrences found (each printed as <file>:<line>:<text> to
#       stderr, then one summary error line), or <rendered-dir> is not a
#       directory containing at least one *.toml
#   64  invalid invocation (wrong argument count)
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

# Branch on captured output, not awk's exit status: awk exits 0 either way.
OFFENDING="$(
    awk '
        /^[[:space:]]*#/ { next }
        /__SIGNALBOX_/   { print FILENAME ":" FNR ":" $0 }
    ' "${TOML_FILES[@]}"
)"

if [ -n "$OFFENDING" ]; then
    printf '%s\n' "$OFFENDING" >&2
    echo "error: unresolved __SIGNALBOX_ placeholder in rendered run config" >&2
    exit 1
fi
