"""Acts report outcomes as data. None of them decides what happens next."""

from __future__ import annotations

import json

from signalbox.acts import map_ci_findings, pr_state_is_merged, stage_files, suite_command
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


def _merge_result(tmp_path, monkeypatch, responses):
    from signalbox import acts

    monkeypatch.setenv("SIGNALBOX_STATE", str(tmp_path))
    root = tmp_path / "worktrees" / "sb-65"
    root.mkdir(parents=True)
    calls = []

    def fake_run(cmd, cwd=None, timeout=120):
        calls.append((cmd, cwd, timeout))
        return responses.pop(0)

    monkeypatch.setattr(acts, "_run", fake_run)
    return acts.merge_pr({"run_id": "sb-65", "pr": 65}), calls


def test_merge_pr_reports_true_when_the_merge_lands_and_verifies(tmp_path, monkeypatch):
    """sb-65 landed, so the observed PR state must make ok true."""
    result, calls = _merge_result(
        tmp_path,
        monkeypatch,
        [
            (0, "", ""),
            (0, '{"state":"MERGED","mergedAt":"2026-07-29T00:00:00Z"}', ""),
            (0, "", ""),
        ],
    )
    assert result["ok"] is True
    assert calls[0][0] == ["gh", "pr", "merge", "65", "--squash"]
    assert calls[1][0] == ["gh", "pr", "view", "65", "--json", "state,mergedAt"]
    assert calls[2][0][-1].endswith("/signalbox/run-sb-65")
    assert all(call[1] == str(tmp_path / "worktrees" / "sb-65") for call in calls)


def test_merge_pr_reports_false_when_the_merge_does_not_land(tmp_path, monkeypatch):
    """Unlike sb-65, a rejected merge must remain false and retain gh's error."""
    result, calls = _merge_result(
        tmp_path,
        monkeypatch,
        [
            (1, "", "merge blocked by checks"),
            (0, '{"state":"OPEN","mergedAt":null}', ""),
        ],
    )
    assert result["ok"] is False
    assert result["error"] == "merge blocked by checks"
    assert len(calls) == 2


def test_merge_pr_trusts_merged_state_after_local_cleanup_error(tmp_path, monkeypatch):
    """sb-65 landed despite gh's worktree checkout failure, so ok must be true."""
    result, calls = _merge_result(
        tmp_path,
        monkeypatch,
        [
            (1, "", "fatal: branch is already checked out"),
            (0, '{"state":"MERGED","mergedAt":"2026-07-29T00:00:00Z"}', ""),
            (0, "", ""),
        ],
    )
    assert result["ok"] is True
    assert "error" not in result
    assert len(calls) == 3


def test_merge_pr_warns_when_remote_ref_survives_a_verified_merge(tmp_path, monkeypatch):
    """sb-65's surviving origin ref is cleanup trouble, not a failed merge."""
    result, _ = _merge_result(
        tmp_path,
        monkeypatch,
        [
            (0, "", ""),
            (0, '{"state":"MERGED","mergedAt":"2026-07-29T00:00:00Z"}', ""),
            (1, "", "ref deletion denied"),
        ],
    )
    assert result["ok"] is True
    assert result["warning"] == "ref deletion denied"


def test_pr_state_is_merged_judges_raw_json_without_a_network():
    assert pr_state_is_merged(
        '{"state":"MERGED","mergedAt":"2026-07-29T00:00:00Z"}'
    ) is True
    assert pr_state_is_merged('{"state":"OPEN","mergedAt":null}') is False
    assert pr_state_is_merged('{"state":"MERGED","mergedAt":null}') is False
    assert pr_state_is_merged("not json") is False
    assert pr_state_is_merged("[]") is False


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
    assert pending_path("shard", {"run_id": "r1"}).name == "shard-unknown.json"


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


def test_a_uv_managed_project_is_reached_through_its_manager(tmp_path):
    """The defect this prevents: signalbox could not detect its own suite.

    102 tests live behind `uv run pytest`; bare `pytest` is on no PATH here. The
    old check asked whether the binary existed, answered no, and published
    "no suite detected" — so the assessor refused to clear the gate for a run
    whose suite never ran, and the repository became silently ungateable.
    """
    (tmp_path / "pyproject.toml").write_text("[project]\nname = 'x'\n")
    assert suite_command(tmp_path) == ["uv", "run", "pytest", "-q"]


def test_detection_falls_through_to_a_marker_whose_runner_exists(tmp_path, monkeypatch):
    import shutil as shutil_module

    from signalbox import acts

    (tmp_path / "pyproject.toml").write_text("")
    (tmp_path / "package.json").write_text("{}")
    # Neither Python runner installed; the JS one is.
    monkeypatch.setattr(
        acts.shutil, "which", lambda name: None if name in {"uv", "pytest"} else "/usr/bin/" + name
    )
    assert suite_command(tmp_path) == ["pnpm", "test"]
    assert shutil_module.which  # the real module is untouched


def test_a_marker_with_no_reachable_runner_is_still_none(tmp_path, monkeypatch):
    from signalbox import acts

    (tmp_path / "Cargo.toml").write_text("")
    monkeypatch.setattr(acts.shutil, "which", lambda name: None)
    assert suite_command(tmp_path) is None


def test_every_marker_offers_more_than_one_runner():
    """A single hard-coded runner per ecosystem is what caused the defect."""
    from signalbox.acts import SUITE_COMMANDS

    for marker, candidates in SUITE_COMMANDS:
        assert len(candidates) >= 2, f"{marker} has no fallback runner"
