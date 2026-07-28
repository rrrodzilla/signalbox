#!/usr/bin/env bash
# Self-contained test runner for UTC correlation stamps, token normalization,
# inherited ID validation, minting, and resolution. It covers the issue #42
# one-clock regression and uses no test framework or added dependencies.
# Prints one PASS/FAIL line per case and exits non-zero when any case failed.
#
# Deliberately no -e: cases capture non-zero subject statuses for assertions.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTS_RUN=0
TESTS_PASSED=0
FIXTURE_ROOT="$(mktemp -d)"

# shellcheck source=../bin/_correlation.sh
source "$ROOT/bin/_correlation.sh"

cleanup() {
    if [ -n "$FIXTURE_ROOT" ] && [ -d "$FIXTURE_ROOT" ]; then
        rm -rf -- "$FIXTURE_ROOT"
    fi
}
trap cleanup EXIT

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

STAMP="$(correlation_stamp)"
STAMP_STATUS=$?
OK=1
if [ "$STAMP_STATUS" -eq 0 ] \
    && [[ "$STAMP" =~ ^[0-9]{8}-[0-9]{6}$ ]]; then
    OK=0
fi
report_case "correlation_stamp has the compact timestamp shape" "$OK" \
    "status=$STAMP_STATUS stamp=$STAMP"

UTC_BEFORE="$(date -u +%Y%m%d-%H%M%S)"
STAMP="$(correlation_stamp)"
STAMP_STATUS=$?
UTC_AFTER="$(date -u +%Y%m%d-%H%M%S)"
OK=1
if [ "$STAMP_STATUS" -eq 0 ] \
    && { [ "$STAMP" = "$UTC_BEFORE" ] || [ "$STAMP" = "$UTC_AFTER" ]; }; then
    OK=0
fi
report_case "correlation_stamp uses UTC" "$OK" \
    "status=$STAMP_STATUS before=$UTC_BEFORE stamp=$STAMP after=$UTC_AFTER"

CHICAGO_BEFORE="$(date -u +%Y%m%d-%H%M%S)"
CHICAGO_STAMP="$(TZ=America/Chicago correlation_stamp)"
CHICAGO_STATUS=$?
CHICAGO_AFTER="$(date -u +%Y%m%d-%H%M%S)"
ZONE_UTC_BEFORE="$(date -u +%Y%m%d-%H%M%S)"
ZONE_UTC_STAMP="$(TZ=UTC correlation_stamp)"
ZONE_UTC_STATUS=$?
ZONE_UTC_AFTER="$(date -u +%Y%m%d-%H%M%S)"
OK=1
if [ "$CHICAGO_STATUS" -eq 0 ] \
    && [ "$ZONE_UTC_STATUS" -eq 0 ] \
    && { [ "$CHICAGO_STAMP" = "$CHICAGO_BEFORE" ] \
        || [ "$CHICAGO_STAMP" = "$CHICAGO_AFTER" ]; } \
    && { [ "$ZONE_UTC_STAMP" = "$ZONE_UTC_BEFORE" ] \
        || [ "$ZONE_UTC_STAMP" = "$ZONE_UTC_AFTER" ]; }; then
    OK=0
fi
report_case "correlation_stamp ignores the local time zone" "$OK" \
    "chicago=$CHICAGO_STAMP utc=$ZONE_UTC_STAMP"

TOKEN="$(correlation_token "feature/name with spaces")"
TOKEN_STATUS=$?
OK=1
if [ "$TOKEN_STATUS" -eq 0 ] \
    && [ "$TOKEN" = "feature-name-with-spaces" ]; then
    OK=0
fi
report_case "correlation_token replaces unsafe characters" "$OK" \
    "status=$TOKEN_STATUS token=$TOKEN"

TOKEN="$(correlation_token "a///b")"
TOKEN_STATUS=$?
OK=1
if [ "$TOKEN_STATUS" -eq 0 ] && [ "$TOKEN" = "a-b" ]; then
    OK=0
fi
report_case "correlation_token collapses hyphen runs" "$OK" \
    "status=$TOKEN_STATUS token=$TOKEN"

