#!/usr/bin/env bash
# Per-shard delta reviewer: bin/shard-review.sh <worker-index>
# stdin = shard.review.requested payload
#   {stage, expected, worker, pending, done, branches,
#    current: {shard, branch}, round, thread_id, feedback}
# stdout = shard.review.raw payload
#   model path: input + {verdict, review, thread_id, provenance}
#   scope-violation path: input + {
#     verdict: "REQUEST_CHANGES", review, thread_id: <inbound unchanged>}
#
# Before invoking a model, rejects a branch whose integration-tip delta touches
# any path outside the shard's plan-declared files. That short circuit writes
# the scope report and offending diff to the normal round log, preserves the
# inbound thread_id and provenance, and invokes no model. Clean deltas are
# reviewed with the same thread continuity as the code-review loop: round 1
# starts a fresh Codex thread, rounds 2+ resume it. Worker-tagged so the two
# reviewer instances split the load exactly like the workers do (the
# non-matching instance exits silently and publishes nothing).
set -euo pipefail
# shellcheck source=_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/_env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/_provenance.sh"
source "$(dirname "${BASH_SOURCE[0]}")/_lang.sh"
source "$(dirname "${BASH_SOURCE[0]}")/_scope.sh"

ME="${1:?worker index}"
PAYLOAD="$(cat)"
[ "$(jq -r '.worker' <<<"$PAYLOAD")" = "$ME" ] || exit 0

STAGE_ID="$(jq -r '.stage' <<<"$PAYLOAD")"
SHARD_ID="$(jq -r '.current.shard' <<<"$PAYLOAD")"
BRANCH="$(jq -r '.current.branch' <<<"$PAYLOAD")"
ROUND="$(jq -r '.round' <<<"$PAYLOAD")"
THREAD_ID="$(jq -r '.thread_id // ""' <<<"$PAYLOAD")"
CODEX_MODEL_RESOLVED="${CODEX_MODEL:-gpt-5.6-sol}"
CODEX_EFFORT_RESOLVED="${CODEX_EFFORT:-high}"
# The run's git namespace, derived exactly as in shard-worker.sh and
# stage-merge.sh so this resolves the worktree shard-worker.sh created:
# branch shard/<feature>/<stage>-<shard> lives in <wt-base>/<feature>-<stage>-<shard>.
FEATURE="$(jq -r '.feature // "feature"' "$RUN_DIR/plan.json" 2>/dev/null || echo feature)"
export FEATURE
WT="$WT_BASE/$FEATURE-${BRANCH##*/}"
lang_profile "$(detect_language "$WT")"

mkdir -p "$RUN_DIR/logs"
LAST="$RUN_DIR/logs/shard-review-$STAGE_ID-$SHARD_ID-r$ROUND.md"
EVENTS="$RUN_DIR/logs/shard-review-$STAGE_ID-$SHARD_ID-r$ROUND.jsonl"

if ! DECLARED="$(
    shard_declared_files "$RUN_DIR/plan.json" "$STAGE_ID" "$SHARD_ID"
)"; then
    printf '%s\n' \
        "[shard-review] cannot resolve declared files for stage $STAGE_ID shard $SHARD_ID" >&2
    exit 1
fi

if ! TOUCHED="$(shard_touched_files "$WT" "$INT_BRANCH" HEAD)"; then
    printf '%s\n' \
        "[shard-review] cannot resolve touched files for stage $STAGE_ID shard $SHARD_ID" >&2
    exit 1
fi

if ! VIOLATIONS="$(scope_violations "$DECLARED" "$TOUCHED")"; then
    printf '%s\n' \
        "[shard-review] cannot resolve scope violations for stage $STAGE_ID shard $SHARD_ID" >&2
    exit 1
fi

