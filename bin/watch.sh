#!/usr/bin/env bash
# Live watch dashboard for a signalbox harness.
#
#   bin/watch.sh [harness-dir]     (default: ./.claude/emergent)
#
# Serves http://localhost:${WATCH_PORT:-8099} with:
#   /                     the dashboard page
#   /status               JSON snapshot of the disk artifacts (the same
#                         terminals the phase runner and operator trust)
#   /stream/<port>/events proxy to that topology's watchtower sse-sink,
#                         so the browser needs no CORS and one origin
#                         covers every engine (8100-8104)
#
# The artifact poll works even for engines started before the watchtower
# sinks existed; the SSE streams light up whenever an engine with a
# watchtower is running. Read-only: this never touches the harness.
set -euo pipefail

HARNESS="${1:-$(pwd)/.claude/emergent}"
PORT="${WATCH_PORT:-8099}"
[ -d "$HARNESS" ] || { echo "no harness at $HARNESS (pass the .claude/emergent dir)" >&2; exit 64; }
HARNESS="$(cd "$HARNESS" && pwd)"

echo "signalbox watch: http://localhost:$PORT"
echo "harness: $HARNESS"
exec python3 - "$HARNESS" "$PORT" <<'PYEOF'
import json, os, sys, time
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HARNESS = sys.argv[1]
PORT = int(sys.argv[2])

ARTIFACTS = [
    "plan.json",
    "state/run.json",
    "state/gate.json",
    "state/escalated.json",
    "state/pending.json",
    "results/CR.md",
    "state/pipeline-plan.stamp",
    "state/pipeline-implement.stamp",
    "state/pipeline-review.stamp",
]

STREAM_PORTS = {8100, 8101, 8102, 8103, 8104}

def artifact_info(rel):
    p = os.path.join(HARNESS, rel)
    info = {"file": rel, "exists": os.path.isfile(p)}
    if info["exists"]:
        st = os.stat(p)
        info["mtime"] = st.st_mtime
        info["size"] = st.st_size
        if rel.endswith(".json") and st.st_size < 262144:
            try:
                with open(p) as fh:
                    info["json"] = json.load(fh)
            except (OSError, ValueError):
                info["json"] = None
    return info

def status():
    logs = []
    logdir = os.path.join(HARNESS, "logs")
    if os.path.isdir(logdir):
        for n in sorted(os.listdir(logdir)):
            p = os.path.join(logdir, n)
            if os.path.isfile(p):
                st = os.stat(p)
                logs.append({"file": n, "mtime": st.st_mtime, "size": st.st_size})
    return {"now": time.time(), "harness": HARNESS,
            "artifacts": {a: artifact_info(a) for a in ARTIFACTS},
            "logs": logs}

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
            if port not in STREAM_PORTS:
                self._body(404, "text/plain", b"unknown stream port")
                return
            self.proxy_sse(port)
        else:
            self._body(404, "text/plain", b"not found")

    def proxy_sse(self, port):
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
h1 .feature { color:var(--blue); }
.meta { color:var(--dim); font-size:12px; margin-top:2px; }
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
.ev.s8100 { border-color:var(--blue); } .ev.s8100 .topic { color:var(--blue); }
.ev.s8101 { border-color:var(--purple); } .ev.s8101 .topic { color:var(--purple); }
.ev.s8102 { border-color:var(--amber); } .ev.s8102 .topic { color:var(--amber); }
.ev.s8103 { border-color:var(--green); } .ev.s8103 .topic { color:var(--green); }
.ev.s8104 { border-color:var(--dim); }
.ev.err { border-color:var(--red); } .ev.err .topic { color:var(--red); }
</style>
</head>
<body>
<h1>signalbox watch <span class="feature" id="feature"></span></h1>
<div class="meta" id="meta">connecting…</div>
<div class="rail" id="rail"></div>
<div class="cols">
  <div>
    <div class="panel">
      <h2>Disk artifacts (the terminals that count)</h2>
      <table id="artifacts"></table>
    </div>
    <div class="panel" style="margin-top:16px">
      <h2>Engine logs (buffered — sizes grow on flush)</h2>
      <table id="logs"></table>
    </div>
  </div>
  <div class="panel">
    <h2>Live events</h2>
    <div class="badges" id="badges"></div>
    <div id="feed"></div>
  </div>
</div>
<script>
const STREAMS = [
  {port:8100, name:"pipeline"},
  {port:8101, name:"plan"},
  {port:8102, name:"implement"},
  {port:8103, name:"review"},
  {port:8104, name:"init"},
];
const PHASES = ["plan","implement","review","promote"];
let promoteState = "pending";
const $ = id => document.getElementById(id);

