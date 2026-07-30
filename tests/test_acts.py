"""Acts report outcomes as data. None of them decides what happens next."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from signalbox.acts import (
    approve,
    clear_pending,
    clear_session,
    map_ci_findings,
    mark_pending,
    notify,
    prepare_workspace,
    pr_state_is_merged,
    read_session,
    reap,
    record_session,
    source_repo,
    stage_files,
    suite_command,
)
from signalbox.dispatch import environment, pending_path
from signalbox.paths import VaultMissing


def test_approve_replays_projected_identity_to_the_control_url(tmp_path, monkeypatch):
    from signalbox import emit

    monkeypatch.setenv("SIGNALBOX_STATE", str(tmp_path))
    payload = {
        "event": "approval.requested",
        "run_id": "71-1234",
        "repo": "acme/widget",
        "issue": 71,
        "title": "Approval",
        "base_sha": "abc123",
        "base_branch": "main",
        "stage_id": "s1-core",
        "stage_count": 2,
        "extra": "not identity",
    }
    mark_pending("approval", payload)
    posted = []
    monkeypatch.setattr(emit, "control_url", lambda: "http://control.test/emit")
    monkeypatch.setattr(
        emit,
        "post",
        lambda body, url=None: posted.append((body, url)) or 202,
    )

    result = approve("71-1234")

    assert result["ok"] is True
    assert posted == [
        (
            {
                "event": "approval.granted",
                "run_id": "71-1234",
                "repo": "acme/widget",
                "issue": 71,
                "title": "Approval",
                "base_sha": "abc123",
                "base_branch": "main",
                "stage_id": "s1-core",
                "stage_count": 2,
            },
            "http://control.test/emit",
        )
    ]


def test_approve_without_a_marker_is_routed_false_data(tmp_path, monkeypatch):
    monkeypatch.setenv("SIGNALBOX_STATE", str(tmp_path))

    result = approve("71-missing")

    assert result["ok"] is False
    assert result["run_id"] == "71-missing"
    assert "no approval marker" in result["error"]


def test_notify_prints_live_approval_invocation_only_for_approval_requested(capsys):
    notify(
        {
            "decision": "needs_human",
            "run_id": "71-1234",
        }
    )
    assert capsys.readouterr().out.splitlines() == [
        "[signalbox] needs_human: run=71-1234 shard=None",
        "signalbox approve 71-1234",
    ]

    notify({"event": "run.halted", "reason": "blocked", "run_id": "71-1234"})
    assert "signalbox approve" not in capsys.readouterr().out


def test_operator_approval_does_not_widen_agent_events():
    from signalbox.emit import ALLOWED_EVENTS

    assert ALLOWED_EVENTS == frozenset(
        {"shard.file-written", "shard.check-ran", "shard.submitted"}
    )


def _prepare_workspace(tmp_path, monkeypatch, *, existing=False):
    from signalbox import acts

    monkeypatch.setenv("SIGNALBOX_STATE", str(tmp_path))
    monkeypatch.setattr(
        acts,
        "_run",
        lambda cmd, cwd=None, timeout=120: (0, "991a9d06e9d099d897556db56d30632743f536c9", ""),
    )
    monkeypatch.setattr(acts, "install_skills", lambda root: [])
    if existing:
        (tmp_path / "worktrees" / "sb-70").mkdir(parents=True)
    return prepare_workspace(
        {"run_id": "sb-70", "base_branch": "main", "repo_path": str(tmp_path)}
    )


def test_prepare_workspace_preserves_direct_callers_without_a_vault(tmp_path, monkeypatch):
    """Startup owns requiring the vault; direct act callers remain compatible."""
    monkeypatch.delenv("SIGNALBOX_VAULT", raising=False)
    result = _prepare_workspace(tmp_path, monkeypatch)
    assert result["ok"] is True


def test_prepare_workspace_refuses_a_missing_vault_directory(tmp_path, monkeypatch):
    """#70: engine launch must recheck the vault that operator preflight saw."""
    missing = tmp_path / "missing-vault"
    monkeypatch.setenv("SIGNALBOX_VAULT", str(missing))
    with pytest.raises(
        VaultMissing,
        match=f"SIGNALBOX_VAULT is not a directory: {missing}",
    ):
        _prepare_workspace(tmp_path, monkeypatch)


