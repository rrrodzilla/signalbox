"""What the viewer actually puts on the wire.

`test_the_page_treats_heartbeat_traffic_as_proof_of_life_not_content` asserted
the page filters reaper noise, and it passed for the entire afternoon during
which port 8103 served a page that did not. The invariant was checked against the
working tree and the defect was in the delivery, so every test agreed with the
source and disagreed with the browser.

These tests exercise the served bytes instead.
"""

from __future__ import annotations

import http.client
import json
import os
import subprocess
import sqlite3
import threading
import time
from http.server import HTTPServer
from pathlib import Path

import pytest

from signalbox.dashboard import PAGE, handler_class

ROOT = Path(__file__).resolve().parent.parent


@pytest.fixture
def serving(tmp_path: Path):
    """A live viewer over a throwaway page, on an ephemeral port."""
    page = tmp_path / "dashboard.html"
    page.write_text("<h1>first</h1>")
    first_store = tmp_path / "first.db"
    second_store = tmp_path / "second.db"
    _store(
        first_store,
        [
            ("later", "shard.submitted", "dispatch-implement", 20, {"run_id": "sb-2"}),
            ("earlier", "run.started", "launch", 10, {"run_id": "sb-1"}),
        ],
    )
    _store(
        second_store,
        [("other", "run.started", "launch", 5, {"run_id": "other"})],
    )
    server = HTTPServer(
        ("127.0.0.1", 0),
        handler_class(
            page,
            stores={
                8101: first_store,
                8201: second_store,
                8301: tmp_path / "missing.db",
            },
        ),
    )
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()

    def get(path: str = "/"):
        connection = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=5)
        try:
            connection.request("GET", path)
            response = connection.getresponse()
            return response.status, response.headers, response.read()
        finally:
            connection.close()

    try:
        yield page, get
    finally:
        server.shutdown()
        server.server_close()


def _store(path: Path, rows: list[tuple[str, str, str, int, dict]]) -> None:
    with sqlite3.connect(path) as connection:
        connection.execute(
            "CREATE TABLE events ("
            "id TEXT PRIMARY KEY, message_type TEXT, source TEXT NOT NULL, "
            "timestamp_ms INTEGER, payload_json TEXT)"
        )
        connection.executemany(
            "INSERT INTO events VALUES (?, ?, ?, ?, ?)",
            [
                (event_id, message_type, source, timestamp_ms, json.dumps(payload))
                for event_id, message_type, source, timestamp_ms, payload in rows
            ],
        )


def test_history_has_the_stream_shape_in_timestamp_order(serving):
    _, get = serving

    status, headers, body = get("/history?stream=8101")

    assert status == 200
    assert headers.get("Content-Type") == "application/json"
    assert json.loads(body) == [
        {
            "type": "run.started",
            "source": "launch",
            "timestamp": 10,
            "payload": {"run_id": "sb-1"},
            "id": "earlier",
        },
        {
            "type": "shard.submitted",
            "source": "dispatch-implement",
            "timestamp": 20,
            "payload": {"run_id": "sb-2"},
            "id": "later",
        },
    ]


def test_history_store_is_selected_per_stream(serving):
    _, get = serving

    status, _, body = get("/history?stream=8201")

    assert status == 200
    assert [event["id"] for event in json.loads(body)] == ["other"]


@pytest.mark.parametrize("stream", ["9999", "8301"])
def test_unknown_or_missing_history_is_an_empty_success(serving, stream):
    _, get = serving

    status, _, body = get(f"/history?stream={stream}")

    assert status == 200
    assert json.loads(body) == []


def test_history_is_served_uncacheable(serving):
    _, get = serving
    _, headers, _ = get("/history?stream=8101")
    assert headers.get("Cache-Control") == "no-store"


def test_the_served_page_tracks_the_file_rather_than_a_snapshot(serving):
    """The defect in #61, as an assertion.

    A viewer that reads its bytes once serves a stale page indefinitely, and a
    stale page renders perfectly — so the operator's only symptom is a correct
    change that appears not to have happened.
    """
    page, get = serving

    status, _, first = get()
    assert status == 200
    assert b"first" in first

    page.write_text("<h1>second</h1>")

    status, _, second = get()
    assert status == 200
    assert b"second" in second, "the viewer is serving bytes it read at startup"


def test_the_page_is_served_uncacheable(serving):
    """The same defect one layer out.

    The install is editable so the running system tracks the working tree. A
    browser caching the page opts out of that, and the operator discovers it by
    hard-reloading — which means trusting the page requires distrusting it first.
    """
    _, get = serving
    _, headers, _ = get()
    assert headers.get("Cache-Control") == "no-store"


