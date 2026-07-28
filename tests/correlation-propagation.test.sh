#!/usr/bin/env bash
# Self-contained test runner for envelope correlation propagation: the review
# seed reading the envelope, the seed topology declaring --correlate, the phase
# runner handing its id to a child engine, and -- when the engine and the exec
# primitives are installed -- a real source-to-handler trail in the event store.
# No framework and no dependencies beyond coreutils, git, jq, and python3
# (tomllib); every fixture lives under mktemp -d and every run directory uses a
# unique test-only slug.
# Prints PASS/FAIL per case and exits non-zero when any case failed.
#
# Deliberately no -e: cases capture subject statuses that may be non-zero so
# every correlation regression is reported in one run.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_ROOT="$(mktemp -d)"
RUN_TOKEN="correlation-propagation-$$"
SEED_SLUG="$RUN_TOKEN-seed"
VALID_PHASE_SLUG="$RUN_TOKEN-valid"
MALFORMED_PHASE_SLUG="$RUN_TOKEN-malformed"
RUN_PATHS=(
    "$ROOT/runs/$SEED_SLUG"
    "$ROOT/runs/$VALID_PHASE_SLUG"
    "$ROOT/runs/$MALFORMED_PHASE_SLUG"
)
TESTS_RUN=0
TESTS_PASSED=0
PRIMITIVES="$HOME/.local/share/emergent/primitives/bin"

cleanup() {
    local RUN_PATH
    rm -rf -- "$FIXTURE_ROOT"
    for RUN_PATH in "${RUN_PATHS[@]}"; do
        case "$RUN_PATH" in
            "$ROOT"/runs/correlation-propagation-*) rm -rf -- "$RUN_PATH" ;;
        esac
    done
}
trap cleanup EXIT

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

report_skip() {
    printf 'SKIP %s — %s\n' "$1" "$2"
}

# A well-formed TypeID, the shape exec-source mints.
EXPECTED_CID="cor_01kyk5bd3xfcgbvh2tacztktzb"

# 1. The review seed reports the envelope's id and keeps it out of the payload.
SEED_OUTPUT="$(
    EMERGENT_CORRELATION_ID="$EXPECTED_CID" \
        SIGNALBOX_RUN_SLUG="$SEED_SLUG" \
        "$ROOT/bin/seed.sh" 2>"$FIXTURE_ROOT/seed.stderr"
)"
SEED_STATUS=$?
SEED_STDERR="$(cat "$FIXTURE_ROOT/seed.stderr" 2>/dev/null)"
OK=1
if [ "$SEED_STATUS" -eq 0 ] \
    && jq -e 'has("correlation_id") | not' <<<"$SEED_OUTPUT" >/dev/null 2>&1 \
    && jq -e '.round == 1 and (.feature | type) == "string"' \
        <<<"$SEED_OUTPUT" >/dev/null 2>&1 \
    && [[ "$SEED_STDERR" == *"$EXPECTED_CID"* ]]; then
    OK=0
fi
report_case "review seed reads the envelope and leaves the payload clean" "$OK" \
    "status=$SEED_STATUS payload=$SEED_OUTPUT stderr=$SEED_STDERR"

# 2. Without an envelope the seed fails loudly. Minting a substitute here is
# the issue #42 regression: the id would exist only in the payload, and the
# event store would have no record of it.
ORPHAN_OUTPUT="$(
    env -u EMERGENT_CORRELATION_ID \
        SIGNALBOX_RUN_SLUG="$SEED_SLUG" \
        "$ROOT/bin/seed.sh" 2>"$FIXTURE_ROOT/seed-orphan.stderr"
)"
ORPHAN_STATUS=$?
OK=1
if [ "$ORPHAN_STATUS" -ne 0 ] && [ -z "$ORPHAN_OUTPUT" ]; then
    OK=0
fi
report_case "review seed refuses to mint without an envelope" "$OK" \
    "status=$ORPHAN_STATUS payload=$ORPHAN_OUTPUT"

# 3. A malformed envelope value is treated as absence, not adopted.
MALFORMED_OUTPUT="$(
    EMERGENT_CORRELATION_ID="pipe-42-20260727-231704" \
        SIGNALBOX_RUN_SLUG="$SEED_SLUG" \
        "$ROOT/bin/seed.sh" 2>"$FIXTURE_ROOT/seed-malformed.stderr"
)"
MALFORMED_STATUS=$?
OK=1
if [ "$MALFORMED_STATUS" -ne 0 ] && [ -z "$MALFORMED_OUTPUT" ]; then
    OK=0
fi
report_case "review seed rejects a legacy hand-minted envelope value" "$OK" \
    "status=$MALFORMED_STATUS payload=$MALFORMED_OUTPUT"

# 4. Every seed source declares --correlate. Without it the fabric stamps
# nothing and every seed in that topology fails closed.
SEED_SOURCES="$(
    python3 - "$ROOT" 2>"$FIXTURE_ROOT/tomllib.stderr" <<'PYEOF'
