# Shard file-scope helpers. Sourced, not executed; this file does not change
# shell options and does not depend on bin/_env.sh.
#
# Functions:
#   shard_declared_files <plan-json-path> <stage-id> <shard-id>
#     Print the shard's declared files, one per line in declared order. Return
#     64 unless given exactly three arguments, 1 with a `[scope]` diagnostic
#     when the plan or declaration cannot be validated or the list cannot be
#     written, and 0 otherwise. Validation failures never print a partial file
#     list.
#   shard_touched_files <git-dir> <base-ref> <head-ref>
#     Print paths changed on <head-ref> since its merge base with <base-ref>,
#     one per line. Renames are not detected, so a renamed file is reported as
#     both its pre-image and its post-image path. Return 64 unless given
#     exactly three arguments, 1 with a `[scope]` diagnostic when Git fails, a
#     path contains a newline, or the list cannot be written, and 0 otherwise.
#     A successful diff with no changes prints nothing.
#   scope_violations <declared-newline-list> <touched-newline-list>
#     Print each unique, nonempty touched path absent from the nonempty
#     declared paths, preserving touched order. Return 64 unless given exactly
#     two arguments, 1 with a `[scope]` diagnostic when the list cannot be
#     written, and 0 otherwise, including when no violation exists.
#   scope_report <shard-id> <declared-newline-list> <violations-newline-list>
#     Print a Markdown shard-scope violation report. Return 64 unless given
#     exactly three arguments, 1 with a `[scope]` diagnostic when the report
#     cannot be written, and 0 otherwise.
# shellcheck shell=bash

shard_declared_files() {
    if [ "$#" -ne 3 ]; then
        return 64
    fi

    local SCOPE_PLAN_PATH="$1"
    local SCOPE_STAGE_ID="$2"
    local SCOPE_SHARD_ID="$3"
    local SCOPE_DECLARED=""

    if [ ! -f "$SCOPE_PLAN_PATH" ] || [ ! -r "$SCOPE_PLAN_PATH" ]; then
        printf '%s\n' \
            "[scope] plan file is missing or unreadable: $SCOPE_PLAN_PATH" >&2
        return 1
    fi

    if ! SCOPE_DECLARED="$(
        jq -er \
            --arg stage "$SCOPE_STAGE_ID" \
            --arg shard "$SCOPE_SHARD_ID" \
            '
                def scope_fail($message): error($message);

                if (.stages | type) != "array" then
                    scope_fail("stages is not an array")
                else
                    .
                end
                | ([.stages[] | select(.id == $stage)] | first)
                | if . == null then
                    scope_fail("stage was not found")
                elif (.shards | type) != "array" then
                    scope_fail("stage shards is not an array")
                else
                    .
                end
                | ([.shards[] | select(.id == $shard)] | first)
                | if . == null then
                    scope_fail("shard was not found")
                elif (.files | type) != "array" or (.files | length) == 0 then
                    scope_fail("shard files is not a nonempty array")
                elif any(.files[]; type != "string"
                    or length == 0
                    or contains("\n")
                    or contains("\u0000")) then
                    scope_fail("shard files contains an invalid path")
                else
                    .files[]
                end
            ' \
            "$SCOPE_PLAN_PATH" 2>/dev/null
    )"; then
        printf '%s\n' \
            "[scope] cannot determine files for stage $SCOPE_STAGE_ID shard $SCOPE_SHARD_ID from $SCOPE_PLAN_PATH" >&2
        return 1
    fi

    if ! printf '%s\n' "$SCOPE_DECLARED"; then
        printf '%s\n' \
            "[scope] cannot write the declared file list for stage $SCOPE_STAGE_ID shard $SCOPE_SHARD_ID" >&2
        return 1
    fi
    return 0
}

