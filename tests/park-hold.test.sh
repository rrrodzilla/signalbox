#!/usr/bin/env bash
# Self-contained regression runner for the phase-runner park handoff, approval
# port-lease lifetime, and approval-request narration. No framework; every
# fixture lives under one mktemp -d, no real registry or network service is
# used, and cleanup targets only PIDs created by this file.
# Prints PASS/FAIL/SKIP per case and exits non-zero when any case fails.
#
# Deliberately no -e: cases must capture non-zero subject statuses. Fixture
# creation and setup are checked explicitly with fatal, so a broken fixture
# can never pass as an empty success.
set -uo pipefail

fatal() {
    printf 'FATAL %s\n' "$1" >&2
    exit 1
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

skip_all() {
    local REASON="$1" NAME
    local -a NAMES=(
        "phase runner emits one parked phase.done"
        "parked phase runner leaves engine alive"
        "park record describes held approval window"
        "park handoff preserves pid file and starts reaper"
        "park reaper exits and removes pid file"
        "review artifact keeps deferred behavior without park record"
        "dead engine declines park handoff"
        "non-review phase never writes park record"
        "lease transfer preserves port and records holder identity"
        "lease transfer rejects invalid invocation"
        "lease transfer rejects missing lease or dead target"
        "lease release preserves a foreign live holder"
        "lease release removes caller-owned or dead entries"
        "new lease reaps an exited transferred holder"
        "approval sink preserves pending payload"
        "approval narration states live webhook hold"
    )

    for NAME in "${NAMES[@]}"; do
        printf 'SKIP %s — %s\n' "$NAME" "$REASON"
        TESTS_RUN=$((TESTS_RUN + 1))
        TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
    done
    printf '%d/%d cases passed (%d skipped)\n' \
        "$TESTS_PASSED" "$TESTS_RUN" "$TESTS_SKIPPED"
    exit 0
}

process_running() {
    local PID_VALUE="$1" STATE_VALUE=""

    [[ "$PID_VALUE" =~ ^[1-9][0-9]*$ ]] || return 1
    kill -0 "$PID_VALUE" 2>/dev/null || return 1
    STATE_VALUE="$(
        awk '{ sub(/^.*\) /, ""); print $1 }' \
            "/proc/$PID_VALUE/stat" 2>/dev/null || true
    )"
    [ "$STATE_VALUE" != "Z" ]
}

await_file() {
    local FILE_VALUE="$1" ATTEMPT

    for ATTEMPT in {1..250}; do
        [ -s "$FILE_VALUE" ] && return 0
        /bin/sleep 0.02
    done
    return 1
}

await_runner_poll() {
    local RUNNER_PID="$1" ENGINE_PID="$2" ATTEMPT CHILD_PID COMM_VALUE
    local CHILDREN_FILE="/proc/$RUNNER_PID/task/$RUNNER_PID/children"

    for ATTEMPT in {1..300}; do
        if ! process_running "$RUNNER_PID"; then
            return 1
        fi
        if [ -r "$CHILDREN_FILE" ]; then
            for CHILD_PID in $(<"$CHILDREN_FILE"); do
                [ "$CHILD_PID" != "$ENGINE_PID" ] || continue
                COMM_VALUE=""
                IFS= read -r COMM_VALUE \
                    <"/proc/$CHILD_PID/comm" 2>/dev/null || true
                if [ "$COMM_VALUE" = "sleep" ]; then
                    return 0
                fi
            done
        fi
        /bin/sleep 0.02
    done
    return 1
}

await_process_exit() {
    local PID_VALUE="$1" ATTEMPT

    for ATTEMPT in {1..400}; do
        process_running "$PID_VALUE" || return 0
        /bin/sleep 0.025
    done
    return 1
}

track_pid() {
    local PID_VALUE="$1"

    [ -n "$PID_VALUE" ] && CREATED_PIDS+=("$PID_VALUE")
}

untrack_pid() {
    local PID_VALUE="$1" INDEX

    for INDEX in "${!CREATED_PIDS[@]}"; do
        if [ "${CREATED_PIDS[$INDEX]}" = "$PID_VALUE" ]; then
            CREATED_PIDS[$INDEX]=""
        fi
    done
}

