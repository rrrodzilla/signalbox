#!/usr/bin/env bash
# bin/terminal-record.sh <complete|halted> [run-dir]
#
# stdin is exactly one pipeline.complete or pipeline.halted payload JSON value.
# The script atomically records it as <run-dir>/state/complete.json or
# <run-dir>/state/halted.json. When [run-dir] is omitted, bin/_env.sh supplies
# RUN_DIR. Empty, malformed, or non-object input is preserved as a truncated
# {"raw": ...} payload and still produces terminal evidence. stdout stays empty;
# diagnostics go to stderr.
#
# Exit status:
#   0   terminal evidence written, including for malformed or empty stdin
#   64  invalid invocation (wrong argument count or unknown terminal kind)
set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    echo "usage: bin/terminal-record.sh <complete|halted> [run-dir]" >&2
    exit 64
fi

TERMINAL="$1"
case "$TERMINAL" in
    complete|halted) ;;
    *)
        echo "usage: bin/terminal-record.sh <complete|halted> [run-dir]" >&2
        exit 64
        ;;
esac

if [ "$#" -eq 2 ]; then
    RUN_DIR="$2"
else
    # shellcheck source=_env.sh
    source "$(dirname "${BASH_SOURCE[0]}")/_env.sh"
fi

RAW_WITH_SENTINEL="$({ cat 2>/dev/null || true; printf 'x'; })"
RAW_PAYLOAD="${RAW_WITH_SENTINEL%?}"

if PAYLOAD="$(
    jq -c -s \
        'if length == 1 and (.[0] | type == "object")
         then .[0]
         else error("expected one JSON object")
         end' \
        <<<"$RAW_PAYLOAD" 2>/dev/null
)"; then
    :
else
    PAYLOAD="$(
        LC_ALL=C printf '%s' "$RAW_PAYLOAD" \
            | head -c 4096 \
            | jq -Rsc '{raw: .}'
    )"
fi

STATE_DIR="$RUN_DIR/state"
TARGET="$STATE_DIR/$TERMINAL.json"
TEMP=""

cleanup() {
    if [ -n "$TEMP" ] && [ -e "$TEMP" ]; then
        rm -f -- "$TEMP"
    fi
}
trap cleanup EXIT

mkdir -p "$STATE_DIR"
TEMP="$(mktemp "$STATE_DIR/.$TERMINAL.json.tmp.XXXXXX")"

printf '%s\n' "$PAYLOAD" \
    | jq -n \
        --arg terminal "$TERMINAL" \
        '
        def integer_or_null($value):
            if (($value | type) == "number") and (($value | floor) == $value)
            then $value
            else null
            end;
        def string_or_null($value):
            if ($value | type) == "string" then $value else null end;

        input as $payload
        | {
            terminal: $terminal,
            issue: integer_or_null($payload.issue),
            phase: string_or_null($payload.phase),
            parked: (
                $terminal == "complete"
                and (($payload.parked | type) == "boolean")
                and $payload.parked
            ),
            outcome: (
                if $terminal == "halted"
                then string_or_null($payload.outcome)
                else null
                end
            ),
            reason: string_or_null($payload.reason),
            correlation_id: string_or_null($payload.correlation_id),
            payload: $payload,
            ts: (now | todate)
        }
        ' >|"$TEMP"

mv -f -- "$TEMP" "$TARGET"
TEMP=""
trap - EXIT

printf 'terminal-record: wrote %s\n' "$TARGET" >&2
