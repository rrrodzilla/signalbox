#!/usr/bin/env bash
# Point the TRIP docs tree at an Obsidian vault:
#   <vault>/<project-folder>/{1-plans,2-changelog,3-code-review,4-unit-tests,6-memo}
#   .claude/docs -> <vault>/<project-folder>   (absolute symlink)
#
# Every skill keeps reading/writing `.claude/docs/...` — the symlink makes
# those paths land in the vault, and the worktree flow keeps working because
# feature worktrees symlink `.claude` from the primary checkout, whose `docs`
# link is absolute.
#
# Idempotent: re-running with the same vault/folder is a no-op. If
# `.claude/docs` is a real directory (pre-vault install), its content is
# migrated into the vault folder first.
#
# Usage: vault-setup.sh <vault-path> <project-folder>
#   <vault-path>      root of the Obsidian vault (must exist)
#   <project-folder>  folder inside the vault for this project's TRIP docs
#                     (may be nested, e.g. "TRIP/MyProject")
#
# Prints VAULT_DOCS=<absolute path> as the last line on success.
# Exits 64 on usage error, 1 on bad environment.

set -euo pipefail

if [ $# -ne 2 ]; then
    echo "usage: vault-setup.sh <vault-path> <project-folder>" >&2
    exit 64
fi

VAULT="$1"
PROJECT_FOLDER="$2"

if [ ! -d "$VAULT" ]; then
    echo "error: vault path does not exist: $VAULT" >&2
    exit 1
fi
if [ ! -d "$VAULT/.obsidian" ]; then
    echo "warning: no .obsidian/ directory in $VAULT — proceeding, but double-check this is the vault root" >&2
fi

# Must run from the primary checkout: in a feature worktree `.claude` is a
# symlink back to the primary, and the docs link must be created there.
REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"
if [ -L .claude ]; then
    echo "error: .claude is a symlink — run this from the primary checkout, not a feature worktree" >&2
    exit 1
fi

VAULT_ABS="$(cd "$VAULT" && pwd)"
DEST="$VAULT_ABS/$PROJECT_FOLDER"
mkdir -p "$DEST"/1-plans "$DEST"/2-changelog "$DEST"/3-code-review \
         "$DEST"/4-unit-tests "$DEST"/6-memo
mkdir -p .claude

if [ -L .claude/docs ]; then
    CURRENT="$(readlink -f .claude/docs || true)"
    if [ "$CURRENT" != "$DEST" ] && [ -n "$CURRENT" ]; then
        echo "notice: relinking .claude/docs from $CURRENT to $DEST (old location left untouched)" >&2
    fi
elif [ -d .claude/docs ]; then
    echo "migrating existing .claude/docs content into $DEST" >&2
    cp -a .claude/docs/. "$DEST"/
    rm -rf .claude/docs
fi

ln -sfn "$DEST" .claude/docs

# Same local-only exclude TRIP-init installs — harmless if already present.
GIT_COMMON="$(git rev-parse --path-format=absolute --git-common-dir)"
grep -qxF '.claude' "$GIT_COMMON/info/exclude" 2>/dev/null \
    || printf '.claude\n' >> "$GIT_COMMON/info/exclude"

echo "VAULT_DOCS=$DEST"
