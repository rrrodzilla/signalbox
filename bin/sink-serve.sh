#!/usr/bin/env bash
# Shared machine-level Signalbox event sink and dashboard.
#
# Invocation:
#   bin/sink-serve.sh
#
# Routes:
#   POST /ingest       accept one pushed event envelope
#   GET  /events       merged SSE firehose (500-event replay plus live events)
#   GET  /status       registered instances and freshly stat'ed disk artifacts
#   GET  /              machine-wide dashboard (also /index.html)
#   GET  /healthz       service health probe
#
# Configuration:
#   SIGNALBOX_SINK_PORT   fixed loopback port (default: 8099)
#   SIGNALBOX_SINK_STATE  persisted registry path
#                         (default: $HOME/.local/share/signalbox/instances.json)
#   SIGNALBOX_SINK_IDLE   seconds before an unidentified quiet instance is stale
#                         (default: 900)
#
# Exits 0 after a clean shutdown, 1 when configuration or the fixed-port bind
# fails. There are no positional arguments; supplying one exits 64.
set -euo pipefail

if [ "$#" -ne 0 ]; then
    echo "usage: sink-serve.sh" >&2
    exit 64
fi

# 8099 is below install.sh's per-repo reservations (8100+) and bin/ports.sh's
# lease scan range (8200-8990), so it can never be leased out from under this
# one machine-level service.
PORT="${SIGNALBOX_SINK_PORT:-8099}"
STATE="${SIGNALBOX_SINK_STATE:-$HOME/.local/share/signalbox/instances.json}"
IDLE="${SIGNALBOX_SINK_IDLE:-900}"

exec python3 - "$PORT" "$STATE" "$IDLE" <<'PYEOF'
import errno
import json
import math
import os
import queue
import sys
import tempfile
import threading
import time
import unicodedata
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MAX_BODY = 1024 * 1024
MAX_ARTIFACT_JSON = 262144
RING_SIZE = 500
CLIENT_QUEUE_SIZE = 128
HEARTBEAT_SECONDS = 15

try:
    PORT = int(sys.argv[1])
    if not 1 <= PORT <= 65535:
        raise ValueError
except ValueError:
    print("error: SIGNALBOX_SINK_PORT must be an integer from 1 to 65535",
          file=sys.stderr)
    sys.exit(1)

STATE = sys.argv[2]
if not STATE:
    print("error: SIGNALBOX_SINK_STATE must not be empty", file=sys.stderr)
    sys.exit(1)

try:
    IDLE = float(sys.argv[3])
    if not math.isfinite(IDLE) or IDLE < 0:
        raise ValueError
except ValueError:
    print("error: SIGNALBOX_SINK_IDLE must be a non-negative number",
          file=sys.stderr)
    sys.exit(1)

# The URL line must reach a redirected stdout immediately (the same
# buffered-narration lesson as signalbox issue #1).
sys.stdout.reconfigure(line_buffering=True)

ARTIFACTS = [
    "plan.json",
    "state/run.json",
    "state/gate.json",
    "state/escalated.json",
    "state/pending.json",
    "state/docs-sync.json",
    "results/CR.md",
    "state/pipeline-plan.stamp",
    "state/pipeline-implement.stamp",
    "state/pipeline-review.stamp",
]

IDENTITY_FIELDS = (
    "repo",
    "repo_root",
    "harness",
    "run_dir",
    "slug",
    "issue",
    "feature",
    "pid",
    "start_id",
)
TEXT_FIELDS = {"repo", "repo_root", "harness", "run_dir", "slug",
               "feature", "start_id"}
REGISTRY = {}
EVENT_RING = deque(maxlen=RING_SIZE)
CLIENTS = set()
LOCK = threading.RLock()


class BadEnvelope(ValueError):
    pass


def artifact_info(run_dir, rel):
    info = {"file": rel, "exists": False}
    if not isinstance(run_dir, str) or not run_dir or "\x00" in run_dir:
        return info
    p = os.path.join(run_dir, rel)
    info["exists"] = os.path.isfile(p)
    if info["exists"]:
        try:
            st = os.stat(p)
        except OSError:
            info["exists"] = False
            return info
        info["mtime"] = st.st_mtime
        info["size"] = st.st_size
        if rel.endswith(".json") and st.st_size < MAX_ARTIFACT_JSON:
            try:
                with open(p) as fh:
                    info["json"] = json.load(
                        fh, parse_constant=reject_constant,
                        parse_float=finite_float
                    )
            except (OSError, ValueError, RecursionError):
                info["json"] = None
    return info


