"""The push-driven promote path: what a webhook can tell us, and what it cannot.

The poller these replace was never covered, which is how issue #56 lived in it:
`gh pr list --head "signalbox/"` matches a branch name exactly and never a
prefix, so it found nothing and reported nothing, indefinitely and silently.
"""

from __future__ import annotations

import json

import pytest

from signalbox import acts


# ── which conclusions mean "this broke" ──────────────────────────────────────


def test_only_unsuccessful_check_runs_are_named():
    runs = [
        {"name": "tests", "conclusion": "success"},
        {"name": "lint", "conclusion": "failure"},
        {"name": "optional", "conclusion": "skipped"},
        {"name": "advisory", "conclusion": "neutral"},
        {"name": "slow", "conclusion": "timed_out"},
    ]
    assert acts.failed_check_names(runs) == ["lint", "slow"]


def test_conclusions_are_compared_case_insensitively():
    """GitHub sends lowercase on webhooks and uppercase via the GraphQL rollup.

    Comparing raw would have made every webhook-sourced success look like a
    failure and opened a fix loop against green code.
    """
    assert acts.failed_check_names([{"name": "tests", "conclusion": "SUCCESS"}]) == []
    assert acts.failed_check_names([{"name": "tests", "conclusion": "success"}]) == []


def test_a_check_run_still_in_flight_counts_as_not_passing():
    """A null conclusion is not success, and must not be silently treated as one."""
    assert acts.failed_check_names([{"name": "tests", "conclusion": None}]) == ["tests"]


def test_an_unnamed_check_run_is_still_reported():
    assert acts.failed_check_names([{"conclusion": "failure"}]) == ["unnamed"]


# ── fetching the detail ──────────────────────────────────────────────────────


def test_check_details_names_the_failed_runs(monkeypatch):
    body = {"check_runs": [
        {
            "name": "tests", "id": 901, "conclusion": "failure",
            "output": {"title": "Tests failed", "summary": "2 failures", "text": "log"},
            "details_url": "https://ci.example/tests",
            "html_url": "https://github.example/checks/901",
            "started_at": "2026-07-31T00:00:00Z",
        },
        {"name": "lint", "conclusion": "success"},
    ]}
    monkeypatch.setattr(acts, "_run", lambda *a, **k: (0, json.dumps(body), ""))
    identity = {
        "pr": 57, "sha": "abc123", "run_id": "sb-101", "repo": "acme/widget",
        "check_runs_url": "https://api/x",
    }
    out = acts.check_details(identity)
    assert out["ok"] is True
    assert out["failed"] == [{
        "name": "tests", "id": 901,
        "output": {"title": "Tests failed", "summary": "2 failures"},
        "details_url": "https://ci.example/tests",
        "html_url": "https://github.example/checks/901",
    }]
    assert out["detail_ok"] is True
    assert identity.items() <= out.items(), "run identity must survive the fetch"


@pytest.mark.parametrize(
    "payload, run_result, reason_fragment",
    [
        ({"pr": 57}, (0, "{}", ""), "no check_runs_url"),
        ({"pr": 57, "check_runs_url": "u"}, (1, "", "gh: not found"), "not found"),
        ({"pr": 57, "check_runs_url": "u"}, (0, "", ""), "returned nothing"),
        ({"pr": 57, "check_runs_url": "u"}, (0, "not json", ""), "unreadable"),
    ],
)
def test_a_detail_fetch_that_fails_is_data_not_an_exception(
    monkeypatch, payload, run_result, reason_fragment
):
    """The CI feedback edge must survive a failed fetch.

    Raising here would strand a red build with no findings event at all, which is
    strictly worse than findings that cannot name the broken check.
    """
    monkeypatch.setattr(acts, "_run", lambda *a, **k: run_result)
    out = acts.check_details(payload)
    assert out["ok"] is False
    assert out["detail_ok"] is False
    assert out["failed"] == []
    assert reason_fragment in out["reason"]
    assert out["pr"] == 57


