#!/usr/bin/env bash
# Self-contained test runner for bin/_lang.sh. Every fixture is built under
# mktemp -d, never in this repository. Prints PASS/FAIL per case and exits
# non-zero when any case failed.
#
# Deliberately no -e: cases capture non-zero function statuses for assertions.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTS_RUN=0
TESTS_PASSED=0
RUN_STATUS=0
FIXTURE_ROOT="$(mktemp -d)"
OUT="$FIXTURE_ROOT/stdout"
ERR="$FIXTURE_ROOT/stderr"

# shellcheck source=../bin/_lang.sh
source "$ROOT/bin/_lang.sh"

cleanup() {
    if [ -n "$FIXTURE_ROOT" ] && [ -d "$FIXTURE_ROOT" ]; then
        rm -rf -- "$FIXTURE_ROOT"
    fi
}
trap cleanup EXIT

run_subject() {
    local STDOUT_FILE="$1"
    local STDERR_FILE="$2"
    shift 2
    "$@" >"$STDOUT_FILE" 2>"$STDERR_FILE"
    RUN_STATUS=$?
}

report_case() {
    local NAME="$1"
    local OK="$2"
    local DETAIL="${3:-}"

    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$OK" -eq 0 ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        printf 'PASS %s\n' "$NAME"
    else
        printf 'FAIL %s%s\n' "$NAME" "${DETAIL:+ — $DETAIL}"
    fi
}

# 1. A Cargo.toml in the given directory selects the Rust profile.
RUST_DIR="$FIXTURE_ROOT/rust"
mkdir -p "$RUST_DIR"
touch "$RUST_DIR/Cargo.toml"
run_subject "$OUT" "$ERR" detect_language "$RUST_DIR"
RUST_DETECTED="$(<"$OUT")"
OK=1
if [ "$RUN_STATUS" -eq 0 ] && [ "$RUST_DETECTED" = "rust" ]; then
    OK=0
fi
report_case "Cargo.toml at the workdir root selects rust" "$OK" \
    "status=$RUN_STATUS output=$RUST_DETECTED"

# 2. A directory without Cargo.toml selects the generic profile.
GENERIC_DIR="$FIXTURE_ROOT/generic"
mkdir -p "$GENERIC_DIR"
run_subject "$OUT" "$ERR" detect_language "$GENERIC_DIR"
GENERIC_DETECTED="$(<"$OUT")"
OK=1
if [ "$RUN_STATUS" -eq 0 ] && [ "$GENERIC_DETECTED" = "generic" ]; then
    OK=0
fi
report_case "workdir without Cargo.toml selects generic" "$OK" \
    "status=$RUN_STATUS output=$GENERIC_DETECTED"

# 3. A missing workdir degrades to generic without failing.
MISSING_DIR="$FIXTURE_ROOT/does-not-exist"
run_subject "$OUT" "$ERR" detect_language "$MISSING_DIR"
MISSING_DETECTED="$(<"$OUT")"
OK=1
if [ "$RUN_STATUS" -eq 0 ] && [ "$MISSING_DETECTED" = "generic" ]; then
    OK=0
fi
report_case "missing workdir degrades to generic" "$OK" \
    "status=$RUN_STATUS output=$MISSING_DETECTED"

# 4. Zero and two arguments are invalid invocations.
run_subject "$OUT" "$ERR" detect_language
ZERO_STATUS=$RUN_STATUS
run_subject "$OUT" "$ERR" detect_language "$GENERIC_DIR" extra
TWO_STATUS=$RUN_STATUS
OK=1
if [ "$ZERO_STATUS" -eq 64 ] && [ "$TWO_STATUS" -eq 64 ]; then
    OK=0
fi
report_case "detect_language wrong argument count exits 64" "$OK" \
    "zero-args=$ZERO_STATUS two-args=$TWO_STATUS"

# 5. Both named profiles resolve to their exact profile texts.
lang_profile rust
RUST_STATUS=$?
OK=1
if [ "$RUST_STATUS" -eq 0 ] \
    && [ "$LANG_PROFILE" = "rust" ] \
    && [ "$LANG_SUBJECT" = "the Rust crate in the current directory" ] \
    && [ "$LANG_SOURCE_SCOPE" = 'every file under `src/`' ] \
    && [ "$LANG_PANICS" = 'Panics reachable from non-test code (`unwrap`, `expect`, indexing, slicing, division, arithmetic overflow)' ] \
    && [ "$LANG_FIX_RULE" = "Library code must not use unwrap or expect; use proper error types." ] \
    && [ "$LANG_EDIT_SCOPE" = "Only edit Rust source files in this repository." ] \
    && [ "$LANG_WIRING" = 'A module that is not yet declared in `lib.rs` is NOT a defect' ]; then
    OK=0
