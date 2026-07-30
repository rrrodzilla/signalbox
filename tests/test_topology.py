"""Architectural invariants of the topology itself.

These are the Gate 2 review questions turned into assertions, because the
failure they catch is silent: a misrouted or unobserved event produces no error,
just a run that quietly does less than it should.
"""

from __future__ import annotations

import re
import tomllib
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
CONFIG = tomllib.load((ROOT / "emergent.toml").open("rb"))

SOURCES = CONFIG["sources"]
HANDLERS = CONFIG["handlers"]
SINKS = CONFIG["sinks"]

# Raw ingress envelopes. The routers immediately turn these into meaningful
# topics, and it is those the dashboard shows.
RAW = {"http.request", "exec.output", "exec.exit"}


def published() -> set[str]:
    topics: set[str] = set()
    for primitive in SOURCES + HANDLERS:
        topics.update(primitive.get("publishes", []))
    return topics


def subscribed() -> set[str]:
    topics: set[str] = set()
    for primitive in HANDLERS + SINKS:
        topics.update(primitive.get("subscribes", []))
    return topics


def named(group: list[dict], name: str) -> dict:
    return next(p for p in group if p["name"] == name)


def test_there_is_exactly_one_engine():
    assert CONFIG["engine"]["name"] == "signalbox"


def test_dashboard_observes_every_topic_the_topology_publishes():
    """Gate 2's log test. An unobserved event is a blind spot on the dashboard."""
    missing = published() - RAW - set(named(SINKS, "dashboard")["subscribes"])
    assert not missing, f"dashboard would not show: {sorted(missing)}"


PAGE_TEXT = (ROOT / "src" / "signalbox" / "dashboard.html").read_text()

BLOCK_NAMES = {"plan", "build", "gate", "promote", "docs"}
MEANINGS = {"go", "work", "judge", "stop", "hold"}


def event_table() -> dict[str, tuple[str | None, str]]:
    """The page's topic -> (block, meaning) table, as data."""
    body = PAGE_TEXT[PAGE_TEXT.index("const EVENT = {") :]
    body = body[: body.index("\n};")]
    return {
        topic: (None if block == "null" else block.strip('"'), meaning)
        for topic, block, meaning in re.findall(
            r'"([a-z][\w.\-]*)":\s*\[\s*(null|"[a-z]+")\s*,\s*"([a-z]+)"\s*\]', body
        )
    }


def test_the_dashboard_renders_every_topic_it_subscribes_to():
    """Subscribing is not rendering, and only the first half was ever asserted.

    The sink can carry a topic the page has no entry for. The register then
    renders the row in the fallback colour and the run card does not move at
    all. Thirteen published topics were in exactly that state, `run.completed`
    and `checks.silent` among them, which is why a healthy run could look dead.
    """
    missing = set(named(SINKS, "dashboard")["subscribes"]) - RAW - {"model.invoked"}
    missing -= set(event_table())
    assert not missing, f"the page has no entry for: {sorted(missing)}"


def test_both_dashboard_views_are_coloured_by_one_table():
    """The register's colour and the card's colour must have a single source.

    They did not: a block table drove the card and four independent regexes
    drove the register, so `shard.built` was green in one view while the other
    painted the same shard blue. Only one of those can be right, and nothing
    made them agree.
    """
    table = event_table()
    assert table, "the page's EVENT table could not be parsed"
    for topic, (block, meaning) in table.items():
        assert meaning in MEANINGS, f"{topic} has an unknown meaning {meaning!r}"
        assert block is None or block in BLOCK_NAMES, f"{topic} names no section"
    assert "sev(e.type)" in PAGE_TEXT, "the register does not read the table"
    assert "const meaning = sev(t);" in PAGE_TEXT, "the card does not read the table"


