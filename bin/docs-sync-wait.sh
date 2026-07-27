#!/usr/bin/env bash
# bin/docs-sync-wait.sh <run-dir> <timeout-secs>
# Blocks until <run-dir>/state/docs-sync.json is newer than
# <run-dir>/state/pipeline-review.stamp, then validates it. Validation fails
# closed: the evidence must report status OK and carry the same correlation_id
# as <run-dir>/results/CR.md, which must exist and declare one. Prints a
# one-line human-readable reason to stdout in every case.
# exit 0 = precondition satisfied; 1 = failed or timed out; 64 = bad invocation.
set -euo pipefail

if [ "$#" -ne 2 ] || ! [[ "$2" =~ ^[0-9]+$ ]]; then
    echo "usage: bin/docs-sync-wait.sh <run-dir> <timeout-secs>" >&2
    exit 64
fi

RUN_DIR="$1"
TIMEOUT=$((10#$2))
STAMP="$RUN_DIR/state/pipeline-review.stamp"
EVIDENCE="$RUN_DIR/state/docs-sync.json"
CR="$RUN_DIR/results/CR.md"

if [ ! -e "$STAMP" ]; then
    printf 'docs-sync precondition failed: missing review stamp %s\n' "$STAMP"
    exit 1
fi

START="$(date +%s)"
DEADLINE=$((START + TIMEOUT))
while [ ! -e "$EVIDENCE" ] || [ ! "$EVIDENCE" -nt "$STAMP" ]; do
    NOW="$(date +%s)"
    if [ "$NOW" -ge "$DEADLINE" ]; then
        if [ -e "$EVIDENCE" ]; then
            printf 'docs-sync precondition timed out: evidence %s is stale (older than the review stamp %s)\n' \
                "$EVIDENCE" "$STAMP"
        else
            printf 'docs-sync precondition timed out: evidence %s never appeared\n' "$EVIDENCE"
        fi
        exit 1
    fi

    REMAINING=$((DEADLINE - NOW))
    SLEEP_FOR=5
    if [ "$REMAINING" -lt "$SLEEP_FOR" ]; then
        SLEEP_FOR="$REMAINING"
    fi
    sleep "$SLEEP_FOR"
done

if ! jq -e 'true' "$EVIDENCE" >/dev/null 2>&1; then
    printf 'docs-sync precondition failed: evidence is not valid JSON: %s\n' "$EVIDENCE"
    exit 1
fi

if ! jq -e 'type == "object" and .status == "OK"' "$EVIDENCE" >/dev/null; then
    STATUS="$(jq -r '
        if type == "object" and has("status") then .status else null end
        | tostring
        | @json
    ' "$EVIDENCE")"
    NOTE="$(jq -r '
        if type == "object" and has("note") then .note else null end
        | tostring
        | @json
    ' "$EVIDENCE")"
    printf 'docs-sync precondition failed: status %s; note %s\n' "$STATUS" "$NOTE"
    exit 1
fi

if [ ! -f "$CR" ]; then
    printf 'docs-sync precondition failed: missing review result %s; correlation cannot be validated\n' "$CR"
    exit 1
fi

CR_CID="$(awk '
    /^correlation_id:[[:space:]]*/ {
        sub(/^correlation_id:[[:space:]]*/, "")
        sub(/[[:space:]]*$/, "")
        if (length($0) > 0) {
            print
            exit
        }
    }
' "$CR")"
if [ -z "$CR_CID" ]; then
    printf 'docs-sync precondition failed: review result %s has no correlation_id; correlation cannot be validated\n' "$CR"
    exit 1
fi

EVIDENCE_CID="$(jq -r '
    if type == "object" and has("correlation_id") then
        .correlation_id | if . == null then "" else tostring end
    else
        ""
    end
' "$EVIDENCE")"
if [ "$CR_CID" != "$EVIDENCE_CID" ]; then
    printf 'docs-sync precondition failed: CR correlation_id "%s" does not match evidence correlation_id "%s"\n' \
        "$CR_CID" "$EVIDENCE_CID"
    exit 1
fi

UPDATED="$(jq -c '
    if type == "object" and has("updated") then .updated else null end
' "$EVIDENCE")"
if [ "$UPDATED" = "[]" ]; then
    UPDATED_REASON='updated=[] (no-op)'
else
    UPDATED_REASON="updated=$UPDATED"
fi

printf 'docs-sync precondition satisfied: status "OK"; %s; correlation_id "%s" matches CR.md\n' \
    "$UPDATED_REASON" "$CR_CID"
