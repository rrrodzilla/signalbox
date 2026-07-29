"""Which model renders which judgment, and which runner does the acting.

These are assertions about intent, not about implementation. A model change is a
behavioural change to the pipeline, so it should not be possible to make one by
accident.
"""

from __future__ import annotations

import pytest

from signalbox.agent import ROLE_MODELS, ROLE_SKILLS, model_env_var, model_for
from signalbox.dispatch import (
    claude_command,
    codex_command,
    codex_prompt,
    model_for as dispatch_model_for,
    runner_for,
)
from signalbox.paths import SKILL_ROOTS, SkillMissing, install_skills, require_skill


def test_every_judging_role_has_a_model():
    """A role with no entry would fall through to whatever the CLI defaults to."""
    assert set(ROLE_MODELS) == set(ROLE_SKILLS)


def test_the_load_bearing_judgments_run_on_fable():
    for role in ("plan", "review", "assess", "survey"):
        assert model_for(role, {}) == "fable"


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
