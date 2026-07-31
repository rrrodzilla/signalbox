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


def test_preflight_refuses_a_topology_larger_than_the_connection_ceiling(
    tmp_path: Path,
):
    """#126: exercise the operator command, not a source-code promise."""
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    for name in ("emergent", "claude", "codex", "gh", "git", "jq", "uv"):
        executable = fake_bin / name
        executable.write_text(
            "#!/usr/bin/env bash\n"
            + ("echo 'emergent test'\n" if name == "emergent" else "exit 0\n")
        )
        executable.chmod(0o755)

    home = tmp_path / "home"
    primitives = home / ".local" / "share" / "emergent" / "primitives" / "bin"
    primitives.mkdir(parents=True)
    for name in (
        "exec-source",
        "exec-handler",
        "exec-sink",
        "http-source",
        "sse-sink",
        "topology-viewer",
    ):
        primitive = primitives / name
        primitive.write_text("#!/usr/bin/env bash\nexit 0\n")
        primitive.chmod(0o755)

    vault = tmp_path / "vault"
    vault.mkdir()
    config = tmp_path / "too-large.toml"
    config.write_text('[[sources]]\nname = "one"\n[[sinks]]\nname = "two"\n')
    ipc = home / ".config" / "acton" / "ipc.toml"
    ipc.parent.mkdir(parents=True)
    ipc.write_text(
        "[timeouts]\nread_timeout_ms = 0\n\n"
        "[limits]\nmax_connections = 1\nmax_message_size = 10485760\n"
    )
    linked_config = tmp_path / "linked-config"
    linked_config.symlink_to(home / ".config", target_is_directory=True)

    preflight_env = {
        **os.environ,
        "PATH": f"{fake_bin}:{os.environ['PATH']}",
        "HOME": str(home),
        "XDG_CONFIG_HOME": str(linked_config),
        "SIGNALBOX_CONFIG": str(config),
        "SIGNALBOX_VAULT": str(vault),
    }
    result = subprocess.run(
        [ROOT / "bin/harness.sh", "preflight"],
        env=preflight_env,
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode == 1
    assert result.stdout == ""
    assert (
        "harness: declared primitive connections (2) exceed the effective "
        "acton max_connections ceiling (1)"
    ) in result.stderr
    assert str(ipc.resolve()) in result.stderr
    assert str(linked_config) not in result.stderr
    assert "\n  repair with: mkdir -p " in result.stderr
    assert "max_connections = 1024" in result.stderr

    repair = result.stderr.split("\n  repair with: ", 1)[1].strip()
    repaired = subprocess.run(
        ["bash", "-c", repair], env={**os.environ, "HOME": str(home)}, check=False
    )
    assert repaired.returncode == 0
    assert ipc.read_text() == (
        "[timeouts]\nread_timeout_ms = 0\n\n"
        "[limits]\nmax_connections = 1024\nmax_message_size = 10485760\n"
    )

    ipc.unlink()
    ipc.parent.rmdir()
    repaired_absent = subprocess.run(
        ["bash", "-c", repair], env={**os.environ, "HOME": str(home)}, check=False
    )
    assert repaired_absent.returncode == 0
    assert ipc.read_text() == "[limits]\nmax_connections = 1024\n"

    ipc.write_text("[limits]\nmax_connections = 1\n")
    public_bypass = subprocess.run(
        [ROOT / "bin/harness.sh", "up", "--preflight-complete"],
        env=preflight_env,
        check=False,
        capture_output=True,
        text=True,
    )
    assert public_bypass.returncode == 1
    assert "declared primitive connections (2)" in public_bypass.stderr
    assert "starting the engine" not in public_bypass.stdout

    config.write_text("not valid toml = [")
    malformed = subprocess.run(
        [ROOT / "bin/harness.sh", "preflight"],
        env=preflight_env,
        check=False,
        capture_output=True,
        text=True,
    )
    assert malformed.returncode == 1
    assert "connection ceiling check failed:" in malformed.stderr
    assert "TOMLDecodeError" in malformed.stderr
    assert "repair with:" not in malformed.stderr


def test_status_reports_a_degraded_engine_when_children_are_missing(tmp_path: Path):
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    pgrep = fake_bin / "pgrep"
    pgrep.write_text(
        "#!/usr/bin/env bash\n"
        "if [[ \"$1\" == -x ]]; then echo \"$$\"; exit 0; fi\n"
        "if [[ \"$1\" == -P ]]; then exit 1; fi\n"
        "exit 1\n"
    )
    pgrep.chmod(0o755)
    config = tmp_path / "emergent.toml"
    config.write_text('[[handlers]]\nname = "expected"\n')

    result = subprocess.run(
        [ROOT / "bin/harness.sh", "status"],
        env={
            **os.environ,
            "PATH": f"{fake_bin}:{os.environ['PATH']}",
            "SIGNALBOX_CONFIG": str(config),
            "SIGNALBOX_LOG_DIR": str(tmp_path / "logs"),
        },
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0, result.stderr
    assert "engine:    DEGRADED" in result.stdout
    assert "primitives 0/1 live" in result.stdout


def test_status_reports_a_healthy_engine_when_all_declared_children_are_live(
    tmp_path: Path,
):
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    pgrep = fake_bin / "pgrep"
    pgrep.write_text(
        "#!/usr/bin/env bash\n"
        "if [[ \"$1\" == -x ]]; then echo \"$$\"; exit 0; fi\n"
        "if [[ \"$1\" == -P ]]; then printf '101\\n102\\n'; exit 0; fi\n"
        "exit 1\n"
    )
    pgrep.chmod(0o755)
    config = tmp_path / "emergent.toml"
    config.write_text(
        '[[sources]]\nname = "one"\n[[handlers]]\nname = "two"\n'
    )

    result = subprocess.run(
        [ROOT / "bin/harness.sh", "status"],
        env={
            **os.environ,
            "PATH": f"{fake_bin}:{os.environ['PATH']}",
            "SIGNALBOX_CONFIG": str(config),
            "SIGNALBOX_LOG_DIR": str(tmp_path / "logs"),
        },
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0, result.stderr
    assert "engine:    up" in result.stdout
    assert "primitives 2/2" in result.stdout
    assert "engine:    DEGRADED" not in result.stdout


def test_status_continues_when_the_topology_cannot_be_counted(tmp_path: Path):
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    pgrep = fake_bin / "pgrep"
    pgrep.write_text(
        "#!/usr/bin/env bash\n"
        "if [[ \"$1\" == -x ]]; then echo \"$$\"; exit 0; fi\n"
        "if [[ \"$1\" == -P ]]; then exit 1; fi\n"
        "exit 1\n"
    )
    pgrep.chmod(0o755)
    fuser = fake_bin / "fuser"
    fuser.write_text("#!/usr/bin/env bash\nexit 1\n")
    fuser.chmod(0o755)
    config = tmp_path / "malformed.toml"
    config.write_text("not valid toml = [")

    result = subprocess.run(
        [ROOT / "bin/harness.sh", "status"],
        env={
            **os.environ,
            "PATH": f"{fake_bin}:{os.environ['PATH']}",
            "SIGNALBOX_CONFIG": str(config),
            "SIGNALBOX_LOG_DIR": str(tmp_path / "logs"),
        },
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0, result.stderr
    assert "engine:    DEGRADED" in result.stdout
    assert "declared primitive count unavailable" in result.stdout
    assert "viewer:    down" in result.stdout
    assert "control    (not listening)" in result.stdout
    assert "Traceback" not in result.stderr


def test_dogfood_passes_the_matched_github_repo_only_on_the_origin_branch():
    harness = (ROOT / "bin" / "harness.sh").read_text()
    body = harness.split("\ndogfood() {", 1)[1].split("\n}", 1)[0]
    origin_branch, no_origin_branch = body.split("\n  else\n", 1)

    assert 'local repo="${BASH_REMATCH[1]}"' in origin_branch
    assert 'forward_up "$repo"' in origin_branch
    assert 'launch "$issue" --repo "$repo" --repo-path "$ROOT"' in origin_branch
    assert "--repo " not in no_origin_branch


def _status_with_engine_pid(
    tmp_path: Path, pid: int | None, invoking_vault: Path
) -> subprocess.CompletedProcess[str]:
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    pgrep = fake_bin / "pgrep"
    pgrep.write_text(
        "#!/usr/bin/env bash\n"
        + (f"printf '%s\\n' {pid}\n" if pid is not None else "exit 1\n")
    )
    pgrep.chmod(0o755)
    return subprocess.run(
        [ROOT / "bin/harness.sh", "status"],
        env={
            **os.environ,
            "PATH": f"{fake_bin}:{os.environ['PATH']}",
            "SIGNALBOX_LOG_DIR": str(tmp_path / "logs"),
            "SIGNALBOX_VAULT": str(invoking_vault),
        },
        check=False,
        capture_output=True,
        text=True,
    )


def test_status_reports_the_running_engines_valid_captured_vault(tmp_path: Path):
    """#100: status reports the environment that will actually receive notes."""
    engine_vault = tmp_path / "engine-vault"
    engine_vault.mkdir()
    child = subprocess.Popen(
        ["sleep", "30"], env={**os.environ, "SIGNALBOX_VAULT": str(engine_vault)}
    )
    try:
        result = _status_with_engine_pid(tmp_path, child.pid, engine_vault)
    finally:
        child.terminate()
        child.wait(timeout=5)

    assert result.returncode == 0, result.stderr
    assert str(engine_vault) in result.stdout
    assert "notes enabled" in result.stdout
    assert "unset" not in result.stdout


def test_status_says_no_captured_environment_when_engine_is_down(tmp_path: Path):
    result = _status_with_engine_pid(tmp_path, None, tmp_path / "shell-vault")

    assert result.returncode == 0, result.stderr
    assert "vault:     unavailable (engine down; no captured environment)" in result.stdout
    assert "engine:    down" in result.stdout


def test_status_surfaces_engine_and_invoking_shell_vault_divergence(tmp_path: Path):
    engine_vault = tmp_path / "engine-vault"
    shell_vault = tmp_path / "shell-vault"
    engine_vault.mkdir()
    shell_vault.mkdir()
    child = subprocess.Popen(
        ["sleep", "30"], env={**os.environ, "SIGNALBOX_VAULT": str(engine_vault)}
    )
    try:
        result = _status_with_engine_pid(tmp_path, child.pid, shell_vault)
    finally:
        child.terminate()
        child.wait(timeout=5)

    assert result.returncode == 0, result.stderr
    assert f"vault:     {engine_vault}" in result.stdout
    assert f"invoking shell differs: {shell_vault}" in result.stdout
    assert "may differ" not in result.stdout


def test_forwarder_pidfile_names_a_supervisor_that_respawns_and_stops(tmp_path: Path):
    """#63: a dropped websocket child respawns, while teardown kills the loop."""
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    invocations = tmp_path / "invocations"
    gh = fake_bin / "gh"
    gh.write_text(
        "#!/usr/bin/env bash\n"
        "case \"$1\" in\n"
        "  extension) echo 'cli/gh-webhook'; exit 0 ;;\n"
        "  api) exit 1 ;;\n"
        "esac\n"
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


def test_forwarder_teardown_reaps_processes_and_purges_its_github_hook(
    tmp_path: Path,
):
    """#107: stopping is clean and removes the temporary ingress it created."""
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    api_calls = tmp_path / "api-calls"
    gh = fake_bin / "gh"
    gh.write_text(
        "#!/usr/bin/env bash\n"
        "case \"$1\" in\n"
        "  extension) echo 'cli/gh-webhook'; exit 0 ;;\n"
        "  api)\n"
        f"    printf '%s\\n' \"$*\" >> {api_calls}\n"
        "    if [[ \"$*\" != *'--method DELETE'* ]]; then echo 42; fi\n"
        "    exit 0 ;;\n"
        "esac\n"
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
    log_dir.mkdir()
    (log_dir / "forward.repo").write_text("owner/repo")
    forward_log = log_dir / "forward.log"
    with forward_log.open("w") as output:
        supervisor_process = subprocess.Popen(
            [ROOT / "bin/harness.sh", "_forward-supervise", "owner/repo"],
            env=env,
            stdout=output,
            stderr=subprocess.STDOUT,
            text=True,
        )
        (log_dir / "forward.pid").write_text(str(supervisor_process.pid))
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and not (log_dir / "forward.ready").exists():
            time.sleep(0.1)
        assert (log_dir / "forward.ready").exists()
        child = int((log_dir / "forward.child.pid").read_text())

        stopped = subprocess.run(
            [ROOT / "bin/harness.sh", "unforward"],
            env=env,
            check=False,
            capture_output=True,
            text=True,
            timeout=15,
        )

        assert stopped.returncode == 0, stopped.stderr
        assert supervisor_process.wait(timeout=5) == 0

    with pytest.raises(ProcessLookupError):
        os.kill(child, 0)
    assert "unbound variable" not in forward_log.read_text()
    assert "repos/owner/repo/hooks" in api_calls.read_text()
    assert "--method DELETE repos/owner/repo/hooks/42" in api_calls.read_text()


def test_unforward_without_ownership_leaves_another_harness_hook(tmp_path: Path):
    """#125: one harness cannot purge another harness's live forwarder hook."""
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    api_calls = tmp_path / "api-calls"
    gh = fake_bin / "gh"
    gh.write_text(
        "#!/usr/bin/env bash\n"
        "case \"$1\" in\n"
        "  extension) echo 'cli/gh-webhook'; exit 0 ;;\n"
        "  api)\n"
        f"    printf '%s\\n' \"$*\" >> {api_calls}\n"
        "    if [[ \"$*\" != *'--method DELETE'* ]]; then echo 42; fi\n"
        "    exit 0 ;;\n"
        "esac\n"
        "trap 'exit 0' TERM INT\n"
        "while true; do sleep 1; done\n"
    )
    gh.chmod(0o755)
    shared_env = {**os.environ, "PATH": f"{fake_bin}:{os.environ['PATH']}"}
    log_a = tmp_path / "harness-a"
    log_b = tmp_path / "harness-b"
    env_a = {**shared_env, "SIGNALBOX_LOG_DIR": str(log_a)}
    env_b = {**shared_env, "SIGNALBOX_LOG_DIR": str(log_b)}

    subprocess.run(
        [ROOT / "bin/harness.sh", "forward", "owner/repo"],
        env=env_a,
        check=True,
        capture_output=True,
        text=True,
    )
    supervisor = int((log_a / "forward.pid").read_text())
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline and not (log_a / "forward.owner").exists():
        time.sleep(0.1)
    assert (log_a / "forward.owner").exists()

    log_b.mkdir()
    (log_b / "forward.repo").write_text("owner/repo")
    before = api_calls.read_text() if api_calls.exists() else ""
    stopped_b = subprocess.run(
        [ROOT / "bin/harness.sh", "unforward"],
        env=env_b,
        check=False,
        capture_output=True,
        text=True,
        timeout=15,
    )
    after_b = api_calls.read_text() if api_calls.exists() else ""

    assert stopped_b.returncode == 0, stopped_b.stderr
    assert stopped_b.stderr == ""
    assert "--method DELETE repos/owner/repo/hooks/" not in after_b[len(before) :]
    os.kill(supervisor, 0)
    assert "owner/repo" in stopped_b.stdout
    assert "forward owner/repo" in stopped_b.stdout

    stopped_a = subprocess.run(
        [ROOT / "bin/harness.sh", "unforward"],
        env=env_a,
        check=False,
        capture_output=True,
        text=True,
        timeout=15,
    )
    assert stopped_a.returncode == 0, stopped_a.stderr
    with pytest.raises(ProcessLookupError):
        os.kill(supervisor, 0)
    assert "--method DELETE repos/owner/repo/hooks/42" in api_calls.read_text()


def test_recycled_pid_cannot_satisfy_forward_hook_ownership(tmp_path: Path):
    """#125: matching live PIDs do not replace a process start-time identity."""
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    api_calls = tmp_path / "api-calls"
    gh = fake_bin / "gh"
    gh.write_text(
        "#!/usr/bin/env bash\n"
        "if [[ \"$1\" == api ]]; then\n"
        f"  printf '%s\\n' \"$*\" >> {api_calls}\n"
        "  if [[ \"$*\" != *'--method DELETE'* ]]; then echo 42; fi\n"
        "  exit 0\n"
        "fi\n"
        "trap 'exit 0' TERM INT\n"
        "while true; do sleep 1; done\n"
    )
    gh.chmod(0o755)
    log_dir = tmp_path / "logs"
    log_dir.mkdir()
    (log_dir / "forward.repo").write_text("owner/repo")
    env = {
        **os.environ,
        "PATH": f"{fake_bin}:{os.environ['PATH']}",
        "SIGNALBOX_LOG_DIR": str(log_dir),
    }
    forward_log = log_dir / "forward.log"
    with forward_log.open("w") as output:
        supervisor = subprocess.Popen(
            [ROOT / "bin/harness.sh", "_forward-supervise", "owner/repo"],
            env=env,
            stdout=output,
            stderr=subprocess.STDOUT,
            text=True,
        )
        (log_dir / "forward.pid").write_text(str(supervisor.pid))
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and not (log_dir / "forward.owner").exists():
            time.sleep(0.1)
        assert (log_dir / "forward.owner").exists(), forward_log.read_text()
        stale_start = (log_dir / "forward.owner").read_text().split(maxsplit=2)[1]
        supervisor.terminate()
        assert supervisor.wait(timeout=5) == 0

    stranger = subprocess.Popen(["sleep", "30"])
    try:
        (log_dir / "forward.pid").write_text(str(stranger.pid))
        (log_dir / "forward.owner").write_text(
            f"{stranger.pid} {stale_start} {log_dir.resolve()}\n"
        )
        stopped = subprocess.run(
            [ROOT / "bin/harness.sh", "unforward"],
            env=env,
            check=False,
            capture_output=True,
            text=True,
            timeout=15,
        )
        assert stopped.returncode == 0, stopped.stderr
        calls = api_calls.read_text() if api_calls.exists() else ""
        assert "--method DELETE repos/owner/repo/hooks/" not in calls
    finally:
        if stranger.poll() is None:
            stranger.terminate()
        stranger.wait(timeout=5)


def test_foreign_log_directory_cannot_satisfy_forward_hook_ownership(
    tmp_path: Path,
):
    """#125: a copied identity record cannot license a hook purge."""
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    api_calls = tmp_path / "api-calls"
    gh = fake_bin / "gh"
    gh.write_text(
        "#!/usr/bin/env bash\n"
        "if [[ \"$1\" == api ]]; then\n"
        f"  printf '%s\\n' \"$*\" >> {api_calls}\n"
        "  if [[ \"$*\" != *'--method DELETE'* ]]; then echo 42; fi\n"
        "  exit 0\n"
        "fi\n"
        "exit 0\n"
    )
    gh.chmod(0o755)
    log_dir = tmp_path / "logs"
    log_dir.mkdir()
    (log_dir / "forward.repo").write_text("owner/repo")
    env = {
        **os.environ,
        "PATH": f"{fake_bin}:{os.environ['PATH']}",
        "SIGNALBOX_LOG_DIR": str(log_dir),
    }

    live_process = subprocess.Popen(["sleep", "30"])
    try:
        raw_stat = Path(f"/proc/{live_process.pid}/stat").read_text()
        live_start = raw_stat.rsplit(") ", 1)[1].split()[19]
        (log_dir / "forward.pid").write_text(str(live_process.pid))
        (log_dir / "forward.owner").write_text(
            f"{live_process.pid} {live_start} {tmp_path / 'foreign-logs'}\n"
        )

        stopped = subprocess.run(
            [ROOT / "bin/harness.sh", "unforward"],
            env=env,
            check=False,
            capture_output=True,
            text=True,
            timeout=15,
        )

        assert stopped.returncode == 0, stopped.stderr
        assert stopped.stderr == ""
        calls = api_calls.read_text() if api_calls.exists() else ""
        assert "--method DELETE repos/owner/repo/hooks/" not in calls
    finally:
        if live_process.poll() is None:
            live_process.terminate()
        live_process.wait(timeout=5)


def test_forwarder_repairs_a_refused_stale_hook_then_connects(tmp_path: Path):
    """#107: the one repairable startup failure is purged and retried once."""
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    attempts = tmp_path / "attempts"
    deleted = tmp_path / "deleted"
    gh = fake_bin / "gh"
    gh.write_text(
        "#!/usr/bin/env bash\n"
        "if [[ \"$1\" == api ]]; then\n"
        f"  if [[ \"$*\" == *'--method DELETE'* ]]; then touch {deleted}; else echo 42; fi\n"
        "  exit 0\n"
        "fi\n"
        f"echo attempt >> {attempts}\n"
        f"if [[ ! -f {deleted} ]]; then\n"
        "  echo 'HTTP 422: Hook already exists on this repository' >&2\n"
        "  exit 1\n"
        "fi\n"
        "trap 'exit 0' TERM INT\n"
        "while true; do sleep 1; done\n"
    )
    gh.chmod(0o755)
    log_dir = tmp_path / "logs"
    log_dir.mkdir()
    (log_dir / "forward.repo").write_text("owner/repo")
    env = {
        **os.environ,
        "PATH": f"{fake_bin}:{os.environ['PATH']}",
        "SIGNALBOX_LOG_DIR": str(log_dir),
    }

    forward_log = log_dir / "forward.log"
    with forward_log.open("w") as output:
        supervisor = subprocess.Popen(
            [ROOT / "bin/harness.sh", "_forward-supervise", "owner/repo"],
            env=env,
            stdout=output,
            stderr=subprocess.STDOUT,
            text=True,
        )
        deadline = time.monotonic() + 6
        while time.monotonic() < deadline and not (log_dir / "forward.ready").exists():
            time.sleep(0.1)
        assert (log_dir / "forward.ready").exists(), forward_log.read_text()
        assert deleted.exists()
        assert attempts.read_text().count("attempt") == 2
        supervisor.terminate()
        assert supervisor.wait(timeout=5) == 0

    assert "purging it and retrying once" in forward_log.read_text()


def test_forwarder_terminates_when_stale_hook_repair_does_not_work(tmp_path: Path):
    """#107: a repeated permanent refusal does not enter capped backoff."""
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    attempts = tmp_path / "attempts"
    gh = fake_bin / "gh"
    gh.write_text(
        "#!/usr/bin/env bash\n"
        "if [[ \"$1\" == api ]]; then\n"
        "  if [[ \"$*\" != *'--method DELETE'* ]]; then echo 42; fi\n"
        "  exit 0\n"
        "fi\n"
        f"echo attempt >> {attempts}\n"
        "echo 'HTTP 422: Hook already exists on this repository' >&2\n"
        "exit 1\n"
    )
    gh.chmod(0o755)
    log_dir = tmp_path / "logs"
    log_dir.mkdir()
    (log_dir / "forward.repo").write_text("owner/repo")
    env = {
        **os.environ,
        "PATH": f"{fake_bin}:{os.environ['PATH']}",
        "SIGNALBOX_LOG_DIR": str(log_dir),
    }

    result = subprocess.run(
        [ROOT / "bin/harness.sh", "_forward-supervise", "owner/repo"],
        env=env,
        check=False,
        capture_output=True,
        text=True,
        timeout=6,
    )

    assert result.returncode != 0
    assert attempts.read_text().count("attempt") == 2
    assert "terminal webhook forwarder failure" in result.stdout
    assert "restarting in" not in result.stdout


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
    assert "forwarder decision: refuse" in launch
    assert "$0 forward <owner/name>" in launch


def test_launch_checks_only_the_exact_target_repository():
    """#63: nested demo paths do not inherit an enclosing checkout's origin."""
    harness = (ROOT / "bin" / "harness.sh").read_text()
    launch = harness.split("\nlaunch() {", 1)[1].split("\n}", 1)[0]

    assert 'local repo_path="$PWD"' in launch
    assert "rev-parse --show-toplevel" in launch
    assert '"$repo_root" == "$exact_repo_path"' in launch
    assert 'git -C "$repo_root" remote get-url origin' in launch
    assert 'find "$repo_root/.github/workflows"' in launch


def _launch_with_remote_workflow_count(
    tmp_path: Path, workflow_count: int, *extra_args: str
) -> tuple[subprocess.CompletedProcess[str], str]:
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    forwarded_args = tmp_path / "launch-args"
    scripts = {
        "pgrep": "#!/usr/bin/env bash\nprintf '1234\\n'\n",
        "fuser": "#!/usr/bin/env bash\nexit 0\n",
        "gh": (
            "#!/usr/bin/env bash\n"
            "if [[ \"$1\" == api && \"$2\" == "
            "'repos/owner/repo/actions/workflows' ]]; then\n"
            f"  printf '%s\\n' {workflow_count}\n"
            "  exit 0\n"
            "fi\n"
            "exit 1\n"
        ),
        "signalbox": (
            "#!/usr/bin/env bash\n"
            f"printf '%s\\n' \"$*\" > {forwarded_args}\n"
        ),
    }
    for name, script in scripts.items():
        executable = fake_bin / name
        executable.write_text(script)
        executable.chmod(0o755)
    result = subprocess.run(
        [
            ROOT / "bin/harness.sh",
            "launch",
            "105",
            "--repo",
            "owner/repo",
            *extra_args,
        ],
        env={
            **os.environ,
            "PATH": f"{fake_bin}:{os.environ['PATH']}",
            "SIGNALBOX_LOG_DIR": str(tmp_path / "logs"),
        },
        check=False,
        capture_output=True,
        text=True,
        timeout=5,
    )
    return result, forwarded_args.read_text() if forwarded_args.exists() else ""


def test_remote_without_workflow_launches_with_forwarder_warning(tmp_path: Path):
    """#105: a remote alone is not a resolvable promote path."""
    result, forwarded_args = _launch_with_remote_workflow_count(tmp_path, 0)

    assert result.returncode == 0, result.stderr
    assert "forwarder decision: warn" in result.stdout
    assert "  warning: webhook forwarder is down; continuing" in result.stdout
    assert forwarded_args == "launch 105 --repo owner/repo\n"


def test_remote_with_workflow_refuses_without_forwarder(tmp_path: Path):
    """#105: a detected workflow retains the named forwarder refusal."""
    result, forwarded_args = _launch_with_remote_workflow_count(tmp_path, 1)

    assert result.returncode == 1
    assert "forwarder decision: refuse (resolvable promote path; no forwarder)" in (
        result.stdout
    )
    assert "forward <owner/name>" in result.stderr
    assert forwarded_args == ""


def test_no_forwarder_downgrades_workflow_refusal(tmp_path: Path):
    """#105: the escape hatch warns and is stripped before CLI launch."""
    result, forwarded_args = _launch_with_remote_workflow_count(
        tmp_path, 1, "--no-forwarder"
    )

    assert result.returncode == 0, result.stderr
    assert "forwarder decision: warn" in result.stdout
    assert "  warning: webhook forwarder is down; continuing" in result.stdout
    assert "--no-forwarder" not in forwarded_args
    assert forwarded_args == "launch 105 --repo owner/repo\n"


def test_forwarder_reports_a_supervisor_without_a_connected_tunnel():
    """#63: a restart loop is not itself proof that ingress is available."""
    harness = (ROOT / "bin" / "harness.sh").read_text()
    status = harness.split("\nstatus() {", 1)[1].split("\n}", 1)[0]
    forward_up = harness.split("\nforward_up() {", 1)[1].split("\n}", 1)[0]

    assert "FORWARD_READYFILE" in status
    assert "supervisor up but tunnel is not connected" in status
    assert "the tunnel has not connected" in forward_up
    assert "retrying with capped backoff" in forward_up
