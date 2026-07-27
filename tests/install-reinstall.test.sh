#!/usr/bin/env bash
# Self-contained test runner for install.sh reinstall behavior. No framework;
# every target repository and HOME lives under a registered mktemp -d fixture,
# and command stubs prevent service or network access. Prints PASS/FAIL per
# case and exits non-zero when any case failed.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUBJECT="$ROOT/install.sh"
LIVENESS="$ROOT/bin/_liveness.sh"
ORIGINAL_PATH="$PATH"
FIXTURES=()
CHILD_PIDS=()
TESTS_RUN=0
TESTS_PASSED=0
RUN_STATUS=0
FIXTURE_REPO=""
FIXTURE_HOME=""
FIXTURE_STUBS=""
FIXTURE_DEST=""

cleanup() {
    local PID_VALUE FIXTURE
    for PID_VALUE in "${CHILD_PIDS[@]}"; do
        kill "$PID_VALUE" 2>/dev/null || true
        wait "$PID_VALUE" 2>/dev/null || true
    done
    for FIXTURE in "${FIXTURES[@]}"; do
        rm -rf -- "$FIXTURE"
    done
}
trap cleanup EXIT

make_stub() {
    local PATH_VALUE="$1"
    printf '#!/usr/bin/env bash\nexit 0\n' >"$PATH_VALUE"
    chmod +x "$PATH_VALUE"
}

fixture() {
    local BASE PRIMITIVES COMMAND

    BASE="$(mktemp -d)"
    FIXTURES+=("$BASE")
    FIXTURE_REPO="$BASE/repo"
    FIXTURE_HOME="$BASE/home"
    FIXTURE_STUBS="$BASE/stubs"
    FIXTURE_DEST="$FIXTURE_REPO/.claude/emergent"
    PRIMITIVES="$FIXTURE_HOME/.local/share/emergent/primitives/bin"

    mkdir -p "$FIXTURE_REPO/.claude/docs" "$FIXTURE_STUBS" "$PRIMITIVES"
    printf '# Fixture architecture\n' >"$FIXTURE_REPO/.claude/docs/ARCHI.md"
    printf '[package]\nname = "fixture"\nversion = "0.1.0"\nedition = "2021"\n' \
        >"$FIXTURE_REPO/Cargo.toml"
    printf 'fixture\n' >"$FIXTURE_REPO/tracked.txt"
    git -C "$FIXTURE_REPO" init -q -b main
    git -C "$FIXTURE_REPO" config user.name fixture
    git -C "$FIXTURE_REPO" config user.email fixture@example.com
    git -C "$FIXTURE_REPO" config commit.gpgsign false
    git -C "$FIXTURE_REPO" config user.signingkey fixture-signing-key
    git -C "$FIXTURE_REPO" add .
    git -C "$FIXTURE_REPO" commit -q -m initial

    for COMMAND in exec-source exec-handler exec-sink stream-runner; do
        make_stub "$PRIMITIVES/$COMMAND"
    done
    for COMMAND in emergent codex claude gh cargo custom-gate; do
        make_stub "$FIXTURE_STUBS/$COMMAND"
    done
    # Simulate a machine without a user D-Bus session. The stub performs no
    # action, and sink-service.sh therefore never probes or touches systemd.
    printf '#!/usr/bin/env bash\nexit 1\n' >"$FIXTURE_STUBS/systemctl"
    chmod +x "$FIXTURE_STUBS/systemctl"
}

