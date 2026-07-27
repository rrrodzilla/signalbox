# Process-liveness helpers. Sourced, not executed; this file does not change
# shell options and has no dependency on _env.sh or its variables.
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
#     status: always 0; invalid launch metadata is warned about on stderr
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
        if ! RECORD="$(jq -er '[
            (if (.slug // "") == "" then "-" else (.slug | tostring) end),
            (if (.pid // "") == "" then "-" else (.pid | tostring) end),
            (if (.start_id // "") == "" then "-" else (.start_id | tostring) end),
            (if (.phase // "") == "" then "-" else (.phase | tostring) end)
        ] | @tsv' "$LAUNCH" 2>/dev/null)"; then
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
