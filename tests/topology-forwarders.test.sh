#!/usr/bin/env bash
# Self-contained conformance test runner for the five tracked topology files.
# No framework and no dependencies beyond coreutils + git + jq + curl + python3;
# python3's tomllib parses the TOML rather than treating it as line-oriented
# text. Every diagnostic fixture is built under its own mktemp -d. Prints
# PASS/FAIL per case and exits non-zero when any case failed.
#
# Deliberately no -e: failing conformance cases are captured and reported
# together instead of terminating the runner at the first mismatch.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES=()
TESTS_RUN=0
TESTS_PASSED=0
RUN_STATUS=0
CHECK_STDOUT=""
CHECK_STDERR=""
FIXTURE_ROOT=""

cleanup() {
    local FIXTURE
    for FIXTURE in "${FIXTURES[@]}"; do
        rm -rf -- "$FIXTURE"
    done
}
trap cleanup EXIT

fixture() {
    FIXTURE_ROOT="$(mktemp -d)"
    FIXTURES+=("$FIXTURE_ROOT")
}

run_check() {
    local CHECK="$1" DIR
    fixture
    DIR="$FIXTURE_ROOT"
    CHECK_STDOUT="$DIR/stdout"
    CHECK_STDERR="$DIR/stderr"

    python3 - "$ROOT" "$CHECK" >"$CHECK_STDOUT" 2>"$CHECK_STDERR" <<'PYEOF'
import re
import subprocess
import sys
import tomllib
from pathlib import Path

root = Path(sys.argv[1])
check = sys.argv[2]
topology_names = (
    "pipeline.toml",
    "plan.toml",
    "implement.toml",
    "emergent.toml",
    "init.toml",
)
expected_labels = {
    "pipeline.toml": "pipeline",
    "plan.toml": "plan",
    "implement.toml": "implement",
    "emergent.toml": "review",
    "init.toml": "init",
}
expected_topics = {
    "pipeline.toml": {
        "phase.request",
        "phase.done",
        "phase.verified",
        "pipeline.complete",
        "pipeline.halted",
        "exec.error",
        "system.started.*",
        "system.stopped.*",
        "system.error.*",
    },
    "plan.toml": {
        "plan.requested",
        "plan.validated",
        "plan.approved",
        "plan.written",
        "plan.escalated",
        "exec.error",
        "system.started.*",
        "system.stopped.*",
        "system.error.*",
    },
    "implement.toml": {
        "stage.item",
        "shard.built",
        "shard.review.raw",
        "shard.fix.requested",
        "shard.done",
        "stage.done",
        "stage.ack",
        "shard.escalated",
        "plan.done",
        "exec.error",
        "system.started.*",
        "system.stopped.*",
        "system.error.*",
    },
    "emergent.toml": {
        "review.requested",
        "review.raw",
        "fix.requested",
        "review.approved",
        "review.escalated",
        "gate.assessed",
        "gate.decided",
        "approval.requested",
        "approval.granted",
        "docs.synced",
        "exec.error",
        "system.started.*",
        "system.stopped.*",
        "system.error.*",
    },
    "init.toml": {
        "init.requested",
        "doc.researched",
        "doc.written",
        "exec.error",
        "system.started.*",
        "system.stopped.*",
        "system.error.*",
    },
}


def load(name):
    with (root / name).open("rb") as stream:
        return tomllib.load(stream)


def forwarders(name):
    return [
        sink
        for sink in load(name).get("sinks", [])
        if sink.get("name", "").startswith("forward-")
    ]


FORWARDER = "__SIGNALBOX_ROOT__/bin/sse-forward.sh"


def canonical_args(topic, label):
    """The exec-sink argv a forwarder for `topic` must carry.

    A wildcard topic cannot be forwarded verbatim — the concrete engine
    name only exists in the payload — so those sinks intentionally go
    through a `bash -c` wrapper that reads the payload, pulls `.name`
    out of it, and rebuilds the concrete topic before handing both to
    the forwarder passed as "$0".
    """
    head = ["-s", topic, "-t", "5000", "--"]
    if not topic.endswith(".*"):
        return head + [FORWARDER, label, topic]
    prefix = topic[: -len(".*")]
    wrapper = (
        'payload=$(cat); name=$(jq -r ".name // empty" <<<"$payload" '
        '2>/dev/null); printf "%s" "$payload" | "$0" '
        + label
        + ' "'
        + prefix
        + '.${name:-unknown}"'
    )
    return head + ["bash", "-c", wrapper, FORWARDER]


def fail(messages):
    if messages:
        print("; ".join(messages), file=sys.stderr)
        raise SystemExit(1)


def tracked_paths():
    """Every path tracked in the work tree, via Git itself.

    Asking Git rather than decoding .git/index keeps this correct across
    index formats (v2/v3/v4) and split indexes, and works the same in a
    linked worktree, where .git is a pointer file.
    """
    result = subprocess.run(
        ["git", "-C", str(root), "ls-files", "-z"],
        capture_output=True,
    )
    if result.returncode != 0:
        raise ValueError(
            "git ls-files failed: "
            + result.stderr.decode("utf-8", "replace").strip()
        )
    return [
        entry.decode("utf-8", "surrogateescape")
        for entry in result.stdout.split(b"\0")
        if entry
    ]


if check == "legacy":
    errors = []
    for name in topology_names:
        if "sse-sink" in (root / name).read_text(encoding="utf-8"):
            errors.append(f"{name} references sse-sink")

    forbidden = [
        ("__SIGNALBOX_PORT_" + suffix + "__").encode()
        for suffix in ("PIPELINE", "PLAN", "IMPLEMENT", "REVIEW", "INIT")
    ]
    # The placeholder guard's own runner writes live port tokens into its
    # throwaway fixtures on purpose — that is precisely what it asserts the
    # guard catches — so its source is exempt from this scan.
    exempt = {"tests/check-placeholders.test.sh"}
    for relative in tracked_paths():
        if relative in exempt:
            continue
        try:
            content = (root / relative).read_bytes()
        except OSError as exc:
            errors.append(f"{relative}: unreadable tracked file ({exc})")
            continue
        for token in forbidden:
            if token in content:
                errors.append(
                    f"{relative} contains {token.decode('ascii')}"
                )
    fail(errors)

elif check == "approval":
    token = "__SIGNALBOX_PORT_" + "APPROVAL__"
    occurrences = {
        name: (root / name).read_text(encoding="utf-8").count(token)
        for name in topology_names
    }
    fail(
        []
        if occurrences == {
            "pipeline.toml": 0,
            "plan.toml": 0,
            "implement.toml": 0,
            "emergent.toml": 1,
            "init.toml": 0,
        }
        else [f"approval placeholder counts are {occurrences}"]
    )

elif check == "shape":
    errors = []
    primitive = "~/.local/share/emergent/primitives/bin/exec-sink"
    for name in topology_names:
        for sink in forwarders(name):
            subscriptions = sink.get("subscribes")
            if not isinstance(subscriptions, list) or len(subscriptions) != 1:
                errors.append(
                    f"{name}:{sink.get('name')} subscribes={subscriptions!r}"
                )
                continue
            topic = subscriptions[0]
            label = expected_labels[name]
            expected_args = canonical_args(topic, label)
            expected_name = "forward-" + topic.replace(".", "-").replace(
                "*", "any"
            )
            if sink.get("args") != expected_args:
                errors.append(f"{name}:{sink.get('name')} has mismatched args")
            if sink.get("path") != primitive:
                errors.append(f"{name}:{sink.get('name')} has wrong path")
            if sink.get("name") != expected_name:
                errors.append(
                    f"{name}:{sink.get('name')} expected name {expected_name}"
                )
    fail(errors)

elif check == "labels":
    errors = []
    wrapper_label = re.compile(r'\| "\$0" ([a-z]+) "system\.')
    for name in topology_names:
        labels = []
        for sink in forwarders(name):
            args = sink.get("args", [])
            if (
                len(args) == 8
                and args[5] == "__SIGNALBOX_ROOT__/bin/sse-forward.sh"
            ):
                labels.append(args[6])
            elif len(args) >= 8 and args[5:7] == ["bash", "-c"]:
                match = wrapper_label.search(args[7])
                labels.append(match.group(1) if match else None)
            else:
                labels.append(None)
        expected = expected_labels[name]
        if not labels or any(label != expected for label in labels):
            errors.append(f"{name} labels={labels!r}, expected {expected!r}")
    fail(errors)

elif check == "topics":
    errors = []
    for name in topology_names:
        actual = {
            sink["subscribes"][0]
            for sink in forwarders(name)
            if isinstance(sink.get("subscribes"), list)
            and len(sink["subscribes"]) == 1
        }
        missing = sorted(expected_topics[name] - actual)
        extra = sorted(actual - expected_topics[name])
        if missing or extra:
            errors.append(f"{name} missing={missing!r} extra={extra!r}")
    fail(errors)

elif check == "unique":
    errors = []
    for name in topology_names:
        names = [sink.get("name") for sink in load(name).get("sinks", [])]
        duplicates = sorted(
            sink_name
            for sink_name in set(names)
            if names.count(sink_name) > 1
        )
        if duplicates:
            errors.append(f"{name} duplicate sink names={duplicates!r}")
    fail(errors)

else:
    raise SystemExit(f"unknown check: {check}")
PYEOF
    RUN_STATUS=$?
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

run_check legacy
OK=1
[ "$RUN_STATUS" -eq 0 ] && OK=0
report_case "legacy SSE primitive and per-engine port tokens are absent" "$OK" \
    "status=$RUN_STATUS $(head -c 300 "$CHECK_STDERR")"

run_check approval
OK=1
[ "$RUN_STATUS" -eq 0 ] && OK=0
report_case "approval webhook placeholder remains exactly once" "$OK" \
    "status=$RUN_STATUS $(head -c 300 "$CHECK_STDERR")"

run_check shape
OK=1
[ "$RUN_STATUS" -eq 0 ] && OK=0
report_case "every forwarder has one internally consistent canonical shape" "$OK" \
    "status=$RUN_STATUS $(head -c 300 "$CHECK_STDERR")"

run_check labels
OK=1
[ "$RUN_STATUS" -eq 0 ] && OK=0
report_case "each topology uses its expected engine label throughout" "$OK" \
    "status=$RUN_STATUS $(head -c 300 "$CHECK_STDERR")"

run_check topics
OK=1
[ "$RUN_STATUS" -eq 0 ] && OK=0
report_case "each topology forwards exactly its required topic set" "$OK" \
    "status=$RUN_STATUS $(head -c 300 "$CHECK_STDERR")"

run_check unique
OK=1
[ "$RUN_STATUS" -eq 0 ] && OK=0
report_case "every sink name is unique within its topology" "$OK" \
    "status=$RUN_STATUS $(head -c 300 "$CHECK_STDERR")"

printf '%d/%d cases passed\n' "$TESTS_PASSED" "$TESTS_RUN"
[ "$TESTS_PASSED" -eq "$TESTS_RUN" ]
