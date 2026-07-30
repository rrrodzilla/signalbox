"""Which model renders which judgment, and which runner does the acting.

These are assertions about intent, not about implementation. A model change is a
behavioural change to the pipeline, so it should not be possible to make one by
accident.
"""

from __future__ import annotations

import json
from pathlib import Path
from types import SimpleNamespace

import pytest

from signalbox import agent, dispatch, emit
from signalbox.agent import (
    ROLE_MODELS,
    ROLE_PRODUCED_TOPICS,
    ROLE_SKILLS,
    model_env_var,
    model_for,
)
from signalbox.dispatch import (
    claude_command,
    claude_resume_command,
    codex_command,
    codex_prompt,
    codex_resume_command,
    model_for as dispatch_model_for,
    runner_for,
)
from signalbox.paths import SKILL_ROOTS, SkillMissing, install_skills, require_skill


def test_every_model_role_declares_the_topic_it_produces():
    assert ROLE_PRODUCED_TOPICS == {
        "plan": "plan.submitted",
        "audit": "plan.audited",
        "review": "review.submitted",
        "assess": "gate.assessed",
        "plan-notes": "notes.planned",
        "write-note": "note.written",
        "implement": "shard.submitted",
        "fix": "shard.submitted",
    }


def test_provenance_body_has_join_fields_and_control_failure_is_nonfatal(
    monkeypatch, capsys
):
    bodies = []
    monkeypatch.setattr(emit, "post", lambda body: bodies.append(body) or 202)
    env = {
        "SIGNALBOX_RUN_ID": "r1",
        "SIGNALBOX_STAGE_ID": "s1",
        "SIGNALBOX_SHARD_ID": "a",
        "SIGNALBOX_ROUND": "2",
    }

    assert (
        emit.post_provenance(
            "review", "claude", "opus", "review.submitted", True, 123, env=env
        )
        == 202
    )
    assert bodies == [
        {
            "role": "review",
            "runner": "claude",
            "model": "opus",
            "produces": "review.submitted",
            "ok": True,
            "duration_ms": 123,
            "run_id": "r1",
            "stage_id": "s1",
            "shard_id": "a",
            "round": 2,
            "event": "model.invoked",
        }
    ]

    monkeypatch.setattr(emit, "post", lambda body: (_ for _ in ()).throw(OSError("down")))
    assert (
        emit.post_provenance(
            "review", "claude", "opus", "review.submitted", False, 456, env=env
        )
        is None
    )
    assert "control endpoint unreachable: down" in capsys.readouterr().err


def test_failed_provenance_body_carries_diagnostic_beside_stamped_identity(
    monkeypatch,
):
    bodies = []
    monkeypatch.setattr(emit, "post", lambda body: bodies.append(body) or 202)
    env = {
        "SIGNALBOX_RUN_ID": "r1",
        "SIGNALBOX_STAGE_ID": "s1",
        "SIGNALBOX_SHARD_ID": "a",
        "SIGNALBOX_ROUND": "2",
    }
    diagnostic = {
        "error": "model process exited with status 17",
        "exit_code": 17,
        "command": ["claude", "-p", "<prompt:123 chars>"],
        "run_id": "caller-cannot-shadow-identity",
    }

    assert (
        emit.post_provenance(
            "review",
            "claude",
            "opus",
            "review.submitted",
            False,
            456,
            diagnostic,
            env=env,
        )
        == 202
    )
    assert bodies == [
        {
            "role": "review",
            "runner": "claude",
            "model": "opus",
            "produces": "review.submitted",
            "ok": False,
            "duration_ms": 456,
            "error": "model process exited with status 17",
            "exit_code": 17,
            "command": ["claude", "-p", "<prompt:123 chars>"],
            "run_id": "r1",
            "stage_id": "s1",
            "shard_id": "a",
            "round": 2,
            "event": "model.invoked",
        }
    ]


def test_every_judging_role_has_a_model():
    """A role with no entry would fall through to whatever the CLI defaults to."""
    assert set(ROLE_MODELS) == set(ROLE_SKILLS)


def test_the_load_bearing_judgments_run_on_opus():
    """The plan binds every shard downstream; the assessment decides promotion."""
    for role in ("plan", "assess"):
        assert model_for(role, {}) == "opus"


