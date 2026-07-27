#!/usr/bin/env bash
# Install the signalbox harness into a target repo: install.sh <repo-path>
#
# Stamps a rendered copy of the topologies, scripts, and prompts into
# <repo>/.claude/emergent/ — the TRIP convention: local-only tooling under
# .claude, kept out of git via info/exclude, never committed to the target.
# The rendered copy contains absolute paths baked into the TOMLs, engine names
# namespaced by repo (so sockets and event-store logs never collide across
# repos), and a target-mode _env.sh that derives everything from where it
# lives. Observability uses one machine-wide shared sink service rather than
# per-repo SSE ports:
#
#   concurrent runs <dest>/runs/<slug>/ (plan, state, results, logs, configs)
#   feature branch  feat/<run plan.json .feature>
#   worktrees       <parent>/<repo>-wt/...      (TRIP's worktree home)
#   testing gate    the integration worktree root + detected/supplied GATE_CMD
#   ledger          repo-scoped readiness + assessments under <dest>/state/
#
# After installing: `<dest>/bin/init-run.sh` once to fill the
# vault, then `<dest>/bin/run.sh <issue>` for each concurrent pipeline run.
# Direct `SIGNALBOX_ISSUE=<n> emergent --config <dest>/pipeline.toml` remains
# available as the single-run form.
# A repo that has never used TRIP needs two things this installer provides:
# the vault wiring (--vault: .claude/docs -> <vault>/<folder>, TRIP-init's
# own idempotent setup, vendored as bin/vault-setup.sh) and a preflight that
# fails fast on missing tooling instead of failing 20 minutes into a run.
#
# Usage: install.sh <target-repo-path> [--reinstall] [--vault <vault-root> [--folder <f>]] [--gate '<command>']
#   --reinstall
#             Refresh an existing harness in place after refusing when a
#             launcher-recorded run is live. Preserves runs/ and the state/
#             readiness ledger. On a never-installed target, acts like a
#             plain install.
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
TARGET="${1:?usage: install.sh <target-repo-path> [--reinstall] [--vault <vault-root> [--folder <folder>]] [--gate '<command>']}"
shift
VAULT="" FOLDER="" GATE_CMD="" GATE_SUPPLIED=0 REINSTALL=0
while [ $# -gt 0 ]; do
    case "$1" in
        --reinstall) REINSTALL=1; shift ;;
        --vault)  VAULT="${2:?--vault needs a path}"; shift 2 ;;
        --folder) FOLDER="${2:?--folder needs a name}"; shift 2 ;;
        --gate) GATE_CMD="${2:?--gate needs a command}"; GATE_SUPPLIED=1; shift 2 ;;
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
REINSTALL_ACTIVE=0

# Resolve install mode before preflight or vault wiring: vault-setup.sh can
# migrate a real docs/ directory, so no mutation may precede this decision.
if [ -e "$DEST" ]; then
    if [ "$REINSTALL" -eq 0 ]; then
        echo "error: $DEST already exists — re-run with --reinstall to refresh it in place" >&2
        echo "       --reinstall rebuilds bin/, prompts/, templates/, the rendered TOMLs and _env.sh," >&2
        echo "       and preserves runs/, state/assessments.jsonl, and state/readiness.json." >&2
        echo "       Removing it by hand destroys live runs and this repo's earned readiness ledger;" >&2
        echo "       if you do it anyway, carry runs/, state/assessments.jsonl and state/readiness.json across." >&2
        exit 1
    fi

    REINSTALL_ACTIVE=1
    # This detects only runs recorded by bin/run.sh. A hand-started
    # `emergent --config` engine remains the operator's responsibility.
    # shellcheck source=bin/_liveness.sh
    source "$SRC/bin/_liveness.sh"
    LIVE_RUNS="$(live_runs "$DEST/runs")"
    if [ -n "$LIVE_RUNS" ]; then
        echo "error: $DEST has live launcher-recorded runs; refusing to refresh in place" >&2
        while IFS=$'\t' read -r LIVE_SLUG LIVE_PID LIVE_PHASE; do
            printf '       live run: slug=%s pid=%s phase=%s\n' \
                "$LIVE_SLUG" "$LIVE_PID" "$LIVE_PHASE" >&2
            printf '       stop this run with: kill -TERM %s\n' "$LIVE_PID" >&2
        done <<<"$LIVE_RUNS"
        echo "       inspect all runs with: $DEST/bin/run.sh --list" >&2
        exit 1
    fi

    # The generated assignment is printf %q output. Evaluate only that single
    # line rather than sourcing _env.sh, whose target-mode probes run git/jq.
    if [ "$GATE_SUPPLIED" -eq 0 ] && [ -f "$DEST/bin/_env.sh" ]; then
        PRIOR_GATE_LINE="$(grep -m 1 '^GATE_CMD=' "$DEST/bin/_env.sh" || true)"
        if [ -n "$PRIOR_GATE_LINE" ]; then
            if ! eval "$PRIOR_GATE_LINE" 2>/dev/null; then
                GATE_CMD=""
            fi
        fi
    fi
fi

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
need python3  "the shared sink service and dashboard are python3"
need curl     "topology sinks POST their events to the shared sink service"
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

if [ "$REINSTALL_ACTIVE" -eq 1 ]; then
    rm -rf -- "$DEST/bin" "$DEST/prompts" "$DEST/templates"
