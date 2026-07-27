# Shared constants for the signalbox topologies. Sourced, not executed.
# This is the PROTOTYPE (demo) mode file; install.sh generates a target-mode
# replacement that derives everything from the host repo's location and detects
# GATE_CMD per repository. GATE_CMD runs in GATE_DIR.
# shellcheck shell=bash
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
APPROVAL_PORT=8105
export ROOT REPO_ROOT WT_BASE BASE_BRANCH INT_BRANCH INT_WT GATE_DIR GATE_CMD ENGINE_PREFIX SEED_WORKDIR SEED_FEATURE APPROVAL_PORT