fi

lang_profile generic
GENERIC_STATUS=$?
GENERIC_FIX_RULE_LOWER="${LANG_FIX_RULE,,}"
if [ "$OK" -eq 0 ] \
    && [ "$GENERIC_STATUS" -eq 0 ] \
    && [ "$LANG_PROFILE" = "generic" ] \
    && [ "$LANG_SUBJECT" = "the project in the current directory" ] \
    && [ "$LANG_SOURCE_SCOPE" = "every source file this change touched, plus enough surrounding code to judge it in context" ] \
    && [ "$LANG_PANICS" = "Crash, abort, or unhandled-failure paths reachable from non-test code (unchecked indexing, unchecked arithmetic, dereferencing a value that may be absent, failed assertions, ignored error returns)" ] \
    && [ "$LANG_FIX_RULE" = "Non-test code must not introduce a new crash or unhandled-failure path on valid input; handle error cases explicitly, in this repository's existing error-handling style." ] \
    && [ "$LANG_EDIT_SCOPE" = "Only edit this repository's own source files, in whatever languages it is actually written in. Do not edit generated files, lockfiles, or vendored dependencies." ] \
    && [ "$LANG_WIRING" = "A file that is not yet imported, registered, or referenced by an entry point is NOT a defect" ] \
    && [[ ! "$GENERIC_FIX_RULE_LOWER" =~ (unwrap|expect|cargo|rust) ]]; then
    OK=0
else
    OK=1
fi
report_case "named profiles set their exact language texts" "$OK" \
    "rust-status=$RUST_STATUS generic-status=$GENERIC_STATUS profile=$LANG_PROFILE"

# 6. Unknown and empty profile names fail soft to generic.
lang_profile bogus
BOGUS_STATUS=$?
BOGUS_PROFILE="$LANG_PROFILE"
BOGUS_RULE="$LANG_FIX_RULE"
lang_profile ""
EMPTY_STATUS=$?
OK=1
if [ "$BOGUS_STATUS" -eq 0 ] \
    && [ "$BOGUS_PROFILE" = "generic" ] \
    && [ "$BOGUS_RULE" = "Non-test code must not introduce a new crash or unhandled-failure path on valid input; handle error cases explicitly, in this repository's existing error-handling style." ] \
    && [ "$EMPTY_STATUS" -eq 0 ] \
    && [ "$LANG_PROFILE" = "generic" ]; then
    OK=0
fi
report_case "unknown and empty profiles fall back to generic" "$OK" \
    "bogus-status=$BOGUS_STATUS empty-status=$EMPTY_STATUS"

# 7. Every token is substituted under both profiles.
TOKEN_PROMPT="$FIXTURE_ROOT/tokens.md"
printf '%s\n' \
    '__SIGNALBOX_LANG_SUBJECT__' \
    '__SIGNALBOX_LANG_SOURCE_SCOPE__' \
    '__SIGNALBOX_LANG_PANICS__' \
    '__SIGNALBOX_LANG_FIX_RULE__' \
    '__SIGNALBOX_LANG_EDIT_SCOPE__' \
    '__SIGNALBOX_LANG_WIRING__' >"$TOKEN_PROMPT"
OK=0
for PROFILE in rust generic; do
    lang_profile "$PROFILE"
    RENDERED="$(render_prompt "$TOKEN_PROMPT")"
    RENDER_STATUS=$?
    if [ "$RENDER_STATUS" -ne 0 ] \
        || [[ "$RENDERED" == *"__SIGNALBOX_LANG_"* ]] \
        || [[ "$RENDERED" != *"$LANG_SUBJECT"* ]] \
        || [[ "$RENDERED" != *"$LANG_SOURCE_SCOPE"* ]] \
        || [[ "$RENDERED" != *"$LANG_PANICS"* ]] \
        || [[ "$RENDERED" != *"$LANG_FIX_RULE"* ]] \
        || [[ "$RENDERED" != *"$LANG_EDIT_SCOPE"* ]] \
        || [[ "$RENDERED" != *"$LANG_WIRING"* ]]; then
        OK=1
    fi