import pathlib
import sys
import tomllib

root = pathlib.Path(sys.argv[1])
missing = []
seen = 0
for name in ("pipeline.toml", "plan.toml", "implement.toml", "emergent.toml", "init.toml"):
    with open(root / name, "rb") as stream:
        topology = tomllib.load(stream)
    for source in topology.get("sources", []):
        args = source.get("args", [])
        if not any("/bin/" in str(arg) and str(arg).endswith(".sh") for arg in args):
            continue
        seen += 1
        if "--correlate" not in args:
            missing.append(f"{name}:{source['name']}")
print(seen, ",".join(missing))
PYEOF
)"
TOML_STATUS=$?
SEED_SOURCE_COUNT="${SEED_SOURCES%% *}"
SEED_SOURCE_MISSING="${SEED_SOURCES#* }"
OK=1
if [ "$TOML_STATUS" -eq 0 ] \
    && [ "$SEED_SOURCE_COUNT" -eq 5 ] \
    && [ -z "$SEED_SOURCE_MISSING" ]; then
    OK=0
fi
report_case "every seed source declares --correlate" "$OK" \
    "toml=$TOML_STATUS count=$SEED_SOURCE_COUNT missing=$SEED_SOURCE_MISSING"

# 5. No topology threads correlation_id through a payload any more; the
# envelope is the single channel.
PAYLOAD_THREADING="$(
    grep -l 'correlation_id' "$ROOT"/*.toml 2>/dev/null | tr '\n' ' '
)"
OK=1
if [ -z "${PAYLOAD_THREADING// /}" ]; then
    OK=0
fi
report_case "no topology carries correlation_id in a payload" "$OK" \
    "files=$PAYLOAD_THREADING"

FAKE_BIN="$FIXTURE_ROOT/bin"
mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/emergent" <<'FAKEEOF'
#!/usr/bin/env bash
set -euo pipefail

jq -n \
    --arg correlation_id "${EMERGENT_CORRELATION_ID-}" \
    --arg issue "${SIGNALBOX_ISSUE-}" \
    --arg run_slug "${SIGNALBOX_RUN_SLUG-}" \
    '{correlation_id: $correlation_id, issue: $issue, run_slug: $run_slug}' \
    >"$FAKE_ENGINE_ENV_FILE"
jq -n '{feature: "fixture", stages: []}' >"$FAKE_ENGINE_RUN_DIR/plan.json"

SLEEP_PID=""
stop_sleep() {
    if [ -n "$SLEEP_PID" ]; then
        kill "$SLEEP_PID" 2>/dev/null || true
        wait "$SLEEP_PID" 2>/dev/null || true
    fi
    exit 0
}
trap stop_sleep TERM
sleep 60 &
SLEEP_PID=$!
wait "$SLEEP_PID"
FAKEEOF
chmod +x "$FAKE_BIN/emergent"

run_phase_case() {
    local SLUG="$1"
    local ENVELOPE_CID="$2"
    local OUTPUT_FILE="$3"
    local ENV_FILE="$4"
    local STDERR_FILE="$5"
    local RUN_DIR="$ROOT/runs/$SLUG"

    mkdir -p "$RUN_DIR"
    jq -cn '{issue: 42, phase: "plan"}' \
        | EMERGENT_CORRELATION_ID="$ENVELOPE_CID" \
            FAKE_ENGINE_ENV_FILE="$ENV_FILE" \
            FAKE_ENGINE_RUN_DIR="$RUN_DIR" \
            SIGNALBOX_RUN_SLUG="$SLUG" \
            PATH="$FAKE_BIN:$PATH" \
            "$ROOT/bin/phase-run.sh" >"$OUTPUT_FILE" 2>"$STDERR_FILE"
}

# 6. The phase runner hands its own envelope id to the child engine, on the
# variable the child's exec-source reads.
VALID_OUTPUT="$FIXTURE_ROOT/phase-valid.json"
VALID_ENV="$FIXTURE_ROOT/phase-valid-env.json"
run_phase_case \
    "$VALID_PHASE_SLUG" "$EXPECTED_CID" "$VALID_OUTPUT" "$VALID_ENV" \
    "$FIXTURE_ROOT/phase-valid.stderr"
VALID_STATUS=$?
OK=1
if [ "$VALID_STATUS" -eq 0 ] \
    && jq -e \
        --arg cid "$EXPECTED_CID" \
        --arg slug "$VALID_PHASE_SLUG" \
        '.correlation_id == $cid and .issue == "42" and .run_slug == $slug' \
        "$VALID_ENV" >/dev/null 2>&1 \
    && jq -e \
        'has("correlation_id") | not' "$VALID_OUTPUT" >/dev/null 2>&1 \
    && jq -e \
        '.outcome == "ARTIFACT" and (.log | type == "string" and length > 0)' \
        "$VALID_OUTPUT" >/dev/null 2>&1; then
    OK=0
fi
report_case "phase runner hands its envelope id to the child engine" "$OK" \
    "status=$VALID_STATUS env=$(head -c 200 "$VALID_ENV" 2>/dev/null) done=$(head -c 200 "$VALID_OUTPUT" 2>/dev/null)"

# 7. A malformed envelope value reaches the child empty, so the child's
# exec-source mints its own rather than adopting a value the store never saw.
INVALID_OUTPUT="$FIXTURE_ROOT/phase-malformed.json"
INVALID_ENV="$FIXTURE_ROOT/phase-malformed-env.json"
run_phase_case \
    "$MALFORMED_PHASE_SLUG" "pipe 42" "$INVALID_OUTPUT" "$INVALID_ENV" \
    "$FIXTURE_ROOT/phase-malformed.stderr"
INVALID_STATUS=$?
OK=1
if [ "$INVALID_STATUS" -eq 0 ] \
    && jq -e \
        --arg slug "$MALFORMED_PHASE_SLUG" \
        '.correlation_id == "" and .issue == "42" and .run_slug == $slug' \
        "$INVALID_ENV" >/dev/null 2>&1; then
    OK=0
fi
report_case "phase runner clears a malformed id before child launch" "$OK" \
    "status=$INVALID_STATUS env=$(head -c 200 "$INVALID_ENV" 2>/dev/null)"

# 8. End to end against the real fabric: exec-source mints, exec-handler
# forwards, the command sees the same value, and the event store records it on
# the envelope of every message.
E2E_NAME="source-to-handler trail lands on the envelope"
if ! command -v emergent >/dev/null 2>&1; then
    report_skip "$E2E_NAME" "emergent engine not installed"
elif [ ! -x "$PRIMITIVES/exec-source" ] || [ ! -x "$PRIMITIVES/exec-handler" ]; then
    report_skip "$E2E_NAME" "exec primitives not installed"
else
    E2E_DIR="$FIXTURE_ROOT/e2e"
    mkdir -p "$E2E_DIR/logs"
    # Quoted heredoc: the shell must not touch $EMERGENT_CORRELATION_ID, and
    # TOML rejects a backslash before it. Paths go in afterwards.
    cat >"$FIXTURE_ROOT/e2e.toml.in" <<'E2EEOF'
[engine]
name = "__NAME__"
socket_path = "auto"
api_port = 0

[event_store]
json_log_dir = "__DIR__/logs"
sqlite_path = "__DIR__/events.db"
retention_days = 1

[[sources]]
name = "seed"
path = "__PRIMITIVES__/exec-source"
args = ["--correlate", "--shell", "sh", "--command", "jq -nc --arg c \"$EMERGENT_CORRELATION_ID\" '{from_command: $c}'"]
publishes = ["trail.seed"]

[[handlers]]
name = "hop"
path = "__PRIMITIVES__/exec-handler"
args = ["-s", "trail.seed", "--publish-as", "trail.hop", "--", "sh", "-c", "jq -c --arg c \"$EMERGENT_CORRELATION_ID\" '.stdout | fromjson | . + {from_handler: $c}'"]
subscribes = ["trail.seed"]
publishes = ["trail.hop"]
E2EEOF
    sed -e "s|__NAME__|signalbox-correlation-test-$$|g" \
        -e "s|__DIR__|$E2E_DIR|g" \
        -e "s|__PRIMITIVES__|$PRIMITIVES|g" \
        "$FIXTURE_ROOT/e2e.toml.in" >"$E2E_DIR/emergent.toml"

    timeout 25 emergent --config "$E2E_DIR/emergent.toml" \
        >"$E2E_DIR/engine.log" 2>&1
    E2E_TRAIL="$(
        cat "$E2E_DIR"/logs/events-*.jsonl 2>/dev/null \
            | jq -Rr 'fromjson? // empty
                      | select(.message.message_type == "trail.hop")
                      | [.message.correlation_id,
                         .message.payload.from_command,
                         .message.payload.from_handler] | @tsv'
    )"
    ENVELOPE_CID="$(cut -f1 <<<"$E2E_TRAIL")"
    COMMAND_CID="$(cut -f2 <<<"$E2E_TRAIL")"
    HANDLER_CID="$(cut -f3 <<<"$E2E_TRAIL")"
    OK=1
    if [[ "$ENVELOPE_CID" =~ ^cor_[0-9a-hjkmnp-tv-z]{26}$ ]] \
        && [ "$COMMAND_CID" = "$ENVELOPE_CID" ] \
        && [ "$HANDLER_CID" = "$ENVELOPE_CID" ]; then
        OK=0
    fi
    report_case "$E2E_NAME" "$OK" \
        "envelope=$ENVELOPE_CID command=$COMMAND_CID handler=$HANDLER_CID"
fi

printf '%d/%d cases passed\n' "$TESTS_PASSED" "$TESTS_RUN"
[ "$TESTS_PASSED" -eq "$TESTS_RUN" ]
