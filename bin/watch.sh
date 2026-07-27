#!/usr/bin/env bash
# Live watch dashboard for a signalbox harness.
#
#   bin/watch.sh [harness-dir]     (default: ./.claude/emergent)
#
# Serves the dashboard with:
#   /                     the dashboard page
#   /status               JSON snapshot of the disk artifacts (the same
#                         terminals the phase runner and operator trust)
#                         plus the discovered stream list
#   /stream/<port>/events proxy to that topology's watchtower sse-sink,
#                         so the browser needs no CORS and one origin
#                         covers every engine
#
# Nothing here assumes port numbers: the watchtower ports are discovered
# by parsing every run's rendered TOMLs, plus the harness-root TOMLs used by
# single-run/prototype launches. Port leases are released and reused, so a
# finished run's TOML can still name a port a newer run now owns; streams are
# therefore claimed by run liveness (see resolve_stream_ports). The page port
# is WATCH_PORT if set, else 8099, else an ephemeral port — the URL actually
# bound is always printed.
#
# The artifact poll works even for engines started before the watchtower
# sinks existed; the SSE streams light up whenever an engine with a
# watchtower is running. Read-only: this never touches the harness.
set -euo pipefail

HARNESS="${1:-$(pwd)/.claude/emergent}"
[ -d "$HARNESS" ] || { echo "no harness at $HARNESS (pass the .claude/emergent dir)" >&2; exit 64; }
HARNESS="$(cd "$HARNESS" && pwd)"

# WATCH_PORT set -> bind exactly that or fail; unset -> 8099, then ephemeral.
if [ -n "${WATCH_PORT:-}" ]; then MODE="strict"; PORT="$WATCH_PORT"; else MODE="auto"; PORT=8099; fi

echo "harness: $HARNESS"
exec python3 - "$HARNESS" "$PORT" "$MODE" <<'PYEOF'
import errno, json, os, sys, time, tomllib
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HARNESS = sys.argv[1]
PORT = int(sys.argv[2])
MODE = sys.argv[3]

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

# Filename -> stream label; emergent.toml is the review loop for legacy reasons.
TOML_LABELS = [("pipeline.toml", "pipeline"), ("plan.toml", "plan"),
               ("implement.toml", "implement"), ("emergent.toml", "review"),
               ("init.toml", "init")]

def discover_streams(run_dir, slug):
    """Return this run's watchtower streams from its rendered TOMLs."""
    streams = []
    for fn, label in TOML_LABELS:
        p = os.path.join(run_dir, fn)
        if not os.path.isfile(p):
            continue
        try:
            with open(p, "rb") as fh:
                cfg = tomllib.load(fh)
        except (OSError, tomllib.TOMLDecodeError):
            continue
        for sink in cfg.get("sinks", []):
            if sink.get("name") != "watchtower":
                continue
            args = sink.get("args", [])
            try:
                streams.append({
                    "run": slug,
                    "name": label,
                    "port": int(args[args.index("--port") + 1]),
                })
            except (TypeError, ValueError, IndexError):
                pass
    return streams

def artifact_info(run_dir, rel):
    p = os.path.join(run_dir, rel)
    info = {"file": rel, "exists": os.path.isfile(p)}
    if info["exists"]:
        try:
            st = os.stat(p)
        except OSError:
            info["exists"] = False
            return info
        info["mtime"] = st.st_mtime
        info["size"] = st.st_size
        if rel.endswith(".json") and st.st_size < 262144:
            try:
                with open(p) as fh:
                    info["json"] = json.load(fh)
            except (OSError, ValueError):
                info["json"] = None
    return info

def load_launch(run_dir):
    p = os.path.join(run_dir, "launch.json")
    if not os.path.isfile(p):
        return None
    try:
        with open(p) as fh:
            launch = json.load(fh)
    except (OSError, ValueError):
        return None
    return launch if isinstance(launch, dict) else None