def test_failed_detail_still_maps_to_a_ci_round_with_run_identity(monkeypatch):
    identity = {
        "pr": 57, "sha": "abc123", "run_id": "sb-101", "repo": "acme/widget",
        "check_runs_url": "https://api/x",
    }
    monkeypatch.setattr(acts, "_run", lambda *a, **k: (1, "", "fetch denied"))

    detailed = acts.check_details(identity)
    result = acts.map_ci_findings({
        **detailed,
        "round": 3,
        "stages": [{"shards": [{"files": ["src/fix.py"]}]}],
    })

    assert result["verdict"] == "changes_requested"
    assert result["round"] == 1
    assert result["ci_origin"] == "post-merge"
    assert result["ci_round"] == 1
    assert len(result["findings"]) == 1
    finding = result["findings"][0]
    assert identity.items() <= finding.items()
    assert finding["reason"] == "fetch denied"
    assert "detail" not in finding


def test_check_details_rejects_a_listing_without_check_runs(monkeypatch):
    monkeypatch.setattr(acts, "_run", lambda *a, **k: (0, '{"other":[]}', ""))

    out = acts.check_details({
        "run_id": "sb-66", "pr": 57, "check_runs_url": "https://api/x",
    })

    assert out["ok"] is False
    assert out["detail_ok"] is False
    assert out["failed"] == []
    assert out["run_id"] == "sb-66"
    assert "no records" in out["reason"]


# ── identity a webhook cannot carry ──────────────────────────────────────────


def test_observed_facts_win_over_the_stored_marker():
    stored = {"run_id": "sb-56", "issue": 56, "sha": "old", "pr": 57}
    observed = {"sha": "new", "conclusion": "success"}
    merged = acts.rehydrated(stored, observed)
    assert merged["sha"] == "new", "the suite describes the commit actually tested"
    assert merged["issue"] == 56, "the webhook cannot know this"
    assert merged["conclusion"] == "success"


def test_rehydrate_restores_run_identity_and_refreshes_the_marker(tmp_path, monkeypatch):
    monkeypatch.setenv("SIGNALBOX_STATE", str(tmp_path))
    opened = {
        "run_id": "sb-56", "repo": "rrrodzilla/signalbox", "issue": 56,
        "base_sha": "d6c8f80", "stage_count": 1, "pr": 57,
    }
    marker = acts.mark_pending("pr", opened)
    assert marker.exists()
    assert marker.name == "pr-57.json"
    marker.touch()
    old_mtime = marker.stat().st_mtime - 3600
    import os
    os.utime(marker, (old_mtime, old_mtime))

    observed = {
        "run_id": "sb-56",
        "repo": "rrrodzilla/signalbox",
        "pr": 57,
        "sha": "e0a1742",
        "conclusion": "success",
        "check_runs_url": "https://api.github.com/x/check-runs",
    }
    out = acts.rehydrate("pr", observed)

    # Everything the notes stage past pr.merged needs, none of which GitHub knows.
    assert out["issue"] == 56
    assert out["base_sha"] == "d6c8f80"
    assert out["conclusion"] == "success"
    assert marker.exists(), "another suite on this PR still needs run identity"
    assert marker.stat().st_mtime > old_mtime, "rehydration refreshes the silence window"


def test_a_suite_for_an_untracked_pr_raises_rather_than_inventing_a_run(
    tmp_path, monkeypatch
):
    """A leftover PR from an earlier engine can deliver a suite we cannot place.

    Returning `ok: false` would let it flow on as a run-shaped payload with no
    run; raising routes it to `checks.unknown-pr` where a human can see it.
    """
    monkeypatch.setenv("SIGNALBOX_STATE", str(tmp_path))
    with pytest.raises(acts.PendingMissing):
        acts.rehydrate("pr", {"run_id": "sb-nope", "pr": 999})