done
report_case "render_prompt substitutes all six tokens for both profiles" "$OK"

# 8. Non-token shell-looking text remains byte-identical.
LITERAL_PROMPT="$FIXTURE_ROOT/literal.md"
printf '%s\n%s' \
    'literal-home=$HOME' \
    'literal-backticks=`printf danger`' >"$LITERAL_PROMPT"
lang_profile generic
run_subject "$OUT" "$ERR" render_prompt "$LITERAL_PROMPT"
OK=1
if [ "$RUN_STATUS" -eq 0 ] && cmp -s "$LITERAL_PROMPT" "$OUT"; then
    OK=0
fi
report_case "render_prompt leaves shell-looking non-token text untouched" "$OK" \
    "status=$RUN_STATUS"

# 9. Missing files and invalid invocation use their documented statuses.
run_subject "$OUT" "$ERR" render_prompt "$FIXTURE_ROOT/missing.md"
MISSING_STATUS=$RUN_STATUS
MISSING_ERROR="$(<"$ERR")"
run_subject "$OUT" "$ERR" render_prompt
RENDER_ZERO_STATUS=$RUN_STATUS
run_subject "$OUT" "$ERR" render_prompt "$TOKEN_PROMPT" extra
RENDER_TWO_STATUS=$RUN_STATUS
OK=1
if [ "$MISSING_STATUS" -eq 1 ] \
    && [ -n "$MISSING_ERROR" ] \
    && [ "$RENDER_ZERO_STATUS" -eq 64 ] \
    && [ "$RENDER_TWO_STATUS" -eq 64 ]; then
    OK=0
fi
report_case "render_prompt reports missing files and invalid invocation" "$OK" \
    "missing=$MISSING_STATUS zero-args=$RENDER_ZERO_STATUS two-args=$RENDER_TWO_STATUS"

# 10. Real prompts leave no language token residue under either profile.
PROMPT_FILES=("$ROOT"/prompts/*.md)
OK=0
if [ "${#PROMPT_FILES[@]}" -eq 0 ]; then
    OK=1
fi
for PROFILE in rust generic; do
    lang_profile "$PROFILE"
    for PROMPT in "${PROMPT_FILES[@]}"; do
        RENDERED="$(render_prompt "$PROMPT")"
        RENDER_STATUS=$?
        if [ "$RENDER_STATUS" -ne 0 ] \
            || [[ "$RENDERED" == *"__SIGNALBOX_LANG_"* ]]; then
            OK=1
        fi
    done
done
report_case "real prompts contain no rendered language-token residue" "$OK"

# 11. Generic texts contain no Rust-profile vocabulary.
lang_profile generic
OK=0
for VALUE in \
    "$LANG_SUBJECT" \
    "$LANG_SOURCE_SCOPE" \
    "$LANG_PANICS" \
    "$LANG_FIX_RULE" \
    "$LANG_EDIT_SCOPE" \
    "$LANG_WIRING"; do
    VALUE_LOWER="${VALUE,,}"
    if [[ "$VALUE_LOWER" =~ (rust|cargo|unwrap|expect|lib\.rs|src/) ]]; then
        OK=1
    fi
done
report_case "generic profile has no Rust vocabulary leakage" "$OK"

# 12. Detection ignores nested packages and checks only the supplied root.
NESTED_ROOT="$FIXTURE_ROOT/nested-root"
mkdir -p "$NESTED_ROOT/package"
touch "$NESTED_ROOT/package/Cargo.toml"
run_subject "$OUT" "$ERR" detect_language "$NESTED_ROOT"
NESTED_DETECTED="$(<"$OUT")"
OK=1
if [ "$RUN_STATUS" -eq 0 ] && [ "$NESTED_DETECTED" = "generic" ]; then
    OK=0
fi
report_case "detect_language ignores nested Cargo packages" "$OK" \
    "status=$RUN_STATUS output=$NESTED_DETECTED"

printf '%d/%d cases passed\n' "$TESTS_PASSED" "$TESTS_RUN"
[ "$TESTS_PASSED" -eq "$TESTS_RUN" ]
