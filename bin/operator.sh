#!/usr/bin/env bash
# Pipeline operator: stdin = phase.done {issue, phase, outcome, log}
# stdout = phase.verified (input + {verdict, reason, parked, provenance})
#
# Headless Opus applies the phantom-run discipline as topology: never trust
# the runner's outcome, verify the phase's disk artifacts first-hand, then
# PROCEED or HALT. Review and implement prompts carry harness-captured branch
# evidence including tip-pinned file content identity, and the operator is
# granted exact `git show <tip>:<path>` reads for those files. Review also
# carries the park hold re-verified at operator time; review and promote carry
# live integration-worktree evidence. Fail-safe: an unparseable verdict is a
# HALT — when the operator can't be understood, the pipeline stops.
set -euo pipefail
# shellcheck source=_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/_env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/_provenance.sh"
# shellcheck source=_liveness.sh
source "$(dirname "${BASH_SOURCE[0]}")/_liveness.sh"

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

# The fields the hold re-check needs, read out of one snapshot of the record. A
# value of the wrong type reads as absent rather than being coerced: a claim
# that a webhook is live must never rest on a coerced field. Empty columns are
# emitted as "-" because tab is IFS whitespace and adjacent empties would
# otherwise collapse into one another.
park_record_fields() {
    jq -er '
        if type != "object" then
            error("park record is not an object")
        else
            .
        end
        | [
            (if .held == true then "true" else "false" end),
            (.pid
             | if type == "number" and . > 0 and floor == . then
                   (floor | tostring)
               elif type == "string" and test("^[1-9][0-9]*$") then
                   .
               else
                   "-"
               end),
            (.start_id | if type == "string" and length > 0 then . else "-" end),
            (.since | if type == "string" and length > 0 then . else "-" end),
            (.deadline
             | if type == "number" and . >= 0 and floor == . then
                   (floor | tostring)
               elif type == "string" and length > 0 then
                   .
               else
                   "-"
               end)
        ]
        | @tsv
    ' 2>/dev/null
}

# A process that has exited but has not yet been reaped stays in /proc as a
# zombie: kill(0) still succeeds and its start identity is unchanged, so pid
# liveness paired with start identity cannot tell it apart from the running
# engine — while its listening socket is already gone. The held engine's parent
# is the detached reaper, which collects it only at its own deadline, so that
# window is real rather than theoretical. The state field in /proc/<pid>/stat is
# what separates them. Fields 3+ follow the LAST ')', because comm (field 2) may
# itself hold spaces and parens; the state is the first of those. Prints nothing
# and returns 1 when /proc cannot answer.
proc_state() {
    local PID_VALUE="${1:-}" STAT_LINE=""
    local -a FIELDS=()

    [[ "$PID_VALUE" =~ ^[1-9][0-9]*$ ]] || return 1
    STAT_LINE="$(cat "/proc/$PID_VALUE/stat" 2>/dev/null)" || return 1
    read -ra FIELDS <<<"${STAT_LINE##*)}"
    [ "${#FIELDS[@]}" -ge 1 ] && [ -n "${FIELDS[0]}" ] || return 1
    printf '%s\n' "${FIELDS[0]}"
}

