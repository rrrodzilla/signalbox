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
import calendar
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

PIPELINE_STAMPS = (
    "state/pipeline-plan.stamp",
    "state/pipeline-implement.stamp",
    "state/pipeline-review.stamp",
)

# bin/run.sh writes this record before it spawns any engine, for pipeline and
# --phase launches alike, so it dates the launch that owns the run directory.
LAUNCH_RECORD = "launch.json"

ARTIFACT_GATES = {
    "plan.json": "state/pipeline-plan.stamp",
    "state/run.json": "state/pipeline-implement.stamp",
    "state/gate.json": "state/pipeline-implement.stamp",
    "results/CR.md": "state/pipeline-review.stamp",
    "state/pending.json": "state/pipeline-review.stamp",
    "state/docs-sync.json": "state/pipeline-review.stamp",
}

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


def parse_started(value):
    """Epoch seconds for an ISO-8601 UTC instant as bin/run.sh records it."""
    if not isinstance(value, str):
        return None
    try:
        return calendar.timegm(time.strptime(value, "%Y-%m-%dT%H:%M:%SZ"))
    except (TypeError, ValueError, OverflowError):
        return None


def launch_boundary(run_dir):
    """Epoch seconds at which the run directory's current launch began.

    Nothing the current launch produces can predate its launch record, so the
    record dates the boundary between this launch's artifacts and whatever an
    earlier launch of the same run directory left behind. The recorded start
    instant is preferred over the record's own mtime because bin/run.sh
    rewrites the record moments after the spawn to add the engine identity;
    the recorded instant is truncated to the second and therefore never lands
    after the launch. Returns None when a run directory carries no readable
    launch record, which leaves stale detection with only the producer-phase
    gate to go on.
    """
    if not isinstance(run_dir, str) or not run_dir or "\x00" in run_dir:
        return None
    path = os.path.join(run_dir, LAUNCH_RECORD)
    if not os.path.isfile(path):
        return None
    try:
        st = os.stat(path)
    except OSError:
        return None
    fallback = st.st_mtime if math.isfinite(st.st_mtime) else None
    try:
        with open(path, "rb") as fh:
            raw = fh.read(MAX_ARTIFACT_JSON)
            if len(raw) >= MAX_ARTIFACT_JSON or fh.read(1):
                return fallback
        record = json.loads(
            raw.decode("utf-8"),
            parse_constant=reject_constant,
            parse_float=finite_float,
        )
    except (OSError, ValueError, RecursionError):
        return fallback
    if not isinstance(record, dict):
        return fallback
    started = parse_started(record.get("started"))
    return fallback if started is None else started


def mark_stale(artifacts, boundary=None):
    """Mark run artifacts that the current launch did not produce.

    An artifact is current when it is at least as new as the launch boundary
    AND at least as new as the stamp of the phase that produces it, counting
    only a stamp the current launch itself wrote. Both halves are needed: a
    rerun under a harness that does not archive keeps the previous launch's
    artifacts and its stamps together, so the producer-phase gate alone reads
    them as current, while a bin/run.sh --phase launch writes no pipeline
    stamp at all, so the gate alone reads its fresh output as stale. Without
    a boundary — a run directory whose launch record is missing or unreadable
    — the producer-phase gate is all that is left and is applied alone.
    """
    if not isinstance(artifacts, dict):
        return artifacts

    def mtime(entry):
        if not isinstance(entry, dict):
            return None
        value = entry.get("mtime")
        if not isinstance(value, (int, float)) or isinstance(value, bool):
            return None
        try:
            return value if math.isfinite(value) else None
        except (OverflowError, TypeError, ValueError):
            return None

    for stamp in PIPELINE_STAMPS:
        entry = artifacts.get(stamp)
        if not isinstance(entry, dict):
            continue
        if entry.get("exists") is not True or boundary is None:
            entry["stale"] = False
            continue
        stamp_mtime = mtime(entry)
        entry["stale"] = stamp_mtime is None or stamp_mtime < boundary

    newest_stamp = None
    newest_clock_valid = True
    for stamp in PIPELINE_STAMPS:
        entry = artifacts.get(stamp)
        if not isinstance(entry, dict) or entry.get("exists") is not True:
            continue
        stamp_mtime = mtime(entry)
        if stamp_mtime is None:
            newest_clock_valid = False
            break
        if boundary is not None and stamp_mtime < boundary:
            continue  # a stamp the previous launch left behind
        newest_stamp = (stamp_mtime if newest_stamp is None
                        else max(newest_stamp, stamp_mtime))

    for artifact, stamp in ARTIFACT_GATES.items():
        entry = artifacts.get(artifact)
        if not isinstance(entry, dict) or entry.get("exists") is not True:
            continue
        gate = artifacts.get(stamp)
        gate_exists = isinstance(gate, dict) and gate.get("exists") is True
        gate_mtime = mtime(gate) if gate_exists else None
        entry_mtime = mtime(entry)
        if entry_mtime is None:
            entry["stale"] = True
        elif boundary is None:
            entry["stale"] = gate_mtime is None or entry_mtime < gate_mtime
        elif entry_mtime < boundary:
            entry["stale"] = True
        elif gate_exists and gate_mtime is None:
            entry["stale"] = True  # unreadable phase clock: fail conservative
        elif gate_mtime is not None and gate_mtime >= boundary:
            entry["stale"] = entry_mtime < gate_mtime
        else:
            # Produced by the current launch, which wrote no stamp for the
            # producing phase: a bin/run.sh --phase launch. It is current.
            entry["stale"] = False

    escalated = artifacts.get("state/escalated.json")
    if isinstance(escalated, dict) and escalated.get("exists") is True:
        escalated_mtime = mtime(escalated)
        if escalated_mtime is None or not newest_clock_valid:
            escalated["stale"] = True
        elif boundary is not None and escalated_mtime < boundary:
            escalated["stale"] = True
        elif boundary is None:
            escalated["stale"] = (newest_stamp is None
                                  or escalated_mtime < newest_stamp)
        else:
            escalated["stale"] = (newest_stamp is not None
                                  and escalated_mtime < newest_stamp)

    return artifacts


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
        mark_stale(artifacts, launch_boundary(run_dir))
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
<title>signalbox</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
:root {
  --enamel:#10151d;      /* page ground: blue-black stove enamel */
  --casing:#171e28;      /* panel casing */
  --casing-2:#1d2632;    /* raised fittings */
  --seam:#2a3542;        /* casing seams */
  --paint:#d3dce4;       /* diagram paint: primary text, track lines */
  --dim:#7d8894;
  --faint:#4a5560;
  --green:#46c25a;       /* clear */
  --amber:#e6a23c;       /* occupied / caution */
  --red:#e15a5f;         /* danger */
  --white-lamp:#eef4fa;  /* route set */
  --violet:#a78bfa;      /* waiting on a human */
  --blue:#5aa7e8;
}
* { box-sizing:border-box; margin:0; }
html { scrollbar-color:var(--seam) var(--enamel); }
body { background:var(--enamel); color:var(--paint);
  font:13px/1.5 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace; }
