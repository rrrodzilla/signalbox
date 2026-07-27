#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUBJECT="$ROOT/bin/check-placeholders.sh"
FIXTURES=()
TESTS_RUN=0
TESTS_PASSED=0
RUN_STATUS=0

cleanup() {
    local FIXTURE

    for FIXTURE in "${FIXTURES[@]}"; do
        rm -rf -- "$FIXTURE"
    done
}
trap cleanup EXIT

run_subject() {
    local STDOUT_FILE="$1"
    local STDERR_FILE="$2"
    shift 2

    "$SUBJECT" "$@" >"$STDOUT_FILE" 2>"$STDERR_FILE"
    RUN_STATUS=$?
}

report_case() {
    local NAME="$1"
    local RESULT="$2"

    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$RESULT" -eq 0 ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo "PASS: $NAME"
    else
        echo "FAIL: $NAME"
    fi
}

PRISTINE_DIR="$(mktemp -d)"
FIXTURES+=("$PRISTINE_DIR")
cat >"$PRISTINE_DIR/pipeline.toml" <<'EOF'
# Uses the same __SIGNALBOX_PORT_*__ placeholders during rendering.
name = "signalbox-pipeline-issue-17"
args = ["--port", "8203"]
EOF
run_subject "$PRISTINE_DIR/stdout" "$PRISTINE_DIR/stderr" "$PRISTINE_DIR"
if [ "$RUN_STATUS" -eq 0 ] &&
    [ ! -s "$PRISTINE_DIR/stdout" ] &&
    [ ! -s "$PRISTINE_DIR/stderr" ]; then
    report_case "pristine rendered directory" 0
else
    report_case "pristine rendered directory" 1
fi

INDENTED_DIR="$(mktemp -d)"
FIXTURES+=("$INDENTED_DIR")
cat >"$INDENTED_DIR/plan.toml" <<'EOF'
    # Uses __SIGNALBOX_PORT_PLAN__ while documenting the template.
name = "signalbox-plan-issue-17"
args = ["--port", "8204"]
EOF
run_subject "$INDENTED_DIR/stdout" "$INDENTED_DIR/stderr" "$INDENTED_DIR"
if [ "$RUN_STATUS" -eq 0 ] &&
    [ ! -s "$INDENTED_DIR/stdout" ] &&
    [ ! -s "$INDENTED_DIR/stderr" ]; then
    report_case "indented placeholder comment" 0
else
    report_case "indented placeholder comment" 1
fi

LEFTOVER_DIR="$(mktemp -d)"
FIXTURES+=("$LEFTOVER_DIR")
LEFTOVER_FILE="$LEFTOVER_DIR/pipeline.toml"
cat >"$LEFTOVER_FILE" <<'EOF'
# Rendered pipeline configuration.
name = "signalbox-pipeline-issue-17"
args = ["--port", "__SIGNALBOX_PORT_PIPELINE__"]
EOF
run_subject "$LEFTOVER_DIR/stdout" "$LEFTOVER_DIR/stderr" "$LEFTOVER_DIR"
LEFTOVER_STDERR="$(<"$LEFTOVER_DIR/stderr")"
if [ "$RUN_STATUS" -eq 1 ] &&
    [[ "$LEFTOVER_STDERR" == *"$LEFTOVER_FILE:3:"* ]] &&
    [[ "$LEFTOVER_STDERR" == *"error: unresolved __SIGNALBOX_ placeholder in rendered run config"* ]]; then
    report_case "genuine non-comment leftover" 0
else
    report_case "genuine non-comment leftover" 1
fi

MULTI_DIR="$(mktemp -d)"
FIXTURES+=("$MULTI_DIR")
MULTI_BAD_FILE="$MULTI_DIR/implement.toml"
MULTI_CLEAN_FILE="$MULTI_DIR/plan.toml"
MULTI_OTHER_FILE="$MULTI_DIR/emergent.toml"
cat >"$MULTI_BAD_FILE" <<'EOF'
name = "signalbox-implement-issue-17"
args = ["--port", "__SIGNALBOX_PORT_IMPLEMENT__"]
EOF
cat >"$MULTI_CLEAN_FILE" <<'EOF'
# Uses __SIGNALBOX_PORT_PLAN__ while documenting the template.
args = ["--port", "8204"]
EOF
cat >"$MULTI_OTHER_FILE" <<'EOF'
# Uses __SIGNALBOX_PORT_REVIEW__ while documenting the template.
args = ["--port", "8206"]
EOF
run_subject "$MULTI_DIR/stdout" "$MULTI_DIR/stderr" "$MULTI_DIR"
MULTI_STDERR="$(<"$MULTI_DIR/stderr")"
if [ "$RUN_STATUS" -eq 1 ] &&
    [[ "$MULTI_STDERR" == *"$MULTI_BAD_FILE:2:"* ]] &&
    [[ "$MULTI_STDERR" != *"$MULTI_CLEAN_FILE:"* ]] &&
    [[ "$MULTI_STDERR" != *"$MULTI_OTHER_FILE:"* ]]; then
    report_case "multiple TOML files isolate the offender" 0
