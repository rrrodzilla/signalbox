"""Architectural invariants of the topology itself.

These are the Gate 2 review questions turned into assertions, because the
failure they catch is silent: a misrouted or unobserved event produces no error,
just a run that quietly does less than it should.
"""

from __future__ import annotations

import re
import ast
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
            r'"([a-z][\w.\-]*)":\s*\[\s*(null|"[a-z]+")\s*,\s*"([a-z]+)"'
            r'(?:\s*,[^\]]+)?\s*\]',
            body,
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


def test_dashboard_uses_the_declared_shard_denominator():
    """Issue #85: sb-69 must not show 2/2 while its third shard is unopened."""
    apply_body = PAGE_TEXT[
        PAGE_TEXT.index("function apply(msg)") : PAGE_TEXT.index("function shardSidings")
    ]
    sidings = PAGE_TEXT[
        PAGE_TEXT.index("function shardSidings") : PAGE_TEXT.index("const LAMP_FOR")
    ]

    assert re.search(
        r"run\.stages\.set\(p\.stage_id,\s*"
        r"recorded\s*==\s*null\s*\?\s*p\.shard_count\s*:\s*"
        r"Math\.max\(recorded,\s*p\.shard_count\)\)",
        apply_body,
    ), (
        "shard_count must be retained without letting a conflict-reopen subset "
        "lower an established stage declaration"
    )
    assert re.search(r'done\s*\+\s*"/"\s*\+\s*declared', sidings), (
        "the shard meter must render the stage's declared shard_count"
    )
    assert not re.search(r'done\s*\+\s*"/"\s*\+\s*run\.shards\.size', sidings), (
        "observed shard IDs are not the declared denominator"
    )


def test_dashboard_counts_every_unique_shard_terminal_as_done():
    """Issue #85: sb-69's numerator includes every review-loop terminal."""
    apply_body = PAGE_TEXT[
        PAGE_TEXT.index("function apply(msg)") : PAGE_TEXT.index("function shardSidings")
    ]
    sidings = PAGE_TEXT[
        PAGE_TEXT.index("function shardSidings") : PAGE_TEXT.index("const LAMP_FOR")
    ]

    approved = apply_body[
        apply_body.index('case "shard.approved"') :
        apply_body.index('case "shard.changes-requested"')
    ]
    assert 'run.shards.set(p.shard_id, "done")' in approved

    failed_terminals = apply_body[
        apply_body.index('case "shard.escalated"') :
        apply_body.index('case "stage.merged"')
    ]
    for topic in (
        "shard.escalated",
        "shard.abandoned",
        "shard.invalid-verdict",
        "shard.silent",
        "scope.violated",
    ):
        assert f'case "{topic}"' in failed_terminals, f"{topic} is not terminal"
    assert 'run.shards.set(p.shard_id, "escalated")' in failed_terminals
    assert re.search(
        r'new Set\(\[\s*"done",\s*"escalated"\s*\]\)', sidings
    ), "both successful and unsuccessful shard terminals must advance done"


def test_dashboard_uses_the_declared_stage_denominator():
    """Issue #85: sb-69's stage position comes from event-carried stage_count."""
    apply_body = PAGE_TEXT[
        PAGE_TEXT.index("function apply(msg)") : PAGE_TEXT.index("function shardSidings")
    ]
    sidings = PAGE_TEXT[
        PAGE_TEXT.index("function shardSidings") : PAGE_TEXT.index("const LAMP_FOR")
    ]

    assert re.search(
        r"run\.stageCount\s*=\s*p\.stage_count", apply_body
    ), "stage_count must be captured from the replayed event stream"
    assert re.search(
        r"stage '\s*\+\s*Math\.min\(run\.merged\s*\+\s*1,\s*run\.stageCount\)"
        r'\s*\+\s*" of "\s*\+\s*run\.stageCount',
        sidings,
    ), (
        "stage position must render merged+1 of the declared stage_count "
        "without advancing beyond the final declared stage"
    )