button { font:inherit; }
:focus-visible { outline:2px solid var(--amber); outline-offset:2px; }

/* ── enamel plate labels: the page's lettering identity ── */
.plate { display:inline-block; text-transform:uppercase; letter-spacing:.22em;
  font-size:10px; font-weight:700; color:var(--dim);
  border:1px solid var(--seam); border-radius:2px; padding:3px 8px 2px 10px;
  background:linear-gradient(180deg, var(--casing-2), var(--casing)); }

/* ── header strip ── */
header { display:flex; align-items:center; gap:14px; flex-wrap:wrap;
  padding:14px 18px 12px; border-bottom:1px solid var(--seam);
  background:linear-gradient(180deg,#131924,var(--enamel)); }
.wordmark { font-size:15px; font-weight:700; letter-spacing:.34em;
  text-transform:uppercase; color:var(--white-lamp); padding-left:2px; }
.wordmark .box { color:var(--amber); }
#meta { color:var(--dim); font-size:11px; letter-spacing:.05em; display:flex;
  align-items:center; gap:8px; flex-wrap:wrap; }
.lamp { display:inline-block; width:9px; height:9px; border-radius:50%;
  background:var(--faint); vertical-align:-1px; flex:none; }
.lamp.on-green { background:var(--green); box-shadow:0 0 6px 1px rgba(70,194,90,.55); }
.lamp.on-amber { background:var(--amber); box-shadow:0 0 6px 1px rgba(230,162,60,.55); }
.lamp.on-red { background:var(--red); box-shadow:0 0 6px 1px rgba(225,90,95,.55); }
.lamp.on-violet { background:var(--violet); box-shadow:0 0 6px 1px rgba(167,139,250,.55); }
.lamp.on-white { background:var(--white-lamp); box-shadow:0 0 6px 1px rgba(238,244,250,.45); }

/* ── two columns: board + register ── */
.deck { display:grid; grid-template-columns:minmax(0,1fr) 420px; gap:0; }
@media (max-width:1100px){ .deck { grid-template-columns:1fr; } }
.board { padding:16px 18px 40px; min-width:0; }
.board section { margin-bottom:22px; }
.board summary { list-style:none; cursor:pointer; }
.board summary::-webkit-details-marker { display:none; }
.board details > summary .plate::before { content:"+\00a0"; letter-spacing:0; }
.board details[open] > summary .plate::before { content:"\2212\00a0"; letter-spacing:0; }
.section-head { display:flex; align-items:baseline; gap:10px; margin-bottom:10px; }
.section-head .count { color:var(--faint); font-size:11px; }
.empty { color:var(--faint); font-size:12px; padding:14px 2px; }

/* ── run cards ── */
.run { border:1px solid var(--seam); border-radius:4px; background:var(--casing);
  margin-bottom:12px; overflow:hidden; }
.run.selected { border-color:var(--dim); box-shadow:0 0 0 1px var(--dim); }
.run.attention { border-color:color-mix(in srgb, var(--red) 45%, var(--seam)); }
.run-head { display:flex; align-items:center; gap:10px; width:100%;
  background:none; border:0; color:inherit; text-align:left; cursor:pointer;
  padding:10px 12px 8px; }
.run-title { font-size:13px; font-weight:600; color:var(--white-lamp);
  min-width:0; overflow-wrap:anywhere; }
.run-title .repo { color:var(--dim); font-weight:400; }
.run-age { margin-left:auto; color:var(--faint); font-size:11px; white-space:nowrap; }
.livery { font-size:10px; text-transform:uppercase; letter-spacing:.14em;
  color:var(--dim); white-space:nowrap; }
.livery.running { color:var(--green); }
.livery.stopped { color:var(--faint); }
.livery.stale { color:var(--amber); }

/* ── the block diagram: four track sections, one lamp each ── */
.track { display:grid; grid-template-columns:repeat(4,1fr); gap:0;
  padding:2px 12px 0; }
.block { position:relative; padding:14px 0 6px; }
.block::before { content:""; position:absolute; left:0; right:0; top:22px;
  height:2px; background:var(--faint); }
.block.done::before { background:var(--green); }
.block.active::before { background:var(--amber); }
.block.failed::before, .block.escalated::before { background:var(--red); }
.block.parked::before { background:var(--violet); }
.block:not(:first-child)::after { content:""; position:absolute; left:-1px;
  top:17px; width:2px; height:12px; background:var(--seam); }
.block .lamp { position:absolute; top:18px; left:50%; margin-left:-5px;
  width:10px; height:10px; border:1px solid var(--enamel); }
.block.active .lamp { animation:pulse 2.4s ease-in-out infinite; }
.block .bname { display:block; text-align:center; margin-top:18px;
  font-size:10px; text-transform:uppercase; letter-spacing:.16em; color:var(--faint); }
.block.done .bname { color:var(--dim); }
.block.active .bname { color:var(--amber); }
.block.failed .bname, .block.escalated .bname { color:var(--red); }
.block.parked .bname { color:var(--violet); }
@keyframes pulse { 50% { box-shadow:0 0 10px 3px rgba(230,162,60,.65); } }
@media (prefers-reduced-motion: reduce) { .block.active .lamp { animation:none; } }

/* ── sub-state within a track block: review rounds, shard sidings ── */
.block .sub { display:block; text-align:center; margin-top:3px; font-size:9px;
  letter-spacing:.08em; color:var(--dim); text-transform:none; }
.block .sub .rounds { color:var(--blue); }
.block .sub .fixing { color:var(--amber); }
.sidings { display:flex; justify-content:center; align-items:center; gap:4px;
  margin-top:4px; flex-wrap:wrap; padding:0 4px; }
.sidings .bar { width:8px; height:2px; background:var(--seam); flex:none; }
.shard-lamp { width:8px; height:8px; border-radius:2px; flex:none;
  background:transparent; border:1px solid var(--faint); }
.shard-lamp.s-building { background:var(--amber); border-color:var(--amber); }
.shard-lamp.s-review { background:var(--blue); border-color:var(--blue); }
.shard-lamp.s-fixing { background:var(--red); border-color:var(--red); }
.shard-lamp.s-done { background:var(--green); border-color:var(--green); }
.shard-lamp.s-escalated { background:var(--red); border-color:var(--red);
  animation:pulse 2.4s ease-in-out infinite; }
@media (prefers-reduced-motion: reduce) { .shard-lamp.s-escalated { animation:none; } }

/* ── status line: why this run is where it is ── */
.verdict { display:flex; gap:8px; align-items:baseline; padding:8px 12px 10px;
  font-size:12px; color:var(--dim); }
.verdict span { overflow-wrap:anywhere; min-width:0; }
.verdict b { font-weight:700; letter-spacing:.08em; flex:none; }
.verdict.v-green b { color:var(--green); } .verdict.v-red b { color:var(--red); }
.verdict.v-amber b { color:var(--amber); } .verdict.v-violet b { color:var(--violet); }
.verdict.v-white b { color:var(--white-lamp); }

/* ── per-run detail drawer ── */
.run details.drawer { border-top:1px solid var(--seam); }
.run details.drawer > summary { cursor:pointer; list-style:none; padding:6px 12px;
  color:var(--faint); font-size:10px; text-transform:uppercase; letter-spacing:.18em; }
.run details.drawer > summary::before { content:"+ "; }
.run details.drawer[open] > summary::before { content:"− "; }
.drawer-body { padding:2px 12px 12px; display:grid;
  grid-template-columns:minmax(0,5fr) minmax(0,4fr); gap:16px; }
@media (max-width:760px){ .drawer-body { grid-template-columns:1fr; } }
.drawer-body h3 { font-size:10px; text-transform:uppercase; letter-spacing:.18em;
  color:var(--faint); margin:8px 0 4px; font-weight:700; }
.idline { color:var(--dim); font-size:11px; overflow-wrap:anywhere; margin-bottom:2px; }
table { width:100%; border-collapse:collapse; font-size:11px; }
td { padding:2px 6px 2px 0; vertical-align:top; overflow-wrap:anywhere; }
td.age, td.size { color:var(--faint); white-space:nowrap; text-align:right; }
.miss { color:var(--faint); }
.stale { color:var(--faint); opacity:.65; }
.badge-stale { margin-left:4px; padding:0 5px; border:1px solid var(--seam);
  border-radius:8px; color:var(--faint); font-size:10px; white-space:nowrap; }
.ok { color:var(--green); } .bad { color:var(--red); }

/* ── provenance pills (asserted by tests: keep class names) ── */
.pill { display:inline-block; margin-left:4px; padding:0 6px; border:1px solid var(--seam);
  border-radius:9px; color:var(--dim); font-size:10px; font-weight:400;
  line-height:15px; vertical-align:baseline; }
.pill.agent-claude { color:var(--violet); border-color:var(--violet); }
.pill.agent-codex { color:var(--blue); border-color:var(--blue); }
.pill.agent-other { color:var(--dim); border-color:var(--dim); }
.pill.model { color:var(--paint); border-color:var(--seam); }
.pill.effort-low { color:var(--dim); border-color:var(--dim); opacity:.7; }
.pill.effort-medium { color:var(--green); border-color:var(--green); opacity:.8; }
.pill.effort-high { color:var(--blue); border-color:var(--blue); opacity:.9; }
.pill.effort-xhigh { color:var(--amber); border-color:var(--amber); }
.pill.effort-max { color:var(--red); border-color:var(--red); font-weight:600; }

/* ── the register: live event log, sticky right rail ── */
.register { border-left:1px solid var(--seam); min-width:0; }
.register-inner { position:sticky; top:0; max-height:100vh; display:flex;
  flex-direction:column; padding:16px 16px 12px; }
@media (max-width:1100px){ .register { border-left:0; border-top:1px solid var(--seam); }
  .register-inner { position:static; max-height:none; } }
.register-head { display:flex; align-items:baseline; gap:10px; margin-bottom:8px; }
.badges { display:flex; gap:6px; flex-wrap:wrap; margin-bottom:10px; }
.badge { appearance:none; background:transparent; font-size:10px; padding:2px 8px;
  border-radius:9px; border:1px solid var(--seam); color:var(--dim); cursor:pointer;
  letter-spacing:.04em; }
.badge.running { color:var(--green); border-color:var(--green); }
.badge.stopped { color:var(--faint); }
.badge.stale { color:var(--amber); border-color:var(--amber); }
.badge.unknown { color:var(--violet); border-color:var(--violet); }
.badge.selected { background:var(--casing-2); box-shadow:0 0 0 1px currentColor; }
#feed { overflow-y:auto; display:flex; flex-direction:column; gap:5px;
  scrollbar-width:thin; }
