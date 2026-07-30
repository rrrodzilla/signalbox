"""Rendezvous terminal outcomes sharing a key, then publish one event.

The file-based shell join in the patterns reference is not crash-safe and never
expires a partial join. Here a lost shard result would strand a run, so this is
the honest version: an accumulator with a real timeout, which is one of the few
things worth writing custom code for.

Two properties keep it from stalling:

  * It subscribes to *every* terminal outcome, not just the happy one, so a
    shard that was abandoned, escalated, or reaped still closes its stage.
  * A partial join publishes anyway once the timeout elapses, marked
    `timed_out`, to a neutral topic. The topology's routers decide which
    terminal outcome follows; a timer cannot assert a run terminal by itself.

Outcomes are read from an `outcome` field the routers stamp. This primitive
never infers meaning from a topic name.

A join's key must name the thing being joined *globally*, which is why `--key`
is repeatable. `run_id` is the only identity signalbox mints that is unique
across runs; `stage_id` and `shard_id` are unique only within one plan. A join
keyed on a plan-local field alone puts two concurrent runs in one bucket, fires
on whichever count armed it first, and publishes a summary mixing both runs'
items while the rest are dropped as late arrivals — silent cross-run corruption
rather than a stall. `test_every_rendezvous_is_run_scoped` enforces it.

Arms mode is the exception: it rendezvous explicitly named topics. It exists
because the zero-note path emits ``notes.synced`` directly and can re-enter.
A bare count of two would let two such events satisfy the join with no
``pr.merged`` event at all. The neutral publication still leaves the topology's
routers to decide the run terminal.
"""

from __future__ import annotations

import argparse
import asyncio
import os
import sys
from collections.abc import Sequence
from dataclasses import dataclass, field
from typing import Awaitable, Callable

from signalbox import identity


@dataclass
class Pending:
    expected: int | None
    results: list[dict] = field(default_factory=list)
    satisfied_arms: set[str] = field(default_factory=set)
    arm_payloads: dict[str, dict] = field(default_factory=dict)
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


def as_keys(key: str | Sequence[str]) -> tuple[str, ...]:
    """One key or several, always a tuple.

    A join's identity is whatever set of fields names the thing being joined.
    For a run-level join that is `run_id` alone; for a stage-level join it is
    `run_id` *and* `stage_id`, because a stage id is only unique within its own
    plan (`signalbox-plan/SKILL.md`: "unique across the whole plan"). Keyed on
    `stage_id` alone, two concurrent runs that both name a stage `s1` land their
    shard outcomes in one bucket, and the join fires on whichever `shard_count`
    armed it first — publishing a `stage.closed` that mixes both runs' shards
    and dropping the rest as late arrivals.
    """
    return (key,) if isinstance(key, str) else tuple(key)


def summarise(
    key_name: str | Sequence[str],
    key_value: str | Sequence[str],
    pending: Pending,
    timed_out: bool,
    carry_payloads: bool = False,
) -> dict:
    """The joined payload. Pure, so the interesting part is testable."""
    first = pending.results[0] if pending.results else {}
    names = as_keys(key_name)
    values = as_keys(key_value)
    summary = {
        **dict(zip(names, values)),
        "expected": pending.expected,
        "received": len(pending.results),
        "timed_out": timed_out,
        "results": [summarise_item(item) for item in pending.results],
    }
    if carry_payloads:
        summary["payloads"] = dict(pending.arm_payloads)
    summary.update(identity.project(first))
    return summary