stop_created_pid() {
    local PID_VALUE="$1"

    [ -n "$PID_VALUE" ] || return 0
    kill -TERM "$PID_VALUE" 2>/dev/null || true
    wait "$PID_VALUE" 2>/dev/null || true
    untrack_pid "$PID_VALUE"
}

fixture_identity() {
    local PID_VALUE="$1"

    bash -c 'source "$1"; proc_identity "$2"' \
        fixture "$HARNESS/bin/_liveness.sh" "$PID_VALUE"
}

write_lease() {
    local SLUG_VALUE="$1" BASE_VALUE="$2" PID_VALUE="$3" START_VALUE="$4"
    local KEY_VALUE="$REPO_NAME/$SLUG_VALUE"
    local TEMP_VALUE="$LEASE_REGISTRY.tmp.$$"

    jq \
        --arg key "$KEY_VALUE" \
        --argjson base "$BASE_VALUE" \
        --argjson pid "$PID_VALUE" \
        --arg start "$START_VALUE" \
        '.[$key] = {
            base: $base,
            pid: $pid,
            start: $start,
            ts: "2026-07-27T00:00:00Z"
        }' "$LEASE_REGISTRY" >"$TEMP_VALUE" \
        || fatal "lease fixture could not be written for $SLUG_VALUE"
    mv "$TEMP_VALUE" "$LEASE_REGISTRY" \
        || fatal "lease fixture could not be installed for $SLUG_VALUE"
}

lease_exists() {
    local SLUG_VALUE="$1"

    jq -e --arg key "$REPO_NAME/$SLUG_VALUE" 'has($key)' \
        "$LEASE_REGISTRY" >/dev/null 2>&1
}

run_ports() {
    local LABEL="$1"
    shift

    PORT_OUT="$FIX/ports-$LABEL.stdout"
    PORT_ERR="$FIX/ports-$LABEL.stderr"
    HOME="$FIX_HOME" \
        SIGNALBOX_LEASE_REGISTRY="$LEASE_REGISTRY" \
        SIGNALBOX_LEASE_PID="${PORT_CALLER_PID:-$$}" \
        "$PORTS_SUBJECT" "$@" >"$PORT_OUT" 2>"$PORT_ERR"
    PORT_STATUS=$?
}

start_holder() {
    local LIFETIME_VALUE="${1:-60}"

    sleep "$LIFETIME_VALUE" &
    HOLDER_PID=$!
    track_pid "$HOLDER_PID"
    HOLDER_START="$(fixture_identity "$HOLDER_PID")" \
        || fatal "holder identity could not be read for pid $HOLDER_PID"
}