.ev { border-left:3px solid var(--seam); padding:2px 8px; font-size:11px; }
.ev .hd { color:var(--dim); overflow-wrap:anywhere; }
.ev .topic { font-weight:600; }
.ev pre { white-space:pre-wrap; word-break:break-word; color:var(--paint); margin-top:2px; }
.ev details pre { max-height:220px; overflow-y:auto; }
.ev details summary { cursor:pointer; color:var(--faint); }
.ev.c0 { border-color:var(--blue); } .ev.c0 .topic { color:var(--blue); }
.ev.c1 { border-color:var(--violet); } .ev.c1 .topic { color:var(--violet); }
.ev.c2 { border-color:var(--amber); } .ev.c2 .topic { color:var(--amber); }
.ev.c3 { border-color:var(--green); } .ev.c3 .topic { color:var(--green); }
.ev.c4 { border-color:var(--dim); }
.ev.err { border-color:var(--red); background:rgba(225,90,95,.06); }
.ev.err .topic { color:var(--red); }
</style>
</head>
<body>
<header>
  <div class="wordmark">Signal<span class="box">box</span></div>
  <div id="meta"><span class="lamp" id="stream-lamp"></span><span id="meta-text">connecting…</span></div>
</header>
<div class="deck">
  <main class="board" id="board" aria-label="runs"></main>
  <aside class="register" aria-label="event register">
    <div class="register-inner">
      <div class="register-head"><span class="plate">Register</span></div>
      <div class="badges" id="badges"></div>
      <div id="feed"><div class="empty" id="feed-empty">Waiting for events…</div></div>
    </div>
  </aside>