def test_a_reaped_pr_carries_the_identity_the_notification_needs(tmp_path, monkeypatch):
    """`checks.silent` is the terminal event for a run that heard nothing back.

    It has to say which run and which PR, so the marker stores the whole opened
    payload rather than a timestamp.
    """
    monkeypatch.setenv("SIGNALBOX_STATE", str(tmp_path))
    acts.mark_pending("pr", {"run_id": "sb-56", "pr": 57, "issue": 56})
    lines = acts.reap("pr", stale_minutes=0).splitlines()
    assert len(lines) == 1
    reaped = json.loads(lines[0])
    assert reaped["run_id"] == "sb-56"
    assert reaped["pr"] == 57
    assert reaped["outcome"] == "silent"


def test_a_pr_still_within_its_window_is_not_reaped(tmp_path, monkeypatch):
    monkeypatch.setenv("SIGNALBOX_STATE", str(tmp_path))
    acts.mark_pending("pr", {"run_id": "sb-56", "pr": 57})
    assert acts.reap("pr", stale_minutes=40) == ""


def test_shard_and_pr_markers_do_not_reap_each_other(tmp_path, monkeypatch):
    """Both kinds share one directory, so the glob is the only thing separating
    them. A shard reap that swept PR markers would cancel every promote wait."""
    monkeypatch.setenv("SIGNALBOX_STATE", str(tmp_path))
    acts.mark_pending("pr", {"run_id": "sb-56", "pr": 57})
    acts.mark_pending("shard", {"shard_id": "s1-fix", "run_id": "sb-56"})

    reaped = json.loads(acts.reap("shard", stale_minutes=0))
    assert reaped["shard_id"] == "s1-fix"
    assert acts.reap("pr", stale_minutes=0) != "", "the pr marker must have survived"


# ── the base a PR opens against ──────────────────────────────────────────────


def test_open_pr_refuses_rather_than_letting_gh_choose_a_base(monkeypatch):
    """`gh pr create` with no --base uses the repository default branch.

    Run sb-56 branched from `redesign/event-first`, was gated on a two-file diff,
    and opened PR #57 against `main` with 132 files and -21440 lines. The gate
    judged one thing and the PR presented another. Now that a green check suite
    merges without a human, guessing here is not survivable.
    """
    called = []
    monkeypatch.setattr(acts, "_run", lambda *a, **k: called.append(a) or (0, "url", ""))
    out = acts.open_pr({"run_id": "sb-56", "issue": 56, "stage_id": "s3"})
    assert out["ok"] is False
    assert out["run_id"] == "sb-56"
    assert out["stage_id"] == "s3"
    assert "base_branch" in out["error"]
    assert not called, "gh must not be invoked without a base"


def test_open_pr_targets_the_pinned_base(monkeypatch, tmp_path):
    seen = []

    def fake_run(cmd, *a, **k):
        seen.append(cmd)
        if cmd[:3] == ["gh", "pr", "view"]:
            return 0, json.dumps({
                "number": 99,
                "url": "https://github.com/o/r/pull/99",
                "baseRefName": "redesign/event-first",
                "headRefName": "signalbox/run-sb-56",
                "state": "OPEN",
            }), ""
        return 0, "https://github.com/o/r/pull/99", ""

    monkeypatch.setenv("SIGNALBOX_STATE", str(tmp_path))
    monkeypatch.setattr(acts, "_run", fake_run)
    out = acts.open_pr(
        {"run_id": "sb-56", "issue": 56, "base_branch": "redesign/event-first"}
    )
    assert out["ok"] is True and out["pr"] == "99"
    create = seen[0]
    assert "--base" in create
    assert create[create.index("--base") + 1] == "redesign/event-first"


def test_open_pr_does_not_claim_success_without_verifying_the_requested_base(
    monkeypatch, tmp_path
):
    responses = iter([
        (0, "https://github.com/o/r/pull/99", ""),
        (0, json.dumps({
            "number": 99,
            "url": "https://github.com/o/r/pull/99",
            "baseRefName": "main",
            "headRefName": "signalbox/run-sb-56",
            "state": "OPEN",
        }), ""),
    ])
    monkeypatch.setenv("SIGNALBOX_STATE", str(tmp_path))
    monkeypatch.setattr(acts, "_run", lambda *a, **k: next(responses))

    out = acts.open_pr({
        "run_id": "sb-56", "issue": 56, "base_branch": "redesign/event-first",
    })

    assert out["ok"] is False
    assert out["run_id"] == "sb-56"


