# Process-liveness helpers and the reinstall/launch lock. Sourced, not
# executed; this file does not change shell options and has no dependency on
# _env.sh or its variables.
#
# Functions:
#   pid_alive <pid>
#     stdout: empty
#     status: 0 when pid is a positive integer and kill(0) succeeds; 1 otherwise
#   proc_identity <pid>
#     stdout: "<boot epoch>:<start time in clock ticks>" when available
#     status: 0 when /proc supplies an identity; 1 for malformed pid or failure
#   owner_live <pid> <recorded-identity>
#     stdout: empty
#     status: 0 when the recorded owner is conservatively still live; 1 otherwise
#   live_runs <runs-dir>
#     stdout: one "<slug>\t<pid>\t<phase>" line per live launched engine
#     status: always 0; launch metadata that is unparseable, not an object, or
#             carries a field of the wrong type or value is skipped with a
#             warning on stderr rather than coerced
#   install_lock <harness-root> shared|exclusive
#     stdout: empty
#     status: 0 once <harness-root>/.install.lock is held on fd 9; 1 with a
#             diagnostic on stderr. Creates nothing under state/.
#   install_unlock
#     stdout: empty
#     status: always 0
# shellcheck shell=bash

pid_alive() {
    local PID_VALUE="${1:-}"

    [[ "$PID_VALUE" =~ ^[1-9][0-9]*$ ]] && kill -0 "$PID_VALUE" 2>/dev/null
}

# Exact process start identity: "<boot epoch>:<start time in clock ticks>",
# both read from /proc. A PID is not an identity — the kernel recycles it, so
# after a crash or reboot an unrelated process can inherit a dead owner's PID.
# The start time distinguishes them; pairing it with btime keeps it exact
# across reboots, which reset both the boot epoch and the tick origin. Prints
# nothing and returns 1 when /proc cannot answer.
proc_identity() {
    local PID_VALUE="${1:-}" STAT_LINE="" BTIME=""
    local -a FIELDS=()

    [[ "$PID_VALUE" =~ ^[1-9][0-9]*$ ]] || return 1
    STAT_LINE="$(cat "/proc/$PID_VALUE/stat" 2>/dev/null)" || return 1
    # comm (field 2) may hold spaces and parens; fields 3+ follow the LAST ')',
    # so starttime (field 22) is the 20th field of the remainder.
    read -ra FIELDS <<<"${STAT_LINE##*)}"
    [ "${#FIELDS[@]}" -ge 20 ] || return 1
    [[ "${FIELDS[19]}" =~ ^[0-9]+$ ]] || return 1
    BTIME="$(awk '/^btime /{print $2; exit}' /proc/stat 2>/dev/null)" || return 1
    [[ "$BTIME" =~ ^[0-9]+$ ]] || return 1
    printf '%s:%s\n' "$BTIME" "${FIELDS[19]}"
}

# An owner still runs only when its PID is alive AND still names the same
# process. No recorded identity (metadata from before this field existed), or
# no readable /proc (non-Linux, torn read), leaves liveness as the only
# available evidence; treating the owner as live is the conservative verdict.
owner_live() {
    local PID_VALUE="${1:-}" RECORDED="${2:-}" CURRENT=""

    pid_alive "$PID_VALUE" || return 1
    [ -n "$RECORDED" ] || return 0
    CURRENT="$(proc_identity "$PID_VALUE" || true)"
    [ -n "$CURRENT" ] || return 0
    [ "$CURRENT" = "$RECORDED" ]
}

