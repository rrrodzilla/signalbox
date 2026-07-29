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
import threading
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
    server = HTTPServer(("127.0.0.1", 0), handler_class(page))
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
