# Provenance helpers. Sourced, not executed; this file does not change shell options.
#
# Functions:
#   provenance_object <agent> <model> [effort]
#   stamp_provenance <run-relative-artifact-path> <agent> <model> [effort]
#   reset_provenance
#
# The map at $RUN_DIR/state/provenance.json has this on-disk shape:
#   {"path/to/artifact":{"agent":"codex","model":"gpt-5.6-sol",
#     "effort":"high","ts":"2026-07-27T10:04:11Z"}}
# The effort member is omitted when no non-empty effort is supplied.
#
# Provenance is diagnostic metadata: every function always returns 0, and no
# provenance failure can fail its caller. Only provenance_object writes stdout;
# stamp_provenance and reset_provenance keep caller event stdout untouched.
# shellcheck shell=bash

provenance_object() {
    local PROVENANCE_AGENT="${1:-}"
    local PROVENANCE_MODEL="${2:-}"
    local PROVENANCE_EFFORT="${3:-}"
    local PROVENANCE_JSON=""

    # Compare with [ ... ] rather than case/[[ ]]: a caller with
    # `shopt -s nocasematch` set would otherwise make these checks accept
    # variants such as CODEX and HIGH.
    if [ "$PROVENANCE_AGENT" != "claude" ] && [ "$PROVENANCE_AGENT" != "codex" ]; then
        printf '%s\n' "[provenance] agent must be claude or codex" >&2 || true
        printf '%s\n' "null" || true
        return 0
    fi

    if [ -z "$PROVENANCE_MODEL" ] \
        || [ "${#PROVENANCE_MODEL}" -gt 128 ] \
        || [[ ! "$PROVENANCE_MODEL" =~ ^[A-Za-z0-9._:+-]+$ ]]; then
        printf '%s\n' "[provenance] model is empty or invalid" >&2 || true
        printf '%s\n' "null" || true
        return 0
    fi

    if [ -n "$PROVENANCE_EFFORT" ] \
        && [ "$PROVENANCE_EFFORT" != "low" ] \
        && [ "$PROVENANCE_EFFORT" != "medium" ] \
        && [ "$PROVENANCE_EFFORT" != "high" ] \
        && [ "$PROVENANCE_EFFORT" != "xhigh" ] \
        && [ "$PROVENANCE_EFFORT" != "max" ]; then
        printf '%s\n' "[provenance] effort is invalid" >&2 || true
        printf '%s\n' "null" || true
        return 0
    fi

    if [ -n "$PROVENANCE_EFFORT" ]; then
        PROVENANCE_JSON="$(
            jq -cn -c \
                --arg agent "$PROVENANCE_AGENT" \
                --arg model "$PROVENANCE_MODEL" \
                --arg effort "$PROVENANCE_EFFORT" \
                '{agent: $agent, model: $model, effort: $effort}' \
                2>/dev/null || true
        )"
    else
        PROVENANCE_JSON="$(
            jq -cn -c \
                --arg agent "$PROVENANCE_AGENT" \
                --arg model "$PROVENANCE_MODEL" \
                '{agent: $agent, model: $model}' \
                2>/dev/null || true
        )"
    fi

    if [ -n "$PROVENANCE_JSON" ]; then
        printf '%s\n' "$PROVENANCE_JSON" || true
    else
        printf '%s\n' "[provenance] could not construct provenance JSON" >&2 || true
        printf '%s\n' "null" || true
    fi

    return 0
}