def test_every_event_moves_the_card_before_any_topic_specific_branch():
    """A run card that only reacts to topics it has a `case` for reads as dead.

    Most events changed nothing visible, because the switch handles 25 topics
    and the stream carries far more. The counter, tick line, and rail flash have
    to be updated unconditionally, ahead of the switch, or the gap comes back
    one unhandled topic at a time.
    """
    body = PAGE_TEXT[PAGE_TEXT.index("function apply(msg)") : PAGE_TEXT.index("function shardSidings")]
    for unconditional in ("run.events++", "run.tick =", "run.pulse ="):
        assert unconditional in body, f"{unconditional} is missing from apply()"
        assert body.index(unconditional) < body.index("switch (t)"), (
            f"{unconditional} must run before the topic switch, not inside it"
        )

    # Ordering alone was not enough: `model.invoked` returned above the counter,
    # so the rule held on paper while one topic escaped it. Provenance now leaves
    # the stream before apply() is called, which is why apply() can be required
    # to have no early exit at all.
    preamble = body[: body.index("run.events++")]
    assert "return" not in preamble, (
        "apply() must not return before the counter; an event that exits early "
        "moves nothing on the card, which is the gap this rule exists to close"
    )


def test_an_event_with_no_run_id_does_not_invent_a_run_card():
    """`stages.exhausted` is `{"count": N}`, and it was minting a phantom run.

    Three topics arrive unattributed for three different reasons: stream-runner's
    end event carries no identity at all, the exec-handler `-e` error topics
    publish `{command, exit_code, stderr}` instead of the inbound payload (#66),
    and reaper telemetry never had a run. Bucketing them under a fake key drew a
    card for a run nobody launched.
    """
    assert '"unattributed"' not in PAGE_TEXT, "no synthetic run key may remain"
    assert "if (isAttributed(msg)) apply(msg);" in PAGE_TEXT, (
        "the board must skip events that name no run"
    )
    # Skipped, not silently dropped: a board that omits events without saying so
    # is the same class of lie as one that invents a run for them.
    assert "unattributed++" in PAGE_TEXT and '" unattributed"' in PAGE_TEXT, (
        "the count of unplaceable events has to be stated somewhere on the page"
    )
    # And they stay in the register, which is the view that can hold them.
    stream = PAGE_TEXT[PAGE_TEXT.index("es.onmessage") :]
    assert stream.index("feed.unshift(") > stream.index("isAttributed(msg)"), (
        "an unattributed event must still reach the register"
    )


def test_a_block_the_run_has_entered_is_distinguishable_from_one_it_has_not():
    """`docs` sat 2m40s between pr.merged and notes.planned looking untouched.

    A judging node publishes nothing until it finishes, so the card cannot show
    activity during the pause — but it can show that the run is *there*. Without
    a distinct state, "waiting on a slow node" and "never reached" render alike.
    """
    assert 'run.blocks[next] = "waiting"' in PAGE_TEXT, "finishing a block must enter the next"
    assert ".block.waiting::before" in PAGE_TEXT, "the waiting rail needs its own style"

    body = PAGE_TEXT[PAGE_TEXT.index("function apply(msg)") : PAGE_TEXT.index("function shardSidings")]
    assert '"waiting"' in body[: body.index("switch (t)")], (
        "a block that speaks must leave waiting, or it never reaches active"
    )
    # A counter that stops at a terminal, or a completed card keeps claiming it
    # is still expecting something.
    assert body.count("run.waiting = {}") >= 2, (
        "both run.completed and run.halted must clear the wait counters"
    )


def test_no_sse_sink_relies_on_a_wildcard():
    """sse-sink accepts the client and streams nothing for wildcard subscriptions.

    Verified against a live engine: an exact topic delivered, `probe.*` did not.
    The failure is silent, so it has to be a test.
    """
    for sink in SINKS:
        if "sse-sink" not in sink["path"]:
            continue
        wildcards = [t for t in sink["subscribes"] if "*" in t]
        assert not wildcards, f"{sink['name']} would silently receive nothing for {wildcards}"


def test_every_subscription_has_a_publisher():
    """A subscription to a topic nobody publishes is a primitive that never runs."""
    available = published() | {"system.started.*", "system.stopped.*", "system.error.*"}
    orphans = {
        topic
        for topic in subscribed()
        if topic not in available and not topic.startswith("system.")
    }
    assert not orphans, f"nothing publishes: {sorted(orphans)}"