start_phase() {
    local SLUG_VALUE="$1" PHASE_VALUE="$2" LIFETIME_VALUE="$3"
    local DEAD_HANDOFF_VALUE="${4:-0}"
    local CASE_DIR="$FIX/phase-$SLUG_VALUE"
    local RUN_PATH="$HARNESS/runs/$SLUG_VALUE"
    local PAYLOAD

    mkdir -p "$CASE_DIR" "$RUN_PATH/state" "$RUN_PATH/logs" "$RUN_PATH/results" \
        || fatal "phase fixture could not be created for $SLUG_VALUE"
    touch -d '2 seconds ago' "$RUN_PATH/state/pipeline-$PHASE_VALUE.stamp" \
        || fatal "phase stamp could not be created for $SLUG_VALUE"

    PHASE_OUT="$CASE_DIR/stdout"
    PHASE_ERR="$CASE_DIR/stderr"
    PHASE_REAPER_FILE="$CASE_DIR/reaper.pid"
    PHASE_RUN_DIR="$RUN_PATH"
    PHASE_PID_FILE="$RUN_PATH/state/phase-$PHASE_VALUE.pid"
    PAYLOAD="$(jq -cn --arg phase "$PHASE_VALUE" \
        '{issue: 44, phase: $phase}')" \
        || fatal "phase payload could not be built for $SLUG_VALUE"

    if [ "$DEAD_HANDOFF_VALUE" -eq 1 ]; then
        printf '%s\n' "$PAYLOAD" \
            | HOME="$FIX_HOME" \
                PATH="$STUB_BIN:$PATH" \
                BASH_ENV="$KILL_SEAM" \
                EMERGENT_CORRELATION_ID="$VALID_CID" \
                SIGNALBOX_RUN_SLUG="$SLUG_VALUE" \
                SIGNALBOX_APPROVAL_PORT="$APPROVAL_PORT" \
                SIGNALBOX_LEASE_REGISTRY="$LEASE_REGISTRY" \
                SIGNALBOX_PARK_GRACE=6 \
                SIGNALBOX_REAPER_PID_FILE="$PHASE_REAPER_FILE" \
                SIGNALBOX_TEST_DEAD_PARK=1 \
                SIGNALBOX_TEST_PENDING="$RUN_PATH/state/pending.json" \
                SIGNALBOX_TEST_ENGINE_LIFETIME="$LIFETIME_VALUE" \
                "$PHASE_SUBJECT" >"$PHASE_OUT" 2>"$PHASE_ERR" &
    else
        printf '%s\n' "$PAYLOAD" \
            | env -u BASH_ENV \
                HOME="$FIX_HOME" \
                PATH="$STUB_BIN:$PATH" \
                EMERGENT_CORRELATION_ID="$VALID_CID" \
                SIGNALBOX_RUN_SLUG="$SLUG_VALUE" \
                SIGNALBOX_APPROVAL_PORT="$APPROVAL_PORT" \
                SIGNALBOX_LEASE_REGISTRY="$LEASE_REGISTRY" \
                SIGNALBOX_PARK_GRACE=6 \
                SIGNALBOX_REAPER_PID_FILE="$PHASE_REAPER_FILE" \
                SIGNALBOX_TEST_ENGINE_LIFETIME="$LIFETIME_VALUE" \
                "$PHASE_SUBJECT" >"$PHASE_OUT" 2>"$PHASE_ERR" &
    fi
    PHASE_RUNNER_PID=$!
    track_pid "$PHASE_RUNNER_PID"
    await_file "$PHASE_PID_FILE" \
        || fatal "phase runner did not record its engine pid for $SLUG_VALUE"
    PHASE_ENGINE_PID="$(head -n 1 "$PHASE_PID_FILE" 2>/dev/null || true)"
    [[ "$PHASE_ENGINE_PID" =~ ^[1-9][0-9]*$ ]] \
        || fatal "phase runner recorded an invalid engine pid for $SLUG_VALUE"
    track_pid "$PHASE_ENGINE_PID"
    await_runner_poll "$PHASE_RUNNER_PID" "$PHASE_ENGINE_PID" \
        || fatal "phase runner did not enter its bounded artifact poll for $SLUG_VALUE"
}

finish_phase() {
    wait "$PHASE_RUNNER_PID" 2>/dev/null
    PHASE_STATUS=$?
    untrack_pid "$PHASE_RUNNER_PID"

    PHASE_REAPER_PID=""
    if await_file "$PHASE_REAPER_FILE"; then
        PHASE_REAPER_PID="$(
            head -n 1 "$PHASE_REAPER_FILE" 2>/dev/null || true
        )"
        [[ "$PHASE_REAPER_PID" =~ ^[1-9][0-9]*$ ]] \
            && track_pid "$PHASE_REAPER_PID"
    fi
}

cleanup() {
    local PID_VALUE

    trap - EXIT
    for PID_VALUE in "${CREATED_PIDS[@]}"; do
        [ -n "$PID_VALUE" ] || continue
        kill -TERM "$PID_VALUE" 2>/dev/null || true
    done
    for PID_VALUE in "${CREATED_PIDS[@]}"; do
        [ -n "$PID_VALUE" ] || continue
        wait "$PID_VALUE" 2>/dev/null || true
    done
    rm -rf -- "$FIX"
}
trap cleanup EXIT

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" \
    || fatal 'the repository root could not be resolved'
FIX="$(mktemp -d "${TMPDIR:-/tmp}/signalbox-park-hold.XXXXXX")" \
    || fatal 'a fixture directory could not be created'
[ -n "$FIX" ] && [ -d "$FIX" ] \
    || fatal 'mktemp -d produced no usable fixture directory'
