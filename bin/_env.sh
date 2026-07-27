# Shared constants for the signalbox topologies. Sourced, not executed.
# This is the PROTOTYPE (demo) mode file; install.sh generates a target-mode
# replacement that derives everything from the host repo's location.
# shellcheck shell=bash
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$ROOT"
WT_BASE="$(dirname "$ROOT")/signalbox-wt"
BASE_BRANCH="main"
INT_BRANCH="integration/stream-demo"
INT_WT="$WT_BASE/integration"
GATE_DIR="$INT_WT/demo"
ENGINE_PREFIX="signalbox"
SEED_WORKDIR="$ROOT/demo"
SEED_FEATURE="demo-parse-pairs"
export ROOT REPO_ROOT WT_BASE BASE_BRANCH INT_BRANCH INT_WT GATE_DIR ENGINE_PREFIX SEED_WORKDIR SEED_FEATURE