def test_an_event_with_no_run_id_does_not_invent_a_run_card():
    """An unattributed operational event must not mint a phantom run.

    Error topics from exec-handler publish `{command, exit_code, stderr}`
    instead of the inbound payload (#66), and reaper telemetry never had a run.
    Bucketing either under a fake key drew a card for a run nobody launched.
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
    stream = PAGE_TEXT[
        PAGE_TEXT.index("function handleMessage") : PAGE_TEXT.index("async function attachStream")
    ]
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


def test_a_silent_judging_node_is_in_flight_until_its_output_lands():
    """Issue #68: audit-plan was opaque between plan.verified and plan.audited.

    PAGE_TEXT proves the source contract rather than the page served by a
    running engine; this repository deliberately has no JavaScript test runner.
    """
    table = event_table()
    assert "survey-codebase" not in PAGE_TEXT, "the removed judging role must stay gone"
    assert table["plan.verified"] == ("plan", "work")
    assert table["plan.audited"] == ("plan", "judge")
    assert '"plan.verified":["plan","work","audit-plan","in"]' in PAGE_TEXT
    assert '"plan.audited":["plan","judge","audit-plan","out"]' in PAGE_TEXT

    body = PAGE_TEXT[
        PAGE_TEXT.index("function apply(msg)") : PAGE_TEXT.index("function shardSidings")
    ]
    assert 'if (node && direction === "in")' in body
    assert "run.inFlight.set(" in body, (
        "an input replayed without its output must leave the judging node in flight"
    )
    assert "run.inFlight.delete(key)" in body
    assert body.index("run.inFlight.delete(key)") < body.index(
        'if (node && direction === "in")'
    ), "the output (or next scoped event) must clear the preceding in-flight window"

    rendered = PAGE_TEXT[
        PAGE_TEXT.index("function renderRun(run, now)") : PAGE_TEXT.index("function renderBoard")
    ]
    assert "run.inFlight.values()" in rendered
    assert 'class="judge-node"' in rendered
    assert "r.inFlight.size > 0" in PAGE_TEXT, (
        "the 800ms silence render must keep the in-flight indicator moving"
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


PASSIVE_CONSUMER_EXEMPTIONS = {
    "exec.exit": "interval-source liveness telemetry is intentionally observed rather than advanced",
    "model.invoked": "invocation provenance is audit telemetry and not run-control input",
    "shard.check-ran": "a check announcement is progress telemetry while the shard remains in flight",
    "run.halted": "the failure terminal is observed and notified but cannot advance further",
    "workspace.released": "successful cleanup occurs after the run terminal and needs no successor",
    "checks.unknown-pr": "a check_suite delivery without a pending marker names no run to terminate",
    "workspace.release-failed": "workspace release begins only after the run terminal",
    "control.unknown-event": (
        "an event outside the control allowlist is an operator error whose payload may name no run"
    ),
    "stages.exhausted": (
        "the last stage.merged publishes this redundant progress marker in parallel with run.built; "
        "routing it to a terminal would halt every healthy run"
    ),
}


def test_every_published_event_has_an_active_consumer_or_a_written_exemption():
    """Passive observability sinks must not disguise a stranded run-control event."""
    passive = {"dashboard", "notify", "trace", "topology"}
    consumers = {
        topic: {
            primitive["name"]
            for primitive in HANDLERS + SINKS
            if topic in primitive.get("subscribes", [])
        }
        for topic in published()
    }
    passive_only = {
        topic for topic, names in consumers.items()
        if names and names <= passive
    }
    assert set(PASSIVE_CONSUMER_EXEMPTIONS) <= published()
    missing = passive_only - set(PASSIVE_CONSUMER_EXEMPTIONS)
    assert not missing, f"published topics with only passive consumers: {sorted(missing)}"


def error_topics() -> set[str]:
    """Every exec-handler error edge declared by the topology."""
    topics = set()
    for primitive in HANDLERS + SINKS:
        args = primitive.get("args", [])
        topics.update(args[index + 1] for index, arg in enumerate(args[:-1]) if arg == "-e")
    return topics


ERROR_HANDLER_EXEMPTIONS = {
    # No pending marker means the delivery carries no run identity to terminate.
    "checks.unknown-pr": "a check_suite delivery without a pending marker names no run",
    # Release is downstream of run.completed, and refusal publishes a second shape.
    "workspace.release-failed": "workspace release begins only after the run terminal",
}


def test_every_error_topic_has_a_handler_or_a_written_terminal_exemption():
    """A new -e edge must not silently strand the run that reached its node."""
    consumers = {
        topic
        for handler in HANDLERS
        for topic in handler.get("subscribes", [])
    }
    assert set(ERROR_HANDLER_EXEMPTIONS) <= error_topics()
    missing = error_topics() - consumers - set(ERROR_HANDLER_EXEMPTIONS)
    assert not missing, f"-e topics with no handler: {sorted(missing)}"


@pytest.mark.parametrize(
    "router,reason",
    [
        ("route-plan-draft-failed-halted", "plan drafting failed"),
        ("route-plan-audit-failed-halted", "plan audit failed"),
        ("route-review-failed-halted", "shard review failed"),
        ("route-rebase-failed-halted", "branch rebase failed"),
        ("route-assess-failed-halted", "promotion assessment failed"),
        ("route-remediation-failed-halted", "remediation failed"),
        ("route-notes-plan-failed-halted", "notes planning failed"),
    ],
)
def test_judging_error_routers_execute_against_nested_error_payloads(router, reason):
    """The v0.11.0 -e envelope nests diagnostics while retaining run identity."""
    payload = {
        "run_id": "sb-110",
        "error": {"exit_code": 17, "stderr": "quota exhausted"},
    }
    assert route(router, payload) == {
        **payload,
        "reason": f"{reason} (exit 17): quota exhausted",
    }

    timed_out = {
        "run_id": "sb-110",
        "error": {"exit_code": None, "stderr": "process timed out"},
    }
    assert route(router, timed_out) == {
        **timed_out,
        "reason": f"{reason} (no exit code): process timed out",
    }

    # The old, un-nested shape must not accidentally satisfy the selector.
    assert route(router, {
        "run_id": "sb-110", "exit_code": 17, "stderr": "quota exhausted"
    }) is None


def test_pre_worktree_failures_route_directly_to_halted():
    workspace = {"run_id": "sb-87", "ok": False}
    assert route("route-prepare-failed-halted", workspace) == {
        **workspace,
        "reason": "workspace preparation failed before a worktree was available",
    }
    fetched = {"run_id": "sb-87", "ok": False, "issue": 87}
    assert route("route-fetch-failed-halted", fetched) == {
        **fetched,
        "reason": "issue fetch failed before a usable worktree was available",
    }


def test_remediation_selectors_execute_as_a_bounded_exhaustive_loop():
    stranded = route("route-gate-blocked", {
        "run_id": "sb-87", "issue": 87, "decision": "block",
    })
    assert stranded is not None
    requested = route("route-remediation-open", stranded)
    assert requested == {**stranded, "attempt": 1}

    # Mirror agent.py's Shape A publication seam. Only CARRIED_KEYS from the
    # inbound envelope accompany the verdict, so this proves the live counter
    # survives project() rather than merely testing an invented post-seam event.
    from signalbox.identity import merge, project

    verdict = {"remediation": "retry", "reason": "may clear"}
    merged = merge(requested, verdict, "remediate")
    retry = {**verdict, **project(merged.payload)}
    assert retry["attempt"] == 1
    assert "stranded_topic" not in retry, "non-carried diagnosis context must not be assumed post-seam"

    assert route("guard-remediation-retry", retry) == {
        **retry, "attempt": 2,
    }
    assert route("guard-remediation-exhaust", retry) is None
    assert route("route-remediation-halt", retry) is None
    assert route("route-remediation-invalid", retry) is None

    last_retry = {**retry, "attempt": 3}
    assert route("guard-remediation-retry", last_retry) is None
    closed = route("guard-remediation-exhaust", last_retry)
    assert closed == {
        **last_retry, "reason": "remediation retry budget exhausted: may clear",
    }
    assert route("route-remediation-closed-halted", closed) == closed

    # Defensive exhaustiveness: the exact old live envelope had no counter.
    # It must close, never exploit jq's `null < 3` ordering to restart at one.
    counterless = {"run_id": "sb-87", **verdict}
    assert route("guard-remediation-retry", counterless) is None
    assert route("guard-remediation-exhaust", counterless) == {
        **counterless,
        "reason": "remediation retry budget exhausted: may clear",
    }

    halt = {**requested, "remediation": "halt", "reason": "restore credentials"}
    assert route("route-remediation-halt", halt) == halt
    assert route("guard-remediation-retry", halt) is None
    assert route("guard-remediation-exhaust", halt) is None
    assert route("route-remediation-invalid", halt) is None
    assert route("route-remediation-closed-halted", halt) == halt

    invalid = {**requested, "remediation": "continue"}
    assert route("route-remediation-invalid", invalid) == invalid
    assert route("route-remediation-invalid-halted", invalid) == {
        **invalid, "reason": "remediation returned an invalid verdict",
    }


@pytest.mark.parametrize(
    "router,payload,topic",
    [
        ("route-plan-invalid", {"run_id": "sb-87", "stages": []}, "plan.invalid-verdict"),
        ("route-audit-invalid", {"run_id": "sb-87", "verdict": "maybe"}, "plan.invalid-verdict"),
        ("route-review-invalid", {"run_id": "sb-87", "verdict": "maybe"}, "review.invalid-verdict"),
        ("route-rebase-conflict", {"run_id": "sb-87", "ok": False}, "branch.rebase-conflicted"),
        ("route-rebase-invalid", {"run_id": "sb-87", "ok": "maybe"}, "branch.rebase-invalid-verdict"),
        ("route-gate-blocked", {"run_id": "sb-87", "decision": "block"}, "gate.blocked"),
        ("route-gate-invalid", {"run_id": "sb-87", "decision": "maybe"}, "gate.invalid-verdict"),
        ("route-push-failed", {"run_id": "sb-87", "ok": False}, "branch.push-failed"),
        ("route-open-failed", {"run_id": "sb-87", "ok": False}, "pr.open-failed"),
        ("route-merge-pr-failed", {"run_id": "sb-87", "ok": False}, "pr.merge-failed"),
    ],
)
def test_each_remediation_producer_names_the_topic_it_stranded(router, payload, topic):
    routed = route(router, payload)
    assert routed == {**payload, "stranded_topic": topic}


def test_silent_checks_name_the_topic_the_reaper_stranded():
    payload = {
        "command": "signalbox reap --kind pr --stale-minutes 40",
        "stdout": '{"run_id":"sb-87","pr":87}',
    }
    assert route("raise-pr-reaped", payload) == {
        "run_id": "sb-87", "pr": 87, "stranded_topic": "checks.silent",
    }


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


def test_remediation_subgraph_cannot_publish_past_the_gate():
    """The remediation block is topological: none of its nodes can promote a run."""
    remediation_nodes = [
        handler for handler in HANDLERS
        if "remediation" in handler["name"] or handler["name"] == "remediate"
    ]
    assert remediation_nodes, "the resolved topology contains no remediation subgraph"
    published_by_remediation = {
        topic for handler in remediation_nodes for topic in handler.get("publishes", [])
    }
    post_gate = {
        "gate.cleared", "approval.granted", "run.completed", "run.built",
        "suite.ran", "branch.pushed", "pr.opened", "checks.passed",
    }
    assert published_by_remediation.isdisjoint(post_gate)


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
        ("route-audit-changes", "route-audit-exhausted"),
        ("guard-stages-advance", "guard-stages-exhaust"),
        ("guard-rounds-continue", "guard-rounds-exhaust"),
        ("guard-remediation-retry", "guard-remediation-exhaust"),
    ],
)
def test_depth_guards_have_both_sides(continue_handler, exhaust_handler):
    """One-sided guards duplicate rather than divert, and never terminate."""
    keep = named(HANDLERS, continue_handler)
    stop = named(HANDLERS, exhaust_handler)
    assert keep["subscribes"] == stop["subscribes"], "guards must split the same topic"
    assert "<" in " ".join(keep["args"]), f"{continue_handler} has no upper bound"
    assert ">=" in " ".join(stop["args"]), f"{exhaust_handler} has no lower bound"


def test_stage_routers_are_wired_to_event_carried_progress():
    first = named(HANDLERS, "open-first-stage")
    advance = named(HANDLERS, "guard-stages-advance")
    exhaust = named(HANDLERS, "guard-stages-exhaust")

    assert first["subscribes"] == ["plan.accepted"]
    assert first["publishes"] == ["stage.opened"]
    assert advance["subscribes"] == exhaust["subscribes"] == ["stage.merged"]
    assert advance["publishes"] == ["stage.opened"]
    assert exhaust["publishes"] == ["stages.exhausted"]
    assert all("stream-runner" not in h["path"] for h in (first, advance, exhaust))


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
        assert len(handler["publishes"]) == 1, f"{act} must publish one attempt"
        attempted = handler["publishes"][0]
        assert attempted.endswith("-attempted")
        outcomes = [
            h for h in HANDLERS if h.get("subscribes") == [attempted]
        ]
        assert len(outcomes) == 2, f"{act} has no routed failure event"
        assert any(
            "failed" in topic
            for outcome in outcomes
            for topic in outcome["publishes"]
        )


def test_rebase_precedes_the_suite_without_changing_the_gate_push_edges():
    rebase = named(HANDLERS, "rebase-branch")
    suite = named(HANDLERS, "run-suite")
    push = named(HANDLERS, "push-branch")

    assert rebase["subscribes"] == ["run.built"]
    assert rebase["args"][rebase["args"].index("-e") + 1] == "branch.rebase-failed"
    assert "branch.rebase-failed" in rebase["publishes"]
    assert suite["subscribes"] == ["branch.rebased"]
    assert "run.built" not in suite["subscribes"]
    assert push["subscribes"] == ["gate.cleared", "approval.granted"]


def test_rebase_invocation_failure_is_observable_and_closes_its_window():
    dashboard = named(SINKS, "dashboard")
    assert "branch.rebase-failed" in dashboard["subscribes"]
    assert '"branch.rebase-failed":["gate","stop"]' in PAGE_TEXT
    recorder = PAGE_TEXT[
        PAGE_TEXT.index("function recordProvenance") :
        PAGE_TEXT.index("function renderInvocationFailures")
    ]
    assert 'p.role === "rebase" && p.ok === false' in recorder
    assert 'flight.node === "rebase-branch"' in recorder
    assert 'run.blocks.gate = "failed"' in recorder


def test_no_path_from_run_built_reaches_suite_ran_without_the_rebase_node():
    """A new seam must not let the suite exercise an unre-based tree."""
    reachable = {"run.built"}
    while True:
        expanded = set(reachable)
        for handler in HANDLERS:
            if handler["name"] == "rebase-branch":
                continue
            if reachable & set(handler.get("subscribes", [])):
                expanded.update(handler.get("publishes", []))
        if expanded == reachable:
            break
        reachable = expanded
    assert "suite.ran" not in reachable


def test_every_model_verdict_has_an_exhaustiveness_router():
    """Model output is untrusted input; an unrecognised verdict must not vanish."""
    for topic in (
        "plan.submitted", "shard.submitted", "review.submitted",
        "branch.rebase-attempted", "gate.assessed", "plan.audited",
    ):
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
    """The stage terminal must not replace the identity-bearing run join."""
    producers = [
        handler["name"]
        for handler in HANDLERS
        if "run.built" in handler.get("publishes", [])
    ]
    assert producers == ["join-run"]
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


def test_approval_wait_is_marked_and_cleared_for_the_same_run():
    """A grant for one overlapping run must not release another run's gate."""
    marker = named(SINKS, "mark-approval-pending")
    clearer = named(SINKS, "clear-approval-pending")

    assert marker["subscribes"] == ["approval.requested"]
    assert marker["args"][-3:] == ["mark-pending", "--kind", "approval"]
    assert clearer["subscribes"] == ["approval.granted"]
    assert clearer["args"][-3:] == ["clear-pending", "--kind", "approval"]

    from signalbox.dispatch import PENDING_KEYS

    assert PENDING_KEYS["approval"] == ("run_id",)