TOKEN="$(correlation_token "--x--")"
TOKEN_STATUS=$?
OK=1
if [ "$TOKEN_STATUS" -eq 0 ] && [ "$TOKEN" = "x" ]; then
    OK=0
fi
report_case "correlation_token trims edge separators" "$OK" \
    "status=$TOKEN_STATUS token=$TOKEN"

TOKEN="$(correlation_token "///" "fallback")"
TOKEN_STATUS=$?
OK=1
if [ "$TOKEN_STATUS" -eq 0 ] && [ "$TOKEN" = "fallback" ]; then
    OK=0
fi
report_case "correlation_token uses a supplied fallback" "$OK" \
    "status=$TOKEN_STATUS token=$TOKEN"

TOKEN="$(correlation_token "")"
TOKEN_STATUS=$?
OK=1
if [ "$TOKEN_STATUS" -eq 0 ] && [ "$TOKEN" = "unknown" ]; then
    OK=0
fi
report_case "correlation_token defaults empty input to unknown" "$OK" \
    "status=$TOKEN_STATUS token=$TOKEN"

printf -v LONG_HEAD '%*s' 63 ""
LONG_HEAD="${LONG_HEAD// /a}"
printf -v LONG_TAIL '%*s' 136 ""
LONG_TAIL="${LONG_TAIL// /b}"
LONG_RAW="$LONG_HEAD/$LONG_TAIL"
TOKEN="$(correlation_token "$LONG_RAW")"
TOKEN_STATUS=$?
OK=1
if [ "$TOKEN_STATUS" -eq 0 ] \
    && [ "${#LONG_RAW}" -eq 200 ] \
    && [ "${#TOKEN}" -le 64 ] \
    && [[ "$TOKEN" != *- ]]; then
    OK=0
fi
report_case "correlation_token truncates to 64 without a trailing hyphen" "$OK" \
    "status=$TOKEN_STATUS raw_length=${#LONG_RAW} token_length=${#TOKEN}"

MINTED="$(mint_correlation_id "review" "demo-parse-pairs")"
MINTED_STATUS=$?
OK=1
if [ "$MINTED_STATUS" -eq 0 ] \
    && [[ "$MINTED" =~ ^review-demo-parse-pairs-[0-9]{8}-[0-9]{6}$ ]]; then
    OK=0
fi
report_case "mint_correlation_id joins prefix, slug, and stamp" "$OK" \
    "status=$MINTED_STATUS id=$MINTED"

MINTED="$(mint_correlation_id "review phase" "demo/parse pairs")"
MINTED_STATUS=$?
OK=1
if [ "$MINTED_STATUS" -eq 0 ] \
    && [[ "$MINTED" =~ ^[A-Za-z0-9._-]+$ ]]; then
    OK=0
fi
report_case "mint_correlation_id sanitizes both arguments" "$OK" \
    "status=$MINTED_STATUS id=$MINTED"

UNSET_OUTPUT="$(
    unset SIGNALBOX_CORRELATION_ID
    inherited_correlation_id
)"
UNSET_STATUS=$?
OK=1
if [ "$UNSET_STATUS" -ne 0 ] && [ -z "$UNSET_OUTPUT" ]; then
    OK=0
fi
report_case "inherited_correlation_id rejects an unset variable" "$OK" \
    "status=$UNSET_STATUS output=$UNSET_OUTPUT"

EMPTY_OUTPUT="$(
    export SIGNALBOX_CORRELATION_ID=""
    inherited_correlation_id
)"
EMPTY_STATUS=$?
OK=1
if [ "$EMPTY_STATUS" -ne 0 ] && [ -z "$EMPTY_OUTPUT" ]; then
    OK=0
fi
report_case "inherited_correlation_id rejects an empty variable" "$OK" \
    "status=$EMPTY_STATUS output=$EMPTY_OUTPUT"

SPACE_OUTPUT="$(
    export SIGNALBOX_CORRELATION_ID="pipe 42"
    inherited_correlation_id
)"
SPACE_STATUS=$?
OK=1
if [ "$SPACE_STATUS" -ne 0 ] && [ -z "$SPACE_OUTPUT" ]; then
    OK=0
