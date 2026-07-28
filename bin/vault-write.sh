#!/usr/bin/env bash
# Vault writer: stdin = doc.researched payload {aspect, doc, content, ...}.
# stdout = doc.written payload {doc, path, bytes}.
#
# Non-destructive by design: TRIP-init gates ARCHI.md on explicit human
# approval, so an existing vault doc is never clobbered — the research
# lands as <name>.proposed.md beside it for the human to diff and adopt.
set -euo pipefail
# shellcheck source=_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/_env.sh"

PAYLOAD="$(cat)"
DOC="$(jq -r '.doc' <<<"$PAYLOAD")"

VAULT="$(readlink -f "$REPO_ROOT/.claude/docs")"
[ -d "$VAULT" ] || { echo "vault missing: $VAULT" >&2; exit 1; }

# Same repo-scoped vault lock bin/docs-sync.sh holds exclusively and
# bin/planner.sh holds shared: the exists-check and the write are one
# transaction, and no reader observes a half-written document.
mkdir -p "$LEDGER_DIR"
exec 9>"$LEDGER_DIR/vault.lock"
flock -x 9

OUT="$VAULT/$DOC"
if [ -e "$OUT" ]; then
    OUT="$VAULT/${DOC%.md}.proposed.md"
    echo "[vault-write] $DOC exists — writing proposal $(basename "$OUT")" >&2
fi

TEMP="$OUT.tmp.$$"
jq -r '.content' <<<"$PAYLOAD" >"$TEMP"
mv "$TEMP" "$OUT"
exec 9>&-

jq -n \
    --arg doc "$DOC" \
    --arg path "$OUT" \
    --argjson bytes "$(wc -c <"$OUT")" \
    '{doc: $doc, path: $path, bytes: $bytes}'
