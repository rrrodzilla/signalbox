#!/usr/bin/env bash
# Self-contained test runner for the review loop's fixer-session continuity
# (bin/fix.sh, bin/shard-fix.sh) and the carrier contract in bin/review.sh.
# No framework; every fixture is a copied harness tree in its own mktemp -d,
# removed by an EXIT trap. Deliberately omits set -e so expected subject
# failures can be captured and asserted.
#
# The agents are never invoked: `claude` and `codex` are replaced by stubs on
# PATH that record their argv, so the assertions are about which session flags
# each round passes and which id survives the round trip.
# Prints PASS/FAIL per case and exits non-zero when any case failed.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES=()
TESTS_RUN=0
TESTS_PASSED=0
RUN_STATUS=0
FIXTURE_PATH=""
STUB_BIN=""
ARGV_LOG=""

cleanup() {
    local FIXTURE
    for FIXTURE in "${FIXTURES[@]}"; do
        rm -rf -- "$FIXTURE"
    done
}
trap cleanup EXIT

# A fixture is a self-contained copy of the harness: _env.sh derives ROOT from
# the script's own parent, so the copy keeps RUN_DIR (and every artifact the
# handlers write) inside the temp tree instead of the developer's checkout.
fixture() {
    local DIR
    DIR="$(mktemp -d)"
    FIXTURES+=("$DIR")
    cp -a "$ROOT/bin" "$DIR/bin"
    cp -a "$ROOT/prompts" "$DIR/prompts"
    mkdir -p "$DIR/runs/probe/logs" "$DIR/runs/probe/state" \
        "$DIR/runs/probe/results" "$DIR/workdir"
    FIXTURE_PATH="$DIR"
}

# Stubs record one line per argument so a flag can be matched exactly even
# though the prompt argument itself spans many lines.
stubs() {
    STUB_BIN="$(mktemp -d)"
    ARGV_LOG="$(mktemp)"
    FIXTURES+=("$STUB_BIN" "$ARGV_LOG")

    cat >"$STUB_BIN/claude" <<'STUB'
#!/usr/bin/env bash
printf 'ARG=%s\n' "$@" >>"$STUB_ARGV_LOG"
if [ -n "${STUB_RESUME_FAILS:-}" ]; then
    for ARG in "$@"; do
        if [ "$ARG" = "--resume" ]; then
            echo "stub: session not found" >&2
            exit 1
        fi
    done
fi
echo "stub fixer ran"
STUB

    # Mimics codex enough for bin/review.sh: -o names the verdict file, and the
    # thread id is read back out of the JSON event stream on stdout.
    cat >"$STUB_BIN/codex" <<'STUB'
#!/usr/bin/env bash
printf 'ARG=%s\n' "$@" >>"$STUB_ARGV_LOG"
OUT=""
while [ "$#" -gt 0 ]; do
    if [ "$1" = "-o" ]; then
        OUT="$2"
        shift
    fi
    shift
done
[ -z "$OUT" ] || printf 'no findings\n\nAPPROVED\n' >"$OUT"
printf '{"type":"thread.started","thread_id":"stub-thread"}\n'
STUB

    chmod +x "$STUB_BIN/claude" "$STUB_BIN/codex"
}

run_handler() {
    local SUBJECT="$1"
    local PAYLOAD="$2"
    local STDOUT_FILE="$3"
    local STDERR_FILE="$4"
    shift 4
    PATH="$STUB_BIN:$PATH" \
        STUB_ARGV_LOG="$ARGV_LOG" \
        SIGNALBOX_RUN_SLUG="probe" \
        "$SUBJECT" "$@" <<<"$PAYLOAD" >"$STDOUT_FILE" 2>"$STDERR_FILE"
    RUN_STATUS=$?
}

# The value passed to a flag is the argument recorded immediately after it.
value_after() {
    local FLAG="$1"
    awk -v flag="ARG=$FLAG" '
        found { sub(/^ARG=/, ""); print; exit }
        $0 == flag { found = 1 }
    ' "$ARGV_LOG"
}

has_flag() {
    grep -Fxq "ARG=$1" "$ARGV_LOG"
}

report_case() {
    local NAME="$1" OK="$2" DETAIL="${3:-}"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$OK" -eq 0 ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        printf 'PASS %s\n' "$NAME"
    else
        printf 'FAIL %s%s\n' "$NAME" "${DETAIL:+ — $DETAIL}"
    fi
}

OUT="$(mktemp)"
ERR="$(mktemp)"
FIXTURES+=("$OUT" "$ERR")

UUID_RE='^[0-9a-fA-F-]{36}$'

# 1. Round 1 has no session to resume, so it mints one and pins it.
fixture
stubs
DIR="$FIXTURE_PATH"
run_handler "$DIR/bin/fix.sh" \
    "$(jq -nc --arg wd "$DIR/workdir" \
        '{verdict:"REQUEST_CHANGES",review:"finding one",round:1,workdir:$wd,thread_id:"t1",correlation_id:"c1"}')" \
    "$OUT" "$ERR"