HARNESS="$FIX/harness"
STUB_BIN="$FIX/stub-bin"
FIX_HOME="$FIX/home"
LEASE_REGISTRY="$FIX/leases.json"
PHASE_SUBJECT="$HARNESS/bin/phase-run.sh"
PORTS_SUBJECT="$HARNESS/bin/ports.sh"
NOTIFY_SUBJECT="$HARNESS/bin/notify.sh"
KILL_SEAM="$FIX/kill-seam.sh"
REPO_NAME="$(basename "$HARNESS")"
APPROVAL_PORT=8765
VALID_CID="cor_0123456789abcdefghjkmnpqrs"
CREATED_PIDS=()
TESTS_RUN=0
TESTS_PASSED=0
TESTS_SKIPPED=0
PORT_STATUS=0
PORT_CALLER_PID=""
PORT_OUT=""
PORT_ERR=""

for REQUIRED in jq flock setsid awk; do
    if ! command -v "$REQUIRED" >/dev/null 2>&1; then
        skip_all "$REQUIRED is unavailable"
    fi
done
if [ ! -r /proc/stat ]; then
    skip_all "/proc process identity is unavailable"
fi

mkdir -p "$HARNESS" "$STUB_BIN" "$FIX_HOME" \
    || fatal 'fixture harness directories could not be created'
cp -r "$ROOT/bin" "$HARNESS/" \
    || fatal 'bin/ could not be copied into the fixture harness'
[ -x "$PHASE_SUBJECT" ] || fatal 'the fixture phase runner is missing'
[ -x "$PORTS_SUBJECT" ] || fatal 'the fixture ports utility is missing'
[ -x "$NOTIFY_SUBJECT" ] || fatal 'the fixture approval sink is missing'

mv "$HARNESS/bin/engine-reaper.sh" "$HARNESS/bin/engine-reaper-real.sh" \
    || fatal 'the fixture reaper could not be wrapped'
cat >"$HARNESS/bin/engine-reaper.sh" <<'REAPER'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$$" >"$SIGNALBOX_REAPER_PID_FILE"
exec "$(dirname "${BASH_SOURCE[0]}")/engine-reaper-real.sh" "$@"
REAPER
chmod +x "$HARNESS/bin/engine-reaper.sh" \
    || fatal 'the fixture reaper wrapper could not be made executable'

cat >"$STUB_BIN/emergent" <<'ENGINE'
#!/usr/bin/env bash
set -euo pipefail
exec sleep "${SIGNALBOX_TEST_ENGINE_LIFETIME:?missing fake-engine lifetime}"
ENGINE
chmod +x "$STUB_BIN/emergent" \
    || fatal 'the fake engine could not be made executable'

# A park can settle between two liveness probes: the loop observes a live
# engine and fresh pending artifact, then the handoff probe finds that engine
# gone. This BASH_ENV seam makes that transition deterministic only for the
# declined-handoff case. It lets the first probe made after pending exists
# succeed, then bounded-polls until the fake engine reaches its own natural
# exit before answering the handoff probe.
cat >"$KILL_SEAM" <<'KILLSEAM'
kill() {
    local DEADLINE_VALUE

    if [ "${SIGNALBOX_TEST_DEAD_PARK:-0}" = 1 ] \
        && [ "${1:-}" = "-0" ] \
        && [ -f "${SIGNALBOX_TEST_PENDING:-/nonexistent}" ]; then
        if [ "${SIGNALBOX_TEST_PENDING_PROBED:-0}" -eq 0 ]; then
            SIGNALBOX_TEST_PENDING_PROBED=1
            builtin kill "$@"
            return
        fi
        DEADLINE_VALUE=$((SECONDS + 4))
        while builtin kill "$@" 2>/dev/null; do
            [ "$SECONDS" -lt "$DEADLINE_VALUE" ] || break
            /bin/sleep 0.02
        done
    fi
    builtin kill "$@"
}
KILLSEAM

jq -n '{}' >"$LEASE_REGISTRY" \
    || fatal 'the isolated lease registry could not be initialized'

# A1-A5. A pending review terminal transfers ownership instead of stopping the
# webhook engine the runner just advertised.
SLUG="phase-review-park"
SHELL_START="$(fixture_identity "$$")" \
    || fatal 'the test runner process identity could not be read'