def test_open_pr_reuses_a_verified_open_pr_for_the_head(monkeypatch, tmp_path):
    """The CI fix loop returns to open-pr while its original PR still exists."""
    seen = []

    def fake_run(cmd, *args, **kwargs):
        seen.append(cmd)
        if cmd[:3] == ["gh", "pr", "create"]:
            return (
                1,
                "",
                "a pull request for branch signalbox/run-sb-56 already exists",
            )
        return 0, json.dumps({
            "number": 99,
            "url": "https://github.com/o/r/pull/99",
            "baseRefName": "redesign/event-first",
            "headRefName": "signalbox/run-sb-56",
            "state": "OPEN",
        }), ""

    monkeypatch.setenv("SIGNALBOX_STATE", str(tmp_path))
    monkeypatch.setattr(acts, "_run", fake_run)

    out = acts.open_pr({
        "run_id": "sb-56", "issue": 56, "pr": 99,
        "base_branch": "redesign/event-first",
    })

    assert out["ok"] is True
    assert out["pr"] == "99"
    assert out["run_id"] == "sb-56"
    assert seen[1][:4] == ["gh", "pr", "view", "signalbox/run-sb-56"]


def test_open_pr_rejects_an_existing_head_pr_against_the_wrong_base(
    monkeypatch, tmp_path
):
    responses = iter([
        (1, "", "a pull request already exists"),
        (0, json.dumps({
            "number": 99,
            "url": "https://github.com/o/r/pull/99",
            "baseRefName": "main",
            "headRefName": "signalbox/run-sb-56",
            "state": "OPEN",
        }), ""),
    ])
    monkeypatch.setenv("SIGNALBOX_STATE", str(tmp_path))
    monkeypatch.setattr(acts, "_run", lambda *a, **k: next(responses))

    out = acts.open_pr({
        "run_id": "sb-56", "issue": 56, "base_branch": "redesign/event-first",
    })

    assert out["ok"] is False
    assert out["run_id"] == "sb-56"


def test_fetch_issue_failure_and_success_preserve_identity(monkeypatch):
    payload = {"run_id": "sb-66", "issue": 66, "stage_count": 3}
    monkeypatch.setattr(acts, "_run", lambda *a, **k: (1, "", "not found"))
    refused = acts.fetch_issue(payload)
    assert refused["ok"] is False
    assert refused["run_id"] == "sb-66"
    assert refused["stage_count"] == 3

    monkeypatch.setattr(
        acts, "_run",
        lambda *a, **k: (0, json.dumps({
            "number": 66, "title": "Outcome routing", "body": "body", "labels": [],
        }), ""),
    )
    fetched = acts.fetch_issue(payload)
    assert fetched["ok"] is True
    assert fetched["run_id"] == "sb-66"


def test_fetch_issue_does_not_claim_success_for_an_unusable_response(monkeypatch):
    monkeypatch.setattr(acts, "_run", lambda *a, **k: (0, "{}", ""))
    assert acts.fetch_issue({"run_id": "sb-66", "issue": 66})["ok"] is False


def test_the_base_branch_survives_every_seam_that_dropped_stage_count():
    """base_branch is decided at launch and read at open-pr, crossing three seams
    that have each silently eaten an identity key before.

    stage_count was carried into shard.opened and lost at the agent's emission,
    stalling every run after its final stage merged. base_sha was lost at the same
    gate. The seams are the dispatcher's environment, `signalbox emit` reading it
    back, and the run join's summary.
    """
    from signalbox.dispatch import environment
    from signalbox.emit import _ENV_KEYS, identity_from_env
    from signalbox.identity import CARRIED_KEYS
    from signalbox.primitives.join_terminal import summarise, Pending

    assert "base_branch" in CARRIED_KEYS

    stamped = environment({"base_branch": "redesign/event-first"}, {})
    assert stamped["SIGNALBOX_BASE_BRANCH"] == "redesign/event-first"

    assert "base_branch" in _ENV_KEYS
    assert identity_from_env(stamped)["base_branch"] == "redesign/event-first"

    merged = {"run_id": "sb-56", "base_branch": "redesign/event-first", "stage_count": 1}
    joined = summarise("run_id", "sb-56", Pending(expected=1, results=[merged]), False)
    assert joined["base_branch"] == "redesign/event-first"