if [ -n "$VIOLATIONS" ]; then
    # The lists carry escaped records so a path containing a newline stays one
    # record; Git needs the raw bytes back, hence the NUL-delimited decode.
    mapfile -d '' -t VIOLATING_PATHS < <(
        if scope_decode_paths "$VIOLATIONS"; then
            printf '0\0'
        else
            printf '%s\0' "$?"
        fi
    )
    DECODE_STATUS_INDEX=$((${#VIOLATING_PATHS[@]} - 1))
    DECODE_STATUS="${VIOLATING_PATHS[$DECODE_STATUS_INDEX]}"
    unset 'VIOLATING_PATHS[DECODE_STATUS_INDEX]'

    if [ "$DECODE_STATUS" -ne 0 ]; then
        printf '%s\n' \
            "[shard-review] cannot decode violating paths for stage $STAGE_ID shard $SHARD_ID" >&2
        exit 1
    fi

    if ! REVIEW="$(scope_report "$SHARD_ID" "$DECLARED" "$VIOLATIONS")"; then
        printf '%s\n' \
            "[shard-review] cannot build scope report for stage $STAGE_ID shard $SHARD_ID" >&2
        exit 1
    fi
    # --literal-pathspecs: violating paths are filenames, not patterns, so a
    # valid name containing *, ?, [] or : must not widen or fail the diff.
    if ! OFFENDING_DIFF="$(
        git -C "$WT" --literal-pathspecs diff "$INT_BRANCH"...HEAD \
            -- "${VIOLATING_PATHS[@]}"
    )"; then
        printf '%s\n' \
            "[shard-review] cannot render offending diff for stage $STAGE_ID shard $SHARD_ID" >&2
        exit 1
    fi
    REVIEW+=$'\n\n```diff\n'
    REVIEW+="$OFFENDING_DIFF"
    REVIEW+=$'\n```\n'

    if ! printf '%s' "$REVIEW" >"$LAST"; then
        printf '%s\n' \
            "[shard-review] cannot write scope review for stage $STAGE_ID shard $SHARD_ID round $ROUND" >&2
        exit 1
    fi

    VIOLATION_SUMMARY="${VIOLATIONS//$'\n'/, }"
    printf '%s\n' \
        "[shard-review] stage $STAGE_ID shard $SHARD_ID round $ROUND scope violation: $VIOLATION_SUMMARY" >&2

    jq -c \
        --arg verdict "REQUEST_CHANGES" \
        --rawfile review "$LAST" \
        '. + {verdict: $verdict, review: $review, thread_id: .thread_id}' \
        <<<"$PAYLOAD"
    exit 0
fi

DIFF="$(git -C "$WT" diff "$INT_BRANCH"...HEAD)"

cd "$WT"

if [ -z "$THREAD_ID" ]; then
    PROMPT="$(render_prompt "$ROOT/prompts/shard-review.md")

## Diff under review ($BRANCH vs $INT_BRANCH)

\`\`\`diff
$DIFF
\`\`\`"

    codex exec \
        --json \
        --skip-git-repo-check \
        --sandbox read-only \
        --color never \
        -c model="$CODEX_MODEL_RESOLVED" \
        -c model_reasoning_effort="$CODEX_EFFORT_RESOLVED" \
        -o "$LAST" \
        "$PROMPT" \
        </dev/null \
        >"$EVENTS" \
        2>"$EVENTS.stderr"

    THREAD_ID="$(jq -r 'select(.type == "thread.started") | .thread_id' "$EVENTS" 2>/dev/null | head -1)"
    [ "$THREAD_ID" != "null" ] || THREAD_ID=""
else
    # Resume: the thread already holds the prior findings, so the prompt only
    # asks to verify. --sandbox / --color are not accepted here (inherited).
    PROMPT="$(render_prompt "$ROOT/prompts/shard-re-review.md")

## Current diff after the fix ($BRANCH vs $INT_BRANCH)

\`\`\`diff
$DIFF
\`\`\`"

    codex exec resume "$THREAD_ID" \
        --json \
        --skip-git-repo-check \
        -c model="$CODEX_MODEL_RESOLVED" \
        -c model_reasoning_effort="$CODEX_EFFORT_RESOLVED" \
        -o "$LAST" \
        "$PROMPT" \
        </dev/null \
        >"$EVENTS" \
        2>"$EVENTS.stderr"
fi

stamp_provenance "logs/shard-review-$STAGE_ID-$SHARD_ID-r$ROUND.md" codex "$CODEX_MODEL_RESOLVED" "$CODEX_EFFORT_RESOLVED"
PROVENANCE="$(provenance_object codex "$CODEX_MODEL_RESOLVED" "$CODEX_EFFORT_RESOLVED")"

VERDICT="$(grep -oE '^(APPROVED|REQUEST_CHANGES)[[:space:]]*$' "$LAST" | tail -1 | tr -d '[:space:]' || true)"
[ -n "$VERDICT" ] || VERDICT="UNKNOWN"

jq -c \
    --arg verdict "$VERDICT" \
    --rawfile review "$LAST" \
    --arg thread_id "$THREAD_ID" \
    --argjson provenance "$PROVENANCE" \
    '. + {verdict: $verdict, review: $review, thread_id: $thread_id, provenance: $provenance}' <<<"$PAYLOAD"