write_lease "$SLUG" "$APPROVAL_PORT" "$$" "$SHELL_START"
start_phase "$SLUG" review 7
printf '%s\n' '{"decision":"human","action":"promote"}' \
    >"$PHASE_RUN_DIR/state/pending.json" \
    || fatal 'the live park pending artifact could not be written'
finish_phase

OK=1
if [ "$PHASE_STATUS" -eq 0 ] \
    && jq -s -e '
        length == 1
        and (.[0] | type) == "object"
        and .[0].issue == 44
        and .[0].phase == "review"
        and .[0].outcome == "PARKED"
        and (.[0].log | type) == "string"
    ' "$PHASE_OUT" >/dev/null 2>&1; then
    OK=0
fi
report_case "phase runner emits one parked phase.done" "$OK" \
    "status=$PHASE_STATUS stdout=$(head -c 240 "$PHASE_OUT" 2>/dev/null)"

OK=1
if process_running "$PHASE_ENGINE_PID"; then
    OK=0
fi
report_case "parked phase runner leaves engine alive" "$OK" \
    "engine_pid=$PHASE_ENGINE_PID stderr=$(head -c 240 "$PHASE_ERR" 2>/dev/null)"

OK=1
if jq -e \
    --argjson pid "$PHASE_ENGINE_PID" \
    --argjson port "$APPROVAL_PORT" \
    '
        .held == true
        and .issue == 44
        and .phase == "review"
        and .holder == "phase-run"
        and .pid == $pid
        and .port == $port
        and (.approve_url | type == "string" and length > 0)
        and (.approve_command | type == "string" and length > 0)
        and .deadline == 6
        and (.start_id | type == "string" and length > 0)
        and .lease_transferred == true
        and .reason == null
    ' "$PHASE_RUN_DIR/state/park.json" >/dev/null 2>&1; then
    OK=0
fi
report_case "park record describes held approval window" "$OK" \
    "record=$(jq -c . "$PHASE_RUN_DIR/state/park.json" 2>/dev/null)"

OK=1
if [ "$(head -n 1 "$PHASE_PID_FILE" 2>/dev/null || true)" = "$PHASE_ENGINE_PID" ] \
    && [[ "$PHASE_REAPER_PID" =~ ^[1-9][0-9]*$ ]] \
    && process_running "$PHASE_REAPER_PID"; then
    OK=0
fi
report_case "park handoff preserves pid file and starts reaper" "$OK" \
    "engine=$PHASE_ENGINE_PID reaper=$PHASE_REAPER_PID"

await_process_exit "$PHASE_ENGINE_PID"
ENGINE_EXIT_STATUS=$?
await_process_exit "$PHASE_REAPER_PID"
REAPER_EXIT_STATUS=$?
untrack_pid "$PHASE_ENGINE_PID"
untrack_pid "$PHASE_REAPER_PID"
OK=1
if [ "$ENGINE_EXIT_STATUS" -eq 0 ] \
    && [ "$REAPER_EXIT_STATUS" -eq 0 ] \
    && [ ! -e "$PHASE_PID_FILE" ]; then
    OK=0
fi
report_case "park reaper exits and removes pid file" "$OK" \
    "engine_exit=$ENGINE_EXIT_STATUS reaper_exit=$REAPER_EXIT_STATUS pid_file=$([ -e "$PHASE_PID_FILE" ] && printf present || printf absent)"

# A6. The pre-existing review-artifact handoff remains a deferred reaper path
# when docs-sync has not landed, and it never creates park evidence.
SLUG="phase-review-artifact"
start_phase "$SLUG" review 7
printf '# CR\ncorrelation_id: fixture-review\nPROMOTION_READY\n' \
    >"$PHASE_RUN_DIR/results/CR.md" \
    || fatal 'the review artifact could not be written'