def engine_pid(run_dir):
    """The active-run marker bin/run.sh writes on launch and removes on exit."""
    p = os.path.join(run_dir, "state", "engine.pid")
    try:
        with open(p) as fh:
            first = fh.readline().strip()
    except OSError:
        return None
    try:
        return int(first)
    except ValueError:
        return None

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

def pid_state(pid, marker_pid, start_id):
    """Liveness of a run's launch PID, corroborated by marker AND identity.

    A launch PID alone proves nothing once the run is over: the OS recycles
    PIDs, so an unrelated process can make a finished run look alive and keep
    it holding a port its lease already released. bin/run.sh removes
    state/engine.pid on exit, but the marker can survive SIGKILL or a reboot —
    so marker equality plus kill(0) is still not identity. The process counts
    as alive only when its start identity is EXACTLY the one bin/run.sh
    recorded for the engine it spawned. A time window would not do: a process
    that inherits a recycled PID moments after the launch falls inside any
    window wide enough to absorb the launcher's own stamping delay. When
    /proc cannot answer, or the run predates start_id, the verdict is
    unknown."""
    if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0:
        return "unknown"
    if marker_pid != pid:
        return "dead"
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return "dead"
    except OSError:
        pass  # exists (EPERM) or indeterminate; identity check decides below
    if not isinstance(start_id, str) or not start_id:
        return "unknown"
    current = proc_start_id(pid)
    if current is None:
        return "unknown"
    return "alive" if current == start_id else "dead"

def log_info(run_dir):
    logs = []
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

def run_info(run_dir, fallback_slug):
    launch = load_launch(run_dir)
    slug = fallback_slug
    if fallback_slug != "single-run" and launch:
        launch_slug = launch.get("slug")
        if isinstance(launch_slug, str) and launch_slug:
            slug = launch_slug
    artifacts = {a: artifact_info(run_dir, a) for a in ARTIFACTS}
    logs = log_info(run_dir)
    plan = artifacts["plan.json"].get("json")
    feature = plan.get("feature") if isinstance(plan, dict) else None
    issue = launch.get("issue") if launch else None
    if issue is None and isinstance(plan, dict):
        issue = plan.get("issue")
    return {
        "slug": slug,
        "issue": issue,
        "feature": feature,
        "launch": launch,
        "pid_state": pid_state(launch.get("pid") if launch else None,
                               engine_pid(run_dir),
                               launch.get("start_id") if launch else None),
        "artifacts": artifacts,
        "logs": logs,
        "streams": discover_streams(run_dir, slug),
    }

# Liveness ranking used to settle a port claimed by more than one run.
# "unknown" covers runs with no launch.json (prototype/single-run launches),
# which still deserve a stream when nothing live contradicts them.
PID_RANK = {"alive": 2, "unknown": 1, "dead": 0}

def resolve_stream_ports(runs):
    """Give each watchtower port to exactly one run, by liveness.

    A released port lease can be re-leased to a later run while the earlier
    run's rendered TOML still names it. Left alone, a finished run's stream
    would relabel the active run's events (and its promote state). So: a dead
    run owns no stream at all, and among the survivors a live run outranks an
    "unknown" one. Ties keep the first run scanned.

    A finished run always ranks dead here, PID recycling included, because
    pid_state requires its engine.pid marker to still name the launch PID.
    """
    owner = {}
    for run_idx, run in enumerate(runs):
        rank = PID_RANK.get(run["pid_state"], 1)
        if rank == 0:
            continue
        for stream_idx, stream in enumerate(run["streams"]):
            best = owner.get(stream["port"])
            if best is None or rank > best[0]:
                owner[stream["port"]] = (rank, run_idx, stream_idx)
    for run_idx, run in enumerate(runs):
        run["streams"] = [
            stream
            for stream_idx, stream in enumerate(run["streams"])
            if owner.get(stream["port"], (0, -1, -1))[1:] == (run_idx, stream_idx)
        ]
    return runs