fi
report_case "inherited_correlation_id rejects spaces" "$OK" \
    "status=$SPACE_STATUS output=$SPACE_OUTPUT"

SLASH_OUTPUT="$(
    export SIGNALBOX_CORRELATION_ID="pipe/42"
    inherited_correlation_id
)"
SLASH_STATUS=$?
OK=1
if [ "$SLASH_STATUS" -ne 0 ] && [ -z "$SLASH_OUTPUT" ]; then
    OK=0
fi
report_case "inherited_correlation_id rejects slashes" "$OK" \
    "status=$SLASH_STATUS output=$SLASH_OUTPUT"

DOTDOT_OUTPUT="$(
    export SIGNALBOX_CORRELATION_ID="pipe..42"
    inherited_correlation_id
)"
DOTDOT_STATUS=$?
OK=1
if [ "$DOTDOT_STATUS" -ne 0 ] && [ -z "$DOTDOT_OUTPUT" ]; then
    OK=0
fi
report_case "inherited_correlation_id rejects dot-dot sequences" "$OK" \
    "status=$DOTDOT_STATUS output=$DOTDOT_OUTPUT"

printf -v TOO_LONG_ID '%*s' 129 ""
TOO_LONG_ID="${TOO_LONG_ID// /a}"
LONG_OUTPUT="$(
    export SIGNALBOX_CORRELATION_ID="$TOO_LONG_ID"
    inherited_correlation_id
)"
LONG_STATUS=$?
OK=1
if [ "$LONG_STATUS" -ne 0 ] && [ -z "$LONG_OUTPUT" ]; then
    OK=0
fi
report_case "inherited_correlation_id rejects 129 characters" "$OK" \
    "status=$LONG_STATUS output_length=${#LONG_OUTPUT}"

VALID_ID="pipe-42-20260727-231704"
VALID_OUTPUT="$(
    export SIGNALBOX_CORRELATION_ID="$VALID_ID"
    inherited_correlation_id
)"
VALID_STATUS=$?
OK=1
if [ "$VALID_STATUS" -eq 0 ] && [ "$VALID_OUTPUT" = "$VALID_ID" ]; then
    OK=0
fi
report_case "inherited_correlation_id returns a valid ID verbatim" "$OK" \
    "status=$VALID_STATUS output=$VALID_OUTPUT"

RESOLVED="$(
    export SIGNALBOX_CORRELATION_ID="$VALID_ID"
    resolve_correlation_id "impl" "demo"
)"
RESOLVED_STATUS=$?
OK=1
if [ "$RESOLVED_STATUS" -eq 0 ] && [ "$RESOLVED" = "$VALID_ID" ]; then
    OK=0
fi
report_case "resolve_correlation_id prefers an inherited ID" "$OK" \
    "status=$RESOLVED_STATUS output=$RESOLVED"

RESOLVED="$(
    unset SIGNALBOX_CORRELATION_ID
    resolve_correlation_id "impl" "demo"
)"
RESOLVED_STATUS=$?
OK=1
if [ "$RESOLVED_STATUS" -eq 0 ] \
    && [[ "$RESOLVED" =~ ^impl-demo-[0-9]{8}-[0-9]{6}$ ]]; then
    OK=0
fi
report_case "resolve_correlation_id mints when inheritance is unset" "$OK" \
    "status=$RESOLVED_STATUS output=$RESOLVED"

RESOLVED="$(
    export SIGNALBOX_CORRELATION_ID="bad inherited/id"
    resolve_correlation_id "impl" "demo"
)"
RESOLVED_STATUS=$?
OK=1
if [ "$RESOLVED_STATUS" -eq 0 ] \
    && [[ "$RESOLVED" =~ ^impl-demo-[0-9]{8}-[0-9]{6}$ ]]; then
    OK=0
fi
report_case "resolve_correlation_id mints when inheritance is malformed" "$OK" \
    "status=$RESOLVED_STATUS output=$RESOLVED"

printf '%d/%d cases passed\n' "$TESTS_PASSED" "$TESTS_RUN"
[ "$TESTS_PASSED" -eq "$TESTS_RUN" ]
