"""A stage must close on every outcome, including the ones nobody wants."""

from __future__ import annotations

import asyncio

import pytest

from signalbox import identity
from signalbox.identity import CARRIED_KEYS
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


def test_split_reopens_only_the_shards_a_conflict_implicated():
    payload = {
        "stage_id": "s1",
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