def test_the_narrower_scoped_judgments_run_on_opus():
    assert model_for("review", {}) == "opus"


def test_the_plan_audit_keeps_its_own_runners_default_model():
    """Codex ships a default; a role running on it should not pin one here.

    The separation matters more than the default: `SIGNALBOX_MODEL` is a Claude
    alias by construction, and putting one in a codex argv fails at the least
    convenient moment — the same rule dispatch already keeps for its two runners.
    """
    from signalbox.agent import runner_for

    assert runner_for("audit", {}) == "codex"
    assert model_for("audit", {}) is None
    assert model_for("audit", {"SIGNALBOX_MODEL": "fable"}) is None
    assert model_for("audit", {"SIGNALBOX_CODEX_MODEL": "gpt-5.6"}) == "gpt-5.6"
    assert model_for("plan", {"SIGNALBOX_MODEL": "sonnet"}) == "sonnet"


def test_a_codex_judge_is_read_only_and_takes_its_prompt_on_stdin():
    """An auditor that could write could fix what it objects to.

    The objection would then stop being a verdict the topology can route, which
    is the whole containment: judgment produces one type, routers own the
    transition.
    """
    from signalbox.agent import codex_command

    command = codex_command("/tmp/wt-62", None)
    assert command[:2] == ["codex", "exec"]
    assert command[command.index("-C") + 1] == "/tmp/wt-62"
    assert command[command.index("--sandbox") + 1] == "read-only"
    assert command[-1] == "-", "the payload is passed on stdin, not in argv"
    assert "--model" not in command


def test_note_writing_runs_on_sonnet():
    assert model_for("plan-notes", {}) == "sonnet"
    assert model_for("write-note", {}) == "sonnet"


def test_a_per_role_override_beats_the_global_one():
    env = {"SIGNALBOX_MODEL": "sonnet", "SIGNALBOX_MODEL_REVIEW": "opus"}
    assert model_for("review", env) == "opus"
    assert model_for("assess", env) == "sonnet"


def test_the_per_role_variable_name_is_derived_not_guessed():
    assert model_env_var("plan-notes") == "SIGNALBOX_MODEL_PLAN_NOTES"
    assert model_env_var("review") == "SIGNALBOX_MODEL_REVIEW"


def test_acting_roles_run_on_codex():
    assert runner_for("signalbox-implement", {}) == "codex"
    assert runner_for("signalbox-fix", {}) == "codex"


def test_an_unknown_skill_falls_back_to_a_runner_that_can_load_skills():
    assert runner_for("signalbox-invented", {}) == "claude"


def test_codex_keeps_its_own_default_model():
    """We pin the runner, not the model; codex's config owns that choice."""
    from pathlib import Path

    assert dispatch_model_for("codex", {}) is None
    assert "--model" not in codex_command(Path("/tmp/wt"), None)


def test_a_claude_model_alias_cannot_leak_into_a_codex_argv():
    """Model names are not portable, so the global override is Claude-only."""
    assert dispatch_model_for("codex", {"SIGNALBOX_MODEL": "fable"}) is None
    assert dispatch_model_for("codex", {"SIGNALBOX_CODEX_MODEL": "gpt-5.6"}) == "gpt-5.6"
    assert dispatch_model_for("claude", {"SIGNALBOX_MODEL": "fable"}) == "fable"


def test_codex_runs_in_the_worktree_and_can_reach_the_control_endpoint():
    from pathlib import Path

    command = codex_command(Path("/tmp/wt-42"), None)
    assert command[:2] == ["codex", "exec"]
    assert "-C" in command and command[command.index("-C") + 1] == "/tmp/wt-42"
    assert command[-1] == "-", "the procedure is passed on stdin, not in argv"
    joined = " ".join(command)
    # Without these two the agent still works and is simply never heard from:
    # emit cannot open a socket, or the identity never reaches the shell.
    assert "sandbox_workspace_write.network_access=true" in joined
    assert 'shell_environment_policy.inherit="all"' in joined
    assert "workspace-write" in joined


