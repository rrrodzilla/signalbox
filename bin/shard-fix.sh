#!/usr/bin/env bash
# Per-shard fixer: bin/shard-fix.sh <worker-index>
# stdin = shard.fix.requested payload (shard.review.raw shape, REQUEST_CHANGES)
# stdout = shard.review.requested payload for the next round
#
# Headless Claude addresses the delta review's findings inside the shard's
# own worktree, commits the fix on the shard branch (signed), and re-emits
# the review request — same thread, round + 1. Worker-tagged like the
# reviewer so fixes for different shards run concurrently.
set -euo pipefail
# shellcheck source=_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/_env.sh"

ME="${1:?worker index}"
PAYLOAD="$(cat)"
[ "$(jq -r '.worker' <<<"$PAYLOAD")" = "$ME" ] || exit 0

STAGE_ID="$(jq -r '.stage' <<<"$PAYLOAD")"
SHARD_ID="$(jq -r '.current.shard' <<<"$PAYLOAD")"
BRANCH="$(jq -r '.current.branch' <<<"$PAYLOAD")"
ROUND="$(jq -r '.round' <<<"$PAYLOAD")"
REVIEW="$(jq -r '.review' <<<"$PAYLOAD")"
WT="$WT_BASE/${BRANCH#shard/}"

mkdir -p "$ROOT/logs"

PROMPT="You are the fix half of an automated per-shard review loop. Your scope
is ONE shard of a larger change, on its own git branch in this worktree.

## Reviewer feedback (round $ROUND)

$REVIEW

## Rules

- If .claude/docs/ARCHI-rules.md exists here, your changes must conform to it.
- Address every issue the reviewer raised, with minimal correct changes.
- Library code must not use unwrap or expect; use proper error handling or
  a graceful fallback.
- Only edit the files this shard owns per the review's scope (the files it created or changed).
- Do not refactor beyond the feedback. Do not add features.
- Do not run cargo, git, or any other command.
- Keep tests and doc comments accurate to the new behavior."

cd "$WT"
env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT \
    claude -p "$PROMPT" \
    --model opus \
    --permission-mode acceptEdits \
    >"$ROOT/logs/shard-fix-$STAGE_ID-$SHARD_ID-r$ROUND.log" 2>&1

if [ -n "$(git status --porcelain)" ]; then
    git add -A
    git commit -S -m "fix: $STAGE_ID/$SHARD_ID shard, address review round $ROUND" >&2
fi

jq -c 'del(.verdict) | .feedback = .review | del(.review) | .round += 1' <<<"$PAYLOAD"
