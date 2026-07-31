"""The irreducible I/O acts. One external effect each, failure always as data.

Every act reads a payload on stdin and prints one JSON object on stdout. None of
them decides what happens next, and none of them exits non-zero for an outcome
that is simply false — a merge that conflicted is `{"ok": false, ...}`, an event
the topology routes, not an exception that strands a run.

Shards of one stage share a single worktree. That is safe precisely because
check_plan enforces disjointness, so no two concurrently running shards can
touch the same path. It is why there are no per-shard branches to merge.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

from signalbox.paths import (
    WorktreeMissing, branch_for, install_skills, require_worktree,
    sessions_dir, state_dir, vault_dir, worktree_for,
)


def _run(cmd: list[str], cwd: str | None = None, timeout: int = 120) -> tuple[int, str, str]:
    completed = subprocess.run(
        cmd, cwd=cwd, capture_output=True, text=True, check=False, timeout=timeout
    )
    return completed.returncode, completed.stdout.strip(), completed.stderr.strip()


def _payload() -> dict:
    raw = sys.stdin.read()
    if not raw.strip():
        return {}
    try:
        value = json.loads(raw)
    except json.JSONDecodeError:
        return {}
    return value if isinstance(value, dict) else {}


def _out(payload: dict) -> int:
    print(json.dumps(payload))
    return 0




# ── workspace ────────────────────────────────────────────────────────────────


def prepare_workspace(payload: dict) -> dict:
    """One worktree per run, branched from the base sha the launch pinned.

    Pinning matters: the base branch moves while a run is in flight, so a run
    that re-read it at merge time would land against a tree it never saw. The
    sha resolved here is the one every later act uses.
    """
    root = worktree_for(payload)
    branch = branch_for(payload)
    source = payload.get("repo_path") or os.getcwd()

    # The base branch is resolved by NAME here, not left for `gh pr create` to
    # default. gh defaults to the repository's default branch, which is only the
    # right answer when the run was launched from it: run sb-56 branched from
    # `redesign/event-first`, was gated on a two-file diff, and opened a PR
    # against `main` containing 132 files. The gate judged one thing and the PR
    # presented another, which is the worst available outcome now that a green
    # suite merges without a human.
    base_branch = payload.get("base_branch")
    if not base_branch:
        code, base_branch, err = _run(["git", "rev-parse", "--abbrev-ref", "HEAD"], cwd=source)
        if code != 0 or base_branch in {"", "HEAD"}:
            return {**payload, "ok": False,
                    "error": err or "cannot name the base branch (detached HEAD?)"}

    if root.exists():
        code, current_branch, err = _run(
            ["git", "rev-parse", "--abbrev-ref", "HEAD"], cwd=str(root)
        )
        if code != 0 or current_branch != branch:
            return {**payload, "ok": False,
                    "error": err or "existing worktree is not on the run branch"}
        base_sha = payload.get("base_sha")
        if not base_sha:
            code, base_sha, err = _run(
                ["git", "merge-base", "HEAD", str(base_branch)], cwd=str(root)
            )
            if code != 0 or not base_sha:
                return {**payload, "ok": False,
                        "error": err or "cannot recover the existing worktree base"}
        resolved = {"base_branch": base_branch, "base_sha": base_sha}
        install_skills(root)
        return {**payload, **resolved, "ok": True, "worktree": str(root), "branch": branch}

    base_sha = payload.get("base_sha")
    if not base_sha:
        code, base_sha, err = _run(["git", "rev-parse", str(base_branch)], cwd=source)
        if code != 0:
            return {**payload, "ok": False, "error": err or "cannot resolve base"}
    resolved = {"base_branch": base_branch, "base_sha": base_sha}

    # Preflight and the engine may have different environments. When startup
    # forwarded a vault, re-resolve it here so #70 cannot launch a run against
    # a path that disappeared. Direct callers historically need no vault.
    if os.environ.get("SIGNALBOX_VAULT"):
        vault_dir()

    root.parent.mkdir(parents=True, exist_ok=True)
    code, _, err = _run(
        ["git", "worktree", "add", "-b", branch, str(root), base_sha], cwd=source
    )
    if code != 0:
        return {**payload, "ok": False, "error": err}
    code, head, err = _run(["git", "rev-parse", "HEAD"], cwd=str(root))
    if code != 0 or head != base_sha:
        return {**payload, **resolved, "ok": False, "worktree": str(root),
                "error": err or "created worktree is not at the pinned base"}
    skills = install_skills(root)
    return {**payload, **resolved, "ok": True, "worktree": str(root), "branch": branch,
            "skills": skills}


def source_repo(git_common_dir: str) -> Path:
    """The repository a worktree belongs to, given its common git dir.

    Pure, because the path arithmetic is the only part worth testing and it
    should not need a repository to exercise. Recovering the source this way
    rather than reading `repo_path` is deliberate: `repo_path` is not in
    CARRIED_KEYS, so it does not survive to a run terminal, and falling back to
    `os.getcwd()` would silently release against whichever tree the engine
    happens to be sitting in.
    """
    common = Path(git_common_dir)
    return common.parent if common.name == ".git" else common


def release_workspace(payload: dict) -> dict:
    """Give back the worktree a finished run was built in.

    Subscribed to `run.completed` rather than `pr.merged`, and the difference is
    load-bearing since #69: notes drafting now starts at `checks.passed` and
    overlaps the merge, and `dispatch` runs every agent with `cwd` set to this
    worktree. Releasing at the merge would delete the directory out from under
    a `write-note` agent that is still working in it. `run.completed` is the
    two-arm rendezvous, so it is the first moment nothing is left inside.

    A halted run keeps its worktree on purpose. That tree is the evidence for
    why it halted, and reclaiming disk is not worth destroying it.
    """
    root = worktree_for(payload)
    branch = branch_for(payload)

    if not root.exists():
        # Releasing twice is not a failure. The state this asserts already holds.
        return {**payload, "ok": True, "worktree": str(root), "released": False}

    code, common, err = _run(
        ["git", "rev-parse", "--path-format=absolute", "--git-common-dir"],
        cwd=str(root),
    )
    if code != 0:
        return {**payload, "ok": False, "worktree": str(root),
                "error": err or "cannot locate the repository this worktree belongs to"}
    source = str(source_repo(common))

    code, out, err = _run(["git", "worktree", "remove", "--force", str(root)], cwd=source)
    if code != 0:
        return {**payload, "ok": False, "worktree": str(root),
                "error": err or out or f"worktree remove exited {code}"}

    # merge-pr already deleted the remote ref. The local branch is the last
    # thing still pinning the run's history here, but losing it is not a reason
    # to call a released workspace a failure — the worktree is already gone.
    code, out, err = _run(["git", "branch", "-D", branch], cwd=source)
    if code != 0:
        return {**payload, "ok": True, "worktree": str(root), "released": True,
                "warning": err or out or f"local branch deletion exited {code}"}
    return {**payload, "ok": True, "worktree": str(root), "branch": branch,
            "released": True}


# ── issue ────────────────────────────────────────────────────────────────────


def fetch_issue(payload: dict) -> dict:
    """Enough of the issue to start a run and to name the PR at the end.

    Deliberately not "everything the planner needs to read". This call fetches
    identity — the title that becomes the PR title (#80), the labels, the body
    that seeds the first read — and stops there. Any fixed field list is a guess
    about what a future issue will require, and the guess was wrong for sb-62:
    the answer it needed sat in a comment nobody had asked GitHub for. The
    planning agent has `gh` and reads the thread itself, so what it can reach is
    bounded by the issue, not by this argv.
    """
    # A launch may carry the issue text directly, for a repository with no
    # GitHub remote. There is then nothing to fetch, and saying so is more
    # honest than calling gh and failing.
    if str(payload.get("body") or "").strip():
        return {**payload, "ok": True, "source": "launch"}

    issue = payload.get("issue")
    repo = payload.get("repo")
    cmd = ["gh", "issue", "view", str(issue), "--json", "number,title,body,labels"]
    if repo:
        cmd += ["--repo", str(repo)]
    code, out, err = _run(cmd, timeout=30)
    if code != 0:
        return {**payload, "ok": False, "error": err or f"gh exited {code}"}
    try:
        data = json.loads(out)
    except json.JSONDecodeError as exc:
        return {**payload, "ok": False, "error": f"unreadable issue response: {exc}"}
    if not isinstance(data, dict) or data.get("title") is None:
        return {**payload, "ok": False, "error": "issue response carried no title"}
    return {
        **payload,
        "ok": True,
        "title": data.get("title"),
        "body": data.get("body"),
        "labels": [label.get("name") for label in data.get("labels") or []],
    }


# ── suite ────────────────────────────────────────────────────────────────────


# One marker, then the runners that can reach that marker's suite, in order of
# preference. A test runner is usually not a bare binary on PATH — it lives in
# the project's own environment — so the project's manager has to be tried first.
SUITE_COMMANDS: tuple[tuple[str, tuple[list[str], ...]], ...] = (
    ("Cargo.toml", (["cargo", "nextest", "run"], ["cargo", "test"])),
    ("pyproject.toml", (["uv", "run", "pytest", "-q"], ["pytest", "-q"])),
    ("package.json", (["pnpm", "test"], ["npm", "test"])),
)


def suite_command(root: Path) -> list[str] | None:
    """The suite this repo actually has and a runner that can reach it, or None.

    "Is the binary on PATH" is not the same question as "can this repo's suite
    run". signalbox's own 102 tests live behind `uv run pytest`; bare `pytest` is
    not installed anywhere, so detection once reported "no suite detected"
    against its own checkout. `run_suite` now distinguishes that condition from
    a repository with no suite: a marker with no reachable runner publishes
    `errored: true` for the topology's human-facing error route, while no marker
    publishes `ran: false, errored: false` for the assessor's human checkpoint.
    """
    for marker, candidates in SUITE_COMMANDS:
        if not (root / marker).exists():
            continue
        for cmd in candidates:
            if shutil.which(cmd[0]):
                return cmd
    return None


def suite_counts(output: str) -> tuple[int, int]:
    """Extract passed and failed test counts from supported runners' summaries."""
    cargo_summaries = re.findall(
        r"test result: [^.]+\.\s*(\d+) passed;\s*(\d+) failed",
        output,
        flags=re.IGNORECASE,
    )
    if cargo_summaries:
        return (
            sum(int(passed) for passed, _ in cargo_summaries),
            sum(int(failed) for _, failed in cargo_summaries),
        )

    for line in reversed(output.splitlines()):
        passed = re.search(r"\b(\d+)\s+passed\b", line, flags=re.IGNORECASE)
        failed = re.search(r"\b(\d+)\s+failed\b", line, flags=re.IGNORECASE)
        if passed or failed:
            return (
                int(passed.group(1)) if passed else 0,
                int(failed.group(1)) if failed else 0,
            )
    return 0, 0


def run_suite(payload: dict) -> dict:
    try:
        root = require_worktree(payload)
    except WorktreeMissing as exc:
        # Distinct from "this repo has no suite": we could not even look.
        return {
            **payload, "ran": False, "ok": False, "passed": 0, "failed": 0,
            "errored": False, "reason": str(exc),
        }
    cmd = suite_command(root)
    if cmd is None:
        detected = [marker for marker, _ in SUITE_COMMANDS if (root / marker).exists()]
        if detected:
            return {
                **payload, "ran": False, "ok": False, "passed": 0, "failed": 0,
                "errored": True,
                "reason": f"suite detected but no runner available ({detected[0]})",
            }
        # Absence is a fact worth publishing, not a pass.
        return {
            **payload, "ran": False, "ok": False, "passed": 0, "failed": 0,
            "errored": False, "reason": "no suite detected",
        }
    try:
        code, out, err = _run(cmd, cwd=str(root), timeout=1800)
    except OSError as exc:
        return {
            **payload, "ran": False, "ok": False, "passed": 0, "failed": 0,
            "errored": True, "reason": f"suite runner could not be invoked: {exc}",
        }
    output = (out + "\n" + err).strip()
    passed, failed = suite_counts(output)
    return {
        **payload,
        "ran": True,
        "ok": code == 0,
        "passed": passed,
        "failed": failed,
        "errored": False,
        "exit_code": code,
        "command": " ".join(cmd),
        "output": output[-8000:],
    }


# ── stage landing ────────────────────────────────────────────────────────────


def stage_files(payload: dict) -> list[str]:
    """Every path the stage's shards declared, deduplicated and ordered."""
    seen: dict[str, None] = {}
    for result in payload.get("results") or []:
        for path in result.get("declared") or []:
            seen.setdefault(str(path), None)
    return list(seen)


def merge_stage(payload: dict) -> dict:
    root = str(worktree_for(payload))
    files = stage_files(payload)
    if not files:
        return {**payload, "ok": False, "conflicts": [], "error": "stage declared no files"}

    code, _, err = _run(["git", "add", "--", *files], cwd=root)
    if code != 0:
        return {**payload, "ok": False, "conflicts": [], "error": err}

    message = f"stage({payload.get('stage_id')}): {payload.get('issue', '')}".strip()
    code, out, err = _run(["git", "commit", "-S", "-m", message], cwd=root)
    if code != 0 and "nothing to commit" not in (out + err).lower():
        return {**payload, "ok": False, "conflicts": [], "error": err or out}

    code, sha, err = _run(["git", "rev-parse", "HEAD"], cwd=root)
    if code != 0 or not sha:
        return {**payload, "ok": False, "conflicts": [],
                "error": err or "could not verify the stage commit"}
    return {**payload, "ok": True, "sha": sha, "files": files}


# ── promotion ────────────────────────────────────────────────────────────────


def push_branch_command(branch: str) -> list[str]:
    """Build the push argv for a branch that may have been rebased."""
    return ["git", "push", "--force-with-lease", "-u", "origin", branch]


def push_branch(payload: dict) -> dict:
    root = str(worktree_for(payload))
    branch = branch_for(payload)
    sha_code, sha, sha_err = _run(["git", "rev-parse", "HEAD"], cwd=root)
    if sha_code != 0 or not sha:
        return {**payload, "ok": False, "error": sha_err or "cannot identify branch tip"}
    # The lease is a fix-loop and approval re-entry safety net, not the primary
    # rebase path. Force-pushing an existing PR makes its old suite stale or
    # cancelled, and the check router deliberately drops those conclusions, so
    # the rebase belongs before the first push and this only protects a repeat.
    code, out, err = _run(push_branch_command(branch), cwd=root, timeout=120)
    verify_code, remote, verify_err = _run(
        ["git", "ls-remote", "--heads", "origin", f"refs/heads/{branch}"],
        cwd=root,
        timeout=45,
    )
    remote_sha = remote.split(maxsplit=1)[0] if remote else ""
    if verify_code != 0 or remote_sha != sha:
        reason = err or out or verify_err or "remote branch does not match local tip"
        return {**payload, "ok": False, "error": reason}
    return {**payload, "ok": True, "branch": branch, "sha": sha}


def open_pr(payload: dict) -> dict:
    """Open the PR against the base the run was actually pinned to.

    An absent base is a failure rather than a default. Letting `gh` choose meant
    letting it choose the repository default branch, so a run launched from any
    other branch opened a PR carrying every commit between the two — reviewed,
    gated, and sized as if it were the shard's diff alone.
    """
    base_branch = payload.get("base_branch")
    if not base_branch:
        return {**payload, "ok": False,
                "error": "no base_branch on the run; refusing to let gh pick one"}

    root = str(worktree_for(payload))
    cmd = [
        "gh", "pr", "create",
        "--base", str(base_branch),
        "--head", branch_for(payload),
        "--title", f"{payload.get('title') or 'signalbox'} (#{payload.get('issue')})",
        "--body", f"Closes #{payload.get('issue')}\n\nOpened by signalbox run `{payload.get('run_id')}`.",
    ]
    code, out, err = _run(cmd, cwd=root, timeout=60)
    candidate = out.rstrip("/").rsplit("/", 1)[-1] if out else ""
    expected_head = branch_for(payload)
    # `gh pr create` refuses on the designed CI fix-loop re-entry because the
    # head already has an open PR. View by branch in that case: the observed
    # remote state, not create's exit status, says whether the outcome holds.
    view_target = candidate or expected_head
    view_code, view_out, view_err = _run(
        ["gh", "pr", "view", view_target,
         "--json", "number,url,baseRefName,headRefName,state"],
        cwd=root,
        timeout=45,
    )
    try:
        observed = json.loads(view_out)
    except json.JSONDecodeError:
        observed = {}
    observed_number = str(observed.get("number") or "")
    verified = (
        view_code == 0
        and isinstance(observed, dict)
        and bool(observed_number)
        and (not candidate or observed_number == candidate)
        and observed.get("baseRefName") == str(base_branch)
        and observed.get("headRefName") == expected_head
        and str(observed.get("state") or "").upper() == "OPEN"
    )
    if not verified:
        return {**payload, "ok": False,
                "error": err or view_err or "could not verify the requested PR was opened"}
    return {
        **payload, "ok": True, "url": observed.get("url") or out,
        "pr": observed_number,
    }


def pr_state_is_merged(raw: str) -> bool:
    """Whether a PR-state response says the merge landed.

    Pure, and separated from the commands on purpose: `gh pr merge` may exit
    non-zero after GitHub accepted the merge when its local branch cleanup
    fails. The remote PR state, not that process status, is authoritative.
    """
    try:
        body = json.loads(raw)
    except (json.JSONDecodeError, TypeError):
        return False
    return (
        isinstance(body, dict)
        and str(body.get("state") or "").upper() == "MERGED"
        and bool(body.get("mergedAt"))
    )


def merge_pr(payload: dict) -> dict:
    root = str(worktree_for(payload))
    pr = str(payload.get("pr"))
    merge_code, merge_out, merge_err = _run(
        ["gh", "pr", "merge", pr, "--squash"],
        cwd=root,
        timeout=120,
    )
    state_code, state_out, state_err = _run(
        ["gh", "pr", "view", pr, "--json", "state,mergedAt"],
        cwd=root,
        timeout=45,
    )
    if state_code != 0 or not pr_state_is_merged(state_out):
        error = merge_err or merge_out or state_err or state_out
        if not error:
            error = (
                f"merge exited {merge_code}; PR state could not verify that the merge landed"
            )
        return {**payload, "ok": False, "error": error}

    branch = branch_for(payload)
    delete_code, delete_out, delete_err = _run(
        [
            "gh", "api", "-X", "DELETE",
            f"repos/{{owner}}/{{repo}}/git/refs/heads/{branch}",
        ],
        cwd=root,
        timeout=45,
    )
    if delete_code != 0:
        warning = delete_err or delete_out or f"remote branch deletion exited {delete_code}"
        return {**payload, "ok": True, "warning": warning}
    return {**payload, "ok": True}


def issue_state_is_closed(raw: str) -> bool:
    """Whether an issue-state response says the issue is closed."""
    try:
        body = json.loads(raw)
    except (json.JSONDecodeError, TypeError):
        return False
    return (
        isinstance(body, dict)
        and str(body.get("state") or "").upper() == "CLOSED"
    )


def close_issue(payload: dict) -> dict:
    """Close the run's issue and verify the observed remote state."""
    repo = payload.get("repo")
    if not repo:
        return {**payload, "ok": True}

    issue = str(payload.get("issue"))
    close_code, close_out, close_err = _run(
        ["gh", "issue", "close", issue, "--repo", str(repo)],
        timeout=45,
    )
    state_code, state_out, state_err = _run(
        ["gh", "issue", "view", issue, "--repo", str(repo), "--json", "state"],
        timeout=30,
    )
    if state_code != 0 or not issue_state_is_closed(state_out):
        error = close_err or close_out or state_err or state_out
        if not error:
            error = (
                f"close exited {close_code}; issue state could not verify closure"
            )
        return {**payload, "ok": False, "error": error}
    return {**payload, "ok": True}


# Conclusions GitHub reports that do not mean "this broke". Shared by the suite
# router in the topology and the per-check detail fetch below, so the two can
# never disagree about what counts as green.
PASSING_CONCLUSIONS = frozenset({"SUCCESS", "NEUTRAL", "SKIPPED"})


def failed_check_names(records: list[dict]) -> list[str]:
    """Which check runs did not pass, from a check-runs listing.

    Pure, and separated from the fetch on purpose: the judgment worth testing is
    which conclusions count as failure, and that should not need a network.
    """
    return [
        str(run.get("name") or "unnamed")
        for run in records
        if str(run.get("conclusion") or "").upper() not in PASSING_CONCLUSIONS
    ]


def check_details(payload: dict) -> dict:
    """Describe the checks behind a failed suite from its check-runs listing.

    A `check_suite` webhook carries one conclusion and no per-check detail, so the
    names have to be fetched. This is the only I/O on the failure path and the
    happy path never reaches it. Failure to fetch is data, not an exception: the
    fix loop still gets its event, with an empty list and a stated reason.
    """
    url = payload.get("check_runs_url")
    if not url:
        return {**payload, "ok": False, "failed": [], "detail_ok": False,
                "reason": "the suite carried no check_runs_url"}
    code, out, err = _run(["gh", "api", str(url)], timeout=45)
    if code != 0 or not out:
        return {**payload, "ok": False, "failed": [], "detail_ok": False,
                "reason": err or "gh api returned nothing"}
    try:
        body = json.loads(out)
    except json.JSONDecodeError as exc:
        return {**payload, "ok": False, "failed": [], "detail_ok": False,
                "reason": f"unreadable check-runs listing: {exc}"}
    records = body.get("check_runs") if isinstance(body, dict) else body
    if not isinstance(records, list):
        return {**payload, "ok": False, "failed": [], "detail_ok": False,
                "reason": "check-runs listing carried no records"}
    failed_names = failed_check_names(records)
    failed = []
    for record, name in zip(
        (record for record in records
         if str(record.get("conclusion") or "").upper() not in PASSING_CONCLUSIONS),
        failed_names,
    ):
        check = {key: record[key] for key in ("id", "details_url", "html_url")
                 if key in record}
        check["name"] = name
        if isinstance(record.get("output"), dict):
            output = {key: record["output"][key] for key in ("title", "summary")
                      if key in record["output"]}
            if output:
                check["output"] = output
        failed.append(check)
    return {**payload, "ok": True, "failed": failed, "detail_ok": True}


def map_ci_findings(payload: dict) -> dict:
    """Turn a red build into review findings, so the existing fix loop handles it."""
    identity = {
        key: payload[key]
        for key in ("pr", "sha", "run_id", "repo", "check_runs_url")
        if key in payload
    }
    findings = []
    for failed in payload.get("failed") or []:
        check = failed if isinstance(failed, dict) else {"name": str(failed)}
        finding = {"source": "ci", **identity}
        if "name" in check:
            finding["check"] = check["name"]
        finding.update({key: check[key] for key in ("id", "output", "details_url", "html_url")
                        if key in check})
        findings.append(finding)
    if not findings:
        finding = {"source": "ci", **identity}
        if "reason" in payload:
            finding["reason"] = payload["reason"]
        findings.append(finding)
    return {
        **payload,
        "verdict": "changes_requested",
        "round": int(payload.get("round") or 1),
        "findings": findings,
    }


# ── silence ──────────────────────────────────────────────────────────────────


def _session_path(run_id: str, shard_id: str) -> Path:
    return sessions_dir(run_id) / f"session-{shard_id}.json"


def read_session(run_id: str, shard_id: str) -> dict | None:
    """The runner session recorded for a shard, or no resumable session."""
    try:
        session = json.loads(_session_path(run_id, shard_id).read_text())
    except (OSError, json.JSONDecodeError):
        return None
    if (
        not isinstance(session, dict)
        or not isinstance(session.get("runner"), str)
        or not isinstance(session.get("session_id"), str)
    ):
        return None
    return {"runner": session["runner"], "session_id": session["session_id"]}


def record_session(
    run_id: str, shard_id: str, runner: str, session_id: str
) -> Path:
    """Persist the runner identity needed to resume this shard next round."""
    path = _session_path(run_id, shard_id)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"runner": runner, "session_id": session_id}))
    return path