def test_approval_waits_are_not_reaped_on_agent_or_ci_clocks():
    """Human approval may legitimately take far longer than either reaper."""
    assert "approval" not in reaped_kinds()
    raiser_programs = [
        h["args"][-1]
        for h in HANDLERS
        if h.get("subscribes") == ["exec.output"] and "reap" in h["args"][-1]
    ]
    assert raiser_programs
    assert all("reap --kind approval" not in program for program in raiser_programs)


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


def test_fixer_sessions_stay_outside_reaped_pending_kinds(monkeypatch, tmp_path):
    """Session records use a namespace that pending-marker reapers never sweep."""
    from signalbox.paths import sessions_dir

    monkeypatch.setenv("SIGNALBOX_STATE", str(tmp_path))
    session_path = sessions_dir("run-1") / "session-shard-1.json"
    session_kind = session_path.relative_to(tmp_path).parts[0]

    assert session_kind == "sessions"
    assert session_kind not in reaped_kinds()


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


def test_every_fetched_issue_field_is_carried_or_deliberately_run_local(monkeypatch):
    """New issue metadata must not silently disappear at the next payload seam."""
    from signalbox import acts
    from signalbox.identity import CARRIED_KEYS

    monkeypatch.setattr(
        acts,
        "_run",
        lambda *args, **kwargs: (
            0,
            '{"number":80,"title":"Carry fetched fields","body":"Details",'
            '"labels":[{"name":"bug"}]}',
            "",
        ),
    )
    inbound = {"run_id": "sb-80", "repo": "owner/repo", "issue": 80, "ok": True}
    fetched_fields = acts.fetch_issue(inbound).keys() - inbound.keys()

    run_local = {
        # Carrying full issue bodies on every event would add noise to the run.
        "body",
        # Nothing downstream consumes labels today; a future consumer must
        # consciously promote them into CARRIED_KEYS when it needs them.
        "labels",
    }
    assert fetched_fields <= set(CARRIED_KEYS) | run_local


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
        "plan": "draft-plan",
        "audit": "audit-plan",
        "review": "review-shard",
        "rebase": "rebase-branch",
        "assess": "assess",
        "remediate": "remediate",
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


