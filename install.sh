#!/usr/bin/env bash
# Install the signalbox harness into a target repo: install.sh <repo-path>
#
# Stamps a rendered copy of the topologies, scripts, and prompts into
# <repo>/.claude/emergent/ — the TRIP convention: local-only tooling under
# .claude, kept out of git via info/exclude, never committed to the target.
# The rendered copy is self-contained: absolute paths baked into the TOMLs,
# engine names namespaced by repo (so sockets and event-store logs never
# collide across repos), and a target-mode _env.sh that derives everything
# from where it lives:
#
#   feature branch  feat/<plan.json .feature>
#   worktrees       <parent>/<repo>-wt/...      (TRIP's worktree home)
#   testing gate    the integration worktree root (cargo workspace)
#   state           per-repo readiness ladder + assessment ledger, so every
#                   repo earns its own autonomy track record from R2
#
# After installing: `emergent --config <dest>/init.toml` once to fill the
# vault, then per feature: `TRIP_ISSUE=<n> emergent --config <dest>/plan.toml`
# (issue -> validated plan.json), `emergent --config <dest>/implement.toml`,
# then the review loop.
# A repo that has never used TRIP needs two things this installer provides:
# the vault wiring (--vault: .claude/docs -> <vault>/<folder>, TRIP-init's
# own idempotent setup, vendored as bin/vault-setup.sh) and a preflight that
# fails fast on missing tooling instead of failing 20 minutes into a run.
#
# Usage: install.sh <target-repo-path> [--vault <vault-root> [--folder <f>]]
#   --vault   Obsidian vault root; wires .claude/docs into it (idempotent,
#             migrates a pre-existing real docs/ dir). Default folder:
#             TRIP/<repo-name>. Without --vault the repo must already be
#             TRIP-wired (.claude/docs present) or init will refuse to run.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${1:?usage: install.sh <target-repo-path> [--vault <vault-root> [--folder <folder>]]}"
shift
VAULT="" FOLDER=""
while [ $# -gt 0 ]; do
    case "$1" in
        --vault)  VAULT="${2:?--vault needs a path}"; shift 2 ;;
        --folder) FOLDER="${2:?--folder needs a name}"; shift 2 ;;
        *) echo "error: unknown argument $1" >&2; exit 64 ;;
    esac
done

TARGET="$(cd "$TARGET" && pwd)"
git -C "$TARGET" rev-parse --git-dir >/dev/null
REPO="$(basename "$TARGET")"
DEST="$TARGET/.claude/emergent"

# --- Preflight: everything the topologies shell out to, checked up front.
MISSING=0
need() {
    command -v "$1" >/dev/null 2>&1 || { echo "preflight: missing $1 — $2" >&2; MISSING=1; }
}
need emergent "install the Emergent engine"
need codex    "reviewers/implementers run codex exec"
need claude   "fixers/assessor/operator run headless Claude"
need gh       "plan seed and promotion use the GitHub CLI"
need jq       "every topology transform is jq"
for p in exec-source exec-handler exec-sink stream-runner; do
    [ -x "$HOME/.local/share/emergent/primitives/bin/$p" ] \
        || { echo "preflight: missing primitive $p — run: emergent marketplace install exec-source exec-handler exec-sink stream-runner" >&2; MISSING=1; }
done
gh auth status >/dev/null 2>&1 \
    || { echo "preflight: gh is not authenticated — run: gh auth login" >&2; MISSING=1; }
[ -n "$(git -C "$TARGET" config user.signingkey || true)" ] \
    || { echo "preflight: no git user.signingkey in $REPO — shard/fix commits are signed (-S)" >&2; MISSING=1; }
[ "$MISSING" -eq 0 ] || { echo "preflight failed — fix the above and re-run" >&2; exit 1; }

# --- Vault wiring: a repo that never ran TRIP has no .claude/docs.
if [ -n "$VAULT" ]; then
    FOLDER="${FOLDER:-TRIP/$REPO}"
    (cd "$TARGET" && "$SRC/bin/vault-setup.sh" "$VAULT" "$FOLDER")
