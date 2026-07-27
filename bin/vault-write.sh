#!/usr/bin/env bash
# Vault writer: stdin = doc.researched payload {aspect, doc, content, ...}.
# stdout = doc.written payload {doc, path, bytes, correlation_id}.
#
# Non-destructive by design: TRIP-init gates ARCHI.md on explicit human
# approval, so an existing vault doc is never clobbered — the research
# lands as <name>.proposed.md beside it for the human to diff and adopt.
set -euo pipefail
# shellcheck source=_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/_env.sh"

PAYLOAD="$(cat)"
DOC="$(jq -r '.doc' <<<"$PAYLOAD")"
CID="$(jq -r '.correlation_id // ""' <<<"$PAYLOAD")"

VAULT="$(readlink -f "$REPO_ROOT/.claude/docs")"
[ -d "$VAULT" ] || { echo "vault missing: $VAULT" >&2; exit 1; }

OUT="$VAULT/$DOC"
if [ -e "$OUT" ]; then
    OUT="$VAULT/${DOC%.md}.proposed.md"
    echo "[vault-write] $DOC exists — writing proposal $(basename "$OUT")" >&2
fi

jq -r '.content' <<<"$PAYLOAD" >"$OUT"

jq -n \
    --arg doc "$DOC" \
    --arg path "$OUT" \
    --argjson bytes "$(wc -c <"$OUT")" \
    --arg cid "$CID" \
    '{doc: $doc, path: $path, bytes: $bytes, correlation_id: $cid}'
