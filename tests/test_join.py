"""A stage must close on every outcome, including the ones nobody wants."""

from __future__ import annotations

import asyncio

import pytest

from signalbox import identity
from signalbox.identity import CARRIED_KEYS, project
from signalbox.primitives.join_terminal import (
    Joiner,
    Pending,
    default_subscriptions,
    expected_count,
    summarise,
)
from signalbox.primitives.split_notes import note_events, publish_events, synced_event
from signalbox.primitives.split_shards import events_for, reopened_shards


class Recorder:
    def __init__(self):
        self.published: list[dict] = []

    async def __call__(self, payload: dict, cause: object) -> None:
        self.published.append(payload)


def _shard(stage="s1", shard="a", outcome="approved", count=2, **extra):
    return {
        "stage_id": stage,
        "shard_id": shard,
        "shard_count": count,
        "run_id": "r1",
        "outcome": outcome,
        **extra,
    }


def _pr_merged(run="r1"):
    return {
        "run_id": run,
        "number": 69,
        "merge_sha": "abc123",
        "merged": True,
    }


def _notes_synced(run="r1"):
    return {
        "run_id": run,
        "expected": 0,
        "received": 0,
        "timed_out": False,
        "results": [],
        "note_count": 0,
    }


def _completion_joiner(recorder, timeout=0):
    return Joiner(
        "run_id",
        None,
        recorder,
        timeout=timeout,
        arms=("pr.merged", "notes.synced"),
    )


def _content_joiner(recorder):
    return Joiner(
        "run_id",
        None,
        recorder,
        timeout=0,
        arms=("survey.completed", "notes.recalled"),
        carry_payloads=True,
    )


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("first_topic", "first_payload", "second_topic", "second_payload"),
    [
        ("pr.merged", _pr_merged(), "notes.synced", _notes_synced()),
        ("notes.synced", _notes_synced(), "pr.merged", _pr_merged()),
    ],
)
async def test_arms_fire_once_when_both_arrive_in_either_order(
    first_topic, first_payload, second_topic, second_payload
):
    recorder = Recorder()
    joiner = _completion_joiner(recorder)

    await joiner.accept(first_payload, topic=first_topic)
    assert recorder.published == []
    await joiner.accept(second_payload, topic=second_topic)

    assert len(recorder.published) == 1
    assert recorder.published[0]["expected"] == 2
    assert recorder.published[0]["received"] == 2


@pytest.mark.asyncio
async def test_arms_can_carry_each_full_payload_keyed_by_topic():
    recorder = Recorder()
    joiner = _content_joiner(recorder)
    survey = {
        "run_id": "r1",
        "issue": 89,
        "paths": ["src/signalbox/primitives/join_terminal.py"],
        "subsystems": ["topology", "vault"],
        "conventions": ["events carry identity"],
        "uncertainty": ["note precedence is not yet specified"],
    }
    recalled = {
        "run_id": "r1",
        "notes": [
            {
                "note": "architecture",
                "content": "Survey and recall rendezvous before planning.",
            }
        ],
    }

    await joiner.accept(survey, topic="survey.completed")
    await joiner.accept(recalled, topic="notes.recalled")

    joined = recorder.published[0]
    assert joined["payloads"] == {
        "survey.completed": survey,
        "notes.recalled": recalled,
    }
    assert joined["payloads"]["survey.completed"]["paths"] == [
        "src/signalbox/primitives/join_terminal.py"
    ]
    assert joined["payloads"]["survey.completed"]["subsystems"] == ["topology", "vault"]
    assert joined["payloads"]["survey.completed"]["conventions"] == ["events carry identity"]
    assert joined["payloads"]["survey.completed"]["uncertainty"] == [
        "note precedence is not yet specified"
    ]
    assert joined["payloads"]["notes.recalled"]["notes"][0]["content"] == (
        "Survey and recall rendezvous before planning."
    )


@pytest.mark.asyncio
async def test_carrying_arm_payloads_still_merges_identity_from_first_arrival():
    recorder = Recorder()
    joiner = _content_joiner(recorder)
    survey = {"run_id": "r1", "issue": 89, "title": "Read the vault"}

    await joiner.accept(survey, topic="survey.completed")
    await joiner.accept({"run_id": "r1", "notes": []}, topic="notes.recalled")

    joined = recorder.published[0]
    assert joined["run_id"] == "r1"
    assert joined["issue"] == 89
    assert joined["title"] == "Read the vault"


