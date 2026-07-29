"""The invariants that license the topology's concurrency."""

from __future__ import annotations

from signalbox.plan import check_plan, duplicate_ids, overlapping_files, shard_events


def _shard(shard_id: str, files: list[str], intent: str = "do a thing") -> dict:
    return {"shard_id": shard_id, "files": files, "intent": intent}


def _plan(**overrides) -> dict:
    base = {
        "run_id": "r1",
        "repo": "acme/widget",
        "issue": 7,
        "base_sha": "abc123",
        "stages": [
            {
                "stage_id": "s1",
                "shards": [_shard("a", ["src/a.py"]), _shard("b", ["src/b.py"])],
            }
        ],
    }
    base.update(overrides)
    return base


def test_disjoint_stage_is_accepted():
    result = check_plan(_plan())
    assert result["ok"] is True
    assert result["violations"] == []


def test_overlapping_shards_in_a_stage_are_rejected():
    plan = _plan(
        stages=[
            {
                "stage_id": "s1",
                "shards": [_shard("a", ["src/x.py"]), _shard("b", ["src/x.py"])],
            }
        ]
    )
    result = check_plan(plan)
    assert result["ok"] is False
    assert any("src/x.py" in v and "disjoint" in v for v in result["violations"])


def test_same_file_in_different_stages_is_fine():
    """Stages are sequential, so they may revisit a file. Only shards must be disjoint."""
    plan = _plan(
        stages=[
            {"stage_id": "s1", "shards": [_shard("a", ["src/x.py"])]},
            {"stage_id": "s2", "shards": [_shard("b", ["src/x.py"])]},
        ]
    )
    assert check_plan(plan)["ok"] is True


def test_overlapping_files_names_every_claimant():
    stage = {
        "stage_id": "s1",
        "shards": [
            _shard("a", ["src/x.py"]),
            _shard("b", ["src/x.py"]),
            _shard("c", ["src/x.py"]),
        ],
    }
    assert overlapping_files(stage) == {"src/x.py": ["a", "b", "c"]}


def test_empty_plan_is_rejected_not_raised():
    result = check_plan({})
    assert result["ok"] is False
    assert "plan has no stages" in result["violations"]


def test_malformed_plan_is_data():
    result = check_plan({"stages": ["not an object", {"shards": []}]})
    assert result["ok"] is False
    assert any("not an object" in v for v in result["violations"])


def test_shard_without_files_or_intent_is_rejected():
    plan = _plan(stages=[{"stage_id": "s1", "shards": [{"shard_id": "a", "files": []}]}])
    violations = check_plan(plan)["violations"]
    assert any("declares no files" in v for v in violations)
    assert any("has no intent" in v for v in violations)


def test_duplicate_ids_are_reported():
    assert duplicate_ids(["a", "b", "a", "c", "c"]) == ["a", "c"]
    plan = _plan(
        stages=[
            {"stage_id": "s1", "shards": [_shard("dup", ["src/a.py"])]},
            {"stage_id": "s1", "shards": [_shard("dup", ["src/b.py"])]},
        ]
    )
    violations = check_plan(plan)["violations"]
    assert "duplicate stage_id: s1" in violations
    assert "duplicate shard_id: dup" in violations


def test_attempt_increments_so_the_retry_guard_terminates():
    first = check_plan({"stages": []})
    assert first["attempt"] == 1
    second = check_plan(first)
    assert second["attempt"] == 2
    assert check_plan(second)["attempt"] == 3


def test_stages_are_stamped_with_run_identity():
    """stream-runner emits the item, not the envelope, so items must self-describe."""
    result = check_plan(_plan())
    stage = result["stages"][0]
    assert stage["run_id"] == "r1"
    assert stage["repo"] == "acme/widget"
    assert stage["issue"] == 7
    assert stage["base_sha"] == "abc123"


def test_shard_events_carry_declared_scope_and_count():
    stage = check_plan(_plan())["stages"][0]
    events = shard_events(stage, stage)
    assert [e["shard_id"] for e in events] == ["a", "b"]
    assert all(e["shard_count"] == 2 for e in events)
    assert all(e["round"] == 1 for e in events)
    assert events[0]["declared"] == ["src/a.py"]
    assert events[0]["run_id"] == "r1"


def test_shard_events_declared_is_a_copy():
    """The guard reads `declared` off each event; mutating one must not touch the plan."""
    stage = check_plan(_plan())["stages"][0]
    events = shard_events(stage, stage)
    events[0]["declared"].append("src/sneaky.py")
    assert stage["shards"][0]["files"] == ["src/a.py"]


def test_stages_carry_a_stage_count_so_the_run_join_terminates():
    result = check_plan(_plan(stages=[
        {"stage_id": "s1", "shards": [_shard("a", ["src/a.py"])]},
        {"stage_id": "s2", "shards": [_shard("b", ["src/b.py"])]},
    ]))
    assert all(stage["stage_count"] == 2 for stage in result["stages"])
    events = shard_events(result["stages"][0], result["stages"][0])
    assert events[0]["stage_count"] == 2