finish_phase
ARTIFACT_REAPER_PID="$PHASE_REAPER_PID"
ARTIFACT_ENGINE_PID="$PHASE_ENGINE_PID"
await_process_exit "$ARTIFACT_ENGINE_PID"
ARTIFACT_ENGINE_EXIT=$?
await_process_exit "$ARTIFACT_REAPER_PID"
ARTIFACT_REAPER_EXIT=$?
untrack_pid "$ARTIFACT_ENGINE_PID"
untrack_pid "$ARTIFACT_REAPER_PID"
OK=1
if [ "$PHASE_STATUS" -eq 0 ] \
    && jq -s -e 'length == 1 and .[0].outcome == "ARTIFACT"' \
        "$PHASE_OUT" >/dev/null 2>&1 \
    && [ ! -e "$PHASE_RUN_DIR/state/park.json" ] \
    && [ "$ARTIFACT_ENGINE_EXIT" -eq 0 ] \
    && [ "$ARTIFACT_REAPER_EXIT" -eq 0 ] \
    && [ ! -e "$PHASE_PID_FILE" ]; then
    OK=0
fi
report_case "review artifact keeps deferred behavior without park record" "$OK" \
    "status=$PHASE_STATUS engine_exit=$ARTIFACT_ENGINE_EXIT reaper_exit=$ARTIFACT_REAPER_EXIT"

# A7. If the engine naturally exits after pending is observed but before
# ownership can move, the phase result stays PARKED and park.json closes the
# advertised approval window explicitly.
SLUG="phase-review-dead"
write_lease "$SLUG" "$APPROVAL_PORT" "$$" "$SHELL_START"
start_phase "$SLUG" review 7 1
printf '%s\n' '{"decision":"human","action":"promote"}' \
    >"$PHASE_RUN_DIR/state/pending.json" \
    || fatal 'the declined park pending artifact could not be written'
finish_phase
untrack_pid "$PHASE_ENGINE_PID"
OK=1
if [ "$PHASE_STATUS" -eq 0 ] \
    && jq -s -e 'length == 1 and .[0].outcome == "PARKED"' \
        "$PHASE_OUT" >/dev/null 2>&1 \
    && jq -e '
        .held == false
        and .pid == null
        and .start_id == null
        and .deadline == null
        and .lease_transferred == false
        and (.reason | type == "string" and length > 0)
    ' "$PHASE_RUN_DIR/state/park.json" >/dev/null 2>&1 \
    && [ ! -e "$PHASE_PID_FILE" ] \
    && [ ! -e "$PHASE_REAPER_FILE" ]; then
    OK=0
fi
report_case "dead engine declines park handoff" "$OK" \
    "status=$PHASE_STATUS record=$(jq -c . "$PHASE_RUN_DIR/state/park.json" 2>/dev/null)"

# A8. Park metadata is review-only.
SLUG="phase-plan-artifact"
start_phase "$SLUG" plan 7
jq -n '{feature: "fixture", stages: []}' >"$PHASE_RUN_DIR/plan.json" \
    || fatal 'the plan artifact could not be written'
finish_phase
await_process_exit "$PHASE_ENGINE_PID"
PLAN_ENGINE_EXIT=$?
untrack_pid "$PHASE_ENGINE_PID"
OK=1
if [ "$PHASE_STATUS" -eq 0 ] \
    && jq -s -e 'length == 1 and .[0].outcome == "ARTIFACT"' \
        "$PHASE_OUT" >/dev/null 2>&1 \
    && [ "$PLAN_ENGINE_EXIT" -eq 0 ] \
    && [ ! -e "$PHASE_RUN_DIR/state/park.json" ]; then
    OK=0
fi
report_case "non-review phase never writes park record" "$OK" \
    "status=$PHASE_STATUS stderr=$(head -c 240 "$PHASE_ERR" 2>/dev/null)"

# B1. transfer keeps the existing port and records the target's exact process
# identity rather than allocating anything new.
start_holder
TRANSFER_HOLDER="$HOLDER_PID"
TRANSFER_START="$HOLDER_START"
SLUG="lease-transfer"
write_lease "$SLUG" 8310 "$$" "$SHELL_START"
run_ports transfer-success transfer "$SLUG" "$TRANSFER_HOLDER"
OK=1
if [ "$PORT_STATUS" -eq 0 ] \
    && [ "$(tr -d '\n' <"$PORT_OUT")" = "8310" ] \
    && jq -e \
        --arg key "$REPO_NAME/$SLUG" \
        --argjson pid "$TRANSFER_HOLDER" \
        --arg start "$TRANSFER_START" \
        '.[$key].base == 8310
         and .[$key].pid == $pid
         and .[$key].start == $start' \
        "$LEASE_REGISTRY" >/dev/null 2>&1; then
    OK=0