@pytest.mark.asyncio
async def test_default_arms_output_is_unchanged_when_payload_carrying_is_off():
    recorder = Recorder()
    joiner = _completion_joiner(recorder)

    await joiner.accept(_pr_merged(), topic="pr.merged")
    await joiner.accept(_notes_synced(), topic="notes.synced")

    assert recorder.published[0] == {
        "run_id": "r1",
        "expected": 2,
        "received": 2,
        "timed_out": False,
        "results": [
            {},
            {},
        ],
    }


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("topic", "payload"),
    [("pr.merged", _pr_merged()), ("notes.synced", _notes_synced())],
)
async def test_two_arrivals_on_one_arm_never_complete_the_join(topic, payload):
    """A doubled zero-note terminal must not substitute for a merge."""
    recorder = Recorder()
    joiner = _completion_joiner(recorder)

    await joiner.accept(payload, topic=topic)
    await joiner.accept(payload, topic=topic)

    assert recorder.published == []
    assert len(joiner.pending[("r1",)].results) == 1


@pytest.mark.asyncio
async def test_duplicate_after_arms_join_closed_is_dropped():
    recorder = Recorder()
    joiner = _completion_joiner(recorder)
    await joiner.accept(_pr_merged(), topic="pr.merged")
    await joiner.accept(_notes_synced(), topic="notes.synced")

    await joiner.accept(_notes_synced(), topic="notes.synced")

    assert len(recorder.published) == 1


@pytest.mark.asyncio
async def test_keyless_arm_arrival_is_ignored():
    recorder = Recorder()
    joiner = _completion_joiner(recorder)

    await joiner.accept({"merged": True}, topic="pr.merged")

    assert recorder.published == []
    assert joiner.pending == {}


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("topic", "payload"),
    [("pr.merged", _pr_merged()), ("notes.synced", _notes_synced())],
)
async def test_first_arrival_on_either_arm_arms_the_timeout(topic, payload):
    """A first arrival arms the timeout and publishes a timed-out partial join."""
    recorder = Recorder()
    joiner = _completion_joiner(recorder, timeout=0.02)

    await joiner.accept(payload, topic=topic)
    assert joiner.pending[("r1",)].timer is not None
    await asyncio.sleep(0.06)

    assert len(recorder.published) == 1
    assert recorder.published[0]["timed_out"] is True
    assert recorder.published[0]["received"] == 1


@pytest.mark.asyncio
async def test_join_fires_once_the_expected_count_arrives():
    recorder = Recorder()
    joiner = Joiner("stage_id", "shard_count", recorder, timeout=0)

    await joiner.accept(_shard(shard="a"))
    assert recorder.published == []

    await joiner.accept(_shard(shard="b"))
    assert len(recorder.published) == 1
    joined = recorder.published[0]
    assert joined["stage_id"] == "s1"
    assert joined["received"] == 2
    assert joined["timed_out"] is False
    assert [r["shard_id"] for r in joined["results"]] == ["a", "b"]


@pytest.mark.asyncio
async def test_a_stage_closes_even_when_a_shard_never_succeeded():
    """The failure outcomes are exactly why the stage cannot hang."""
    recorder = Recorder()
    joiner = Joiner("stage_id", "shard_count", recorder, timeout=0)
    await joiner.accept(_shard(shard="a", outcome="approved"))
    await joiner.accept(_shard(shard="b", outcome="scope_violation"))
    assert len(recorder.published) == 1
    outcomes = {r["outcome"] for r in recorder.published[0]["results"]}
    assert outcomes == {"approved", "scope_violation"}


@pytest.mark.asyncio
async def test_partial_join_publishes_on_timeout_rather_than_stalling():
    recorder = Recorder()
    joiner = Joiner("stage_id", "shard_count", recorder, timeout=0.05)
    await joiner.accept(_shard(shard="a", count=3))
    await asyncio.sleep(0.15)
    assert len(recorder.published) == 1
    assert recorder.published[0]["timed_out"] is True
    assert recorder.published[0]["received"] == 1
    assert recorder.published[0]["expected"] == 3


