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
import shutil
import subprocess
import sys
from pathlib import Path

from signalbox.dispatch import state_dir


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


def worktree_for(payload: dict) -> Path:
    return state_dir() / "worktrees" / str(payload.get("run_id", "unknown"))


def branch_for(payload: dict) -> str:
    return f"signalbox/run-{payload.get('run_id', 'unknown')}"


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

    code, base_sha, err = _run(
        ["git", "rev-parse", str(payload.get("base_branch") or "HEAD")], cwd=source
    )
    if code != 0:
        return {**payload, "ok": False, "error": err or "cannot resolve base"}

    if root.exists():
        return {**payload, "ok": True, "worktree": str(root), "branch": branch, "base_sha": base_sha}

    root.parent.mkdir(parents=True, exist_ok=True)
    code, _, err = _run(
        ["git", "worktree", "add", "-b", branch, str(root), base_sha], cwd=source
    )
    if code != 0:
        return {**payload, "ok": False, "error": err}
    return {**payload, "ok": True, "worktree": str(root), "branch": branch, "base_sha": base_sha}


# ── issue ────────────────────────────────────────────────────────────────────


def fetch_issue(payload: dict) -> dict:
    issue = payload.get("issue")
    repo = payload.get("repo")
    cmd = ["gh", "issue", "view", str(issue), "--json", "number,title,body,labels"]
    if repo:
        cmd += ["--repo", str(repo)]
    code, out, err = _run(cmd, timeout=30)
    if code != 0:
        return {**payload, "ok": False, "error": err or f"gh exited {code}"}
    data = json.loads(out)
    return {
        **payload,
        "ok": True,
        "title": data.get("title"),
        "body": data.get("body"),
        "labels": [label.get("name") for label in data.get("labels") or []],
    }


# ── suite ────────────────────────────────────────────────────────────────────


SUITE_COMMANDS = (
    ("Cargo.toml", ["cargo", "nextest", "run"]),
    ("pyproject.toml", ["pytest", "-q"]),
    ("package.json", ["pnpm", "test"]),
)


def suite_command(root: Path) -> list[str] | None:
    """The suite this repo actually has, or None."""
    for marker, cmd in SUITE_COMMANDS:
        if (root / marker).exists() and shutil.which(cmd[0]):
            return cmd
    return None


def run_suite(payload: dict) -> dict:
    root = worktree_for(payload)
    cmd = suite_command(root)
    if cmd is None:
        # Absence is a fact worth publishing, not a pass.
        return {**payload, "ran": False, "passed": 0, "failed": 0, "reason": "no suite detected"}
    code, out, err = _run(cmd, cwd=str(root), timeout=1800)
    return {
        **payload,
        "ran": True,
        "ok": code == 0,
        "exit_code": code,
        "command": " ".join(cmd),
        "output": (out + "\n" + err).strip()[-8000:],
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

    code, sha, _ = _run(["git", "rev-parse", "HEAD"], cwd=root)
    return {**payload, "ok": True, "sha": sha, "files": files}


# ── promotion ────────────────────────────────────────────────────────────────


def push_branch(payload: dict) -> dict:
    root = str(worktree_for(payload))
    branch = branch_for(payload)
    code, _, err = _run(["git", "push", "-u", "origin", branch], cwd=root, timeout=120)
    if code != 0:
        return {**payload, "ok": False, "error": err}
    _, sha, _ = _run(["git", "rev-parse", "HEAD"], cwd=root)
    return {**payload, "ok": True, "branch": branch, "sha": sha}


def open_pr(payload: dict) -> dict:
    root = str(worktree_for(payload))
    cmd = [
        "gh", "pr", "create",
        "--head", branch_for(payload),
        "--title", f"{payload.get('title') or 'signalbox'} (#{payload.get('issue')})",
        "--body", f"Closes #{payload.get('issue')}\n\nOpened by signalbox run `{payload.get('run_id')}`.",
    ]
    if payload.get("base_branch"):
        cmd += ["--base", str(payload["base_branch"])]
    code, out, err = _run(cmd, cwd=root, timeout=60)
    if code != 0:
        return {**payload, "ok": False, "error": err}
    return {**payload, "ok": True, "url": out, "pr": out.rstrip("/").rsplit("/", 1)[-1]}


def merge_pr(payload: dict) -> dict:
    code, out, err = _run(
        ["gh", "pr", "merge", str(payload.get("pr")), "--squash", "--delete-branch"],
        cwd=str(worktree_for(payload)),
        timeout=120,
    )
    if code != 0:
        return {**payload, "ok": False, "error": err or out}
    return {**payload, "ok": True}


def poll_checks() -> str:
    """One line of JSON per PR whose checks have concluded, for the interval source."""
    code, out, _ = _run(
        ["gh", "pr", "list", "--head", "signalbox/", "--json", "number,headRefName,statusCheckRollup"],
        timeout=45,
    )
    if code != 0 or not out:
        return ""
    lines = []
    for pr in json.loads(out):
        rollup = pr.get("statusCheckRollup") or []
        states = {check.get("conclusion") for check in rollup if check.get("conclusion")}
        if not rollup or None in states:
            continue
        conclusion = "success" if states <= {"SUCCESS", "NEUTRAL", "SKIPPED"} else "failure"
        lines.append(
            json.dumps(
                {
                    "pr": pr.get("number"),
                    "run_id": pr.get("headRefName", "").removeprefix("signalbox/run-"),
                    "conclusion": conclusion,
                    "failed": [c.get("name") for c in rollup if c.get("conclusion") not in {"SUCCESS", "NEUTRAL", "SKIPPED"}],
                }
            )
        )
    return "\n".join(lines)


def map_ci_findings(payload: dict) -> dict:
    """Turn a red build into review findings, so the existing fix loop handles it."""
    return {
        **payload,
        "verdict": "changes_requested",
        "round": int(payload.get("round") or 1),
        "findings": [
            {"source": "ci", "check": name, "detail": "CI check failed after merge"}
            for name in payload.get("failed") or []
        ],
    }


# ── silence ──────────────────────────────────────────────────────────────────


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
        lines.append(
            json.dumps({**payload, "outcome": "silent", "reason": f"{kind} emitted nothing"})
        )
    return "\n".join(lines)


def notify(payload: dict) -> None:
    label = payload.get("reason") or payload.get("decision") or "attention"
    print(f"[signalbox] {label}: run={payload.get('run_id')} shard={payload.get('shard_id')}")
    hook = os.environ.get("SIGNALBOX_NOTIFY_COMMAND")
    if hook:
        subprocess.run(["bash", "-c", hook], input=json.dumps(payload), text=True, check=False)


# ── dispatch ─────────────────────────────────────────────────────────────────


def main(command: str, argv: list[str]) -> int:
    if command == "poll-checks":
        print(poll_checks())
        return 0

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
        parser.add_argument("--repo", default=None)
        parser.add_argument("--run-id", default=None)
        args = parser.parse_args(argv)
        run_id = args.run_id or f"{args.issue}-{os.getpid()}"
        post({"event": "run.requested", "run_id": run_id, "issue": args.issue, "repo": args.repo})
        print(run_id)
        return 0

    payload = _payload()

    if command == "notify":
        notify(payload)
        return 0

    handlers = {
        "prepare-workspace": prepare_workspace,
        "fetch-issue": fetch_issue,
        "run-suite": run_suite,
        "merge-stage": merge_stage,
        "push-branch": push_branch,
        "open-pr": open_pr,
        "merge-pr": merge_pr,
        "map-ci-findings": map_ci_findings,
    }
    return _out(handlers[command](payload))