def log_info(run_dir):
    logs = []
    if not isinstance(run_dir, str) or not run_dir or "\x00" in run_dir:
        return logs
    logdir = os.path.join(run_dir, "logs")
    if os.path.isdir(logdir):
        try:
            names = sorted(os.listdir(logdir))
        except OSError:
            names = []
        for n in names:
            p = os.path.join(logdir, n)
            if os.path.isfile(p):
                try:
                    st = os.stat(p)
                except OSError:
                    continue
                logs.append({"file": n, "mtime": st.st_mtime, "size": st.st_size})
    return logs


def load_provenance(run_dir):
    """Load and sanitize one run's optional artifact provenance map."""
    if not isinstance(run_dir, str) or not run_dir or "\x00" in run_dir:
        return {}
    path = os.path.join(run_dir, "state", "provenance.json")
    try:
        with open(path, "rb") as fh:
            raw = fh.read(MAX_ARTIFACT_JSON)
            if len(raw) >= MAX_ARTIFACT_JSON or fh.read(1):
                return {}
        document = json.loads(
            raw.decode("utf-8"),
            parse_constant=reject_constant,
            parse_float=finite_float,
        )
        if not isinstance(document, dict):
            return {}
        sanitized = {}
        for rel, entry in document.items():
            if not isinstance(entry, dict):
                continue
            agent = entry.get("agent")
            model = entry.get("model")
            if (not valid_provenance_text(agent, 32)
                    or not valid_provenance_text(model, 128)):
                continue
            clean = {"agent": agent, "model": model}
            effort = entry.get("effort")
            if (isinstance(effort, str)
                    and effort in {"low", "medium", "high", "xhigh", "max"}):
                clean["effort"] = effort
            sanitized[rel] = clean
        return sanitized
    except Exception:
        # Provenance is diagnostic metadata. A missing, torn, or hostile map
        # must not affect this run's other status or any other registered run.
        return {}


def valid_provenance_text(value, limit):
    return (isinstance(value, str)
            and 0 < len(value) <= limit
            and not any(unicodedata.category(char) == "Cc" for char in value))


def proc_start_id(pid):
    """Exact process start identity: "<boot epoch>:<start time in ticks>",
    the same string bin/run.sh reads from /proc and records in launch.json as
    start_id. Both halves are integers straight out of the kernel, so equality
    is exact — there is no clock to be tolerant of. Returns None when /proc
    cannot answer (non-Linux, torn read). A missing /proc/<pid> is not
    "indeterminate" — the caller's kill(0) already separates gone from alive,
    so None here strictly means the identity question could not be asked."""
    try:
        with open("/proc/%d/stat" % pid, "rb") as fh:
            # comm (field 2) may contain spaces and parens; fields 3+ start
            # after the LAST ')'. starttime is field 22 -> index 19 past comm.
            ticks = int(fh.read().rsplit(b")", 1)[1].split()[19])
        with open("/proc/stat", "rb") as fh:
            for line in fh:
                if line.startswith(b"btime "):
                    return "%d:%d" % (int(line.split()[1]), ticks)
    except (OSError, ValueError, IndexError):
        pass
    return None


def valid_pid(value):
    return isinstance(value, int) and not isinstance(value, bool) and value > 0