def test_resume_commands_preserve_session_sandbox_and_current_scope():
    payload = {"shard_id": "a", "round": 2, "declared": ["src/only.py"]}

    claude = claude_resume_command("signalbox-fix", payload, "sonnet", "session-1")
    assert claude[claude.index("--resume") + 1] == "session-1"
    assert "--session-id-source" not in claude
    assert "src/only.py" in claude[claude.index("-p") + 1]

    codex = codex_resume_command(None, "session-2")
    assert codex[:3] == ["codex", "exec", "resume"]
    assert codex[-2:] == ["session-2", "-"]
    assert "-C" not in codex and "--sandbox" not in codex and "-s" not in codex
    joined = " ".join(codex)
    assert 'sandbox_mode="workspace-write"' in joined
    assert "sandbox_workspace_write.network_access=true" in joined
    assert 'shell_environment_policy.inherit="all"' in joined


def test_cold_start_commands_request_a_session_identity():
    claude = claude_command(
        "signalbox-fix", {"shard_id": "a"}, "sonnet", "minted-uuid"
    )
    assert claude[claude.index("--session-id") + 1] == "minted-uuid"
    assert "--json" in codex_command(Path("/tmp/wt"), None)


def test_codex_names_the_skill_in_its_own_mention_syntax():
    """Codex resolves `$name` against .codex/skills, so it is a reference.

    Inlining the procedure instead would fork one reviewable file into two
    copies that drift, and would put the whole SKILL.md in every prompt.
    """
    prompt = codex_prompt("signalbox-implement", {"shard_id": "a"})
    assert "$signalbox-implement" in prompt
    assert "signalbox emit" in prompt
    assert "BEGIN PROCEDURE" not in prompt


def test_skills_are_installed_where_both_runners_look(tmp_path):
    """Neither runner reads the other's directory, so each needs its own copy."""
    installed = install_skills(tmp_path)
    assert "signalbox-implement" in installed
    for runner, root in SKILL_ROOTS.items():
        path = tmp_path / root / "signalbox-implement" / "SKILL.md"
        assert path.is_file(), f"{runner} would not find the skill at {path}"


def test_a_skill_the_runner_cannot_see_is_an_error_before_it_starts(tmp_path):
    """The failure being prevented: an agent handed a name that resolves to
    nothing does not error, it improvises, and it edits files while doing so."""
    install_skills(tmp_path)
    assert require_skill(tmp_path, "codex", "signalbox-implement").is_dir()
    with pytest.raises(SkillMissing):
        require_skill(tmp_path, "codex", "signalbox-does-not-exist")
    with pytest.raises(SkillMissing):
        require_skill(tmp_path, "some-other-cli", "signalbox-implement")


def test_an_uninstalled_worktree_fails_the_check(tmp_path):
    with pytest.raises(SkillMissing):
        require_skill(tmp_path, "claude", "signalbox-implement")


def test_the_claude_runner_still_names_the_skill():
    command = claude_command("signalbox-fix", {"shard_id": "a"}, "sonnet")
    assert command[0] == "claude"
    assert "Load the signalbox-fix skill" in command[2]
    assert command[command.index("--model") + 1] == "sonnet"


@pytest.mark.parametrize("role", ["plan-notes", "write-note"])
def test_notes_roles_receive_the_resolved_vault(monkeypatch, tmp_path, role):
    """Incident #70: notes must escape the disposable judging worktree."""
    calls = []
    vault = tmp_path / "vault"
    vault.mkdir()
    monkeypatch.setenv("SIGNALBOX_VAULT", str(vault))
    monkeypatch.setattr(agent, "_workdir", lambda payload: "/tmp/wt")
    monkeypatch.setattr(
        agent.subprocess,
        "run",
        lambda command, **kwargs: calls.append((command, kwargs))
        or SimpleNamespace(returncode=0, stdout='{"verdict":"done"}', stderr=""),
    )
    monkeypatch.setattr(agent, "post_provenance", lambda *args, **kwargs: None)

    _, code = agent.run(role, {}, model="sonnet")

    assert code == 0
    command, kwargs = calls[0]
    assert command[command.index("--add-dir") + 1] == str(vault.resolve())
    assert kwargs["env"]["SIGNALBOX_VAULT"] == str(vault.resolve())
    assert kwargs["env"]["SIGNALBOX_VAULT"] != "None"


