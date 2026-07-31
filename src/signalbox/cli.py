"""One entry point. Every subcommand is a primitive's body, nothing more.

There is deliberately no `run-pipeline` here, and no subcommand that knows the
order of phases. The order lives in emergent.toml. A conductor in this file
would be the previous implementation's central mistake, reintroduced.
"""

from __future__ import annotations

import json
import sys


# The acts, declared once so a test can compare them against what the topology
# actually calls. prepare-workspace was wired into the topology and the acts
# dispatch but missing here, and every run failed on its first step.
ACT_COMMANDS = frozenset({
    "prepare-workspace", "release-workspace", "fetch-issue", "run-suite",
    "merge-stage", "push-branch",
    "open-pr", "merge-pr", "close-issue", "check-details", "map-ci-findings", "reap",
    "mark-pending", "clear-pending", "rehydrate", "notify", "launch", "approve",
})

COMMANDS = ACT_COMMANDS | {
    "primitive", "check-plan", "agent", "dispatch", "emit", "dashboard", "paths",
    "topology-diagram",
}


def _stdin_payload() -> dict:
    raw = sys.stdin.read()
    if not raw.strip():
        return {}
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as exc:
        print(f"signalbox: unreadable payload: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
    return value if isinstance(value, dict) else {"value": value}


def _emit(payload: dict) -> int:
    print(json.dumps(payload))
    return 0


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if not argv:
        print(__doc__, file=sys.stderr)
        return 2

    command, rest = argv[0], argv[1:]

    if command == "primitive":
        return _primitive(rest)

    if command == "check-plan":
        from signalbox.plan import check_plan

        return _emit(check_plan(_stdin_payload()))

    if command == "agent":
        from signalbox import agent

        return agent.main(rest)

    if command == "dispatch":
        from signalbox import dispatch

        return dispatch.main(rest)

    if command == "emit":
        from signalbox import emit

        return emit.main(rest)

    if command == "dashboard":
        from signalbox import dashboard

        return dashboard.main(rest)

    if command == "topology-diagram":
        from signalbox import topology_diagram

        return topology_diagram.main(rest)

    if command == "paths":
        # A diagnostic, because the failure it catches is silent: a non-editable
        # install runs a stale copy of the code and skills while the source in
        # front of you reads correct.
        from signalbox.emit import control_url
        from signalbox.paths import VaultMissing, skills_dir, state_dir, vault_dir

        print(f"package  {__file__.rsplit('/', 1)[0]}")
        print(f"skills   {skills_dir()}")
        print(f"state    {state_dir()}")
        print(f"control  {control_url()}")
        try:
            vault = vault_dir()
        except VaultMissing as exc:
            print(f"signalbox paths: {exc}", file=sys.stderr)
            return 1
        print(f"vault    {vault}")
        return 0

    if command in ACT_COMMANDS:
        from signalbox import acts

        return acts.main(command, rest)

    print(f"signalbox: unknown command {command!r}", file=sys.stderr)
    return 2


def _primitive(argv: list[str]) -> int:
    if not argv:
        print("signalbox primitive: name required", file=sys.stderr)
        return 2
    name, rest = argv[0], argv[1:]

    if name == "split-shards":
        from signalbox.primitives import split_shards

        split_shards.main()
        return 0

    if name == "split-notes":
        from signalbox.primitives import split_notes

        split_notes.main()
        return 0

    if name == "join-terminal":
        from signalbox.primitives import join_terminal

        # Preserve the primitive's own argument boundary: join-terminal accepts
        # either its established --count-field mode or the topic-based --arms
        # rendezvous mode.
        sys.argv = ["signalbox primitive join-terminal", *rest]
        join_terminal.main()
        return 0

    print(f"signalbox primitive: unknown primitive {name!r}", file=sys.stderr)
    return 2