def clear_session(run_id: str, shard_id: str) -> bool:
    """Forget a shard's runner session once that shard is retired."""
    path = _session_path(run_id, shard_id)
    existed = path.exists()
    path.unlink(missing_ok=True)
    return existed


def reap(kind: str, stale_minutes: int) -> str:
    """Pending markers older than the threshold, as one JSON line each."""
    import time

    directory = state_dir() / "pending"
    if not directory.is_dir():
        return ""
    cutoff = time.time() - stale_minutes * 60
    lines = []
    for marker in sorted(directory.glob(f"{kind}-*.json")):
        try:
            if marker.stat().st_mtime > cutoff:
                continue
            payload = json.loads(marker.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        marker.unlink(missing_ok=True)
        if kind == "shard":
            clear_session(
                str(payload.get("run_id", "unknown")),
                str(payload.get("shard_id", "unknown")),
            )
        lines.append(
            json.dumps({**payload, "outcome": "silent", "reason": f"{kind} emitted nothing"})
        )
    return "\n".join(lines)


def mark_pending(kind: str, payload: dict) -> Path:
    """Record that something is now being waited on, so its silence can be named.

    A push source makes arrivals observable and silence invisible. If GitHub never
    delivers `check_suite.completed` — no workflow on the branch, a revoked hook, a
    dropped delivery — there is no event to subscribe to and the run waits forever,
    which is exactly how a gate-cleared run sat at `pr.opened` indefinitely. The
    marker is the thing a reaper can find later; without it, waiting and hanging
    are the same observation.
    """
    from signalbox.dispatch import pending_path
    from signalbox.identity import project

    marker = pending_path(kind, payload)
    marker.parent.mkdir(parents=True, exist_ok=True)
    stored = project(payload) if kind == "approval" else payload
    marker.write_text(json.dumps(stored))
    return marker


def rehydrated(stored: dict, observed: dict) -> dict:
    """Stored identity fills the gaps; observed facts win. Pure.

    Observed wins because the marker describes what we asked for and the event
    describes what happened — a suite's `sha` is the commit actually tested, which
    is the truer value even when the marker holds an earlier one.
    """
    return {**stored, **observed}


class PendingMissing(RuntimeError):
    """No marker for something we were asked to rehydrate."""


def rehydrate(kind: str, payload: dict) -> dict:
    """Restore run identity from the pending marker, and clear it.

    A webhook knows about a commit, not about a run. GitHub can tell us the head
    branch and the conclusion, but not the issue number or the base sha the run
    was pinned to, and the notes stage past pr.merged needs both. They are read
    back from what `pr.opened` recorded rather than guessed.

    Clearing is the same act deliberately: a check suite that concluded is not a
    silent one, and a separate clearer is a second thing to forget to wire.

    A missing marker raises rather than returning `ok: false`. Every other act
    treats a false outcome as data, but this is not an outcome — it means a suite
    arrived for a signalbox branch this engine is not tracking (a leftover PR from
    an earlier run, most likely), and there is no run to attribute it to.
    """
    from signalbox.dispatch import pending_path

    marker = pending_path(kind, payload)
    try:
        stored = json.loads(marker.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise PendingMissing(
            f"no {kind} marker at {marker}: {exc}"
        ) from exc
    marker.unlink(missing_ok=True)
    return rehydrated(stored, payload)


def clear_pending(kind: str, payload: dict) -> bool:
    """Forget the marker for a shard that has now been heard from.

    The marker exists to give silence a name, and an agent that announced is not
    silent. Nothing cleared these before, so the reaper eventually reported every
    successful shard as `shard.silent` — demo-3's two shards were both reported
    silent nineteen minutes after they were approved and merged.
    """
    from signalbox.dispatch import pending_path

    marker = pending_path(kind, payload)
    existed = marker.exists()
    marker.unlink(missing_ok=True)
    if kind == "shard" and payload.get("event") in {
        "shard.approved",
        "scope.violated",
        "pr.merged",
    }:
        clear_session(
            str(payload.get("run_id", "unknown")),
            str(payload.get("shard_id", "unknown")),
        )
    return existed


def approve(run_id: str) -> dict:
    """Replay a parked run's stored identity through the control ingress."""
    from signalbox import emit
    from signalbox.dispatch import pending_path
    from signalbox.identity import project

    marker = pending_path("approval", {"run_id": run_id})
    try:
        stored = json.loads(marker.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        return {
            "run_id": run_id,
            "ok": False,
            "error": f"no approval marker at {marker}: {exc}",
        }

    identity = project(stored)
    body = {"event": "approval.granted", **identity}
    status = emit.post(body, url=emit.control_url())
    return {**identity, "ok": True, "status": status}


def notify(payload: dict) -> None:
    label = payload.get("reason") or payload.get("decision") or "attention"
    print(f"[signalbox] {label}: run={payload.get('run_id')} shard={payload.get('shard_id')}")
    # Only the human gate asks for approval; other notification topics remain
    # labels so operator commands are never suggested outside their live context.
    if (
        payload.get("event") == "approval.requested"
        or payload.get("decision") == "needs_human"
    ):
        print(f"signalbox approve {payload.get('run_id')}")
    hook = os.environ.get("SIGNALBOX_NOTIFY_COMMAND")
    if hook:
        subprocess.run(["bash", "-c", hook], input=json.dumps(payload), text=True, check=False)


# ── dispatch ─────────────────────────────────────────────────────────────────


def main(command: str, argv: list[str]) -> int:
    if command == "reap":
        import argparse

        parser = argparse.ArgumentParser(prog="signalbox reap")
        parser.add_argument("--kind", default="shard")
        parser.add_argument("--stale-minutes", type=int, default=20)
        args = parser.parse_args(argv)
        print(reap(args.kind, args.stale_minutes))
        return 0

    if command == "launch":
        import argparse

        from signalbox.emit import post

        parser = argparse.ArgumentParser(prog="signalbox launch")
        parser.add_argument("issue", type=int)
        parser.add_argument("--repo", default=None, help="owner/name, for gh")
        parser.add_argument("--repo-path", default=None, help="the git repo to branch from")
        parser.add_argument("--run-id", default=None)
        parser.add_argument("--title", default=None)
        parser.add_argument("--body-file", default=None, help="issue text, when there is no remote")
        parser.add_argument("--base-branch", default=None)
        args = parser.parse_args(argv)

        run_id = args.run_id or f"{args.issue}-{os.getpid()}"
        request = {
            "event": "run.requested",
            "run_id": run_id,
            "issue": args.issue,
            "repo": args.repo,
            "repo_path": os.path.abspath(args.repo_path) if args.repo_path else os.getcwd(),
        }
        if args.title:
            request["title"] = args.title
        if args.base_branch:
            request["base_branch"] = args.base_branch
        if args.body_file:
            request["body"] = Path(args.body_file).read_text()
        post(request)
        print(run_id)
        return 0

    if command == "approve":
        import argparse

        parser = argparse.ArgumentParser(prog="signalbox approve")
        parser.add_argument("run_id")
        args = parser.parse_args(argv)
        return _out(approve(args.run_id))

    if command in {"mark-pending", "clear-pending", "rehydrate"}:
        import argparse

        parser = argparse.ArgumentParser(prog=f"signalbox {command}")
        parser.add_argument("--kind", default="shard")
        args = parser.parse_args(argv)
        payload = _payload()
        if command == "rehydrate":
            return _out(rehydrate(args.kind, payload))
        act = mark_pending if command == "mark-pending" else clear_pending
        act(args.kind, payload)
        return 0

    payload = _payload()

    if command == "notify":
        notify(payload)
        return 0

    handlers = {
        "prepare-workspace": prepare_workspace,
        "release-workspace": release_workspace,
        "fetch-issue": fetch_issue,
        "run-suite": run_suite,
        "merge-stage": merge_stage,
        "push-branch": push_branch,
        "open-pr": open_pr,
        "merge-pr": merge_pr,
        "close-issue": close_issue,
        "check-details": check_details,
        "map-ci-findings": map_ci_findings,
    }
    return _out(handlers[command](payload))