def test_every_published_event_has_a_consumer():
    """An event nobody consumes is work that goes nowhere."""
    unconsumed = published() - RAW - subscribed()
    assert not unconsumed, f"nothing consumes: {sorted(unconsumed)}"


def test_notes_planning_fans_out_with_merge_only_after_checks_pass():
    planner = named(HANDLERS, "plan-notes")
    merger = named(HANDLERS, "merge-pr")
    assert planner["subscribes"] == ["checks.passed"]
    assert merger["subscribes"] == ["checks.passed"]
    assert "pr.merged" not in planner["subscribes"]


def test_run_completion_is_only_published_by_the_full_completion_router():
    producers = [handler for handler in HANDLERS
                 if "run.completed" in handler.get("publishes", [])]
    assert [handler["name"] for handler in producers] == ["route-completion-full"]

    joiner = named(HANDLERS, "join-completion")
    assert joiner["path"] == "signalbox"
    assert joiner["subscribes"] == ["pr.merged", "notes.synced"]
    args = " ".join(joiner["args"])
    assert "--key run_id" in args
    assert "--arms pr.merged,notes.synced" in args
    assert "--timeout-seconds" in args
    assert "--publish-as completion.closed" in args
    assert joiner["publishes"] == ["completion.closed"]

    summary = {
        "run_id": "sb-82",
        "results": [{"topic": "pr.merged"}, {"topic": "notes.synced"}],
        "timed_out": False,
    }
    assert route("route-completion-full", summary) == summary
    assert route("route-completion-short", summary) is None


def test_a_zero_note_plan_needs_the_merge_arm_to_reach_the_run_terminal():
    """The direct notes terminal is one arm, never a substitute for the merge."""
    splitter = named(HANDLERS, "split-notes")
    assert splitter["subscribes"] == ["notes.planned"]
    assert "notes.synced" in splitter["publishes"]

    completion = named(HANDLERS, "join-completion")
    assert completion["subscribes"] == ["pr.merged", "notes.synced"]
    assert completion["publishes"] == ["completion.closed"]
    assert "--arms" in completion["args"], (
        "a count join could mistake duplicate notes.synced events for both arms"
    )
    full = named(HANDLERS, "route-completion-full")
    assert full["subscribes"] == ["completion.closed"]
    assert full["publishes"] == ["run.completed"]


@pytest.mark.parametrize("topic", ["pr.merged", "notes.synced"])
def test_one_completion_arm_alone_times_out_to_halted(topic):
    """Neither arm may be routed directly to success, including zero notes."""
    direct = [
        handler["name"]
        for handler in HANDLERS
        if topic in handler.get("subscribes", [])
        and {"run.completed", "run.halted"}.intersection(handler.get("publishes", []))
        and handler["name"] != "join-completion"
    ]
    assert direct == []

    summary = {
        "run_id": "sb-82",
        "timed_out": True,
        "results": [{"topic": topic, "outcome": "arrived"}],
    }
    assert route("route-completion-full", summary) is None
    halted = route("route-completion-short", summary)
    assert halted == {
        **summary,
        "reason": "completion timed out — an arm never arrived",
    }


def test_stateful_joins_publish_neutral_topics_before_run_terminals():
    """A join reports state; stateless routers decide whether that state is terminal."""
    for handler in HANDLERS:
        args = handler.get("args", [])
        if not any(arg in {"join-terminal", "join_terminal"} for arg in args):
            continue
        publish_as = args[args.index("--publish-as") + 1]
        assert publish_as not in {"run.completed", "run.halted"}, (
            f"{handler['name']} publishes terminal {publish_as} directly"
        )


@pytest.mark.parametrize(
    "continue_handler,exhaust_handler",
    [
        ("route-plan-retry", "route-plan-exhausted"),
        ("guard-rounds-continue", "guard-rounds-exhaust"),
    ],
)
def test_depth_guards_have_both_sides(continue_handler, exhaust_handler):
    """One-sided guards duplicate rather than divert, and never terminate."""
    keep = named(HANDLERS, continue_handler)
    stop = named(HANDLERS, exhaust_handler)
    assert keep["subscribes"] == stop["subscribes"], "guards must split the same topic"
    assert "<" in " ".join(keep["args"]), f"{continue_handler} has no upper bound"
    assert ">=" in " ".join(stop["args"]), f"{exhaust_handler} has no lower bound"


