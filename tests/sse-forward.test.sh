#!/usr/bin/env bash
# Self-contained test runner for bin/sse-forward.sh. No framework and no
# dependencies beyond coreutils + jq + a local curl stub; every fixture is
# built under its own mktemp -d harness tree. Prints PASS/FAIL per case and
# exits non-zero when any case failed.
#
# Deliberately no -e: several cases must capture and assert a subject exit
# status that is expected to be non-zero.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_SUBJECT="$ROOT/bin/sse-forward.sh"
FIXTURES=()
TESTS_RUN=0
TESTS_PASSED=0
RUN_STATUS=0
FIXTURE_ROOT=""
FIXTURE_SUBJECT=""
TEST_INPUT=""
TEST_RUN_SLUG="issue-14"
TEST_ISSUE="14"
TEST_CURL_STATUS="0"
TEST_SINK_PORT=""
TEST_USE_DEFAULT_PORT=1
TEST_CORRELATION_ID=""

cleanup() {
    local FIXTURE
    for FIXTURE in "${FIXTURES[@]}"; do
        rm -rf -- "$FIXTURE"
    done
}
trap cleanup EXIT

fixture() {
    FIXTURE_ROOT="$(mktemp -d)"
    FIXTURES+=("$FIXTURE_ROOT")
    mkdir -p \
        "$FIXTURE_ROOT/harness/bin" \
        "$FIXTURE_ROOT/harness/repos/example-repo" \
        "$FIXTURE_ROOT/stub" \
        "$FIXTURE_ROOT/curl-record"

    FIXTURE_SUBJECT="$FIXTURE_ROOT/harness/bin/sse-forward.sh"
    cp "$SOURCE_SUBJECT" "$FIXTURE_SUBJECT"
    chmod +x "$FIXTURE_SUBJECT"

    cat >"$FIXTURE_ROOT/harness/bin/_env.sh" <<'EOF'
# Minimal fixture environment for sse-forward.sh.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_SLUG="${SIGNALBOX_RUN_SLUG:-}"
if [ -n "$RUN_SLUG" ]; then
    RUN_DIR="$ROOT/runs/$RUN_SLUG"
else
    RUN_DIR="$ROOT"
fi
REPO_ROOT="$ROOT/repos/example-repo"
FEATURE="fixture-feature"
export ROOT RUN_SLUG RUN_DIR REPO_ROOT FEATURE
EOF

    cat >"$FIXTURE_ROOT/stub/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$@" >"$CURL_RECORD_DIR/args"
BODY=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --data-binary)
            shift
            # @- means the subject streams the body on stdin, matching how real
            # curl reads it; anything else is a literal inline body.
            if [ "${1:-}" = "@-" ]; then
                BODY="$({ cat 2>/dev/null || true; printf 'x'; })"
                BODY="${BODY%?}"
            else
                BODY="${1:-}"
            fi
            ;;
    esac
    shift
done
printf '%s' "$BODY" >"$CURL_RECORD_DIR/body"
exit "${CURL_EXIT_STATUS:-0}"
EOF
    chmod +x "$FIXTURE_ROOT/stub/curl"
}

