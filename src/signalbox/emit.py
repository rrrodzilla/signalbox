"""The announce tool a working agent calls.

This is the whole action space of an implementing agent. It writes code, and it
says what it did; it cannot merge, approve, advance a stage, or decide what
happens next, because none of those are events it can emit.

Identity comes from the environment the dispatcher set, never from arguments, so
an agent cannot claim a different shard or widen its own declared scope.
"""

from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request

ALLOWED_EVENTS = frozenset(
    {"shard.file-written", "shard.check-ran", "shard.submitted"}
)

_ENV_KEYS = {
    "run_id": "SIGNALBOX_RUN_ID",
    "repo": "SIGNALBOX_REPO",
    "issue": "SIGNALBOX_ISSUE",
    "stage_id": "SIGNALBOX_STAGE_ID",
    "shard_id": "SIGNALBOX_SHARD_ID",
    "shard_count": "SIGNALBOX_SHARD_COUNT",
    "round": "SIGNALBOX_ROUND",
}


def control_url() -> str:
    return os.environ.get("SIGNALBOX_CONTROL_URL", "http://127.0.0.1:8100/emit")


def identity_from_env(env: dict[str, str]) -> dict:
    """Read the identity the dispatcher stamped into the environment."""
    identity: dict = {}
    for field, var in _ENV_KEYS.items():
        value = env.get(var)
        if value in (None, ""):
            continue
        identity[field] = int(value) if field in {"shard_count", "round", "issue"} and value.isdigit() else value

    declared = env.get("SIGNALBOX_DECLARED")
    if declared:
        try:
            identity["declared"] = json.loads(declared)
        except json.JSONDecodeError:
            identity["declared"] = [p for p in declared.split(os.pathsep) if p]

    # http-source stamps no correlation, so the agent carries the parent's.
    correlation = env.get("EMERGENT_CORRELATION_ID")
    if correlation:
        identity["correlation_id"] = correlation
    return identity


def build_body(event: str, fields: dict, env: dict[str, str]) -> dict:
    """The POST body: the agent's fields, with our identity layered on top."""
    return {**fields, **identity_from_env(env), "event": event}


def parse_fields(pairs: list[str]) -> dict:
    """`--field k=v` pairs, with JSON values decoded when they parse as JSON."""
    fields: dict = {}
    for pair in pairs:
        key, _, raw = pair.partition("=")
        if not key or not _:
            raise ValueError(f"malformed --field {pair!r}, expected key=value")
        try:
            fields[key] = json.loads(raw)
        except json.JSONDecodeError:
            fields[key] = raw
    return fields


def post(body: dict, url: str | None = None, timeout: float = 10.0) -> int:
    request = urllib.request.Request(
        url or control_url(),
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.status


def main(argv: list[str]) -> int:
    import argparse

    parser = argparse.ArgumentParser(prog="signalbox emit")
    parser.add_argument("event", help=f"one of: {', '.join(sorted(ALLOWED_EVENTS))}")
    parser.add_argument("--field", action="append", default=[], metavar="KEY=VALUE")
    args = parser.parse_args(argv)

    if args.event not in ALLOWED_EVENTS:
        print(
            f"signalbox emit: {args.event!r} is not an event you may announce. "
            f"Allowed: {', '.join(sorted(ALLOWED_EVENTS))}",
            file=sys.stderr,
        )
        return 2

    try:
        fields = parse_fields(args.field)
    except ValueError as exc:
        print(f"signalbox emit: {exc}", file=sys.stderr)
        return 2

    body = build_body(args.event, fields, dict(os.environ))
    try:
        post(body)
    except (urllib.error.URLError, OSError) as exc:
        print(f"signalbox emit: control endpoint unreachable: {exc}", file=sys.stderr)
        return 1
    return 0