live_runs() (
    local RUNS_DIR="${1:-}" LAUNCH="" RECORD=""
    local SLUG_VALUE="" PID_VALUE="" START_VALUE="" PHASE_VALUE=""
    local -a LAUNCH_FILES=()

    [ -n "$RUNS_DIR" ] || return 0
    shopt -s nullglob
    LAUNCH_FILES=("$RUNS_DIR"/*/launch.json)
    for LAUNCH in "${LAUNCH_FILES[@]}"; do
        # Fields are validated, never coerced: tostring would happily turn an
        # object slug or a boolean phase into a plausible-looking column, so a
        # record whose shape or field types are wrong is an error here and is
        # reported as invalid metadata below. Absent or null fields stay
        # tolerated — older metadata predates start_id.
        if ! RECORD="$(jq -er '
            def text_field($name):
                .[$name] as $value
                | if $value == null then "-"
                  elif ($value | type) != "string" then
                      error("\($name) is not a string")
                  elif $value == "" then "-"
                  else $value
                  end;
            def pid_field:
                .pid as $value
                | if $value == null then "-"
                  elif ($value | type) == "number" then
                      # floor before tostring: jq preserves the original numeric
                      # literal, so a whole-number pid written as 1234.0 or
                      # 1.234e3 would otherwise print in that form and fail
                      # pid_alive. Flooring produces the plain digits.
                      (if ($value | floor) == $value and $value > 0
                       then ($value | floor | tostring)
                       else error("pid is not a positive whole number")
                       end)
                  elif ($value | type) != "string" then
                      error("pid is not a number")
                  elif $value == "" then "-"
                  elif ($value | test("^[1-9][0-9]*$")) then $value
                  else error("pid is not a positive whole number")
                  end;
            if type != "object" then error("record is not an object") else . end
            | [
                text_field("slug"),
                pid_field,
                text_field("start_id"),
                text_field("phase")
            ]
            | @tsv' "$LAUNCH" 2>/dev/null)"; then
            printf 'warning: invalid launch metadata: %s\n' "$LAUNCH" >&2 || true
            continue
        fi
        IFS=$'\t' read -r \
            SLUG_VALUE PID_VALUE START_VALUE PHASE_VALUE <<<"$RECORD" || true
        # Tab is IFS whitespace, so empty columns would collapse into their
        # neighbours: jq emits "-" sentinels and they are restored here.
        [ "$SLUG_VALUE" != "-" ] || SLUG_VALUE=""
        [ "$PID_VALUE" != "-" ] || PID_VALUE=""
        [ "$START_VALUE" != "-" ] || START_VALUE=""
        [ "$PHASE_VALUE" != "-" ] || PHASE_VALUE=""

        if owner_live "$PID_VALUE" "$START_VALUE"; then
            printf '%s\t%s\t%s\n' "$SLUG_VALUE" "$PID_VALUE" "$PHASE_VALUE" || true
        fi
    done
    return 0
)

# A liveness scan is only a snapshot: an engine launched after the installer
# scanned and before it finished rebuilding would be invisible to the scan and
# would then run under a half-refreshed bin/. Reinstall and launcher startup
# therefore serialize on one lock file. It sits at the harness root, not under
# state/: reinstall must not touch runs/, state/, logs/ or results/ at all, and
# coordination metadata is the installer's, not the repo's earned ledger. The
# root itself survives a refresh — only bin/, prompts/ and templates/ are
# rebuilt — so the lock keeps its identity across reinstalls. Launchers hold it
# shared — they never exclude each other — for their startup window alone, from
# before they inspect existing run state until launch.json records the new
# engine; the installer holds it exclusively from before its liveness scan
# until the refresh is complete. So a launcher either recorded its engine in
# time for the scan to refuse, or waits for a finished harness. Fd 9 is this
# repo's lock-descriptor convention.
SIGNALBOX_LOCK_HELD=0

install_lock() {
    local ROOT_DIR="${1:-}" MODE="${2:-}" LOCK_FILE="" MODE_FLAG=""
    local WAIT_SECONDS="${SIGNALBOX_LOCK_WAIT:-60}"

    case "$MODE" in
        shared) MODE_FLAG="-s" ;;
        exclusive) MODE_FLAG="-x" ;;
        *)
            printf 'error: install lock mode must be shared or exclusive\n' >&2
            return 1
            ;;
    esac
    if [ -z "$ROOT_DIR" ]; then
        printf 'error: install lock needs a harness root\n' >&2
        return 1
    fi
    if ! command -v flock >/dev/null 2>&1; then
        printf 'error: flock is missing — reinstall and bin/run.sh coordinate through it\n' >&2
        return 1
    fi
    [[ "$WAIT_SECONDS" =~ ^[0-9]+$ ]] || WAIT_SECONDS=60
    LOCK_FILE="$ROOT_DIR/.install.lock"
    # Append mode, never truncate: the file is a lock, and a concurrent holder
    # has it open. Nothing is ever written to it. Only the harness root is
    # created — never state/, which this feature must leave alone.
    if ! mkdir -p "$ROOT_DIR" 2>/dev/null \
        || ! touch "$LOCK_FILE" 2>/dev/null; then
        printf 'error: cannot create the install lock: %s\n' "$LOCK_FILE" >&2
        return 1
    fi
    exec 9>>"$LOCK_FILE"
    SIGNALBOX_LOCK_HELD=1
    if ! flock "$MODE_FLAG" -w "$WAIT_SECONDS" 9; then
        install_unlock
        printf 'error: timed out after %ss waiting for the install lock %s — another reinstall or launch holds it\n' \
            "$WAIT_SECONDS" "$LOCK_FILE" >&2
        return 1
    fi
    return 0
}

# Closing the descriptor releases the lock. Children that inherited it keep it
# held until they close their own copy, so any long-lived child must be spawned
# with fd 9 closed.
install_unlock() {
    [ "${SIGNALBOX_LOCK_HELD:-0}" -eq 1 ] || return 0
    exec 9>&-
    SIGNALBOX_LOCK_HELD=0
    return 0
}