else
    report_case "multiple TOML files isolate the offender" 1
fi

BASIC_BLOCK_DIR="$(mktemp -d)"
FIXTURES+=("$BASIC_BLOCK_DIR")
BASIC_BLOCK_FILE="$BASIC_BLOCK_DIR/pipeline.toml"
cat >"$BASIC_BLOCK_FILE" <<'EOF'
# Uses __SIGNALBOX_PORT_PIPELINE__ while documenting the template.
prompt = """
# __SIGNALBOX_PORT_PIPELINE__
"""
# Uses __SIGNALBOX_PORT_PIPELINE__ again after the string closes.
args = ["--port", "8203"]
EOF
run_subject "$BASIC_BLOCK_DIR/stdout" "$BASIC_BLOCK_DIR/stderr" "$BASIC_BLOCK_DIR"
BASIC_BLOCK_STDERR="$(<"$BASIC_BLOCK_DIR/stderr")"
if [ "$RUN_STATUS" -eq 1 ] &&
    [[ "$BASIC_BLOCK_STDERR" == *"$BASIC_BLOCK_FILE:3:"* ]] &&
    [[ "$BASIC_BLOCK_STDERR" != *"$BASIC_BLOCK_FILE:1:"* ]] &&
    [[ "$BASIC_BLOCK_STDERR" != *"$BASIC_BLOCK_FILE:5:"* ]]; then
    report_case "hash line inside multiline basic string" 0
else
    report_case "hash line inside multiline basic string" 1
fi

LITERAL_BLOCK_DIR="$(mktemp -d)"
FIXTURES+=("$LITERAL_BLOCK_DIR")
LITERAL_BLOCK_FILE="$LITERAL_BLOCK_DIR/implement.toml"
cat >"$LITERAL_BLOCK_FILE" <<'EOF'
body = '''
# __SIGNALBOX_PORT_IMPLEMENT__
'''
# Uses __SIGNALBOX_PORT_IMPLEMENT__ after the string closes.
name = "signalbox-implement-issue-17"
EOF
run_subject "$LITERAL_BLOCK_DIR/stdout" "$LITERAL_BLOCK_DIR/stderr" "$LITERAL_BLOCK_DIR"
LITERAL_BLOCK_STDERR="$(<"$LITERAL_BLOCK_DIR/stderr")"
if [ "$RUN_STATUS" -eq 1 ] &&
    [[ "$LITERAL_BLOCK_STDERR" == *"$LITERAL_BLOCK_FILE:2:"* ]] &&
    [[ "$LITERAL_BLOCK_STDERR" != *"$LITERAL_BLOCK_FILE:4:"* ]]; then
    report_case "hash line inside multiline literal string" 0
else
    report_case "hash line inside multiline literal string" 1
fi

QUOTED_DIR="$(mktemp -d)"
FIXTURES+=("$QUOTED_DIR")
cat >"$QUOTED_DIR/plan.toml" <<'EOF'
# A comment naming __SIGNALBOX_PORT_PLAN__ and one " quote.
label = "value with a # hash"
# A later comment naming __SIGNALBOX_PORT_PLAN__ once more.
args = ["--port", "8204"]
EOF
run_subject "$QUOTED_DIR/stdout" "$QUOTED_DIR/stderr" "$QUOTED_DIR"
if [ "$RUN_STATUS" -eq 0 ] &&
    [ ! -s "$QUOTED_DIR/stdout" ] &&
    [ ! -s "$QUOTED_DIR/stderr" ]; then
    report_case "quotes in comments and values keep comments skipped" 0
else
    report_case "quotes in comments and values keep comments skipped" 1
fi

ARGUMENT_DIR="$(mktemp -d)"
FIXTURES+=("$ARGUMENT_DIR")
run_subject "$ARGUMENT_DIR/zero.stdout" "$ARGUMENT_DIR/zero.stderr"
ZERO_STATUS="$RUN_STATUS"
run_subject "$ARGUMENT_DIR/two.stdout" "$ARGUMENT_DIR/two.stderr" first second
TWO_STATUS="$RUN_STATUS"
if [ "$ZERO_STATUS" -eq 64 ] && [ "$TWO_STATUS" -eq 64 ]; then
    report_case "wrong argument counts" 0
else
    report_case "wrong argument counts" 1
fi

EMPTY_DIR="$(mktemp -d)"
FIXTURES+=("$EMPTY_DIR")
run_subject "$EMPTY_DIR/stdout" "$EMPTY_DIR/stderr" "$EMPTY_DIR"
if [ "$RUN_STATUS" -eq 1 ]; then
    report_case "directory without TOML files" 0
else
    report_case "directory without TOML files" 1
fi

echo "Summary: $TESTS_PASSED/$TESTS_RUN cases passed"
if [ "$TESTS_PASSED" -eq "$TESTS_RUN" ]; then
    exit 0
fi
exit 1