run_subject() {
    local STDOUT_FILE="$1"
    local STDERR_FILE="$2"
    shift 2
    HOME="$FIXTURE_HOME" PATH="$FIXTURE_STUBS:$ORIGINAL_PATH" \
        "$SUBJECT" "$FIXTURE_REPO" "$@" >"$STDOUT_FILE" 2>"$STDERR_FILE"
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

# shellcheck source=../bin/_liveness.sh
source "$LIVENESS"

fixture
OUT="$(mktemp)"
ERR="$(mktemp)"
FIXTURES+=("$OUT" "$ERR")

# 1. A fresh target receives every required install surface.
run_subject "$OUT" "$ERR"
OK=1
if [ "$RUN_STATUS" -eq 0 ] \
    && [ -d "$FIXTURE_DEST/bin" ] \
    && [ -d "$FIXTURE_DEST/prompts" ] \
    && [ -d "$FIXTURE_DEST/templates" ] \
    && [ -d "$FIXTURE_DEST/runs" ] \
    && [ -d "$FIXTURE_DEST/state" ] \
    && [ -s "$FIXTURE_DEST/pipeline.toml" ]; then
    OK=0
fi
report_case "fresh install creates the harness layout" "$OK" \
    "status=$RUN_STATUS stderr=$(head -c 200 "$ERR")"

# 2. Existing installs require the supported in-place path and explain manual
# carry requirements.
run_subject "$OUT" "$ERR"
OK=1
if [ "$RUN_STATUS" -eq 1 ] \
    && grep -q -- '--reinstall' "$ERR" \
    && grep -q 'runs/' "$ERR" \
    && grep -q 'assessments.jsonl' "$ERR" \
    && grep -q 'readiness.json' "$ERR"; then
    OK=0
fi
report_case "second install names reinstall and the carry-list" "$OK" \
    "status=$RUN_STATUS stderr=$(head -c 300 "$ERR")"

# 3. Regression: a live recorded run blocks every mutation and its run state
# and earned ledger remain byte-identical.
RUN_DIR="$FIXTURE_DEST/runs/issue-12"
mkdir -p "$RUN_DIR/state"
printf '{"feature":"recognizable-plan"}\n' >"$RUN_DIR/plan.json"
printf 'recognizable run state\n' >"$RUN_DIR/state/progress"
printf '{"assessment":"recognizable"}\n' >"$FIXTURE_DEST/state/assessments.jsonl"
printf '{"readiness":"recognizable"}\n' >"$FIXTURE_DEST/state/readiness.json"
EXPECTED_PLAN="$FIXTURE_HOME/expected-plan.json"
EXPECTED_ASSESSMENTS="$FIXTURE_HOME/expected-assessments.jsonl"
EXPECTED_READINESS="$FIXTURE_HOME/expected-readiness.json"
cp "$RUN_DIR/plan.json" "$EXPECTED_PLAN"
cp "$FIXTURE_DEST/state/assessments.jsonl" "$EXPECTED_ASSESSMENTS"
cp "$FIXTURE_DEST/state/readiness.json" "$EXPECTED_READINESS"

sleep 60 &
LIVE_PID=$!
CHILD_PIDS+=("$LIVE_PID")
LIVE_START="$(proc_identity "$LIVE_PID")"
jq -n \
    --arg slug issue-12 \
    --argjson pid "$LIVE_PID" \
    --arg start_id "$LIVE_START" \
    --arg phase plan \
    --argjson issue 12 \
    '{slug: $slug, pid: $pid, start_id: $start_id, phase: $phase, issue: $issue}' \
    >"$RUN_DIR/launch.json"

run_subject "$OUT" "$ERR" --reinstall
OK=1
if [ "$RUN_STATUS" -eq 1 ] \
    && grep -q 'issue-12' "$ERR" \
    && grep -q "$LIVE_PID" "$ERR" \
    && cmp -s "$RUN_DIR/plan.json" "$EXPECTED_PLAN" \
    && cmp -s "$FIXTURE_DEST/state/assessments.jsonl" "$EXPECTED_ASSESSMENTS" \
    && cmp -s "$FIXTURE_DEST/state/readiness.json" "$EXPECTED_READINESS"; then
    OK=0
fi
report_case "live run refuses reinstall without losing run or ledger state" "$OK" \
    "status=$RUN_STATUS stderr=$(head -c 300 "$ERR")"

# 4. Once the exact owner stops, generated files refresh while all seeded
# persistent state survives byte-for-byte.
kill "$LIVE_PID" 2>/dev/null || true
wait "$LIVE_PID" 2>/dev/null || true
printf '\nINSTALL_REINSTALL_SENTINEL\n' >>"$FIXTURE_DEST/bin/run.sh"
printf '\n# INSTALL_REINSTALL_SENTINEL\n' >>"$FIXTURE_DEST/pipeline.toml"
run_subject "$OUT" "$ERR" --reinstall
OK=1
if [ "$RUN_STATUS" -eq 0 ] \
    && cmp -s "$RUN_DIR/plan.json" "$EXPECTED_PLAN" \
    && cmp -s "$FIXTURE_DEST/state/assessments.jsonl" "$EXPECTED_ASSESSMENTS" \
    && cmp -s "$FIXTURE_DEST/state/readiness.json" "$EXPECTED_READINESS" \
    && [ -s "$FIXTURE_DEST/bin/run.sh" ] \
    && [ -s "$FIXTURE_DEST/pipeline.toml" ] \
    && [ -e "$FIXTURE_DEST/.install.lock" ] \
    && [ ! -e "$FIXTURE_DEST/state/install.lock" ] \
    && ! grep -q 'INSTALL_REINSTALL_SENTINEL' "$FIXTURE_DEST/bin/run.sh" \
    && ! grep -q 'INSTALL_REINSTALL_SENTINEL' "$FIXTURE_DEST/pipeline.toml" \
    && grep -q '^refreshed:' "$OUT" \
    && grep -q '^preserved:' "$OUT"; then
    OK=0
fi
report_case "stopped run permits an in-place refresh that preserves state" "$OK" \
    "status=$RUN_STATUS stderr=$(head -c 300 "$ERR")"

# 5. Rebuilding generated directories removes files deleted from the source.
printf '#!/usr/bin/env bash\n' >"$FIXTURE_DEST/bin/obsolete-harness-script.sh"
printf 'obsolete prompt\n' >"$FIXTURE_DEST/prompts/obsolete.md"
run_subject "$OUT" "$ERR" --reinstall
OK=1
if [ "$RUN_STATUS" -eq 0 ] \
    && [ ! -e "$FIXTURE_DEST/bin/obsolete-harness-script.sh" ] \
    && [ ! -e "$FIXTURE_DEST/prompts/obsolete.md" ]; then
    OK=0
fi
report_case "reinstall removes stale generated scripts and prompts" "$OK" \
    "status=$RUN_STATUS stderr=$(head -c 300 "$ERR")"

# 6. A hand-edited gate survives by default, while an explicit flag wins.
sed -i 's/^GATE_CMD=.*/GATE_CMD=custom-gate/' "$FIXTURE_DEST/bin/_env.sh"
run_subject "$OUT" "$ERR" --reinstall
PRESERVED_STATUS=$RUN_STATUS
PRESERVED_GATE=1
grep -qxF 'GATE_CMD=custom-gate' "$FIXTURE_DEST/bin/_env.sh" && PRESERVED_GATE=0
run_subject "$OUT" "$ERR" --reinstall --gate 'echo overridden'
OVERRIDE_STATUS=$RUN_STATUS
OVERRIDE_ASSIGN="$(printf 'GATE_CMD=%q' 'echo overridden')"
OVERRIDE_GATE=1
grep -qxF "$OVERRIDE_ASSIGN" "$FIXTURE_DEST/bin/_env.sh" && OVERRIDE_GATE=0
OK=1
if [ "$PRESERVED_STATUS" -eq 0 ] \
    && [ "$PRESERVED_GATE" -eq 0 ] \
    && [ "$OVERRIDE_STATUS" -eq 0 ] \
    && [ "$OVERRIDE_GATE" -eq 0 ]; then
    OK=0
fi
report_case "reinstall preserves the recorded gate unless overridden" "$OK" \
    "preserved-status=$PRESERVED_STATUS override-status=$OVERRIDE_STATUS"

# 7. --reinstall is harmless on a target that has never had the harness.
fixture
run_subject "$OUT" "$ERR" --reinstall
OK=1
if [ "$RUN_STATUS" -eq 0 ] \
    && [ -d "$FIXTURE_DEST/bin" ] \
    && [ -d "$FIXTURE_DEST/runs" ] \
    && [ -d "$FIXTURE_DEST/state" ] \
    && [ -s "$FIXTURE_DEST/pipeline.toml" ] \
    && grep -q '^installed:' "$OUT"; then
    OK=0
fi
report_case "reinstall flag performs a plain install on a fresh target" "$OK" \
    "status=$RUN_STATUS stderr=$(head -c 300 "$ERR")"

# 8. Launch race: a launcher inside its startup window holds the harness lock
# shared, and reinstall must refuse without touching the tree — the run it is
# about to record would otherwise be invisible to a scan that already ran.
# Once the launcher releases, the refresh proceeds normally.
LOCK_FILE="$FIXTURE_DEST/.install.lock"
LAUNCHER_READY="$FIXTURE_HOME/launcher.ready"
( exec 9>>"$LOCK_FILE"; flock -s 9; : >"$LAUNCHER_READY"; sleep 60 ) &
LAUNCHER_PID=$!
CHILD_PIDS+=("$LAUNCHER_PID")
for _ in $(seq 1 100); do
    [ -e "$LAUNCHER_READY" ] && break
    sleep 0.1
done
printf '\nINSTALL_LOCK_SENTINEL\n' >>"$FIXTURE_DEST/bin/run.sh"
export SIGNALBOX_LOCK_WAIT=1
run_subject "$OUT" "$ERR" --reinstall
unset SIGNALBOX_LOCK_WAIT
BLOCKED_STATUS=$RUN_STATUS
BLOCKED_INTACT=1
grep -q 'INSTALL_LOCK_SENTINEL' "$FIXTURE_DEST/bin/run.sh" && BLOCKED_INTACT=0
BLOCKED_NAMED=1
grep -q 'install.lock' "$ERR" && BLOCKED_NAMED=0
kill "$LAUNCHER_PID" 2>/dev/null || true
wait "$LAUNCHER_PID" 2>/dev/null || true
run_subject "$OUT" "$ERR" --reinstall
OK=1
if [ "$BLOCKED_STATUS" -eq 1 ] \
    && [ "$BLOCKED_INTACT" -eq 0 ] \
    && [ "$BLOCKED_NAMED" -eq 0 ] \
    && [ "$RUN_STATUS" -eq 0 ] \
    && ! grep -q 'INSTALL_LOCK_SENTINEL' "$FIXTURE_DEST/bin/run.sh"; then
    OK=0
fi
report_case "a launcher's startup lock blocks reinstall until it releases" "$OK" \
    "blocked-status=$BLOCKED_STATUS intact=$BLOCKED_INTACT named=$BLOCKED_NAMED release-status=$RUN_STATUS"

# 9. Stale launcher: a harness installed before the lock existed starts runs
# without taking it, so one can record an engine after the first liveness scan.
# The gh stub stands in for that launcher — install.sh runs gh during preflight,
# after the scan and before the entry point is withdrawn. The rescan that
# follows the withdrawal must catch the run, refuse, and put bin/ back untouched.
sleep 60 &
STALE_PID=$!
CHILD_PIDS+=("$STALE_PID")
STALE_START="$(proc_identity "$STALE_PID")"
mkdir -p "$FIXTURE_DEST/runs/issue-77"
export STALE_LAUNCH_DEST="$FIXTURE_DEST/runs/issue-77/launch.json"
export STALE_LAUNCH_SRC="$FIXTURE_HOME/stale-launch.json"
jq -n \
    --arg slug issue-77 \
    --argjson pid "$STALE_PID" \
    --arg start_id "$STALE_START" \
    --arg phase pipeline \
    --argjson issue 77 \
    '{slug: $slug, pid: $pid, start_id: $start_id, phase: $phase, issue: $issue}' \
    >"$STALE_LAUNCH_SRC"
cat >"$FIXTURE_STUBS/gh" <<'STUB'
#!/usr/bin/env bash
if [ -n "${STALE_LAUNCH_SRC:-}" ] && [ -n "${STALE_LAUNCH_DEST:-}" ]; then
    cp "$STALE_LAUNCH_SRC" "$STALE_LAUNCH_DEST"
fi
exit 0
STUB
chmod +x "$FIXTURE_STUBS/gh"
printf '\nSTALE_LAUNCH_SENTINEL\n' >>"$FIXTURE_DEST/bin/run.sh"
run_subject "$OUT" "$ERR" --reinstall
STAGED_LEFT=0
compgen -G "$FIXTURE_DEST/.bin.reinstalling.*" >/dev/null && STAGED_LEFT=1
OK=1
if [ "$RUN_STATUS" -eq 1 ] \
    && grep -q 'issue-77' "$ERR" \
    && grep -q "$STALE_PID" "$ERR" \
    && [ "$STAGED_LEFT" -eq 0 ] \
    && [ -d "$FIXTURE_DEST/prompts" ] \
    && grep -q 'STALE_LAUNCH_SENTINEL' "$FIXTURE_DEST/bin/run.sh"; then
    OK=0
fi
report_case "a run recorded after the first scan is refused with bin/ restored" "$OK" \
    "status=$RUN_STATUS staged-left=$STAGED_LEFT stderr=$(head -c 300 "$ERR")"
unset STALE_LAUNCH_SRC STALE_LAUNCH_DEST

printf '%d/%d cases passed\n' "$TESTS_PASSED" "$TESTS_RUN"
[ "$TESTS_PASSED" -eq "$TESTS_RUN" ]
