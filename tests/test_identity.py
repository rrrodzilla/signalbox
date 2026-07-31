"""Identity is the system's to assign. A model cannot reassign itself."""

from __future__ import annotations

import pytest

from signalbox.agent import (
    UNPARSEABLE_OUTPUT_ELISION_MARKER,
    UNPARSEABLE_OUTPUT_HEAD_LIMIT,
    UNPARSEABLE_OUTPUT_TAIL_LIMIT,
    close_unclosed_root,
    elide_unparseable_output,
    extract_verdict,
    scan_objects,
)
from signalbox.emit import ALLOWED_EVENTS, build_body, identity_from_env, parse_fields
from signalbox import identity
from signalbox.identity import CARRIED_KEYS, carry, merge, project, spoofed_keys


def test_project_includes_every_present_carried_key():
    source = {key: f"value-{index}" for index, key in enumerate(CARRIED_KEYS)}
    source["verdict"] = "done"
    assert project(source) == {key: source[key] for key in CARRIED_KEYS}


def test_project_omits_absent_carried_keys():
    result = project({"run_id": "r1", "verdict": "done"})
    assert result == {"run_id": "r1"}
    for key in ("note", "note_count", "pr", "attempt"):
        assert key not in result


def test_project_follows_new_carried_keys(monkeypatch):
    monkeypatch.setattr(identity, "CARRIED_KEYS", (*CARRIED_KEYS, "sentinel"))
    assert project({"run_id": "r1", "sentinel": "carried"})["sentinel"] == "carried"


def test_all_identity_operations_follow_future_carried_keys(monkeypatch):
    monkeypatch.setattr(identity, "CARRIED_KEYS", (*CARRIED_KEYS, "sentinel"))
    inbound = {"sentinel": "system"}
    produced = {"sentinel": "model"}

    assert carry(inbound, produced)["sentinel"] == "system"
    assert spoofed_keys(inbound, produced) == ["sentinel"]


def test_carry_overrides_model_supplied_identity():
    inbound = {"run_id": "r1", "shard_id": "a", "declared": ["src/a.py"], "round": 2}
    produced = {"verdict": "done", "shard_id": "b", "declared": ["src/", "**"]}
    result = carry(inbound, produced)
    assert result["shard_id"] == "a"
    assert result["declared"] == ["src/a.py"]
    assert result["round"] == 2
    assert result["verdict"] == "done"


def test_non_drafting_role_cannot_override_model_supplied_stage_cursor():
    stages = [{"stage_id": "s1"}, {"stage_id": "s2"}]
    inbound = {"stage_index": 1, "stages": stages}
    produced = {"stage_index": 0, "stages": [{"stage_id": "spoofed"}]}

    result = merge(inbound, produced, "implement")

    assert result.payload["stage_index"] == 1
    assert result.payload["stages"] == stages
    assert result.envelope_overridden == ["stage_index", "stages"]
    assert result.product_overridden == []


@pytest.mark.parametrize(
    ("feedback_key", "feedback"),
    [
        ("objections", ["the stage ordering is unsafe"]),
        ("violations", ["stage s2 names a missing dependency"]),
    ],
)
def test_plan_redraft_replaces_rejected_stages_and_keeps_feedback(
    feedback_key, feedback
):
    rejected = [{"stage_id": "rejected"}]
    redraft = [{"stage_id": "redrafted"}]
    inbound = {"run_id": "r1", "stages": rejected, feedback_key: feedback}
    produced = {"stages": redraft}

    result = merge(inbound, produced, "plan")

    assert result.payload["stages"] == redraft
    assert result.payload[feedback_key] == feedback
    assert result.envelope_overridden == []
    assert result.product_overridden == ["stages"]
    assert result.product_omitted == []


def test_unparseable_plan_drops_rejected_stages_and_reports_the_omission():
    rejected = [{"stage_id": "rejected"}]
    inbound = {"run_id": "r1", "stages": rejected}
    produced = {"verdict": "unparseable", "output": "not json"}

    result = merge(inbound, produced, "plan")

    assert result.payload == {
        "run_id": "r1",
        "verdict": "unparseable",
        "output": "not json",
    }
    assert result.envelope_overridden == []
    assert result.product_overridden == []
    assert result.product_omitted == ["stages"]