def test_prepare_workspace_accepts_the_engine_environment_vault(tmp_path, monkeypatch):
    """#70: a resolved engine vault closes the preflight-environment gap."""
    vault = tmp_path / "vault"
    vault.mkdir()
    monkeypatch.setenv("SIGNALBOX_VAULT", str(vault))
    result = _prepare_workspace(tmp_path, monkeypatch)
    assert result["ok"] is True


def test_prepare_workspace_resumes_an_existing_run_without_a_vault(tmp_path, monkeypatch):
    """An existing workspace predates this launch-time environment recheck."""
    monkeypatch.delenv("SIGNALBOX_VAULT", raising=False)
    result = _prepare_workspace(tmp_path, monkeypatch, existing=True)
    assert result["ok"] is True


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
    assert pending_path("shard", {"run_id": "r1", "shard_id": "a"}).name == "shard-r1-a.json"
    # A missing half renders "unknown" rather than quietly borrowing the other,
    # so an unaddressable marker is visible instead of colliding with a real one.
    assert pending_path("shard", {"shard_id": "a"}).name == "shard-unknown-a.json"
    assert pending_path("shard", {"run_id": "r1"}).name == "shard-r1-unknown.json"


def test_fixer_session_round_trips_outside_pending(tmp_path, monkeypatch):
    monkeypatch.setenv("SIGNALBOX_STATE", str(tmp_path))

    path = record_session("r1", "s1-fix", "codex", "session-123")

    assert path == tmp_path / "sessions" / "r1" / "session-s1-fix.json"
    assert read_session("r1", "s1-fix") == {
        "runner": "codex",
        "session_id": "session-123",
    }


def test_fixer_sessions_are_isolated_by_run(tmp_path, monkeypatch):
    monkeypatch.setenv("SIGNALBOX_STATE", str(tmp_path))

    record_session("r1", "s1-store", "codex", "session-r1")
    record_session("r2", "s1-store", "claude", "session-r2")

    assert read_session("r1", "s1-store") == {
        "runner": "codex",
        "session_id": "session-r1",
    }
    assert read_session("r2", "s1-store") == {
        "runner": "claude",
        "session_id": "session-r2",
    }


def test_missing_or_unparsable_fixer_session_is_a_cold_start(tmp_path, monkeypatch):
    monkeypatch.setenv("SIGNALBOX_STATE", str(tmp_path))
    assert read_session("r1", "missing") is None

    path = tmp_path / "sessions" / "r1" / "session-broken.json"
    path.parent.mkdir(parents=True)
    path.write_text("{not json")
    assert read_session("r1", "broken") is None

    path.write_text(json.dumps({"runner": "codex"}))
    assert read_session("r1", "broken") is None


def test_clear_session_is_idempotent(tmp_path, monkeypatch):
    monkeypatch.setenv("SIGNALBOX_STATE", str(tmp_path))
    record_session("r1", "s1-fix", "claude", "session-456")

    assert clear_session("r1", "s1-fix") is True
    assert clear_session("r1", "s1-fix") is False
    assert read_session("r1", "s1-fix") is None


def test_submission_clears_pending_but_preserves_session_for_review(
    tmp_path, monkeypatch
):
    monkeypatch.setenv("SIGNALBOX_STATE", str(tmp_path))
    payload = {
        "event": "shard.submitted",
        "run_id": "r1",
        "shard_id": "s1-fix",
    }
    marker = pending_path("shard", payload)
    marker.parent.mkdir(parents=True)
    marker.write_text(json.dumps(payload))
    record_session("r1", "s1-fix", "codex", "session-123")

    assert clear_pending("shard", payload) is True
    assert read_session("r1", "s1-fix") == {
        "runner": "codex",
        "session_id": "session-123",
    }


@pytest.mark.parametrize("event", ["shard.approved", "scope.violated", "pr.merged"])
def test_terminal_event_retires_fixer_session(tmp_path, monkeypatch, event):
    monkeypatch.setenv("SIGNALBOX_STATE", str(tmp_path))
    payload = {"event": event, "run_id": "r1", "shard_id": "s1-fix"}
    record_session("r1", "s1-fix", "codex", "session-123")

    clear_pending("shard", payload)

    assert read_session("r1", "s1-fix") is None


