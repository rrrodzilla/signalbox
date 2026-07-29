"""Shape B: dispatch a working agent that announces as it goes.

Implementation is the one place a model genuinely acts on the world, and a
single event thirty minutes later would be a thirty-minute hole where nothing is
observable, resumable, or reactive. So the agent re-enters through the control
endpoint: every file it writes is an event, which is what lets the scope guard
fire mid-implementation rather than at review.

Because an exec-sink discards output, an agent that dies silently would produce
nothing at all. The pending marker written here is what the reaper scans, so
silence has a name.

Two runners can do the acting. The topology does not know which, and neither
does anything downstream: whichever one runs, its only way to be heard is
`signalbox emit`, and the events it emits are identical. Both resolve the same
SKILL.md by name from the worktree, so the procedure is one reviewable file and
not two copies that can drift.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from pathlib import Path

from signalbox.emit import post_provenance
from signalbox.paths import SkillMissing, require_skill, state_dir, worktree_for

# Which CLI performs each acting skill. Implementation and fix run on codex;
# the judging roles in agent.py run on Claude. Both are just processes that
# announce through the control endpoint, so this is a swap, not a fork in the
# design.
SKILL_RUNNERS = {
    "signalbox-implement": "codex",
    "signalbox-fix": "codex",
}
DEFAULT_RUNNER = "claude"

# Left unset for codex so its own configured default model applies; a runner
# that ships its own default should keep owning it.
RUNNER_MODELS: dict[str, str | None] = {
    "codex": None,
    "claude": "sonnet",
}

# Deliberately one variable per runner rather than one global. Model names are
# not portable between them, so a single SIGNALBOX_MODEL would put a Claude
# alias in a codex argv and fail at the least convenient moment.
RUNNER_MODEL_VARS = {
    "codex": "SIGNALBOX_CODEX_MODEL",
    "claude": "SIGNALBOX_MODEL",
}

CLAUDE_TOOLS = ("Read", "Grep", "Glob", "Write", "Edit", "Bash", "Skill")


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
            "SIGNALBOX_BASE_SHA": str(payload.get("base_sha", "")),
            # The promote path opens the PR against this. Dropped here, it is gone
            # by `shard.submitted` and `open-pr` has nothing to target.
            "SIGNALBOX_BASE_BRANCH": str(payload.get("base_branch", "")),
            "SIGNALBOX_STAGE_ID": str(payload.get("stage_id", "")),
            "SIGNALBOX_SHARD_ID": str(payload.get("shard_id", "")),
            "SIGNALBOX_SHARD_COUNT": str(payload.get("shard_count", "")),
            # Both join counts have to survive the agent's emit. Whichever one is
            # missing, the join it feeds waits forever.
            "SIGNALBOX_STAGE_COUNT": str(payload.get("stage_count", "")),
            "SIGNALBOX_ROUND": str(payload.get("round", 1)),
            "SIGNALBOX_DECLARED": json.dumps(payload.get("declared") or []),
        }
    )
    return env


def runner_for(skill: str, env: dict[str, str] | None = None) -> str:
    env = os.environ if env is None else env
    return env.get("SIGNALBOX_RUNNER") or SKILL_RUNNERS.get(skill, DEFAULT_RUNNER)


def model_for(runner: str, env: dict[str, str] | None = None) -> str | None:
    env = os.environ if env is None else env
    override = RUNNER_MODEL_VARS.get(runner)
    return (env.get(override) if override else None) or RUNNER_MODELS.get(runner)


def prompt_for(skill: str, payload: dict) -> str:
    """The prompt for a runner that can load skills by name."""
    return (
        f"Load the {skill} skill and follow it exactly.\n\n"
        f"Work item:\n{json.dumps(payload, indent=2)}\n\n"
        "Announce your progress with `signalbox emit` as you work. That is the "
        "only way anything outside this session learns what you did. Do not "
        "commit, merge, review your own work, or take any action beyond the "
        "files this shard declares."
    )


def codex_prompt(skill: str, payload: dict) -> str:
    """The same instruction, in codex's mention syntax.

    Codex discovers project skills from `.codex/skills/` and resolves a
    `$name` mention against them, so the procedure is referenced rather than
    inlined — the same SKILL.md both runners read, named the same way.
    """
    return (
        f"Follow the ${skill} skill exactly.\n\n"
        f"Work item:\n{json.dumps(payload, indent=2)}\n\n"
        "Announce your progress by running `signalbox emit` as you work. That is "
        "the only way anything outside this session learns what you did; nothing "
        "reads your final message. Your identity is already in the environment "
        "(SIGNALBOX_RUN_ID, SIGNALBOX_SHARD_ID, SIGNALBOX_ROUND and the rest), so "
        "never pass those on the command line. Do not commit, merge, review your "
        "own work, push, open a pull request, or touch any file this shard does "
        "not declare."
    )


def claude_command(skill: str, payload: dict, model: str | None) -> list[str]:
    command = ["claude", "-p", prompt_for(skill, payload)]
    if model:
        command += ["--model", model]
    return command + ["--allowedTools", *CLAUDE_TOOLS]


def codex_command(worktree: Path, model: str | None) -> list[str]:
    """Codex, non-interactive, writing only inside the run's worktree.

    The sandbox is what bounds an acting agent here, in place of Claude Code's
    tool allowlist. Two settings are load-bearing and neither is a default:
    loopback network access, without which `signalbox emit` cannot reach the
    control endpoint and the whole run goes silent; and inheriting the full
    environment, without which the identity variables never reach the shell
    commands the model runs, which is the same silence with a different cause.
    """
    command = [
        "codex",
        "exec",
        "-C",
        str(worktree),
        "--sandbox",
        "workspace-write",
        "-c",
        "sandbox_workspace_write.network_access=true",
        "-c",
        'shell_environment_policy.inherit="all"',
        "-c",
        'approval_policy="never"',
    ]
    if model:
        command += ["--model", model]
    # `-` makes codex read the prompt from stdin, which keeps the work item off
    # the command line where it would show up in every process listing.
    return command + ["-"]


def main(argv: list[str]) -> int:
    import argparse

    parser = argparse.ArgumentParser(prog="signalbox dispatch")
    parser.add_argument("--skill", required=True)
    parser.add_argument("--runner", default=None)
    parser.add_argument("--model", default=None)
    args = parser.parse_args(argv)

    raw = sys.stdin.read()
    try:
        payload = json.loads(raw) if raw.strip() else {}
    except json.JSONDecodeError as exc:
        print(f"signalbox dispatch: unreadable payload: {exc}", file=sys.stderr)
        return 1

    runner = args.runner or runner_for(args.skill)
    model = args.model or model_for(runner)
    worktree = worktree_for(payload)

    if runner not in ("codex", "claude"):
        print(f"signalbox dispatch: unknown runner {runner!r}", file=sys.stderr)
        return 2

    # A skill the runner cannot see produces no error of its own: the agent is
    # handed a name that resolves to nothing and improvises. Fail loudly instead.
    try:
        require_skill(worktree, runner, args.skill)
    except SkillMissing as exc:
        print(f"signalbox dispatch: {exc}", file=sys.stderr)
        return 1

    if runner == "codex":
        command = codex_command(worktree, model)
        stdin_text = codex_prompt(args.skill, payload)
    else:
        command = claude_command(args.skill, payload, model)
        # The sink already closed our stdin; hand the child an empty one rather
        # than a spent pipe.
        stdin_text = ""

    marker = pending_path("shard", payload)
    marker.parent.mkdir(parents=True, exist_ok=True)
    marker.write_text(json.dumps({**payload, "runner": runner, "model": model}))

    invocation_env = environment(payload, dict(os.environ))
    started = time.monotonic()
    completed = subprocess.run(
        command,
        cwd=str(worktree),
        env=invocation_env,
        input=stdin_text,
        capture_output=True,
        text=True,
        check=False,
    )
    duration_ms = round((time.monotonic() - started) * 1000)
    post_provenance(
        args.skill.removeprefix("signalbox-"),
        runner,
        model,
        "shard.submitted",
        completed.returncode == 0,
        duration_ms,
        env=invocation_env,
    )
    # The marker stays whatever happens; that is the point. Only a shard that
    # announced a terminal verdict clears it, and the reaper finds the rest.
    if completed.returncode != 0:
        print(completed.stderr.strip()[:2000], file=sys.stderr)
        return completed.returncode
    return 0
