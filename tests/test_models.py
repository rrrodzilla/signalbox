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
from signalbox.paths import SkillMissing, skill_body, strip_frontmatter


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


def test_codex_gets_the_procedure_inline_because_it_cannot_load_a_skill():
    prompt = codex_prompt("signalbox-implement", {"shard_id": "a"})
    assert "signalbox emit" in prompt
    # A sentence that only exists in the skill file, so this fails if the body
    # stops being inlined rather than merely being named.
    assert skill_body("signalbox-implement")[:80] in prompt


def test_a_missing_skill_is_an_error_not_an_empty_procedure():
    with pytest.raises(SkillMissing):
        skill_body("signalbox-does-not-exist")


def test_frontmatter_is_stripped_but_prose_survives():
    text = "---\nname: x\ndescription: y\n---\n\n# Heading\n\nBody.\n"
    assert strip_frontmatter(text) == "# Heading\n\nBody.\n"
    assert strip_frontmatter("# No frontmatter\n") == "# No frontmatter\n"


def test_the_claude_runner_still_names_the_skill():
    command = claude_command("signalbox-fix", {"shard_id": "a"}, "sonnet")
    assert command[0] == "claude"
    assert "Load the signalbox-fix skill" in command[2]
    assert command[command.index("--model") + 1] == "sonnet"
