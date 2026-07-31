"""Split a note plan into one note.drafted event per note.

One event per note is what removes the vault lock. Notes were a shared document
that every run serialised on; as N independent events they have no shared
resource to contend for, and a slow note delays only itself.
"""

from __future__ import annotations

import asyncio
import os
import sys
from collections.abc import Awaitable, Callable

from signalbox.identity import project

Publish = Callable[[dict, object], Awaitable[None]]
SUBSCRIPTIONS = ["notes.plan-accepted"]


def note_events(payload: dict) -> list[dict]:
    """One payload per note, each stamped with the run identity and the total."""
    notes = [n for n in payload.get("notes") or [] if n]
    count = len(notes)
    return [
        {
            **(
                {"note": note, "reason": None}
                if isinstance(note, str)
                else {"reason": None, **note}
            ),
            **project(payload),
            "note_count": count,
        }
        for note in notes
    ]


def synced_event(payload: dict) -> dict | None:
    """A terminal join-shaped payload when the plan contains no notes."""
    if any(payload.get("notes") or []):
        return None
    return {
        "expected": 0,
        "received": 0,
        "timed_out": False,
        "results": [],
        **project(payload),
    }


async def publish_events(
    payload: dict,
    cause: object,
    publish_note: Publish,
    publish_synced: Publish,
) -> None:
    """Publish drafted notes, or the synthetic terminal event for an empty plan."""
    events = note_events(payload)
    if not events:
        print("split-notes: plan named no notes", file=sys.stderr)
        event = synced_event(payload)
        assert event is not None
        await publish_synced(event, cause)
        return
    for event in events:
        await publish_note(event, cause)


def main() -> None:
    from emergent import create_message, run_handler

    async def split(msg, handler) -> None:
        async def publish_note(event: dict, _cause: object) -> None:
            await handler.publish(
                create_message("note.drafted").caused_by(msg.id).payload(event)
            )

        async def publish_synced(event: dict, _cause: object) -> None:
            await handler.publish(
                create_message("notes.synced").caused_by(msg.id).payload(event)
            )

        await publish_events(
            msg.payload_as(dict) or {},
            msg.id,
            publish_note,
            publish_synced,
        )

    name = os.environ.get("EMERGENT_PRIMITIVE_NAME", "split-notes")
    asyncio.run(run_handler(name, SUBSCRIPTIONS, split))


if __name__ == "__main__":
    main()
