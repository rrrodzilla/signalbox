#!/usr/bin/env bash
# SSE event forwarder: bin/sse-forward.sh <engine-label> <topic>
#
# stdin is one event payload JSON value. The script wraps it in the shared
# sink's event envelope, including run identity and launch metadata, then POSTs
# that envelope to /ingest. Empty or invalid JSON is preserved as a truncated
# {"raw": ...} payload. Delivery is fire-and-forget: unavailable or slow sink
# services, missing metadata, and environment discovery failures never stall or
# fail the originating pipeline, and the success path prints nothing.
#
# Exit status:
#   0   event accepted for best-effort forwarding (whether or not delivery works)
#   64  invalid invocation (wrong argument count or an empty argument)
set -euo pipefail

if [ "$#" -ne 2 ] || [ -z "$1" ] || [ -z "$2" ]; then
    echo "usage: bin/sse-forward.sh <engine-label> <topic>" >&2
    exit 64
fi

ENGINE_LABEL="$1"
TOPIC="$2"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FALLBACK_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -n "${SIGNALBOX_RUN_SLUG:-}" ]; then
    FALLBACK_RUN_SLUG="$SIGNALBOX_RUN_SLUG"
elif [ -n "${SIGNALBOX_ISSUE:-}" ]; then
    FALLBACK_RUN_SLUG="issue-$SIGNALBOX_ISSUE"
else
    FALLBACK_RUN_SLUG=""
fi

FALLBACK_RUN_DIR="$FALLBACK_ROOT"
if [ -n "$FALLBACK_RUN_SLUG" ]; then
    FALLBACK_RUN_DIR="$FALLBACK_ROOT/runs/$FALLBACK_RUN_SLUG"
fi
FALLBACK_REPO_ROOT="$FALLBACK_ROOT"

# Pre-seed usable paths before the shared environment probe. _env.sh may stop
# partway through discovery, so every value is normalized again afterwards.
ROOT="$FALLBACK_ROOT"
RUN_SLUG="$FALLBACK_RUN_SLUG"
RUN_DIR="$FALLBACK_RUN_DIR"
REPO_ROOT="$FALLBACK_REPO_ROOT"
source "$SCRIPT_DIR/_env.sh" 2>/dev/null || true

ROOT="${ROOT:-$FALLBACK_ROOT}"
RUN_SLUG="${RUN_SLUG:-$FALLBACK_RUN_SLUG}"
RUN_DIR="${RUN_DIR:-$FALLBACK_RUN_DIR}"
REPO_ROOT="${REPO_ROOT:-$FALLBACK_REPO_ROOT}"
FEATURE="${FEATURE:-}"

SLUG="${RUN_SLUG:-single-run}"
REPO="$(basename -- "$REPO_ROOT" 2>/dev/null || true)"
SENT_AT="$(date -u +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || true)"
RAW_WITH_SENTINEL="$({ cat 2>/dev/null || true; printf 'x'; })"
RAW_PAYLOAD="${RAW_WITH_SENTINEL%?}"

if PARSED_PAYLOAD="$(
    jq -c -s \
        'if length == 1 then .[0] else error("expected one JSON value") end' \
        <<<"$RAW_PAYLOAD" 2>/dev/null
)"; then
    :
else
    PARSED_PAYLOAD="$(
        LC_ALL=C printf '%s' "$RAW_PAYLOAD" \
            | head -c 4096 \
            | jq -Rsc '{raw: .}' 2>/dev/null \
            || true
    )"
fi

EMPTY_OBJECT="$(jq -cn '{}' 2>/dev/null || true)"
LAUNCH_JSON="$EMPTY_OBJECT"
PLAN_JSON="$EMPTY_OBJECT"

if [ -f "$RUN_DIR/launch.json" ]; then
    CANDIDATE="$(
        jq -c -s \
            'if length == 1 and (.[0] | type == "object")
             then .[0] else {} end' \
            "$RUN_DIR/launch.json" 2>/dev/null || true
    )"
    if [ -n "$CANDIDATE" ]; then
        LAUNCH_JSON="$CANDIDATE"
    fi
