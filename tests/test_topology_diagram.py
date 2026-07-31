"""Properties of the topology-derived README picture."""

from __future__ import annotations

import copy
import re
import tomllib
from pathlib import Path

import pytest

from signalbox.cli import ACT_COMMANDS, COMMANDS, main as cli_main
from signalbox.topology_diagram import (
    HIDDEN_TOPICS,
    InvalidPrimitive,
    REMEDIATION_ROUTER,
    RemediationRouterMissing,
    StaleProjection,
    render_counts_sentence,
    render_main_block,
    render_remediation_block,
    render_topology,
    resolve_topology,
)

ROOT = Path(__file__).resolve().parent.parent


def config() -> dict:
    """Re-read the live configuration for every invocation."""
    with (ROOT / "emergent.toml").open("rb") as stream:
        return tomllib.load(stream)


def test_rendering_is_deterministic_bounded_and_counts_derive_from_groups():
    first = render_topology(config())
    assert first == render_topology(config())
    assert all(len(line) <= 78 for block in first[:2] for line in block.splitlines())
    value = {"sources": [{}, {}], "handlers": [{}], "sinks": []}
    assert render_counts_sentence(value) == (
        "One engine. Two sources, one handler, zero sinks, and no script that knows what comes next."
    )


def test_hidden_topics_are_justified_and_stale_keys_fail():
    value = config()
    assert set(HIDDEN_TOPICS) <= resolve_topology(value)["published"]
    assert all(reason.strip() for reason in HIDDEN_TOPICS.values())
    stale = copy.deepcopy(value)
    for primitive in stale["sources"] + stale["handlers"] + stale["sinks"]:
        primitive["publishes"] = [
            topic for topic in primitive.get("publishes", []) if topic != "assess.failed"
        ]
    with pytest.raises(StaleProjection, match="stale hidden-topic keys"):
        resolve_topology(stale)


def test_main_order_is_reachable_layer_order_not_alphabetical():
    block = render_main_block(config())
    topics = re.findall(r"\[([^\]]+?)(?: \([^\]]+\))?\]", block)
    assert topics[0] == "run.requested"
    assert topics.index("workspace.prepare-attempted") < topics.index("checks.passed")
    assert topics != sorted(topics)
    # The out-of-band ingress bridge keeps the lifecycle beyond dispatch in
    # this same reachable projection.
    assert "shard.submitted" in topics
    assert "checks.passed" in topics


def _records(block: str) -> dict[str, tuple[list[str], list[str]]]:
    records: dict[str, tuple[list[str], list[str]]] = {}
    topic: str | None = None
    direction: str | None = None
    for line in block.splitlines():
        assert not line.endswith(" ─> ")
        if " ─> [" in line:
            source_text, remainder = line.split(" ─> [", 1)
            if "] ─> " in remainder:
                label, target_text = remainder.split("] ─> ", 1)
                targets = target_text.split(", ")
            else:
                label, targets = remainder.removesuffix("]"), []
            topic = label.split(" (")[0]
            records[topic] = (source_text.split(", "), targets)
            direction = None
        elif line.startswith("["):
            topic = line[1:line.index("]")].split(" (")[0]
            records[topic] = ([], [])
            direction = None
        elif line.startswith(("├─< from: ", "└─< from: ")):
            direction = "from"
            records[topic][0].extend(line.split(": ", 1)[1].split(", "))
        elif line.startswith("└─> to: "):
            direction = "to"
            records[topic][1].extend(line.split(": ", 1)[1].split(", "))
        else:
            assert topic is not None and direction is not None
            records[topic][0 if direction == "from" else 1].extend(line.strip(" │").split(", "))
    return records


def _bare(value: str) -> str:
    return value.strip(" ,").split(" (")[0]


def test_every_drawn_edge_has_resolved_endpoints_and_publish_only_has_no_arrow():
    value = config()
    topology = resolve_topology(value)
    records = _records(render_main_block(value))
    for topic, (sources, targets) in records.items():
        assert {_bare(item) for item in sources} == set(topology["publishers"][topic])
        assert {_bare(item) for item in targets} == set(topology["subscribers"].get(topic, ()))

    publisher_only = copy.deepcopy(value)
    publisher_only["sources"].append({"name": "new-source", "publishes": ["new.topic"]})
    rendered = render_main_block(publisher_only)
    assert "new-source ─> [new.topic]" in rendered
    assert "[new.topic] ─>" not in rendered


def test_halt_marks_only_topics_whose_own_consumers_halt():
    value = config()
    topology = resolve_topology(value)
    halt_publishers = set(topology["publishers"]["run.halted"])
    expected = {
        topic for topic, consumers in topology["subscribers"].items()
        if set(consumers) & halt_publishers and topic != "run.halted"
    } - set(HIDDEN_TOPICS)
    marked = set(re.findall(r"\[([^\]]+?) \(halt\)\]", render_main_block(value)))
    assert marked == expected
    assert {"branch.pushed", "approval.granted"}.isdisjoint(marked)