def test_the_title_survives_the_agent_environment_seam():
    """sb-78's title crosses the two hand-mapped agent environment seams."""
    from signalbox.dispatch import environment
    from signalbox.emit import _ENV_KEYS, identity_from_env

    stamped = environment({"title": "Keep this title"}, {})
    assert stamped["SIGNALBOX_TITLE"] == "Keep this title"

    assert "title" in _ENV_KEYS
    assert identity_from_env(stamped)["title"] == "Keep this title"


def test_a_none_title_does_not_round_trip_as_the_string_none():
    """sb-78 must not repeat #74's str(None) precedent at the agent env seam.

    An absent title must not reach the agent as the string "None", must not
    leave a stale value standing, and must not come back as a title.
    """
    from signalbox.dispatch import environment
    from signalbox.emit import identity_from_env

    stamped = environment({"title": None}, {"SIGNALBOX_TITLE": "stale title"})
    assert "SIGNALBOX_TITLE" not in stamped
    assert "title" not in identity_from_env(stamped)


def test_the_shard_intent_reaches_the_reviewer():
    """The reviewer judges the diff against the intent, so the intent must arrive.

    `plan.py` stamps it onto `shard.opened` and it died at the agent environment
    seam: absent from CARRIED_KEYS, from the dispatcher's environment, and from
    `_ENV_KEYS`. So `shard.submitted` carried no intent, `shard.built` carried
    none, and `signalbox-review` was told to judge against an intent that was
    never in its payload. It degraded to reviewing scope alone, which is why the
    loss was silent: the verdict still looked reasonable.
    """
    from signalbox.dispatch import environment
    from signalbox.emit import _ENV_KEYS, build_body, identity_from_env
    from signalbox.identity import CARRIED_KEYS

    intent = "make the cursor an event, not a variable"
    assert "intent" in CARRIED_KEYS
    assert "intent" in _ENV_KEYS

    stamped = environment({"intent": intent}, {})
    assert stamped["SIGNALBOX_INTENT"] == intent
    assert identity_from_env(stamped)["intent"] == intent

    # `shard.submitted` is built from the agent's fields plus this identity, and
    # `route-shard-done` is a bare `select`, so whatever lands here is exactly
    # what review receives.
    assert build_body("shard.submitted", {"verdict": "done"}, stamped)["intent"] == intent


def test_a_shard_cannot_restate_the_intent_it_is_judged_against():
    """Identity wins over model output, or a shard could move its own goalposts.

    An agent that found the intent inconvenient could otherwise emit a narrower
    one and be reviewed against that instead.
    """
    from signalbox.dispatch import environment
    from signalbox.emit import build_body
    from signalbox.identity import carry, spoofed_keys

    real = "carry the intent to the reviewer"
    stamped = environment({"intent": real}, {})
    body = build_body("shard.submitted", {"intent": "something easier"}, stamped)
    assert body["intent"] == real

    # And the same on the judging side: a verdict cannot rewrite it either.
    inbound = {"run_id": "sb-1", "intent": real}
    verdict = {"verdict": "approved", "intent": "something easier"}
    assert carry(inbound, verdict)["intent"] == real
    assert spoofed_keys(inbound, verdict) == ["intent"]


