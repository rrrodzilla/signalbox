"""The reaper's contract has two halves, and only one of them existed.

A marker turns an agent's silence into an event. Nothing removed the marker when
an agent did speak, so on 2026-07-29 both of demo-3's shards — implemented,
reviewed, approved, and merged — were reported as `shard.silent` nineteen
minutes later.
"""

from __future__ import annotations

import json

import pytest

from signalbox.acts import clear_pending, mark_pending, reap, rehydrate
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
        "session_id": "session-123",
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


def test_a_pr_webhook_round_trip_uses_the_pr_marker(tmp_path, monkeypatch):
    """The sb-76 stall came from naming a PR marker with the run identity."""
    monkeypatch.setenv("SIGNALBOX_STATE", str(tmp_path))
    payload = {
        "run_id": "sb-56",
        "repo": "rrrodzilla/signalbox",
        "sha": "e0a1742",
        "conclusion": "success",
        "check_runs_url": "https://api.github.com/x/check-runs",
        "pr": 57,
    }

    marker = mark_pending("pr", payload)
    assert marker.name == "pr-57.json"
    assert rehydrate("pr", payload) == payload
    assert not marker.exists()


def test_approval_marker_carries_the_full_projected_run_identity(
    tmp_path, monkeypatch
):
    monkeypatch.setenv("SIGNALBOX_STATE", str(tmp_path))
    payload = _shard(
        event="approval.requested",
        title="Repair approval",
        base_branch="release",
        extra="not identity",
    )

    marker = mark_pending("approval", payload)

    assert marker.name == "approval-r1.json"
    assert json.loads(marker.read_text()) == {
        key: payload[key] for key in CARRIED_KEYS if key in payload
    }


def test_a_shard_marker_separates_shards_within_a_run_and_across_runs(tmp_path, monkeypatch):
    """Both halves of the marker's identity, each of which has broken a run.

    sb-76 stalled because a shard marker collapsed onto the enclosing run id, so
    a run's shards shared one marker. The mirror image breaks concurrency: shard
    ids are unique only within a plan, so on shard_id alone two runs that both
    name a shard `s1-tests` share one marker — the second overwrites the first,
    and whichever clears it first leaves the other silent with nothing to reap
    it. The marker has to separate on both.
    """
    monkeypatch.setenv("SIGNALBOX_STATE", str(tmp_path))

    def name(run_id, shard_id):
        return pending_path("shard", {"run_id": run_id, "shard_id": shard_id}).name

    # Within one run: two shards, two markers (sb-76).
    assert name("sb-76", "s1-alpha") != name("sb-76", "s1-beta")
    # Across runs: the same shard id, two markers (concurrency).
    assert name("sb-76", "s1-tests") != name("sb-77", "s1-tests")
    assert name("sb-76", "s1-tests") == "shard-sb-76-s1-tests.json"


def test_a_present_null_pending_key_is_named_unknown():
    assert pending_path("approval", {"run_id": None}).name == "approval-unknown.json"


def test_an_unknown_pending_kind_raises(tmp_path, monkeypatch):
    """The sb-76 stall must not recur through a silently invented marker kind."""
    monkeypatch.setenv("SIGNALBOX_STATE", str(tmp_path))
    with pytest.raises(KeyError):
        pending_path("stage", {"stage_id": "s1"})


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
    assert body["session_id"] == "session-123"


def test_an_absent_count_is_omitted_rather_than_sent_as_an_empty_string():
    """A join comparing a count against "" would never terminate either."""
    env = environment({"run_id": "r1"}, {})
    identity = identity_from_env(env)
    assert "stage_count" not in identity
    assert "shard_count" not in identity


def test_stage_cursor_survives_an_agents_emission():
    stages = [
        {"stage_id": "s1", "shards": [{"shard_id": "a"}]},
        {"stage_id": "s2", "shards": [{"shard_id": "b"}]},
    ]
    env = environment(_shard(stage_index=0, stages=stages), {})

    body = build_body("shard.submitted", {"outcome": "done"}, env)

    assert body["stage_index"] == 0
    assert body["stages"] == stages


def test_malformed_stages_fail_instead_of_becoming_strings():
    with pytest.raises(ValueError):
        identity_from_env({"SIGNALBOX_STAGES": "s1:s2"})


def test_the_environment_carries_every_key_the_emit_path_reads():
    from signalbox.emit import _ENV_KEYS

    env = environment(_shard(), {})
    missing = [var for var in _ENV_KEYS.values() if var not in env]
    assert missing == [], f"emit reads variables the dispatcher never sets: {missing}"


def test_present_null_identity_is_absent_from_the_agent_environment():
    from signalbox.emit import _ENV_KEYS

    payload = {field: None for field in _ENV_KEYS}
    payload.update({"stages": None, "declared": None})
    base = {variable: "stale" for variable in _ENV_KEYS.values()}

    env = environment(payload, base)

    assert all(variable not in env for variable in _ENV_KEYS.values())
    assert json.loads(env["SIGNALBOX_STAGES"]) == []
    assert json.loads(env["SIGNALBOX_DECLARED"]) == []
    assert not ({"None", "null", "True", "False"} & set(env.values()))


# ── concurrency: a marker must name exactly one thing ────────────────────────

# Kinds whose key is assigned by something outside signalbox and is already
# unique across every run. A GitHub PR number is the only one today. Everything
# else is plan-local and must be run-scoped.
GLOBALLY_UNIQUE_KINDS = {"pr"}


def test_every_pending_kind_is_globally_addressable():
    """A marker is how silence gets a name, so it must name one thing.

    Two different waits that render to one filename destroy each other: the
    second overwrites the first, and whichever clears it first leaves the other
    silent with no marker left for the reaper to find. `shard_id` is unique only
    within a plan, so a shard marker is run-scoped; `pr` is GitHub's and is not.
    A new kind fails here unless it makes that choice deliberately.
    """
    from signalbox.dispatch import PENDING_KEYS

    for kind, keys in PENDING_KEYS.items():
        assert isinstance(keys, tuple) and keys, f"{kind} names no key"
        if kind in GLOBALLY_UNIQUE_KINDS:
            continue
        assert "run_id" in keys, (
            f"pending kind {kind!r} keys on {keys}, which is unique only within a "
            "plan; two concurrent runs would share one marker"
        )


def test_the_pr_marker_stays_unscoped_because_github_assigns_it(tmp_path, monkeypatch):
    """Run-scoping the PR marker would break the path that clears it.

    The check-suite webhook recovers run_id by string-trimming the head branch,
    while `pr` arrives as a guaranteed field. Keying on the derived value risks
    a marker that is written under one name and looked for under another, which
    is a false `checks.silent` on a run whose CI actually reported.
    """
    monkeypatch.setenv("SIGNALBOX_STATE", str(tmp_path))
    assert pending_path("pr", {"pr": 94, "run_id": "sb-59"}).name == "pr-94.json"
    assert pending_path("pr", {"pr": 94}).name == "pr-94.json"
