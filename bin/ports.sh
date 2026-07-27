#!/usr/bin/env bash
# Per-run port lease registry.
# Invocation:
#   bin/ports.sh lease <slug>   stdout = leased base port
#   bin/ports.sh release <slug> stdout = empty
#   bin/ports.sh list           stdout = human-readable global lease table
# Diagnostics are written to stderr. This is an operator utility, not a
# topology handler, and it has no stdin event contract.
set -euo pipefail
# shellcheck source=_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/_env.sh"

usage() {
    echo "usage: bin/ports.sh lease <slug> | release <slug> | list" >&2
}

pid_alive() {
    local PID_VALUE="$1"
    [[ "$PID_VALUE" =~ ^[1-9][0-9]*$ ]] && kill -0 "$PID_VALUE" 2>/dev/null
}

write_registry() {
    local FILTER="$1"
    shift
    local TEMP="${REGISTRY}.tmp.$$"

    jq "$@" "$FILTER" "$REGISTRY" >"$TEMP"
    mv "$TEMP" "$REGISTRY"
}

reap_dead() {
    local ENTRY KEY PID_VALUE

    while IFS= read -r ENTRY; do
        KEY="$(jq -r '.key' <<<"$ENTRY")"
        PID_VALUE="$(jq -r '.value.pid // empty' <<<"$ENTRY")"
        if ! pid_alive "$PID_VALUE"; then
            write_registry 'del(.[$key])' --arg key "$KEY"
        fi
    done < <(jq -c 'to_entries[]' "$REGISTRY")
}

block_overlaps() {
    local BASE_VALUE="$1"
    local OTHER_BASE="$2"

    [ "$BASE_VALUE" -le "$((OTHER_BASE + 5))" ] \
        && [ "$((BASE_VALUE + 5))" -ge "$OTHER_BASE" ]
}

reserved_block_overlaps() {
    local BASE_VALUE="$1"
    local RESERVED_BASE

    [ -s "$PORT_REGISTRY" ] || return 1
    while IFS= read -r RESERVED_BASE; do
        if [[ "$RESERVED_BASE" =~ ^[0-9]+$ ]] \
            && block_overlaps "$BASE_VALUE" "$RESERVED_BASE"; then
            return 0
        fi
    done < <(jq -r '.[]' "$PORT_REGISTRY")
    return 1
}

lease_block_overlaps() {
    local BASE_VALUE="$1"
    local LEASE_BASE

    while IFS= read -r LEASE_BASE; do
        if [[ "$LEASE_BASE" =~ ^[0-9]+$ ]] \
            && block_overlaps "$BASE_VALUE" "$LEASE_BASE"; then
            return 0
        fi
    done < <(jq -r 'to_entries[] | .value.base' "$REGISTRY")
    return 1
}

port_accepts_tcp() {
    local PORT_VALUE="$1"

    # Connection refusal is the expected result for a free candidate port.
    if (exec 3<>"/dev/tcp/127.0.0.1/$PORT_VALUE") 2>/dev/null; then
        return 0
    fi
    return 1
}

block_accepts_tcp() {
    local BASE_VALUE="$1"
    local PORT_VALUE

    for ((PORT_VALUE = BASE_VALUE; PORT_VALUE <= BASE_VALUE + 5; PORT_VALUE++)); do
        if port_accepts_tcp "$PORT_VALUE"; then
            return 0
        fi
    done
    return 1
}

COMMAND="${1:-}"
SLUG="${2:-}"
case "$COMMAND" in
    lease|release)
        if [ $# -ne 2 ] || [ -z "$SLUG" ]; then
            usage
            exit 64
        fi
        ;;
    list)
        if [ $# -ne 1 ]; then
            usage
            exit 64
        fi
        ;;
    *)
        usage
        exit 64
        ;;
esac

REGISTRY="${SIGNALBOX_LEASE_REGISTRY:-$HOME/.local/share/signalbox/leases.json}"
case "$REGISTRY" in
    *.json) LOCK="${REGISTRY%.json}.lock" ;;
    *)      LOCK="${REGISTRY}.lock" ;;
esac
PORT_REGISTRY="$HOME/.local/share/signalbox/ports.json"
REPO="$(basename "$REPO_ROOT")"
KEY="$REPO/$SLUG"

mkdir -p "$(dirname "$REGISTRY")"
exec 9>"$LOCK"
flock -x 9
[ -s "$REGISTRY" ] || jq -n '{}' >"$REGISTRY"
if ! jq -e 'type == "object"' "$REGISTRY" >/dev/null; then
    echo "error: lease registry is not a JSON object: $REGISTRY" >&2
    exit 1
fi

case "$COMMAND" in
    lease)
        CALLER_PID="${SIGNALBOX_LEASE_PID:-$PPID}"
        if ! [[ "$CALLER_PID" =~ ^[1-9][0-9]*$ ]]; then
            echo "error: invalid lease owner pid: $CALLER_PID" >&2
            exit 1
        fi

        reap_dead
        HELD_PID="$(jq -r --arg key "$KEY" '.[$key].pid // empty' "$REGISTRY")"
        if [ -n "$HELD_PID" ]; then
            if [ "$HELD_PID" != "$CALLER_PID" ]; then
                echo "error: run $KEY is already held by live pid $HELD_PID" >&2
                exit 1
            fi

            BASE="$(jq -r --arg key "$KEY" '.[$key].base' "$REGISTRY")"
            STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            write_registry \
                '.[$key] = {base: $base, pid: $pid, ts: $ts}' \
                --arg key "$KEY" \
                --argjson base "$BASE" \
                --argjson pid "$CALLER_PID" \
                --arg ts "$STARTED"
            printf '%s\n' "$BASE"
            exit 0
        fi

        BASE=""
        for ((CANDIDATE = 8200; CANDIDATE <= 8990; CANDIDATE += 10)); do
            if reserved_block_overlaps "$CANDIDATE"; then
                continue
            fi
            if lease_block_overlaps "$CANDIDATE"; then
                continue
            fi
            if block_accepts_tcp "$CANDIDATE"; then
                continue
            fi
            BASE="$CANDIDATE"
            break
        done

        if [ -z "$BASE" ]; then
            echo "error: no free port block; tried candidate bases 8200-8990 (ports through 8995)" >&2
            exit 1
        fi

        STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        write_registry \
            '.[$key] = {base: $base, pid: $pid, ts: $ts}' \
            --arg key "$KEY" \
            --argjson base "$BASE" \
            --argjson pid "$CALLER_PID" \
            --arg ts "$STARTED"
        printf '%s\n' "$BASE"
        ;;
    release)
        write_registry 'del(.[$key])' --arg key "$KEY"
        ;;
    list)
        printf '%-36s %-6s %-8s %s\n' "RUN" "BASE" "PID" "STATUS"
        while IFS= read -r ENTRY; do
            KEY="$(jq -r '.key' <<<"$ENTRY")"
            BASE="$(jq -r '.value.base' <<<"$ENTRY")"
            HELD_PID="$(jq -r '.value.pid' <<<"$ENTRY")"
            if pid_alive "$HELD_PID"; then
                STATUS="alive"
            else
                STATUS="dead"
            fi
            printf '%-36s %-6s %-8s %s\n' "$KEY" "$BASE" "$HELD_PID" "$STATUS"
        done < <(jq -c 'to_entries | sort_by(.key)[]' "$REGISTRY")
        ;;
esac