def test_a_none_intent_does_not_round_trip_as_the_string_none():
    """#74's str(None) precedent: "None" would read as a real instruction."""
    from signalbox.dispatch import environment
    from signalbox.emit import identity_from_env

    stamped = environment({"intent": None}, {"SIGNALBOX_INTENT": "stale intent"})
    assert "SIGNALBOX_INTENT" not in stamped
    assert "intent" not in identity_from_env(stamped)


def test_merge_stage_preserves_the_plan_cursor(monkeypatch, tmp_path):
    """The merge act rebuilds stage.closed and must echo the whole cursor."""
    stages = [
        {"stage_id": "stage-1", "shards": []},
        {"stage_id": "stage-2", "shards": []},
    ]
    payload = {
        "run_id": "sb-59",
        "stage_id": "stage-1",
        "stage_index": 0,
        "stages": stages,
        "results": [{"declared": ["tests/test_checks.py"]}],
        "worktree": str(tmp_path),
    }
    commands = iter(
        [
            (0, "", ""),
            (0, "", ""),
            (0, "deadbeef", ""),
        ]
    )
    monkeypatch.setattr(acts, "_run", lambda *args, **kwargs: next(commands))

    merged = acts.merge_stage(payload)

    assert merged["stage_index"] == 0
    assert merged["stages"] == stages


def test_merge_stage_refuses_when_the_commit_cannot_be_verified_with_identity(
    monkeypatch, tmp_path
):
    payload = {
        "run_id": "sb-66",
        "issue": 66,
        "stage_id": "s1-outcomes",
        "results": [{"declared": ["tests/test_checks.py"]}],
        "worktree": str(tmp_path),
    }
    commands = iter([
        (0, "", ""),
        (0, "", ""),
        (1, "", "cannot read HEAD"),
    ])
    monkeypatch.setattr(acts, "_run", lambda *args, **kwargs: next(commands))

    merged = acts.merge_stage(payload)

    assert merged["ok"] is False
    assert merged["run_id"] == "sb-66"
    assert merged["issue"] == 66
    assert merged["stage_id"] == "s1-outcomes"
    assert "cannot read HEAD" in merged["error"]


def test_product_keys_are_a_narrow_exemption_from_carried_identity(monkeypatch):
    """Only explicitly named roles may author their narrow carried products.

    Derive this guard from the role map itself rather than enumerating today's
    agent seams: a new role must not silently acquire permission to rewrite an
    envelope key, and the non-drafting seams below must remain ordinary carried
    identity seams as the map grows.
    """
    from signalbox import identity
    from signalbox.identity import CARRIED_KEYS, ROLE_PRODUCT_KEYS

    carried = set(CARRIED_KEYS)
    claimed = {
        role: set(product_keys)
        for role, product_keys in ROLE_PRODUCT_KEYS.items()
        if product_keys
    }

    assert set().union(*claimed.values(), set()) <= carried
    assert claimed == {
        "plan": {"stages"},
        "remediate": {"resume_topic"},
    }
    assert {
        "declared",
        "round",
        "run_id",
        "remediation_attempt",
        "shard_id",
        "session_id",
    }.isdisjoint(set().union(*claimed.values(), set()))

    future_product_keys = {
        **ROLE_PRODUCT_KEYS,
        "sentinel-role": frozenset({"sentinel-key"}),
    }
    monkeypatch.setattr(identity, "ROLE_PRODUCT_KEYS", future_product_keys)

    for role, product_keys in future_product_keys.items():
        inbound = {
            "run_id": "sb-product-key-guard",
            **{key: f"rejected-{key}" for key in product_keys},
        }
        result = identity.merge(inbound, {"verdict": "unparseable"}, role)

        assert product_keys.isdisjoint(result.payload)
        assert result.product_omitted == sorted(product_keys)


