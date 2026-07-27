#!/usr/bin/env bash
# Pipeline operator: stdin = phase.done {issue, phase, outcome, log, correlation_id}
# stdout = phase.verified (input + {verdict, reason, parked, provenance})
#
# Headless Opus applies the phantom-run discipline as topology: never trust
# the runner's outcome, verify the phase's disk artifacts first-hand, then
# PROCEED or HALT. Review and implement prompts carry harness-captured branch
# evidence including tip-pinned file content identity, and the operator is
# granted exact `git show <tip>:<path>` reads for those files. Review and
# promote also carry live integration-worktree evidence. Fail-safe: an
# unparseable verdict is a HALT — when the operator can't be understood, the
# pipeline stops.
set -euo pipefail
# shellcheck source=_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/_env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/_provenance.sh"

# Bound prompt and permission-rule growth when a branch changes many files.
TIP_FILES_LIMIT=40
# Avoid streaming arbitrarily large blobs merely to count their lines.
TIP_FILE_MAX_BYTES=1048576

PAYLOAD="$(cat)"
PHASE="$(jq -r '.phase' <<<"$PAYLOAD")"
OUTCOME="$(jq -r '.outcome' <<<"$PAYLOAD")"
ISSUE="$(jq -r '.issue' <<<"$PAYLOAD")"
LOG="$(jq -r '.log' <<<"$PAYLOAD")"

mkdir -p "$RUN_DIR/logs"
OUT="$RUN_DIR/logs/operator-$PHASE.md"
RUN_DISPLAY="$RUN_SLUG"
[ -n "$RUN_DISPLAY" ] || RUN_DISPLAY="(single-run)"

# A permission rule is an exact command string, so the worktree path has to be
# embedded as a single shell word. An unescaped path carrying a space or a
# metacharacter is parsed as several words (or as shell syntax) when the
# operator runs the rule verbatim, while the quoting the operator would
# naturally add makes the command no longer match the rule — either way the
# corroborating check is unavailable. printf %q yields a form that is both one
# shell word and the exact text of the rule, and the same string is published
# to the prompt below so the operator runs precisely what was granted.
INT_WT_STATUS_CMD=""
if [ -d "$INT_WT" ]; then
    INT_WT_STATUS_CMD="git -C $(printf '%q' "$INT_WT") status --porcelain"
fi

PROMPT="$(cat "$ROOT/prompts/operator.md")

## This phase

- phase: $PHASE
- issue: #$ISSUE
- runner-reported outcome: $OUTCOME (verify it — do not trust it)
- harness root: $ROOT
- run root: $RUN_DIR
- run slug: $RUN_DISPLAY
- repo root: $REPO_ROOT
- worktree home: $WT_BASE
- integration worktree: $INT_WT
- integration worktree status command: ${INT_WT_STATUS_CMD:-(not granted: no integration worktree yet)}
- base branch: $BASE_BRANCH
- engine log: $LOG

## Engine log tail (runner's view, last 30 lines)

$(tail -30 "$LOG" 2>/dev/null || echo "(log unreadable)")"

# The harness shell can inspect the integration worktree without model-tool
# permission mediation, so this is the live evidence route that cannot be
# denied. Keep recorder failure non-fatal: unavailable evidence must become
# explicit operator input rather than aborting the pipeline handler.
if [ "$PHASE" = "review" ] || [ "$PHASE" = "promote" ]; then
    WORKTREE_EVIDENCE="(worktree evidence unavailable)"
    if CAPTURED_WORKTREE_EVIDENCE="$(
        "$(dirname "${BASH_SOURCE[0]}")/worktree-evidence.sh" "$INT_WT"
    )" && [ -n "$CAPTURED_WORKTREE_EVIDENCE" ]; then
        WORKTREE_EVIDENCE="$CAPTURED_WORKTREE_EVIDENCE"
    fi
    CAPTURED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    PROMPT="$PROMPT

## Worktree evidence (harness-captured live at operator time)

- integration worktree: $INT_WT
- captured: $CAPTURED_AT
$WORKTREE_EVIDENCE"
fi

# The worktrees this operator must inspect are siblings of REPO_ROOT, so the
# session's default allowed directory cannot reach them and every check of the
# integration worktree was permission-denied (issue #12). WT_BASE rather than
# INT_WT so shard worktrees stay visible to future checks. Guarded because the
# worktree home does not exist until bin/plan-seed.sh creates it during the
# first implement phase — handing claude a nonexistent --add-dir path would
# break the plan-phase operator instead of unblocking it.
ADD_DIR=()
if [ -d "$WT_BASE" ]; then
    ADD_DIR=(--add-dir "$WT_BASE")
fi