</div>
<script>
const PHASES = ["plan","implement","review","promote"];
const ACTIVITY_PHASES = ["plan","implement","review"];
const promoteStates = Object.create(null);
const haltInfo = Object.create(null);      // key -> {phase, reason} from pipeline.halted
const completeInfo = Object.create(null);  // key -> {parked, reason} from pipeline.complete
const reviewLoop = Object.create(null);    // key -> {mode, round} from the review-phase cycle
const shardYard = Object.create(null);     // key -> stage -> shard -> {state, round}
const phaseActivity = Object.create(null); // key -> phase -> true, from this launch's live events
const instanceColours = Object.create(null);
const openDrawers = new Set();             // run keys whose detail drawer is open
let stoppedOpen = false;                   // the collapsed STOPPED section
let selectedKey = "all";
let lastStatus = null;
const $ = id => document.getElementById(id);

function markPhaseActive(key, phase) {
  if (!ACTIVITY_PHASES.includes(phase)) return;
  const activity = phaseActivity[key] || (phaseActivity[key] = Object.create(null));
  activity[phase] = true;
}

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

// Phase state is derived from the current launch only. A stamp or artifact
// /status marked stale belongs to an earlier launch of the same run
// directory, so it is dropped here rather than read as this launch's
// progress. An artifact that is live while its producing phase has no live
// stamp is a bin/run.sh --phase launch: the phase produced it, so it counts
// as done. A live state/escalated.json is already newer than every live
// stamp — /status marks it stale otherwise — so no stamp comparison is left
// to make.
//
// A live phase event may upgrade a blank phase to active, including before
// its first artifact lands, but it never contradicts an artifact-derived
// terminal state.
function derive(run) {
  const a = run.artifacts;
  const live = x => (x && x.exists === true && x.stale !== true) ? x : null;
  const stamp = p => live(a["state/pipeline-" + p + ".stamp"]);
  const out = {};
  const ps = stamp("plan"), pj = live(a["plan.json"]);
  if (!ps) out.plan = pj ? "done" : "pending";
  else out.plan = (pj && pj.mtime >= ps.mtime) ? "done" : "active";
  const is = stamp("implement"), gj = live(a["state/gate.json"]);
  const verdictState = () => (gj.json && gj.json.verdict === "GREEN") ? "done" : "failed";
  if (!is) out.implement = gj ? verdictState() : "pending";
  else if (gj && gj.mtime >= is.mtime) out.implement = verdictState();
  else out.implement = "active";
  const rs = stamp("review"), cr = live(a["results/CR.md"]), pend = live(a["state/pending.json"]);
  if (!rs) out.review = cr ? "done" : (pend ? "parked" : "pending");
  else if (cr && cr.mtime >= rs.mtime) out.review = "done";
  else if (pend && pend.mtime >= rs.mtime) out.review = "parked";
  else out.review = "active";
  out.promote = promoteStates[run.key] || "pending";
  const activity = phaseActivity[run.key] || {};
  for (const p of ACTIVITY_PHASES) {
    if (out[p] === "pending" && activity[p]) out[p] = "active";
  }
  const esc = live(a["state/escalated.json"]);
  if (esc && esc.json) {
    const p = esc.json.escalated_phase === "shard" ? "implement" : esc.json.escalated_phase;
    if (out[p]) out[p] = "escalated";
  }
  return out;
}

