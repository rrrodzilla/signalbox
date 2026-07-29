"""Shape B: dispatch a working agent that announces as it goes.

Implementation is the one place a model genuinely acts on the world, and a
single event thirty minutes later would be a thirty-minute hole where nothing is
observable, resumable, or reactive. So the agent re-enters through the control
endpoint: every file it writes is an event, which is what lets the scope guard
fire mid-implementation rather than at review.

Because an exec-sink discards output, an agent that dies silently would produce
nothing at all. The pending marker written here is what the reaper scans, so
silence has a name.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

from signalbox.paths import state_dir, worktree_for



def pending_path(kind: str, payload: dict) -> Path:
    key = payload.get("shard_id") or payload.get("run_id") or "unknown"
    return state_dir() / "pending" / f"{kind}-{key}.json"


def environment(payload: dict, base: dict[str, str]) -> dict[str, str]:
    """The identity an agent's `signalbox emit` will read back.

    Passing identity through the environment rather than the prompt is what
    makes it unspoofable: the agent never types these values, so it cannot get
    them wrong or change them.
    """
    env = dict(base)
    env.update(
        {
            "SIGNALBOX_RUN_ID": str(payload.get("run_id", "")),
            "SIGNALBOX_REPO": str(payload.get("repo", "")),
            "SIGNALBOX_ISSUE": str(payload.get("issue", "")),
            "SIGNALBOX_STAGE_ID": str(payload.get("stage_id", "")),
            "SIGNALBOX_SHARD_ID": str(payload.get("shard_id", "")),
            "SIGNALBOX_SHARD_COUNT": str(payload.get("shard_count", "")),
            "SIGNALBOX_ROUND": str(payload.get("round", 1)),
            "SIGNALBOX_DECLARED": json.dumps(payload.get("declared") or []),
        }
    )
    return env


def prompt_for(skill: str, payload: dict) -> str:
    return (
        f"Load the {skill} skill and follow it exactly.\n\n"
        f"Work item:\n{json.dumps(payload, indent=2)}\n\n"
        "Announce your progress with `signalbox emit` as you work. That is the "
        "only way anything outside this session learns what you did. Do not "
        "commit, merge, review your own work, or take any action beyond the "
        "files this shard declares."
    )


def main(argv: list[str]) -> int:
    import argparse

    parser = argparse.ArgumentParser(prog="signalbox dispatch")
    parser.add_argument("--skill", required=True)
    parser.add_argument("--model", default=os.environ.get("SIGNALBOX_MODEL", "opus"))
    args = parser.parse_args(argv)

    raw = sys.stdin.read()
    try:
        payload = json.loads(raw) if raw.strip() else {}
    except json.JSONDecodeError as exc:
        print(f"signalbox dispatch: unreadable payload: {exc}", file=sys.stderr)
        return 1

    marker = pending_path("shard", payload)
    marker.parent.mkdir(parents=True, exist_ok=True)
    marker.write_text(json.dumps(payload))

    try:
        completed = subprocess.run(
            [
                "claude",
                "-p",
                prompt_for(args.skill, payload),
                "--model",
                args.model,
                "--allowedTools",
                "Read", "Grep", "Glob", "Write", "Edit", "Bash", "Skill",
            ],
            cwd=str(worktree_for(payload)),
            env=environment(payload, dict(os.environ)),
            capture_output=True,
            text=True,
            check=False,
        )
        if completed.returncode != 0:
            print(completed.stderr.strip()[:2000], file=sys.stderr)
            return completed.returncode
    finally:
        # The marker stays if we die here; that is the point. Only a shard that
        # announced a terminal verdict clears it, and the reaper finds the rest.
        pass
    return 0