fi
report_case "lease transfer preserves port and records holder identity" "$OK" \
    "status=$PORT_STATUS stdout=$(head -c 80 "$PORT_OUT") registry=$(jq -c . "$LEASE_REGISTRY" 2>/dev/null)"

# B2. Invocation errors are distinct from operational transfer failures.
run_ports transfer-short transfer "$SLUG"
TRANSFER_SHORT_STATUS=$PORT_STATUS
run_ports transfer-zero transfer "$SLUG" 0
TRANSFER_ZERO_STATUS=$PORT_STATUS
run_ports transfer-negative transfer "$SLUG" -7
TRANSFER_NEGATIVE_STATUS=$PORT_STATUS
OK=1
if [ "$TRANSFER_SHORT_STATUS" -eq 64 ] \
    && [ "$TRANSFER_ZERO_STATUS" -eq 64 ] \
    && [ "$TRANSFER_NEGATIVE_STATUS" -eq 64 ]; then
    OK=0
fi
report_case "lease transfer rejects invalid invocation" "$OK" \
    "short=$TRANSFER_SHORT_STATUS zero=$TRANSFER_ZERO_STATUS negative=$TRANSFER_NEGATIVE_STATUS"

# B3. Missing source entries and dead targets are operational failures.
run_ports transfer-missing transfer lease-missing "$TRANSFER_HOLDER"
TRANSFER_MISSING_STATUS=$PORT_STATUS
start_holder
DEAD_TARGET_PID="$HOLDER_PID"
DEAD_TARGET_START="$HOLDER_START"
stop_created_pid "$DEAD_TARGET_PID"
write_lease lease-dead-target 8320 "$$" "$SHELL_START"
run_ports transfer-dead transfer lease-dead-target "$DEAD_TARGET_PID"
TRANSFER_DEAD_STATUS=$PORT_STATUS
OK=1
if [ "$TRANSFER_MISSING_STATUS" -eq 1 ] \
    && [ "$TRANSFER_DEAD_STATUS" -eq 1 ] \
    && lease_exists lease-dead-target; then
    OK=0
fi
report_case "lease transfer rejects missing lease or dead target" "$OK" \
    "missing=$TRANSFER_MISSING_STATUS dead=$TRANSFER_DEAD_STATUS dead_pid=$DEAD_TARGET_PID start=$DEAD_TARGET_START"

# B4. A launcher-style release cannot erase the live engine's transferred
# lease, even though release itself remains idempotently successful.
SLUG="lease-foreign-release"
write_lease "$SLUG" 8330 "$TRANSFER_HOLDER" "$TRANSFER_START"
PORT_CALLER_PID="$$"
run_ports release-foreign release "$SLUG"
PORT_CALLER_PID=""
OK=1
if [ "$PORT_STATUS" -eq 0 ] \
    && lease_exists "$SLUG" \
    && grep -q "live pid $TRANSFER_HOLDER" "$PORT_ERR"; then
    OK=0
fi
report_case "lease release preserves a foreign live holder" "$OK" \
    "status=$PORT_STATUS stderr=$(head -c 200 "$PORT_ERR")"

# B5. The original release behavior remains for the actual caller and for a
# recorded owner that is no longer live.
write_lease lease-owned 8340 "$$" "$SHELL_START"
PORT_CALLER_PID="$$"
run_ports release-owned release lease-owned
RELEASE_OWNED_STATUS=$PORT_STATUS
PORT_CALLER_PID=""
write_lease lease-dead 8350 "$DEAD_TARGET_PID" "$DEAD_TARGET_START"
run_ports release-dead release lease-dead
RELEASE_DEAD_STATUS=$PORT_STATUS
OK=1
if [ "$RELEASE_OWNED_STATUS" -eq 0 ] \
    && [ "$RELEASE_DEAD_STATUS" -eq 0 ] \
    && ! lease_exists lease-owned \
    && ! lease_exists lease-dead; then
    OK=0