MINTED="$(value_after --session-id)"
EMITTED="$(jq -r '.fix_session_id' "$OUT" 2>/dev/null || true)"
OK=1
if [ "$RUN_STATUS" -eq 0 ] \
    && ! has_flag --resume \
    && [[ "$MINTED" =~ $UUID_RE ]] \
    && [ "$EMITTED" = "$MINTED" ]; then
    OK=0
fi
report_case "round 1 mints a session id, pins it, and emits it" "$OK" \
    "status=$RUN_STATUS minted=$MINTED emitted=$EMITTED"

# 2. A later round resumes the id it was handed and passes it on unchanged.
fixture
stubs
DIR="$FIXTURE_PATH"
run_handler "$DIR/bin/fix.sh" \
    "$(jq -nc --arg wd "$DIR/workdir" \
        '{verdict:"REQUEST_CHANGES",review:"finding two",round:2,workdir:$wd,thread_id:"t1",fix_session_id:"sess-abc",correlation_id:"c1"}')" \
    "$OUT" "$ERR"
RESUMED="$(value_after --resume)"
EMITTED="$(jq -r '.fix_session_id' "$OUT" 2>/dev/null || true)"
OK=1
if [ "$RUN_STATUS" -eq 0 ] \
    && [ "$RESUMED" = "sess-abc" ] \
    && ! has_flag --session-id \
    && [ "$EMITTED" = "sess-abc" ]; then
    OK=0
fi
report_case "a later round resumes the carried session id" "$OK" \
    "status=$RUN_STATUS resumed=$RESUMED emitted=$EMITTED"

# 3. A dead session degrades to a fresh one instead of wedging the loop.
fixture
stubs
DIR="$FIXTURE_PATH"
PATH="$STUB_BIN:$PATH" \
    STUB_ARGV_LOG="$ARGV_LOG" \
    STUB_RESUME_FAILS=1 \
    SIGNALBOX_RUN_SLUG="probe" \
    "$DIR/bin/fix.sh" \
    <<<"$(jq -nc --arg wd "$DIR/workdir" \
        '{verdict:"REQUEST_CHANGES",review:"finding three",round:3,workdir:$wd,thread_id:"t1",fix_session_id:"sess-dead",correlation_id:"c1"}')" \
    >"$OUT" 2>"$ERR"
RUN_STATUS=$?
MINTED="$(value_after --session-id)"
EMITTED="$(jq -r '.fix_session_id' "$OUT" 2>/dev/null || true)"
OK=1
if [ "$RUN_STATUS" -eq 0 ] \
    && has_flag --resume \
    && [[ "$MINTED" =~ $UUID_RE ]] \
    && [ "$EMITTED" = "$MINTED" ] \
    && [ "$EMITTED" != "sess-dead" ] \
    && grep -Fq "could not resume session sess-dead" "$ERR"; then
    OK=0
fi
report_case "an unresumable session falls back to a fresh one" "$OK" \
    "status=$RUN_STATUS minted=$MINTED emitted=$EMITTED stderr=$(head -c 200 "$ERR")"

# 4. The scope-conflict rule reaches the fixer on the round that starts a
#    session — the round where the whole rule set is sent.
fixture
stubs
DIR="$FIXTURE_PATH"
run_handler "$DIR/bin/fix.sh" \
    "$(jq -nc --arg wd "$DIR/workdir" \
        '{verdict:"REQUEST_CHANGES",review:"finding one",round:1,workdir:$wd,thread_id:"t1",correlation_id:"c1"}')" \
    "$OUT" "$ERR"
OK=1
if grep -Fq "SCOPE-CONFLICT" "$ARGV_LOG" \
    && grep -Fq "a mechanism the plan does" "$ARGV_LOG"; then
    OK=0
fi
report_case "the opening round carries the scope-conflict rule" "$OK" \
    "prompt=$(grep -c SCOPE-CONFLICT "$ARGV_LOG") matches"

# 5. The resumed round tells the fixer to recognize its own earlier work, and
#    does not re-send the rules the session already holds.
fixture
stubs
DIR="$FIXTURE_PATH"
run_handler "$DIR/bin/fix.sh" \
    "$(jq -nc --arg wd "$DIR/workdir" \
        '{verdict:"REQUEST_CHANGES",review:"finding two",round:2,workdir:$wd,thread_id:"t1",fix_session_id:"sess-abc",correlation_id:"c1"}')" \
    "$OUT" "$ERR"
OK=1
if grep -Fq "code YOU added" "$ARGV_LOG" \
    && grep -Fq "the wrong mechanism" "$ARGV_LOG" \
    && ! grep -Fq "## Rules" "$ARGV_LOG"; then
    OK=0
