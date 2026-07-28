#!/usr/bin/env bash
# Self-contained test runner for review correlation-id minting, topology
# pass-through, and pipeline-to-phase propagation. No framework and no
# dependencies beyond coreutils, git, jq, and python3 (tomllib); every fixture
# lives under mktemp -d and every run directory uses a unique test-only slug.
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

EXPECTED_CID="pipe-42-20260727-231704"

# 1. A pipeline id is inherited byte-for-byte by the review seed.
INHERITED_OUTPUT="$(
    SIGNALBOX_RUN_SLUG="$SEED_SLUG" \
        SIGNALBOX_CORRELATION_ID="$EXPECTED_CID" \
        "$ROOT/bin/seed.sh" 2>"$FIXTURE_ROOT/seed-inherited.stderr"
)"
INHERITED_STATUS=$?
INHERITED_CID="$(jq -r '.correlation_id // empty' <<<"$INHERITED_OUTPUT" 2>/dev/null)"
OK=1
if [ "$INHERITED_STATUS" -eq 0 ] && [ "$INHERITED_CID" = "$EXPECTED_CID" ]; then
    OK=0
fi
report_case "review seed inherits the pipeline correlation id" "$OK" \
    "status=$INHERITED_STATUS id=$INHERITED_CID"

# 2. Without a parent id the review seed mints a UTC-stamped id.
UTC_BEFORE="$(date -u +%Y%m%d-%H%M%S)"
MINTED_OUTPUT="$(
    env -u SIGNALBOX_CORRELATION_ID \
        SIGNALBOX_RUN_SLUG="$SEED_SLUG" \
        "$ROOT/bin/seed.sh" 2>"$FIXTURE_ROOT/seed-minted.stderr"
)"
MINTED_STATUS=$?
UTC_AFTER="$(date -u +%Y%m%d-%H%M%S)"
MINTED_CID="$(jq -r '.correlation_id // empty' <<<"$MINTED_OUTPUT" 2>/dev/null)"
MINTED_STAMP="${MINTED_CID: -15}"
OK=1
if [ "$MINTED_STATUS" -eq 0 ] \
    && [[ "$MINTED_CID" =~ ^review-[A-Za-z0-9._-]+-[0-9]{8}-[0-9]{6}$ ]] \
    && { [ "$MINTED_STAMP" = "$UTC_BEFORE" ] \
        || [ "$MINTED_STAMP" = "$UTC_AFTER" ]; }; then
    OK=0
fi
report_case "review seed mints a UTC-stamped correlation id" "$OK" \
    "status=$MINTED_STATUS before=$UTC_BEFORE id=$MINTED_CID after=$UTC_AFTER"

# 3. A non-UTC local timezone cannot change the minted UTC stamp.
CHICAGO_BEFORE="$(date -u +%Y%m%d-%H%M%S)"
CHICAGO_OUTPUT="$(
    env -u SIGNALBOX_CORRELATION_ID \
        TZ=America/Chicago SIGNALBOX_RUN_SLUG="$SEED_SLUG" \
        "$ROOT/bin/seed.sh" 2>"$FIXTURE_ROOT/seed-chicago.stderr"
)"
CHICAGO_STATUS=$?
CHICAGO_AFTER="$(date -u +%Y%m%d-%H%M%S)"
CHICAGO_CID="$(jq -r '.correlation_id // empty' <<<"$CHICAGO_OUTPUT" 2>/dev/null)"
CHICAGO_STAMP="${CHICAGO_CID: -15}"
OK=1
if [ "$CHICAGO_STATUS" -eq 0 ] \
    && [[ "$CHICAGO_CID" =~ ^review-[A-Za-z0-9._-]+-[0-9]{8}-[0-9]{6}$ ]] \
    && { [ "$CHICAGO_STAMP" = "$CHICAGO_BEFORE" ] \
        || [ "$CHICAGO_STAMP" = "$CHICAGO_AFTER" ]; }; then
    OK=0
fi
report_case "review seed stays on UTC under America/Chicago" "$OK" \
    "status=$CHICAGO_STATUS before=$CHICAGO_BEFORE id=$CHICAGO_CID after=$CHICAGO_AFTER"

# 4. A malformed inherited id falls back to a newly minted review id.
MALFORMED_OUTPUT="$(
    SIGNALBOX_RUN_SLUG="$SEED_SLUG" \
        SIGNALBOX_CORRELATION_ID="bad id" \
        "$ROOT/bin/seed.sh" 2>"$FIXTURE_ROOT/seed-malformed.stderr"
)"
MALFORMED_STATUS=$?
MALFORMED_CID="$(jq -r '.correlation_id // empty' <<<"$MALFORMED_OUTPUT" 2>/dev/null)"
OK=1
if [ "$MALFORMED_STATUS" -eq 0 ] \
    && [ "$MALFORMED_CID" != "bad id" ] \
    && [[ "$MALFORMED_CID" =~ ^review-[A-Za-z0-9._-]+-[0-9]{8}-[0-9]{6}$ ]]; then
    OK=0