def test_non_notes_roles_receive_neither_vault_access_nor_a_stamped_env(
    monkeypatch,
):
    calls = []
    monkeypatch.setenv("SIGNALBOX_VAULT", "/should/not/be-forwarded")
    monkeypatch.setattr(agent, "_workdir", lambda payload: "/tmp/wt")
    monkeypatch.setattr(
        agent.subprocess,
        "run",
        lambda command, **kwargs: calls.append((command, kwargs))
        or SimpleNamespace(
            returncode=0,
            stdout='{"verdict":"approved"}',
            stderr="",
        ),
    )
    monkeypatch.setattr(agent, "post_provenance", lambda *args, **kwargs: None)

    _, code = agent.run("review", {}, model="opus")

    assert code == 0
    command, kwargs = calls[0]
    assert "--add-dir" not in command
    assert "env" not in kwargs


def test_plan_verdict_keeps_model_authored_stages_at_agent_seam(monkeypatch):
    inbound_stages = [{"stage_id": "rejected"}]
    authored_stages = [{"stage_id": "redraft"}]
    monkeypatch.setattr(agent, "_workdir", lambda payload: "/tmp/wt")
    monkeypatch.setattr(
        agent.subprocess,
        "run",
        lambda *args, **kwargs: SimpleNamespace(
            returncode=0,
            stdout=json.dumps({"verdict": "done", "stages": authored_stages}),
            stderr="",
        ),
    )
    monkeypatch.setattr(agent, "post_provenance", lambda *args, **kwargs: None)

    verdict, code = agent.run(
        "plan", {"run_id": "r1", "stages": inbound_stages}, model="opus"
    )

    assert code == 0
    assert verdict["stages"] == authored_stages
    assert "identity_overridden" not in verdict
    assert verdict["product_overridden"] == ["stages"]


@pytest.mark.parametrize("role", ["implement", "review"])
def test_non_authoring_verdict_has_stages_restamped_and_reported(monkeypatch, role):
    inbound_stages = [{"stage_id": "planned"}]
    monkeypatch.setattr(agent, "_workdir", lambda payload: "/tmp/wt")
    monkeypatch.setattr(agent, "prompt_for", lambda role, payload: "prompt")
    monkeypatch.setattr(
        agent.subprocess,
        "run",
        lambda *args, **kwargs: SimpleNamespace(
            returncode=0,
            stdout=json.dumps(
                {"verdict": "done", "stages": [{"stage_id": "spoofed"}]}
            ),
            stderr="",
        ),
    )
    monkeypatch.setattr(agent, "post_provenance", lambda *args, **kwargs: None)

    verdict, code = agent.run(
        role, {"run_id": "r1", "stages": inbound_stages}, model="opus"
    )

    assert code == 0
    assert verdict["stages"] == inbound_stages
    assert verdict["identity_overridden"] == ["stages"]
    assert "product_overridden" not in verdict


def test_agent_seam_does_not_publish_stale_non_carried_envelope_fields(monkeypatch):
    monkeypatch.setattr(agent, "_workdir", lambda payload: "/tmp/wt")
    monkeypatch.setattr(
        agent.subprocess,
        "run",
        lambda *args, **kwargs: SimpleNamespace(
            returncode=0,
            stdout=json.dumps({"objections": []}),
            stderr="",
        ),
    )
    monkeypatch.setattr(agent, "post_provenance", lambda *args, **kwargs: None)

    verdict, code = agent.run(
        "audit",
        {
            "run_id": "r1",
            "verdict": "changes_requested",
            "violations": ["stale feedback"],
        },
    )

    assert code == 0
    assert verdict == {"run_id": "r1", "objections": []}


def test_a_missing_notes_vault_is_a_clean_cli_error(monkeypatch, capsys):
    """Incident #70 configuration errors follow the paths.py caller convention."""
    monkeypatch.setattr(
        agent,
        "run",
        lambda *args, **kwargs: (_ for _ in ()).throw(
            agent.VaultMissing("SIGNALBOX_VAULT is not configured")
        ),
    )
    monkeypatch.setattr(agent.sys, "stdin", SimpleNamespace(read=lambda: "{}"))

    assert agent.main(["plan-notes"]) == 1
    assert (
        capsys.readouterr().err
        == "signalbox agent: SIGNALBOX_VAULT is not configured\n"
    )