stamp_provenance() {
    local PROVENANCE_PATH="${1:-}"
    local PROVENANCE_AGENT="${2:-}"
    local PROVENANCE_MODEL="${3:-}"
    local PROVENANCE_EFFORT="${4:-}"
    local PROVENANCE_RUN_DIR="${RUN_DIR:-}"
    local PROVENANCE_OBJECT=""
    local PROVENANCE_STATE_DIR=""
    local PROVENANCE_MAP=""
    local PROVENANCE_LOCK=""
    local PROVENANCE_BASE=""
    local PROVENANCE_TS=""
    local PROVENANCE_MERGED=""
    local PROVENANCE_TEMP=""

    if [ -z "$PROVENANCE_RUN_DIR" ]; then
        printf '%s\n' "[provenance] RUN_DIR is unset; provenance was not stamped" >&2 || true
        return 0
    fi

    # Bash arguments cannot contain NUL bytes; reject every other forbidden
    # path shape explicitly.
    if [ -z "$PROVENANCE_PATH" ] \
        || [ "${#PROVENANCE_PATH}" -gt 256 ] \
        || [[ "$PROVENANCE_PATH" == /* ]] \
        || [[ "$PROVENANCE_PATH" =~ (^|/)\.\.(/|$) ]] \
        || [[ "$PROVENANCE_PATH" == *$'\n'* ]] \
        || [[ "$PROVENANCE_PATH" == *$'\r'* ]]; then
        printf '%s\n' "[provenance] artifact path is invalid" >&2 || true
        return 0
    fi

    PROVENANCE_OBJECT="$(
        provenance_object \
            "$PROVENANCE_AGENT" \
            "$PROVENANCE_MODEL" \
            "$PROVENANCE_EFFORT" || true
    )"
    if [ "$PROVENANCE_OBJECT" = "null" ] || [ -z "$PROVENANCE_OBJECT" ]; then
        printf '%s\n' "[provenance] invalid provenance was not stamped" >&2 || true
        return 0
    fi

    PROVENANCE_STATE_DIR="$PROVENANCE_RUN_DIR/state"
    PROVENANCE_MAP="$PROVENANCE_STATE_DIR/provenance.json"
    PROVENANCE_LOCK="$PROVENANCE_STATE_DIR/provenance.lock"

    if ! mkdir -p "$PROVENANCE_STATE_DIR" 2>/dev/null; then
        printf '%s\n' "[provenance] could not create provenance state directory" >&2 || true
        return 0
    fi

    (
        # >| rather than >: a caller with `set -o noclobber` would otherwise
        # fail to open the already-existing lock, silently skipping the stamp.
        if ! exec 9>|"$PROVENANCE_LOCK"; then
            printf '%s\n' "[provenance] could not open provenance lock" >&2 || true
            exit 0
        fi
        if ! flock -x 9 2>/dev/null; then
            printf '%s\n' "[provenance] could not acquire provenance lock" >&2 || true
            exit 0
        fi

        PROVENANCE_BASE="{}"
        if [ -s "$PROVENANCE_MAP" ]; then
            PROVENANCE_BASE="$(
                jq -c \
                    'if type == "object" then . else error("expected object") end' \
                    "$PROVENANCE_MAP" 2>/dev/null || true
            )"
            if [ -z "$PROVENANCE_BASE" ]; then
                printf '%s\n' "[provenance] provenance map is unparseable; starting from {}" >&2 || true
                PROVENANCE_BASE="{}"
            fi
        elif [ -e "$PROVENANCE_MAP" ]; then
            printf '%s\n' "[provenance] provenance map is empty; starting from {}" >&2 || true
        else
            printf '%s\n' "[provenance] provenance map is missing; starting from {}" >&2 || true
        fi

        PROVENANCE_TS="$(date -u +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || true)"
        if [ -z "$PROVENANCE_TS" ]; then
            printf '%s\n' "[provenance] could not create timestamp" >&2 || true
            exit 0
        fi

        PROVENANCE_MERGED="$(
            jq -cn -c \
                --arg path "$PROVENANCE_PATH" \
                --argjson provenance "$PROVENANCE_OBJECT" \
                --arg ts "$PROVENANCE_TS" \
                --argjson existing "$PROVENANCE_BASE" \
                '$existing + {($path): ($provenance + {ts: $ts})}' \
                2>/dev/null || true
        )"
        if [ -z "$PROVENANCE_MERGED" ]; then
            printf '%s\n' "[provenance] could not merge provenance map" >&2 || true
            exit 0
        fi

        PROVENANCE_TEMP="$(
            mktemp "$PROVENANCE_STATE_DIR/.provenance.json.tmp.XXXXXX" \
                2>/dev/null || true
        )"
        if [ -z "$PROVENANCE_TEMP" ]; then
            printf '%s\n' "[provenance] could not create temporary provenance map" >&2 || true
            exit 0
        fi

        # >| because mktemp already created this file, which plain > would
        # refuse to truncate under noclobber.
        if ! printf '%s\n' "$PROVENANCE_MERGED" >|"$PROVENANCE_TEMP"; then
            printf '%s\n' "[provenance] could not write temporary provenance map" >&2 || true
            rm -f -- "$PROVENANCE_TEMP" 2>/dev/null || true
            exit 0
        fi
        if ! mv -f -- "$PROVENANCE_TEMP" "$PROVENANCE_MAP" 2>/dev/null; then
            printf '%s\n' "[provenance] could not replace provenance map" >&2 || true
            rm -f -- "$PROVENANCE_TEMP" 2>/dev/null || true
            exit 0
        fi

        exit 0
    ) || {
        printf '%s\n' "[provenance] unexpected stamp failure was ignored" >&2 || true
    }

    return 0
}

reset_provenance() {
    local PROVENANCE_RUN_DIR="${RUN_DIR:-}"
    local PROVENANCE_STATE_DIR=""
    local PROVENANCE_MAP=""
    local PROVENANCE_LOCK=""

    if [ -z "$PROVENANCE_RUN_DIR" ]; then
        return 0
    fi

    PROVENANCE_STATE_DIR="$PROVENANCE_RUN_DIR/state"
    PROVENANCE_MAP="$PROVENANCE_STATE_DIR/provenance.json"
    PROVENANCE_LOCK="$PROVENANCE_STATE_DIR/provenance.lock"

    if ! mkdir -p "$PROVENANCE_STATE_DIR" 2>/dev/null; then
        printf '%s\n' "[provenance] could not create provenance state directory for reset" >&2 || true
        return 0
    fi

    (
        # >| for the same noclobber reason as in stamp_provenance.
        if ! exec 9>|"$PROVENANCE_LOCK"; then
            printf '%s\n' "[provenance] could not open provenance lock for reset" >&2 || true
            exit 0
        fi
        if ! flock -x 9 2>/dev/null; then
            printf '%s\n' "[provenance] could not acquire provenance lock for reset" >&2 || true
            exit 0
        fi
        if ! rm -f -- "$PROVENANCE_MAP" 2>/dev/null; then
            printf '%s\n' "[provenance] could not reset provenance map" >&2 || true
        fi
        exit 0
    ) || {
        printf '%s\n' "[provenance] unexpected reset failure was ignored" >&2 || true
    }

    return 0
}
