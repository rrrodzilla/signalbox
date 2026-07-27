# Correlation ID helpers. Sourced, not executed; this file does not change
# shell options.
#
# Functions:
#   correlation_stamp
#     Print one compact UTC timestamp.
#   correlation_token <raw> [fallback]
#     Normalize arbitrary input into a non-empty, directory-safe token.
#   inherited_correlation_id
#     Print and accept a valid SIGNALBOX_CORRELATION_ID, or print nothing and
#     return 1.
#   mint_correlation_id <prefix> <slug>
#     Print a sanitized prefix, slug token, and UTC stamp as one ID.
#   resolve_correlation_id <prefix> <slug>
#     Print a valid inherited ID when present, otherwise mint one; return 0.
#
# Every timestamp is UTC via `date -u`: one clock per harness keeps IDs minted
# in different phases of the same run orderable. This is the issue #42
# regression boundary.
# shellcheck shell=bash

correlation_stamp() {
    date -u +%Y%m%d-%H%M%S
}

correlation_token() {
    local LC_ALL=C
    local CORRELATION_RAW="${1:-}"
    local CORRELATION_FALLBACK="${2:-}"
    local CORRELATION_TOKEN=""
    local CORRELATION_CHAR=""
    local CORRELATION_INDEX=0
    local CORRELATION_LENGTH="${#CORRELATION_RAW}"

    for ((CORRELATION_INDEX = 0; CORRELATION_INDEX < CORRELATION_LENGTH; CORRELATION_INDEX++)); do
        CORRELATION_CHAR="${CORRELATION_RAW:CORRELATION_INDEX:1}"
        case "$CORRELATION_CHAR" in
            [A-Za-z0-9._-]) ;;
            *) CORRELATION_CHAR="-" ;;
        esac

        if [ "$CORRELATION_CHAR" = "-" ] && [[ "$CORRELATION_TOKEN" == *- ]]; then
            continue
        fi
        CORRELATION_TOKEN+="$CORRELATION_CHAR"
    done

    while [[ "$CORRELATION_TOKEN" == [-.]* ]]; do
        CORRELATION_TOKEN="${CORRELATION_TOKEN:1}"
    done
    while [[ "$CORRELATION_TOKEN" == *[-.] ]]; do
        CORRELATION_TOKEN="${CORRELATION_TOKEN:0:${#CORRELATION_TOKEN}-1}"
    done

    CORRELATION_TOKEN="${CORRELATION_TOKEN:0:64}"
    while [[ "$CORRELATION_TOKEN" == *- ]]; do
        CORRELATION_TOKEN="${CORRELATION_TOKEN:0:${#CORRELATION_TOKEN}-1}"
    done

    if [ -n "$CORRELATION_TOKEN" ]; then
        printf '%s\n' "$CORRELATION_TOKEN"
    elif [ -n "$CORRELATION_FALLBACK" ]; then
        printf '%s\n' "$CORRELATION_FALLBACK"
    else
        printf '%s\n' "unknown"
    fi
}

inherited_correlation_id() {
    local CORRELATION_ID="${SIGNALBOX_CORRELATION_ID:-}"

    # Callers running under set -e must invoke this probe as
    # "$(inherited_correlation_id || true)".
    if [ -n "$CORRELATION_ID" ] \
        && [ "${#CORRELATION_ID}" -le 128 ] \
        && [[ "$CORRELATION_ID" =~ ^[A-Za-z0-9._-]+$ ]] \
        && [[ "$CORRELATION_ID" != *".."* ]]; then
        printf '%s\n' "$CORRELATION_ID"
        return 0
    fi

    return 1
}

mint_correlation_id() {
    local CORRELATION_PREFIX="${1:-}"
    local CORRELATION_SLUG="${2:-}"
    local CORRELATION_PREFIX_TOKEN=""
    local CORRELATION_SLUG_TOKEN=""
    local CORRELATION_STAMP=""

    CORRELATION_PREFIX_TOKEN="$(correlation_token "$CORRELATION_PREFIX" "run")"
    CORRELATION_SLUG_TOKEN="$(correlation_token "$CORRELATION_SLUG")"
    CORRELATION_STAMP="$(correlation_stamp)"
    printf '%s-%s-%s\n' \
        "$CORRELATION_PREFIX_TOKEN" \
        "$CORRELATION_SLUG_TOKEN" \
        "$CORRELATION_STAMP"
}

resolve_correlation_id() {
    local CORRELATION_PREFIX="${1:-}"
    local CORRELATION_SLUG="${2:-}"
    local CORRELATION_INHERITED=""

    if CORRELATION_INHERITED="$(inherited_correlation_id)"; then
        printf '%s\n' "$CORRELATION_INHERITED"
    else
        mint_correlation_id "$CORRELATION_PREFIX" "$CORRELATION_SLUG"
    fi
    return 0
}
