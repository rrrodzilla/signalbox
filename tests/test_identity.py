"""Identity is the system's to assign. A model cannot reassign itself."""

from __future__ import annotations

from signalbox.agent import extract_verdict
from signalbox.emit import ALLOWED_EVENTS, build_body, identity_from_env, parse_fields
from signalbox.identity import carry, spoofed_keys


def test_carry_overrides_model_supplied_identity():
    inbound = {"run_id": "r1", "shard_id": "a", "declared": ["src/a.py"], "round": 2}
    produced = {"verdict": "done", "shard_id": "b", "declared": ["src/", "**"]}
    result = carry(inbound, produced)
    assert result["shard_id"] == "a"
    assert result["declared"] == ["src/a.py"]
    assert result["round"] == 2
    assert result["verdict"] == "done"


def test_carry_leaves_non_identity_fields_alone():
    result = carry({"run_id": "r1"}, {"findings": [1, 2], "verdict": "approved"})
    assert result["findings"] == [1, 2]
    assert result["run_id"] == "r1"


def test_carry_does_not_invent_absent_keys():
    assert "shard_id" not in carry({"run_id": "r1"}, {"verdict": "done"})


def test_spoofed_keys_reports_the_attempt():
    inbound = {"run_id": "r1", "shard_id": "a"}
    produced = {"shard_id": "b", "run_id": "r1"}
    assert spoofed_keys(inbound, produced) == ["shard_id"]


def test_spoofed_keys_is_empty_when_the_model_echoes_correctly():
    assert spoofed_keys({"shard_id": "a"}, {"shard_id": "a"}) == []


# ── the announce tool ────────────────────────────────────────────────────────


def test_emit_body_takes_identity_from_env_not_arguments():
    env = {
        "SIGNALBOX_RUN_ID": "r1",
        "SIGNALBOX_SHARD_ID": "a",
        "SIGNALBOX_DECLARED": '["src/a.py"]',
        "SIGNALBOX_ROUND": "3",
    }
    body = build_body("shard.file-written", {"path": "src/a.py", "shard_id": "b"}, env)
    assert body["shard_id"] == "a"
    assert body["declared"] == ["src/a.py"]
    assert body["round"] == 3
    assert body["event"] == "shard.file-written"
    assert body["path"] == "src/a.py"


def test_emit_carries_correlation_across_the_http_boundary():
    env = {"SIGNALBOX_RUN_ID": "r1", "EMERGENT_CORRELATION_ID": "corr-9"}
    assert identity_from_env(env)["correlation_id"] == "corr-9"


def test_emit_ignores_blank_env_values():
    assert "shard_id" not in identity_from_env({"SIGNALBOX_SHARD_ID": ""})


def test_emit_vocabulary_excludes_anything_that_advances_the_run():
    for forbidden in ("shard.approved", "stage.merged", "approval.granted", "pr.merged"):
        assert forbidden not in ALLOWED_EVENTS


def test_model_provenance_is_not_in_the_agent_emission_vocabulary():
    assert "model.invoked" not in ALLOWED_EVENTS


def test_parse_fields_decodes_json_values():
    assert parse_fields(["a=1", "b=hi", 'c=["x"]']) == {"a": 1, "b": "hi", "c": ["x"]}


# ── verdict extraction ───────────────────────────────────────────────────────


def test_extract_verdict_ignores_narration():
    out = 'Sure! Here is my review.\n{"verdict": "approved", "findings": []}\nHope that helps.'
    assert extract_verdict(out) == {"verdict": "approved", "findings": []}


def test_extract_verdict_takes_the_last_object():
    out = '{"verdict": "changes_requested"}\nActually, on reflection:\n{"verdict": "approved"}'
    assert extract_verdict(out) == {"verdict": "approved"}


def test_extract_verdict_handles_nesting_and_braces_in_strings():
    out = 'noise {"verdict": "approved", "note": "use {} carefully", "d": {"k": [1,2]}} tail'
    assert extract_verdict(out)["d"] == {"k": [1, 2]}


def test_extract_verdict_returns_none_when_there_is_no_object():
    assert extract_verdict("I could not complete this task.") is None
    assert extract_verdict("") is None