def test_the_stage_pacer_is_acked_by_a_real_downstream_outcome():
    """A pacer acked by nothing that fires on the failure path stalls the batch."""
    pacer = named(HANDLERS, "pace-stages")
    args = " ".join(pacer["args"])
    assert "--ack-topic stage.merged" in args
    assert "stage.merged" in published(), "nothing would ever ack the pacer"


def test_shards_are_split_rather_than_paced():
    """Shards are disjoint by invariant, so holding them behind an ack is pure latency."""
    splitter = named(HANDLERS, "split-shards")
    assert "stream-runner" not in splitter["path"]
    assert splitter["publishes"] == ["shard.opened"]


def test_the_join_cannot_hang_on_a_shard_that_died():
    joined = set(named(HANDLERS, "join-stage")["subscribes"])
    for terminal in ("shard.approved", "shard.escalated", "shard.abandoned", "shard.silent"):
        assert terminal in joined, f"a stage would hang on {terminal}"


def test_promotion_is_decomposed_into_retryable_acts():
    """One promote handler would make a failed step a stall instead of an event."""
    for act in ("push-branch", "open-pr", "merge-pr"):
        handler = named(HANDLERS, act)
        assert len(handler["publishes"]) == 2, f"{act} has no failure event"
        assert any("failed" in topic for topic in handler["publishes"])


def test_every_model_verdict_has_an_exhaustiveness_router():
    """Model output is untrusted input; an unrecognised verdict must not vanish."""
    for topic in ("shard.submitted", "review.submitted", "gate.assessed"):
        catchers = [
            h for h in HANDLERS
            if topic in h.get("subscribes", []) and "invalid" in " ".join(h["publishes"])
        ]
        assert catchers, f"{topic} has no invalid-verdict router"


def test_no_primitive_is_named_like_a_conductor():
    """Gate 2's name test. A conductor can only ever do what it already knows."""
    banned = {"runner", "pipeline", "controller", "coordinator", "orchestrator", "manager"}
    for primitive in SOURCES + HANDLERS + SINKS:
        word = primitive["name"].lower().replace("-", " ").split()
        assert not banned.intersection(word), f"{primitive['name']} reads as a conductor"


def test_every_signalbox_subcommand_the_topology_calls_actually_exists():
    """A handler naming a command the CLI does not have fails only at runtime.

    Found the hard way: prepare-workspace was wired into the topology and into
    the acts dispatch, but never added to the CLI's command list, so the very
    first act of every run failed.
    """
    from signalbox.cli import COMMANDS

    called = set()
    for primitive in SOURCES + HANDLERS + SINKS:
        args = primitive.get("args", [])
        for index, arg in enumerate(args):
            if arg == "signalbox" and index + 1 < len(args):
                nxt = args[index + 1]
                if not nxt.startswith("-"):
                    called.add(nxt)
    assert called, "no signalbox subcommand found in the topology"
    assert called <= COMMANDS, f"topology calls unknown commands: {sorted(called - COMMANDS)}"


def test_every_act_is_reachable_from_the_acts_dispatch():
    """The mirror of the above: a command the CLI routes but acts cannot handle."""
    from signalbox.cli import ACT_COMMANDS

    handled = {"poll-checks", "reap", "launch", "notify"}  # handled before the table
    from signalbox import acts
    import inspect

    source = inspect.getsource(acts.main)
    for command in sorted(ACT_COMMANDS - handled):
        assert f'"{command}"' in source, f"acts.main cannot dispatch {command}"


def test_run_built_carries_identity_rather_than_a_bare_count():
    """stream-runner's end event is {"count": N}. Nothing downstream can use it.

    run-suite looked for a worktree named "unknown" and reported "no suite
    detected" while a passing suite sat in the real one.
    """
    pacer = named(HANDLERS, "pace-stages")
    assert "run.built" not in pacer["publishes"], "run.built must not come from the pacer"

    joiner = named(HANDLERS, "join-run")
    assert joiner["publishes"] == ["run.built"]
    assert joiner["subscribes"] == ["stage.merged"]
    args = " ".join(joiner["args"])
    assert "--key run_id" in args and "--count-field stage_count" in args


