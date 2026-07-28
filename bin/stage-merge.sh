#!/usr/bin/env bash
# Fan-in merge: stdin = stage.done payload {stage, done, branches}.
# Before the first mutation, a pre-flight proves that every shard branch
# touched only its plan-declared files and that no two branches touched the
# same path. It then rebases each shard branch onto the integration tip,
# fast-forwards the integration branch, and removes the shard worktree — a
# single clean linear history, never a merge commit. Emits the ack that
# releases the stream-runner's next stage.
set -euo pipefail
# shellcheck source=_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/_env.sh"
# shellcheck source=_scope.sh
source "$(dirname "${BASH_SOURCE[0]}")/_scope.sh"

PAYLOAD="$(cat)"
STAGE_ID="$(jq -r '.stage' <<<"$PAYLOAD")"
# The run's git namespace, derived exactly as in plan-seed.sh and
# shard-worker.sh so this resolves the worktree shard-worker.sh created.
FEATURE="$(jq -r '.feature // "feature"' "$RUN_DIR/plan.json" 2>/dev/null || echo feature)"
export FEATURE

mapfile -t BRANCHES < <(jq -r '.branches[]' <<<"$PAYLOAD")
declare -a SHARD_IDS=()
declare -a DECLARED_LISTS=()
declare -a TOUCHED_LISTS=()
declare -a VIOLATION_LISTS=()
declare -a NAME_RESOLVED=()
declare -a DECLARATION_RESOLVED=()
declare -a TOUCHED_RESOLVED=()
declare -a VIOLATIONS_RESOLVED=()
declare -a OVERLAP_PATHS=()
declare -A PATH_COUNTS=()
declare -A PATH_BRANCHES=()
PREFLIGHT_FAILED=0

for INDEX in "${!BRANCHES[@]}"; do
    BRANCH="${BRANCHES[$INDEX]}"
    BRANCH_TAIL="${BRANCH##*/}"
    SHARD_IDS[$INDEX]=""
    DECLARED_LISTS[$INDEX]=""
    TOUCHED_LISTS[$INDEX]=""
    VIOLATION_LISTS[$INDEX]=""
    NAME_RESOLVED[$INDEX]=0
    DECLARATION_RESOLVED[$INDEX]=0
    TOUCHED_RESOLVED[$INDEX]=0
    VIOLATIONS_RESOLVED[$INDEX]=0

    if [[ "$BRANCH_TAIL" == "$STAGE_ID-"* ]]; then
        SHARD_IDS[$INDEX]="${BRANCH_TAIL#"$STAGE_ID-"}"
        NAME_RESOLVED[$INDEX]=1
        if DECLARED_LISTS[$INDEX]="$(
            shard_declared_files \
                "$RUN_DIR/plan.json" "$STAGE_ID" "${SHARD_IDS[$INDEX]}"
        )"; then
            DECLARATION_RESOLVED[$INDEX]=1
        else
            PREFLIGHT_FAILED=1
        fi
    else
        printf '[scope] branch %s does not have the required stage prefix %s-\n' \
            "$BRANCH" "$STAGE_ID" >&2
        PREFLIGHT_FAILED=1
    fi

    if TOUCHED_LISTS[$INDEX]="$(
        shard_touched_files "$ROOT" "$INT_BRANCH" "$BRANCH"
    )"; then
        TOUCHED_RESOLVED[$INDEX]=1
    else
        PREFLIGHT_FAILED=1
    fi

    if [ "${DECLARATION_RESOLVED[$INDEX]}" -eq 1 ] \
        && [ "${TOUCHED_RESOLVED[$INDEX]}" -eq 1 ]; then
        if VIOLATION_LISTS[$INDEX]="$(
            scope_violations \
                "${DECLARED_LISTS[$INDEX]}" "${TOUCHED_LISTS[$INDEX]}"
        )"; then
            VIOLATIONS_RESOLVED[$INDEX]=1
            if [ -n "${VIOLATION_LISTS[$INDEX]}" ]; then
                PREFLIGHT_FAILED=1
            fi
        else
            PREFLIGHT_FAILED=1
        fi
    fi
done

for INDEX in "${!BRANCHES[@]}"; do
    if [ "${TOUCHED_RESOLVED[$INDEX]}" -ne 1 ]; then
        continue
    fi

    BRANCH="${BRANCHES[$INDEX]}"
    BRANCH_SEEN_PATHS=()
    while IFS= read -r TOUCHED_PATH || [ -n "$TOUCHED_PATH" ]; do
        if [ -z "$TOUCHED_PATH" ]; then
            continue
        fi

        PATH_ALREADY_SEEN=0
        for SEEN_PATH in "${BRANCH_SEEN_PATHS[@]}"; do
            if [ "$TOUCHED_PATH" = "$SEEN_PATH" ]; then
                PATH_ALREADY_SEEN=1
                break
            fi
        done
        if [ "$PATH_ALREADY_SEEN" -eq 1 ]; then
            continue
        fi
        BRANCH_SEEN_PATHS+=("$TOUCHED_PATH")

        if [ -n "${PATH_COUNTS[$TOUCHED_PATH]+x}" ]; then
            PATH_COUNTS[$TOUCHED_PATH]=$((
                "${PATH_COUNTS[$TOUCHED_PATH]}" + 1
            ))
            PATH_BRANCHES[$TOUCHED_PATH]+=$'\n'"$BRANCH"
            if [ "${PATH_COUNTS[$TOUCHED_PATH]}" -eq 2 ]; then
                OVERLAP_PATHS+=("$TOUCHED_PATH")
                PREFLIGHT_FAILED=1
            fi
        else
            PATH_COUNTS[$TOUCHED_PATH]=1
            PATH_BRANCHES[$TOUCHED_PATH]="$BRANCH"
        fi
    done <<<"${TOUCHED_LISTS[$INDEX]}"