# The same eight nodes as the provenance test, for the same reason: a model call
# is the slow, IO-bound thing in this topology, and every one of them is an exec
# primitive whose `--max-concurrent` defaults to 1.
MODEL_NODES = (
    "draft-plan", "audit-plan", "review-shard", "rebase-branch", "assess",
    "remediate", "plan-notes", "write-note", "dispatch-implement", "dispatch-fix",
)


def max_concurrent(primitive: dict) -> int:
    """What a primitive declares, or the exec default it inherits by saying nothing."""
    args = primitive["args"]
    boundary = args.index("--") if "--" in args else len(args)
    flags = args[:boundary]
    return int(flags[flags.index("--max-concurrent") + 1]) if "--max-concurrent" in flags else 1


@pytest.mark.parametrize("node_name", MODEL_NODES)
def test_no_model_node_consumes_its_subscription_serially(node_name):
    """A serial model node is a global lock wearing an event subscription.

    exec-handler and exec-sink default to `--max-concurrent 1`, which is one
    process consuming its whole subscription in arrival order. On a node that
    waits minutes for a model, that default silently paced work the rest of the
    design had already licensed to run at once — split-shards fanned a stage
    out, the join armed for the full count, the dashboard drew every card, and
    then the shards ran one at a time with nothing downstream able to tell.

    The flag has to be read before the `--` boundary. After it, `--max-concurrent`
    is an argument to the agent's own command and means nothing to the primitive.
    """
    node = named(HANDLERS + SINKS, node_name)
    assert max_concurrent(node) > 1, f"{node_name} serialises every model call"