# A path grant only makes the worktree visible; acceptEdits still denies Bash
# commands unless the invocation is allowed. Every rule below is one whole
# command with no trailing wildcard: a `:*` suffix admits arbitrary trailing
# arguments, so `git log`/`git diff`/`git show` would gain `--output=<file>`
# and `symbolic-ref`/`branch` their write modes (ref updates, -d/-D deletion,
# -m renaming). Exact forms keep the operator unable to mutate any state.
#
# The ref-bearing forms prompts/operator.md asks for at implement cannot be
# written as constants, so they are spelled out from this run's own plan and
# from the configured base branch. Both refs are validated first: a rule is an
# exact command string, and git permits branch names carrying `;`, `&`, or
# `$(...)`, which would be parsed as shell syntax inside the rule. Anything
# that is not a plain ref token simply yields no rule bearing that ref rather
# than an unbounded or command-injecting one.
#
# The slug is accepted only when it is a kebab-case token — anything else
# (missing, unreadable, or carrying shell or path characters) simply yields
# no ref-bearing rules rather than an unbounded one.
FEATURE_BRANCH=""
if [ -r "$RUN_DIR/plan.json" ]; then
    FEATURE_SLUG="$(jq -r '.feature // ""' "$RUN_DIR/plan.json" 2>/dev/null || true)"
    case "$FEATURE_SLUG" in
        "" | -* | *- | *[!a-z0-9-]*) ;;
        *) FEATURE_BRANCH="feat/$FEATURE_SLUG" ;;
    esac
fi

# The base branch comes from _env.sh, not from a per-run artifact, but the
# installer imposes no narrower contract than git's own ref rules, so it is
# validated on the same terms as the slug: a plain ref token (letters, digits,
# `.`, `_`, `/`, `-`), never leading `-`, never `..`, never a trailing `/`.
SAFE_BASE=""
case "$BASE_BRANCH" in
    "" | -* | */ | *..* | *[!A-Za-z0-9._/-]*) ;;
    *) SAFE_BASE="$BASE_BRANCH" ;;
esac

