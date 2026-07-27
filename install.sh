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
#   testing gate    the integration worktree root + detected/supplied GATE_CMD
#   state           per-repo readiness ladder + assessment ledger, so every
#                   repo earns its own autonomy track record from R2
#
# After installing: `emergent --config <dest>/init.toml` once to fill the
# vault, then per feature: `SIGNALBOX_ISSUE=<n> emergent --config <dest>/plan.toml`
# (issue -> validated plan.json), `emergent --config <dest>/implement.toml`,
# then the review loop.
# A repo that has never used TRIP needs two things this installer provides:
# the vault wiring (--vault: .claude/docs -> <vault>/<folder>, TRIP-init's
# own idempotent setup, vendored as bin/vault-setup.sh) and a preflight that
# fails fast on missing tooling instead of failing 20 minutes into a run.
#
# Usage: install.sh <target-repo-path> [--vault <vault-root> [--folder <f>]] [--gate '<command>']
#   --vault   Obsidian vault root; wires .claude/docs into it (idempotent,
#             migrates a pre-existing real docs/ dir). Default folder:
#             TRIP/<repo-name>. Without --vault the repo must already be
#             TRIP-wired (.claude/docs present) or init will refuse to run.
#   --gate    Testing command to run in the integration worktree. Without it,
#             the target checkout's repo root is probed in order for Taskfile
#             ci, Cargo.toml, justfile/Makefile ci, then package.json test; the
#             integration worktree is a checkout of that same repository.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${1:?usage: install.sh <target-repo-path> [--vault <vault-root> [--folder <folder>]] [--gate '<command>']}"
shift
VAULT="" FOLDER="" GATE_CMD=""
while [ $# -gt 0 ]; do
    case "$1" in
        --vault)  VAULT="${2:?--vault needs a path}"; shift 2 ;;
        --folder) FOLDER="${2:?--folder needs a name}"; shift 2 ;;
        --gate) GATE_CMD="${2:?--gate needs a command}"; shift 2 ;;
        *) echo "error: unknown argument $1" >&2; exit 64 ;;
    esac
done

detect_gate() {
    local repo="$1" file

    # Deliberate grep-level YAML heuristic: no YAML parser is available.
    for file in Taskfile.yml Taskfile.yaml; do
        if [ -f "$repo/$file" ] \
            && grep -qE '^[[:space:]]*ci:[[:space:]]*$|^[[:space:]]*ci:[[:space:]]' "$repo/$file"; then
            printf '%s\n' 'task ci'
            return 0
        fi
    done

    if [ -f "$repo/Cargo.toml" ]; then
        printf '%s\n' 'cargo clippy --all-targets -q && cargo nextest run'
        return 0
    fi

    for file in justfile Justfile .justfile; do
        if [ -f "$repo/$file" ] && grep -qE '^[[:space:]]*ci[[:space:]]*:' "$repo/$file"; then
            printf '%s\n' 'just ci'
            return 0
        fi
    done

    for file in Makefile makefile; do
        if [ -f "$repo/$file" ] && grep -qE '^[[:space:]]*ci[[:space:]]*:' "$repo/$file"; then
            printf '%s\n' 'make ci'
            return 0
        fi
    done

    if [ -f "$repo/package.json" ] \
        && jq -e '.scripts.test | type == "string"' "$repo/package.json" >/dev/null 2>&1; then
        if [ -f "$repo/pnpm-lock.yaml" ]; then
            printf '%s\n' 'pnpm test'
        elif [ -f "$repo/yarn.lock" ]; then
            printf '%s\n' 'yarn test'
        elif [ -f "$repo/package-lock.json" ]; then
            printf '%s\n' 'npm test'
        else
            printf '%s\n' 'pnpm test'
        fi
        return 0
    fi

    return 1
}

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
if [ -z "$GATE_CMD" ]; then
    GATE_CMD="$(detect_gate "$TARGET" || true)"
fi
if [ -z "$GATE_CMD" ]; then
    echo "preflight: cannot detect a testing gate in $REPO — re-run with --gate '<command>' (tried: Taskfile ci, root Cargo.toml, justfile/Makefile ci, package.json test)" >&2
    MISSING=1
else
    need "${GATE_CMD%% *}" "the testing gate runs: $GATE_CMD"
fi
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
# GATE_CMD is the detected-or-supplied gate, runs in GATE_DIR, and is safe to hand-edit.
ENV
printf 'GATE_CMD=%q\n' "$GATE_CMD" >>"$DEST/bin/_env.sh"
cat >>"$DEST/bin/_env.sh" <<'ENV'
export ROOT REPO_ROOT WT_BASE FEATURE BASE_BRANCH INT_BRANCH INT_WT GATE_DIR ENGINE_PREFIX SEED_WORKDIR GATE_CMD
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
echo "gate:      $GATE_CMD"
echo "next:      emergent --config $DEST/init.toml                    (fill the vault, once per repo)"
echo "           SIGNALBOX_ISSUE=<n> emergent --config $DEST/pipeline.toml (issue -> plan -> implement -> review,"
echo "                                                                 Fable operating the phase seams)"