fi

mkdir -p "$DEST/bin" "$DEST/prompts" "$DEST/state" "$DEST/logs" "$DEST/results" \
    "$DEST/runs" "$DEST/templates"

cp "$SRC"/bin/*.sh "$DEST/bin/"
cp "$SRC"/prompts/*.md "$DEST/prompts/"
# Target mode reviews the feature diff, not a whole demo crate.
mv "$DEST/prompts/review-target.md" "$DEST/prompts/review.md"

# SSE ports are gone: every instance pushes to the shared sink service on one
# fixed known port (default 8099, configurable with SIGNALBOX_SINK_PORT). The
# only per-repo reservation left is the approval webhook, which remains
# per-run/per-repo by nature. PORT_BASE is that approval port.
PORT_REG="$HOME/.local/share/signalbox/ports.json"
mkdir -p "$(dirname "$PORT_REG")"
[ -s "$PORT_REG" ] || echo '{}' >"$PORT_REG"
PORT_BASE="$(jq -r --arg repo "$REPO" '.[$repo] // empty' "$PORT_REG")"
if [ -z "$PORT_BASE" ]; then
    PORT_BASE="$(jq -r '[.[]] | (max // 8090) + 10' "$PORT_REG")"
    jq --arg repo "$REPO" --argjson base "$PORT_BASE" '.[$repo] = $base' "$PORT_REG" >"$PORT_REG.tmp" \
        && mv "$PORT_REG.tmp" "$PORT_REG"
fi

# Preserve partially rendered topology templates for per-run launchers.
for t in emergent.toml implement.toml init.toml plan.toml pipeline.toml; do
    sed -e "s|__SIGNALBOX_ROOT__|$DEST|g" \
        -e "s|signalbox-review-loop|$REPO-review-loop|g" \
        -e "s|signalbox-implement-stream|$REPO-implement-stream|g" \
        -e "s|signalbox-init|$REPO-init|g" \
        -e "s|signalbox-plan|$REPO-plan|g" \
        -e "s|signalbox-pipeline|$REPO-pipeline|g" \
        "$SRC/$t" >"$DEST/templates/$t"
done

# Render the single-run topologies: bake the install path, namespace the
# engines, assign the reserved approval port, and use no run suffix.
for t in emergent.toml implement.toml init.toml plan.toml pipeline.toml; do
    sed -e "s|__SIGNALBOX_ROOT__|$DEST|g" \
        -e "s|__SIGNALBOX_RUN_SUFFIX__||g" \
        -e "s|__SIGNALBOX_PORT_APPROVAL__|$PORT_BASE|g" \
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
REPO_ROOT="$(cd "$ROOT/../.." && pwd)"                             # primary checkout
WT_BASE="$(dirname "$REPO_ROOT")/$(basename "$REPO_ROOT")-wt"      # TRIP worktree home
FEATURE="$(jq -r '.feature // "feature"' "$RUN_DIR/plan.json" 2>/dev/null || echo feature)"
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
APPROVAL_PORT=""
if [ -f "$RUN_DIR/launch.json" ]; then
    APPROVAL_PORT="$(jq -r '.ports.approval // empty' "$RUN_DIR/launch.json" 2>/dev/null || true)"
fi
if [ -z "$APPROVAL_PORT" ]; then
    APPROVAL_PORT="${SIGNALBOX_APPROVAL_PORT:-}"
fi
if [ -z "$APPROVAL_PORT" ]; then
ENV
printf '    APPROVAL_PORT=%q\n' "$PORT_BASE" >>"$DEST/bin/_env.sh"
cat >>"$DEST/bin/_env.sh" <<'ENV'
fi
export ROOT RUN_SLUG RUN_DIR LEDGER_DIR REPO_ROOT WT_BASE FEATURE BASE_BRANCH INT_BRANCH INT_WT GATE_DIR ENGINE_PREFIX SEED_WORKDIR GATE_CMD APPROVAL_PORT
ENV

chmod +x "$DEST"/bin/*.sh

# The sink service is machine-wide and shared by every repo and run, so a
# second repo install simply refreshes the canonical copy. Observability must
# never fail a harness install if the user systemd service cannot be ensured.
"$DEST/bin/sink-service.sh" ensure || true

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

if [ "$REINSTALL_ACTIVE" -eq 1 ]; then
    echo "refreshed: $DEST (in place)"
    echo "preserved: $DEST/runs/ and $DEST/state/ readiness ledger"
else
    echo "installed: $DEST"
fi
echo "engines:   $REPO-pipeline (+ $REPO-init, $REPO-plan, $REPO-implement-stream, $REPO-review-loop)"
echo "gate:      $GATE_CMD"
echo "observe:   shared dashboard http://127.0.0.1:${SIGNALBOX_SINK_PORT:-8099}/ (SIGNALBOX_SINK_PORT); unit signalbox-sink.service; status: $DEST/bin/sink-service.sh status; approval webhook port $PORT_BASE reserved in $PORT_REG"
echo "next:      $DEST/bin/init-run.sh                                 (fill the vault once; stops itself when all three docs land)"
echo "           $DEST/bin/run.sh <issue>                              (concurrent run; artifacts under $DEST/runs/<slug>/)"
echo "single:    SIGNALBOX_ISSUE=<n> emergent --config $DEST/pipeline.toml"
