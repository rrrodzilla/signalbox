# Language profile helpers. Sourced, not executed; this file does not change
# shell options and does not depend on bin/_env.sh.
#
# Functions:
#   detect_language <dir>
#     Print exactly `rust` when <dir>/Cargo.toml is a regular file, otherwise
#     print `generic`. Return 64 unless given exactly one argument; otherwise
#     return 0, including for a missing or unreadable directory. Detection
#     deliberately checks only the given directory's own root, never ancestors
#     or nested packages, because that directory is the agent's actual workdir.
#   lang_profile <profile>
#     Set and export LANG_PROFILE, LANG_SUBJECT, LANG_SOURCE_SCOPE,
#     LANG_PANICS, LANG_FIX_RULE, LANG_EDIT_SCOPE, and LANG_WIRING. Unknown or
#     empty profiles select generic. Write nothing to stdout. Return 64 unless
#     given exactly one argument; otherwise return 0.
#   render_prompt <file>
#     Print <file> with all six SIGNALBOX language tokens replaced by the
#     current profile values. Select generic first when LANG_PROFILE is unset
#     or empty. Return 64 unless given exactly one argument, 1 with a diagnostic
#     when <file> is missing or unreadable, and 0 otherwise. Reading through
#     Bash command substitution strips trailing newlines; callers embed this
#     output in a larger prompt string, so that behavior is intentional.
# shellcheck shell=bash

detect_language() {
    if [ "$#" -ne 1 ]; then
        return 64
    fi

    local LANG_DIR="$1"

    if [ -d "$LANG_DIR" ] \
        && [ -r "$LANG_DIR" ] \
        && [ -x "$LANG_DIR" ] \
        && [ -f "$LANG_DIR/Cargo.toml" ]; then
        printf '%s\n' "rust"
    else
        printf '%s\n' "generic"
    fi
    return 0
}

lang_profile() {
    if [ "$#" -ne 1 ]; then
        return 64
    fi

    local LANG_REQUESTED_PROFILE="$1"

    case "$LANG_REQUESTED_PROFILE" in
        rust)
            LANG_PROFILE="rust"
            LANG_SUBJECT="the Rust crate in the current directory"
            LANG_SOURCE_SCOPE='every file under `src/`'
            LANG_PANICS='Panics reachable from non-test code (`unwrap`, `expect`, indexing, slicing, division, arithmetic overflow)'
            LANG_FIX_RULE="Library code must not use unwrap or expect; use proper error types."
            LANG_EDIT_SCOPE="Only edit Rust source files in this repository."
            LANG_WIRING='A module that is not yet declared in `lib.rs` is NOT a defect'
            ;;
        *)
            LANG_PROFILE="generic"
            LANG_SUBJECT="the project in the current directory"
            LANG_SOURCE_SCOPE="every source file this change touched, plus enough surrounding code to judge it in context"
            LANG_PANICS="Crash, abort, or unhandled-failure paths reachable from non-test code (unchecked indexing, unchecked arithmetic, dereferencing a value that may be absent, failed assertions, ignored error returns)"
            LANG_FIX_RULE="Non-test code must not introduce a new crash or unhandled-failure path on valid input; handle error cases explicitly, in this repository's existing error-handling style."
            LANG_EDIT_SCOPE="Only edit this repository's own source files, in whatever languages it is actually written in. Do not edit generated files, lockfiles, or vendored dependencies."
            LANG_WIRING="A file that is not yet imported, registered, or referenced by an entry point is NOT a defect"
            ;;
    esac

    export LANG_PROFILE LANG_SUBJECT LANG_SOURCE_SCOPE LANG_PANICS
    export LANG_FIX_RULE LANG_EDIT_SCOPE LANG_WIRING
    return 0
}

render_prompt() {
    if [ "$#" -ne 1 ]; then
        return 64
    fi

    local LANG_FILE="$1"
    local LANG_TEXT=""

    if [ ! -f "$LANG_FILE" ] || [ ! -r "$LANG_FILE" ]; then
        printf '%s\n' "[lang] prompt file is missing or unreadable: $LANG_FILE" >&2
        return 1
    fi

    if [ -z "${LANG_PROFILE:-}" ]; then
        lang_profile generic
    fi

    if ! LANG_TEXT="$(<"$LANG_FILE")"; then
        printf '%s\n' "[lang] prompt file could not be read: $LANG_FILE" >&2
        return 1
    fi
    LANG_TEXT="${LANG_TEXT//__SIGNALBOX_LANG_SUBJECT__/$LANG_SUBJECT}"
    LANG_TEXT="${LANG_TEXT//__SIGNALBOX_LANG_SOURCE_SCOPE__/$LANG_SOURCE_SCOPE}"
    LANG_TEXT="${LANG_TEXT//__SIGNALBOX_LANG_PANICS__/$LANG_PANICS}"
    LANG_TEXT="${LANG_TEXT//__SIGNALBOX_LANG_FIX_RULE__/$LANG_FIX_RULE}"
    LANG_TEXT="${LANG_TEXT//__SIGNALBOX_LANG_EDIT_SCOPE__/$LANG_EDIT_SCOPE}"
    LANG_TEXT="${LANG_TEXT//__SIGNALBOX_LANG_WIRING__/$LANG_WIRING}"
    printf '%s' "$LANG_TEXT"
}