def reaped_kinds() -> set[str]:
    """Every `--kind` an interval reaper sweeps."""
    kinds = set()
    for source in SOURCES:
        args = " ".join(source.get("args", []))
        if "signalbox reap" not in args:
            continue
        kinds.add(args.split("--kind")[1].split()[0])
    return kinds


def test_every_pending_marker_has_something_that_clears_it():
    """The reaper turns silence into an event; something must end the silence.

    Without a clearer, every marker eventually ages past the stale threshold and
    a successful shard is reported as `shard.silent`. Both of demo-3's shards
    were reported silent nineteen minutes after being merged.

    Generalised over kinds when the pr reaper arrived: the shard-only version of
    this test would have passed a pr marker that nothing ever cleared.
    """
    clearer = named(SINKS, "clear-pending")
    assert "shard.submitted" in clearer["subscribes"], (
        "an agent that announced is not silent"
    )
    assert "scope.violated" in clearer["subscribes"], (
        "a scope violation terminates the shard without a submission"
    )
    dispatchers = [s for s in SINKS if "dispatch" in " ".join(s.get("args", []))]
    assert dispatchers, "no dispatcher writes markers, so this invariant is stale"

    # Every kind swept must be both written and un-written by something.
    for kind in reaped_kinds():
        writers = [
            p for p in HANDLERS + SINKS
            if f"mark-pending --kind {kind}" in " ".join(p.get("args", []))
            or (kind == "shard" and "dispatch" in " ".join(p.get("args", [])))
        ]
        assert writers, f"nothing writes a {kind} marker, so the reaper sweeps nothing"
        erasers = [
            p for p in HANDLERS + SINKS
            if f"clear-pending --kind {kind}" in " ".join(p.get("args", []))
            or f"rehydrate --kind {kind}" in " ".join(p.get("args", []))
        ]
        assert erasers, f"nothing clears a {kind} marker, so success reads as silence"


def test_each_reaper_raises_only_its_own_kind():
    """Both reapers publish through `exec.output`, so the selectors must not
    overlap. A bare test("reap") matched both and would have announced a stalled
    PR as `shard.silent`."""
    raisers = {
        h["name"]: h["args"][-1]
        for h in HANDLERS
        if h.get("subscribes") == ["exec.output"] and "reap" in h["args"][-1]
    }
    assert len(raisers) == len(reaped_kinds()), "a reaped kind has no raiser"
    for kind in reaped_kinds():
        matching = [n for n, prog in raisers.items() if f"--kind {kind}" in prog]
        assert len(matching) == 1, f"{kind} is raised by {matching}, expected exactly one"


def test_the_promote_path_waits_on_a_push_rather_than_a_poll():
    """`checks.reported` must originate from GitHub telling us, not us asking.

    The poller it replaced burned a `gh pr list` every 45s to recompute a
    conclusion GitHub had already computed, and hid issue #56 while doing it.
    """
    for source in SOURCES:
        assert "poll-checks" not in " ".join(source.get("args", [])), (
            "the promote path is polling again"
        )
    assert named(SOURCES, "github")["publishes"] == ["http.request"]
    router = named(HANDLERS, "route-check-suite")
    assert router["subscribes"] == ["http.request"]
    # The webhook cannot carry issue or base_sha, so identity is restored, and
    # `checks.reported` is what carries it onward.
    rehydrator = named(HANDLERS, "rehydrate-pr")
    assert rehydrator["subscribes"] == router["publishes"]
    assert "checks.reported" in rehydrator["publishes"]


