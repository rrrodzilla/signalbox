"""Where a run's files live.

Shared by the dispatcher, the judging agents, and the I/O acts so all three
agree on one worktree per run without any of them owning the answer.
"""

from __future__ import annotations

import os
import shutil
from pathlib import Path


def state_dir() -> Path:
    root = os.environ.get(
        "SIGNALBOX_STATE",
        os.path.join(
            os.environ.get("XDG_STATE_HOME", os.path.expanduser("~/.local/state")),
            "signalbox",
        ),
    )
    return Path(root)


def worktree_for(payload: dict) -> Path:
    return state_dir() / "worktrees" / str(payload.get("run_id", "unknown"))


def branch_for(payload: dict) -> str:
    return f"signalbox/run-{payload.get('run_id', 'unknown')}"


def skills_dir() -> Path:
    """The skills this installation ships.

    Resolved from the package location so an editable install picks up edits
    immediately, which matters because a stale skill fails as an unparseable
    verdict rather than an error.
    """
    override = os.environ.get("SIGNALBOX_SKILLS")
    if override:
        return Path(override)
    return Path(__file__).resolve().parent.parent.parent / "skills"


class VaultMissing(RuntimeError):
    """The operator-configured notes vault is absent.

    Never fall back to a path inside the disposable worktree. In incident #70,
    notes were written under a relative ``docs/vault/`` fallback and then
    discarded by ``release_workspace``.
    """


def vault_dir() -> Path:
    """The configured absolute notes vault, or an error if it is not a directory."""
    configured = os.environ.get("SIGNALBOX_VAULT")
    if not configured:
        raise VaultMissing("SIGNALBOX_VAULT is not configured")
    path = Path(configured)
    if not path.is_absolute():
        raise VaultMissing(f"SIGNALBOX_VAULT is not an absolute path: {path}")
    if not path.is_dir():
        raise VaultMissing(f"SIGNALBOX_VAULT is not a directory: {path}")
    return path


# Where each runner looks for project skills, relative to the working
# directory. Both discover by scanning; neither reads the other's directory, so
# a skill has to be installed once per runner. Verified empirically: a skill in
# `.codex/skills/` is listed by codex and one in `.claude/skills/` is not.
SKILL_ROOTS = {
    "claude": Path(".claude") / "skills",
    "codex": Path(".codex") / "skills",
}


def install_skills(worktree: Path) -> list[str]:
    """Make the skills discoverable to agents working in this worktree.

    Both runners resolve skills from the project they are running in, and every
    agent runs with the worktree as its working directory, so the skills have to
    be there. Installing into every root rather than the one we expect to use
    means a runner swap is a one-line change and not a silent loss of procedure.

    They are untracked and no shard declares them, so the merge step cannot
    commit them into the target repository.
    """
    source = skills_dir()
    if not source.is_dir():
        return []
    targets = [worktree / root for root in SKILL_ROOTS.values()]
    for target in targets:
        target.mkdir(parents=True, exist_ok=True)
    installed = []
    for skill in sorted(source.iterdir()):
        if not (skill / "SKILL.md").is_file():
            continue
        for target in targets:
            shutil.copytree(skill, target / skill.name, dirs_exist_ok=True)
        installed.append(skill.name)
    return installed


class SkillMissing(RuntimeError):
    """A skill is not where the runner about to be launched will look.

    Raised rather than dispatching anyway: an acting agent with no procedure
    still edits files, and it edits them by improvisation.
    """


def require_skill(worktree: Path, runner: str, name: str) -> Path:
    """The installed skill a runner will resolve, or an error saying it will not.

    Nothing about a missing skill is visible at runtime — the agent is simply
    handed a name that resolves to nothing and proceeds on its own judgment. So
    the check happens here, before the process starts.
    """
    try:
        root = SKILL_ROOTS[runner]
    except KeyError as exc:
        raise SkillMissing(f"no skill root known for runner {runner!r}") from exc
    path = worktree / root / name
    if not (path / "SKILL.md").is_file():
        raise SkillMissing(
            f"{runner} will not find skill {name!r}: no SKILL.md at {path}"
        )
    return path


class WorktreeMissing(RuntimeError):
    """The run's worktree is absent.

    Never degrade to the current directory when this happens. An agent that
    falls back to wherever the engine happens to be running reads and judges a
    completely different repository, and reports confidently about it — which
    is exactly what happened before this existed.
    """


def require_worktree(payload: dict) -> Path:
    tree = worktree_for(payload)
    if not tree.is_dir():
        raise WorktreeMissing(
            f"no worktree for run {payload.get('run_id')!r} at {tree}; "
            "refusing to operate on another directory"
        )
    return tree
