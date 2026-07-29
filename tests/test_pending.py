"""The reaper's contract has two halves, and only one of them existed.

A marker turns an agent's silence into an event. Nothing removed the marker when
an agent did speak, so on 2026-07-29 both of demo-3's shards — implemented,
reviewed, approved, and merged — were reported as `shard.silent` nineteen
minutes later.
"""

from __future__ import annotations

from signalbox.acts import clear_pending, reap
from signalbox.dispatch import environment, pending_path
from signalbox.emit import build_body, identity_from_env
from signalbox.identity import CARRIED_KEYS


def _shard(**overrides) -> dict:
    payload = {
        "run_id": "r1",
        "repo": "acme/widget",
        "issue": 7,
        "base_sha": "abc123",
        "stage_id": "s1",
        "shard_id": "a",
        "shard_count": 2,
        "stage_count": 3,
        "round": 1,
        "declared": ["src/a.py"],
    }
    payload.update(overrides)
    return payload


def test_announcing_clears_the_marker(tmp_path, monkeypatch):
    monkeypatch.setenv("SIGNALBOX_STATE", str(tmp_path))
    marker = pending_path("shard", {"shard_id": "a"})
    marker.parent.mkdir(parents=True)
    marker.write_text("{}")
    assert clear_pending("shard", {"shard_id": "a"}) is True
    assert not marker.exists()


def test_clearing_a_marker_that_is_already_gone_is_not_an_error(tmp_path, monkeypatch):
    monkeypatch.setenv("SIGNALBOX_STATE", str(tmp_path))
    assert clear_pending("shard", {"shard_id": "ghost"}) is False


def test_a_cleared_marker_is_never_reaped(tmp_path, monkeypatch):
    """The regression itself: a shard that spoke must not be reported silent."""
    import os
    import time

    monkeypatch.setenv("SIGNALBOX_STATE", str(tmp_path))
    marker = pending_path("shard", {"shard_id": "a"})
    marker.parent.mkdir(parents=True)
    marker.write_text("{}")
    old = time.time() - 3600
    os.utime(marker, (old, old))

    assert reap("shard", 20) != "", "an uncleared stale marker is still reaped"

    marker.write_text("{}")
    os.utime(marker, (old, old))
    clear_pending("shard", {"shard_id": "a"})
    assert reap("shard", 20) == ""


def test_both_join_counts_survive_an_agents_emission():
    """stage_count once died here, and every run stalled after its last merge.

    `join-run` counts `stage.merged` up to `stage_count`. The count reaches that
    join only by passing through the environment, the agent's emit, and `carry`,
    so all three have to know the key.
    """
    env = environment(_shard(), {})
    identity = identity_from_env(env)
    assert identity["stage_count"] == 3
    assert identity["shard_count"] == 2
    assert "stage_count" in CARRIED_KEYS

    body = build_body("shard.submitted", {"outcome": "done"}, env)
    assert body["stage_count"] == 3
    assert body["base_sha"] == "abc123"


def test_an_absent_count_is_omitted_rather_than_sent_as_an_empty_string():
    """A join comparing a count against "" would never terminate either."""
    env = environment({"run_id": "r1"}, {})
    identity = identity_from_env(env)
    assert "stage_count" not in identity
    assert "shard_count" not in identity


def test_the_environment_carries_every_key_the_emit_path_reads():
    from signalbox.emit import _ENV_KEYS

    env = environment(_shard(), {})
    missing = [var for var in _ENV_KEYS.values() if var not in env]
    assert missing == [], f"emit reads variables the dispatcher never sets: {missing}"