def discover_runs():
    """Re-scan run directories and TOMLs for every request."""
    runs = []
    runs_dir = os.path.join(HARNESS, "runs")
    if os.path.isdir(runs_dir):
        try:
            names = sorted(os.listdir(runs_dir))
        except OSError:
            names = []
        for name in names:
            run_dir = os.path.join(runs_dir, name)
            if os.path.isdir(run_dir):
                runs.append(run_info(run_dir, name))

    root = run_info(HARNESS, "single-run")
    root_has_artifacts = (
        root["launch"] is not None
        or bool(root["logs"])
        or any(a["exists"] for a in root["artifacts"].values())
    )
    if root_has_artifacts:
        runs.append(root)
    return resolve_stream_ports(runs)

def status():
    return {"now": time.time(), "harness": HARNESS, "runs": discover_runs()}

def header_text(value):
    """Header-safe label: run slugs come from launch.json, headers are ASCII."""
    return "".join(c if 32 <= ord(c) < 127 else "?" for c in str(value))

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
        self.wfile.write(body)

    def do_GET(self):
        if self.path in ("/", "/index.html"):
            self._body(200, "text/html; charset=utf-8", PAGE.encode())
        elif self.path == "/status":
            self._body(200, "application/json", json.dumps(status()).encode())
        elif self.path.startswith("/stream/"):
            parts = self.path.split("/")
            try:
                port = int(parts[2])
            except (IndexError, ValueError):
                self._body(400, "text/plain", b"bad stream path")
                return
            # resolve_stream_ports leaves at most one stream per port, so this
            # is the port's sole owner as of this connect.
            owners = {
                stream["port"]: stream
                for run in discover_runs()
                for stream in run["streams"]
            }
            owner = owners.get(port)
            if owner is None:
                self._body(404, "text/plain", b"unknown stream port")
                return
            self.proxy_sse(port, owner)
        else:
            self._body(404, "text/plain", b"not found")

    def proxy_sse(self, port, owner):
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=4)
        try:
            conn.request("GET", "/events", headers={"Accept": "text/event-stream"})
            resp = conn.getresponse()
        except OSError:
            conn.close()
            self._body(502, "text/plain", b"stream offline")
            return
        if resp.status != 200:
            conn.close()
            self._body(502, "text/plain", b"stream offline")
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-store")
        # The owner resolved for this connection, so the page can label the
        # events it is about to read without waiting for its next /status poll
        # — a port re-leased between polls would otherwise carry the previous
        # run's name (and promote state) into the new owner's events.
        self.send_header("X-Signalbox-Run", header_text(owner["run"]))
        self.send_header("X-Signalbox-Stream", header_text(owner["name"]))
        self.end_headers()
        # SSE idles between events; only the connect gets a timeout.
        conn.sock.settimeout(None)
        try:
            while True:
                chunk = resp.read1(65536)
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
        except OSError:
            pass
        finally:
            conn.close()