fi
report_case "review seed replaces a malformed inherited id" "$OK" \
    "status=$MALFORMED_STATUS id=$MALFORMED_CID"

# 5. Load unwrap-seed from TOML and prove it only unwraps the seed envelope.
UNWRAP_PROGRAM="$(
    python3 - "$ROOT/emergent.toml" 2>"$FIXTURE_ROOT/tomllib.stderr" <<'PYEOF'
import sys
import tomllib

with open(sys.argv[1], "rb") as stream:
    topology = tomllib.load(stream)

handler = next(
    item for item in topology.get("handlers", [])
    if item.get("name") == "unwrap-seed"
)
print(handler["args"][-1])
PYEOF
)"
TOML_STATUS=$?
SEED_JSON="$(
    jq -cn --arg cid "$EXPECTED_CID" \
        '{feature: "fixture", workdir: "/tmp/fixture", round: 1,
          feedback: "", correlation_id: $cid}'
)"
ENVELOPE="$(jq -cn --arg stdout "$SEED_JSON" '{stdout: $stdout}')"
UNWRAPPED="$(jq -c "$UNWRAP_PROGRAM" <<<"$ENVELOPE" 2>"$FIXTURE_ROOT/unwrap.stderr")"
UNWRAP_STATUS=$?
UNWRAPPED_CID="$(jq -r '.correlation_id // empty' <<<"$UNWRAPPED" 2>/dev/null)"
OK=1
if [ "$TOML_STATUS" -eq 0 ] \
    && [ "$UNWRAP_STATUS" -eq 0 ] \
    && [ "$UNWRAPPED_CID" = "$EXPECTED_CID" ] \
    && [[ "$UNWRAP_PROGRAM" != *now* ]] \
    && [[ "$UNWRAP_PROGRAM" != *strftime* ]]; then
    OK=0
fi
report_case "unwrap-seed passes the id through without minting" "$OK" \
    "toml=$TOML_STATUS jq=$UNWRAP_STATUS id=$UNWRAPPED_CID program=$UNWRAP_PROGRAM"

FAKE_BIN="$FIXTURE_ROOT/bin"
mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/emergent" <<'FAKEEOF'
#!/usr/bin/env bash
set -euo pipefail

jq -n \
    --arg correlation_id "${SIGNALBOX_CORRELATION_ID-}" \
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
    local PAYLOAD_CID="$2"
    local OUTPUT_FILE="$3"
    local ENV_FILE="$4"
    local STDERR_FILE="$5"
    local RUN_DIR="$ROOT/runs/$SLUG"

    mkdir -p "$RUN_DIR"
    printf '%s' "$(
        jq -cn --arg cid "$PAYLOAD_CID" \
            '{issue: 42, phase: "plan", correlation_id: $cid}'
    )" \
        | FAKE_ENGINE_ENV_FILE="$ENV_FILE" \
            FAKE_ENGINE_RUN_DIR="$RUN_DIR" \
            SIGNALBOX_RUN_SLUG="$SLUG" \
            PATH="$FAKE_BIN:$PATH" \
            "$ROOT/bin/phase-run.sh" >"$OUTPUT_FILE" 2>"$STDERR_FILE"
}

# 6. A valid phase.request id reaches the child engine and phase.done unchanged.
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
        --arg cid "$EXPECTED_CID" \
        '.correlation_id == $cid
         and .outcome == "ARTIFACT"
         and (.log | type == "string" and length > 0)' \
        "$VALID_OUTPUT" >/dev/null 2>&1; then
    OK=0
fi
report_case "phase runner propagates the pipeline id to its child" "$OK" \
    "status=$VALID_STATUS env=$(head -c 200 "$VALID_ENV" 2>/dev/null) done=$(head -c 200 "$VALID_OUTPUT" 2>/dev/null)"

# 7. A malformed payload id reaches the child as the empty mint-own signal.
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
        "$INVALID_ENV" >/dev/null 2>&1 \
    && jq -e \
        '.correlation_id == "pipe 42"
         and .outcome == "ARTIFACT"
         and (.log | type == "string" and length > 0)' \
        "$INVALID_OUTPUT" >/dev/null 2>&1; then
    OK=0
fi
report_case "phase runner clears a malformed id before child launch" "$OK" \
    "status=$INVALID_STATUS env=$(head -c 200 "$INVALID_ENV" 2>/dev/null) done=$(head -c 200 "$INVALID_OUTPUT" 2>/dev/null)"

printf '%d/%d cases passed\n' "$TESTS_PASSED" "$TESTS_RUN"
[ "$TESTS_PASSED" -eq "$TESTS_RUN" ]
