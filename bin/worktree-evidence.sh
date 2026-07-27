#!/usr/bin/env bash
# Worktree evidence recorder: argv = one worktree path.
# stdout = one single-line JSON object describing whether the path is a worktree
# and, when it is, its branch, tip, porcelain status, and cleanliness.
#
# Issue #12 requires this evidence because the operator's mandatory porcelain
# check needs a recorded fallback when the live integration-worktree check is
# unavailable. Diagnostics, if any, are reserved for stderr.
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "usage: worktree-evidence.sh <worktree-path>" >&2
    exit 64
fi

WORKTREE="$1"

if [ ! -d "$WORKTREE" ]; then
    jq -nc \
        --arg worktree "$WORKTREE" \
        --argjson exists false \
        --arg error "path is not an existing directory" \
        '{worktree: $worktree, exists: $exists, error: $error}'
    exit 0
fi

if ! INSIDE="$(git -C "$WORKTREE" rev-parse --is-inside-work-tree 2>/dev/null)"; then
    jq -nc \
        --arg worktree "$WORKTREE" \
        --argjson exists false \
        --arg error "path is not a git work tree" \
        '{worktree: $worktree, exists: $exists, error: $error}'
    exit 0
fi

if [ "$INSIDE" != "true" ]; then
    jq -nc \
        --arg worktree "$WORKTREE" \
        --argjson exists false \
        --arg error "path is not a git work tree" \
        '{worktree: $worktree, exists: $exists, error: $error}'
    exit 0
fi

BRANCH="$(git -C "$WORKTREE" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
TIP="$(git -C "$WORKTREE" rev-parse --short HEAD 2>/dev/null || true)"
PORCELAIN="$(git -C "$WORKTREE" status --porcelain)"
if [ -z "$PORCELAIN" ]; then
    CLEAN=true
else
    CLEAN=false
fi

jq -nc \
    --arg worktree "$WORKTREE" \
    --argjson exists true \
    --arg branch "$BRANCH" \
    --arg tip "$TIP" \
    --arg porcelain "$PORCELAIN" \
    --argjson clean "$CLEAN" \
    '{
        worktree: $worktree,
        exists: $exists,
        branch: $branch,
        tip: $tip,
        porcelain: $porcelain,
        clean: $clean
    }'
