#!/usr/bin/env bash
# Usage: bin/check-placeholders.sh <rendered-dir>
#
# Checks every top-level TOML file in a rendered run directory for unresolved
# __SIGNALBOX_ placeholders. Whole-line comments are excluded because templates
# legitimately name the placeholder tokens in their own prose; only a live
# (non-comment) occurrence is evidence of a rendering failure.
#
# TOML string state is tracked while scanning so that a line beginning with #
# inside a multiline string is treated as string content, not as a comment:
# such a line still carries a live placeholder and is reported.
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
        BEGIN { DQ = "\""; SQ = "\047"; DQ3 = DQ DQ DQ; SQ3 = SQ SQ SQ }

        # Skip a single-line basic string, returning the index just past it.
        function skip_basic(s, i, n,   c) {
            while (i <= n) {
                c = substr(s, i, 1)
                if (c == "\\") { i += 2; continue }
                if (c == DQ) { return i + 1 }
                i++
            }
            return n + 1
        }

        # Skip a single-line literal string, which honours no escapes.
        function skip_literal(s, i, n) {
            while (i <= n) {
                if (substr(s, i, 1) == SQ) { return i + 1 }
                i++
            }
            return n + 1
        }

        # Walk one line, updating STATE: 0 outside any multiline string,
        # 1 inside a multiline basic string, 2 inside a multiline literal one.
        function scan(s,   i, n, c) {
            i = 1
            n = length(s)
            while (i <= n) {
                c = substr(s, i, 1)
                if (STATE == 0) {
                    if (c == "#") { return }
                    if (substr(s, i, 3) == DQ3) { STATE = 1; i += 3; continue }
                    if (substr(s, i, 3) == SQ3) { STATE = 2; i += 3; continue }
                    if (c == DQ) { i = skip_basic(s, i + 1, n); continue }
                    if (c == SQ) { i = skip_literal(s, i + 1, n); continue }
                    i++
                } else if (STATE == 1) {
                    if (c == "\\") { i += 2; continue }
                    if (substr(s, i, 3) == DQ3) { STATE = 0; i += 3; continue }
                    i++
                } else {
                    if (substr(s, i, 3) == SQ3) { STATE = 0; i += 3; continue }
                    i++
                }
            }
        }

        FNR == 1 { STATE = 0 }
        STATE == 0 && /^[[:space:]]*#/ { next }
        {
            scan($0)
            if ($0 ~ /__SIGNALBOX_/) { print FILENAME ":" FNR ":" $0 }
        }
    ' "${TOML_FILES[@]}"
)"

if [ -n "$OFFENDING" ]; then
    printf '%s\n' "$OFFENDING" >&2
    echo "error: unresolved __SIGNALBOX_ placeholder in rendered run config" >&2
    exit 1
fi
