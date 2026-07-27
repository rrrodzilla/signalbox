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
[ -n "$FEATURE" ] || FEATURE="$(jq -r '.feature' "$RUN_DIR/plan.json" 2>/dev/null || true)"
ISSUE="$(jq -r '.issue // empty' "$RUN_DIR/plan.json" 2>/dev/null || true)"

# Resolution must stay nonfatal: an unresolvable vault symlink has to reach
# finish "ERROR" rather than kill the script and suppress the downstream event.
VAULT_ERR=""
if ! VAULT="$(readlink -f "$REPO_ROOT/.claude/docs" 2>&1)"; then
    VAULT_ERR="cannot resolve vault path $REPO_ROOT/.claude/docs: $VAULT"
    VAULT="$REPO_ROOT/.claude/docs"
fi
STATE_PATH="$RUN_DIR/state/docs-sync.json"
DOCS=("ARCHI.md" "ARCHI-rules.md" "TESTING.md")
UPDATED=()
UNCHANGED=()

mkdir -p "$RUN_DIR/state" "$RUN_DIR/logs"

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

if [ -n "$VAULT_ERR" ]; then
    UNCHANGED=("${DOCS[@]}")
    finish "ERROR" "$VAULT_ERR"
fi

if [ ! -d "$VAULT" ]; then
    UNCHANGED=("${DOCS[@]}")
    finish "ERROR" "vault not found at resolved path: $VAULT"
fi

# A broken worktree or a missing base ref must be an ERROR, not an OK empty diff.
if ! CHANGED_FILES="$(git -C "$WORKDIR" diff --name-only "$BASE_BRANCH"...HEAD 2>&1)"; then
    UNCHANGED=("${DOCS[@]}")
    finish "ERROR" "git diff --name-only $BASE_BRANCH...HEAD failed in $WORKDIR: $CHANGED_FILES"
fi
if ! DIFF_STAT="$(git -C "$WORKDIR" diff --stat "$BASE_BRANCH"...HEAD 2>&1)"; then
    UNCHANGED=("${DOCS[@]}")
    finish "ERROR" "git diff --stat $BASE_BRANCH...HEAD failed in $WORKDIR: $DIFF_STAT"
fi

if [ -z "$CHANGED_FILES" ]; then
    UNCHANGED=("${DOCS[@]}")
    # Nothing to sync still requires the three vault documents to be present:
    # an empty diff must not hand the operator seam a status: "OK" over a vault
    # that is missing a required document.
    EMPTY_DIFF_MISSING=()
    for DOC in "${DOCS[@]}"; do
        [ -f "$VAULT/$DOC" ] || EMPTY_DIFF_MISSING+=("$DOC")
    done
    if [ "${#EMPTY_DIFF_MISSING[@]}" -gt 0 ]; then
        finish "ERROR" "empty feature diff — nothing to sync; required vault documents absent: $(IFS=', '; echo "${EMPTY_DIFF_MISSING[*]}")."
    fi
    finish "OK" "empty feature diff — nothing to sync"
fi

# The vault is repo-scoped, not run-scoped: every concurrent run syncs the SAME
# three documents. Hash-read, model edit and hash-verify are therefore one
# serialized transaction under a repo-scoped lock — otherwise two runs interleave
# and the second overwrites the first feature's documentation while both still
# record status "OK", and bin/planner.sh (which takes the lock shared) can read
# the vault mid-edit. Held across the model call by necessity: the window that
# must be exclusive is exactly the window in which the documents are mutated.
mkdir -p "$LEDGER_DIR"
exec 9>"$LEDGER_DIR/vault.lock"
flock -x 9

declare -A BEFORE=()
declare -A AFTER=()
# Documents absent from the vault after the run, whatever their hash history;
# filled in by the post-run pass. Any entry here forces an ERROR status.
MISSING=()

for DOC in "${DOCS[@]}"; do
    if [ -f "$VAULT/$DOC" ]; then
        BEFORE["$DOC"]="$(sha256sum "$VAULT/$DOC" | awk '{print $1}')"
    else
        BEFORE["$DOC"]=""
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

# Run from the feature worktree: the allowed git commands must inspect the HEAD
# under review, not the base checkout.
cd "$WORKDIR"
CLAUDE_RC=0
env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT \
    claude -p "$PROMPT" \
    --model sonnet \
    --permission-mode acceptEdits \
    --add-dir "$VAULT" \
    --allowedTools "Bash(git diff:*)" "Bash(git log:*)" "Bash(git show:*)" "Bash(git status:*)" \
    >"$RUN_DIR/logs/docs-sync.md" 2>"$RUN_DIR/logs/docs-sync.md.stderr" || CLAUDE_RC=$?

for DOC in "${DOCS[@]}"; do
    if [ -f "$VAULT/$DOC" ]; then
        AFTER["$DOC"]="$(sha256sum "$VAULT/$DOC" | awk '{print $1}')"
    else
        AFTER["$DOC"]=""
    fi

    # An absent-then-created document changed hash state: that is an update.
    if [ "${BEFORE[$DOC]}" != "${AFTER[$DOC]}" ]; then
        UPDATED+=("$DOC")
    else
        UNCHANGED+=("$DOC")
    fi

    # Absence is judged on the post-run state alone, independent of the hash
    # comparison above: a deleted document also changes hash state, so the
    # update branch is not evidence that the document exists.
    [ -n "${AFTER[$DOC]}" ] || MISSING+=("$DOC")
done

# The mutation window is over: hand the vault to the next run before parsing
# this run's own log and reporting.
exec 9>&-

NOTE_LINE="$(grep -E '^\{.*"note".*\}[[:space:]]*$' "$RUN_DIR/logs/docs-sync.md" | tail -1 || true)"
NOTE=""
if [ -n "$NOTE_LINE" ] && jq -e . >/dev/null 2>&1 <<<"$NOTE_LINE"; then
    NOTE="$(jq -r '.note // ""' <<<"$NOTE_LINE")"
fi

append_note() {
    if [ -n "$NOTE" ]; then
        NOTE="$NOTE $1"
    else
        NOTE="$1"
    fi
}

STATUS="OK"
if [ ! -s "$RUN_DIR/logs/docs-sync.md" ]; then
    STATUS="ERROR"
    [ -n "$NOTE" ] || NOTE="model process produced no output; vault files were still verified by hash"
elif [ "$CLAUDE_RC" -ne 0 ]; then
    # Nonzero exit with partial stdout must not be reported as a clean sync.
    STATUS="ERROR"
    append_note "model process exited $CLAUDE_RC; its output may be incomplete."
fi

# All three vault documents are required. A run that ends with any of them
# absent — deleted by the sync, or never present at all — is an ERROR, so the
# operator seam blocks promotion instead of reading a status: "OK" note.
if [ "${#MISSING[@]}" -gt 0 ]; then
    STATUS="ERROR"
    append_note "Required vault documents absent after sync: $(IFS=', '; echo "${MISSING[*]}")."
fi

finish "$STATUS" "$NOTE"
