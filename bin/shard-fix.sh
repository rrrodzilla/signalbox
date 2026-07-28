#!/usr/bin/env bash
# Per-shard fixer: bin/shard-fix.sh <worker-index>
# stdin = shard.fix.requested payload (shard.review.raw shape, REQUEST_CHANGES)
# stdout = shard.review.requested payload for the next round
#   (input transformed with fixer provenance)
#
# Headless Claude addresses the delta review's findings inside the shard's
# own worktree, commits the fix on the shard branch (signed), and re-emits
# the review request — same thread, round + 1. Worker-tagged like the
# reviewer so fixes for different shards run concurrently.
#
# Rounds 2+ resume the fixer's own session (fix_session_id, minted here in
# round 1) so it can recognize code it wrote in an earlier round instead of
# patching it blind — the same symmetry with the resumed reviewer thread that
# bin/fix.sh has for the integration loop (signalbox #39). The id rides in the
# per-shard payload, so concurrent shards keep separate sessions.
set -euo pipefail
# shellcheck source=_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/_env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/_provenance.sh"
source "$(dirname "${BASH_SOURCE[0]}")/_lang.sh"

ME="${1:?worker index}"
PAYLOAD="$(cat)"
[ "$(jq -r '.worker' <<<"$PAYLOAD")" = "$ME" ] || exit 0

STAGE_ID="$(jq -r '.stage' <<<"$PAYLOAD")"
SHARD_ID="$(jq -r '.current.shard' <<<"$PAYLOAD")"
BRANCH="$(jq -r '.current.branch' <<<"$PAYLOAD")"
ROUND="$(jq -r '.round' <<<"$PAYLOAD")"
REVIEW="$(jq -r '.review' <<<"$PAYLOAD")"
FIX_SESSION_ID="$(jq -r '.fix_session_id // ""' <<<"$PAYLOAD")"
# The run's git namespace, derived exactly as in shard-worker.sh and
# stage-merge.sh so this resolves the worktree shard-worker.sh created:
# branch shard/<feature>/<stage>-<shard> lives in <wt-base>/<feature>-<stage>-<shard>.
FEATURE="$(jq -r '.feature // "feature"' "$RUN_DIR/plan.json" 2>/dev/null || echo feature)"
export FEATURE
WT="$WT_BASE/$FEATURE-${BRANCH##*/}"
lang_profile "$(detect_language "$WT")"

mkdir -p "$RUN_DIR/logs"

new_session_id() {
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen
    else
        cat /proc/sys/kernel/random/uuid
    fi
}

PROMPT="You are the fix half of an automated per-shard review loop. Your scope
is ONE shard of a larger change, on its own git branch in this worktree.

## Reviewer feedback (round $ROUND)

$REVIEW

## Rules

- If .claude/docs/ARCHI-rules.md exists here, your changes must conform to it.
- Address every issue the reviewer raised, with minimal correct changes.
- $LANG_FIX_RULE
- If addressing the feedback correctly would require a mechanism this shard's
  scope does not cover, do not build it: make no change and end your reply
  with a line reading SCOPE-CONFLICT followed by one paragraph naming the
  decision required. Raising it is correct; growing an unplanned mechanism one
  exception at a time is not.
- Only edit the files this shard owns per the review's scope (the files it created or changed).
- Do not refactor beyond the feedback. Do not add features.
- Do not run build, test, git, or any other command.
- Keep tests and doc comments accurate to the new behavior."

RESUME_PROMPT="## Reviewer feedback (round $ROUND)

$REVIEW

This is the same per-shard review loop, continued — the earlier rounds in this
session are yours. Before editing, check whether this finding sits in code YOU
added in an earlier round; if it does, say so, and judge whether that approach
is sound instead of patching it again. The rules from the first round still
apply in full."

LOG="$RUN_DIR/logs/shard-fix-$STAGE_ID-$SHARD_ID-r$ROUND.log"

run_fixer() {
    local FIXER_PROMPT="$1"
    shift
    env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT \
        claude -p "$FIXER_PROMPT" \
        --model opus \
        --permission-mode acceptEdits \
        "$@" \
        >"$LOG" 2>&1
}

cd "$WT"
if [ -z "$FIX_SESSION_ID" ] \
    || ! run_fixer "$RESUME_PROMPT" --resume "$FIX_SESSION_ID"; then
    # Round 1, or a session that no longer resumes: fall back to a fresh one
    # with the full prompt rather than stalling this shard's loop.
    if [ -n "$FIX_SESSION_ID" ]; then
        echo "[shard-fix] $STAGE_ID/$SHARD_ID round $ROUND: could not resume session $FIX_SESSION_ID — starting a fresh one" >&2
    fi
    FIX_SESSION_ID="$(new_session_id)"
    run_fixer "$PROMPT" --session-id "$FIX_SESSION_ID"
fi
stamp_provenance "logs/shard-fix-$STAGE_ID-$SHARD_ID-r$ROUND.log" claude opus ""

if [ -n "$(git status --porcelain)" ]; then
    git add -A
    git commit -S -m "fix: $STAGE_ID/$SHARD_ID shard, address review round $ROUND" >&2
fi

PROVENANCE="$(provenance_object claude opus "")"
jq -c \
    --argjson provenance "$PROVENANCE" \
    --arg fix_session_id "$FIX_SESSION_ID" \
    'del(.verdict) | .feedback = .review | del(.review) | .round += 1
     | . + {provenance: $provenance, fix_session_id: $fix_session_id}' \
    <<<"$PAYLOAD"