def test_every_carried_key_survives_every_payload_building_seam():
    """CARRIED_KEYS is the contract across payload-building seams.

    This deliberately excludes dispatch.environment and emit._ENV_KEYS: those
    are key-to-environment-variable mappings and cannot be projected
    mechanically.
    """
    from signalbox.identity import CARRIED_KEYS
    from signalbox.plan import _stamp_stage, shard_events
    from signalbox.primitives.join_terminal import Pending, summarise
    from signalbox.primitives.split_notes import note_events

    carried = {key: f"value-{key}" for key in CARRIED_KEYS}
    carried.update(
        {
            "attempt": 0,
            "remediation_attempt": 1,
            "stage_id": "stage-1",
            "stage_index": 0,
            "stage_count": 1,
            "shard_id": "shard-1",
            "shard_count": 1,
            "declared": ["tests/test_checks.py"],
            # Shard-scoped, like shard_id and declared: `shard_events` re-stamps
            # it from the shard after projecting the envelope, so it has to be
            # the shard's own value rather than a run-scoped placeholder.
            "intent": "exercise the identity seams",
            "round": 1,
            "note": "architecture",
            "note_count": 1,
        }
    )
    stages = [
        {
            "stage_id": carried["stage_id"],
            "shards": [
                {
                    "shard_id": carried["shard_id"],
                    "files": carried["declared"],
                    "intent": carried["intent"],
                }
            ],
        }
    ]
    carried["stages"] = stages
    plan = {
        **carried,
        "stages": stages,
    }

    stage = _stamp_stage(plan["stages"][0], plan, 0, stages)
    shard = shard_events(stage, stage)[0]
    note = note_events({**shard, "notes": [carried["note"]]})[0]
    summary = summarise(
        "joined",
        "terminal",
        Pending(expected=1, results=[note]),
        False,
    )

    for payload in (stage, shard, note, summary):
        for key in CARRIED_KEYS:
            assert payload[key] == carried[key]


def test_a_future_carried_key_survives_every_payload_building_seam(monkeypatch):
    """New carried keys cross every builder when present and stay absent otherwise."""
    from signalbox import identity
    from signalbox.plan import _stamp_stage, shard_events
    from signalbox.primitives.join_terminal import Pending, summarise
    from signalbox.primitives.split_notes import note_events

    monkeypatch.setattr(identity, "CARRIED_KEYS", (*identity.CARRIED_KEYS, "sentinel"))

    def cross_seams(envelope):
        plan = {
            **envelope,
            "stages": [
                {
                    "stage_id": "stage-1",
                    "shards": [
                        {
                            "shard_id": "shard-1",
                            "files": ["tests/test_checks.py"],
                            "intent": "exercise a future identity key",
                        }
                    ],
                }
            ],
        }
        stage = _stamp_stage(plan["stages"][0], plan, 0, plan["stages"])
        shard = shard_events(stage, stage)[0]
        note = note_events({**shard, "notes": ["architecture"]})[0]
        summary = summarise(
            "joined",
            "terminal",
            Pending(expected=1, results=[note]),
            False,
        )
        return stage, shard, note, summary

    for payload in cross_seams({"sentinel": "future-value"}):
        assert payload["sentinel"] == "future-value"
    for payload in cross_seams({}):
        assert "sentinel" not in payload


def test_prepare_workspace_names_the_branch_it_actually_branched_from(tmp_path, monkeypatch):
    """The base is discovered here and used at open-pr, so it must be recorded.

    Nothing recorded the *name* before — only the sha — so open-pr had nothing to
    pass and `gh` substituted the repository default.
    """
    import subprocess

    source = tmp_path / "repo"
    source.mkdir()
    run = lambda *c: subprocess.run(c, cwd=source, check=True, capture_output=True)
    run("git", "init", "-q", "-b", "redesign/event-first")
    run("git", "config", "user.email", "t@t")
    run("git", "config", "user.name", "t")
    (source / "f").write_text("x")
    run("git", "add", "-A")
    run("git", "commit", "-qm", "init", "--no-gpg-sign")

    monkeypatch.setenv("SIGNALBOX_STATE", str(tmp_path / "state"))
    out = acts.prepare_workspace({"run_id": "sb-1", "repo_path": str(source)})

    assert out["ok"] is True, out.get("error")
    assert out["base_branch"] == "redesign/event-first"
    assert out["base_sha"], "the sha must still be pinned"
