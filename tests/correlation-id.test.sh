#!/usr/bin/env bash
# Self-contained test runner for envelope correlation reading. The run's ID is
# minted by exec-source and reaches a script as EMERGENT_CORRELATION_ID; these
# cases cover the shape it must accept, everything it must reject, and the
# issue #42 boundary: a script that cannot see the envelope reports absence
# rather than inventing a replacement ID.
# Prints one PASS/FAIL line per case and exits non-zero when any case failed.
#
# Deliberately no -e: cases capture non-zero subject statuses for assertions.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTS_RUN=0
TESTS_PASSED=0

# shellcheck source=../bin/_correlation.sh
source "$ROOT/bin/_correlation.sh"

# A well-formed TypeID: "cor_" plus 26 Crockford base32 characters.
VALID_ID="cor_01kyk5bd3xfcgbvh2tacztktzb"

report_case() {
    local NAME="$1"
    local OK="$2"
    local DETAIL="${3:-}"

    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$OK" -eq 0 ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        printf 'PASS %s\n' "$NAME"
    else
        printf 'FAIL %s%s\n' "$NAME" "${DETAIL:+ — $DETAIL}"
    fi
}

# Assert that correlation_id rejects $2, printing nothing and returning
# non-zero, and that correlation_id_or_empty degrades to empty-and-zero.
assert_rejected() {
    local NAME="$1"
    local VALUE="$2"
    local OUTPUT STATUS FALLBACK FALLBACK_STATUS OK=1

    OUTPUT="$(
        export EMERGENT_CORRELATION_ID="$VALUE"
        correlation_id
    )"
    STATUS=$?
    FALLBACK="$(
        export EMERGENT_CORRELATION_ID="$VALUE"
        correlation_id_or_empty
    )"
    FALLBACK_STATUS=$?

    if [ "$STATUS" -ne 0 ] \
        && [ -z "$OUTPUT" ] \
        && [ "$FALLBACK_STATUS" -eq 0 ] \
        && [ -z "$FALLBACK" ]; then
        OK=0
    fi
    report_case "$NAME" "$OK" \
        "status=$STATUS output=$OUTPUT fallback_status=$FALLBACK_STATUS"
}

VALID_OUTPUT="$(
    export EMERGENT_CORRELATION_ID="$VALID_ID"
    correlation_id
)"
VALID_STATUS=$?
OK=1
if [ "$VALID_STATUS" -eq 0 ] && [ "$VALID_OUTPUT" = "$VALID_ID" ]; then
    OK=0
fi
report_case "correlation_id returns a valid TypeID verbatim" "$OK" \
    "status=$VALID_STATUS output=$VALID_OUTPUT"

FALLBACK_OUTPUT="$(
    export EMERGENT_CORRELATION_ID="$VALID_ID"
    correlation_id_or_empty
)"
FALLBACK_STATUS=$?
OK=1
if [ "$FALLBACK_STATUS" -eq 0 ] && [ "$FALLBACK_OUTPUT" = "$VALID_ID" ]; then
    OK=0
fi
report_case "correlation_id_or_empty returns a valid TypeID verbatim" "$OK" \
    "status=$FALLBACK_STATUS output=$FALLBACK_OUTPUT"

UNSET_OUTPUT="$(
    unset EMERGENT_CORRELATION_ID
    correlation_id
)"
UNSET_STATUS=$?
OK=1
if [ "$UNSET_STATUS" -ne 0 ] && [ -z "$UNSET_OUTPUT" ]; then
    OK=0
fi
report_case "correlation_id rejects an unset variable" "$OK" \
    "status=$UNSET_STATUS output=$UNSET_OUTPUT"

assert_rejected "correlation_id rejects an empty variable" ""
assert_rejected "correlation_id rejects spaces" "cor_01kyk5bd3x fcgbvh2tacztk"
assert_rejected "correlation_id rejects slashes" "cor_01kyk5bd3xfcgbvh2tacztkt/"
assert_rejected "correlation_id rejects dot-dot sequences" "cor_..01kyk5bd3x"

# The hand-minted shape this harness used before the ID moved to the envelope.
# Accepting it would key a trail on a value the event store never recorded.
assert_rejected "correlation_id rejects a legacy hand-minted ID" \
    "pipe-42-20260727-231704"

# A message ID is a TypeID too, but with the wrong prefix.
assert_rejected "correlation_id rejects a wrong-prefix TypeID" \
    "msg_01h455vb4pex5vsknk084sn02q"

assert_rejected "correlation_id rejects a bare prefix" "cor_"

# Crockford base32 excludes i, l, o and u so they cannot be confused with
# 1 and 0; a suffix containing one was never minted by the fabric.
assert_rejected "correlation_id rejects excluded base32 letters" \
    "cor_01kyk5bd3xfcgbvh2taczilou"

assert_rejected "correlation_id rejects a 25-character suffix" \
    "cor_01kyk5bd3xfcgbvh2tacztkt"
assert_rejected "correlation_id rejects a 27-character suffix" \
    "cor_01kyk5bd3xfcgbvh2tacztktzbb"

UPPER_ID="cor_01KYK5BD3XFCGBVH2TACZTKTZB"
assert_rejected "correlation_id rejects an upper-case suffix" "$UPPER_ID"

printf '%d/%d cases passed\n' "$TESTS_PASSED" "$TESTS_RUN"
[ "$TESTS_PASSED" -eq "$TESTS_RUN" ]