# The forwarder reads the run's id from the envelope the exec-sink exports;
# TEST_CORRELATION_ID stands in for it. The payload is passed through verbatim
# and is no longer where the id comes from.
run_subject() {
    local STDOUT_FILE="$FIXTURE_ROOT/stdout"
    local STDERR_FILE="$FIXTURE_ROOT/stderr"
    local STDIN_FILE="$FIXTURE_ROOT/stdin"
    local RUN_DIR="$FIXTURE_ROOT/harness/runs/$TEST_RUN_SLUG"

    mkdir -p "$RUN_DIR"
    rm -f "$FIXTURE_ROOT/curl-record/args" "$FIXTURE_ROOT/curl-record/body"
    printf '%s' "$TEST_INPUT" >"$STDIN_FILE"

    if [ "$TEST_USE_DEFAULT_PORT" -eq 1 ]; then
        env -u SIGNALBOX_SINK_PORT \
            PATH="$FIXTURE_ROOT/stub:$PATH" \
            CURL_RECORD_DIR="$FIXTURE_ROOT/curl-record" \
            CURL_EXIT_STATUS="$TEST_CURL_STATUS" \
            SIGNALBOX_RUN_SLUG="$TEST_RUN_SLUG" \
            SIGNALBOX_ISSUE="$TEST_ISSUE" \
            EMERGENT_CORRELATION_ID="$TEST_CORRELATION_ID" \
            "$FIXTURE_SUBJECT" "$@" \
            <"$STDIN_FILE" >"$STDOUT_FILE" 2>"$STDERR_FILE"
    else
        PATH="$FIXTURE_ROOT/stub:$PATH" \
            CURL_RECORD_DIR="$FIXTURE_ROOT/curl-record" \
            CURL_EXIT_STATUS="$TEST_CURL_STATUS" \
            SIGNALBOX_RUN_SLUG="$TEST_RUN_SLUG" \
            SIGNALBOX_ISSUE="$TEST_ISSUE" \
            SIGNALBOX_SINK_PORT="$TEST_SINK_PORT" \
            EMERGENT_CORRELATION_ID="$TEST_CORRELATION_ID" \
            "$FIXTURE_SUBJECT" "$@" \
            <"$STDIN_FILE" >"$STDOUT_FILE" 2>"$STDERR_FILE"
    fi
    RUN_STATUS=$?
}

report_case() {
    local NAME="$1" OK="$2" DETAIL="${3:-}"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$OK" -eq 0 ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        printf 'PASS %s\n' "$NAME"
    else
        printf 'FAIL %s%s\n' "$NAME" "${DETAIL:+ — $DETAIL}"
    fi
}

reset_case() {
    TEST_INPUT=""
    TEST_RUN_SLUG="issue-14"
    TEST_ISSUE="14"
    TEST_CURL_STATUS="0"
    TEST_SINK_PORT=""
    TEST_USE_DEFAULT_PORT=1
    TEST_CORRELATION_ID=""
    fixture
}

# 1. A valid object payload is preserved exactly with its event identity.
reset_case
TEST_INPUT='{"correlation_id":"cid-123","nested":{"ok":true},"count":2}'
TEST_CORRELATION_ID="cor_01kyk5bd3xfcgbvh2tacztktzb"
run_subject pipeline phase.request
BODY="$FIXTURE_ROOT/curl-record/body"
OK=1
if [ "$RUN_STATUS" -eq 0 ] \
    && [ ! -s "$FIXTURE_ROOT/stdout" ] \
    && jq -e \
        --arg harness "$FIXTURE_ROOT/harness" \
        '
        .type == "phase.request"
        and .engine_label == "pipeline"
        and .correlation_id == "cor_01kyk5bd3xfcgbvh2tacztktzb"
        and .payload == {
            correlation_id: "cid-123",
            nested: {ok: true},
            count: 2
        }
        and (
            .sent_at
            | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
        )
        and (.instance.key | test("^example-repo/issue-14@[A-Za-z0-9._/-]+$"))
        and (.instance | del(.key)) == {
            repo: "example-repo",
            repo_root: ($harness + "/repos/example-repo"),
            harness: $harness,
            run_dir: ($harness + "/runs/issue-14"),
            slug: "issue-14",
            issue: 14,
            feature: "fixture-feature",
            engine: null,
            pid: null,
            start_id: null
        }
        ' "$BODY" >/dev/null; then
    OK=0
fi
report_case "valid payload produces the exact event and instance envelope" "$OK" \
    "status=$RUN_STATUS body=$(head -c 240 "$BODY" 2>/dev/null)"

# 2. launch.json contributes the exact liveness and engine fields.
reset_case
RUN_DIR="$FIXTURE_ROOT/harness/runs/$TEST_RUN_SLUG"
mkdir -p "$RUN_DIR"
jq -n \
    --arg engine "signalbox-implement-14" \
    --arg start_id "start-abc" \
    '{pid: 4321, start_id: $start_id, engines: {implement: $engine}}' \
    >"$RUN_DIR/launch.json"
TEST_INPUT='{"stage":"s1"}'
run_subject implement shard.built
BODY="$FIXTURE_ROOT/curl-record/body"
OK=1
if [ "$RUN_STATUS" -eq 0 ] \
    && jq -e '
        .instance.pid == 4321
        and .instance.start_id == "start-abc"
        and .instance.engine == "signalbox-implement-14"
    ' "$BODY" >/dev/null; then
    OK=0