shard_touched_files() {
    if [ "$#" -ne 3 ]; then
        return 64
    fi

    local SCOPE_GIT_DIR="$1"
    local SCOPE_BASE_REF="$2"
    local SCOPE_HEAD_REF="$3"
    local SCOPE_DIFF_STATUS=""
    local SCOPE_STATUS_INDEX=0
    local SCOPE_PATH=""
    local -a SCOPE_DIFF_ENTRIES=()

    mapfile -d '' -t SCOPE_DIFF_ENTRIES < <(
        if git -C "$SCOPE_GIT_DIR" diff --name-only --no-renames -z \
            "$SCOPE_BASE_REF...$SCOPE_HEAD_REF" -- 2>/dev/null; then
            printf '0\0'
        else
            printf '%s\0' "$?"
        fi
    )

    SCOPE_STATUS_INDEX=$((${#SCOPE_DIFF_ENTRIES[@]} - 1))
    SCOPE_DIFF_STATUS="${SCOPE_DIFF_ENTRIES[$SCOPE_STATUS_INDEX]}"
    unset 'SCOPE_DIFF_ENTRIES[SCOPE_STATUS_INDEX]'

    if [ "$SCOPE_DIFF_STATUS" -ne 0 ]; then
        printf '%s\n' \
            "[scope] git diff failed in $SCOPE_GIT_DIR for $SCOPE_BASE_REF...$SCOPE_HEAD_REF" >&2
        return 1
    fi

    for SCOPE_PATH in "${SCOPE_DIFF_ENTRIES[@]}"; do
        if [[ "$SCOPE_PATH" == *$'\n'* ]]; then
            printf '%s\n' \
                "[scope] git diff contains a path with a newline" >&2
            return 1
        fi
    done

    for SCOPE_PATH in "${SCOPE_DIFF_ENTRIES[@]}"; do
        if ! printf '%s\n' "$SCOPE_PATH"; then
            printf '%s\n' \
                "[scope] cannot write the touched file list for $SCOPE_BASE_REF...$SCOPE_HEAD_REF" >&2
            return 1
        fi
    done
    return 0
}

scope_violations() {
    if [ "$#" -ne 2 ]; then
        return 64
    fi

    local SCOPE_DECLARED_LIST="$1"
    local SCOPE_TOUCHED_LIST="$2"
    local SCOPE_PATH=""
    local SCOPE_CANDIDATE=""
    local SCOPE_ALREADY_SEEN=0
    local SCOPE_IS_DECLARED=0
    local -a SCOPE_DECLARED_PATHS=()
    local -a SCOPE_SEEN_TOUCHED_PATHS=()

    while IFS= read -r SCOPE_PATH || [ -n "$SCOPE_PATH" ]; do
        if [ -n "$SCOPE_PATH" ]; then
            SCOPE_DECLARED_PATHS+=("$SCOPE_PATH")
        fi
    done <<<"$SCOPE_DECLARED_LIST"

    while IFS= read -r SCOPE_PATH || [ -n "$SCOPE_PATH" ]; do
        if [ -z "$SCOPE_PATH" ]; then
            continue
        fi

        SCOPE_ALREADY_SEEN=0
        for SCOPE_CANDIDATE in "${SCOPE_SEEN_TOUCHED_PATHS[@]}"; do
            if [ "$SCOPE_PATH" = "$SCOPE_CANDIDATE" ]; then
                SCOPE_ALREADY_SEEN=1
                break
            fi
        done
        if [ "$SCOPE_ALREADY_SEEN" -eq 1 ]; then
            continue
        fi
        SCOPE_SEEN_TOUCHED_PATHS+=("$SCOPE_PATH")

        SCOPE_IS_DECLARED=0
        for SCOPE_CANDIDATE in "${SCOPE_DECLARED_PATHS[@]}"; do
            if [ "$SCOPE_PATH" = "$SCOPE_CANDIDATE" ]; then
                SCOPE_IS_DECLARED=1
                break
            fi
        done
        if [ "$SCOPE_IS_DECLARED" -eq 0 ] && ! printf '%s\n' "$SCOPE_PATH"; then
            printf '%s\n' \
                "[scope] cannot write the violation list" >&2
            return 1
        fi
    done <<<"$SCOPE_TOUCHED_LIST"
    return 0
}

scope_report() {
    if [ "$#" -ne 3 ]; then
        return 64
    fi

    local SCOPE_SHARD_ID="$1"
    local SCOPE_DECLARED_LIST="$2"
    local SCOPE_VIOLATIONS_LIST="$3"
    local SCOPE_PATH=""
    local SCOPE_TEXT=""

    SCOPE_TEXT="## Shard scope violation"$'\n\n'
    SCOPE_TEXT+="Shard \`$SCOPE_SHARD_ID\` exceeded its declared file scope."$'\n\n'
    SCOPE_TEXT+="These are the only files this shard may change:"$'\n\n'
    while IFS= read -r SCOPE_PATH || [ -n "$SCOPE_PATH" ]; do
        if [ -n "$SCOPE_PATH" ]; then
            SCOPE_TEXT+="- $SCOPE_PATH"$'\n'
        fi
    done <<<"$SCOPE_DECLARED_LIST"
    SCOPE_TEXT+=$'\n'"The branch also changed files this shard does not own:"$'\n\n'
    while IFS= read -r SCOPE_PATH || [ -n "$SCOPE_PATH" ]; do
        if [ -n "$SCOPE_PATH" ]; then
            SCOPE_TEXT+="- $SCOPE_PATH"$'\n'
        fi
    done <<<"$SCOPE_VIOLATIONS_LIST"
    SCOPE_TEXT+=$'\n'"A file this shard does not own belongs to a concurrent shard in the same stage and collides at the fan-in merge. Each unowned file must be restored to its state at the integration tip and left out of this shard entirely. If the change genuinely cannot be made without that file, the correct response is to make no edit and end the reply with a line reading SCOPE-CONFLICT plus one paragraph naming the decision required."$'\n'

    if ! printf '%s' "$SCOPE_TEXT"; then
        printf '%s\n' \
            "[scope] cannot write the scope report for shard $SCOPE_SHARD_ID" >&2
        return 1
    fi
    return 0
}
