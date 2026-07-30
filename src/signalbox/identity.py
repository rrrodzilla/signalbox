"""Identity keys travel mechanically, never through a model.

Every event carries the keys that say which run, stage, and shard it belongs
to. Those keys are the join keys, the scope declaration, and the loop counters,
so a model that forgets one, renames one, or invents one would silently corrupt
routing. So the model never supplies them: whatever it produces is merged *onto*
the identity of the envelope it was handed.

Payload builders must project identity through :data:`CARRIED_KEYS`, never by
hand-enumerating keys. sb-60 lost ``base_branch`` that way on 2026-07-29
(issue #65).
"""

from __future__ import annotations

# Keys that are the system's to assign, in the order they read naturally.
CARRIED_KEYS: tuple[str, ...] = (
    "run_id",
    "repo",
    "issue",
    # Issue #80: every PR opened as "signalbox (#N)" because the issue title
    # died at the plan splitter.
    "title",
    "base_sha",
    # The base the PR opens against. Carried for the same reason base_sha is: it
    # is decided at launch and must not be re-derived later. `gh pr create` will
    # happily default it to the repository's default branch, which turned a
    # two-file gated diff into a 132-file pull request.
    "base_branch",
    "attempt",
    "stage_id",
    "stage_index",
    "stages",
    "shard_id",
    "shard_count",
    # The run join's expected count. Without it `join-run` never learns how many
    # stages to wait for, so a run stalls after its last stage merges — which is
    # what happened to demo-3 on 2026-07-29.
    "stage_count",
    "declared",
    # What the shard was asked to accomplish. The reviewer judges the diff
    # against it and `signalbox-review` names an unmet intent as a rejection
    # reason, so a review that never received it was silently judging scope
    # alone. Carried rather than re-read from a plan on disk, and carried
    # rather than supplied by the model, because a shard that could restate
    # its own intent could rewrite the standard it is about to be judged by.
    "intent",
    "round",
    # Runner sessions are assigned at the process boundary. Carrying this key
    # mechanically prevents a model from replacing the session to be resumed.
    "session_id",
    "note",
    "note_count",
    "pr",
)


def project(source: dict) -> dict:
    """Return the carried identity keys that are present in ``source``."""
    return {key: source[key] for key in CARRIED_KEYS if key in source}


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