fi
report_case "the resumed round asks the fixer to recognize its own work" "$OK" \
    "own-work=$(grep -c 'code YOU added' "$ARGV_LOG") rules=$(grep -c '## Rules' "$ARGV_LOG")"

# 6. review.sh is only a carrier: the fixer's id must survive its round trip.
fixture
stubs
DIR="$FIXTURE_PATH"
run_handler "$DIR/bin/review.sh" \
    "$(jq -nc --arg wd "$DIR/workdir" \
        '{workdir:$wd,round:2,feedback:"prior",thread_id:"t1",fix_session_id:"sess-carried",correlation_id:"c1"}')" \
    "$OUT" "$ERR"
CARRIED="$(jq -r '.fix_session_id' "$OUT" 2>/dev/null || true)"
OK=1
if [ "$RUN_STATUS" -eq 0 ] && [ "$CARRIED" = "sess-carried" ]; then
    OK=0
fi
report_case "review.sh carries the fixer session id through" "$OK" \
    "status=$RUN_STATUS carried=$CARRIED stderr=$(head -c 200 "$ERR")"

# 7. The first review of a run has no fixer session yet; the field is still
#    present and empty so the fixer mints one rather than reading null.
fixture
stubs
DIR="$FIXTURE_PATH"
run_handler "$DIR/bin/review.sh" \
    "$(jq -nc --arg wd "$DIR/workdir" \
        '{workdir:$wd,round:1,feedback:"",correlation_id:"c1"}')" \
    "$OUT" "$ERR"
PRESENT="$(jq -r 'has("fix_session_id")' "$OUT" 2>/dev/null || true)"
EMPTY="$(jq -r '.fix_session_id' "$OUT" 2>/dev/null || true)"
OK=1
if [ "$RUN_STATUS" -eq 0 ] && [ "$PRESENT" = "true" ] && [ "$EMPTY" = "" ]; then
    OK=0
fi
report_case "an unstarted fixer session round-trips as empty, not null" "$OK" \
    "status=$RUN_STATUS present=$PRESENT value=$EMPTY"

# 8. The per-shard loop mints its own session, keyed to that shard's payload so
#    concurrent shards never share one.
fixture
stubs
DIR="$FIXTURE_PATH"
mkdir -p "$DIR/runs/probe"
jq -nc '{issue:1,feature:"probe-feature"}' >"$DIR/runs/probe/plan.json"
WT_DIR="$(dirname "$DIR")/signalbox-wt/probe-feature-core-one"
mkdir -p "$WT_DIR"
FIXTURES+=("$(dirname "$DIR")/signalbox-wt")
run_handler "$DIR/bin/shard-fix.sh" \
    "$(jq -nc '{worker:"0",stage:"core",current:{shard:"one",branch:"shard/probe-feature/core-one"},round:1,review:"shard finding",feature:"probe-feature"}')" \
    "$OUT" "$ERR" 0
MINTED="$(value_after --session-id)"
EMITTED="$(jq -r '.fix_session_id' "$OUT" 2>/dev/null || true)"
OK=1
if [ "$RUN_STATUS" -eq 0 ] \
    && [[ "$MINTED" =~ $UUID_RE ]] \
    && [ "$EMITTED" = "$MINTED" ]; then
    OK=0
fi
report_case "shard round 1 mints a per-shard session id" "$OK" \
    "status=$RUN_STATUS minted=$MINTED emitted=$EMITTED stderr=$(head -c 200 "$ERR")"

# 9. And resumes it on the next shard round.
fixture
stubs
DIR="$FIXTURE_PATH"
jq -nc '{issue:1,feature:"probe-feature"}' >"$DIR/runs/probe/plan.json"
WT_DIR="$(dirname "$DIR")/signalbox-wt/probe-feature-core-one"
mkdir -p "$WT_DIR"
FIXTURES+=("$(dirname "$DIR")/signalbox-wt")
run_handler "$DIR/bin/shard-fix.sh" \
    "$(jq -nc '{worker:"0",stage:"core",current:{shard:"one",branch:"shard/probe-feature/core-one"},round:2,review:"shard finding",feature:"probe-feature",fix_session_id:"shard-sess"}')" \
    "$OUT" "$ERR" 0
RESUMED="$(value_after --resume)"
EMITTED="$(jq -r '.fix_session_id' "$OUT" 2>/dev/null || true)"
OK=1
if [ "$RUN_STATUS" -eq 0 ] \
    && [ "$RESUMED" = "shard-sess" ] \
    && ! has_flag --session-id \
    && [ "$EMITTED" = "shard-sess" ]; then
    OK=0
fi
report_case "a later shard round resumes its own session" "$OK" \
    "status=$RUN_STATUS resumed=$RESUMED emitted=$EMITTED stderr=$(head -c 200 "$ERR")"

printf '%d/%d cases passed\n' "$TESTS_PASSED" "$TESTS_RUN"
[ "$TESTS_PASSED" -eq "$TESTS_RUN" ]
