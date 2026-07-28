#!/usr/bin/env bash
# Fixer handler: stdin = fix.requested payload
#   {verdict, review, round, workdir, thread_id, fix_session_id?}
# stdout = review.requested payload for the next round
#   {workdir, round+1, feedback, thread_id, fix_session_id, correlation_id,
#    provenance}
#
# Runs headless Claude in $workdir to address the reviewer's feedback, then
# re-emits a review request carrying that feedback so the re-review can
# verify each point was addressed. The topic cycle IS the review loop.
#
# Round 1 (no fix_session_id): a session id is minted and pinned with
# --session-id. Rounds 2+ resume THAT session, so the fixer sees its own
# earlier rounds exactly as the reviewer sees its own prior findings via
# `codex exec resume` (bin/review.sh). Without that symmetry the fixer
# re-derives a local patch every round with no memory of having built the
# thing it is patching, and a mechanism it invented in round 1 grows an
# exception per round until the round guard escalates it (signalbox #39).
# The id travels in the event payload, not a state file; bin/review.sh
# passes it through untouched.
set -euo pipefail
# shellcheck source=_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/_env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/_provenance.sh"
source "$(dirname "${BASH_SOURCE[0]}")/_lang.sh"

PAYLOAD="$(cat)"

WORKDIR="$(jq -r '.workdir' <<<"$PAYLOAD")"
# The fix target's own directory decides the wording; the harness installs into any repository.
lang_profile "$(detect_language "$WORKDIR")"
ROUND="$(jq -r '.round' <<<"$PAYLOAD")"
REVIEW="$(jq -r '.review' <<<"$PAYLOAD")"
THREAD_ID="$(jq -r '.thread_id // ""' <<<"$PAYLOAD")"
FIX_SESSION_ID="$(jq -r '.fix_session_id // ""' <<<"$PAYLOAD")"
CID="$(jq -r '.correlation_id // ""' <<<"$PAYLOAD")"

mkdir -p "$RUN_DIR/logs"

new_session_id() {
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen
    else
        cat /proc/sys/kernel/random/uuid
    fi
}

INTENT=""
if [ -f "$RUN_DIR/plan.json" ]; then
    INTENT="## Feature intent (from the validated plan — authoritative)

Issue #$(jq -r '.issue' "$RUN_DIR/plan.json"): feature \`$(jq -r '.feature' "$RUN_DIR/plan.json")\`

$(jq -r '.scope_notes // "(no scope notes)"' "$RUN_DIR/plan.json")

"
fi

RULES="## Rules

- The feature intent above (if present) OUTRANKS the reviewer. If a feedback
  item asks you to undo, restore, deprecate, or version-gate something the
  plan declares deliberate, do NOT implement that item — leave the code as
  the plan intends and state the conflict plainly at the end of your reply.
  Silently reverting the feature to satisfy a reviewer is the worst outcome.

- If addressing the feedback correctly would require a mechanism the plan does
  NOT scope — a new ordering primitive, protocol, or state machine — do not
  build it. Make no change, and end your reply with a line reading
  SCOPE-CONFLICT followed by one paragraph naming the design decision that is
  required and why no local fix exists. Raising a design question is a correct
  outcome; growing an unplanned mechanism one exception at a time is not.

- If .claude/docs/ARCHI-rules.md exists here, your changes must conform to it.
- Address every issue the reviewer raised, with minimal correct changes.
- $LANG_FIX_RULE
- Do not refactor beyond what the feedback requires. Do not add features.
- $LANG_EDIT_SCOPE Do not run build, test, git, or any other command.
- Keep doc comments accurate to the new behavior."

PROMPT="You are the fix half of an automated review loop on $LANG_SUBJECT.

$INTENT## Reviewer feedback (round $ROUND)

$REVIEW

$RULES"

# Resumed rounds already hold the intent, the earlier feedback, and the fixer's
# own earlier edits, so the continuation prompt carries only what is new — plus
# the one instruction that memory makes actionable: recognize your own work.
RESUME_PROMPT="## Reviewer feedback (round $ROUND)

$REVIEW

This is the same review loop, continued — the earlier rounds in this session
are yours. Before editing, check whether this finding sits in code YOU added
in an earlier round. If it does, say so, and judge whether that earlier
approach is sound instead of patching it again: a mechanism that needs a new
exception every round is the wrong mechanism, and saying so is worth more than
another exception.

The rules from the first round still apply in full."

LOG="$RUN_DIR/logs/fix-round-$ROUND.log"

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

cd "$WORKDIR"
if [ -z "$FIX_SESSION_ID" ] \
    || ! run_fixer "$RESUME_PROMPT" --resume "$FIX_SESSION_ID"; then
    # No session yet (round 1), or the resume failed because the session was
    # lost or expired. Either way start a fresh one carrying the full prompt:
    # a dead session id must degrade the loop to today's memoryless behavior,
    # never wedge it.
    if [ -n "$FIX_SESSION_ID" ]; then
        echo "[fix] round $ROUND: could not resume session $FIX_SESSION_ID — starting a fresh one" >&2
    fi
    FIX_SESSION_ID="$(new_session_id)"
    run_fixer "$PROMPT" --session-id "$FIX_SESSION_ID"
fi
stamp_provenance "logs/fix-round-$ROUND.log" claude opus ""

# Target mode ($WORKDIR = the integration worktree): fix edits must become
# commits on the feature branch — uncommitted worktree state is invisible to
# the merge and silently dies with the worktree.
if [ "$(git rev-parse --show-toplevel 2>/dev/null || true)" = "$INT_WT" ] \
    && [ -n "$(git status --porcelain)" ]; then
    git add -A
    git commit -S -m "fix: address review round $ROUND feedback" >&2
fi

NEXT=$((ROUND + 1))
PROVENANCE="$(provenance_object claude opus "")"
jq -n \
    --arg workdir "$WORKDIR" \
    --argjson round "$NEXT" \
    --arg feedback "$REVIEW" \
    --arg thread_id "$THREAD_ID" \
    --arg fix_session_id "$FIX_SESSION_ID" \
    --arg cid "$CID" \
    --argjson provenance "$PROVENANCE" \
    '{workdir: $workdir, round: $round, feedback: $feedback, thread_id: $thread_id, fix_session_id: $fix_session_id, correlation_id: $cid, provenance: $provenance}'
