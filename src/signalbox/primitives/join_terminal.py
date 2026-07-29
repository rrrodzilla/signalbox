"""Wait for N terminal outcomes sharing a key, then publish one event.

The file-based shell join in the patterns reference is not crash-safe and never
expires a partial join. Here a lost shard result would strand a run, so this is
the honest version: an accumulator with a real timeout, which is one of the few
things worth writing custom code for.

Two properties keep it from stalling:

  * It subscribes to *every* terminal outcome, not just the happy one, so a
    shard that was abandoned, escalated, or reaped still closes its stage.
  * A partial join publishes anyway once the timeout elapses, marked
    `timed_out`, so downstream sees a stage that failed rather than silence.

Outcomes are read from an `outcome` field the routers stamp. This primitive
never infers meaning from a topic name.
"""

from __future__ import annotations

import argparse
import asyncio
import os
import sys
from dataclasses import dataclass, field
from typing import Awaitable, Callable


@dataclass
class Pending:
    expected: int | None
    results: list[dict] = field(default_factory=list)
    timer: asyncio.Task | None = None


def expected_count(payload: dict, count_field: str) -> int | None:
    """How many outcomes this key is waiting for, or None if unstated."""
    try:
        count = int(payload.get(count_field))
    except (TypeError, ValueError):
        return None
    return count if count > 0 else None


# What a joined item may be asked about. A join is used at three levels — shards
# into a stage, stages into a run, notes into a set — so the item's shape is not
# knowable here. Report the keys it actually has.
ITEM_KEYS = (
    "stage_id", "shard_id", "note", "round", "outcome", "declared",
    "files", "sha", "ok",
)


def summarise_item(item: dict) -> dict:
    """One joined item, described by the keys it actually carries.

    A fixed shard-shaped template was wrong for the run-level join, whose items
    are stages. Every shard field came back null and `outcome` came back the
    fabricated string "unknown", so `run.built` reported a run whose stages had
    all merged clean as a run with one unidentifiable result.

    That record has a consumer. The assessor reads it to verify that merged work
    stayed inside its declared scope and that each shard's review closed rather
    than being abandoned, and it cannot clear a gate on evidence it does not
    have — so it correctly sent a green, in-scope, 113-test-passing run to a
    human. The verdict was right and the record was lying.
    """
    record = {key: item[key] for key in ITEM_KEYS if key in item}
    # A stage carries its own shards' outcomes. Keep them: scope verification
    # needs the leaves, and flattening them away is what lost them.
    nested = item.get("results")
    if isinstance(nested, list) and nested:
        record["results"] = nested
    return record


def summarise(key_name: str, key_value: str, pending: Pending, timed_out: bool) -> dict:
    """The joined payload. Pure, so the interesting part is testable."""
    first = pending.results[0] if pending.results else {}
    return {
        key_name: key_value,
        "run_id": first.get("run_id"),
        "repo": first.get("repo"),
        "issue": first.get("issue"),
        "base_sha": first.get("base_sha"),
        # Carried for the same reason as base_sha: `open-pr` runs downstream of
        # this join, and a base it cannot read is a base `gh` picks instead.
        "base_branch": first.get("base_branch"),
        "stage_count": first.get("stage_count"),
        "expected": pending.expected,
        "received": len(pending.results),
        "timed_out": timed_out,
        "results": [summarise_item(item) for item in pending.results],
    }


class Joiner:
    """Accumulate outcomes by key. Publishing is injected, so this is testable."""

    def __init__(
        self,
        key: str,
        count_field: str,
        publish: Callable[[dict, object], Awaitable[None]],
        timeout: float = 3600.0,
    ):
        self.key = key
        self.count_field = count_field
        self.publish = publish
        self.timeout = timeout
        self.pending: dict[str, Pending] = {}
        self.closed: set[str] = set()

    async def _fire(self, key_value: str, cause: object, timed_out: bool) -> None:
        entry = self.pending.pop(key_value, None)
        if entry is None:
            return
        if entry.timer is not None and not entry.timer.done():
            entry.timer.cancel()
        self.closed.add(key_value)
        await self.publish(summarise(self.key, key_value, entry, timed_out), cause)

    async def _expire(self, key_value: str) -> None:
        try:
            await asyncio.sleep(self.timeout)
        except asyncio.CancelledError:
            return
        print(
            f"join: {self.key}={key_value} timed out after {self.timeout}s",
            file=sys.stderr,
        )
        await self._fire(key_value, None, timed_out=True)

    async def accept(self, payload: dict, cause: object = None) -> None:
        key_value = payload.get(self.key)
        if key_value is None:
            print(f"join: message without {self.key}, ignored", file=sys.stderr)
            return
        key_value = str(key_value)

        if key_value in self.closed:
            # A late arrival after the join already fired. Say so rather than
            # silently reopening a stage that has moved on.
            print(f"join: late arrival for {self.key}={key_value}", file=sys.stderr)
            return

        entry = self.pending.get(key_value)
        if entry is None:
            entry = Pending(expected=expected_count(payload, self.count_field))
            self.pending[key_value] = entry
            if self.timeout > 0:
                entry.timer = asyncio.create_task(self._expire(key_value))
        if entry.expected is None:
            entry.expected = expected_count(payload, self.count_field)

        entry.results.append(payload)

        if entry.expected is not None and len(entry.results) >= entry.expected:
            await self._fire(key_value, cause, timed_out=False)


def default_subscriptions(key: str) -> list[str]:
    if key == "stage_id":
        return [
            "shard.approved",
            "shard.escalated",
            "shard.abandoned",
            "shard.invalid-verdict",
            "shard.silent",
            "scope.violated",
        ]
    return ["note.written", "note.write-failed"]


def main() -> None:
    from emergent import create_message, run_handler

    parser = argparse.ArgumentParser(prog="signalbox primitive join-terminal")
    parser.add_argument("--key", required=True)
    parser.add_argument("--count-field", required=True)
    parser.add_argument("--publish-as", required=True)
    parser.add_argument("--timeout-seconds", type=float, default=3600.0)
    parser.add_argument("--subscribe", action="append", default=None)
    args = parser.parse_args()

    joiner: Joiner

    async def publish_joined(payload: dict, cause: object) -> None:
        message = create_message(args.publish_as).payload(payload)
        if cause is not None:
            message = message.caused_by(cause)
        await publish_joined.handler.publish(message)

    async def accept(msg, handler) -> None:
        publish_joined.handler = handler
        await joiner.accept(msg.payload_as(dict) or {}, msg.id)

    joiner = Joiner(args.key, args.count_field, publish_joined, args.timeout_seconds)
    subscribes = args.subscribe or default_subscriptions(args.key)
    name = os.environ.get("EMERGENT_PRIMITIVE_NAME", f"join-{args.key}")
    asyncio.run(run_handler(name, subscribes, accept))


if __name__ == "__main__":
    main()
