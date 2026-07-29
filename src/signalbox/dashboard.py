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


def handler_class() -> type[http.server.BaseHTTPRequestHandler]:
    body = PAGE.read_bytes()

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self) -> None:  # noqa: N802 - stdlib naming
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
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
