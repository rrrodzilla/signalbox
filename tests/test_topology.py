"""Architectural invariants of the topology itself.

These are the Gate 2 review questions turned into assertions, because the
failure they catch is silent: a misrouted or unobserved event produces no error,
just a run that quietly does less than it should.
"""

from __future__ import annotations

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
RAW = {"http.request", "exec.output"}


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


def test_every_pending_marker_has_something_that_clears_it():
    """The reaper turns silence into an event; something must end the silence.

    Without a clearer, every marker eventually ages past the stale threshold and
    a successful shard is reported as `shard.silent`. Both of demo-3's shards
    were reported silent nineteen minutes after being merged.
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


def test_the_join_count_a_run_terminates_on_is_an_identity_key():
    """`join-run` waits on stage_count, so stage_count must be carried, not
    reconstructed. It was carried into shard.opened and lost at the agent's
    emission, which stalled every run after its final stage merged."""
    from signalbox.identity import CARRIED_KEYS

    joiner = named(HANDLERS, "join-run")
    count_field = joiner["args"][joiner["args"].index("--count-field") + 1]
    assert count_field in CARRIED_KEYS