@pytest.mark.asyncio
async def test_keys_accumulate_independently():
    recorder = Recorder()
    joiner = Joiner("stage_id", "shard_count", recorder, timeout=0)
    await joiner.accept(_shard(stage="s1", shard="a"))
    await joiner.accept(_shard(stage="s2", shard="x"))
    await joiner.accept(_shard(stage="s2", shard="y"))
    assert len(recorder.published) == 1
    assert recorder.published[0]["stage_id"] == "s2"


@pytest.mark.asyncio
async def test_late_arrival_does_not_reopen_a_closed_stage():
    recorder = Recorder()
    joiner = Joiner("stage_id", "shard_count", recorder, timeout=0)
    await joiner.accept(_shard(shard="a"))
    await joiner.accept(_shard(shard="b"))
    await joiner.accept(_shard(shard="c"))
    assert len(recorder.published) == 1


@pytest.mark.asyncio
async def test_message_without_the_key_is_ignored_not_fatal():
    recorder = Recorder()
    joiner = Joiner("stage_id", "shard_count", recorder, timeout=0)
    await joiner.accept({"shard_id": "orphan"})
    assert recorder.published == []


def test_expected_count_rejects_nonsense():
    assert expected_count({"shard_count": 3}, "shard_count") == 3
    assert expected_count({"shard_count": "3"}, "shard_count") == 3
    assert expected_count({"shard_count": 0}, "shard_count") is None
    assert expected_count({}, "shard_count") is None
    assert expected_count({"shard_count": "many"}, "shard_count") is None


def test_summarise_keeps_declared_scope_for_the_merge_step():
    pending = Pending(expected=1, results=[_shard(declared=["src/a.py"])])
    assert summarise("stage_id", "s1", pending, False)["results"][0]["declared"] == ["src/a.py"]


def test_summarise_carries_every_identity_key_from_the_first_result():
    carried = {key: f"value-{key}" for key in CARRIED_KEYS}
    summary = summarise(
        "join_key",
        "joined",
        Pending(expected=1, results=[carried]),
        False,
    )

    assert all(summary[key] == carried[key] for key in CARRIED_KEYS)


def test_stage_join_preserves_the_plan_cursor_from_its_first_result():
    stages = [
        {"stage_id": "s1", "shards": []},
        {"stage_id": "s2", "shards": []},
    ]
    summary = summarise(
        "stage_id",
        "s1",
        Pending(
            expected=1,
            results=[_shard(stage_index=0, stages=stages)],
        ),
        False,
    )

    assert summary["stage_index"] == 0
    assert summary["stages"] == stages


def test_a_future_carried_key_crosses_the_join_without_changing_its_summary(monkeypatch):
    monkeypatch.setattr(identity, "CARRIED_KEYS", (*CARRIED_KEYS, "sentinel"))
    summary = summarise(
        "stage_id",
        "joined-stage",
        Pending(expected=1, results=[{"stage_id": "identity-stage", "sentinel": "future-value"}]),
        False,
    )

    assert summary["stage_id"] == "identity-stage"
    assert summary["sentinel"] == "future-value"
    assert summary["results"] == [{"stage_id": "identity-stage"}]


def test_join_subscribes_to_every_terminal_shard_outcome():
    subs = default_subscriptions("stage_id")
    assert "shard.approved" in subs
    for failure in ("shard.escalated", "shard.abandoned", "shard.silent", "scope.violated"):
        assert failure in subs, f"a stage would hang on {failure}"


# ── splitters ────────────────────────────────────────────────────────────────


def test_plan_splitter_projection_keeps_the_issue_title():
    """The sb-78 trace exposed the plan splitter as the next title-carrying seam."""
    payload = {"run_id": "sb-78", "title": "Preserve identity through every seam"}

    assert project(payload)["title"] == "Preserve identity through every seam"


def test_split_reopens_only_the_shards_a_conflict_implicated():
    stages = [
        {"stage_id": "s1", "shards": []},
        {"stage_id": "s2", "shards": []},
    ]
    payload = {
        "stage_id": "s1",
        "stage_index": 0,
        "stages": stages,
        "run_id": "r1",
        "conflicts": ["src/b.py"],
        "shards": [
            {"shard_id": "a", "files": ["src/a.py"], "intent": "x"},
            {"shard_id": "b", "files": ["src/b.py"], "intent": "y"},
        ],
    }
    events = reopened_shards(payload)
    assert [e["shard_id"] for e in events] == ["b"]
    assert events[0]["reopened_from"] == "merge_conflict"
    assert events[0]["stage_index"] == 0
    assert events[0]["stages"] == stages


