#!/usr/bin/env bash
# Init runner: invoke as bin/init-run.sh with no arguments.
# This is an operator entry point with no stdin/stdout event contract; it is
# not a topology handler or sink, and its stdout is human narration.
#
# Runs the init engine, watches DISK ARTIFACTS (never engine claims) for all
# three vault documents, then stops only the child it launched, gracefully,
# by PID.
set -euo pipefail
# shellcheck source=_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/_env.sh"

if [ $# -ne 0 ]; then
    echo "usage: bin/init-run.sh" >&2
    exit 64
fi

CFG="$ROOT/init.toml"
if [ ! -f "$CFG" ]; then
    echo "error: init config missing: $CFG" >&2
    exit 1
fi
if grep -q '__SIGNALBOX_ROOT__' "$CFG"; then
    echo "error: harness must be installed first: ./install.sh <target-repo> [--vault <vault-root>]" >&2
    exit 1
fi

VAULT="$(readlink -f "$REPO_ROOT/.claude/docs" 2>/dev/null || true)"
if [ ! -d "$VAULT" ]; then
    echo "error: vault wiring must be set up first: bin/vault-setup.sh <vault-root> <folder>, or re-run ./install.sh <target-repo> --vault <vault-root>" >&2
    exit 1
fi

mkdir -p "$ROOT/state" "$ROOT/logs"
STAMP="$ROOT/state/init.stamp"
LOG="$ROOT/logs/init.log"
touch "$STAMP"

emergent --config "$CFG" >"$LOG" 2>&1 &
PID=$!
echo "[init] engine up (pid $PID), watching artifacts; log: $LOG"

trap 'kill -TERM "$PID" 2>/dev/null || true' INT TERM

# Redirected engine stdout is buffered, so polling narration in $LOG can
# deadlock a successful run into its timeout. Only fresh disk artifacts count.
fresh() { [ -f "$1" ] && [ "$1" -nt "$STAMP" ]; }

ARCHI_PATH=""
ARCHI_STATUS=""
RULES_PATH=""
RULES_STATUS=""
TESTING_PATH=""
TESTING_STATUS=""
OUTCOME="TIMEOUT"
TIMEOUT=2400
SECS=0

while [ "$SECS" -lt "$TIMEOUT" ]; do
    if [ -z "$ARCHI_PATH" ]; then
        if fresh "$VAULT/ARCHI.md"; then
            ARCHI_PATH="$VAULT/ARCHI.md"
            ARCHI_STATUS="adopted directly"
            echo "[init] ARCHI.md landed: $ARCHI_PATH"
        elif fresh "$VAULT/ARCHI.proposed.md"; then
            ARCHI_PATH="$VAULT/ARCHI.proposed.md"
            ARCHI_STATUS=".proposed.md sibling awaiting human diff-and-adopt"
            echo "[init] ARCHI.md landed: $ARCHI_PATH"
        fi
    fi

    if [ -z "$RULES_PATH" ]; then
        if fresh "$VAULT/ARCHI-rules.md"; then
            RULES_PATH="$VAULT/ARCHI-rules.md"
            RULES_STATUS="adopted directly"
            echo "[init] ARCHI-rules.md landed: $RULES_PATH"
        elif fresh "$VAULT/ARCHI-rules.proposed.md"; then
            RULES_PATH="$VAULT/ARCHI-rules.proposed.md"
            RULES_STATUS=".proposed.md sibling awaiting human diff-and-adopt"
            echo "[init] ARCHI-rules.md landed: $RULES_PATH"
        fi
    fi

    if [ -z "$TESTING_PATH" ]; then
        if fresh "$VAULT/TESTING.md"; then
            TESTING_PATH="$VAULT/TESTING.md"
            TESTING_STATUS="adopted directly"
            echo "[init] TESTING.md landed: $TESTING_PATH"
        elif fresh "$VAULT/TESTING.proposed.md"; then
            TESTING_PATH="$VAULT/TESTING.proposed.md"
            TESTING_STATUS=".proposed.md sibling awaiting human diff-and-adopt"
            echo "[init] TESTING.md landed: $TESTING_PATH"
        fi
    fi

    # Check artifacts first: the engine may exit immediately after its final write.
    if [ -n "$ARCHI_PATH" ] && [ -n "$RULES_PATH" ] && [ -n "$TESTING_PATH" ]; then
        OUTCOME="ARTIFACT"
        break
    fi
    kill -0 "$PID" 2>/dev/null || { OUTCOME="ENGINE_DIED"; break; }

    sleep 5
    SECS=$((SECS + 5))
done

# Let in-flight sinks finish narrating, then stop ONLY our child, gracefully.
if kill -0 "$PID" 2>/dev/null; then
    sleep 5
    kill -TERM "$PID" 2>/dev/null || true
    for _ in $(seq 1 30); do
        kill -0 "$PID" 2>/dev/null || break
        sleep 2
    done
    # The child may exit between the liveness check and the kill; either half
    # going nonzero is a benign race, not a run failure.
    { kill -0 "$PID" 2>/dev/null && kill -KILL "$PID" 2>/dev/null; } || true
fi
wait "$PID" 2>/dev/null || true
trap - INT TERM

echo "[init] engine stopped, outcome: $OUTCOME"
if [ -n "$ARCHI_PATH" ]; then
    echo "[init] ARCHI.md: $ARCHI_PATH ($ARCHI_STATUS)"
else
    echo "[init] ARCHI.md: did not land"
fi
if [ -n "$RULES_PATH" ]; then
    echo "[init] ARCHI-rules.md: $RULES_PATH ($RULES_STATUS)"
else
    echo "[init] ARCHI-rules.md: did not land"
fi
if [ -n "$TESTING_PATH" ]; then
    echo "[init] TESTING.md: $TESTING_PATH ($TESTING_STATUS)"
else
    echo "[init] TESTING.md: did not land"
fi

if [ "$OUTCOME" = "ARTIFACT" ]; then
    exit 0
fi
exit 1