def test_a_stage_is_never_paced_by_the_node_that_implements_it():
    """Disjointness licenses the fan-out; the dispatcher must not take it back.

    The width here is what makes `test_shards_are_split_rather_than_paced` mean
    something. A splitter that publishes N events into a sink that runs one at a
    time is the ack-paced design that test forbids, reintroduced one node later
    and invisible to every event the topology carries.
    """
    widest_stage_ever_planned = 5
    for node_name in ("dispatch-implement", "review-shard", "dispatch-fix"):
        node = named(HANDLERS + SINKS, node_name)
        assert max_concurrent(node) >= widest_stage_ever_planned, (
            f"{node_name} would queue shards of a single stage behind each other"
        )


def test_planning_gathers_its_own_inputs_with_no_rendezvous_to_lose():
    """The survey/recall join is gone, and must not come back by accident.

    It was two roles and a barrier around work the drafting agent already does
    with its own subagents, so the engine was never orchestrating the breadth —
    only the two processes. What the barrier did add was a way to lose: sb-62
    halted holding one of two arms, for want of an input the surveying agent was
    still producing.
    """
    planner = named(HANDLERS, "draft-plan")
    assert planner["subscribes"] == ["issue.fetched", "plan.rejected"]

    for gone in ("survey-codebase", "recall-vault", "join-plan-inputs"):
        assert not [h for h in HANDLERS if h["name"] == gone], (
            f"{gone} is back; planning inputs must not be a rendezvous again"
        )

    # Nothing may join on the planning inputs by any name. Asserting on the
    # handler names alone would let the same barrier return as `join-plan-start`.
    for handler in HANDLERS:
        args = handler.get("args", [])
        if not any(arg in {"join-terminal", "join_terminal"} for arg in args):
            continue
        arms = args[args.index("--arms") + 1] if "--arms" in args else ""
        assert "codebase.surveyed" not in arms and "vault.recalled" not in arms, (
            f"{handler['name']} rebuilds the planning rendezvous"
        )


def test_the_plan_audit_is_a_second_opinion_from_a_different_runner():
    """An auditor sharing the drafter's model shares its blind spots.

    The whole value of the pass is that the thing judging the plan is not the
    thing that wrote it, so a plan cannot be approved by the reasoning that
    produced it.
    """
    from signalbox.agent import runner_for

    auditor = named(HANDLERS, "audit-plan")
    assert auditor["subscribes"] == ["plan.verified"]
    assert "plan.audited" in auditor["publishes"]
    assert runner_for("audit", {}) != runner_for("plan", {})

    # The invariant check runs first: a malformed plan is not a thing to put to
    # a vote, and disjointness is what licenses parallel shards at all.
    verified = named(HANDLERS, "route-plan-verified")
    assert verified["subscribes"] == ["plan.checked"]
    assert verified["publishes"] == ["plan.verified"]


def test_only_an_approved_audit_reaches_plan_accepted():
    """The auditor renders a verdict; it never performs the transition itself."""
    accepting = [h for h in HANDLERS if "plan.accepted" in h.get("publishes", [])]
    assert [h["name"] for h in accepting] == ["route-plan-approved"]
    assert named(HANDLERS, "route-plan-approved")["subscribes"] == ["plan.audited"]

    plan = {"run_id": "sb-62", "attempt": 1, "stages": [{"stage_id": "s1"}]}

    approved = route("route-plan-approved", {**plan, "verdict": "approved"})
    assert approved == {**plan, "verdict": "approved"}
    assert route("route-plan-approved", {**plan, "verdict": "changes_requested"}) is None

    # A verdict outside the vocabulary must become an event rather than leave the
    # run holding a verified plan nobody ever accepted.
    for stray in ("looks fine", "APPROVED", ""):
        assert route("route-plan-approved", {**plan, "verdict": stray}) is None
        assert route("route-audit-invalid", {**plan, "verdict": stray}) is not None
    assert route("route-audit-invalid", {**plan, "verdict": "approved"}) is None