# park.json records what the supervisor observed when it made the hold, so a
# recorded `held: true` is evidence of a past claim, never of a live endpoint:
# by the time this operator runs the held engine may have exited, its pid may
# have been recycled onto an unrelated process, or the park deadline may have
# elapsed, and the record on disk still reads the same. The hold is therefore
# re-established here from /proc and the clock: the recorded pid must still be
# the same process by start identity, must not merely be its own unreaped
# corpse, and must still have park deadline left. One sentence describing the
# outcome is printed either way; status 0 means the approval window is open at
# this instant. Anything that cannot be established — no pid, no recorded start
# identity, unreadable /proc, an unevaluable deadline — is a closed window
# rather than a hopeful one, because handing a human a dead endpoint costs more
# than an unnecessary relaunch of the review phase.
park_hold_status() {
    local RECORDED="$1" PID_VALUE="$2" START_VALUE="$3"
    local SINCE="$4" DEADLINE="$5"
    local CURRENT_IDENTITY="" CURRENT_STATE=""
    local NOW_EPOCH="" SINCE_EPOCH="" EXPIRES_EPOCH=""

    if [ "$RECORDED" != "true" ]; then
        printf 'the record itself reports no hold, so no approval window was opened'
        return 1
    fi
    if [ -z "$PID_VALUE" ]; then
        printf 'the record claims a hold but carries no usable pid, so no holding engine can be established'
        return 1
    fi
    if ! pid_alive "$PID_VALUE"; then
        printf 'the holding engine (pid %s) is no longer running, so the approval window is closed' \
            "$PID_VALUE"
        return 1
    fi
    if [ -z "$START_VALUE" ]; then
        printf 'pid %s is alive but the record carries no start identity, so a recycled pid cannot be ruled out and the window cannot be called live' \
            "$PID_VALUE"
        return 1
    fi
    CURRENT_IDENTITY="$(proc_identity "$PID_VALUE" 2>/dev/null || true)"
    if [ -z "$CURRENT_IDENTITY" ]; then
        printf '/proc cannot supply a current start identity for pid %s, so the hold cannot be confirmed live' \
            "$PID_VALUE"
        return 1
    fi
    if [ "$CURRENT_IDENTITY" != "$START_VALUE" ]; then
        printf 'pid %s now names a different process (start identity %s, recorded %s), so the approval window is closed' \
            "$PID_VALUE" "$CURRENT_IDENTITY" "$START_VALUE"
        return 1
    fi
    CURRENT_STATE="$(proc_state "$PID_VALUE" 2>/dev/null || true)"
    if [ -z "$CURRENT_STATE" ]; then
        printf '/proc cannot supply a current state for pid %s, so the hold cannot be confirmed live' \
            "$PID_VALUE"
        return 1
    fi
    # Z is an exited process still held open by its unreaped exit status; X and
    # x are one already being torn down. All three keep answering kill(0) and
    # keep their recorded start identity, and none of them still holds a socket.
    # A state that is not a single letter is not the kernel's state field at
    # all, so it decides nothing and the hold stays unconfirmed.
    case "$CURRENT_STATE" in
        Z | X | x)
            printf 'pid %s has already exited (process state %s) and only awaits reaping, so its approval socket is closed and the window with it' \
                "$PID_VALUE" "$CURRENT_STATE"
            return 1
            ;;
        [A-Za-z]) ;;
        *)
            printf '/proc did not yield a readable process state for pid %s, so the hold cannot be confirmed live' \
                "$PID_VALUE"
            return 1
            ;;
    esac

    NOW_EPOCH="$(date -u +%s 2>/dev/null || true)"
    case "$NOW_EPOCH" in
        "" | *[!0-9]*)
            printf 'the current time could not be read, so the park deadline cannot be checked and the window cannot be called live'
            return 1
            ;;
    esac
    # The deadline is recorded as the grace in seconds that runs from `since`;
    # an absolute instant is read as one too, so whichever form the record
    # carries is evaluated as itself instead of being mistaken for the other.
    case "$DEADLINE" in
        "") ;;
        *[!0-9]*)
            EXPIRES_EPOCH="$(date -u -d "$DEADLINE" +%s 2>/dev/null || true)"
            ;;
        *)
            if [ -n "$SINCE" ]; then
                SINCE_EPOCH="$(date -u -d "$SINCE" +%s 2>/dev/null || true)"
                case "$SINCE_EPOCH" in
                    "" | *[!0-9]*) SINCE_EPOCH="" ;;
                esac
                if [ -n "$SINCE_EPOCH" ]; then
                    EXPIRES_EPOCH="$((SINCE_EPOCH + DEADLINE))"
                fi
            fi
            ;;
    esac
    case "$EXPIRES_EPOCH" in
        "" | *[!0-9]*)
            printf 'the park deadline could not be evaluated (since %s, deadline %s), so the window cannot be called live' \
                "${SINCE:-unrecorded}" "${DEADLINE:-unrecorded}"
            return 1
            ;;
    esac
    if [ "$NOW_EPOCH" -ge "$EXPIRES_EPOCH" ]; then
        printf 'the park deadline elapsed %ss ago, so the approval window is closed' \
            "$((NOW_EPOCH - EXPIRES_EPOCH))"
        return 1
    fi
    printf 'pid %s is running under its recorded start identity and %ss of the park deadline remain, so the approval webhook is live' \
        "$PID_VALUE" "$((EXPIRES_EPOCH - NOW_EPOCH))"
    return 0
}