@pytest.mark.parametrize("returncode", [0, 17])
def test_judging_invocation_always_posts_resolved_model(monkeypatch, returncode):
    posted = []
    monkeypatch.setattr(
        agent.subprocess,
        "run",
        lambda *a, **k: SimpleNamespace(
            returncode=returncode,
            stdout='{"verdict":"approved"}',
            stderr="failed",
        ),
    )
    monkeypatch.setattr(agent, "_workdir", lambda payload: "/tmp/wt")
    monkeypatch.setattr(
        agent,
        "post_provenance",
        lambda *args, **kwargs: posted.append((args, kwargs)),
    )

    payload = {
        "run_id": "r1",
        "stage_id": "s1",
        "shard_id": "a",
        "round": 2,
    }
    _, code = agent.run("review", payload, model="opus")

    assert code == returncode
    args, kwargs = posted[0]
    assert args[:5] == (
        "review",
        "claude",
        "opus",
        "review.submitted",
        returncode == 0,
    )
    assert isinstance(args[5], int) and args[5] >= 0
    if returncode == 0:
        assert args[6] == {}
    else:
        assert args[6] == {
            "stderr": "failed",
            "exit_code": 17,
            "command": [
                "claude",
                "-p",
                "<redacted: 242 chars>",
                "--model",
                "opus",
                "--allowedTools",
                "Read",
                "Grep",
                "Glob",
                "Skill",
                "Bash",
            ],
        }
    assert kwargs["env"]["SIGNALBOX_RUN_ID"] == "r1"
    assert kwargs["env"]["SIGNALBOX_STAGE_ID"] == "s1"
    assert kwargs["env"]["SIGNALBOX_SHARD_ID"] == "a"
    assert kwargs["env"]["SIGNALBOX_ROUND"] == "2"


@pytest.mark.parametrize(
    "base_env,expected_model",
    [
        ({}, None),
        ({"SIGNALBOX_CODEX_MODEL": "gpt-5.6"}, "gpt-5.6"),
    ],
)
def test_acting_invocation_posts_codex_model_or_null(
    tmp_path, monkeypatch, base_env, expected_model
):
    posted = []
    payload = {
        "run_id": "r1",
        "shard_id": "a",
        "round": 1,
        "declared": [],
    }
    monkeypatch.setenv("SIGNALBOX_STATE", str(tmp_path / "state"))
    monkeypatch.setattr(dispatch, "worktree_for", lambda payload: tmp_path)
    monkeypatch.setattr(dispatch, "require_skill", lambda *args: None)
    monkeypatch.setattr(
        dispatch.subprocess,
        "run",
        lambda *a, **k: SimpleNamespace(returncode=0, stderr=""),
    )
    monkeypatch.setattr(
        dispatch,
        "post_provenance",
        lambda *args, **kwargs: posted.append((args, kwargs)),
    )
    monkeypatch.delenv("SIGNALBOX_CODEX_MODEL", raising=False)
    for key, value in base_env.items():
        monkeypatch.setenv(key, value)
    monkeypatch.setattr(dispatch.sys, "stdin", SimpleNamespace(read=lambda: json.dumps(payload)))

    assert dispatch.main(["--skill", "signalbox-implement"]) == 0
    assert posted[0][0][:5] == (
        "implement",
        "codex",
        expected_model,
        "shard.submitted",
        True,
    )
    assert isinstance(posted[0][0][5], int) and posted[0][0][5] >= 0
    assert posted[0][1]["env"]["SIGNALBOX_RUN_ID"] == "r1"


def test_acting_nonzero_invocation_still_posts_provenance(tmp_path, monkeypatch):
    posted = []
    monkeypatch.setenv("SIGNALBOX_STATE", str(tmp_path / "state"))
    monkeypatch.setattr(dispatch, "worktree_for", lambda payload: tmp_path)
    monkeypatch.setattr(dispatch, "require_skill", lambda *args: None)
    monkeypatch.setattr(
        dispatch.subprocess,
        "run",
        lambda *a, **k: SimpleNamespace(returncode=9, stderr="failed"),
    )
    monkeypatch.setattr(
        dispatch,
        "post_provenance",
        lambda *args, **kwargs: posted.append((args, kwargs)),
    )
    monkeypatch.setattr(
        dispatch.sys,
        "stdin",
        SimpleNamespace(
            read=lambda: json.dumps(
                {"run_id": "r1", "shard_id": "a", "round": 1, "declared": []}
            )
        ),
    )

    assert dispatch.main(["--skill", "signalbox-implement"]) == 9
    assert posted[0][0][:5] == (
        "implement",
        "codex",
        dispatch_model_for("codex"),
        "shard.submitted",
        False,
    )
    diagnostic = posted[0][0][6]
    assert diagnostic["stderr"] == "failed"
    assert diagnostic["exit_code"] == 9
    assert diagnostic["command"][:2] == ["codex", "exec"]
    assert diagnostic["command"][-1] == "-"


