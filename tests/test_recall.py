"""Vault context reaches planning without becoming a run dependency.

Recall stopped being a topology role when planning absorbed it, but the property
it protected did not move: an operator with no vault gets a run without recalled
context, never a run that cannot start."""

from __future__ import annotations

import json
from types import SimpleNamespace

from signalbox import agent


def _isolate_invocation(monkeypatch):
    monkeypatch.setattr(agent, "_workdir", lambda payload: "/tmp/wt")
    monkeypatch.setattr(agent, "post_provenance", lambda *args, **kwargs: None)


def test_a_missing_vault_yields_empty_recall_and_completes(monkeypatch):
    calls = []
    monkeypatch.delenv("SIGNALBOX_VAULT", raising=False)
    _isolate_invocation(monkeypatch)
    monkeypatch.setattr(
        agent.subprocess,
        "run",
        lambda command, **kwargs: calls.append((command, kwargs))
        or SimpleNamespace(
            returncode=0,
            stdout=json.dumps(
                {
                    "hazards": [],
                    "warnings": [],
                    "contradictions": [],
                    "contradictions_omitted": 0,
                }
            ),
            stderr="",
        ),
    )

    result, code = agent.run("plan", {"run_id": "sb-89"}, model="fable")

    assert code == 0
    assert result == {
        "run_id": "sb-89",
        "hazards": [],
        "warnings": [],
        "contradictions": [],
        "contradictions_omitted": 0,
    }
    command, kwargs = calls[0]
    assert "--add-dir" not in command
    assert kwargs["env"]["SIGNALBOX_VAULT"] == ""


def test_the_planner_can_fan_out_but_cannot_write():
    """Planning gained subagents when it absorbed survey and recall.

    `Agent` is what lets it run those two concurrently instead of the topology
    doing it with a join. `Write` and `Edit` stay off: a planning agent that can
    edit is one that can implement its own plan, and nothing downstream would
    know it had.
    """
    tools = agent.tools_for("plan")
    assert {"Skill", "Agent"}.issubset(tools)
    assert not {"Write", "Edit"}.intersection(tools)


def test_a_vault_note_contradicting_code_is_attributed_in_the_payload(
    monkeypatch, tmp_path
):
    vault = tmp_path / "vault"
    vault.mkdir()
    note = vault / "architecture.md"
    note.write_text(
        "# Architecture\n\nThe worker still polls GitHub every 45 seconds.\n"
    )
    monkeypatch.setenv("SIGNALBOX_VAULT", str(vault))
    _isolate_invocation(monkeypatch)

    def invoke(command, **kwargs):
        configured = kwargs["env"]["SIGNALBOX_VAULT"]
        text = (vault / "architecture.md").read_text()
        assert configured == str(vault)
        assert command[command.index("--add-dir") + 1] == str(vault)
        return SimpleNamespace(
            returncode=0,
            stdout=json.dumps(
                {
                    "hazards": [],
                    "warnings": [],
                    "contradictions": [
                        {
                            "note": "architecture.md",
                            "claim": text.splitlines()[-1],
                            "evidence": "the issue says webhooks replaced polling",
                        }
                    ],
                    "contradictions_omitted": 0,
                }
            ),
            stderr="",
        )

    monkeypatch.setattr(agent.subprocess, "run", invoke)
    result, code = agent.run("plan", {"run_id": "sb-89"}, model="fable")

    assert code == 0
    assert result["contradictions"] == [
        {
            "note": "architecture.md",
            "claim": "The worker still polls GitHub every 45 seconds.",
            "evidence": "the issue says webhooks replaced polling",
        }
    ]