class Joiner:
    """Accumulate outcomes by key. Publishing is injected, so this is testable."""

    def __init__(
        self,
        key: str | Sequence[str],
        count_field: str | None,
        publish: Callable[[dict, object], Awaitable[None]],
        timeout: float = 3600.0,
        arms: tuple[str, ...] | None = None,
        carry_payloads: bool = False,
    ):
        if carry_payloads and arms is None:
            raise ValueError("carry_payloads requires arms")
        self.keys = as_keys(key)
        # How the key reads in a diagnostic line, e.g. "run_id+stage_id".
        self.key = "+".join(self.keys)
        self.count_field = count_field
        self.arms = arms
        self.arm_set = set(arms) if arms is not None else None
        self.carry_payloads = carry_payloads
        self.publish = publish
        self.timeout = timeout
        self.pending: dict[tuple[str, ...], Pending] = {}
        self.closed: set[tuple[str, ...]] = set()

    def bucket(self, payload: dict) -> tuple[str, ...] | None:
        """The composite identity this payload joins under, or None if partial.

        Every key must be present. A payload missing one cannot be placed: it
        would otherwise fall into a bucket shared with every other payload
        missing that key, which is the collision this join exists to prevent.
        """
        values = []
        for key in self.keys:
            value = payload.get(key)
            if value is None:
                print(f"join: message without {key}, ignored", file=sys.stderr)
                return None
            values.append(str(value))
        return tuple(values)

    async def _fire(self, key_value: tuple[str, ...], cause: object, timed_out: bool) -> None:
        entry = self.pending.pop(key_value, None)
        if entry is None:
            return
        if entry.timer is not None and not entry.timer.done():
            entry.timer.cancel()
        self.closed.add(key_value)
        await self.publish(
            summarise(
                self.keys,
                key_value,
                entry,
                timed_out,
                carry_payloads=self.carry_payloads,
            ),
            cause,
        )

    async def _expire(self, key_value: tuple[str, ...]) -> None:
        try:
            await asyncio.sleep(self.timeout)
        except asyncio.CancelledError:
            return
        print(
            f"join: {self.key}={'+'.join(key_value)} timed out after {self.timeout}s",
            file=sys.stderr,
        )
        await self._fire(key_value, None, timed_out=True)

    async def accept(
        self,
        payload: dict,
        cause: object = None,
        topic: str | None = None,
    ) -> None:
        """Accept one arrival.

        Arms are identified by the delivering envelope, not payload content.
        In particular, a doubled zero-note ``notes.synced`` must remain one
        satisfied arm; it cannot stand in for the missing ``pr.merged`` arm.
        """
        key_value = self.bucket(payload)
        if key_value is None:
            return

        if key_value in self.closed:
            # A late arrival after the join already fired. Say so rather than
            # silently reopening a stage that has moved on.
            print(
                f"join: late arrival for {self.key}={'+'.join(key_value)}",
                file=sys.stderr,
            )
            return

        if self.arm_set is not None and topic not in self.arm_set:
            print(f"join: arrival from unknown arm {topic!r}, ignored", file=sys.stderr)
            return

        entry = self.pending.get(key_value)
        if entry is None:
            expected = (
                len(self.arms)
                if self.arms is not None
                else expected_count(payload, self.count_field or "")
            )
            entry = Pending(expected=expected)
            self.pending[key_value] = entry
            if self.timeout > 0:
                entry.timer = asyncio.create_task(self._expire(key_value))
        if self.arms is not None:
            if topic in entry.satisfied_arms:
                print(
                    f"join: duplicate arm {topic!r} for {self.key}={key_value}, ignored",
                    file=sys.stderr,
                )
                return
            entry.satisfied_arms.add(topic)
            if self.carry_payloads:
                entry.arm_payloads[topic] = payload
        elif entry.expected is None:
            entry.expected = expected_count(payload, self.count_field)

        entry.results.append(payload)

        complete = (
            entry.satisfied_arms == self.arm_set
            if self.arm_set is not None
            else entry.expected is not None and len(entry.results) >= entry.expected
        )
        if complete:
            await self._fire(key_value, cause, timed_out=False)


def default_subscriptions(key: str | Sequence[str]) -> list[str]:
    # Membership, not equality: the stage join is keyed on run_id AND stage_id,
    # and an equality check silently gave it the notes subscriptions instead.
    if "stage_id" in as_keys(key):
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
    parser.add_argument(
        "--key",
        required=True,
        action="append",
        help="join identity; repeat to join on a composite key, e.g. "
        "--key run_id --key stage_id",
    )
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--count-field")
    mode.add_argument("--arms")
    parser.add_argument(
        "--carry-payloads",
        action="store_true",
        help="in arms mode, carry each full payload keyed by topic",
    )
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
        await joiner.accept(msg.payload_as(dict) or {}, msg.id, msg.message_type)

    arms = (
        tuple(arm.strip() for arm in args.arms.split(",") if arm.strip())
        if args.arms
        else None
    )
    if args.arms is not None and not arms:
        parser.error("--arms must name at least one topic")
    if arms is not None and len(set(arms)) != len(arms):
        parser.error("--arms must name distinct topics")
    if args.carry_payloads and arms is None:
        parser.error("--carry-payloads requires --arms")
    keys = tuple(args.key)
    if len(set(keys)) != len(keys):
        parser.error("--key must name distinct fields")
    joiner = Joiner(
        keys,
        args.count_field,
        publish_joined,
        args.timeout_seconds,
        arms=arms,
        carry_payloads=args.carry_payloads,
    )
    subscribes = args.subscribe or list(arms or default_subscriptions(keys))
    name = os.environ.get("EMERGENT_PRIMITIVE_NAME", f"join-{'-'.join(keys)}")
    asyncio.run(run_handler(name, subscribes, accept))


if __name__ == "__main__":
    main()
