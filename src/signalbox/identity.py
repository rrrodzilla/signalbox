"""Identity keys travel mechanically, never through a model.

Every event carries the keys that say which run, stage, and shard it belongs
to. Those keys are the join keys, the scope declaration, and the loop counters,
so a model that forgets one, renames one, or invents one would silently corrupt
routing. So the model never supplies them: whatever it produces is merged *onto*
the identity of the envelope it was handed.
"""

from __future__ import annotations

# Keys that are the system's to assign, in the order they read naturally.
CARRIED_KEYS: tuple[str, ...] = (
    "run_id",
    "repo",
    "issue",
    "base_sha",
    "attempt",
    "stage_id",
    "shard_id",
    "shard_count",
    # The run join's expected count. Without it `join-run` never learns how many
    # stages to wait for, so a run stalls after its last stage merges — which is
    # what happened to demo-3 on 2026-07-29.
    "stage_count",
    "declared",
    "round",
    "note",
    "note_count",
    "pr",
)


def carry(inbound: dict, produced: dict) -> dict:
    """Merge model output onto the inbound envelope's identity.

    Identity always wins. A model cannot reassign a shard, widen its declared
    scope, or reset a round counter by saying so.
    """
    merged = dict(produced)
    for key in CARRIED_KEYS:
        if key in inbound:
            merged[key] = inbound[key]
    return merged


def spoofed_keys(inbound: dict, produced: dict) -> list[str]:
    """Identity keys the model tried to set to something other than the truth.

    Not an error on its own; it is worth reporting, because a model reaching for
    these is a prompt problem worth seeing in the event log.
    """
    return sorted(
        key
        for key in CARRIED_KEYS
        if key in produced and key in inbound and produced[key] != inbound[key]
    )