PAGE = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>signalbox watch</title>
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
.run-meta { color:var(--dim); font-size:11px; margin-top:2px; }
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
.badge { font-size:11px; padding:2px 8px; border-radius:10px; border:1px solid var(--line); color:var(--dim); }
.badge.live { color:var(--green); border-color:var(--green); }
.badge.offline { color:#484f58; }
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
<h1>signalbox watch</h1>
<div class="meta" id="meta">connecting…</div>
<div class="panel" style="margin-top:16px">
  <h2>Merged live events</h2>
  <div class="badges" id="badges"></div>
  <div id="feed"></div>
</div>
<div id="runs"></div>
<script>
// Streams are discovered server-side from the harness TOMLs and delivered
// via /status — the page assumes no port numbers. /status already resolves a
// reused port to its owning live run, so at most one stream per port arrives
// and a changed label means the port genuinely changed hands. Each SSE
// response repeats the owner it resolved at connect time; attach() freezes
// that into a per-connection snapshot and every event from that connection
// is labeled through the snapshot alone. The mutable STREAMS entries feed
// only the badges: a /status poll (or a reconnect) may retarget a badge to
// the port's new owner while buffered events from the old connection are
// still being parsed, and those must keep the identity of the connection
// they actually arrived on — run labels and promote state both.
const STREAMS = [];
const PHASES = ["plan","implement","review","promote"];
const promoteStates = {};
const $ = id => document.getElementById(id);

function adoptIdentity(stream, run, name) {
  if (run) stream.run = run;
  if (name) stream.name = name;
  const b = $("badge-" + stream.port);
  if (b) b.textContent = stream.run + "/" + stream.name + " :" + stream.port;
}

function ensureStreams(list) {
  for (const s of list || []) {
    const existing = STREAMS.find(x => x.port === s.port);
    if (existing) {
      adoptIdentity(existing, s.run, s.name);
      continue;
    }
    const stream = Object.assign({}, s, {cls: "c" + (STREAMS.length % 5)});
    STREAMS.push(stream);
    const b = document.createElement("span");
    b.className = "badge"; b.id = "badge-" + stream.port;
    b.textContent = stream.run + "/" + stream.name + " :" + stream.port;
    $("badges").appendChild(b);
    attach(stream);
  }
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
  out.promote = promoteStates[run.slug] || "pending";
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
    return "<tr><td class='" + (x.exists ? "" : "miss") + "'>" + esc(x.file) + extra + "</td>" +
      "<td class='age'>" + (x.exists ? age(now, x.mtime) : "—") + "</td>" +
      "<td class='size'>" + (x.exists ? x.size + "b" : "") + "</td></tr>";
  }).join("");
}

function logRows(run, now) {
  return run.logs.map(l =>
    "<tr><td>" + esc(l.file) + "</td><td class='age'>" + age(now, l.mtime) +
    "</td><td class='size'>" + l.size + "b</td></tr>").join("");
}

function renderRun(run, now) {
  const states = derive(run);
  const launch = run.launch || {};
  const feature = run.feature || "feature unknown";
  const issue = run.issue === null || run.issue === undefined ? "issue unknown" : "issue #" + run.issue;
  const pid = launch.pid === null || launch.pid === undefined ? "pid unknown" : "pid " + launch.pid;
  const phase = launch.phase ? " · launch phase " + esc(launch.phase) : "";
  const started = launch.started ? " · started " + esc(launch.started) : "";
  const rail = PHASES.map(p =>
    '<div class="phase ' + states[p] + '"><div class="name">' + p +
    '</div><div class="st">' + states[p] + "</div></div>").join("");
  return '<section class="run">' +
    '<div class="run-head">' + esc(feature) + " · " + esc(issue) + " · " +
      esc(run.slug) + " · " + esc(pid) + " " + esc(run.pid_state) + "</div>" +
    '<div class="run-meta">' + esc(run.streams.length) + " streams" + phase + started + "</div>" +
    '<div class="rail">' + rail + "</div>" +
    '<div class="cols"><div class="panel"><h2>Disk artifacts (the terminals that count)</h2>' +
      '<table>' + artifactRows(run, now) + "</table></div>" +
    '<div class="panel"><h2>Engine logs (buffered — sizes grow on flush)</h2>' +
      '<table>' + logRows(run, now) + "</table></div></div></section>";
}

async function poll() {
  try {
    const s = await (await fetch("/status")).json();
    const streams = s.runs.flatMap(run => run.streams || []);
    ensureStreams(streams);
    $("meta").textContent = s.harness + " · " + s.runs.length + " runs · " +
      new Date(s.now * 1000).toLocaleTimeString();
    $("runs").innerHTML = s.runs.map(run => renderRun(run, s.now)).join("");
  } catch (e) {
    $("meta").textContent = "status poll failed: " + e;
  }
  setTimeout(poll, 4000);
}

function badge(port, cls) {
  const b = $("badge-" + port);
  b.className = "badge " + cls;
}