def test_events_for_opens_every_shard_when_there_is_no_conflict():
    stage = {
        "stage_id": "s1",
        "run_id": "r1",
        "shards": [
            {"shard_id": "a", "files": ["src/a.py"], "intent": "x"},
            {"shard_id": "b", "files": ["src/b.py"], "intent": "y"},
        ],
    }
    assert [e["shard_id"] for e in events_for(stage)] == ["a", "b"]


def test_note_events_carry_the_count_so_the_join_terminates():
    events = note_events({"run_id": "r1", "notes": ["arch", "testing", "shards"]})
    assert len(events) == 3
    assert all(e["note_count"] == 3 for e in events)
    assert [e["note"] for e in events] == ["arch", "testing", "shards"]


@pytest.mark.asyncio
async def test_the_pure_layer_returns_a_notes_synced_event_for_an_empty_plan_not_nothing():
    """A zero-note plan once vanished at the splitter and left its run waiting forever."""
    event = synced_event({"run_id": "r1", "note_count": 0, "notes": []})

    assert event is not None


@pytest.mark.asyncio
async def test_an_empty_plan_still_publishes_an_event_so_the_run_reaches_a_terminal():
    """The splitter logged the empty plan but silence gave downstream no terminal fact."""
    recorder = Recorder()

    await publish_events(
        {"run_id": "r1", "note_count": 0, "notes": []},
        "planned-message",
        lambda payload, cause: pytest.fail("an empty plan drafted a note"),
        recorder,
    )

    assert len(recorder.published) == 1


@pytest.mark.asyncio
async def test_the_synthetic_payload_matches_the_join_summary_shape_with_projected_identity():
    """The direct terminal must look like the join result consumers already understand."""
    payload = {"run_id": "r1", "note_count": 0, "notes": []}

    assert synced_event(payload) == {
        "expected": 0,
        "received": 0,
        "timed_out": False,
        "results": [],
        "run_id": "r1",
        "note_count": 0,
    }


def test_a_stage_item_keeps_the_identity_a_stage_actually_has():
    """The record `run.built` carried was a lie, and the assessor believed it.

    This is the real stage.merged payload from run sb-56. The joiner's per-item
    template only looked for shard fields, so a stage produced
    {shard_id: null, round: null, outcome: "unknown", declared: []} — and the
    assessor, which reads this to verify merged work stayed in declared scope,
    could not clear a run that had in fact merged one clean in-scope stage with
    113 tests passing. It sent it to a human. Correctly, on that evidence.
    """
    from signalbox.primitives.join_terminal import summarise_item

    stage_merged = {
        "run_id": "sb-56",
        "stage_id": "s1-poll-checks-fix",
        "files": ["src/signalbox/acts.py", "tests/test_acts.py"],
        "sha": "7cbce1b501d768d277d7862527f7adda0b0f40c2",
        "ok": True,
        "stage_count": 1,
        "results": [
            {
                "shard_id": "s1-poll-checks-fix",
                "outcome": "approved",
                "round": 1,
                "declared": ["src/signalbox/acts.py", "tests/test_acts.py"],
            }
        ],
    }
    item = summarise_item(stage_merged)
    assert item["stage_id"] == "s1-poll-checks-fix"
    assert item["ok"] is True
    assert item["sha"].startswith("7cbce1b")
    assert item["files"] == ["src/signalbox/acts.py", "tests/test_acts.py"]
    # The leaves are what scope verification needs; flattening them lost them.
    assert item["results"][0]["outcome"] == "approved"
    assert item["results"][0]["declared"] == ["src/signalbox/acts.py", "tests/test_acts.py"]


def test_a_shard_item_is_unchanged_by_that():
    from signalbox.primitives.join_terminal import summarise_item

    shard = {"shard_id": "a", "outcome": "approved", "round": 2,
             "declared": ["src/a.py"], "run_id": "r1"}
    item = summarise_item(shard)
    assert item == {"shard_id": "a", "round": 2, "outcome": "approved",
                    "declared": ["src/a.py"]}