done

if [ "$PREFLIGHT_FAILED" -ne 0 ]; then
    printf '%s\n' \
        "Shard-scope failure: the per-shard review gate should have caught this before fan-in." >&2

    for INDEX in "${!BRANCHES[@]}"; do
        BRANCH="${BRANCHES[$INDEX]}"
        if [ "${VIOLATIONS_RESOLVED[$INDEX]}" -eq 1 ] \
            && [ -n "${VIOLATION_LISTS[$INDEX]}" ]; then
            printf '\nBranch: `%s`\n\n' "$BRANCH" >&2
            scope_report \
                "${SHARD_IDS[$INDEX]}" \
                "${DECLARED_LISTS[$INDEX]}" \
                "${VIOLATION_LISTS[$INDEX]}" >&2
        fi

        if [ "${NAME_RESOLVED[$INDEX]}" -ne 1 ] \
            || [ "${DECLARATION_RESOLVED[$INDEX]}" -ne 1 ] \
            || [ "${TOUCHED_RESOLVED[$INDEX]}" -ne 1 ] \
            || { [ "${DECLARATION_RESOLVED[$INDEX]}" -eq 1 ] \
                && [ "${TOUCHED_RESOLVED[$INDEX]}" -eq 1 ] \
                && [ "${VIOLATIONS_RESOLVED[$INDEX]}" -ne 1 ]; }; then
            printf '\n## Shard scope unresolved\n\n' >&2
            printf 'Branch: `%s`\n\n' "$BRANCH" >&2
            if [ "${NAME_RESOLVED[$INDEX]}" -eq 1 ]; then
                printf 'Shard: `%s`\n\n' "${SHARD_IDS[$INDEX]}" >&2
            else
                printf 'Shard: unavailable (the branch name does not start with `%s-`).\n\n' \
                    "$STAGE_ID" >&2
            fi

            if [ "${DECLARATION_RESOLVED[$INDEX]}" -eq 1 ]; then
                printf 'Declared files:\n\n' >&2
                while IFS= read -r DECLARED_PATH || [ -n "$DECLARED_PATH" ]; do
                    [ -z "$DECLARED_PATH" ] \
                        || printf -- '- %s\n' "$DECLARED_PATH" >&2
                done <<<"${DECLARED_LISTS[$INDEX]}"
                printf '\n' >&2
            else
                printf '%s\n\n' \
                    'Declared files: unavailable (the plan declaration could not be resolved).' >&2
            fi

            if [ "${TOUCHED_RESOLVED[$INDEX]}" -ne 1 ]; then
                printf '%s\n' \
                    'Out-of-lane paths: unavailable (the branch diff could not be resolved).' >&2
            elif [ "${DECLARATION_RESOLVED[$INDEX]}" -ne 1 ]; then
                printf '%s\n' \
                    'Out-of-lane paths: unavailable (the declaration could not be resolved).' >&2
            else
                printf '%s\n' \
                    'Out-of-lane paths: unavailable (scope comparison failed).' >&2
            fi
        fi
    done

    if [ "${#OVERLAP_PATHS[@]}" -gt 0 ]; then
        printf '\n## Cross-branch shard overlap\n\n' >&2
        for OVERLAP_PATH in "${OVERLAP_PATHS[@]}"; do
            printf -- '- %s\n' "$OVERLAP_PATH" >&2
            while IFS= read -r BRANCH || [ -n "$BRANCH" ]; do
                [ -z "$BRANCH" ] || printf '  - %s\n' "$BRANCH" >&2
            done <<<"${PATH_BRANCHES[$OVERLAP_PATH]}"
        done
    fi
    exit 1
fi

mkdir -p "$ROOT/state"
# Keep this lock scoped to each worktree command: concurrent runs share one
# repository's worktree admin state.
WORKTREE_LOCK="$ROOT/state/worktree.lock"

for BRANCH in $(jq -r '.branches[]' <<<"$PAYLOAD"); do
    WT="$WT_BASE/$FEATURE-${BRANCH##*/}"
    {
        git -C "$WT" rebase "$INT_BRANCH"
        git -C "$INT_WT" merge --ff-only "$BRANCH"
        ( flock -x 9; git -C "$ROOT" worktree remove "$WT" ) 9>"$WORKTREE_LOCK"
        # -d from the integration worktree: merged-ness is judged against the
        # branch we merged into, not whatever the primary checkout has as HEAD.
        git -C "$INT_WT" branch -d "$BRANCH"
    } >&2
done

jq -c --arg stage "$STAGE_ID" \
    '{stage: $stage, merged: .branches, tip: ""}' <<<"$PAYLOAD" |
    jq -c --arg tip "$(git -C "$INT_WT" rev-parse --short HEAD)" '.tip = $tip'
