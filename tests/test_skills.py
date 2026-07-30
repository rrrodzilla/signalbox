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
from signalbox.paths import VaultMissing, vault_dir

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
    assert "model.invoked" not in ALLOWED_EVENTS


def test_acting_skills_forbid_advancing_the_run():
    """The containment that keeps an implementing agent from being a conductor."""
    body = (SKILLS / "signalbox-implement" / "SKILL.md").read_text().lower()
    assert "do not commit" in body
    assert "cannot" in body and "merge" in body


def test_vault_dir_returns_configured_directory(monkeypatch, tmp_path):
    monkeypatch.setenv("SIGNALBOX_VAULT", str(tmp_path))

    assert vault_dir() == tmp_path


def test_vault_dir_refuses_unset_configuration(monkeypatch):
    """Incident #70 requires refusing to invent a worktree-relative fallback."""
    monkeypatch.delenv("SIGNALBOX_VAULT", raising=False)

    with pytest.raises(VaultMissing):
        vault_dir()
    assert "#70" in (VaultMissing.__doc__ or "")


def test_vault_dir_refuses_relative_configuration(monkeypatch, tmp_path):
    """Even an existing relative directory would put notes under the agent cwd."""
    relative_vault = tmp_path / "docs" / "vault"
    relative_vault.mkdir(parents=True)
    monkeypatch.chdir(tmp_path)
    monkeypatch.setenv("SIGNALBOX_VAULT", "docs/vault")

    with pytest.raises(VaultMissing, match="not an absolute path"):
        vault_dir()


def test_vault_dir_refuses_a_non_directory(monkeypatch, tmp_path):
    """Incident #70 requires resolving a real external vault directory."""
    not_a_directory = tmp_path / "file"
    not_a_directory.write_text("not a vault")
    monkeypatch.setenv("SIGNALBOX_VAULT", str(not_a_directory))

    with pytest.raises(VaultMissing):
        vault_dir()


def test_vault_skills_require_the_stamped_vault_and_carry_warnings():
    """Vault instructions retain the .claude/ guard without a relative fallback."""
    for skill in ("signalbox-plan-notes", "signalbox-write-note"):
        path = SKILLS / skill / "SKILL.md"
        body = path.read_text()
        assert "docs/vault" not in body, f"{skill} retains the discarded fallback"
        assert "$SIGNALBOX_VAULT" in body, f"{skill} does not name the stamped vault"
        assert ".claude/" in body, f"{skill} does not warn about .claude/"
        description = _frontmatter(path).get("description", "").lower()
        assert "merged" not in description, f"{skill} claims the pull request merged"
        assert "landed" not in description, f"{skill} claims the change landed"

    write_note = (SKILLS / "signalbox-write-note" / "SKILL.md").read_text()
    assert "Do not commit." in write_note
    assert "A later step handles that" not in write_note