def test_an_unreadable_page_names_the_file(serving):
    """A blank 500 reads as a dead viewer, which is the wrong thing to debug."""
    page, get = serving
    page.unlink()

    status, _, body = get()
    assert status == 500
    assert page.name.encode() in body


def test_the_real_page_is_what_ships():
    """The default is the page in this checkout, not one installed elsewhere."""
    assert PAGE == ROOT / "src" / "signalbox" / "dashboard.html"
    assert PAGE.is_file()


def test_failed_invocation_diagnostics_survive_the_provenance_register():
    """The viewer must not discard the failure fields published by the runner."""
    page = PAGE.read_text()
    recorder = page[
        page.index("function recordProvenance") : page.index(
            "function renderInvocationFailures"
        )
    ]

    for field in ("ok", "stderr", "exit_code", "command"):
        assert f"{field}: p.{field}" in recorder


def test_failed_invocation_diagnostics_are_visible_on_the_run():
    """A stalled run's drawer names the command, exit status, and error text."""
    page = PAGE.read_text()
    renderer = page[
        page.index("function renderInvocationFailures") : page.index(
            "let unattributed"
        )
    ]
    run = page[page.index("function renderRun") : page.index("function renderBoard")]

    assert "invocation.run_id === run.key" in renderer
    assert "invocation.ok === false" in renderer
    assert "invocation.exit_code" in renderer
    assert "invocation.command" in renderer
    assert "invocation.stderr" in renderer
    assert "renderInvocationFailures(run)" in run


def test_a_relaunched_run_starts_its_card_over():
    """A run id is reused across launches, so the card cannot be.

    sb-113 relaunched on 2026-07-30 and drew `attempt 2`, `stage 1 of 3` and
    `1/2 shards` before its planner had said a word — every one of those left
    over from a run that had already been parked. Only `run.requested` may
    discard a card: it is the one event that means the run is starting, and
    every other event has to stay free to arrive out of order.
    """
    page = PAGE.read_text()
    fresh = page[page.index("function freshRun") : page.index("function runFor")]
    restart = page[page.index("function restartRun") : page.index("function shardState")]
    apply_fn = page[page.index("function apply(msg)") :][:400]

    assert 'run.requested" ? restartRun(' in apply_fn
    assert "freshRun(id)" in restart and "runs.set(id, run)" in restart

    # What "starts over" has to mean, or the reset is decorative.
    for cleared in ("attempt: 1", "rounds: 0", "merged: 0", "events: 0",
                    "shards: new Map()", "stages: new Map()", "stageCount: null",
                    "currentStage: null", 'state: "running"'):
        assert cleared in fresh, f"a restarted card keeps stale {cleared}"


def test_the_lifecycle_stops_the_viewer_it_starts():
    """`down` has to name the viewer or it survives every restart.

    The one that outlived the reinstall was still running the uv *tool* snapshot
    of the package rather than this working tree, so restarting the engine could
    not fix it and nothing said so.
    """
    harness = (ROOT / "bin" / "harness.sh").read_text()
    assert "dashboard_pid()" in harness, "the harness cannot find the viewer's process"
    # Anchored: "down() {" is also a suffix of "dashboard_down() {".
    body = harness.split("\ndown() {", 1)[1].split("\n}", 1)[0]
    assert "dashboard_down" in body, "`down` leaves the viewer running"


def test_the_viewer_is_not_found_by_matching_its_command_line():
    """`pgrep -f 'signalbox dashboard'` matches the shell about to run the kill.

    It killed its own caller the first time it ran. A pidfile names one process
    and cannot widen, which is the same reason the forwarder uses one.
    """
    lines = (ROOT / "bin" / "harness.sh").read_text().splitlines()
    # Comments are where this rule is explained, so assert about code only.
    code = "\n".join(line for line in lines if not line.lstrip().startswith("#"))
    assert "pgrep -f 'signalbox dashboard'" not in code
    assert "DASHBOARD_PIDFILE" in code


def test_preflight_requires_the_operator_vault():
    """#70: fail in the operator shell before starting an unusable engine."""
    harness = (ROOT / "bin" / "harness.sh").read_text()
    body = harness.split("\npreflight() {", 1)[1].split("\n}", 1)[0]
    assert '[[ -n "${SIGNALBOX_VAULT:-}" && -d "$SIGNALBOX_VAULT" ]]' in body
    assert 'missing+=("SIGNALBOX_VAULT ' in body
    assert "export SIGNALBOX_VAULT=" in body
    assert "before '$0 up'" in body


