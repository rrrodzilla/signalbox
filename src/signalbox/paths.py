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


def install_skills(worktree: Path) -> list[str]:
    """Make the skills discoverable to agents working in this worktree.

    Claude Code resolves skills from the project it is running in, and every
    agent runs with the worktree as its working directory, so the skills have
    to be there. They are untracked and no shard declares them, so the merge
    step cannot commit them into the target repository.
    """
    source = skills_dir()
    if not source.is_dir():
        return []
    target = worktree / ".claude" / "skills"
    target.mkdir(parents=True, exist_ok=True)
    installed = []
    for skill in sorted(source.iterdir()):
        if not (skill / "SKILL.md").is_file():
            continue
        shutil.copytree(skill, target / skill.name, dirs_exist_ok=True)
        installed.append(skill.name)
    return installed