# At a review park the supervisor writes the engine hold record before the
# operator runs. Capture it in the harness shell instead of asking the model to
# infer liveness from an engine log — and re-verify the hold here, because the
# record says what was true when the park was made, not what is true now. The
# presented `held` is this re-verification; the record's own claim stays visible
# as `recorded_held`, and `hold_check` states the basis either way. As with
# worktree evidence, a present record that cannot be read as an object becomes
# explicit unavailable evidence rather than failing this handler.
if [ "$PHASE" = "review" ] && [ -e "$RUN_DIR/state/park.json" ]; then
    PARK_EVIDENCE="(park record unavailable or malformed)"
    # One read, so the re-check and the presented lines describe the same
    # record even if the supervisor replaces it meanwhile.
    PARK_RECORD="$(cat "$RUN_DIR/state/park.json" 2>/dev/null || true)"
    if PARK_FIELDS="$(park_record_fields <<<"$PARK_RECORD")"; then
        IFS=$'\t' read -r \
            RECORDED_HELD PARK_PID PARK_START PARK_SINCE PARK_DEADLINE \
            <<<"$PARK_FIELDS" || true
        # The "-" sentinels stand for columns the record did not usably carry.
        [ "$PARK_PID" != "-" ] || PARK_PID=""
        [ "$PARK_START" != "-" ] || PARK_START=""
        [ "$PARK_SINCE" != "-" ] || PARK_SINCE=""
        [ "$PARK_DEADLINE" != "-" ] || PARK_DEADLINE=""

        HELD_NOW="false"
        if HOLD_CHECK="$(
            park_hold_status "$RECORDED_HELD" "$PARK_PID" "$PARK_START" \
                "$PARK_SINCE" "$PARK_DEADLINE"
        )"; then
            HELD_NOW="true"
        fi
        HOLD_CHECKED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        if CAPTURED_PARK_EVIDENCE="$(
            jq -er \
                --arg held "$HELD_NOW" \
                --arg hold_check "$HOLD_CHECK" \
                --arg hold_checked_at "$HOLD_CHECKED_AT" \
                '[
                    "- held: \($held)",
                    "- recorded_held: \(.held | tojson)",
                    "- hold_checked_at: \($hold_checked_at)",
                    "- hold_check: \($hold_check)",
                    "- approve_url: \(.approve_url | tojson)",
                    "- approve_command: \(.approve_command | tojson)",
                    "- pid: \(.pid | tojson)",
                    "- start_id: \(.start_id | tojson)",
                    "- deadline: \(.deadline | tojson)",
                    "- since: \(.since | tojson)",
                    "- lease_transferred: \(.lease_transferred | tojson)",
                    "- reason: \(.reason | tojson)"
                ] | join("\n")' <<<"$PARK_RECORD" 2>/dev/null
        )" && [ -n "$CAPTURED_PARK_EVIDENCE" ]; then
            PARK_EVIDENCE="$CAPTURED_PARK_EVIDENCE"
        fi
    fi
    PROMPT="$PROMPT

## Park hold evidence (harness-captured live at operator time)

$PARK_EVIDENCE"
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