def valid_timestamp(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return False
    try:
        return math.isfinite(value)
    except OverflowError:
        return False


def instance_state(instance, now):
    """Compute liveness without relying on best-effort system.* delivery."""
    pid = instance.get("pid")
    start_id = instance.get("start_id")
    if valid_pid(pid) and isinstance(start_id, str) and start_id:
        proc_dir = "/proc/%d" % pid
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return "stopped"
        except OSError:
            pass
        if not os.path.exists(proc_dir):
            return "stopped"
        current = proc_start_id(pid)
        if current is not None:
            return "running" if current == start_id else "stopped"
        if not os.path.exists(proc_dir):
            return "stopped"

    # Only the authoritative identity above may report "stopped". A
    # system.stopped.<name> event describes one primitive shutting down, not the
    # end of the run, so it can never retire an instance whose engine is still
    # up — and wildcard exec-sink delivery is unverified besides. An instance
    # without launch identity (a direct or init run) therefore stays "unknown"
    # until it goes quiet for IDLE seconds, and then "stale".
    last_event = instance.get("last_event")
    if isinstance(last_event, (int, float)) and now - last_event > IDLE:
        return "stale"
    return "unknown"


def clean_identity_value(field, value):
    if field in TEXT_FIELDS:
        if isinstance(value, str) and "\x00" not in value and len(value) <= 262144:
            return value
        return None
    if field == "issue":
        return value if isinstance(value, int) and not isinstance(value, bool) else None
    if field == "pid":
        return value if valid_pid(value) else None
    return None


def persisted_instance(instance):
    saved = {"key": instance["key"]}
    for field in IDENTITY_FIELDS:
        value = instance.get(field)
        if value is not None:
            saved[field] = value
    saved["engines"] = dict(instance.get("engines", {}))
    saved["first_seen"] = instance["first_seen"]
    saved["last_event"] = instance["last_event"]
    return saved


def persist_registry():
    """Atomically persist identity and timestamps; the event ring is volatile."""
    parent = os.path.dirname(os.path.abspath(STATE))
    data = {
        "instances": [
            persisted_instance(REGISTRY[key]) for key in sorted(REGISTRY)
        ]
    }
    temp_path = None
    try:
        fd, temp_path = tempfile.mkstemp(
            prefix=os.path.basename(STATE) + ".tmp.", dir=parent
        )
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(data, fh, ensure_ascii=True, separators=(",", ":"))
            fh.write("\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(temp_path, STATE)
        temp_path = None
    except OSError as exc:
        print(f"warning: could not persist sink registry at {STATE}: {exc}",
              file=sys.stderr)
    finally:
        if temp_path is not None:
            try:
                os.unlink(temp_path)
            except OSError:
                pass


def load_registry():
    try:
        with open(STATE, encoding="utf-8") as fh:
            saved = json.load(
                fh, parse_constant=reject_constant, parse_float=finite_float
            )
    except FileNotFoundError:
        return
    except (OSError, ValueError, TypeError, RecursionError) as exc:
        print(f"warning: ignoring unreadable sink registry at {STATE}: {exc}",
              file=sys.stderr)
        return
    rows = saved.get("instances") if isinstance(saved, dict) else None
    if not isinstance(rows, list):
        print(f"warning: ignoring malformed sink registry at {STATE}",
              file=sys.stderr)
        return
    for row in rows:
        if not isinstance(row, dict):
            continue
        key = row.get("key")
        first_seen = row.get("first_seen")
        last_event = row.get("last_event")
        if (not isinstance(key, str) or not key
                or not valid_timestamp(first_seen)
                or not valid_timestamp(last_event)):
            continue
        instance = {
            "key": key,
            "engines": {},
            "first_seen": float(first_seen),
            "last_event": float(last_event),
        }
        for field in IDENTITY_FIELDS:
            value = clean_identity_value(field, row.get(field))
            if value is not None:
                instance[field] = value
        engines = row.get("engines")
        if isinstance(engines, dict):
            instance["engines"] = {
                label: engine
                for label, engine in engines.items()
                if isinstance(label, str) and isinstance(engine, str)
            }
        REGISTRY[key] = instance


def required_text(value, name):
    if not isinstance(value, str) or not value:
        raise BadEnvelope(f"{name} must be a non-empty string")
    if len(value) > 4096 or "\r" in value or "\n" in value:
        raise BadEnvelope(f"{name} is invalid")
    try:
        value.encode("utf-8")
    except UnicodeEncodeError as exc:
        raise BadEnvelope(f"{name} is invalid") from exc
    return value


def validate_envelope(envelope):
    if not isinstance(envelope, dict):
        raise BadEnvelope("body must be a JSON object")
    event_type = required_text(envelope.get("type"), "type")
    engine_label = required_text(envelope.get("engine_label"), "engine_label")
    source = envelope.get("instance")
    if not isinstance(source, dict):
        raise BadEnvelope("instance must be a JSON object")
    key = required_text(source.get("key"), "instance.key")
    return event_type, engine_label, key, source


def ingest(envelope):
    event_type, engine_label, key, source = validate_envelope(envelope)
    try:
        compact = json.dumps(
            envelope, ensure_ascii=True, separators=(",", ":"), allow_nan=False
        )
    except (TypeError, ValueError) as exc:
        raise BadEnvelope("body is not valid JSON data") from exc

    now = time.time()
    with LOCK:
        instance = REGISTRY.get(key)
        if instance is None:
            instance = {
                "key": key,
                "engines": {},
                "first_seen": now,
                "last_event": now,
            }
            REGISTRY[key] = instance
        for field in IDENTITY_FIELDS:
            if field not in source or source[field] is None:
                continue
            value = clean_identity_value(field, source[field])
            if value is not None:
                instance[field] = value
        engine = source.get("engine")
        if isinstance(engine, str) and "\x00" not in engine:
            instance["engines"][engine_label] = engine
        instance["last_event"] = now
        EVENT_RING.append((event_type, compact))
        for client in tuple(CLIENTS):
            try:
                client.put_nowait((event_type, compact))
            except queue.Full:
                pass
        persist_registry()


def status():
    now = time.time()
    with LOCK:
        instances = []
        for key in sorted(REGISTRY):
            original = REGISTRY[key]
            copied = {
                field: original.get(field)
                for field in ("key",) + IDENTITY_FIELDS
            }
            copied["engines"] = dict(original.get("engines", {}))
            copied["first_seen"] = original["first_seen"]
            copied["last_event"] = original["last_event"]
            instances.append(copied)

    for instance in instances:
        instance["state"] = instance_state(instance, now)
        run_dir = instance.get("run_dir")
        if not isinstance(run_dir, str):
            run_dir = ""
        provenance = load_provenance(run_dir)
        artifacts = {
            artifact: artifact_info(run_dir, artifact)
            for artifact in ARTIFACTS
        }
        for artifact, info in artifacts.items():
            entry = provenance.get(artifact)
            if entry is not None:
                info["provenance"] = entry
        logs = log_info(run_dir)
        for info in logs:
            entry = provenance.get("logs/" + info["file"])
            if entry is not None:
                info["provenance"] = entry
        instance["artifacts"] = artifacts
        instance["logs"] = logs
    return {"now": now, "instances": instances}


def reject_constant(value):
    raise ValueError(f"invalid JSON constant {value}")


def finite_float(value):
    parsed = float(value)
    if not math.isfinite(parsed):
        raise ValueError(f"non-finite JSON number {value}")
    return parsed


def sse_frame(event):
    event_type, compact = event
    return f"event: {event_type}\ndata: {compact}\n\n".encode("utf-8")


class SinkServer(ThreadingHTTPServer):
    daemon_threads = True


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def _body(self, code, ctype, body):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except OSError:
            pass

    def _plain_error(self, reason):
        self._body(400, "text/plain; charset=utf-8",
                   (reason + "\n").encode("utf-8"))

    def do_POST(self):
        if self.path != "/ingest":
            self._body(404, "text/plain; charset=utf-8", b"not found\n")
            return
        length_text = self.headers.get("Content-Length")
        try:
            length = int(length_text) if length_text is not None else -1
        except ValueError:
            length = -1
        if length < 0:
            self.close_connection = True
            self._plain_error("valid Content-Length required")
            return
        if length > MAX_BODY:
            self.close_connection = True
            self._plain_error("body exceeds 1 MiB")
            return
        try:
            raw = self.rfile.read(length)
            if len(raw) != length:
                raise BadEnvelope("incomplete request body")
            envelope = json.loads(
                raw.decode("utf-8"), parse_constant=reject_constant
            )
            ingest(envelope)
        except (BadEnvelope, UnicodeDecodeError, ValueError, RecursionError) as exc:
            self._plain_error(str(exc) or "invalid JSON body")
            return
        except Exception as exc:
            # A hostile or torn request must take down at most its handler
            # thread, never the shared service used by every running instance.
            print(f"warning: rejected ingest after internal error: {exc}",
                  file=sys.stderr)
            self._plain_error("invalid ingest envelope")
            return
        self._body(204, "text/plain", b"")

    def do_GET(self):
        if self.path in ("/", "/index.html"):
            self._body(200, "text/html; charset=utf-8", PAGE.encode("utf-8"))
        elif self.path == "/status":
            body = json.dumps(
                status(), ensure_ascii=True, separators=(",", ":"),
                allow_nan=False
            ).encode("utf-8")
            self._body(200, "application/json", body)
        elif self.path == "/events":
            self.events()
        elif self.path == "/healthz":
            self._body(200, "application/json", b'{"ok":true}\n')
        else:
            self._body(404, "text/plain; charset=utf-8", b"not found\n")

    def events(self):
        client = queue.Queue(maxsize=CLIENT_QUEUE_SIZE)
        with LOCK:
            replay = list(EVENT_RING)
            CLIENTS.add(client)
        try:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Connection", "keep-alive")
            self.end_headers()
            for event in replay:
                self.wfile.write(sse_frame(event))
            self.wfile.flush()
            while True:
                try:
                    event = client.get(timeout=HEARTBEAT_SECONDS)
                    self.wfile.write(sse_frame(event))
                except queue.Empty:
                    self.wfile.write(b": ping\n\n")
                self.wfile.flush()
        except OSError:
            pass
        finally:
            with LOCK:
                CLIENTS.discard(client)


PAGE = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>signalbox sink</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
:root { --bg:#0d1117; --panel:#161b22; --line:#30363d; --fg:#e6edf3; --dim:#8b949e;
        --green:#3fb950; --red:#f85149; --amber:#d29922; --blue:#58a6ff; --purple:#bc8cff; }
* { box-sizing:border-box; margin:0; }
body { background:var(--bg); color:var(--fg); font:14px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace; padding:16px; }
h1 { font-size:16px; letter-spacing:.06em; }
.meta { color:var(--dim); font-size:12px; margin-top:2px; }
.run { margin-top:16px; border:1px solid var(--line); border-radius:8px; background:var(--panel); padding:12px; }
.run-head { color:var(--blue); font-size:14px; font-weight:600; }
.run-meta { color:var(--dim); font-size:11px; margin-top:2px; word-break:break-word; }
.rail { display:flex; gap:8px; margin:16px 0; flex-wrap:wrap; }
.phase { flex:1; min-width:130px; border:1px solid var(--line); border-radius:8px; padding:10px 12px; background:var(--panel); }
.phase .name { text-transform:uppercase; font-size:11px; letter-spacing:.1em; color:var(--dim); }
.phase .st { font-size:13px; margin-top:4px; font-weight:600; }
.phase.pending .st { color:var(--dim); }
.phase.active .st { color:var(--amber); }
.phase.active { border-color:var(--amber); }
.phase.done .st { color:var(--green); }
.phase.failed .st, .phase.escalated .st { color:var(--red); }
.phase.failed, .phase.escalated { border-color:var(--red); }
.phase.parked .st { color:var(--purple); }
.cols { display:grid; grid-template-columns: 340px 1fr; gap:16px; align-items:start; }
@media (max-width:900px){ .cols { grid-template-columns:1fr; } }
.panel { border:1px solid var(--line); border-radius:8px; background:var(--panel); padding:12px; }
.panel h2 { font-size:11px; text-transform:uppercase; letter-spacing:.1em; color:var(--dim); margin-bottom:8px; }
table { width:100%; border-collapse:collapse; font-size:12px; }
td { padding:3px 6px 3px 0; vertical-align:top; }
td.age, td.size { color:var(--dim); white-space:nowrap; text-align:right; }
.miss { color:#484f58; }
.ok { color:var(--green); } .bad { color:var(--red); }
.badges { display:flex; gap:6px; flex-wrap:wrap; margin-bottom:10px; }
.badge { appearance:none; background:transparent; font:inherit; font-size:11px; padding:2px 8px; border-radius:10px; border:1px solid var(--line); color:var(--dim); cursor:pointer; }
.badge.running { color:var(--green); border-color:var(--green); }
.badge.stopped { color:var(--red); border-color:var(--red); }
.badge.stale { color:var(--amber); border-color:var(--amber); }
.badge.unknown { color:var(--purple); border-color:var(--purple); }
.badge.selected { background:var(--line); box-shadow:0 0 0 1px currentColor; }
.pill { display:inline-block; margin-left:4px; padding:0 6px; border:1px solid var(--line); border-radius:10px; color:var(--dim); font-size:10px; font-weight:400; line-height:16px; vertical-align:baseline; }
.pill.agent-claude { color:var(--purple); border-color:var(--purple); }
.pill.agent-codex { color:var(--blue); border-color:var(--blue); }
.pill.agent-other { color:var(--dim); border-color:var(--dim); }
.pill.model { color:var(--fg); border-color:var(--line); }
.pill.effort-low { color:var(--dim); border-color:var(--dim); opacity:.7; }
.pill.effort-medium { color:var(--green); border-color:var(--green); opacity:.8; }
.pill.effort-high { color:var(--blue); border-color:var(--blue); opacity:.9; }
.pill.effort-xhigh { color:var(--amber); border-color:var(--amber); }
.pill.effort-max { color:var(--red); border-color:var(--red); font-weight:600; }
#feed { max-height:70vh; overflow-y:auto; display:flex; flex-direction:column; gap:6px; }
.ev { border-left:3px solid var(--line); padding:2px 8px; font-size:12px; }
.ev .hd { color:var(--dim); }
.ev .topic { font-weight:600; }
.ev pre { white-space:pre-wrap; word-break:break-word; color:var(--fg); margin-top:2px; }
.ev details pre { max-height:240px; overflow-y:auto; }
.ev.c0 { border-color:var(--blue); } .ev.c0 .topic { color:var(--blue); }
.ev.c1 { border-color:var(--purple); } .ev.c1 .topic { color:var(--purple); }
.ev.c2 { border-color:var(--amber); } .ev.c2 .topic { color:var(--amber); }
.ev.c3 { border-color:var(--green); } .ev.c3 .topic { color:var(--green); }
.ev.c4 { border-color:var(--dim); }
.ev.err { border-color:var(--red); } .ev.err .topic { color:var(--red); }
</style>
</head>
<body>
<h1>signalbox sink</h1>
<div class="meta" id="meta">connecting…</div>
<div class="panel" style="margin-top:16px">
  <h2>Merged live events</h2>
  <div class="badges" id="badges"></div>
  <div id="feed"></div>
</div>
<div id="runs"></div>
<script>
const PHASES = ["plan","implement","review","promote"];
const promoteStates = Object.create(null);
const instanceColours = Object.create(null);
let selectedKey = "all";
const $ = id => document.getElementById(id);

function age(now, m) {
  const s = Math.max(0, Math.round(now - m));
  if (s < 60) return s + "s";
  if (s < 3600) return Math.round(s/60) + "m";
  return (s/3600).toFixed(1) + "h";
}
function esc(value) {
  return String(value).replace(/[&<>"']/g, c => ({
    "&":"&amp;", "<":"&lt;", ">":"&gt;", '"':"&quot;", "'":"&#39;"
  })[c]);
}
function provenanceParts(value) {
  const usable = (text, limit) => typeof text === "string" && text.length > 0 &&
    text.length <= limit && !/[\u0000-\u001f\u007f-\u009f]/.test(text);
  if (!value || typeof value !== "object" ||
      !usable(value.agent, 32) || !usable(value.model, 128)) return null;
  const agentClass = value.agent === "claude" ? "agent-claude" :
    value.agent === "codex" ? "agent-codex" : "agent-other";
  const effortClasses = {
    low:"effort-low", medium:"effort-medium", high:"effort-high",
    xhigh:"effort-xhigh", max:"effort-max"
  };
  const effort = typeof value.effort === "string" &&
    Object.prototype.hasOwnProperty.call(effortClasses, value.effort)
    ? value.effort : null;
  return {
    agent:value.agent,
    agentClass,
    model:value.model,
    effort,
    effortClass:effort ? effortClasses[effort] : ""
  };
}
function provenancePills(value) {
  const p = provenanceParts(value);
  if (!p) return "";
  let pills = '<span class="pill ' + p.agentClass + '">' + esc(p.agent) + "</span>" +
    '<span class="pill model">' + esc(p.model) + "</span>";
  if (p.effort) {
    pills += '<span class="pill ' + p.effortClass + '">' + esc(p.effort) + "</span>";
  }
  return pills;
}
function appendProvenancePills(parent, value) {
  const p = provenanceParts(value);
  if (!p) return;
  for (const [text, className] of [
    [p.agent, p.agentClass], [p.model, "model"],
    ...(p.effort ? [[p.effort, p.effortClass]] : [])
  ]) {
    const pill = document.createElement("span");
    pill.className = "pill " + className;
    pill.textContent = text;
    parent.appendChild(pill);
  }
}

function derive(run) {
  const a = run.artifacts;
  const stamp = p => a["state/pipeline-" + p + ".stamp"];
  const out = {};
  const ps = stamp("plan"), pj = a["plan.json"];
  out.plan = !ps.exists ? "pending" : (pj.exists && pj.mtime >= ps.mtime ? "done" : "active");
  const is = stamp("implement"), gj = a["state/gate.json"];
  if (!is.exists) out.implement = "pending";
  else if (gj.exists && gj.mtime >= is.mtime)
    out.implement = (gj.json && gj.json.verdict === "GREEN") ? "done" : "failed";
  else out.implement = "active";
  const rs = stamp("review"), cr = a["results/CR.md"], pend = a["state/pending.json"];
  if (!rs.exists) out.review = "pending";
  else if (cr.exists && cr.mtime >= rs.mtime) out.review = "done";
  else if (pend.exists && pend.mtime >= rs.mtime) out.review = "parked";
  else out.review = "active";
  out.promote = promoteStates[run.key] || "pending";
  const esc = a["state/escalated.json"];
  const stamps = PHASES.map(p => stamp(p)).filter(x => x && x.exists).map(x => x.mtime);
  if (esc.exists && esc.json && stamps.length && esc.mtime >= Math.max(...stamps)) {
    const p = esc.json.escalated_phase === "shard" ? "implement" : esc.json.escalated_phase;
    if (out[p]) out[p] = "escalated";
  }
  return out;
}

function artifactRows(run, now) {
  return Object.values(run.artifacts).map(x => {
    let extra = "";
    if (x.exists && x.json && x.json.verdict) {
      const verdictClass = x.json.verdict === "GREEN" ? "ok" : "bad";
      extra = ' <span class="' + verdictClass + '">' + esc(x.json.verdict) + "</span>";
    }
    extra += provenancePills(x.provenance);
    return "<tr><td class='" + (x.exists ? "" : "miss") + "'>" + esc(x.file) + extra + "</td>" +
      "<td class='age'>" + (x.exists ? age(now, x.mtime) : "—") + "</td>" +
      "<td class='size'>" + (x.exists ? x.size + "b" : "") + "</td></tr>";
  }).join("");
}

function logRows(run, now) {
  return run.logs.map(l =>
    "<tr><td>" + esc(l.file) + provenancePills(l.provenance) +
    "</td><td class='age'>" + age(now, l.mtime) +
    "</td><td class='size'>" + l.size + "b</td></tr>").join("");
}

function instanceLabel(run) {
  const repo = run.repo || "repo unknown";
  const suffix = run.issue === null || run.issue === undefined
    ? (run.slug || "instance unknown") : "#" + run.issue;
  return repo + " · " + suffix;
}

function colourFor(key) {
  if (!(key in instanceColours)) {
    instanceColours[key] = "c" + (Object.keys(instanceColours).length % 5);
  }
  return instanceColours[key];
}

function renderRun(run, now) {
  const states = derive(run);
  const feature = run.feature || "feature unknown";
  const issue = run.issue === null || run.issue === undefined ? "issue unknown" : "issue #" + run.issue;
  const pid = run.pid === null || run.pid === undefined ? "pid unknown" : "pid " + run.pid;
  const engines = Object.entries(run.engines || {}).map(([label, engine]) =>
    esc(label) + "=" + esc(engine)).join(" · ") || "no engines registered";
  const rail = PHASES.map(p =>
    '<div class="phase ' + states[p] + '"><div class="name">' + p +
    '</div><div class="st">' + states[p] + "</div></div>").join("");
  return '<section class="run">' +
    '<div class="run-head">' + esc(feature) + " · " + esc(issue) + " · " +
      esc(run.key) + " · " + esc(pid) + " " + esc(run.state) + "</div>" +
    '<div class="run-meta">' + engines + " · " + esc(run.run_dir || "run directory unknown") + "</div>" +
    '<div class="rail">' + rail + "</div>" +
    '<div class="cols"><div class="panel"><h2>Disk artifacts (the terminals that count)</h2>' +
      '<table>' + artifactRows(run, now) + "</table></div>" +
    '<div class="panel"><h2>Engine logs (buffered — sizes grow on flush)</h2>' +
      '<table>' + logRows(run, now) + "</table></div></div></section>";
}

function select(key) {
  selectedKey = key;
  for (const row of $("feed").children) {
    row.hidden = key !== "all" && row.dataset.key !== key;
  }
  for (const chip of $("badges").children) {
    chip.classList.toggle("selected", chip.dataset.key === key);
  }
}

function renderChips(instances) {
  const badges = $("badges");
  badges.replaceChildren();
  const all = document.createElement("button");
  all.type = "button";
  all.className = "badge" + (selectedKey === "all" ? " selected" : "");
  all.dataset.key = "all";
  all.textContent = "all";
  all.addEventListener("click", () => select("all"));
  badges.appendChild(all);
  for (const instance of instances) {
    const chip = document.createElement("button");
    chip.type = "button";
    chip.className = "badge " + instance.state +
      (selectedKey === instance.key ? " selected" : "");
    chip.dataset.key = instance.key;
    chip.textContent = instanceLabel(instance);
    chip.addEventListener("click", () => select(instance.key));
    badges.appendChild(chip);
  }
  if (selectedKey !== "all" && !instances.some(x => x.key === selectedKey)) {
    select("all");
  }
}

async function poll() {
  try {
    const s = await (await fetch("/status")).json();
    renderChips(s.instances);
    $("meta").textContent = s.instances.length + " instances · " +
      new Date(s.now * 1000).toLocaleTimeString();
    $("runs").innerHTML = s.instances.map(run => renderRun(run, s.now)).join("");
  } catch (e) {
    $("meta").textContent = "status poll failed: " + e;
  }
  setTimeout(poll, 4000);
}

// Identity travels inside every envelope, so a row never needs correlation
// with a separately-polled owner table. That makes the old X-Signalbox-Run
// connection handshake unnecessary.
function addEvent(topic, dataText) {
  let obj = null;
  try { obj = JSON.parse(dataText); } catch (e) {}
  const t = topic || (obj && obj.type) || "message";
  const instance = obj && obj.instance && typeof obj.instance === "object"
    ? obj.instance : {};
  const key = instance.key || "";
  const pl = obj && obj.payload !== undefined ? obj.payload : obj;
  if (t === "phase.request" && pl && pl.phase === "promote") promoteStates[key] = "active";
  if (t === "pipeline.complete") promoteStates[key] = pl && pl.parked ? "parked" : "done";
  if (t === "pipeline.halted" && pl && pl.phase === "promote") promoteStates[key] = "failed";
  const div = document.createElement("div");
  div.dataset.key = key;
  div.hidden = selectedKey !== "all" && selectedKey !== key;
  div.className = "ev " + colourFor(key) +
    (t.includes("error") || t.includes("escalated") || t.includes("halted") ? " err" : "");
  const body = obj && obj.payload !== undefined ? JSON.stringify(obj.payload, null, 1)
             : obj ? JSON.stringify(obj, null, 1) : dataText;
  const candidate = obj && obj.sent_at ? new Date(obj.sent_at) : new Date();
  const when = Number.isNaN(candidate.getTime()) ? new Date() : candidate;
  const label = instanceLabel(instance);
  const engine = obj && obj.engine_label ? obj.engine_label : "engine unknown";
  const short = body.length > 700;
  div.innerHTML = '<div class="hd">' + when.toLocaleTimeString() +
    ' · <span class="event-instance"></span> · <span class="event-engine"></span>' +
    ' · <span class="topic"></span><span class="event-provenance"></span></div>' +
    (short ? '<details><summary>' + body.length + ' chars</summary><pre></pre></details>'
           : '<pre></pre>');
  div.querySelector(".event-instance").textContent = label;
  div.querySelector(".event-engine").textContent = engine;
  div.querySelector(".topic").textContent = t;
  appendProvenancePills(
    div.querySelector(".event-provenance"),
    pl && typeof pl === "object" ? pl.provenance : null
  );
  div.querySelector("pre").textContent = body;
  const feed = $("feed");
  feed.prepend(div);
  while (feed.children.length > 300) feed.lastChild.remove();
}

// One merged connection replaces all per-port fan-out. Keep the proven frame
// parser: data lines are accumulated until one complete blank-line frame.
async function attach() {
  while (true) {
    try {
      const r = await fetch("/events", {headers: {"Accept": "text/event-stream"}});
      if (!r.ok) throw new Error("stream offline");
      const rd = r.body.getReader();
      const dec = new TextDecoder();
      let buf = "";
      for (;;) {
        const { done, value } = await rd.read();
        if (done) break;
        buf += dec.decode(value, { stream: true });
        let i;
        while ((i = buf.indexOf("\n\n")) >= 0) {
          const frame = buf.slice(0, i); buf = buf.slice(i + 2);
          let ev = "", data = [];
          for (const line of frame.split("\n")) {
            if (line.startsWith("event:")) ev = line.slice(6).trim();
            else if (line.startsWith("data:")) data.push(line.slice(5).trimStart());
          }
          if (data.length) addEvent(ev, data.join("\n"));
        }
      }
    } catch (e) { /* service restarting or connection dropped */ }
    await new Promise(res => setTimeout(res, 3000));
  }
}

poll();
attach();
</script>
</body>
</html>
"""

try:
    os.makedirs(os.path.dirname(os.path.abspath(STATE)), exist_ok=True)
except OSError as exc:
    print(f"error: cannot create sink state directory for {STATE}: {exc}",
          file=sys.stderr)
    sys.exit(1)

load_registry()
try:
    SERVER = SinkServer(("127.0.0.1", PORT), Handler)
except OSError as exc:
    if exc.errno == errno.EADDRINUSE:
        print(f"error: SIGNALBOX_SINK_PORT {PORT} is already in use",
              file=sys.stderr)
    else:
        print(f"error: cannot bind SIGNALBOX_SINK_PORT {PORT}: {exc}",
              file=sys.stderr)
    sys.exit(1)

print(f"signalbox sink: http://127.0.0.1:{PORT}")
try:
    SERVER.serve_forever()
except KeyboardInterrupt:
    pass
finally:
    SERVER.server_close()
PYEOF