def test_dispatch_resumes_matching_stored_codex_session(monkeypatch, tmp_path):
    calls = []
    recorded = []
    payload = {
        "run_id": "r1",
        "shard_id": "a",
        "round": 2,
        "declared": ["src/only.py"],
    }
    monkeypatch.setenv("SIGNALBOX_STATE", str(tmp_path / "state"))
    monkeypatch.setattr(dispatch, "worktree_for", lambda payload: tmp_path)
    monkeypatch.setattr(dispatch, "require_skill", lambda *args: None)
    monkeypatch.setattr(
        dispatch,
        "read_session",
        lambda *args: {"runner": "codex", "session_id": "thread-123"},
    )
    monkeypatch.setattr(
        dispatch, "record_session", lambda *args: recorded.append(args)
    )
    monkeypatch.setattr(
        dispatch.subprocess,
        "run",
        lambda command, **kwargs: calls.append((command, kwargs))
        or SimpleNamespace(
            returncode=0,
            stdout='{"type":"thread.started","thread_id":"thread-current"}\n',
            stderr="",
        ),
    )
    monkeypatch.setattr(dispatch, "post_provenance", lambda *args, **kwargs: None)
    monkeypatch.setattr(dispatch.sys, "stdin", SimpleNamespace(read=lambda: json.dumps(payload)))

    assert dispatch.main(["--skill", "signalbox-fix"]) == 0
    command, kwargs = calls[0]
    assert command[:3] == ["codex", "exec", "resume"]
    assert command[-2] == "thread-123"
    assert "--json" in command
    assert kwargs["cwd"] == str(tmp_path)
    assert kwargs["env"]["SIGNALBOX_SESSION_ID"] == "thread-123"
    assert '"declared": [\n    "src/only.py"\n  ]' in kwargs["input"]
    assert recorded == [("r1", "a", "codex", "thread-current")]


@pytest.mark.parametrize("round_number", [1, 2])
def test_successful_codex_cold_start_records_jsonl_thread(
    monkeypatch, tmp_path, round_number
):
    recorded = []
    payload = {
        "run_id": "r1",
        "shard_id": "a",
        "round": round_number,
        "declared": [],
    }
    monkeypatch.setenv("SIGNALBOX_STATE", str(tmp_path / "state"))
    monkeypatch.setattr(dispatch, "worktree_for", lambda payload: tmp_path)
    monkeypatch.setattr(dispatch, "require_skill", lambda *args: None)
    monkeypatch.setattr(dispatch, "read_session", lambda *args: None)
    monkeypatch.setattr(
        dispatch,
        "record_session",
        lambda *args: recorded.append(args),
    )
    monkeypatch.setattr(
        dispatch.subprocess,
        "run",
        lambda *args, **kwargs: SimpleNamespace(
            returncode=0,
            stdout='{"type":"thread.started","thread_id":"thread-new"}\n',
            stderr="",
        ),
    )
    monkeypatch.setattr(dispatch, "post_provenance", lambda *args, **kwargs: None)
    monkeypatch.setattr(dispatch.sys, "stdin", SimpleNamespace(read=lambda: json.dumps(payload)))

    assert dispatch.main(["--skill", "signalbox-implement"]) == 0
    assert recorded == [("r1", "a", "codex", "thread-new")]