STREAMS.forEach(s => {
  const b = document.createElement("span");
  b.className = "badge"; b.id = "badge-" + s.port; b.textContent = s.name;
  $("badges").appendChild(b);
});
PHASES.forEach(p => {
  const d = document.createElement("div");
  d.className = "phase pending"; d.id = "phase-" + p;
  d.innerHTML = '<div class="name">' + p + '</div><div class="st">pending</div>';
  $("rail").appendChild(d);
});

function age(now, m) {
  const s = Math.max(0, Math.round(now - m));
  if (s < 60) return s + "s";
  if (s < 3600) return Math.round(s/60) + "m";
  return (s/3600).toFixed(1) + "h";
}
function setPhase(p, st) {
  const d = $("phase-" + p);
  d.className = "phase " + st;
  d.querySelector(".st").textContent = st;
}

function derive(s) {
  const a = s.artifacts;
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
  out.promote = promoteState;
  const esc = a["state/escalated.json"];
  const stamps = PHASES.map(p => stamp(p)).filter(x => x && x.exists).map(x => x.mtime);
  if (esc.exists && esc.json && stamps.length && esc.mtime >= Math.max(...stamps)) {
    const p = esc.json.escalated_phase === "shard" ? "implement" : esc.json.escalated_phase;
    if (out[p]) out[p] = "escalated";
  }
  return out;
}

async function poll() {
  try {
    const s = await (await fetch("/status")).json();
    const a = s.artifacts, pj = a["plan.json"];
    if (pj.exists && pj.json)
      $("feature").textContent = pj.json.feature + " · issue #" + pj.json.issue;
    $("meta").textContent = s.harness + " · " + new Date(s.now * 1000).toLocaleTimeString();
    const st = derive(s);
    PHASES.forEach(p => setPhase(p, st[p]));
    $("artifacts").innerHTML = Object.values(a).map(x => {
      let extra = "";
      if (x.exists && x.json && x.json.verdict)
        extra = ' <span class="' + (x.json.verdict === "GREEN" ? "ok" : "bad") + '">' + x.json.verdict + "</span>";
      return "<tr><td class='" + (x.exists ? "" : "miss") + "'>" + x.file + extra + "</td>" +
        "<td class='age'>" + (x.exists ? age(s.now, x.mtime) : "—") + "</td>" +
        "<td class='size'>" + (x.exists ? x.size + "b" : "") + "</td></tr>";
    }).join("");
    $("logs").innerHTML = s.logs.map(l =>
      "<tr><td>" + l.file + "</td><td class='age'>" + age(s.now, l.mtime) +
      "</td><td class='size'>" + l.size + "b</td></tr>").join("");
  } catch (e) {
    $("meta").textContent = "status poll failed: " + e;
  }
  setTimeout(poll, 4000);
}

function badge(port, cls) {
  const b = $("badge-" + port);
  b.className = "badge " + cls;
}

function addEvent(stream, topic, dataText) {
  let obj = null;
  try { obj = JSON.parse(dataText); } catch (e) {}
  const t = topic || (obj && (obj.message_type || obj.type || obj.topic)) || "message";
  if (t.startsWith("system.") ) {
    // engine heartbeat: reflect in badge title, keep the feed for real events
    badge(stream.port, "live");
    return;
  }
  const pl = obj && obj.payload !== undefined ? obj.payload : obj;
  if (t === "phase.request" && pl && pl.phase === "promote") promoteState = "active";
  if (t === "pipeline.complete") promoteState = pl && pl.parked ? "parked" : "done";
  if (t === "pipeline.halted") { if (pl && pl.phase === "promote") promoteState = "failed"; }
  const div = document.createElement("div");
  div.className = "ev s" + stream.port + (t.includes("error") || t.includes("escalated") || t.includes("halted") ? " err" : "");
  // sse-sink envelope: {id, type, source, timestamp, payload}
  const body = obj && obj.payload !== undefined ? JSON.stringify(obj.payload, null, 1)
             : obj ? JSON.stringify(obj, null, 1) : dataText;
  const when = obj && obj.timestamp ? new Date(obj.timestamp) : new Date();
  const src = obj && obj.source ? " · " + obj.source : "";
  const short = body.length > 700;
  div.innerHTML = '<div class="hd">' + when.toLocaleTimeString() +
    ' · ' + stream.name + src + ' · <span class="topic"></span></div>' +
    (short ? '<details><summary>' + body.length + ' chars</summary><pre></pre></details>'
           : '<pre></pre>');
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
          if (data.length) addEvent(stream, ev, data.join("\n"));
        }
      }
    } catch (e) { /* engine not running or stream dropped */ }
    badge(stream.port, "offline");
    await new Promise(res => setTimeout(res, 3000));
  }
}

poll();
STREAMS.forEach(attach);
</script>
</body>
</html>
"""

srv = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
srv.daemon_threads = True
srv.serve_forever()
PYEOF