def test_both_plan_loops_spend_one_shared_attempt_counter():
    """Two feedback edges reach draft-plan, and they must not each get three.

    `attempt` is carried identity and incremented by check-plan, so an audit
    rejection and an invariant rejection draw down the same budget. Separate
    counters would let a plan cycle six times.
    """
    objected = {"run_id": "sb-62", "verdict": "changes_requested", "attempt": 2}
    assert route("route-audit-changes", objected) == objected
    assert route("route-audit-exhausted", objected) is None

    spent = {**objected, "attempt": 3}
    assert route("route-audit-changes", spent) is None
    halted = route("route-audit-exhausted", spent)
    assert halted == {**spent, "reason": "the plan audit never cleared its objections"}

    rejecting = {h["name"] for h in HANDLERS if "plan.rejected" in h.get("publishes", [])}
    assert rejecting == {"route-plan-retry", "route-audit-changes"}
    assert named(HANDLERS, "draft-plan")["subscribes"][-1] == "plan.rejected"


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


def acts_that_can_refuse() -> dict[str, str]:
    """Topology node -> command, derived from acts.py's real dispatch and returns."""
    source = (ROOT / "src" / "signalbox" / "acts.py").read_text()
    tree = ast.parse(source)
    functions = {
        node.name: node
        for node in tree.body
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
    }
    main = functions["main"]
    dispatch: dict[str, str] = {}
    for node in ast.walk(main):
        if not isinstance(node, ast.Dict):
            continue
        for key, value in zip(node.keys, node.values):
            if (
                isinstance(key, ast.Constant)
                and isinstance(key.value, str)
                and isinstance(value, ast.Name)
                and value.id in functions
            ):
                dispatch[key.value] = value.id

    refusing_commands = set()
    for command, function_name in dispatch.items():
        for node in ast.walk(functions[function_name]):
            if not isinstance(node, ast.Dict):
                continue
            fields = {
                key.value: value
                for key, value in zip(node.keys, node.values)
                if isinstance(key, ast.Constant) and isinstance(key.value, str)
            }
            ok = fields.get("ok")
            if isinstance(ok, ast.Constant) and ok.value is False:
                refusing_commands.add(command)
                break

    nodes: dict[str, str] = {}
    for handler in HANDLERS:
        args = handler.get("args", [])
        for command in refusing_commands:
            if "signalbox" in args and command in args[args.index("signalbox") + 1 :]:
                nodes[handler["name"]] = command
    assert set(nodes.values()) == refusing_commands
    return nodes


def test_every_refusing_act_routes_one_identity_bearing_attempt_by_its_outcome():
    """A refusal is data, so only an `.ok` router may announce act success.

    The set is deliberately derived from acts.py and the topology: enumerating
    today's seams would pass while the next act was already wired incorrectly.
    `rehydrate` is excluded because it raises PendingMissing instead of returning
    `ok: false`, so rehydrate-pr correctly retains its `-e` edge. `run-suite` is
    the other deliberate exception: red is `ok: false` but must reach assess and
    become `block`, so its transition routers select on `.errored`, not `.ok`.
    """
    refusing = acts_that_can_refuse()
    assert "run-suite" in refusing

    rehydrate = named(HANDLERS, "rehydrate-pr")
    assert rehydrate["args"][rehydrate["args"].index("-e") + 1] == "checks.unknown-pr"

    identity = {"run_id": "sb-66", "stage_id": "s3-verify", "shard_id": "s3-invariants"}
    for node_name in sorted(set(refusing) - {"run-suite"}):
        act = named(HANDLERS, node_name)
        attempts = [
            topic for topic in act["publishes"]
            if topic.endswith("-attempted") or topic == "merge.attempted"
        ]
        assert len(attempts) == 1, f"{node_name} must publish one attempt"
        attempted = attempts[0]
        routers = [h for h in HANDLERS if h.get("subscribes") == [attempted]]
        assert len(routers) == 2, f"{node_name} must have exactly two outcome routers"

        selected_routers = {}
        for ok in (True, False):
            envelope = {**identity, "ok": ok}
            matches = {
                router["name"]: route(router["name"], envelope)
                for router in routers
            }
            selected = [
                name for name, output in matches.items() if output is not None
            ]
            assert len(selected) == 1, (
                f"{node_name} routers are not exclusive and exhaustive for ok={ok}"
            )
            selected_routers[ok] = named(HANDLERS, selected[0])
            output = matches[selected[0]]
            assert output is not None
            assert {key: output[key] for key in envelope} == envelope
            assert set(output) - set(envelope) <= {"stranded_topic"}
            assert identity.items() <= matches[selected[0]].items()

        success = selected_routers[True]
        failure = selected_routers[False]
        assert success["name"] != failure["name"], (
            f"{node_name}'s refusal selected its success router"
        )
        success_topics = set(success["publishes"])
        failure_topics = set(failure["publishes"])
        assert success_topics.isdisjoint(failure_topics)
        assert any(
            outcome in topic
            for topic in failure_topics
            for outcome in ("failed", "conflicted", "refused")
        ), f"{node_name}'s false router does not publish a failure topic"
        assert not success_topics.intersection(act["publishes"])
        assert all(
            not success_topics.intersection(handler.get("publishes", []))
            for handler in HANDLERS
            if handler["name"] != success["name"]
        ), f"{node_name}'s success topic bypasses its outcome router"


