#!/usr/bin/env bash
# Vault docs syncer: stdin = approval.granted payload
# {feature, workdir, round, verdict, review, thread_id, correlation_id,
#  action, readiness, floor, rationale, decision}.
# stdout = docs.synced payload (the same object plus
# {docs_sync: {status, updated, unchanged, path}}).
#
# The syncer sits before the promotion sink so every reviewed feature records
# either a mechanically verified vault update or an explicit no-op/error.
# No terminal path suppresses the downstream event.
set -euo pipefail
# shellcheck source=_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/_env.sh"

PAYLOAD="$(cat)"
CID="$(jq -r '.correlation_id // ""' <<<"$PAYLOAD")"
WORKDIR="$(jq -r '.workdir // empty' <<<"$PAYLOAD")"
[ -n "$WORKDIR" ] || WORKDIR="$INT_WT"
FEATURE="$(jq -r '.feature // empty' <<<"$PAYLOAD")"
[ -n "$FEATURE" ] || FEATURE="$(jq -r '.feature' "$ROOT/plan.json" 2>/dev/null || true)"
ISSUE="$(jq -r '.issue // empty' "$ROOT/plan.json" 2>/dev/null || true)"

VAULT="$(readlink -f "$REPO_ROOT/.claude/docs")"
STATE_PATH="$ROOT/state/docs-sync.json"
DOCS=("ARCHI.md" "ARCHI-rules.md" "TESTING.md")
UPDATED=()
UNCHANGED=()

mkdir -p "$ROOT/state" "$ROOT/logs"

finish() {
    local STATUS="$1"
    local NOTE="$2"
    local UPDATED_JSON
    local UNCHANGED_JSON
    local ISSUE_JSON="null"

    UPDATED_JSON="$(jq -nc --args '$ARGS.positional' "${UPDATED[@]}")"
    UNCHANGED_JSON="$(jq -nc --args '$ARGS.positional' "${UNCHANGED[@]}")"
    if [[ "$ISSUE" =~ ^[0-9]+$ ]]; then
        ISSUE_JSON="$ISSUE"
    fi

    jq -n \
        --argjson updated "$UPDATED_JSON" \
        --argjson unchanged "$UNCHANGED_JSON" \
        --arg status "$STATUS" \
        --arg note "$NOTE" \
        --arg vault "$VAULT" \
        --arg feature "$FEATURE" \
        --argjson issue "$ISSUE_JSON" \
        --arg cid "$CID" \
        '{
            updated: $updated,
            unchanged: $unchanged,
            status: $status,
            note: $note,
            vault: $vault,
            feature: $feature,
            issue: $issue,
            correlation_id: $cid,
            ts: (now | todate)
        }' >"$STATE_PATH"

    jq -c \
        --arg status "$STATUS" \
        --argjson updated "$UPDATED_JSON" \
        --argjson unchanged "$UNCHANGED_JSON" \
        --arg path "$STATE_PATH" \
        '. + {docs_sync: {
            status: $status,
            updated: $updated,
            unchanged: $unchanged,
            path: $path
        }}' <<<"$PAYLOAD"
    exit 0
}

if [ ! -d "$VAULT" ]; then
    UNCHANGED=("${DOCS[@]}")
    finish "ERROR" "vault not found at resolved path: $VAULT"
fi

CHANGED_FILES="$(git -C "$WORKDIR" diff --name-only "$BASE_BRANCH"...HEAD || true)"
DIFF_STAT="$(git -C "$WORKDIR" diff --stat "$BASE_BRANCH"...HEAD || true)"

if [ -z "$CHANGED_FILES" ]; then
    UNCHANGED=("${DOCS[@]}")
    finish "OK" "empty feature diff — nothing to sync"
fi

declare -A BEFORE=()
declare -A AFTER=()
MISSING=()

for DOC in "${DOCS[@]}"; do
    if [ -f "$VAULT/$DOC" ]; then
        BEFORE["$DOC"]="$(sha256sum "$VAULT/$DOC" | awk '{print $1}')"
    else
        BEFORE["$DOC"]=""
        MISSING+=("$DOC")
    fi
done

TODAY="$(date -I)"
ISSUE_CONTEXT="${ISSUE:+"#$ISSUE"}"
[ -n "$ISSUE_CONTEXT" ] || ISSUE_CONTEXT="(prototype mode; no issue number)"
PROMPT="$(cat "$ROOT/prompts/docs-sync.md")

## This docs sync

- issue: $ISSUE_CONTEXT
- feature: $FEATURE
- repo root: $REPO_ROOT
- vault: $VAULT
- architecture doc: $VAULT/ARCHI.md
- architecture rules doc: $VAULT/ARCHI-rules.md
- testing doc: $VAULT/TESTING.md
- date: $TODAY
- integration worktree: $WORKDIR

## Changed files

\`\`\`text
$CHANGED_FILES
\`\`\`

## Diff stat

\`\`\`text
$DIFF_STAT
\`\`\`

Use the available git diff, git log, git show, and git status commands to read
the portions of the feature delta and repository context you need. Do not
infer the change from the stat alone."

cd "$REPO_ROOT"
env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT \
    claude -p "$PROMPT" \
    --model opus \
    --permission-mode acceptEdits \
    --add-dir "$VAULT" \
    --allowedTools "Bash(git diff:*)" "Bash(git log:*)" "Bash(git show:*)" "Bash(git status:*)" \
    >"$ROOT/logs/docs-sync.md" 2>"$ROOT/logs/docs-sync.md.stderr" || true

for DOC in "${DOCS[@]}"; do
    if [ -f "$VAULT/$DOC" ]; then
        AFTER["$DOC"]="$(sha256sum "$VAULT/$DOC" | awk '{print $1}')"
    else
        AFTER["$DOC"]=""
    fi

    if [ -z "${BEFORE[$DOC]}" ]; then
        UNCHANGED+=("$DOC")
    elif [ "${BEFORE[$DOC]}" != "${AFTER[$DOC]}" ]; then
        UPDATED+=("$DOC")
    else
        UNCHANGED+=("$DOC")
    fi
done

NOTE_LINE="$(grep -E '^\{.*"note".*\}[[:space:]]*$' "$ROOT/logs/docs-sync.md" | tail -1 || true)"
NOTE=""
if [ -n "$NOTE_LINE" ] && jq -e . >/dev/null 2>&1 <<<"$NOTE_LINE"; then
    NOTE="$(jq -r '.note // ""' <<<"$NOTE_LINE")"
fi

if [ "${#MISSING[@]}" -gt 0 ]; then
    MISSING_NOTE="Missing vault documents treated as unchanged: $(IFS=', '; echo "${MISSING[*]}")."
    if [ -n "$NOTE" ]; then
        NOTE="$NOTE $MISSING_NOTE"
    else
        NOTE="$MISSING_NOTE"
    fi
fi

STATUS="OK"
if [ ! -s "$ROOT/logs/docs-sync.md" ]; then
    STATUS="ERROR"
    [ -n "$NOTE" ] || NOTE="model process produced no output; vault files were still verified by hash"
fi

finish "$STATUS" "$NOTE"