# A permission rule is one exact command string, so a path carrying whitespace,
# quotes, `;`, `&`, or `$(...)` has no safe spelling inside it. Such files still
# appear in evidence, but receive no injectable permission grant.
plain_path_token() {
    local PATH_TOKEN="$1"

    case "$PATH_TOKEN" in
        "" | -* | /* | *..* | *[!A-Za-z0-9._/-]*) return 1 ;;
        *) return 0 ;;
    esac
}

# The implement terminal's two mandatory checks — at least one shard commit,
# and a diff confined to plan.json's declared files — are both ref-bearing, and
# a rule is one exact command string. A base branch spelled with `;`, `&`, or
# `$(...)` is legal to git but has no safe spelling inside a rule, so those two
# rules are simply omitted; without a second route such a repository could
# never complete implement verification. The harness shell has no such limit:
# it passes every ref as an argv word that no shell ever parses, so it captures
# the same two facts itself. Both names are resolved inside refs/heads
# explicitly: gitrevisions prefers refs/tags for a bare name, so a tag sharing
# a branch's name would otherwise substitute its history while the evidence
# still reads `resolved: true`. Ranges are built from the resolved object ids,
# not the ref names, so a ref git might read as an option cannot reach a range
# argument. Failure is non-fatal and explicit: unusable evidence must reach the
# operator as a stated error, never abort the pipeline handler.
branch_evidence() {
    local BASE="$1"
    local BRANCH="$2"
    local BASE_TIP=""
    local BRANCH_TIP=""
    local BRANCH_SHORT=""
    local COMMITS=""
    local FILES=""
    local DIFFSTAT=""
    local FILE_COUNT=0
    local FILE_PATH=""
    local BLOB=""
    local SIZE=""
    local LINES=""
    local LINES_JSON="null"
    local PINNED_READ=""
    local ENTRY=""
    local TIP_FILES="[]"
    local TIP_FILES_TRUNCATED="false"
    local -a TIP_FILE_OBJECTS=()

    if ! BASE_TIP="$(
        git -C "$REPO_ROOT" rev-parse --verify --quiet \
            "refs/heads/$BASE^{commit}" 2>/dev/null
    )"; then
        jq -nc \
            --arg base "$BASE" \
            --arg branch "$BRANCH" \
            --argjson resolved false \
            --arg error "base branch does not resolve to a commit" \
            '{base: $base, branch: $branch, resolved: $resolved, error: $error}'
        return 0
    fi
    if ! BRANCH_TIP="$(
        git -C "$REPO_ROOT" rev-parse --verify --quiet \
            "refs/heads/$BRANCH^{commit}" 2>/dev/null
    )"; then
        jq -nc \
            --arg base "$BASE" \
            --arg branch "$BRANCH" \
            --argjson resolved false \
            --arg error "feature branch does not resolve to a commit" \
            '{base: $base, branch: $branch, resolved: $resolved, error: $error}'
        return 0
    fi
    if ! COMMITS="$(
        git -C "$REPO_ROOT" log --oneline "$BASE_TIP..$BRANCH_TIP" 2>/dev/null
    )" || ! FILES="$(
        git -C "$REPO_ROOT" -c core.quotePath=false \
            diff --name-only "$BASE_TIP...$BRANCH_TIP" 2>/dev/null
    )" || ! DIFFSTAT="$(
        git -C "$REPO_ROOT" -c core.quotePath=false \
            diff --stat "$BASE_TIP...$BRANCH_TIP" 2>/dev/null
    )"; then
        jq -nc \
            --arg base "$BASE" \
            --arg branch "$BRANCH" \
            --argjson resolved false \
            --arg error "git could not compare the branches" \
            '{base: $base, branch: $branch, resolved: $resolved, error: $error}'
        return 0
    fi
    # gate.json records the short tip, so the evidence carries that form too.
    BRANCH_SHORT="$(
        git -C "$REPO_ROOT" rev-parse --short "$BRANCH_TIP" 2>/dev/null || true
    )"

    while IFS= read -r FILE_PATH; do
        [ -n "$FILE_PATH" ] || continue
        FILE_COUNT=$((FILE_COUNT + 1))
        if [ "$FILE_COUNT" -gt "$TIP_FILES_LIMIT" ]; then
            continue
        fi

        BLOB=""
        if ! BLOB="$(
            git -C "$REPO_ROOT" rev-parse --verify --quiet \
                "$BRANCH_TIP:$FILE_PATH" 2>/dev/null
        )"; then
            TIP_FILE_OBJECTS+=("$(
                jq -nc \
                    --arg path "$FILE_PATH" \
                    --argjson present false \
                    '{path: $path, present: $present}'
            )")
            continue
        fi

        SIZE=""
        if ! SIZE="$(
            git -C "$REPO_ROOT" cat-file -s "$BLOB" 2>/dev/null
        )"; then
            TIP_FILE_OBJECTS+=("$(
                jq -nc \
                    --arg path "$FILE_PATH" \
                    --argjson present false \
                    '{path: $path, present: $present}'
            )")
            continue
        fi

        LINES_JSON="null"
        if [ "$SIZE" -le "$TIP_FILE_MAX_BYTES" ]; then
            LINES=""
            if LINES="$(
                git -C "$REPO_ROOT" show "$BRANCH_TIP:$FILE_PATH" 2>/dev/null \
                    | wc -l
            )"; then
                LINES="${LINES//[[:space:]]/}"
                case "$LINES" in
                    "" | *[!0-9]*) ;;
                    *) LINES_JSON="$LINES" ;;
                esac
            fi
        fi

        PINNED_READ=""
        if plain_path_token "$FILE_PATH"; then
            PINNED_READ="git show $BRANCH_TIP:$FILE_PATH"
        fi
        ENTRY="$(
            jq -nc \
                --arg path "$FILE_PATH" \
                --argjson present true \
                --arg blob "$BLOB" \
                --argjson size "$SIZE" \
                --argjson lines "$LINES_JSON" \
                --arg pinned_read "$PINNED_READ" \
                '{
                    path: $path,
                    present: $present,
                    blob: $blob,
                    size: $size,
                    lines: $lines
                } + if $pinned_read == "" then {}
                    else {pinned_read: $pinned_read}
                    end'
        )"
        TIP_FILE_OBJECTS+=("$ENTRY")
    done <<<"$FILES"

    if [ "${#TIP_FILE_OBJECTS[@]}" -gt 0 ]; then
        TIP_FILES="$(
            printf '%s\n' "${TIP_FILE_OBJECTS[@]}" | jq -sc '.'
        )"
    fi
    if [ "$FILE_COUNT" -gt "$TIP_FILES_LIMIT" ]; then
        TIP_FILES_TRUNCATED="true"
    fi

    jq -nc \
        --arg base "$BASE" \
        --arg branch "$BRANCH" \
        --argjson resolved true \
        --arg base_tip "$BASE_TIP" \
        --arg branch_tip "$BRANCH_TIP" \
        --arg branch_tip_short "$BRANCH_SHORT" \
        --arg commits "$COMMITS" \
        --arg files "$FILES" \
        --arg diffstat "$DIFFSTAT" \
        --argjson tip_files "$TIP_FILES" \
        --argjson tip_files_truncated "$TIP_FILES_TRUNCATED" \
        --argjson tip_files_limit "$TIP_FILES_LIMIT" \
        '{
            base: $base,
            branch: $branch,
            resolved: $resolved,
            base_tip: $base_tip,
            branch_tip: $branch_tip,
            branch_tip_short: $branch_tip_short,
            commits: ($commits | split("\n") | map(select(length > 0))),
            files: ($files | split("\n") | map(select(length > 0))),
            diffstat: $diffstat,
            tip_files: $tip_files,
            tip_files_truncated: $tip_files_truncated,
            tip_files_limit: $tip_files_limit
        }'
}

BRANCH_EVIDENCE=""
if { [ "$PHASE" = "implement" ] || [ "$PHASE" = "review" ]; } \
    && [ -n "$FEATURE_BRANCH" ]; then
    BRANCH_EVIDENCE="$(branch_evidence "$BASE_BRANCH" "$FEATURE_BRANCH")"
    BRANCH_CAPTURED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    PROMPT="$PROMPT

## Branch evidence (harness-captured live at operator time)

- repo root: $REPO_ROOT
- base branch: $BASE_BRANCH
- feature branch: $FEATURE_BRANCH
- captured: $BRANCH_CAPTURED_AT
$BRANCH_EVIDENCE"
fi

GIT_TOOLS=(
    "Bash(git status --porcelain)"
    "Bash(git rev-parse --short HEAD)"
    "Bash(git symbolic-ref --short HEAD)"
    "Bash(git branch --show-current)"
    "Bash(git branch --list)"
    "Bash(git worktree list)"
)
if [ -n "$SAFE_BASE" ]; then
    GIT_TOOLS+=(
        "Bash(git log origin/$SAFE_BASE --oneline -20)"
        "Bash(git show --stat origin/$SAFE_BASE)"
    )
fi
if [ -n "$FEATURE_BRANCH" ]; then
    GIT_TOOLS+=("Bash(git rev-parse --short $FEATURE_BRANCH)")
    if [ -n "$SAFE_BASE" ]; then
        GIT_TOOLS+=(
            "Bash(git log $SAFE_BASE..$FEATURE_BRANCH --oneline)"
            "Bash(git diff --stat $SAFE_BASE...$FEATURE_BRANCH)"
        )
    fi
fi
if [ -n "$INT_WT_STATUS_CMD" ]; then
    GIT_TOOLS+=("Bash($INT_WT_STATUS_CMD)")
fi
if [ -n "$BRANCH_EVIDENCE" ]; then
    while IFS= read -r PINNED_READ; do
        [ -n "$PINNED_READ" ] || continue
        GIT_TOOLS+=("Bash($PINNED_READ)")
    done < <(
        jq -r '.tip_files[]? | .pinned_read // empty' \
            <<<"$BRANCH_EVIDENCE" 2>/dev/null || true
    )
fi

# Test-only binary seam for tests/operator-evidence.test.sh; production keeps
# resolving the normal claude executable.
CLAUDE_BIN="${SIGNALBOX_OPERATOR_CLAUDE:-claude}"

cd "$REPO_ROOT"
# Read-only gh is explicitly allowed so the operator can confirm PR/issue/CI
# state itself instead of reporting "could not verify" — approved commands
# also run outside the sandbox, which is what blocked gh's network calls.
env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT \
    "$CLAUDE_BIN" -p "$PROMPT" \
    --model opus \
    --permission-mode acceptEdits \
    ${ADD_DIR[@]+"${ADD_DIR[@]}"} \
    --allowedTools \
        "Bash(gh pr view:*)" "Bash(gh pr checks:*)" "Bash(gh pr list:*)" \
        "Bash(gh issue view:*)" "Bash(gh issue list:*)" \
        "Bash(gh run view:*)" "Bash(gh run list:*)" \
        ${GIT_TOOLS[@]+"${GIT_TOOLS[@]}"} \
    >"$OUT" 2>"$OUT.stderr" || true
stamp_provenance "logs/operator-$PHASE.md" claude opus ""

VERDICT_LINE="$(grep -E '^\{.*"verdict".*\}[[:space:]]*$' "$OUT" | tail -1 || true)"

VERDICT="HALT"
REASON="operator output unparseable (see $OUT) — failing safe"
PARKED="false"
if [ -n "$VERDICT_LINE" ] && jq -e . >/dev/null 2>&1 <<<"$VERDICT_LINE"; then
    V="$(jq -r '.verdict // ""' <<<"$VERDICT_LINE")"
    if [ "$V" = "PROCEED" ] || [ "$V" = "HALT" ]; then
        VERDICT="$V"
        REASON="$(jq -r '.reason // ""' <<<"$VERDICT_LINE")"
        PARKED="$(jq -r 'if .parked == true then "true" else "false" end' <<<"$VERDICT_LINE")"
    fi
fi

PROVENANCE="$(provenance_object claude opus "")"
jq -c \
    --arg verdict "$VERDICT" \
    --arg reason "$REASON" \
    --argjson parked "$PARKED" \
    --argjson provenance "$PROVENANCE" \
    '. + {
        verdict: $verdict,
        reason: $reason,
        parked: $parked,
        provenance: $provenance
    }' <<<"$PAYLOAD"
