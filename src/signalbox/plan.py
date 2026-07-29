"""Plan invariants.

The load-bearing one is shard-scope disjointness within a stage. That invariant
is what licenses splitting a stage's shards into events that all run at once:
if two shards in the same stage could touch the same file, parallel execution
would be a race, and the topology would have to serialise them. Enforcing it
here is what makes the concurrency safe rather than hopeful.

Everything in this module is a pure function of a plan dict.
"""

from __future__ import annotations

from collections import Counter
from typing import Any

MAX_ATTEMPTS = 3


def _stage_shards(stage: Any) -> list[dict]:
    shards = stage.get("shards") if isinstance(stage, dict) else None
    return [s for s in shards if isinstance(s, dict)] if isinstance(shards, list) else []


def overlapping_files(stage: dict) -> dict[str, list[str]]:
    """Files claimed by more than one shard of a stage, mapped to the claimants."""
    claims: dict[str, list[str]] = {}
    for shard in _stage_shards(stage):
        shard_id = str(shard.get("shard_id", "?"))
        files = shard.get("files")
        if not isinstance(files, list):
            continue
        for path in files:
            claims.setdefault(str(path), []).append(shard_id)
    return {path: ids for path, ids in claims.items() if len(ids) > 1}


def duplicate_ids(values: list[str]) -> list[str]:
    """Identifiers appearing more than once, sorted."""
    return sorted(value for value, count in Counter(values).items() if count > 1)


def check_plan(plan: dict) -> dict:
    """Measure a plan against its invariants.

    Returns the plan with `ok`, `violations`, and an incremented `attempt`.
    Never raises: a malformed plan is data, not an exception.
    """
    violations: list[str] = []

    stages = plan.get("stages")
    if not isinstance(stages, list) or not stages:
        violations.append("plan has no stages")
        stages = []

    stage_ids: list[str] = []
    shard_ids: list[str] = []

    for index, stage in enumerate(stages):
        label = f"stage[{index}]"
        if not isinstance(stage, dict):
            violations.append(f"{label} is not an object")
            continue

        stage_id = stage.get("stage_id")
        if not stage_id:
            violations.append(f"{label} has no stage_id")
        else:
            stage_ids.append(str(stage_id))
            label = str(stage_id)

        shards = _stage_shards(stage)
        if not shards:
            violations.append(f"{label} has no shards")

        for shard in shards:
            shard_id = shard.get("shard_id")
            if not shard_id:
                violations.append(f"{label} contains a shard with no shard_id")
            else:
                shard_ids.append(str(shard_id))

            files = shard.get("files")
            if not isinstance(files, list) or not files:
                violations.append(f"{label}/{shard_id} declares no files")
            elif any(not isinstance(path, str) or not path for path in files):
                violations.append(f"{label}/{shard_id} has a malformed file entry")

            if not str(shard.get("intent") or "").strip():
                violations.append(f"{label}/{shard_id} has no intent")

        for path, claimants in sorted(overlapping_files(stage).items()):
            violations.append(
                f"{label}: {path} is claimed by {', '.join(sorted(claimants))} "
                "(shards in a stage must be disjoint)"
            )

    for duplicate in duplicate_ids(stage_ids):
        violations.append(f"duplicate stage_id: {duplicate}")
    for duplicate in duplicate_ids(shard_ids):
        violations.append(f"duplicate shard_id: {duplicate}")

    return {
        **plan,
        "stages": [_stamp_stage(stage, plan) for stage in stages if isinstance(stage, dict)],
        "ok": not violations,
        "violations": violations,
        "attempt": int(plan.get("attempt") or 0) + 1,
    }


def _stamp_stage(stage: dict, plan: dict) -> dict:
    """Denormalise run identity into each stage.

    stream-runner emits one *item* from the collection, not the envelope around
    it, so a stage that does not carry run identity would arrive downstream as
    an orphan. Stamping here keeps every streamed item self-describing.
    """
    return {
        **stage,
        "run_id": plan.get("run_id"),
        "repo": plan.get("repo"),
        "issue": plan.get("issue"),
        "base_sha": plan.get("base_sha"),
    }


def shard_events(stage: dict, envelope: dict) -> list[dict]:
    """One shard.opened payload per shard, with identity stamped by us.

    `declared` is the shard's file list copied onto every shard event, so the
    scope guard downstream is a pure predicate over one payload and needs no
    lookup, no shared state, and no plan on disk.
    """
    shards = _stage_shards(stage)
    count = len(shards)
    stage_id = stage.get("stage_id")
    return [
        {
            "run_id": envelope.get("run_id"),
            "repo": envelope.get("repo"),
            "issue": envelope.get("issue"),
            "base_sha": envelope.get("base_sha"),
            "stage_id": stage_id,
            "shard_id": shard.get("shard_id"),
            "shard_count": count,
            "declared": list(shard.get("files") or []),
            "intent": shard.get("intent"),
            "round": 1,
        }
        for shard in shards
    ]