fi
report_case "lease release removes caller-owned or dead entries" "$OK" \
    "owned=$RELEASE_OWNED_STATUS dead=$RELEASE_DEAD_STATUS"

# B6. Once a transferred holder exits, the next lease call reaps that entry
# and can assign the slug normally instead of stranding it forever.
start_holder
REAP_HOLDER="$HOLDER_PID"
REAP_START="$HOLDER_START"
SLUG="lease-reap-transferred"
write_lease "$SLUG" 8360 "$$" "$SHELL_START"
run_ports transfer-reap transfer "$SLUG" "$REAP_HOLDER"
TRANSFER_REAP_STATUS=$PORT_STATUS
stop_created_pid "$REAP_HOLDER"
PORT_CALLER_PID="$$"
run_ports lease-after-exit lease "$SLUG"
LEASE_AFTER_EXIT_STATUS=$PORT_STATUS
PORT_CALLER_PID=""
OK=1
if [ "$TRANSFER_REAP_STATUS" -eq 0 ] \
    && [ "$LEASE_AFTER_EXIT_STATUS" -eq 0 ] \
    && jq -e \
        --arg key "$REPO_NAME/$SLUG" \
        --argjson caller "$$" \
        --argjson old "$REAP_HOLDER" \
        '.[$key].pid == $caller and .[$key].pid != $old' \
        "$LEASE_REGISTRY" >/dev/null 2>&1; then
    OK=0
fi
report_case "new lease reaps an exited transferred holder" "$OK" \
    "transfer=$TRANSFER_REAP_STATUS lease=$LEASE_AFTER_EXIT_STATUS stdout=$(head -c 80 "$PORT_OUT")"
stop_created_pid "$TRANSFER_HOLDER"

# C. The approval sink persists the replay body and narrates both the concrete
# webhook command and the deliberate engine hold.
NOTIFY_SLUG="notify-park"
NOTIFY_RUN="$HARNESS/runs/$NOTIFY_SLUG"
NOTIFY_INPUT="$FIX/notify-input.json"
NOTIFY_OUT="$FIX/notify.stdout"
NOTIFY_ERR="$FIX/notify.stderr"
mkdir -p "$NOTIFY_RUN/state" \
    || fatal 'the notify fixture state directory could not be created'
jq -n \
    '{
        feature: "park-hold",
        workdir: "/fixture/integration",
        round: 2,
        verdict: "APPROVED",
        action: "promote",
        readiness: 2,
        floor: 4,
        rationale: "Human approval is required for remote promotion.",
        decision: "human"
    }' >"$NOTIFY_INPUT" \
    || fatal 'the approval payload could not be written'
HOME="$FIX_HOME" \
    SIGNALBOX_RUN_SLUG="$NOTIFY_SLUG" \
    SIGNALBOX_APPROVAL_PORT="$APPROVAL_PORT" \
    "$NOTIFY_SUBJECT" <"$NOTIFY_INPUT" >"$NOTIFY_OUT" 2>"$NOTIFY_ERR"
NOTIFY_STATUS=$?

OK=1
if [ "$NOTIFY_STATUS" -eq 0 ] \
    && cmp -s "$NOTIFY_INPUT" "$NOTIFY_RUN/state/pending.json"; then
    OK=0
fi
report_case "approval sink preserves pending payload" "$OK" \
    "status=$NOTIFY_STATUS pending=$(jq -c . "$NOTIFY_RUN/state/pending.json" 2>/dev/null)"

OK=1
if grep -q 'curl' "$NOTIFY_OUT" \
    && grep -q "http://127.0.0.1:$APPROVAL_PORT/approve" "$NOTIFY_OUT" \
    && grep -q 'POST' "$NOTIFY_OUT" \
    && grep -Eq 'hold the review engine open|engine.*held open' "$NOTIFY_OUT"; then
    OK=0
fi
report_case "approval narration states live webhook hold" "$OK" \
    "stdout=$(head -c 320 "$NOTIFY_OUT" 2>/dev/null)"

printf '%d/%d cases passed (%d skipped)\n' \
    "$TESTS_PASSED" "$TESTS_RUN" "$TESTS_SKIPPED"
[ "$TESTS_PASSED" -eq "$TESTS_RUN" ]