function artifactRows(run, now) {
  return Object.values(run.artifacts).map(x => {
    let extra = "";
    const stale = x.exists && x.stale === true;
    if (stale) {
      extra = ' <span class="badge-stale">' + esc("previous run") + "</span>";
    }
    if (x.exists && x.json && x.json.verdict) {
      const verdictClass = x.json.verdict === "GREEN" ? "ok" : "bad";
      extra += ' <span class="' + verdictClass + '">' + esc(x.json.verdict) + "</span>";
    }
    extra += provenancePills(x.provenance);
    return "<tr class='" + (stale ? "stale" : "") + "'><td class='" +
      (x.exists ? "" : "miss") + "'>" + esc(x.file) + extra + "</td>" +
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

// One line that answers "why is this run where it is". Precedence: terminal
// outcomes, then human-gated states, then the derived active phase.
function verdictFor(run, states) {
  const finished = completeInfo[run.key];
  if (finished) {
    return finished.parked
      ? { cls:"v-violet", label:"PARKED", text:finished.reason || "awaiting human approval" }
      : { cls:"v-green", label:"COMPLETE", text:finished.reason || "merged; release is the human's" };
  }
  const halted = haltInfo[run.key];
  if (halted) {
    return { cls:"v-red", label:"HALTED AT " + (halted.phase || "?").toUpperCase(),
             text:halted.reason || "see engine log" };
  }
  const escArt = run.artifacts["state/escalated.json"];
  const escPhase = PHASES.find(p => states[p] === "escalated");
  if (escPhase) {
    const why = escArt.exists && escArt.stale !== true && escArt.json &&
      (escArt.json.reason || escArt.json.summary);
    return { cls:"v-red", label:"ESCALATED IN " + escPhase.toUpperCase(),
             text:why || "escalation recorded" };
  }
  if (states.review === "parked") {
    const pend = run.artifacts["state/pending.json"];
    const j = pend.exists && pend.stale !== true && pend.json ? pend.json : null;
    const bits = [];
    if (j && j.floor !== undefined) bits.push("floor R" + j.floor);
    if (j && j.earned !== undefined) bits.push("earned R" + j.earned);
    if (j && j.reason) bits.push(j.reason);
    return { cls:"v-violet", label:"PARKED",
             text:bits.join(" · ") || "state/pending.json present — approval is yours" };
  }
  const gate = run.artifacts["state/gate.json"];
  const cr = run.artifacts["results/CR.md"];
  if (gate.exists && gate.stale !== true && gate.json &&
      gate.json.verdict && gate.json.verdict !== "GREEN") {
    return { cls:"v-red", label:"GATE " + gate.json.verdict,
             text:"tip " + (gate.json.tip || "?") };
  }
  if (cr.exists && cr.stale !== true &&
      states.review === "done" && states.promote === "pending") {
    return { cls:"v-white", label:"PROMOTION READY",
             text:"CR.md written" + (gate.exists && gate.stale !== true &&
               gate.json && gate.json.tip
               ? " · gate GREEN at " + gate.json.tip : "") };
  }
  const activePhase = PHASES.find(p => states[p] === "active");
  if (states.promote === "active") {
    return { cls:"v-amber", label:"PROMOTING", text:"push, PR, merge in flight" };
  }
  if (activePhase) {
    let text = "";
    if (activePhase === "review" && reviewLoop[run.key]) {
      const rl = reviewLoop[run.key];
      text = "round " + rl.round + (rl.mode === "fixing"
        ? " · fixer addressing feedback"
        : rl.mode === "approved" ? " approved · gate and docs-sync"
        : " · reviewer at work");
    }
    if (activePhase === "implement") {
      const counts = yardCounts(run);
      if (counts) text = counts.done + "/" + counts.total + " shards approved";
    }
    return { cls:"v-amber", label:activePhase.toUpperCase() + " IN PROGRESS", text };
  }
  if (PHASES.every(p => states[p] === "pending")) {
    return { cls:"", label:"WAITING", text:"no phase started yet" };
  }
  return { cls:"", label:"IDLE", text:"" };
}

// Sections of the board, by claim on the operator's attention.
function groupFor(run, states, verdict) {
  const needsHand = verdict.cls === "v-red" || verdict.cls === "v-violet";
  if (needsHand) return 0;
  if (completeInfo[run.key] && !completeInfo[run.key].parked) return 3;
  if (run.state === "running") return 1;
  if (run.state === "stopped") return 3;
  return 2;
}

function headLamp(run, verdict) {
  if (verdict.cls === "v-red") return "on-red";
  if (verdict.cls === "v-violet") return "on-violet";
  if (run.state === "running") return "on-green";
  if (run.state === "stale") return "on-amber";
  return "";
}

function shardName(s) {
  if (s && typeof s === "object") {
    if (typeof s.shard === "string" && s.shard) return s.shard;
    if (typeof s.id === "string" && s.id) return s.id;
    return null;
  }
  return typeof s === "string" && s ? s : null;
}

function markShard(key, stage, name, state, round) {
  if (!name) return;
  const yard = shardYard[key] || (shardYard[key] = Object.create(null));
  const st = yard[stage] || (yard[stage] = Object.create(null));
  const prev = st[name];
  st[name] = { state, round: round || (prev && prev.round) || 0 };
}

// One lamp per planned shard, in plan order, with a barrier bar between
// stages: the fan-out and the fan-in points made visible. plan.json names
// every shard up front; live states arrive from the implement engine's
// shard events, so a shard with no event yet renders hollow.
function yardCounts(run) {
  const pj = run.artifacts["plan.json"];
  const stages = pj.exists && pj.json && Array.isArray(pj.json.stages)
    ? pj.json.stages : [];
  const yard = shardYard[run.key] || {};
  let done = 0, total = 0;
  for (const stg of stages) {
    if (!stg || typeof stg !== "object" || !Array.isArray(stg.shards)) continue;
    for (const s of stg.shards) {
      const n = shardName(s);
      if (!n) continue;
      total++;
      const info = yard[stg.id] && yard[stg.id][n];
      if (info && info.state === "done") done++;
    }
  }
  return total ? { done, total } : null;
}

function sidings(run, states) {
  if (states.implement !== "active" && states.implement !== "failed"
      && states.implement !== "escalated") return "";
  const pj = run.artifacts["plan.json"];
  const stages = pj.exists && pj.json && Array.isArray(pj.json.stages)
    ? pj.json.stages : [];
  const yard = shardYard[run.key] || {};
  const parts = [];
  for (const stg of stages) {
    if (!stg || typeof stg !== "object" || !Array.isArray(stg.shards)) continue;
    const lamps = [];
    for (const s of stg.shards) {
      const n = shardName(s);
      if (!n) continue;
      const info = yard[stg.id] && yard[stg.id][n];
      const state = info ? info.state : "pending";
      const roundText = info && info.round > 1 ? " · R" + info.round : "";
      lamps.push('<span class="shard-lamp s-' + esc(state) + '" title="' +
        esc(n) + " · " + esc(state) + esc(roundText) + '"></span>');
    }
    if (!lamps.length) continue;
    if (parts.length) parts.push('<span class="bar"></span>');
    parts.push(lamps.join(""));
  }
  if (!parts.length) return "";
  const counts = yardCounts(run);
  return '<span class="sub">' + (counts ? counts.done + "/" + counts.total +
      " shards" : "") + "</span>" +
    '<div class="sidings">' + parts.join("") + "</div>";
}

// The review phase is a loop, not a line: reviewer -> fixer -> reviewer until
// approved or escalated. Name the round and whose hands the work is in.
function reviewSub(run, states) {
  if (states.review !== "active") return "";
  const rl = reviewLoop[run.key];
  if (!rl) return "";
  const mode = rl.mode === "fixing"
      ? '<span class="fixing">fix in flight</span>'
    : rl.mode === "approved" ? "approved · gate + docs"
    : rl.mode === "escalated" ? "escalated"
    : "reviewer at work";
  return '<span class="sub"><span class="rounds">&#8635; R' + rl.round +
    "</span> · " + mode + "</span>";
}

function runCard(run, now, states, verdict, attention) {
  const feature = run.feature || run.slug || "run " + run.key;
  const issue = run.issue === null || run.issue === undefined ? "" : " #" + run.issue;
  const repo = run.repo || "repo unknown";
  const track = PHASES.map(p => {
    const extra = p === "implement" ? sidings(run, states)
      : p === "review" ? reviewSub(run, states) : "";
    return '<div class="block ' + states[p] + '"><span class="lamp ' +
      ({done:"on-green", active:"on-amber", failed:"on-red", escalated:"on-red",
        parked:"on-violet"}[states[p]] || "") + '"></span>' +
      '<span class="bname">' + p + "</span>" + extra + "</div>";
  }).join("");
  const engines = Object.entries(run.engines || {}).map(([label, engine]) =>
    esc(label) + "=" + esc(engine)).join(" · ") || "no engines registered";
  const runJson = run.artifacts["state/run.json"];
  const correlation = runJson.exists && runJson.stale !== true &&
    runJson.json && runJson.json.correlation_id
    ? '<div class="idline">correlation ' + esc(runJson.json.correlation_id) + "</div>" : "";
  const docs = run.artifacts["state/docs-sync.json"];
  const docsLine = docs.exists && docs.stale !== true &&
    docs.json && Array.isArray(docs.json.updated)
    ? '<div class="idline">docs-sync: ' + esc(docs.json.updated.join(", ") || "none") + "</div>" : "";
  return '<article class="run ' + (attention ? "attention " : "") +
      (selectedKey === run.key ? "selected" : "") + '" data-key="' + esc(run.key) + '">' +
    '<button type="button" class="run-head" data-select="' + esc(run.key) + '">' +
      '<span class="lamp ' + headLamp(run, verdict) + '"></span>' +
      '<span class="run-title"><span class="repo">' + esc(repo) + "</span> " +
        esc(feature) + esc(issue) + "</span>" +
      '<span class="livery ' + esc(run.state) + '">' + esc(run.state) + "</span>" +
      '<span class="run-age">' + age(now, run.last_event) + " ago</span>" +
    "</button>" +
    '<div class="track">' + track + "</div>" +
    '<div class="verdict ' + verdict.cls + '"><b>' + esc(verdict.label) + "</b>" +
      (verdict.text ? "<span>" + esc(verdict.text) + "</span>" : "") + "</div>" +
    '<details class="drawer"' + (openDrawers.has(run.key) ? " open" : "") +
      ' data-drawer="' + esc(run.key) + '"><summary>Artifacts, logs, identity</summary>' +
      '<div class="drawer-body"><div>' +
        '<h3>Disk artifacts — the terminals that count</h3>' +
        "<table>" + artifactRows(run, now) + "</table></div>" +
      "<div>" +
        '<h3>Identity</h3>' +
        '<div class="idline">pid ' + esc(run.pid === null || run.pid === undefined ? "unknown" : run.pid) +
          " · " + esc(run.key) + "</div>" +
        correlation + docsLine +
        '<div class="idline">' + engines + "</div>" +
        '<div class="idline">' + esc(run.run_dir || "run directory unknown") + "</div>" +
        '<h3>Engine logs — buffered, sizes grow on flush</h3>' +
        "<table>" + logRows(run, now) + "</table></div>" +
      "</div></details></article>";
}

const SECTIONS = [
  { name:"Attention", hint:"needs your hand" },
  { name:"Running", hint:"in motion" },
  { name:"Quiet", hint:"no launch identity; going stale" },
  { name:"Stopped", hint:"engines gone or complete" },
];

function renderBoard(instances, now) {
  const groups = [[], [], [], []];
  for (const run of instances) {
    const states = derive(run);
    const verdict = verdictFor(run, states);
    const g = groupFor(run, states, verdict);
    groups[g].push(runCard(run, now, states, verdict, g === 0));
  }
  let html = "";
  if (!instances.length) {
    html = '<div class="empty">No boxes registered. Launch one with bin/run.sh &lt;issue&gt;.</div>';
  }
  for (let g = 0; g < 4; g++) {
    if (!groups[g].length) continue;
    const head = '<div class="section-head"><span class="plate">' + SECTIONS[g].name +
      '</span><span class="count">' + groups[g].length + " · " + SECTIONS[g].hint + "</span></div>";
    if (g === 3) {
      html += '<section><details' + (stoppedOpen ? " open" : "") + ' data-stopped>' +
        "<summary>" + head + "</summary>" + groups[g].join("") + "</details></section>";
    } else {
      html += "<section>" + head + groups[g].join("") + "</section>";
    }
  }
  const board = $("board");
  board.innerHTML = html;
  for (const btn of board.querySelectorAll("[data-select]")) {
    btn.addEventListener("click", () => {
      select(selectedKey === btn.dataset.select ? "all" : btn.dataset.select);
    });
  }
  for (const drawer of board.querySelectorAll("[data-drawer]")) {
    drawer.addEventListener("toggle", () => {
      if (drawer.open) openDrawers.add(drawer.dataset.drawer);
      else openDrawers.delete(drawer.dataset.drawer);
    });
  }
  const stopped = board.querySelector("[data-stopped]");
  if (stopped) {
    stopped.addEventListener("toggle", () => { stoppedOpen = stopped.open; });
  }
}

function select(key) {
  selectedKey = key;
  for (const row of $("feed").children) {
    if (row.id === "feed-empty") continue;
    row.hidden = key !== "all" && row.dataset.key !== key;
  }
  for (const chip of $("badges").children) {
    chip.classList.toggle("selected", chip.dataset.key === key);
  }
  for (const card of $("board").querySelectorAll(".run")) {
    card.classList.toggle("selected", card.dataset.key === key);
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
    lastStatus = s;
    renderChips(s.instances);
    const running = s.instances.filter(x => x.state === "running").length;
    $("meta-text").textContent = s.instances.length + " boxes · " + running +
      " running · " + new Date(s.now * 1000).toLocaleTimeString();
    renderBoard(s.instances, s.now);
  } catch (e) {
    $("meta-text").textContent = "status poll failed: " + e;
  }
  setTimeout(poll, 4000);
}

// Apply the run-state half of an event. It is DOM-free so tests can exercise
// it directly.
function applyRunState(t, key, pl, engineLabel) {
  // A run re-enters through phase.request in the pipeline topology, or through
  // system.started.* when bin/run.sh --phase starts a phase engine directly
  // and never publishes phase.request. verdictFor checks terminal latches
  // before every state the new launch can produce, so either latch would
  // otherwise shadow the entire relaunch.
  const phaseRequested = t === "phase.request" && pl &&
    typeof pl.phase === "string";
  const reentered = phaseRequested || t.indexOf("system.started.") === 0;
  if (reentered) {
    delete haltInfo[key];
    delete completeInfo[key];
    if (promoteStates[key] !== "active") delete promoteStates[key];
  }
  // The pipeline advances one phase at a time, so a new request replaces
  // every live-activity mark left by the phase it just advanced from.
  if (phaseRequested) {
    delete phaseActivity[key];
    markPhaseActive(key, pl.phase);
  }
  // Any phase-scoped event proves that phase is running. A system.stopped.*
  // event only reports engine wind-down, so it is not progress.
  if (t.indexOf("system.stopped.") !== 0) markPhaseActive(key, engineLabel);
  if (t === "phase.request" && pl && pl.phase === "promote") promoteStates[key] = "active";
  // A phase (re)start clears that phase's cycle state so a rerun of the same
  // run key never wears the previous attempt's rounds or shard lamps.
  // Keep these phase.request-only: system.started.* arrives once per node, and
  // a late node can follow fresh cycle events from the same launch.
  if (t === "phase.request" && pl && pl.phase === "implement") delete shardYard[key];
  if (t === "phase.request" && pl && pl.phase === "review") delete reviewLoop[key];
  const round = pl && typeof pl.round === "number" ? pl.round : 1;
  // The review phase is a cycle (review -> fix -> review), not one long state.
  // Track whose hands the work is in and which round it is on.
  if (engineLabel === "review") {
    if (t === "review.requested") reviewLoop[key] = { mode:"review", round };
    if (t === "fix.requested") reviewLoop[key] = { mode:"fixing", round };
    if (t === "review.approved") reviewLoop[key] = { mode:"approved", round };
    if (t === "review.escalated") reviewLoop[key] = { mode:"escalated", round };
  }
  // Implement fan-out: per-shard states keyed by the plan's shard ids.
  if (t === "stage.item" && pl && typeof pl.id === "string" && Array.isArray(pl.shards)) {
    for (const s of pl.shards) markShard(key, pl.id, shardName(s), "building");
  }
  if (t === "shard.built" && pl && typeof pl.stage === "string") {
    for (const s of (Array.isArray(pl.pending) ? pl.pending : []))
      markShard(key, pl.stage, shardName(s), "review");
    for (const s of (Array.isArray(pl.done) ? pl.done : []))
      markShard(key, pl.stage, shardName(s), "done");
  }
  if ((t === "shard.review.raw" || t === "shard.fix.requested")
      && pl && typeof pl.stage === "string" && pl.current) {
    const n = shardName(pl.current);
    if (t === "shard.review.raw" && pl.verdict === "APPROVED")
      markShard(key, pl.stage, n, "done", round);
    else if (pl.verdict === "REQUEST_CHANGES" && round >= 3)
      markShard(key, pl.stage, n, "escalated", round);
    else markShard(key, pl.stage, n, "fixing", round);
  }
  if (t === "shard.done" && pl && typeof pl.stage === "string") {
    for (const s of (Array.isArray(pl.done) ? pl.done : []))
      markShard(key, pl.stage, shardName(s), "done");
  }
  // A phase terminal releases its live mark; fresh artifacts remain the
  // authority for whether that phase finished successfully.
  if (t === "phase.done" && pl && typeof pl.phase === "string" && phaseActivity[key]) {
    delete phaseActivity[key][pl.phase];
  }
  if (t === "pipeline.complete") {
    // Pipeline terminals latch the verdict and clear every in-flight phase.
    delete phaseActivity[key];
    promoteStates[key] = pl && pl.parked ? "parked" : "done";
    completeInfo[key] = {
      parked: !!(pl && pl.parked),
      reason: pl && typeof pl.reason === "string" ? pl.reason.slice(0, 300) : ""
    };
  }
  if (t === "pipeline.halted") {
    // Pipeline terminals latch the verdict and clear every in-flight phase.
    delete phaseActivity[key];
    if (pl && pl.phase === "promote") promoteStates[key] = "failed";
    haltInfo[key] = {
      phase: pl && typeof pl.phase === "string" ? pl.phase : "",
      reason: pl && typeof pl.reason === "string" ? pl.reason.slice(0, 300) : ""
    };
  }
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
  applyRunState(t, key, pl, obj && obj.engine_label ? obj.engine_label : "");
  const div = document.createElement("div");
  div.dataset.key = key;
  div.hidden = selectedKey !== "all" && selectedKey !== key;
  // exec.error fires on any stderr output, even from healthy commands whose
  // diagnostics deliberately go to stderr; only a non-zero (or absent, e.g.
  // timeout/spawn-failure) exit code marks a genuine failure.
  const benignExecError = t === "exec.error" && pl && pl.exit_code === 0;
  div.className = "ev " + colourFor(key) +
    ((t.includes("error") && !benignExecError) ||
      t.includes("escalated") || t.includes("halted") ? " err" : "");
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
  const placeholder = $("feed-empty");
  if (placeholder) placeholder.remove();
  feed.prepend(div);
  while (feed.children.length > 300) feed.lastChild.remove();
}

// One merged connection replaces all per-port fan-out. Keep the proven frame
// parser: data lines are accumulated until one complete blank-line frame.
async function attach() {
  const streamLamp = $("stream-lamp");
  while (true) {
    try {
      const r = await fetch("/events", {headers: {"Accept": "text/event-stream"}});
      if (!r.ok) throw new Error("stream offline");
      streamLamp.className = "lamp on-green";
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
    streamLamp.className = "lamp on-red";
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