def test_merge_follows_future_role_product_keys(monkeypatch):
    monkeypatch.setattr(
        identity,
        "ROLE_PRODUCT_KEYS",
        {**identity.ROLE_PRODUCT_KEYS, "sentinel-role": frozenset({"sentinel-key"})},
    )
    inbound = {"run_id": "r1", "sentinel-key": "rejected"}

    result = merge(inbound, {"verdict": "unparseable"}, "sentinel-role")

    assert "sentinel-key" not in result.payload
    assert result.product_omitted == ["sentinel-key"]


def test_carry_leaves_non_identity_fields_alone():
    result = carry({"run_id": "r1"}, {"findings": [1, 2], "verdict": "approved"})
    assert result["findings"] == [1, 2]
    assert result["run_id"] == "r1"


def test_carry_does_not_invent_absent_keys():
    assert "shard_id" not in carry({"run_id": "r1"}, {"verdict": "done"})


@pytest.mark.parametrize("produced", [{"verdict": "ok"}, {"title": "model rewrite"}])
def test_carry_preserves_the_inbound_issue_title(produced):
    """In sb-78, agent.run() first dropped title while carrying the plan verdict."""
    result = carry({"run_id": "sb-78", "title": "The real issue title"}, produced)

    assert result["title"] == "The real issue title"


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


def test_unparseable_output_elision_keeps_both_ends_and_names_the_omission():
    head = "h" * UNPARSEABLE_OUTPUT_HEAD_LIMIT
    omitted = "x" * 17
    tail = "t" * UNPARSEABLE_OUTPUT_TAIL_LIMIT

    output, elided = elide_unparseable_output(head + omitted + tail)

    marker = UNPARSEABLE_OUTPUT_ELISION_MARKER.format(elided=len(omitted))
    assert output == head + marker + tail
    assert elided == len(omitted)


def test_unparseable_output_elision_keeps_short_output_whole():
    stdout = "malformed but complete diagnostic text"

    assert elide_unparseable_output(stdout) == (stdout, 0)


# ── repairing a root object the model forgot to close ────────────────────────


def test_a_plan_missing_only_its_root_brace_is_recovered():
    """The sb-113 shape: every stage, shard and array closed, root left open.

    Both drafts on 2026-07-30 ended exactly here, at `stop_reason: end_turn` and
    ~2.5k output tokens, and cost the run an attempt each for one character.
    """
    out = '{"stages":[{"stage_id":"s1","shards":[{"shard_id":"s1-a","files":["a.py"],"intent":"do it."}]}]'
    assert extract_verdict(out) is None
    recovered = extract_verdict(close_unclosed_root(out))
    assert recovered["stages"][0]["shards"][0]["shard_id"] == "s1-a"


def test_a_complete_object_is_never_repaired():
    """Nothing is owed, so nothing is appended — the normal path must not move."""
    assert close_unclosed_root('{"verdict": "approved"}') is None
    assert close_unclosed_root('narration {"verdict": "approved"} more') is None


def test_an_unterminated_string_is_left_unparseable():
    """Stopping mid-value is real truncation; a brace there invents the rest."""
    assert close_unclosed_root('{"stages": [], "note": "the run was') is None


def test_an_unclosed_inner_object_is_left_unparseable():
    """Completing an inner object guesses at content, not at punctuation."""
    assert close_unclosed_root('{"stages":[{"stage_id":"s1"') is None


def test_an_unclosed_array_is_left_unparseable():
    """A half-emitted stages array must not become a plan that lost its tail.

    Only braces are ever appended, so output that stopped inside an array either
    fails the depth guard or fails `json.loads`. Losing stage 2 silently is worse
    than an invalid verdict, because the run would build the wrong thing.
    """
    out = '{"stages":[{"stage_id":"s1","shards":[]},'
    repaired = close_unclosed_root(out)
    assert repaired is None or extract_verdict(repaired) is None


def test_a_root_left_open_where_a_brace_cannot_follow_is_rejected_by_the_parser():
    """The depth guard permits it; JSON is what actually refuses it."""
    assert extract_verdict(close_unclosed_root('{"verdict": "approved",')) is None


def test_scan_reports_how_the_output_ended():
    assert scan_objects('{"a": 1}').open_depth == 0
    assert scan_objects('{"a": 1').open_depth == 1
    assert scan_objects('{"a": "x').unterminated_string is True
    assert scan_objects('{"a": "}"').unterminated_string is False