def test_both_http_sources_are_distinguishable_by_shape():
    """http-source publishes a fixed topic, so control POSTs and GitHub deliveries
    arrive as the same event type and every router must tell them apart itself."""
    ingress = [s for s in SOURCES if "http-source" in s["path"]]
    assert len(ingress) == 2, "this invariant assumes exactly two ingress sources"
    assert all(s["publishes"] == ["http.request"] for s in ingress)

    ports = {s["args"][s["args"].index("--port") + 1] for s in ingress}
    assert len(ports) == 2, "two http-sources cannot share a port"
    for source in ingress:
        assert source["args"][source["args"].index("--host") + 1] == "127.0.0.1", (
            "an ingress actuator must not be reachable off-loopback"
        )

    for handler in HANDLERS:
        if handler.get("subscribes") != ["http.request"]:
            continue
        prog = handler["args"][-1]
        assert "x-github-event" in prog or ".body.event" in prog, (
            f"{handler['name']} reads http.request without distinguishing its origin"
        )


def test_the_join_count_a_run_terminates_on_is_an_identity_key():
    """`join-run` waits on stage_count, so stage_count must be carried, not
    reconstructed. It was carried into shard.opened and lost at the agent's
    emission, which stalled every run after its final stage merged."""
    from signalbox.identity import CARRIED_KEYS

    joiner = named(HANDLERS, "join-run")
    count_field = joiner["args"][joiner["args"].index("--count-field") + 1]
    assert count_field in CARRIED_KEYS


def test_the_dashboard_stream_has_something_to_carry_while_idle():
    """An idle sse-sink stream sends zero bytes, so a browser calls it dead.

    Its headers are chunked and do not flush until the first event, so with no
    run in flight the dashboard reports "can't establish a connection" — broken
    exactly when it should read as quiet. Verified live: curl received 0 bytes
    from an idle stream for three seconds, then headers and data arrived
    together the instant an event was posted.

    Something must therefore flow while nothing is running, and the only such
    traffic is the interval sources' output.
    """
    dashboard = named(SINKS, "dashboard")
    interval_topics: set[str] = set()
    for source in SOURCES:
        args = source.get("args", [])
        if "--interval" in args:
            interval_topics.update(source.get("publishes", []))
    assert interval_topics, "no interval source, so nothing keeps the stream warm"
    assert interval_topics & set(dashboard["subscribes"]), (
        "the dashboard subscribes to nothing that flows while idle; its stream "
        f"will never open. Interval traffic is {sorted(interval_topics)}"
    )


def test_every_non_deterministic_node_publishes_invocation_provenance():
    """A model verdict without its invocation edge cannot be audited.

    The package owns the role-to-output declaration while emergent.toml owns the
    executable graph. Comparing both here prevents either declaration from
    quietly gaining a model-bearing role the other does not know about.
    """
    from signalbox.agent import ROLE_PRODUCED_TOPICS

    nodes_by_role = {
        "survey": "survey-codebase",
        "plan": "draft-plan",
        "review": "review-shard",
        "assess": "assess",
        "plan-notes": "plan-notes",
        "write-note": "write-note",
        "implement": "dispatch-implement",
        "fix": "dispatch-fix",
    }
    assert set(nodes_by_role) == set(ROLE_PRODUCED_TOPICS)

    primitives = HANDLERS + SINKS
    for role, node_name in nodes_by_role.items():
        node = named(primitives, node_name)
        produced = set(node.get("publishes", []))
        assert "model.invoked" in produced, f"{node_name} loses invocation provenance"
        if role not in {"implement", "fix"}:
            assert ROLE_PRODUCED_TOPICS[role] in produced, (
                f"{node_name} disagrees with ROLE_PRODUCED_TOPICS[{role!r}]"
            )
        else:
            assert ROLE_PRODUCED_TOPICS[role] == "shard.submitted"


# ── routing, executed rather than inspected ──────────────────────────────────
#
# Every test above reads the config. These run the jq, because a selector that
# matches nothing parses perfectly and fails silently — which is precisely how a
# gate-cleared run sat at `pr.opened` with no event to wait for.


def route(handler_name: str, payload: dict) -> dict | None:
    """Run a router's jq against a payload. None when it does not match."""
    import json
    import shutil
    import subprocess

    if shutil.which("jq") is None:
        pytest.skip("jq is not installed")
    prog = named(HANDLERS, handler_name)["args"][-1]
    done = subprocess.run(
        ["jq", "-c", prog], input=json.dumps(payload),
        capture_output=True, text=True, check=False,
    )
    assert done.returncode == 0, f"{handler_name} jq failed: {done.stderr}"
    out = done.stdout.strip()
    return json.loads(out) if out else None


