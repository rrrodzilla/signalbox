#!/usr/bin/env bash
# Vault researcher: bin/research.sh <aspect>
# stdin = init.requested payload {repo, vault, correlation_id}
# stdout = doc.researched payload {aspect, doc, content, correlation_id}
#
# One researcher per aspect, fanned out by subscription — each runs a
# read-only Codex analysis of the repo and produces the COMPLETE document
# for its vault file. The writer downstream is dumb; all judgment is here.
set -euo pipefail
# shellcheck source=_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/_env.sh"

ASPECT="${1:?usage: research.sh <architecture|rules|testing>}"
PAYLOAD="$(cat)"
CID="$(jq -r '.correlation_id // ""' <<<"$PAYLOAD")"

case "$ASPECT" in
    architecture) DOC="ARCHI.md" ;;
    rules)        DOC="ARCHI-rules.md" ;;
    testing)      DOC="TESTING.md" ;;
    *) echo "unknown aspect: $ASPECT" >&2; exit 64 ;;
esac

mkdir -p "$ROOT/logs"
LAST="$ROOT/logs/init-$ASPECT.md"
EVENTS="$ROOT/logs/init-$ASPECT.jsonl"

PROMPT="$(cat "$ROOT/prompts/init-$ASPECT.md")"

cd "$REPO_ROOT"
codex exec \
    --json \
    --skip-git-repo-check \
    --sandbox read-only \
    --color never \
    -c model="${CODEX_MODEL:-gpt-5.6-sol}" \
    -c model_reasoning_effort="${CODEX_EFFORT:-high}" \
    -o "$LAST" \
    "$PROMPT" \
    </dev/null \
    >"$EVENTS" \
    2>"$EVENTS.stderr"

jq -n \
    --arg aspect "$ASPECT" \
    --arg doc "$DOC" \
    --rawfile content "$LAST" \
    --arg cid "$CID" \
    '{aspect: $aspect, doc: $doc, content: $content, correlation_id: $cid}'
