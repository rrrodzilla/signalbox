"""Acts report outcomes as data. None of them decides what happens next."""

from __future__ import annotations

import json

from signalbox.acts import map_ci_findings, stage_files, suite_command
from signalbox.dispatch import environment, pending_path


def test_stage_files_is_the_union_of_declared_scopes():
    payload = {
        "results": [
            {"shard_id": "a", "declared": ["src/a.py", "src/shared.py"]},
            {"shard_id": "b", "declared": ["src/b.py"]},
        ]
    }
    assert stage_files(payload) == ["src/a.py", "src/shared.py", "src/b.py"]


def test_stage_files_deduplicates_and_preserves_order():
    payload = {"results": [{"declared": ["a", "b"]}, {"declared": ["b", "c"]}]}
    assert stage_files(payload) == ["a", "b", "c"]


def test_stage_files_of_an_empty_stage_is_empty():
    assert stage_files({}) == []


def test_ci_failure_becomes_review_findings():
    """The fix loop already exists; a red build just has to speak its vocabulary."""
    result = map_ci_findings({"pr": 12, "failed": ["build", "clippy"], "round": 2})
    assert result["verdict"] == "changes_requested"
    assert result["round"] == 2
    assert [f["check"] for f in result["findings"]] == ["build", "clippy"]
    assert all(f["source"] == "ci" for f in result["findings"])


def test_suite_command_is_none_when_the_repo_has_no_suite(tmp_path):
    assert suite_command(tmp_path) is None


def test_dispatch_environment_stamps_unspoofable_identity():
    env = environment(
        {
            "run_id": "r1",
            "shard_id": "a",
            "stage_id": "s1",
            "shard_count": 2,
            "round": 3,
            "declared": ["src/a.py"],
        },
        {"PATH": "/usr/bin"},
    )
    assert env["SIGNALBOX_SHARD_ID"] == "a"
    assert env["SIGNALBOX_ROUND"] == "3"
    assert json.loads(env["SIGNALBOX_DECLARED"]) == ["src/a.py"]
    assert env["PATH"] == "/usr/bin"


def test_dispatch_environment_defaults_round_for_a_first_pass():
    assert environment({"run_id": "r1"}, {})["SIGNALBOX_ROUND"] == "1"


def test_pending_marker_is_named_for_the_shard_the_reaper_will_report():
    assert pending_path("shard", {"shard_id": "a"}).name == "shard-a.json"
    assert pending_path("shard", {"run_id": "r1"}).name == "shard-r1.json"


def test_a_missing_worktree_raises_rather_than_defaulting(tmp_path, monkeypatch):
    """The bug this prevents: an agent judged the wrong repository, confidently.

    run.built once carried no run_id, so the worktree resolved to
    .../worktrees/unknown, the path did not exist, and the assessor silently
    fell back to the engine's working directory and reviewed that instead.
    """
    import pytest

    from signalbox.paths import WorktreeMissing, require_worktree

    monkeypatch.setenv("SIGNALBOX_STATE", str(tmp_path))
    with pytest.raises(WorktreeMissing):
        require_worktree({"run_id": "nope"})


def test_run_suite_distinguishes_no_worktree_from_no_suite(tmp_path, monkeypatch):
    from signalbox.acts import run_suite

    monkeypatch.setenv("SIGNALBOX_STATE", str(tmp_path))
    result = run_suite({"run_id": "nope"})
    assert result["ran"] is False
    assert result["ok"] is False
    assert "no worktree" in result["reason"]