def test_remediation_fan_in_and_named_errors_are_resolved():
    value = config()
    router = next(item for item in value["handlers"] if item["name"] == REMEDIATION_ROUTER)
    lines = render_remediation_block(value).splitlines()
    assert lines[:len(router["subscribes"])] == [
        f"[{topic}] ─> {REMEDIATION_ROUTER}" for topic in router["subscribes"]
    ]
    missing = copy.deepcopy(value)
    missing["handlers"] = [item for item in missing["handlers"] if item["name"] != REMEDIATION_ROUTER]
    with pytest.raises(RemediationRouterMissing, match="remediation router is absent"):
        render_remediation_block(missing)
    malformed = copy.deepcopy(value)
    malformed["handlers"][0].pop("name")
    with pytest.raises(InvalidPrimitive, match="non-empty name"):
        resolve_topology(malformed)


def _temporary_root(tmp_path: Path, readme: str) -> Path:
    (tmp_path / "README.md").write_text(readme)
    (tmp_path / "emergent.toml").write_bytes((ROOT / "emergent.toml").read_bytes())
    return tmp_path


def test_topology_diagram_is_a_non_act_cli_command(monkeypatch, capsys):
    monkeypatch.setenv("SIGNALBOX_ROOT", str(ROOT))
    expected = render_topology(config())

    assert "topology-diagram" in COMMANDS
    assert "topology-diagram" not in ACT_COMMANDS
    assert cli_main(["topology-diagram"]) == 0
    assert capsys.readouterr().out == f"{expected[0]}\n\n{expected[1]}\n\n{expected[2]}\n"


def test_topology_diagram_write_repairs_drift_and_is_idempotent(
    tmp_path, monkeypatch
):
    expected_main, expected_remediation, expected_counts = render_topology(config())
    fixture = (ROOT / "README.md").read_text()
    fixture = fixture.replace(
        expected_counts,
        "One engine. Drifted sources and no script that knows what comes next.",
        1,
    )
    fixture = fixture.replace(
        f"```\n{expected_main}\n```", "```\ndrifted main block\n```", 1
    )
    fixture = fixture.replace(
        f"```\n{expected_remediation}\n```",
        "```\ndrifted remediation block\n```",
        1,
    )
    assert expected_counts not in fixture
    assert expected_main not in fixture
    assert expected_remediation not in fixture

    root = _temporary_root(tmp_path, fixture)
    elsewhere = tmp_path / "elsewhere"
    elsewhere.mkdir()
    monkeypatch.chdir(elsewhere)
    monkeypatch.setenv("SIGNALBOX_ROOT", str(root))

    assert cli_main(["topology-diagram", "--write"]) == 0
    rewritten = (root / "README.md").read_text()
    assert expected_counts in rewritten
    assert f"```\n{expected_main}\n```" in rewritten
    assert f"```\n{expected_remediation}\n```" in rewritten

    assert cli_main(["topology-diagram", "--write"]) == 0
    assert (root / "README.md").read_text() == rewritten


def test_write_anchor_does_not_depend_on_remediation_count_wording(
    tmp_path, monkeypatch
):
    expected_remediation = render_remediation_block(config())
    fixture = (ROOT / "README.md").read_text().replace(
        "The remaining ten formerly stranded outcomes",
        "The remaining eleven formerly stranded outcomes",
        1,
    )
    fixture = fixture.replace(
        f"```\n{expected_remediation}\n```",
        "```\ndrifted remediation block\n```",
        1,
    )
    assert expected_remediation not in fixture
    root = _temporary_root(tmp_path, fixture)
    monkeypatch.setenv("SIGNALBOX_ROOT", str(root))

    assert cli_main(["topology-diagram", "--write"]) == 0
    rewritten = (root / "README.md").read_text()
    assert "The remaining eleven formerly stranded outcomes" in rewritten
    assert f"```\n{expected_remediation}\n```" in rewritten


def test_topology_diagram_argument_errors_exit_two(monkeypatch, capsys):
    monkeypatch.setenv("SIGNALBOX_ROOT", str(ROOT))
    with pytest.raises(SystemExit) as raised:
        cli_main(["topology-diagram", "--unknown"])
    assert raised.value.code == 2
    assert "usage: signalbox topology-diagram" in capsys.readouterr().err


def test_topology_diagram_toml_read_failure_is_one_line(
    tmp_path, monkeypatch, capsys
):
    monkeypatch.setenv("SIGNALBOX_ROOT", str(tmp_path))

    assert cli_main(["topology-diagram"]) == 1
    error = capsys.readouterr().err
    assert error.startswith("signalbox topology-diagram: ")
    assert "emergent.toml" in error
    assert "Traceback" not in error
    assert len(error.splitlines()) == 1


def test_topology_diagram_resolution_failure_is_one_line(
    monkeypatch, capsys
):
    from signalbox import topology_diagram

    monkeypatch.setenv("SIGNALBOX_ROOT", str(ROOT))
    monkeypatch.setattr(
        topology_diagram,
        "render_topology",
        lambda _config: (_ for _ in ()).throw(StaleProjection("stale graph")),
    )

    assert cli_main(["topology-diagram"]) == 1
    assert capsys.readouterr().err == "signalbox topology-diagram: stale graph\n"
