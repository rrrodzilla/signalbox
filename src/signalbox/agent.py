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
from signalbox.emit import post_provenance
from signalbox.identity import carry, spoofed_keys
from signalbox.paths import WorktreeMissing, require_worktree

# Each role is a skill, so the procedure is versioned and reviewable on its own
# rather than living in an argv string.
ROLE_SKILLS = {
    "survey": "signalbox-survey",
    "plan": "signalbox-plan",
    "review": "signalbox-review",
    "assess": "signalbox-assess",
    "plan-notes": "signalbox-plan-notes",
    "write-note": "signalbox-write-note",
}

READ_ONLY_ROLES = frozenset({"survey", "plan", "review", "assess", "plan-notes"})

# Which model renders each judgment. This is a property of the role, not of the
# run, because the judgments differ in kind. Planning and assessing get the
# strongest reasoning: the plan fixes stage boundaries and file-disjointness for
# everything downstream, and the assessment decides whether a run is fit to
# promote or belongs in front of a human. Surveying is breadth-first reading and
# reviewing judges one shard against one intent, so both work at a narrower
# scope. Note writing is transcription of decisions already made.
ROLE_MODELS = {
    "survey": "opus",
    "plan": "fable",
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
    "survey": "codebase.surveyed",
    "plan": "plan.submitted",
    "review": "review.submitted",
    "assess": "gate.assessed",
    "plan-notes": "notes.planned",
    "write-note": "note.written",
    "implement": "shard.submitted",
    "fix": "shard.submitted",
}


def model_env_var(role: str) -> str:
    return f"SIGNALBOX_MODEL_{role.upper().replace('-', '_')}"


def model_for(role: str, env: dict[str, str] | None = None) -> str:
    """The model for a role: per-role override, then global override, then map.

    The global override exists so a whole run can be pinned to one model while
    diagnosing a behaviour, without editing the map.
    """
    env = os.environ if env is None else env
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


def tools_for(role: str) -> list[str]:
    if role in READ_ONLY_ROLES:
        return ["Read", "Grep", "Glob", "Skill", "Bash"]
    return ["Read", "Grep", "Glob", "Skill", "Bash", "Write", "Edit"]


def _workdir(payload: dict) -> str:
    """Judging agents read the run's worktree, and nothing else.

    It is also where the skills were installed, so this is what makes them
    resolvable at all. Raises rather than defaulting: a judgment rendered
    against the wrong repository is worse than no judgment.
    """
    return str(require_worktree(payload))


def run(role: str, payload: dict, model: str | None = None) -> tuple[dict, int]:
    """Invoke the model and return (verdict, exit_code)."""
    invoked_model = model or model_for(role)
    started = time.monotonic()
    completed = subprocess.run(
        [
            "claude",
            "-p",
            prompt_for(role, payload),
            "--model",
            invoked_model,
            "--allowedTools",
            *tools_for(role),
        ],
        cwd=_workdir(payload),
        capture_output=True,
        text=True,
        check=False,
    )
    duration_ms = round((time.monotonic() - started) * 1000)
    post_provenance(
        role,
        "claude",
        invoked_model,
        ROLE_PRODUCED_TOPICS[role],
        completed.returncode == 0,
        duration_ms,
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
    except WorktreeMissing as exc:
        print(f"signalbox agent: {exc}", file=sys.stderr)
        return 1
    if code != 0:
        return code
    print(json.dumps(verdict))
    return 0