def delivery(conclusion: str, branch: str = "signalbox/run-sb-56",
             prs: tuple[int, ...] = (57,), action: str = "completed") -> dict:
    return {
        "headers": {"x-github-event": "check_suite"},
        "body": {
            "action": action,
            "repository": {"full_name": "rrrodzilla/signalbox"},
            "check_suite": {
                "head_branch": branch,
                "head_sha": "e0a1742",
                "conclusion": conclusion,
                "check_runs_url": "https://api.github.com/x/check-runs",
                "pull_requests": [{"number": n} for n in prs],
            },
        },
    }


@pytest.mark.parametrize(
    "conclusion, expected",
    [("success", "success"), ("neutral", "success"), ("skipped", "success"),
     ("failure", "failure"), ("timed_out", "failure"), ("action_required", "failure")],
)
def test_a_concluded_suite_becomes_a_promote_signal(conclusion, expected):
    routed = route("route-check-suite", delivery(conclusion))
    assert routed is not None, f"{conclusion} was dropped"
    assert routed["conclusion"] == expected
    assert routed["pr"] == 57
    assert routed["run_id"] == "sb-56", "run identity comes from the branch name"
    assert routed["repo"] == "rrrodzilla/signalbox"


def test_checks_passed_carries_string_run_identity_to_notes_planning():
    reported = {
        "run_id": "sb-69",
        "repo": "rrrodzilla/signalbox",
        "issue": 69,
        "base_sha": "abc123",
        "conclusion": "success",
    }
    passed = route("route-checks-passed", reported)
    assert passed == reported
    assert isinstance(passed["run_id"], str)
    assert named(HANDLERS, "plan-notes")["subscribes"] == ["checks.passed"]


@pytest.mark.parametrize("conclusion", ["cancelled", "stale"])
def test_a_superseded_suite_is_dropped_rather_than_called_a_failure(conclusion):
    """cancel-in-progress produces one of these on every amended push.

    Routing them as failures would open a fix loop against work that was never
    judged, and the fix loop writes commits — so this is not a cosmetic drop.
    """
    assert route("route-check-suite", delivery(conclusion)) is None


@pytest.mark.parametrize(
    "payload, why",
    [
        (delivery("success", branch="feature/unrelated"), "not a run branch"),
        (delivery("success", prs=()), "no PR to merge"),
        (delivery("success", action="requested"), "not concluded"),
        ({"headers": {"x-github-event": "push"}, "body": {"ref": "main"}}, "not a suite"),
        ({"headers": {}, "body": {"event": "shard.submitted"}}, "a control POST"),
    ],
)
def test_only_a_concluded_run_suite_is_routed(payload, why):
    assert route("route-check-suite", payload) is None, f"routed something that is {why}"


def test_a_github_delivery_is_not_reported_as_an_unknown_emission():
    """The catch-all fires on anything without known vocabulary in `.body.event`.

    GitHub deliveries share the topic and have no `.body.event` at all, so without
    a header guard every CI conclusion would also publish `control.unknown-event`
    — a real, wrong, notified event on every green build.
    """
    assert route("route-unknown-emission", delivery("success")) is None
    assert route("route-unknown-emission",
                 {"headers": {"x-github-event": "push"}, "body": {}}) is None

    # Still reports genuine unknown vocabulary from the control port.
    unknown = route("route-unknown-emission",
                    {"headers": {}, "body": {"event": "shard.vibes", "run_id": "x"}})
    assert unknown == {"event": "shard.vibes", "run_id": "x"}


def test_a_model_invocation_routes_to_its_topic_and_nowhere_else():
    """Provenance shares the control ingress with five commands.

    A selector that overlaps another ingress router duplicates one model call
    into domain work, while a selector that misses silently erases the audit
    edge, so execute every control router against the real envelope.
    """
    envelope = {
        "headers": {},
        "body": {"event": "model.invoked", "run_id": "sb-60", "role": "review"},
    }
    control_routers = [
        h["name"]
        for h in HANDLERS
        if h.get("subscribes") == ["http.request"]
        and h["name"] != "route-check-suite"
    ]
    routed = {name: route(name, envelope) for name in control_routers}
    assert routed["route-model-invoked"] == envelope["body"]
    assert all(
        result is None
        for name, result in routed.items()
        if name != "route-model-invoked"
    ), f"model.invoked also routed through {routed}"


