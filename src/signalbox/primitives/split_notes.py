"""Split a note plan into one note.drafted event per note.

One event per note is what removes the vault lock. Notes were a shared document
that every run serialised on; as N independent events they have no shared
resource to contend for, and a slow note delays only itself.
"""

from __future__ import annotations

import asyncio
import os
import sys

from signalbox.identity import project


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


def main() -> None:
    from emergent import create_message, run_handler

    async def split(msg, handler) -> None:
        events = note_events(msg.payload_as(dict) or {})
        if not events:
            print("split-notes: plan named no notes", file=sys.stderr)
            return
        for event in events:
            await handler.publish(
                create_message("note.drafted").caused_by(msg.id).payload(event)
            )

    name = os.environ.get("EMERGENT_PRIMITIVE_NAME", "split-notes")
    asyncio.run(run_handler(name, ["notes.planned"], split))


if __name__ == "__main__":
    main()