def test_a_missing_outcome_is_absent_rather_than_the_word_unknown():
    """"unknown" reads as a verified fact about the item. Absence reads as absence."""
    from signalbox.primitives.join_terminal import summarise_item

    assert "outcome" not in summarise_item({"stage_id": "s1"})


# ── concurrency: a rendezvous must be run-scoped ─────────────────────────────


@pytest.mark.asyncio
async def test_two_runs_sharing_a_stage_id_join_separately():
    """The defect that made concurrent runs unsafe, at the primitive.

    Stage ids are unique within a plan, not across plans, and the plan skill's
    own example names them `s1`/`s2`. Keyed on stage_id alone, two runs' shards
    landed in one bucket: the join fired on whichever shard_count armed it
    first, published a stage.closed mixing both runs' shards, and dropped the
    remainder as late arrivals — so one run merged foreign work and the other
    never closed its stage at all.
    """
    recorder = Recorder()
    joiner = Joiner(("run_id", "stage_id"), "shard_count", recorder, timeout=0)

    # Interleaved on purpose: this is what concurrency actually looks like.
    await joiner.accept(_shard(shard="a", run_id="sb-1"))
    await joiner.accept(_shard(shard="a", run_id="sb-2"))
    assert recorder.published == [], "neither run has both its shards yet"

    await joiner.accept(_shard(shard="b", run_id="sb-1"))
    assert len(recorder.published) == 1
    await joiner.accept(_shard(shard="b", run_id="sb-2"))
    assert len(recorder.published) == 2

    for published, run in zip(recorder.published, ("sb-1", "sb-2")):
        assert published["run_id"] == run
        assert published["stage_id"] == "s1"
        assert published["received"] == 2
        assert published["timed_out"] is False
        # The decisive assertion: no shard from the other run leaked in.
        assert {item["shard_id"] for item in published["results"]} == {"a", "b"}


@pytest.mark.asyncio
async def test_one_run_closing_a_stage_does_not_close_the_other_runs():
    """`closed` is per composite key, or the second run's shards read as late."""
    recorder = Recorder()
    joiner = Joiner(("run_id", "stage_id"), "shard_count", recorder, timeout=0)

    await joiner.accept(_shard(shard="a", run_id="sb-1"))
    await joiner.accept(_shard(shard="b", run_id="sb-1"))
    assert len(recorder.published) == 1

    await joiner.accept(_shard(shard="a", run_id="sb-2"))
    await joiner.accept(_shard(shard="b", run_id="sb-2"))

    assert len(recorder.published) == 2
    assert recorder.published[1]["run_id"] == "sb-2"
    assert recorder.published[1]["received"] == 2


@pytest.mark.asyncio
async def test_a_payload_missing_one_composite_key_is_ignored_not_pooled():
    """A partial key must not become a bucket every partial payload shares."""
    recorder = Recorder()
    joiner = Joiner(("run_id", "stage_id"), "shard_count", recorder, timeout=0)

    await joiner.accept({"stage_id": "s1", "shard_count": 2, "outcome": "approved"})
    await joiner.accept({"run_id": "sb-1", "shard_count": 2, "outcome": "approved"})

    assert recorder.published == []
    assert joiner.pending == {}


def test_a_composite_join_reports_every_key_it_joined_on():
    """Downstream routers read these fields; a joined payload must carry both."""
    from signalbox.primitives.join_terminal import Pending, summarise

    summary = summarise(
        ("run_id", "stage_id"),
        ("sb-1", "s1"),
        Pending(expected=1, results=[]),
        False,
    )
    assert summary["run_id"] == "sb-1"
    assert summary["stage_id"] == "s1"


def test_a_single_key_join_still_takes_a_bare_string():
    """The run-level joins pass one key; composite support must not break them."""
    from signalbox.primitives.join_terminal import as_keys

    assert as_keys("run_id") == ("run_id",)
    assert as_keys(("run_id", "stage_id")) == ("run_id", "stage_id")


def test_the_stage_subscriptions_survive_a_composite_key():
    """Chosen by membership, not equality — on equality the stage join silently
    fell back to the notes subscriptions and would have heard no shard at all."""
    from signalbox.primitives.join_terminal import default_subscriptions

    assert default_subscriptions(("run_id", "stage_id")) == default_subscriptions("stage_id")
    assert "shard.approved" in default_subscriptions(("run_id", "stage_id"))