def test_status_names_the_shell_vault_and_engine_environment_split():
    """#70: status sees this shell; prepare-workspace checks the live engine."""
    harness = (ROOT / "bin" / "harness.sh").read_text()
    body = harness.split("\nstatus() {", 1)[1].split("\n}", 1)[0]
    assert 'say "vault:     ${SIGNALBOX_VAULT:-unset}"' in body
    assert "engine environment was captured at 'up' and may differ" in body
    assert "prepare-workspace verifies each run" in body


def test_forwarder_pidfile_names_a_supervisor_that_respawns_and_stops(tmp_path: Path):
    """#63: a dropped websocket child respawns, while teardown kills the loop."""
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    invocations = tmp_path / "invocations"
    gh = fake_bin / "gh"
    gh.write_text(
        "#!/usr/bin/env bash\n"
        "if [[ \"$1 $2\" == \"extension list\" ]]; then\n"
        "  echo 'cli/gh-webhook'; exit 0\n"
        "fi\n"
        f"echo started >> {invocations}\n"
        "trap 'exit 0' TERM INT\n"
        "while true; do sleep 1; done\n"
    )
    gh.chmod(0o755)
    log_dir = tmp_path / "logs"
    env = {
        **os.environ,
        "PATH": f"{fake_bin}:{os.environ['PATH']}",
        "SIGNALBOX_LOG_DIR": str(log_dir),
    }

    subprocess.run(
        [ROOT / "bin/harness.sh", "forward", "owner/repo"],
        env=env,
        check=True,
        capture_output=True,
        text=True,
    )
    supervisor = int((log_dir / "forward.pid").read_text())
    child = int((log_dir / "forward.child.pid").read_text())
    assert supervisor != child
    assert (log_dir / "forward.ready").exists()

    os.kill(child, 15)
    deadline = time.monotonic() + 6
    while time.monotonic() < deadline:
        if invocations.read_text().count("started") >= 2:
            break
        time.sleep(0.1)
    assert invocations.read_text().count("started") >= 2
    assert "restarting in" in (log_dir / "forward.log").read_text()

    subprocess.run(
        [ROOT / "bin/harness.sh", "unforward"],
        env=env,
        check=True,
        capture_output=True,
        text=True,
    )
    with pytest.raises(ProcessLookupError):
        os.kill(supervisor, 0)
    assert not (log_dir / "forward.child.pid").exists()


def test_forwarder_lifecycle_and_launch_guard_are_explicit():
    """#63: lifecycle ordering and recovery stay visible as shell invariants."""
    lines = (ROOT / "bin" / "harness.sh").read_text().splitlines()
    code = "\n".join(line for line in lines if not line.lstrip().startswith("#"))
    forward_up = code.split("\nforward_up() {", 1)[1].split("\n}", 1)[0]
    forward_down = code.split("\nforward_down() {", 1)[1].split("\n}", 1)[0]
    launch = code.split("\nlaunch() {", 1)[1].split("\n}", 1)[0]

    assert "_forward-supervise" in forward_up
    assert 'printf \'%s\' "$!" >"$FORWARD_PIDFILE"' in forward_up
    assert forward_down.index('kill -TERM "$pid"') < forward_down.index(
        'kill -TERM "$child"'
    )
    assert "forward_pid" in launch
    assert "promote_capable" in launch
    assert "$0 forward <owner/name>" in launch


def test_launch_checks_only_the_exact_target_repository():
    """#63: nested demo paths do not inherit an enclosing checkout's origin."""
    harness = (ROOT / "bin" / "harness.sh").read_text()
    launch = harness.split("\nlaunch() {", 1)[1].split("\n}", 1)[0]

    assert 'local repo_path="$PWD"' in launch
    assert "rev-parse --show-toplevel" in launch
    assert '"$repo_root" == "$exact_repo_path"' in launch
    assert 'git -C "$repo_root" remote get-url origin' in launch


def test_forwarder_reports_a_supervisor_without_a_connected_tunnel():
    """#63: a restart loop is not itself proof that ingress is available."""
    harness = (ROOT / "bin" / "harness.sh").read_text()
    status = harness.split("\nstatus() {", 1)[1].split("\n}", 1)[0]
    forward_up = harness.split("\nforward_up() {", 1)[1].split("\n}", 1)[0]

    assert "FORWARD_READYFILE" in status
    assert "supervisor up but tunnel is not connected" in status
    assert "the tunnel has not connected" in forward_up
    assert "retrying with capped backoff" in forward_up