@pytest.mark.parametrize(
    "payload,matched",
    [
        ({"errored": True}, "route-suite-errored"),
        ({"errored": False}, "route-suite-ran"),
        ({}, "route-suite-ran"),
    ],
)
def test_suite_outcome_routers_are_exclusive_and_exhaustive(payload, matched):
    """Suite invocation errors halt; red, green, and no-suite all reach assess."""
    envelope = {
        "run_id": "sb-66",
        "stage_id": "s3-verify",
        "shard_id": "s3-invariants",
        **payload,
    }
    routers = ("route-suite-ran", "route-suite-errored")
    outputs = {name: route(name, envelope) for name in routers}
    assert [name for name, output in outputs.items() if output is not None] == [matched]
    assert outputs[matched] == envelope


def test_suite_routes_reach_a_human_or_the_promotion_gate():
    errored = named(HANDLERS, "route-suite-error-halted")
    assert errored["subscribes"] == ["suite.errored"]
    assert "run.halted" in errored["publishes"]
    assert "suite.errored" in named(SINKS, "notify")["subscribes"]
    assert named(HANDLERS, "assess")["subscribes"] == ["suite.ran"]


@pytest.mark.parametrize(
    "payload,matched",
    [
        ({"ok": True, "rebased_onto_sha": "a" * 40, "conflicts": []}, "ok"),
        ({"ok": False, "rebased_onto_sha": "b" * 40, "conflicts": ["src/x.py"]}, "conflict"),
        ({"ok": "yes", "conflicts": []}, "invalid"),
        ({"conflicts": []}, "invalid"),
    ],
)
def test_rebase_verdict_routers_are_exclusive_when_executed(payload, matched):
    outputs = {
        "ok": route("route-rebase-ok", payload),
        "conflict": route("route-rebase-conflict", payload),
        "invalid": route("route-rebase-invalid", payload),
    }
    assert [name for name, output in outputs.items() if output is not None] == [matched]
    output = outputs[matched]
    assert output is not None
    assert {key: output[key] for key in payload} == payload
    expected_topic = {
        "conflict": "branch.rebase-conflicted",
        "invalid": "branch.rebase-invalid-verdict",
    }.get(matched)
    if expected_topic is None:
        assert output == payload
    else:
        assert output == {**payload, "stranded_topic": expected_topic}


def checked_stage_plan(run_id: str = "sb-59") -> dict:
    """Build the exact stamped-stage/raw-cursor shape check_plan produces."""
    from signalbox.plan import check_plan

    plan = {
        "run_id": run_id,
        "repo": "rrrodzilla/signalbox",
        "issue": 59,
        "title": "Replace the global stage cursor",
        "base_sha": "0b4a37d",
        "base_branch": "main",
        "stages": [
            {
                "stage_id": f"s{index + 1}",
                "shards": [{
                    "shard_id": f"shard-{index + 1}",
                    "files": [f"stage-{index + 1}.txt"],
                    "intent": f"implement stage {index + 1}",
                }],
            }
            for index in range(3)
        ],
    }
    checked = check_plan(plan)
    assert checked["ok"] is True
    return checked


def test_plan_acceptance_opens_this_runs_first_stage():
    accepted = checked_stage_plan()
    opened = route("open-first-stage", accepted)
    assert opened == accepted["stages"][0]
    assert opened["stage_index"] == 0


def test_stage_merge_advances_from_the_event_carried_index():
    accepted = checked_stage_plan(run_id="sb-99")
    merged = {**accepted["stages"][0], "stage_id": "stale-name-from-before-restart"}
    opened = route("guard-stages-advance", merged)
    assert opened == accepted["stages"][1]
    assert opened["run_id"] == "sb-99"
    assert opened["stage_index"] == 1
    assert opened["stage_count"] == 3
    assert opened["stages"] == merged["stages"]
    assert route("guard-stages-exhaust", merged) is None


def test_replayed_last_stage_merge_exhausts_with_identity():
    merged = checked_stage_plan()["stages"][2]
    assert route("guard-stages-advance", merged) is None
    assert route("guard-stages-exhaust", merged) == merged


def test_reopening_a_conflicted_stage_does_not_move_the_stage_cursor():
    """A conflict retry keeps its stage_index and only re-enters the splitter."""
    accepted = checked_stage_plan()
    conflict = accepted["stages"][0]
    splitter = named(HANDLERS, "split-shards")
    assert "stage.conflicted" in splitter["subscribes"]
    for router in ("guard-stages-advance", "guard-stages-exhaust"):
        assert "stage.conflicted" not in named(HANDLERS, router)["subscribes"]

    first_merge = {**conflict, "conflict_round": 0}
    reopened_merge = {**conflict, "conflict_round": 1}
    assert route("guard-stages-advance", first_merge) == accepted["stages"][1]
    assert route("guard-stages-advance", reopened_merge) == accepted["stages"][1]


@pytest.mark.parametrize("stage_index, advances", [(0, True), (1, True), (2, False)])
def test_stage_depth_guard_is_exclusive_on_both_sides(stage_index, advances):
    merged = checked_stage_plan()["stages"][stage_index]
    outputs = [
        route("guard-stages-advance", merged),
        route("guard-stages-exhaust", merged),
    ]
    assert sum(output is not None for output in outputs) == 1
    assert (outputs[0] is not None) is advances


def test_missing_stage_cursor_neither_advances_nor_falsely_exhausts():
    raw_stage = checked_stage_plan()["stages"][0]["stages"][1]
    assert route("guard-stages-advance", raw_stage) is None
    assert route("guard-stages-exhaust", raw_stage) is None


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