def test_reaping_a_silent_shard_also_retires_its_session(tmp_path, monkeypatch):
    monkeypatch.setenv("SIGNALBOX_STATE", str(tmp_path))
    payload = {"run_id": "r1", "shard_id": "s1-fix"}
    marker = pending_path("shard", payload)
    marker.parent.mkdir(parents=True)
    marker.write_text(json.dumps(payload))
    record_session("r1", "s1-fix", "codex", "session-123")

    assert json.loads(reap("shard", stale_minutes=0))["outcome"] == "silent"
    assert read_session("r1", "s1-fix") is None


def test_a_missing_worktree_raises_rather_than_defaulting(tmp_path, monkeypatch):
    """The bug this prevents: an agent judged the wrong repository, confidently.

    run.built once carried no run_id, so the worktree resolved to
    .../worktrees/unknown, the path did not exist, and the assessor silently
    fell back to the engine's working directory and reviewed that instead.
    """
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


# ── releasing the workspace ──────────────────────────────────────────────────


def test_source_repo_is_the_parent_of_a_dot_git_common_dir():
    assert source_repo("/home/u/code/proj/.git") == Path("/home/u/code/proj")


def test_source_repo_of_a_bare_repository_is_the_common_dir_itself():
    """`--git-common-dir` does not always end in `.git`, and stripping blindly
    would hand `git worktree remove` the parent of a bare repo."""
    assert source_repo("/srv/git/proj.git") == Path("/srv/git/proj.git")


def _release(tmp_path, monkeypatch, responses, *, exists=True):
    from signalbox import acts

    monkeypatch.setenv("SIGNALBOX_STATE", str(tmp_path))
    if exists:
        (tmp_path / "worktrees" / "sb-69").mkdir(parents=True)
    calls = []

    def fake_run(cmd, cwd=None, timeout=120):
        calls.append((cmd, cwd))
        return responses.pop(0)

    monkeypatch.setattr(acts, "_run", fake_run)
    return acts.release_workspace({"run_id": "sb-69"}), calls


def test_release_removes_the_worktree_from_the_repository_that_owns_it(tmp_path, monkeypatch):
    """A worktree cannot remove itself, so the act must run against the source."""
    result, calls = _release(tmp_path, monkeypatch, [
        (0, "/home/u/code/proj/.git", ""),
        (0, "", ""),
        (0, "", ""),
    ])
    assert result["ok"] is True
    assert result["released"] is True
    assert result["branch"] == "signalbox/run-sb-69"

    locate, remove, prune = calls
    assert locate[0][:2] == ["git", "rev-parse"]
    assert locate[1] == str(tmp_path / "worktrees" / "sb-69")
    assert remove[0] == ["git", "worktree", "remove", "--force",
                         str(tmp_path / "worktrees" / "sb-69")]
    assert remove[1] == "/home/u/code/proj"
    assert prune[0] == ["git", "branch", "-D", "signalbox/run-sb-69"]
    assert prune[1] == "/home/u/code/proj"


def test_release_of_an_absent_worktree_is_not_a_failure(tmp_path, monkeypatch):
    """The state being asserted already holds, and git is never called."""
    result, calls = _release(tmp_path, monkeypatch, [], exists=False)
    assert result["ok"] is True
    assert result["released"] is False
    assert calls == []


def test_a_worktree_that_will_not_be_removed_is_a_refusal(tmp_path, monkeypatch):
    result, _ = _release(tmp_path, monkeypatch, [
        (0, "/home/u/code/proj/.git", ""),
        (1, "", "fatal: working trees containing modified files"),
    ])
    assert result["ok"] is False
    assert "modified files" in result["error"]


def test_a_surviving_local_branch_does_not_unrelease_a_removed_worktree(tmp_path, monkeypatch):
    """The worktree is already gone; calling that a failure would be a lie."""
    result, _ = _release(tmp_path, monkeypatch, [
        (0, "/home/u/code/proj/.git", ""),
        (0, "", ""),
        (1, "", "error: branch 'signalbox/run-sb-69' not found"),
    ])
    assert result["ok"] is True
    assert result["released"] is True
    assert "not found" in result["warning"]


def test_release_carries_run_identity_through_to_the_verdict(tmp_path, monkeypatch):
    """The routers select on .ok, but the register still needs to name the run."""
    result, _ = _release(tmp_path, monkeypatch, [
        (0, "/home/u/code/proj/.git", ""),
        (0, "", ""),
        (0, "", ""),
    ])
    assert result["run_id"] == "sb-69"