fi

if [ -f "$RUN_DIR/plan.json" ]; then
    CANDIDATE="$(
        jq -c -s \
            'if length == 1 and (.[0] | type == "object")
             then .[0] else {} end' \
            "$RUN_DIR/plan.json" 2>/dev/null || true
    )"
    if [ -n "$CANDIDATE" ]; then
        PLAN_JSON="$CANDIDATE"
    fi
fi

# The payload, launch, and plan documents reach jq on stdin rather than through
# --argjson: a large but valid payload would otherwise exceed the per-argument
# size limit and drop the event with "Argument list too long". printf is a shell
# builtin, so composing the stream costs no argument space. A stream that is not
# exactly three documents (an unparseable payload leaves its slot empty) fails
# the guard below and falls through to the envelope-construction error path.
ENVELOPE="$(
    printf '%s\n%s\n%s\n' "$PARSED_PAYLOAD" "$LAUNCH_JSON" "$PLAN_JSON" \
    | jq -cn -c \
        --arg type "$TOPIC" \
        --arg engine_label "$ENGINE_LABEL" \
        --arg sent_at "$SENT_AT" \
        --arg root "$ROOT" \
        --arg run_dir "$RUN_DIR" \
        --arg slug "$SLUG" \
        --arg repo "$REPO" \
        --arg repo_root "$REPO_ROOT" \
        --arg issue_env "${SIGNALBOX_ISSUE:-}" \
        --arg feature_env "$FEATURE" \
        '
        def integer_or_null($value):
            if (($value | type) == "number") and (($value | floor) == $value)
            then $value
            else null
            end;
        def string_or_null($value):
            if ($value | type) == "string" then $value else null end;

        ([inputs]) as $documents
        | (
            if ($documents | length) == 3
            then $documents
            else error("expected payload, launch, and plan documents")
            end
        ) as $stdin
        | $stdin[0] as $payload
        | $stdin[1] as $launch
        | $stdin[2] as $plan
        | (integer_or_null($launch.issue)) as $launch_issue
        | (integer_or_null($plan.issue)) as $plan_issue
        | {
            type: $type,
            engine_label: $engine_label,
            sent_at: $sent_at,
            correlation_id: (
                if ($payload | type) == "object"
                    and ($payload | has("correlation_id"))
                then $payload.correlation_id
                else null
                end
            ),
            payload: $payload,
            instance: {
                key: ($repo + "/" + $slug),
                repo: $repo,
                repo_root: $repo_root,
                harness: $root,
                run_dir: $run_dir,
                slug: $slug,
                issue: (
                    if ($issue_env | test("^[0-9]+$"))
                    then ($issue_env | tonumber)
                    elif $launch_issue != null
                    then $launch_issue
                    else $plan_issue
                    end
                ),
                feature: (
                    if $feature_env != "" and $feature_env != "feature"
                    then $feature_env
                    else string_or_null($plan.feature)
                    end
                ),
                engine: string_or_null(
                    try $launch.engines[$engine_label] catch null
                ),
                pid: integer_or_null($launch.pid),
                start_id: string_or_null($launch.start_id)
            }
        }
        ' 2>/dev/null || true
)"

if [ -z "$ENVELOPE" ]; then
    echo "[sse-forward] could not construct event envelope" >&2
    exit 0
fi

SINK_PORT="${SIGNALBOX_SINK_PORT:-8099}"
# The envelope reaches curl on stdin (--data-binary @-) for the same reason it
# reaches jq that way: as an argv element, a large envelope would exceed the
# per-argument size limit and the POST would never run.
printf '%s' "$ENVELOPE" \
    | curl -sS -X POST \
        --connect-timeout 1 \
        --max-time 2 \
        -H "Content-Type: application/json" \
        --data-binary @- \
        "http://127.0.0.1:$SINK_PORT/ingest" >/dev/null || true

exit 0
