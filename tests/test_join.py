"""A stage must close on every outcome, including the ones nobody wants."""

from __future__ import annotations

import asyncio

import pytest

from signalbox.primitives.join_terminal import (
    Joiner,
    Pending,
    default_subscriptions,
    expected_count,
    summarise,
)
from signalbox.primitives.split_notes import note_events
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