elif [ ! -e "$TARGET/.claude/docs" ]; then
    echo "error: $TARGET/.claude/docs missing and no --vault given." >&2
    echo "       This repo has never been TRIP-wired. Re-run with:" >&2
    echo "       install.sh $TARGET --vault <obsidian-vault-root> [--folder TRIP/$REPO]" >&2
    exit 1
fi

if [ -e "$DEST" ]; then
    echo "error: $DEST already exists — remove it first to reinstall" >&2
    exit 1
fi

mkdir -p "$DEST/bin" "$DEST/prompts" "$DEST/state" "$DEST/logs" "$DEST/results"

cp "$SRC"/bin/*.sh "$DEST/bin/"
cp "$SRC"/prompts/*.md "$DEST/prompts/"
# Target mode reviews the feature diff, not a whole demo crate.
mv "$DEST/prompts/review-target.md" "$DEST/prompts/review.md"

# Render the topologies: bake the install path, namespace the engines.
for t in emergent.toml implement.toml init.toml plan.toml pipeline.toml; do
    sed -e "s|__SIGNALBOX_ROOT__|$DEST|g" \
        -e "s|signalbox-review-loop|$REPO-review-loop|g" \
        -e "s|signalbox-implement-stream|$REPO-implement-stream|g" \
        -e "s|signalbox-init|$REPO-init|g" \
        -e "s|signalbox-plan|$REPO-plan|g" \
        -e "s|signalbox-pipeline|$REPO-pipeline|g" \
        "$SRC/$t" >"$DEST/$t"
done

# Target-mode _env.sh: everything derives from the install location.
cat >"$DEST/bin/_env.sh" <<'ENV'
# Target-mode constants (generated by install.sh). Sourced, not executed.
# shellcheck shell=bash
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"            # .claude/emergent
REPO_ROOT="$(cd "$ROOT/../.." && pwd)"                             # primary checkout
WT_BASE="$(dirname "$REPO_ROOT")/$(basename "$REPO_ROOT")-wt"      # TRIP worktree home
FEATURE="$(jq -r '.feature // "feature"' "$ROOT/plan.json" 2>/dev/null || echo feature)"
BASE_BRANCH="$(git -C "$REPO_ROOT" symbolic-ref --short HEAD)"
INT_BRANCH="feat/$FEATURE"
INT_WT="$WT_BASE/$FEATURE"
GATE_DIR="$INT_WT"
ENGINE_PREFIX="$(basename "$REPO_ROOT")"
SEED_WORKDIR="$INT_WT"
export ROOT REPO_ROOT WT_BASE FEATURE BASE_BRANCH INT_BRANCH INT_WT GATE_DIR ENGINE_PREFIX SEED_WORKDIR
ENV

chmod +x "$DEST"/bin/*.sh

# User-level launcher skill (/signalbox): install once, never overwrite —
# an existing copy may carry the user's own customizations.
SKILL_DEST="$HOME/.claude/skills/signalbox"
if [ ! -e "$SKILL_DEST" ]; then
    mkdir -p "$SKILL_DEST"
    cp "$SRC/skills/signalbox/SKILL.md" "$SKILL_DEST/"
    echo "installed /signalbox launcher skill -> $SKILL_DEST"
fi

# TRIP keeps .claude out of the target's git entirely.
GIT_COMMON="$(git -C "$TARGET" rev-parse --path-format=absolute --git-common-dir)"
grep -qxF '.claude' "$GIT_COMMON/info/exclude" 2>/dev/null \
    || printf '.claude\n' >>"$GIT_COMMON/info/exclude"

echo "installed: $DEST"
echo "engines:   $REPO-pipeline (+ $REPO-init, $REPO-plan, $REPO-implement-stream, $REPO-review-loop)"
echo "next:      emergent --config $DEST/init.toml                    (fill the vault, once per repo)"
echo "           TRIP_ISSUE=<n> emergent --config $DEST/pipeline.toml (issue -> plan -> implement -> review,"
echo "                                                                 Fable operating the phase seams)"