fi
report_case "launch metadata contributes pid, start_id, and engine" "$OK" \
    "status=$RUN_STATUS body=$(head -c 240 "$BODY" 2>/dev/null)"

# 3. Missing launch.json keeps liveness fields null and still succeeds.
reset_case
TEST_INPUT='42'
run_subject review review.approved
BODY="$FIXTURE_ROOT/curl-record/body"
OK=1
if [ "$RUN_STATUS" -eq 0 ] \
    && jq -e '
        .payload == 42
        and .correlation_id == null
        and .instance.pid == null
        and .instance.start_id == null
        and .instance.engine == null
    ' "$BODY" >/dev/null; then
    OK=0
fi
report_case "missing launch metadata degrades to null fields" "$OK" \
    "status=$RUN_STATUS body=$(head -c 240 "$BODY" 2>/dev/null)"

# 4. Invalid JSON is preserved under payload.raw.
reset_case
TEST_INPUT='not-json: [still important'
run_subject plan plan.escalated
BODY="$FIXTURE_ROOT/curl-record/body"
OK=1
if [ "$RUN_STATUS" -eq 0 ] \
    && jq -e \
        --arg raw "$TEST_INPUT" \
        '.payload == {raw: $raw} and .correlation_id == null' \
        "$BODY" >/dev/null; then
    OK=0
fi
report_case "unparseable stdin becomes payload.raw" "$OK" \
    "status=$RUN_STATUS body=$(head -c 240 "$BODY" 2>/dev/null)"

# 5. Delivery failure is swallowed after the curl stub records the request.
reset_case
TEST_CURL_STATUS=7
TEST_INPUT='{"event":"kept"}'
run_subject init doc.researched
OK=1
if [ "$RUN_STATUS" -eq 0 ] \
    && [ -s "$FIXTURE_ROOT/curl-record/body" ] \
    && [ ! -s "$FIXTURE_ROOT/stdout" ]; then
    OK=0
fi
report_case "sink delivery failure still exits 0" "$OK" \
    "status=$RUN_STATUS stderr=$(head -c 160 "$FIXTURE_ROOT/stderr")"

# 6. Wrong argument counts and empty arguments are wiring errors.
reset_case
TEST_INPUT='{}'
run_subject
S0=$RUN_STATUS
run_subject pipeline phase.request extra
S3=$RUN_STATUS
run_subject "" phase.request
SE=$RUN_STATUS
OK=1
if [ "$S0" -eq 64 ] && [ "$S3" -eq 64 ] && [ "$SE" -eq 64 ]; then
    OK=0
fi
report_case "wrong or empty arguments exit 64" "$OK" \
    "zero=$S0 three=$S3 empty=$SE"

# 7. The default port is 8099, the options are exact, and the body is streamed.
reset_case
TEST_INPUT='{"default":true}'
run_subject pipeline system.started.pipeline
BODY="$FIXTURE_ROOT/curl-record/body"
mapfile -t CURL_ARGS <"$FIXTURE_ROOT/curl-record/args"
OK=1
if [ "$RUN_STATUS" -eq 0 ] \
    && [ "${#CURL_ARGS[@]}" -eq 12 ] \
    && [ "${CURL_ARGS[0]}" = "-sS" ] \
    && [ "${CURL_ARGS[1]}" = "-X" ] \
    && [ "${CURL_ARGS[2]}" = "POST" ] \
    && [ "${CURL_ARGS[3]}" = "--connect-timeout" ] \
    && [ "${CURL_ARGS[4]}" = "1" ] \
    && [ "${CURL_ARGS[5]}" = "--max-time" ] \
    && [ "${CURL_ARGS[6]}" = "2" ] \
    && [ "${CURL_ARGS[7]}" = "-H" ] \
    && [ "${CURL_ARGS[8]}" = "Content-Type: application/json" ] \
    && [ "${CURL_ARGS[9]}" = "--data-binary" ] \
    && [ "${CURL_ARGS[10]}" = "@-" ] \
    && [ "${CURL_ARGS[11]}" = "http://127.0.0.1:8099/ingest" ] \
    && jq -e '.payload == {default: true}' "$BODY" >/dev/null; then
    OK=0