def test_a_run_level_invocation_cannot_match_a_shard_scoped_entry():
    """Issue #84: prevent the run-level sb-69 invocation mislabeling."""
    matcher = PAGE_TEXT[
        PAGE_TEXT.index("function invocationFor") : PAGE_TEXT.index(
            "function isProvenance"
        )
    ]
    assert 'if (entry[k] === undefined) continue;' in matcher
    scoped = '(k === "stage_id" || k === "shard_id")'
    reject = 'invocation[k] === undefined) { conflict = true; break; }'
    skip = 'if (invocation[k] === undefined) continue;'
    assert scoped in matcher, "stage and shard scope must be entry-side constraints"
    assert reject in matcher, "a coarser invocation must conflict with a scoped entry"
    assert matcher.index(scoped) < matcher.index(reject) < matcher.index(skip), (
        "missing invocation scope must reject before the generic missing-key skip"
    )


def test_a_topic_producer_wins_when_two_invocations_share_a_run():
    """Issue #98: plan.audited must resolve to its audit invocation."""
    matcher = PAGE_TEXT[
        PAGE_TEXT.index("function invocationFor") : PAGE_TEXT.index(
            "function isProvenance"
        )
    ]
    preference = "const produces = invocation.produces === entry.type;"
    selection = "(produces && !bestProduces)"
    assert preference in matcher
    assert selection in matcher
    assert matcher.index(preference) < matcher.index(selection)


def test_recorded_provenance_keeps_the_topic_an_invocation_produces():
    """Issue #98: the client must retain the server's producer discriminator."""
    recorder = PAGE_TEXT[
        PAGE_TEXT.index("function recordProvenance") : PAGE_TEXT.index(
            "let unattributed"
        )
    ]
    assert "produces: p.produces" in recorder


def test_an_equal_score_provenance_tie_yields_no_badge():
    """Issue #98: ambiguous provenance must never depend on arrival order."""
    matcher = PAGE_TEXT[
        PAGE_TEXT.index("function invocationFor") : PAGE_TEXT.index(
            "function isProvenance"
        )
    ]
    tie = "produces === bestProduces && score === bestScore"
    assert tie in matcher
    assert "tied = true;" in matcher
    assert matcher.index(tie) < matcher.index("return tied ? null : best;")


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


def test_the_page_replays_history_before_attaching_each_live_stream():
    """Reload must rebuild the board before opening the overlap-prone live tail."""
    attach = PAGE_TEXT[
        PAGE_TEXT.index("async function attachStream") : PAGE_TEXT.index(
            "for (const url of streamUrls())"
        )
    ]
    assert 'new URL("/history", location.origin)' in attach
    assert 'historyUrl.searchParams.set("stream", parsed.port)' in attach
    assert attach.index("await fetch(historyUrl") < attach.index("new EventSource(url)")
    assert attach.index("handleMessage(msg, url, true)") < attach.index(
        "new EventSource(url)"
    )


def test_replay_and_live_events_share_filters_and_overlap_deduplication():
    """Backfill may not bypass the live heartbeat/provenance/attribution rules."""
    handler = PAGE_TEXT[
        PAGE_TEXT.index("function handleMessage") : PAGE_TEXT.index(
            "async function attachStream"
        )
    ]
    assert "HEARTBEAT.has(msg.type)" in handler
    assert handler.index("if (isProvenance(msg))") < handler.index(
        "if (isAttributed(msg))"
    )

    attach = PAGE_TEXT[
        PAGE_TEXT.index("async function attachStream") : PAGE_TEXT.index(
            "for (const url of streamUrls())"
        )
    ]
    assert "replayIds.has(id)" in attach, "stored event ids must deduplicate overlap"
    assert "msg?.timestamp <= lastReplayTimestamp" in attach
    assert "replayKeys.has(replayKey(msg))" in attach, (
        "id-less SSE messages need a bounded replay-overlap guard"
    )


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


def _join_keys(handler: dict) -> list[str]:
    """The fields a join-terminal handler rendezvouses on."""
    args = handler["args"]
    return [args[i + 1] for i, arg in enumerate(args) if arg == "--key"]


def joins() -> list[dict]:
    return [h for h in HANDLERS if "join-terminal" in h.get("args", [])]


def test_every_rendezvous_is_run_scoped():
    """The invariant that licenses concurrent runs.

    A join buckets by the values of its keys. Any key that is unique only within
    a plan — `stage_id`, `shard_id` — puts two concurrent runs in one bucket:
    the join fires on whichever count armed it first, publishes a summary mixing
    both runs' items, and drops the rest as late arrivals. That is silent
    cross-run corruption, not a stall, so it is worth an invariant rather than a
    convention.

    `run_id` is the only globally unique identity signalbox mints, so every join
    must include it. Adding a join without it fails here rather than in
    production the first time two runs overlap.
    """
    assert joins(), "no joins found — the extractor is looking in the wrong place"
    for handler in joins():
        keys = _join_keys(handler)
        assert keys, f"{handler['name']} joins on nothing"
        assert "run_id" in keys, (
            f"{handler['name']} rendezvouses on {keys}, which is not run-scoped; "
            "two concurrent runs would share a bucket"
        )


def test_the_stage_join_is_keyed_on_the_stage_within_the_run():
    """Run-scoping must not flatten the stage join into a run join.

    `run_id` alone would rendezvous every stage of a run in one bucket, so the
    first stage to reach its shard_count would close using another stage's
    shards. Both halves of the key are load-bearing.
    """
    keys = _join_keys(named(HANDLERS, "join-stage"))
    assert keys == ["run_id", "stage_id"]


def test_no_join_repeats_a_key():
    """A repeated key is a typo that silently widens nothing and reads as intent."""
    for handler in joins():
        keys = _join_keys(handler)
        assert len(keys) == len(set(keys)), f"{handler['name']} repeats a join key"
