"""Shape A: a model produces exactly one verdict, and stops.

The model's whole job is to print one JSON object describing what it concluded.
It does not choose what happens next — the routers in the topology turn one
verdict type into the domain vocabulary, and adding an outcome is a new router
plus a line in a skill, not a change here.

Whatever the model prints, identity is re-stamped from the inbound envelope
before publishing, so a verdict can never move itself to a different shard.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time

from signalbox.dispatch import environment
from signalbox.diagnostics import invocation_diagnostic
from signalbox.emit import post_provenance
from signalbox.identity import carry, spoofed_keys
from signalbox.paths import (
    VaultMissing,
    WorktreeMissing,
    recall_vault_dir,
    require_worktree,
    vault_dir,
)

# Each role is a skill, so the procedure is versioned and reviewable on its own
# rather than living in an argv string.
ROLE_SKILLS = {
    "plan": "signalbox-plan",
    "audit": "signalbox-audit-plan",
    "review": "signalbox-review",
    "assess": "signalbox-assess",
    "plan-notes": "signalbox-plan-notes",
    "write-note": "signalbox-write-note",
}

# Which CLI renders each judgment. Everything runs on Claude except the plan
# audit, which runs on codex on purpose: an auditor sharing a drafter's model
# shares its blind spots, and a plan reviewed by the family that wrote it agrees
# with itself. `signalbox-survey` and `signalbox-recall` are no longer roles —
# they are skills the planning agent's own subagents load, which is why they
# still exist on disk with nothing in this map pointing at them.
ROLE_RUNNERS = {"audit": "codex"}
DEFAULT_ROLE_RUNNER = "claude"

READ_ONLY_ROLES = frozenset({"plan", "audit", "review", "assess", "plan-notes"})
NOTES_ROLES = frozenset({"plan-notes", "write-note"})
# Planning absorbed recall, so planning is what needs the vault now. It reads
# through `recall_vault_dir`, not `vault_dir`: an operator with no vault gets a
# run without recalled context, never a run that cannot start.
VAULT_ROLES = NOTES_ROLES | {"plan"}

# Which model renders each judgment. This is a property of the role, not of the
# run, because the judgments differ in kind. Planning and assessing get the
# strongest reasoning: the plan fixes stage boundaries and file-disjointness for
# everything downstream, and the assessment decides whether a run is fit to
# promote or belongs in front of a human. Reviewing judges one shard against one
# intent, so it works at a narrower scope. Note writing is transcription of
# decisions already made.
#
# `audit` is None for the same reason dispatch leaves codex unpinned: a runner
# that ships its own default model should keep owning it, and a Claude alias in
# a codex argv fails at the least convenient moment.
ROLE_MODELS: dict[str, str | None] = {
    "plan": "fable",
    "audit": None,
    "review": "opus",
    "assess": "fable",
    "plan-notes": "sonnet",
    "write-note": "sonnet",
}

# The successful output topic owned by each model-bearing topology role.
# Acting roles produce their topic through `signalbox emit`; judging roles have
# their stdout wrapped by exec-handler.  Keeping both shapes in one map lets the
# topology assert that every produced event has an invocation provenance edge.
ROLE_PRODUCED_TOPICS = {
    "plan": "plan.submitted",
    "audit": "plan.audited",
    "review": "review.submitted",
    "assess": "gate.assessed",
    "plan-notes": "notes.planned",
    "write-note": "note.written",
    "implement": "shard.submitted",
    "fix": "shard.submitted",
}


def model_env_var(role: str) -> str:
    return f"SIGNALBOX_MODEL_{role.upper().replace('-', '_')}"


def runner_for(role: str, env: dict[str, str] | None = None) -> str:
    env = os.environ if env is None else env
    return env.get("SIGNALBOX_RUNNER") or ROLE_RUNNERS.get(role, DEFAULT_ROLE_RUNNER)


def model_for(role: str, env: dict[str, str] | None = None) -> str | None:
    """The model for a role: per-role override, then global override, then map.

    The global override exists so a whole run can be pinned to one model while
    diagnosing a behaviour, without editing the map. `SIGNALBOX_MODEL` is a
    Claude alias by construction, so it must not reach a codex role — the same
    separation dispatch keeps between its two runners.
    """
    env = os.environ if env is None else env
    if runner_for(role, env) == "codex":
        return env.get("SIGNALBOX_CODEX_MODEL") or ROLE_MODELS[role]
    return env.get(model_env_var(role)) or env.get("SIGNALBOX_MODEL") or ROLE_MODELS[role]


def extract_verdict(stdout: str) -> dict | None:
    """The last complete JSON object in the output, or None.

    Models narrate. Rather than trusting them not to, take the last balanced
    object; if there is none, the caller publishes an invalid-verdict event and
    the topology deals with it as data.
    """
    depth = 0
    start = None
    candidates: list[str] = []
    in_string = False
    escaped = False

    for index, char in enumerate(stdout):
        if in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
            continue
        if char == '"':
            in_string = True
        elif char == "{":
            if depth == 0:
                start = index
            depth += 1
        elif char == "}":
            if depth:
                depth -= 1
                if depth == 0 and start is not None:
                    candidates.append(stdout[start : index + 1])

    for blob in reversed(candidates):
        try:
            parsed = json.loads(blob)
        except json.JSONDecodeError:
            continue
        if isinstance(parsed, dict):
            return parsed
    return None


def prompt_for(role: str, payload: dict) -> str:
    skill = ROLE_SKILLS[role]
    return (
        f"Load the {skill} skill and follow it exactly.\n\n"
        f"Input payload:\n{json.dumps(payload, indent=2)}\n\n"
        "Print exactly one JSON object on stdout and nothing else. "
        "Do not print prose before or after it."
    )


def codex_prompt_for(role: str, payload: dict) -> str:
    """The same instruction in codex's mention syntax.

    Codex resolves a `$name` mention against `.codex/skills/`, so both runners
    read the one SKILL.md rather than two copies that can drift.
    """
    skill = ROLE_SKILLS[role]
    return (
        f"Follow the ${skill} skill exactly.\n\n"
        f"Input payload:\n{json.dumps(payload, indent=2)}\n\n"
        "Print exactly one JSON object as your final message and nothing else. "
        "Do not print prose before or after it. Read only: do not edit, write, "
        "or commit anything, and take no action beyond rendering the verdict."
    )


def tools_for(role: str) -> list[str]:
    # Planning fans out into its own subagents to survey the tree and read the
    # vault, which is what the topology used to do with two roles and a join.
    if role == "plan":
        return ["Read", "Grep", "Glob", "Skill", "Bash", "Agent"]
    if role in READ_ONLY_ROLES:
        return ["Read", "Grep", "Glob", "Skill", "Bash"]
    return ["Read", "Grep", "Glob", "Skill", "Bash", "Write", "Edit"]


def codex_command(worktree: str, model: str | None) -> list[str]:
    """Codex as a judging agent: read-only, non-interactive, no approvals.

    The read-only sandbox is what makes this Shape A rather than Shape B. An
    auditor that could write would be able to fix what it objects to, and the
    objection would stop being a verdict the topology can route.
    """
    command = [
        "codex",
        "exec",
        "-C",
        worktree,
        "--sandbox",
        "read-only",
        "-c",
        'approval_policy="never"',
    ]
    if model:
        command += ["--model", model]
    # `-` reads the prompt from stdin, keeping the payload out of every process
    # listing on the box.
    return command + ["-"]


def _workdir(payload: dict) -> str:
    """Judging agents read the run's worktree, and nothing else.

    It is also where the skills were installed, so this is what makes them
    resolvable at all. Raises rather than defaulting: a judgment rendered
    against the wrong repository is worse than no judgment.
    """
    return str(require_worktree(payload))


def run(role: str, payload: dict, model: str | None = None) -> tuple[dict, int]:
    """Invoke the model and return (verdict, exit_code).

    Notes roles receive the resolved vault explicitly so incident #70 cannot
    recur through an inherited environment or a path relative to the worktree.
    """
    runner = runner_for(role)
    invoked_model = model if model is not None else model_for(role)
    workdir = _workdir(payload)
    subprocess_kwargs: dict = {}

    # Resolved before either command is built. `--add-dir` is a Claude flag and
    # a codex argv ends in the `-` that makes it read stdin, so appending to
    # whichever command happens to exist would silently corrupt one of them.
    vault = None
    if role in VAULT_ROLES:
        vault = vault_dir() if role in NOTES_ROLES else recall_vault_dir()
        subprocess_kwargs["env"] = {
            **os.environ,
            "SIGNALBOX_VAULT": "" if vault is None else str(vault),
        }

    if runner == "codex":
        command = codex_command(workdir, invoked_model)
        stdin_text = codex_prompt_for(role, payload)
    else:
        command = ["claude", "-p", prompt_for(role, payload)]
        if invoked_model:
            command += ["--model", invoked_model]
        command += ["--allowedTools", *tools_for(role)]
        if vault is not None:
            command += ["--add-dir", str(vault)]
        stdin_text = ""

    started = time.monotonic()
    completed = subprocess.run(
        command,
        cwd=workdir,
        input=stdin_text,
        capture_output=True,
        text=True,
        check=False,
        **subprocess_kwargs,
    )
    duration_ms = round((time.monotonic() - started) * 1000)
    post_provenance(
        role,
        runner,
        invoked_model,
        ROLE_PRODUCED_TOPICS[role],
        completed.returncode == 0,
        duration_ms,
        invocation_diagnostic(completed, command),
        env=environment(payload, dict(os.environ)),
    )
    if completed.returncode != 0:
        print(completed.stderr.strip()[:2000], file=sys.stderr)
        return {}, completed.returncode

    verdict = extract_verdict(completed.stdout)
    if verdict is None:
        # Not an error: an unparseable verdict is data the routers can see.
        return carry(payload, {"verdict": "unparseable", "output": completed.stdout[-2000:]}), 0

    spoofed = spoofed_keys(payload, verdict)
    result = carry(payload, verdict)
    if spoofed:
        result["identity_overridden"] = spoofed
    return result, 0


def main(argv: list[str]) -> int:
    if not argv or argv[0] not in ROLE_SKILLS:
        print(
            f"signalbox agent: role must be one of {', '.join(sorted(ROLE_SKILLS))}",
            file=sys.stderr,
        )
        return 2
    role = argv[0]

    raw = sys.stdin.read()
    try:
        payload = json.loads(raw) if raw.strip() else {}
    except json.JSONDecodeError as exc:
        print(f"signalbox agent: unreadable payload: {exc}", file=sys.stderr)
        return 1

    try:
        verdict, code = run(role, payload)
    except (VaultMissing, WorktreeMissing) as exc:
        print(f"signalbox agent: {exc}", file=sys.stderr)
        return 1
    if code != 0:
        return code
    print(json.dumps(verdict))
    return 0