fi
report_case "default URL and fire-and-forget curl options are exact" "$OK" \
    "status=$RUN_STATUS url=${CURL_ARGS[11]:-missing}"

# 8. SIGNALBOX_SINK_PORT overrides the default URL port.
reset_case
TEST_USE_DEFAULT_PORT=0
TEST_SINK_PORT=18123
TEST_INPUT='{"custom":true}'
run_subject pipeline system.started.pipeline
mapfile -t CURL_ARGS <"$FIXTURE_ROOT/curl-record/args"
OK=1
if [ "$RUN_STATUS" -eq 0 ] \
    && [ "${CURL_ARGS[11]:-}" = "http://127.0.0.1:18123/ingest" ]; then
    OK=0
fi
report_case "SIGNALBOX_SINK_PORT overrides the posted URL" "$OK" \
    "status=$RUN_STATUS url=${CURL_ARGS[11]:-missing}"

# 9. A payload past the per-argument size limit still forwards intact. Linux
#    caps a single argv element at 128 KiB, so 200 KB of payload would fail with
#    "Argument list too long" if the envelope were built or posted through argv.
reset_case
LARGE_VALUE="$(head -c 200000 /dev/zero | tr '\0' 'a')"
TEST_INPUT="$(
    printf '%s' "$LARGE_VALUE" | jq -Rsc '{correlation_id: "cid-big", blob: .}'
)"
TEST_CORRELATION_ID="cor_01kyk5bd3xfcgbvh2tacztktzb"
run_subject pipeline phase.request
BODY="$FIXTURE_ROOT/curl-record/body"
OK=1
if [ "$RUN_STATUS" -eq 0 ] \
    && [ ! -s "$FIXTURE_ROOT/stderr" ] \
    && jq -e '
        .correlation_id == "cor_01kyk5bd3xfcgbvh2tacztktzb"
        and .payload.correlation_id == "cid-big"
        and (.payload.blob | length) == 200000
        and (.payload.blob | test("^a+$"))
    ' "$BODY" >/dev/null; then
    OK=0
fi
report_case "payload beyond the per-argument limit forwards intact" "$OK" \
    "status=$RUN_STATUS stderr=$(head -c 160 "$FIXTURE_ROOT/stderr")"

# 10. Two harness trees that share a repository basename and a run slug are
#     still two instances: the key carries canonical path identity, and it is
#     stable across events from the same tree.
reset_case
TEST_INPUT='{"first":true}'
run_subject pipeline phase.request
FIRST_STATUS=$RUN_STATUS
FIRST_KEY="$(jq -r '.instance.key // empty' "$FIXTURE_ROOT/curl-record/body" 2>/dev/null)"
run_subject pipeline phase.request
REPEAT_KEY="$(jq -r '.instance.key // empty' "$FIXTURE_ROOT/curl-record/body" 2>/dev/null)"
reset_case
TEST_INPUT='{"second":true}'
run_subject pipeline phase.request
SECOND_STATUS=$RUN_STATUS
SECOND_KEY="$(jq -r '.instance.key // empty' "$FIXTURE_ROOT/curl-record/body" 2>/dev/null)"
OK=1
if [ "$FIRST_STATUS" -eq 0 ] \
    && [ "$SECOND_STATUS" -eq 0 ] \
    && [ -n "$FIRST_KEY" ] \
    && [ "$FIRST_KEY" = "$REPEAT_KEY" ] \
    && [ "$FIRST_KEY" != "$SECOND_KEY" ] \
    && [ "${FIRST_KEY%@*}" = "example-repo/issue-14" ] \
    && [ "${SECOND_KEY%@*}" = "example-repo/issue-14" ]; then
    OK=0
fi
report_case "same repo basename and slug in two trees produce distinct keys" "$OK" \
    "first=$FIRST_KEY repeat=$REPEAT_KEY second=$SECOND_KEY"

printf '%d/%d cases passed\n' "$TESTS_PASSED" "$TESTS_RUN"
[ "$TESTS_PASSED" -eq "$TESTS_RUN" ]