// owner is the frozen per-connection identity from attach(), never a live
// STREAMS entry — reading mutable stream.run here is how a port handoff
// smears one run's events and promote state onto another.
function addEvent(owner, topic, dataText) {
  let obj = null;
  try { obj = JSON.parse(dataText); } catch (e) {}
  const t = topic || (obj && (obj.message_type || obj.type || obj.topic)) || "message";
  if (t.startsWith("system.") ) {
    // engine heartbeat: reflect in badge title, keep the feed for real events
    badge(owner.port, "live");
    return;
  }
  const pl = obj && obj.payload !== undefined ? obj.payload : obj;
  if (t === "phase.request" && pl && pl.phase === "promote") promoteStates[owner.run] = "active";
  if (t === "pipeline.complete") promoteStates[owner.run] = pl && pl.parked ? "parked" : "done";
  if (t === "pipeline.halted" && pl && pl.phase === "promote") promoteStates[owner.run] = "failed";
  const div = document.createElement("div");
  div.className = "ev " + owner.cls + (t.includes("error") || t.includes("escalated") || t.includes("halted") ? " err" : "");
  // sse-sink envelope: {id, type, source, timestamp, payload}
  const body = obj && obj.payload !== undefined ? JSON.stringify(obj.payload, null, 1)
             : obj ? JSON.stringify(obj, null, 1) : dataText;
  const when = obj && obj.timestamp ? new Date(obj.timestamp) : new Date();
  const src = obj && obj.source ? " · " + obj.source : "";
  const short = body.length > 700;
  div.innerHTML = '<div class="hd">' + when.toLocaleTimeString() +
    ' · <span class="event-stream"></span>' + src + ' · <span class="topic"></span></div>' +
    (short ? '<details><summary>' + body.length + ' chars</summary><pre></pre></details>'
           : '<pre></pre>');
  div.querySelector(".event-stream").textContent = owner.run + " · " + owner.name;
  div.querySelector(".topic").textContent = t;
  div.querySelector("pre").textContent = body;
  const feed = $("feed");
  feed.prepend(div);
  while (feed.children.length > 300) feed.lastChild.remove();
}

async function attach(stream) {
  while (true) {
    try {
      badge(stream.port, "connecting");
      const r = await fetch("/stream/" + stream.port + "/events");
      if (!r.ok) throw new Error("offline");
      // Freeze the owner the proxy actually connected to before reading a
      // single event: on a fast handoff this connection belongs to the new
      // run while /status still reports the old one. The snapshot is const
      // for the life of THIS response body — later polls and reconnects may
      // retarget the shared stream entry (badges), but every event below is
      // labeled with the identity of the connection it arrived on.
      const owner = {
        port: stream.port,
        cls: stream.cls,
        run: r.headers.get("X-Signalbox-Run") || stream.run,
        name: r.headers.get("X-Signalbox-Stream") || stream.name,
      };
      adoptIdentity(stream, owner.run, owner.name);
      badge(stream.port, "live");
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
          if (data.length) addEvent(owner, ev, data.join("\n"));
        }
      }
    } catch (e) { /* engine not running or stream dropped */ }
    badge(stream.port, "offline");
    await new Promise(res => setTimeout(res, 3000));
  }
}

poll();
</script>
</body>
</html>
"""

try:
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
except OSError as e:
    if e.errno != errno.EADDRINUSE:
        raise
    if MODE == "strict":
        print(f"WATCH_PORT={PORT} is already in use", file=sys.stderr)
        sys.exit(65)
    # Default port busy (another repo's dashboard?) — take an ephemeral one.
    srv = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
srv.daemon_threads = True
ports = ", ".join(
    f"{stream['run']}/{stream['name']}:{stream['port']}"
    for run in discover_runs()
    for stream in run["streams"]
) or "none found"
print(f"signalbox watch: http://localhost:{srv.server_address[1]}")
print(f"streams: {ports}")
srv.serve_forever()
PYEOF