def test_failed_codex_resume_falls_back_and_records_replacement(monkeypatch, tmp_path):
    calls = []
    recorded = []
    payload = {"run_id": "r1", "shard_id": "a", "round": 2, "declared": []}
    monkeypatch.setenv("SIGNALBOX_STATE", str(tmp_path / "state"))
    monkeypatch.setattr(dispatch, "worktree_for", lambda payload: tmp_path)
    monkeypatch.setattr(dispatch, "require_skill", lambda *args: None)
    monkeypatch.setattr(
        dispatch,
        "read_session",
        lambda *args: {"runner": "codex", "session_id": "thread-stale"},
    )
    monkeypatch.setattr(
        dispatch, "record_session", lambda *args: recorded.append(args)
    )

    def run(command, **kwargs):
        calls.append((command, kwargs))
        if "resume" in command:
            return SimpleNamespace(returncode=1, stdout="", stderr="missing thread")
        return SimpleNamespace(
            returncode=0,
            stdout='{"type":"thread.started","thread_id":"thread-new"}\n',
            stderr="",
        )

    monkeypatch.setattr(dispatch.subprocess, "run", run)
    monkeypatch.setattr(dispatch, "post_provenance", lambda *args, **kwargs: None)
    monkeypatch.setattr(
        dispatch.sys, "stdin", SimpleNamespace(read=lambda: json.dumps(payload))
    )

    assert dispatch.main(["--skill", "signalbox-fix"]) == 0
    assert calls[0][0][:3] == ["codex", "exec", "resume"]
    assert calls[1][0][:2] == ["codex", "exec"]
    assert calls[1][0][:3] != ["codex", "exec", "resume"]
    assert calls[1][1]["env"]["SIGNALBOX_SESSION_ID"] == ""
    assert recorded == [("r1", "a", "codex", "thread-new")]


def test_failed_codex_resume_with_output_does_not_run_shard_twice(
    monkeypatch, tmp_path
):
    calls = []
    recorded = []
    payload = {"run_id": "r1", "shard_id": "a", "round": 2, "declared": []}
    monkeypatch.setenv("SIGNALBOX_STATE", str(tmp_path / "state"))
    monkeypatch.setattr(dispatch, "worktree_for", lambda payload: tmp_path)
    monkeypatch.setattr(dispatch, "require_skill", lambda *args: None)
    monkeypatch.setattr(
        dispatch,
        "read_session",
        lambda *args: {"runner": "codex", "session_id": "thread-stale"},
    )
    monkeypatch.setattr(
        dispatch, "record_session", lambda *args: recorded.append(args)
    )
    monkeypatch.setattr(
        dispatch.subprocess,
        "run",
        lambda command, **kwargs: calls.append((command, kwargs))
        or SimpleNamespace(
            returncode=1,
            stdout='{"type":"thread.started","thread_id":"thread-current"}\n'
            '{"type":"item.completed","item":{"type":"agent_message"}}\n',
            stderr="stream closed",
        ),
    )
    monkeypatch.setattr(dispatch, "post_provenance", lambda *args, **kwargs: None)
    monkeypatch.setattr(
        dispatch.sys, "stdin", SimpleNamespace(read=lambda: json.dumps(payload))
    )

    assert dispatch.main(["--skill", "signalbox-fix"]) == 1
    assert len(calls) == 1
    assert recorded == [("r1", "a", "codex", "thread-current")]


def test_failed_codex_cold_start_still_records_jsonl_thread(monkeypatch, tmp_path):
    recorded = []
    payload = {"run_id": "r1", "shard_id": "a", "round": 1, "declared": []}
    monkeypatch.setenv("SIGNALBOX_STATE", str(tmp_path / "state"))
    monkeypatch.setattr(dispatch, "worktree_for", lambda payload: tmp_path)
    monkeypatch.setattr(dispatch, "require_skill", lambda *args: None)
    monkeypatch.setattr(dispatch, "read_session", lambda *args: None)
    monkeypatch.setattr(
        dispatch, "record_session", lambda *args: recorded.append(args)
    )
    monkeypatch.setattr(
        dispatch.subprocess,
        "run",
        lambda *args, **kwargs: SimpleNamespace(
            returncode=1,
            stdout='{"type":"thread.started","thread_id":"thread-new"}\n',
            stderr="rate limited",
        ),
    )
    monkeypatch.setattr(dispatch, "post_provenance", lambda *args, **kwargs: None)
    monkeypatch.setattr(
        dispatch.sys, "stdin", SimpleNamespace(read=lambda: json.dumps(payload))
    )

    assert dispatch.main(["--skill", "signalbox-implement"]) == 1
    assert recorded == [("r1", "a", "codex", "thread-new")]
