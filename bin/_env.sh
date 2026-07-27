# Shared constants for the signalbox topologies. Sourced, not executed.
# This is the PROTOTYPE (demo) mode file; install.sh generates a target-mode
# replacement that derives everything from the host repo's location and detects
# GATE_CMD per repository. GATE_CMD runs in GATE_DIR.
# shellcheck shell=bash
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -n "${SIGNALBOX_RUN_SLUG:-}" ]; then
    RUN_SLUG="${SIGNALBOX_RUN_SLUG:-}"
elif [ -n "${SIGNALBOX_ISSUE:-}" ]; then
    RUN_SLUG="issue-${SIGNALBOX_ISSUE:-}"
else
    RUN_SLUG=""
fi
if [ -n "$RUN_SLUG" ]; then
    RUN_DIR="$ROOT/runs/$RUN_SLUG"
else
    RUN_DIR="$ROOT"
fi
LEDGER_DIR="$ROOT/state"
REPO_ROOT="$ROOT"
WT_BASE="$(dirname "$ROOT")/signalbox-wt"
BASE_BRANCH="main"
INT_BRANCH="integration/stream-demo"
INT_WT="$WT_BASE/integration"
GATE_DIR="$INT_WT/demo"
GATE_CMD='cargo clippy --all-targets -q && cargo nextest run'
ENGINE_PREFIX="signalbox"
SEED_WORKDIR="$ROOT/demo"
SEED_FEATURE="demo-parse-pairs"
APPROVAL_PORT=""
if [ -f "$RUN_DIR/launch.json" ]; then
    APPROVAL_PORT="$(jq -r '.ports.approval // empty' "$RUN_DIR/launch.json" 2>/dev/null || true)"
fi
if [ -z "$APPROVAL_PORT" ]; then
    APPROVAL_PORT="${SIGNALBOX_APPROVAL_PORT:-}"
fi
if [ -z "$APPROVAL_PORT" ]; then
    APPROVAL_PORT=8105
fi
export ROOT RUN_SLUG RUN_DIR LEDGER_DIR REPO_ROOT WT_BASE BASE_BRANCH INT_BRANCH INT_WT GATE_DIR GATE_CMD ENGINE_PREFIX SEED_WORKDIR SEED_FEATURE APPROVAL_PORT
