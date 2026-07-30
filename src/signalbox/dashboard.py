"""Serve the dashboard page.

This is a viewer, not a sink. It has no subscription, receives no events, and is
not part of the topology — the page connects straight to sse-sink's stream in
the browser. It also reads event-store history on demand, without subscribing
or joining the topology. Killing it affects nothing.

That distinction is the whole reason the previous implementation's 1686-line
event service is gone: fan-out belongs to the engine, and a dashboard only needs
somewhere to fetch one HTML file from.
"""

from __future__ import annotations

import http.server
import json
import socketserver
import sqlite3
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

PAGE = Path(__file__).with_name("dashboard.html")
DEFAULT_STORE = Path.home() / ".local" / "share" / "emergent" / "signalbox" / "events.db"


def handler_class(
    page: Path = PAGE,
    stores: dict[int, Path] | None = None,
) -> type[http.server.BaseHTTPRequestHandler]:
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

    stream_stores = dict(stores or {})

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self) -> None:  # noqa: N802 - stdlib naming
            request = urlsplit(self.path)
            if request.path == "/history":
                self._history(parse_qs(request.query).get("stream", []))
                return

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

        def _history(self, streams: list[str]) -> None:
            try:
                port = int(streams[0]) if len(streams) == 1 else None
            except ValueError:
                port = None
            path = stream_stores.get(port) if port is not None else None
            events = _read_history(path) if path is not None else []
            body = json.dumps(events, separators=(",", ":")).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_args) -> None:
            pass

    return Handler


def _read_history(path: Path) -> list[dict]:
    """Read the current store contents; an unavailable store is no history."""
    try:
        uri = path.resolve().as_uri() + "?mode=ro"
        with sqlite3.connect(uri, uri=True) as connection:
            rows = connection.execute(
                "SELECT id, message_type, source, timestamp_ms, payload_json "
                "FROM events ORDER BY timestamp_ms ASC"
            )
            history = []
            for event_id, message_type, source, timestamp_ms, payload_json in rows:
                payload = json.loads(payload_json)
                if not isinstance(payload, dict):
                    raise ValueError("event payload is not an object")
                history.append({
                    "type": message_type,
                    "source": source,
                    "timestamp": timestamp_ms,
                    "payload": payload,
                    "id": event_id,
                })
            return history
    except (OSError, sqlite3.Error, ValueError, TypeError, json.JSONDecodeError):
        return []


def _store(value: str) -> tuple[int, Path]:
    port_text, separator, path_text = value.partition("=")
    if not separator or not path_text:
        raise ValueError("expected PORT=DB-PATH")
    return int(port_text), Path(path_text).expanduser()


def main(argv: list[str]) -> int:
    import argparse

    parser = argparse.ArgumentParser(prog="signalbox dashboard")
    parser.add_argument("--port", type=int, default=8103)
    parser.add_argument(
        "--store",
        action="append",
        default=[],
        metavar="PORT=DB-PATH",
        help="event store used by /history for a stream (repeatable)",
    )
    args = parser.parse_args(argv)
    stores = {8101: DEFAULT_STORE}
    try:
        stores.update(_store(value) for value in args.store)
    except ValueError as exc:
        parser.error(f"--store: {exc}")

    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.TCPServer(
        ("127.0.0.1", args.port), handler_class(stores=stores)
    ) as server:
        print(f"dashboard: http://localhost:{args.port}")
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass
    return 0
