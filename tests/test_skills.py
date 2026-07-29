"""Every skill a primitive names must exist, and say what the routers expect.

A skill referenced by a handler but absent on disk fails at runtime, inside a
model call, as an unparseable verdict — the most expensive place to discover a
typo. These checks make it a test failure instead.
"""

from __future__ import annotations

import tomllib
from pathlib import Path

import pytest

from signalbox.agent import ROLE_SKILLS
from signalbox.emit import ALLOWED_EVENTS

ROOT = Path(__file__).resolve().parent.parent
SKILLS = ROOT / "skills"


def _frontmatter(path: Path) -> dict:
    text = path.read_text()
    assert text.startswith("---\n"), f"{path} has no frontmatter"
    _, block, _ = text.split("---\n", 2)
    fields: dict[str, str] = {}
    for line in block.splitlines():
        key, _, value = line.partition(":")
        if value:
            fields[key.strip()] = value.strip()
    return fields


def dispatch_skills() -> set[str]:
    """Skills named by `signalbox dispatch --skill` in the topology."""
    config = tomllib.load((ROOT / "emergent.toml").open("rb"))
    named = set()
    for sink in config["sinks"]:
        args = sink.get("args", [])
        if "--skill" in args:
            named.add(args[args.index("--skill") + 1])
    return named


ALL_SKILLS = sorted(set(ROLE_SKILLS.values()) | dispatch_skills())


def test_every_role_and_dispatch_names_a_distinct_skill():
    assert len(ALL_SKILLS) == 8, ALL_SKILLS


@pytest.mark.parametrize("skill", ALL_SKILLS)
def test_skill_exists_with_frontmatter(skill: str):
    path = SKILLS / skill / "SKILL.md"
    assert path.is_file(), f"{skill} is referenced by a primitive but not on disk"
    fields = _frontmatter(path)
    assert fields.get("name") == skill, f"{path} declares name {fields.get('name')!r}"
    assert len(fields.get("description", "")) > 40, f"{skill} needs a real description"


@pytest.mark.parametrize(
    "skill,vocabulary",
    [
        ("signalbox-review", ("approved", "changes_requested")),
        ("signalbox-assess", ("clear", "needs_human", "block")),
    ],
)
def test_judging_skill_states_the_exact_vocabulary_its_routers_match(skill, vocabulary):
    """A verdict string the routers do not match escalates to a human."""
    body = (SKILLS / skill / "SKILL.md").read_text()
    for term in vocabulary:
        assert f"`{term}`" in body or f'"{term}"' in body, f"{skill} never states {term}"


def test_acting_skills_document_only_emittable_events():
    """An acting skill must not teach an agent to announce something it cannot."""
    for skill in ("signalbox-implement", "signalbox-fix"):
        body = (SKILLS / skill / "SKILL.md").read_text()
        for line in body.splitlines():
            if "signalbox emit " not in line:
                continue
            event = line.split("signalbox emit ", 1)[1].split()[0]
            assert event in ALLOWED_EVENTS, f"{skill} teaches unemittable {event!r}"


def test_acting_skills_forbid_advancing_the_run():
    """The containment that keeps an implementing agent from being a conductor."""
    body = (SKILLS / "signalbox-implement" / "SKILL.md").read_text().lower()
    assert "do not commit" in body
    assert "cannot" in body and "merge" in body


def test_vault_skills_carry_the_dot_claude_warning():
    """Writes under .claude/ are silently dropped; a skill that forgets loses notes."""
    for skill in ("signalbox-plan-notes", "signalbox-write-note"):
        body = (SKILLS / skill / "SKILL.md").read_text()
        assert ".claude/" in body, f"{skill} does not warn about .claude/"
