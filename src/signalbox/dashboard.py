"""Serve the dashboard page.

This is a viewer, not a sink. It has no subscription, receives no events, and is
not part of the topology — the page connects straight to sse-sink's stream in
the browser. Killing it affects nothing.

That distinction is the whole reason the previous implementation's 1686-line
event service is gone: fan-out belongs to the engine, and a dashboard only needs
somewhere to fetch one HTML file from.
"""

from __future__ import annotations

import http.server
import socketserver
from pathlib import Path

PAGE = Path(__file__).with_name("dashboard.html")


def handler_class(page: Path = PAGE) -> type[http.server.BaseHTTPRequestHandler]:
    """Serve `page`, read fresh on every request.

    Reading once at startup is what let this process serve a stale page for 76
    minutes after the fix for it landed. The install is editable precisely so the
    running system tracks the working tree, and a viewer that snapshots its bytes
    opts out of that guarantee for the one file an operator watches — silently,
    because a stale page renders perfectly.

    No-store is the other half. A file that changes under a running process by
    design cannot be cached anywhere, and a browser holding the old copy is the
    same defect one layer out: the operator hard-reloads to find out, which means
    trusting the page requires distrusting it first.
    """

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self) -> None:  # noqa: N802 - stdlib naming
            try:
                body = page.read_bytes()
            except OSError as exc:
                # Say which file and why. A blank 500 here reads as a dead
                # viewer, which is the wrong thing to go debug.
                self.send_error(500, f"cannot read {page}: {exc}")
                return
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_args) -> None:
            pass

    return Handler


def main(argv: list[str]) -> int:
    import argparse

    parser = argparse.ArgumentParser(prog="signalbox dashboard")
    parser.add_argument("--port", type=int, default=8103)
    args = parser.parse_args(argv)

    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.TCPServer(("127.0.0.1", args.port), handler_class()) as server:
        print(f"dashboard: http://localhost:{args.port}")
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass
    return 0
