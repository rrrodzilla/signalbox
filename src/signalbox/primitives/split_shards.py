"""Split a stage into one shard.opened event per shard.

exec primitives publish exactly one event per execution, so a stage cannot be
fanned out with jq. This is the ten-line SDK splitter: N events, causation
intact, none held back — because shards in a stage are disjoint by an invariant
check_plan enforces, so there is nothing to pace.

It also serves the reopen path. A stage that failed to merge republishes only
the shards a conflict actually implicated, which is what makes the merge-conflict
feedback edge cost nothing.
"""

from __future__ import annotations

import asyncio
import os
import sys

from signalbox.plan import shard_events

# The SDK is imported inside main() so the splitting logic above stays testable
# without an engine, and without emergent-client installed.


def reopened_shards(payload: dict) -> list[dict]:
    """Shard events for the shards a merge conflict implicated.

    A conflict payload echoes the stage's shards plus the conflicting paths. Any
    shard that declared one of those paths is reopened; the rest stay merged.
    """
    conflicts = {str(path) for path in payload.get("conflicts") or []}
    shards = [
        shard
        for shard in payload.get("shards") or []
        if isinstance(shard, dict)
        and conflicts.intersection(str(p) for p in shard.get("files") or [])
    ]
    events = shard_events({**payload, "shards": shards}, payload)
    return [{**event, "reopened_from": "merge_conflict"} for event in events]


def events_for(payload: dict) -> list[dict]:
    """Shard events for a stage, whether it is opening or reopening."""
    if payload.get("conflicts"):
        return reopened_shards(payload)
    return shard_events(payload, payload)


def main() -> None:
    from emergent import create_message, run_handler

    async def split(msg, handler) -> None:
        payload = msg.payload_as(dict) or {}
        events = events_for(payload)
        if not events:
            print(
                f"split-shards: nothing to split for stage {payload.get('stage_id')!r}",
                file=sys.stderr,
            )
            return
        for event in events:
            await handler.publish(
                create_message("shard.opened").caused_by(msg.id).payload(event)
            )

    name = os.environ.get("EMERGENT_PRIMITIVE_NAME", "split-shards")
    asyncio.run(run_handler(name, ["stage.opened", "stage.conflicted"], split))


if __name__ == "__main__":
    main()