# Git imposes no encoding on a pathname — any byte but NUL and `/` is legal —
# while jq speaks UTF-8 and its --arg replaces every byte that is not part of a
# valid sequence with U+FFFD. Two distinct paths differing only in such bytes
# would therefore publish as one identical string, so the evidence's exact-path
# claim would be false precisely where it matters: one real file would be
# described twice and the other not at all. This emits the path fields for one
# entry, so every published path stays reversible to the bytes git holds.
#
# The test is a round trip through jq itself rather than any separate notion of
# validity: jq is the encoder whose fidelity is in question, so nothing else can
# be authoritative about what survives it. The sentinel is what makes the
# comparison exact — command substitution strips trailing newlines, and a path
# may end in one — so only a genuine substitution reads as a mismatch. A path
# that survives is published literally under `path`; one that does not is
# published as base64 of its exact bytes under `path_base64`, marked by
# `path_encoding` so a reader knows which field it is holding and can invert it.
# Both forms are published output only: every git lookup uses the raw value.
path_fields() {
    local RAW="$1"
    local ROUND_TRIP=""

    ROUND_TRIP="$(jq -nr --arg path "$RAW" '$path + "."' 2>/dev/null || true)"
    if [ "$ROUND_TRIP" = "$RAW." ]; then
        jq -nc --arg path "$RAW" '{path: $path}'
        return 0
    fi
    jq -nc \
        --arg path_base64 "$(printf '%s' "$RAW" | base64 | tr -d '\n')" \
        --arg path_encoding "base64" \
        '{path_base64: $path_base64, path_encoding: $path_encoding}'
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
    local FILES_JSON="[]"
    local DIFFSTAT=""
    local FILE_COUNT=0
    local FILE_PATH=""
    local PATH_FIELDS=""
    local ENTRY_META=""
    local ENTRY_TYPE=""
    local ENTRY_OID=""
    local BLOB=""
    local SIZE=""
    local LINES=""
    local LINES_JSON="null"
    local PINNED_READ=""
    local ENTRY=""
    local TIP_FILES="[]"
    local TIP_FILES_TRUNCATED="false"
    local -a CHANGED_PATHS=()
    local -a FILE_PATH_OBJECTS=()
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
    )" || ! DIFFSTAT="$(
        git -C "$REPO_ROOT" -c core.quotePath=false \
            diff --stat "$BASE_TIP...$BRANCH_TIP" 2>/dev/null
    )" || ! git -C "$REPO_ROOT" diff --name-only -z \
        "$BASE_TIP...$BRANCH_TIP" >/dev/null 2>&1; then
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

    # Only -z lists paths verbatim. Line-delimited --name-only C-quotes any path
    # carrying a quote, a backslash, a tab, or a newline (core.quotePath governs
    # non-ASCII alone), and that spelling is not the tree's path: the lookup
    # below would miss and call a real file absent, while the published list
    # would name paths the branch does not contain. Command substitution cannot
    # carry NUL bytes, so the records are read straight into an array, and every
    # later use is built from those exact values. The probe above is what proves
    # git could compare at all: a process substitution would hide git's exit
    # status behind mapfile's own.
    mapfile -t -d '' CHANGED_PATHS < <(
        git -C "$REPO_ROOT" diff --name-only -z \
            "$BASE_TIP...$BRANCH_TIP" 2>/dev/null
    )

    for FILE_PATH in ${CHANGED_PATHS[@]+"${CHANGED_PATHS[@]}"}; do
        [ -n "$FILE_PATH" ] || continue
        # The published list is encoded from the exact delimited value rather
        # than re-split out of a rendering, so it stays the tree's own paths. A
        # path jq can carry verbatim stays a bare string here, as the file set
        # has always read; one it cannot becomes the same marked object the tip
        # entries use, which is what keeps two such paths distinguishable.
        PATH_FIELDS="$(path_fields "$FILE_PATH")"
        FILE_PATH_OBJECTS+=("$(
            jq -c 'if has("path") then .path else . end' <<<"$PATH_FIELDS"
        )")
        FILE_COUNT=$((FILE_COUNT + 1))
        if [ "$FILE_COUNT" -gt "$TIP_FILES_LIMIT" ]; then
            continue
        fi

        # The tree entry's own type decides what may be claimed about it. A
        # gitlink is a present entry whose target commit normally lives in the
        # submodule's object store rather than this one, so questioning the
        # object database about it reads as absence; only a blob has a size, a
        # line count, or content a pinned read can return. The pathspec is read
        # against the whole tree, matching the diff's root-relative paths, and
        # forced literal so a path carrying `*`, `?`, or `[` describes itself
        # instead of matching its neighbours.
        ENTRY_META=""
        if ! ENTRY_META="$(
            GIT_LITERAL_PATHSPECS=1 git -C "$REPO_ROOT" ls-tree \
                --full-tree "$BRANCH_TIP" -- "$FILE_PATH" 2>/dev/null
        )" || [ -z "$ENTRY_META" ]; then
            TIP_FILE_OBJECTS+=("$(
                jq -nc \
                    --argjson path_fields "$PATH_FIELDS" \
                    --argjson present false \
                    '$path_fields + {present: $present}'
            )")
            continue
        fi
        # `<mode> SP <type> SP <object> TAB <path>`; the path is already known,
        # and is the only field ls-tree may quote, so it is discarded here.
        ENTRY_TYPE=""
        ENTRY_OID=""
        read -r _ ENTRY_TYPE ENTRY_OID <<<"${ENTRY_META%%$'\t'*}"

        case "$ENTRY_TYPE" in
            blob) ;;
            commit)
                TIP_FILE_OBJECTS+=("$(
                    jq -nc \
                        --argjson path_fields "$PATH_FIELDS" \
                        --argjson present true \
                        --arg type "gitlink" \
                        --arg commit "$ENTRY_OID" \
                        '$path_fields + {
                            present: $present,
                            type: $type,
                            commit: $commit
                        }'
                )")
                continue
                ;;
            *)
                TIP_FILE_OBJECTS+=("$(
                    jq -nc \
                        --argjson path_fields "$PATH_FIELDS" \
                        --argjson present true \
                        --arg type "$ENTRY_TYPE" \
                        '$path_fields + {present: $present, type: $type}'
                )")
                continue
                ;;
        esac

        BLOB="$ENTRY_OID"
        SIZE=""
        if ! SIZE="$(
            git -C "$REPO_ROOT" cat-file -s "$BLOB" 2>/dev/null
        )"; then
            # The entry is in the tree, so it is present whatever the object
            # database can still say about it; it simply has no measurable size.
            TIP_FILE_OBJECTS+=("$(
                jq -nc \
                    --argjson path_fields "$PATH_FIELDS" \
                    --argjson present true \
                    --arg type "blob" \
                    --arg blob "$BLOB" \
                    '$path_fields + {
                        present: $present,
                        type: $type,
                        blob: $blob
                    }'
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
                --argjson path_fields "$PATH_FIELDS" \
                --argjson present true \
                --arg type "blob" \
                --arg blob "$BLOB" \
                --argjson size "$SIZE" \
                --argjson lines "$LINES_JSON" \
                --arg pinned_read "$PINNED_READ" \
                '$path_fields + {
                    present: $present,
                    type: $type,
                    blob: $blob,
                    size: $size,
                    lines: $lines
                } + if $pinned_read == "" then {}
                    else {pinned_read: $pinned_read}
                    end'
        )"
        TIP_FILE_OBJECTS+=("$ENTRY")
    done

    if [ "${#FILE_PATH_OBJECTS[@]}" -gt 0 ]; then
        FILES_JSON="$(
            printf '%s\n' "${FILE_PATH_OBJECTS[@]}" | jq -sc '.'
        )"
    fi
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
        --argjson files "$FILES_JSON" \
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
            files: $files,
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