def test_a_model_invocation_is_known_control_vocabulary():
    """Every invocation used to produce a false unknown-event beside provenance."""
    envelope = {
        "headers": {},
        "body": {"event": "model.invoked", "run_id": "sb-60", "role": "plan"},
    }
    assert route("route-unknown-emission", envelope) is None


def test_the_page_treats_heartbeat_traffic_as_proof_of_life_not_content():
    """Consumed telemetry must not weaken the interval proof-of-life contract.

    model.invoked is consumed by the stream but is not a heartbeat rendered by
    the page; adding it must not let either interval topic escape filtering.
    """
    page = (ROOT / "src" / "signalbox" / "dashboard.html").read_text()
    assert "HEARTBEAT" in page, "the page has no heartbeat filter"
    dashboard = named(SINKS, "dashboard")
    assert "model.invoked" in dashboard["subscribes"]
    # Asserted as a property rather than a shape: provenance used to be diverted
    # by an early return inside apply(), and is now diverted at the stream. Either
    # way the contract is that it is recorded, and that it never reaches the card
    # or the register — which is also why apply() may have no early exit.
    assert "provenance.set(" in page, "model.invoked must be recorded as provenance"
    divert = page.index("if (isProvenance(msg))")
    assert page.index("recordProvenance(", divert) < page.index("return;", divert), (
        "model.invoked must be consumed as provenance before rendering"
    )
    assert divert < page.index("apply(msg);"), (
        "provenance must be diverted before apply(), or it moves the card while "
        "staying out of the register — the same inconsistency, inverted"
    )
    assert divert < page.index("feed.unshift("), (
        "model.invoked must not become standalone feed content"
    )
    for source in SOURCES:
        if "--interval" not in source.get("args", []):
            continue
        for topic in source.get("publishes", []):
            if topic in dashboard["subscribes"]:
                assert f'"{topic}"' in page, f"{topic} is subscribed but not filtered from the feed"


def test_a_completed_run_releases_the_worktree_it_was_built_in():
    """Nothing released a worktree before; every run since the rewrite kept its tree."""
    release = named(HANDLERS, "release-workspace")
    assert release["subscribes"] == ["run.completed"]
    assert "signalbox" in release["args"]
    assert "release-workspace" in release["args"]


def test_the_worktree_outlives_the_merge_because_notes_are_still_inside_it():
    """#69 moved notes to checks.passed, so they overlap the merge.

    Every agent runs with cwd set to the run's worktree, so a release triggered
    by pr.merged would delete the directory out from under a write-note agent
    that is still working in it. The rendezvous is the first moment nothing is
    left inside.
    """
    release = named(HANDLERS, "release-workspace")
    assert "pr.merged" not in release["subscribes"]
    assert "checks.passed" not in release["subscribes"]
    assert named(HANDLERS, "plan-notes")["subscribes"] == ["checks.passed"]


def test_a_halted_run_keeps_its_worktree_as_evidence():
    releasing = [handler["name"] for handler in HANDLERS
                 if "run.halted" in handler.get("subscribes", [])
                 and "release-workspace" in handler.get("args", [])]
    assert releasing == []


def test_a_refused_release_cannot_announce_itself_as_released():
    """`_out` exits 0 whatever the act decided (#66), so ok is routed, not trusted."""
    attempted = named(HANDLERS, "release-workspace")["publishes"]
    assert "workspace.released" not in attempted, (
        "the act must publish an attempt; only a router may call it released"
    )
    assert route("route-release-ok", {"ok": True, "run_id": "sb-69"}) is not None
    assert route("route-release-ok", {"ok": False, "run_id": "sb-69"}) is None
    assert route("route-release-refused", {"ok": False, "run_id": "sb-69"}) is not None
    assert route("route-release-refused", {"ok": True, "run_id": "sb-69"}) is None
