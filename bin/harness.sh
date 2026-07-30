#!/usr/bin/env bash
# The operator's side of signalbox: install the CLI, start the engine, launch a
# run, see what is up.
#
# This is not a pipeline runner. It knows nothing about plan, implement, review,
# or promote, and it must not learn: the order of a run lives in emergent.toml
# and nowhere else. Everything here is process lifecycle and preflight, the two
# jobs the topology genuinely cannot do for itself.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$ROOT/emergent.toml"
LOG_DIR="${SIGNALBOX_LOG_DIR:-$ROOT/.harness}"
ENGINE_LOG="$LOG_DIR/engine.log"
DASHBOARD_LOG="$LOG_DIR/dashboard.log"
DASHBOARD_PIDFILE="$LOG_DIR/dashboard.pid"
FORWARD_LOG="$LOG_DIR/forward.log"
FORWARD_PIDFILE="$LOG_DIR/forward.pid"

CONTROL_PORT=8100
STREAM_PORT=8101
TOPOLOGY_PORT=8102
DASHBOARD_PORT=8103
GITHUB_PORT=8104

# The repo whose deliveries the forwarder tunnels. Only set for a dogfood run or
# an explicit `forward`; a run against another repo passes its own.
FORWARD_REPO="${SIGNALBOX_FORWARD_REPO:-}"

say() { printf '%s\n' "$*"; }
fail() { printf 'harness: %s\n' "$*" >&2; exit 1; }

# ── preflight ────────────────────────────────────────────────────────────────
# Fail on a missing tool now rather than twenty minutes into a run, where the
# same absence surfaces as an agent that produced no verdict.

REQUIRED_PRIMITIVES=(exec-source exec-handler exec-sink http-source sse-sink
                     topology-viewer)

preflight() {
  local missing=()
  for tool in emergent claude codex gh git jq python3 uv; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  # #70: reject the operator shell before `up`; prepare-workspace separately
  # checks the environment captured by the engine when it started.
  [[ -n "${SIGNALBOX_VAULT:-}" && -d "$SIGNALBOX_VAULT" ]] \
    || missing+=("SIGNALBOX_VAULT (export SIGNALBOX_VAULT=/absolute/path/to/vault before '$0 up')")
  ((${#missing[@]} == 0)) || fail "missing tools: ${missing[*]}"

  local primitives_dir="$HOME/.local/share/emergent/primitives/bin"
  local absent=()
  for primitive in "${REQUIRED_PRIMITIVES[@]}"; do
    [[ -x "$primitives_dir/$primitive" ]] || absent+=("$primitive")
  done
  if ((${#absent[@]})); then
    fail "missing primitives: ${absent[*]}
  install them with: emergent marketplace install ${absent[*]}"
  fi

  gh auth status >/dev/null 2>&1 || say "  warning: gh is not authenticated; a run against a remote repo will stall at fetch-issue"
  git -C "$ROOT" config --get user.signingkey >/dev/null 2>&1 \
    || say "  warning: no git signing key configured; merge-stage commits with -S and will fail"

  say "preflight ok: $(emergent --version 2>/dev/null | head -1), $(codex --version 2>/dev/null | head -1)"
}

# ── install ──────────────────────────────────────────────────────────────────
# Editable on purpose. A wheel build is the one way to end up running a stale
# copy while the source reads correct, and that failure is invisible: a stale
# skill or act reports a verdict, just the wrong one.

install() {
  preflight
  say "installing the signalbox CLI from $ROOT (editable)"
  uv tool install --force --reinstall -e "$ROOT" >/dev/null
  local resolved
  resolved="$(command -v signalbox)" || fail "signalbox is not on PATH after install"
  say "  signalbox -> $resolved"
  signalbox paths | sed 's/^/  /'
  say "running the invariant suite"
  (cd "$ROOT" && uv run pytest -q)
}

# ── lifecycle ────────────────────────────────────────────────────────────────

engine_pids() { pgrep -x emergent 2>/dev/null || true; }

# The viewer is a separate process from the engine, so `down` has to name it or
# it survives every restart. One that outlived the reinstall was still running
# the uv *tool* snapshot of the package rather than this working tree.
#
# A pidfile rather than `pgrep -f 'signalbox dashboard'`: that pattern matches any
# process whose arguments merely contain the phrase, including the shell about to
# run the kill. It took down its own caller the first time it was used.
dashboard_pid() {
  [[ -f "$DASHBOARD_PIDFILE" ]] || return 1
  local pid
  pid="$(cat "$DASHBOARD_PIDFILE" 2>/dev/null)" || return 1
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && printf '%s' "$pid"
}

port_held() { fuser -n tcp "$1" >/dev/null 2>&1; }

up() {
  preflight
  if [[ -n "$(engine_pids)" ]]; then
    fail "an emergent engine is already running (pid $(engine_pids | tr '\n' ' '))
  stop it with: $0 down"
  fi
  mkdir -p "$LOG_DIR"

  say "starting the engine from $CONFIG"
  nohup emergent -c "$CONFIG" >"$ENGINE_LOG" 2>&1 &
  local deadline=$((SECONDS + 45))
  until port_held "$CONTROL_PORT"; do
    ((SECONDS < deadline)) || fail "control endpoint never came up; see $ENGINE_LOG"
    sleep 1
  done

  # Always replace it rather than reusing whatever holds the port. The viewer is
  # disposable by construction — no subscription, no state — so the only thing
  # reuse can preserve is a stale copy of the package.
  dashboard_down
  say "starting the dashboard viewer"
  nohup signalbox dashboard >"$DASHBOARD_LOG" 2>&1 &
  printf '%s' "$!" >"$DASHBOARD_PIDFILE"
  deadline=$((SECONDS + 10))
  until port_held "$DASHBOARD_PORT"; do
    ((SECONDS < deadline)) || fail "dashboard never came up; see $DASHBOARD_LOG"
    sleep 1
  done

  status
}

dashboard_down() {
  local pid
  pid="$(dashboard_pid || true)"
  if [[ -n "$pid" ]]; then
    say "stopping dashboard viewer: $pid"
    kill -TERM "$pid" 2>/dev/null || true
    local deadline=$((SECONDS + 10))
    while kill -0 "$pid" 2>/dev/null; do
      ((SECONDS < deadline)) || { kill -9 "$pid" 2>/dev/null || true; break; }
      sleep 1
    done
  fi
  rm -f "$DASHBOARD_PIDFILE"
}

down() {
  local pids
  pids="$(engine_pids)"
  if [[ -z "$pids" ]]; then
    say "no engine running"
  else
    say "stopping engine: $pids"
    # SIGTERM so the event store flushes; a killed engine loses the tail of the
    # trail, which is the only record a run has.
    xargs -r kill -TERM <<<"$pids"
    local deadline=$((SECONDS + 20))
    while [[ -n "$(engine_pids)" ]]; do
      if ((SECONDS >= deadline)); then
        say "  did not drain in 20s, forcing"
        xargs -r kill -9 <<<"$(engine_pids)"
        break
      fi
      sleep 1
    done
  fi
  # The viewer holds no subscription and flushes nothing, but leaving it up means
  # `restart` silently keeps serving the package it started with.
  dashboard_down
  say "engine stopped"
}

status() {
  # #70: this is the invoking shell's view. The engine may have been started
  # from another shell and prepare-workspace is authoritative for each run.
  say "vault:     ${SIGNALBOX_VAULT:-unset}"
  say "  caveat: live engine environment was captured at 'up' and may differ; prepare-workspace verifies each run"
  local pids
  pids="$(engine_pids)"
  if [[ -n "$pids" ]]; then
    say "engine:    up (pid $(tr '\n' ' ' <<<"$pids"))"
  else
    say "engine:    down"
  fi
  local dpid
  dpid="$(dashboard_pid || true)"
  if [[ -n "$dpid" ]]; then
    say "viewer:    up (pid $dpid)"
  else
    say "viewer:    down"
  fi
  local fpid
  fpid="$(forward_pid || true)"
  if [[ -n "$fpid" ]]; then
    say "forwarder: up (pid $fpid, $(cat "$LOG_DIR/forward.repo" 2>/dev/null || echo unknown))"
  else
    say "forwarder: down — a run will reach pr.opened and then wait for a delivery that cannot arrive"
  fi
  for entry in "control:$CONTROL_PORT" "stream:$STREAM_PORT" \
               "topology:$TOPOLOGY_PORT" "dashboard:$DASHBOARD_PORT" \
               "github:$GITHUB_PORT"; do
    local label="${entry%%:*}" port="${entry##*:}"
    if port_held "$port"; then
      printf '  %-10s %s\n' "$label" "http://127.0.0.1:$port"
    else
      printf '  %-10s (not listening)\n' "$label"
    fi
  done
  local worktrees="${SIGNALBOX_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/signalbox}/worktrees"
  if [[ -d "$worktrees" ]]; then
    say "worktrees: $(find "$worktrees" -maxdepth 1 -mindepth 1 -type d -printf '%f ' 2>/dev/null)"
  fi
}

# ── webhook forwarding ───────────────────────────────────────────────────────
# The promote path waits for GitHub to say a check suite concluded. GitHub cannot
# reach 127.0.0.1, so `gh webhook forward` opens the tunnel: it creates a
# temporary repo webhook, holds a websocket, and POSTs each delivery locally.
#
# This is a genuine operator concern rather than a topology one. The engine cannot
# start it — an engine primitive that opened a tunnel would be a primitive that
# reaches outside the topology — and a dead tunnel is invisible to the engine by
# construction, which is why `reap-prs` exists to give that silence a name.

forward_pid() {
  [[ -f "$FORWARD_PIDFILE" ]] || return 1
  local pid
  pid="$(cat "$FORWARD_PIDFILE" 2>/dev/null)" || return 1
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && printf '%s' "$pid"
}

forward_up() {
  local repo="${1:-$FORWARD_REPO}"
  [[ -n "$repo" ]] || fail "usage: $0 forward <owner/name>"

  gh extension list 2>/dev/null | grep -q 'cli/gh-webhook' \
    || fail "the webhook forwarder is not installed
  install it with: gh extension install cli/gh-webhook"

  if [[ -n "$(forward_pid || true)" ]]; then
    say "forwarder already running for $(cat "$LOG_DIR/forward.repo" 2>/dev/null || echo unknown) (pid $(forward_pid))"
    return 0
  fi

  mkdir -p "$LOG_DIR"
  printf '%s' "$repo" >"$LOG_DIR/forward.repo"
  say "forwarding $repo check suites to http://127.0.0.1:$GITHUB_PORT/github"
  nohup gh webhook forward \
    --repo="$repo" \
    --events=check_suite \
    --url="http://127.0.0.1:$GITHUB_PORT/github" \
    >"$FORWARD_LOG" 2>&1 &
  printf '%s' "$!" >"$FORWARD_PIDFILE"

  # It either establishes the websocket or it does not; a forwarder that failed
  # to authenticate looks exactly like one waiting for a delivery.
  sleep 3
  if [[ -z "$(forward_pid || true)" ]]; then
    say "  forwarder exited immediately:"
    sed 's/^/    /' "$FORWARD_LOG" >&2
    fail "webhook forwarding did not start"
  fi
  say "  forwarder up (pid $(forward_pid))"
}

forward_down() {
  local pid
  pid="$(forward_pid || true)"
  if [[ -z "$pid" ]]; then
    say "no forwarder running"
  else
    say "stopping forwarder: $pid"
    kill -TERM "$pid" 2>/dev/null || true
    sleep 1
  fi
  rm -f "$FORWARD_PIDFILE"
}

# ── launch ───────────────────────────────────────────────────────────────────
# A thin pass-through to `signalbox launch`, which POSTs one run.requested to
# the control endpoint. The engine decides everything after that.

launch() {
  (($# >= 1)) || fail "usage: $0 launch <issue> [--repo owner/name] [--repo-path DIR] [--run-id ID] ..."
  [[ -n "$(engine_pids)" ]] || fail "no engine running; start one with: $0 up"
  port_held "$CONTROL_PORT" || fail "control endpoint is not listening on $CONTROL_PORT"
  signalbox launch "$@"
}

# Dogfood: run signalbox against its own checkout. Split out so the repo path
# and run-id convention live in one place instead of in a shell history.
dogfood() {
  (($# >= 1)) || fail "usage: $0 dogfood <issue> [extra launch args...]"
  local issue="$1"; shift
  local branch
  branch="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)"
  say "dogfooding on $ROOT (branch $branch, base $(git -C "$ROOT" rev-parse --short HEAD))"

  # Without the tunnel the run reaches pr.opened and waits 40 minutes for a
  # reaper. Start it here rather than making the operator remember.
  local origin
  origin="$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)"
  if [[ "$origin" =~ github\.com[:/]([^/]+/[^/.]+) ]]; then
    forward_up "${BASH_REMATCH[1]}"
  else
    say "  no github origin; skipping webhook forwarding"
  fi

  launch "$issue" --repo-path "$ROOT" --run-id "sb-$issue" "$@"
}

case "${1:-}" in
  preflight) shift; preflight "$@" ;;
  install)   shift; install "$@" ;;
  up)        shift; up "$@" ;;
  down)      shift; forward_down; down "$@" ;;
  restart)   shift; forward_down; down; up ;;
  status)    shift; status "$@" ;;
  launch)    shift; launch "$@" ;;
  dogfood)   shift; dogfood "$@" ;;
  forward)   shift; forward_up "$@" ;;
  unforward) shift; forward_down ;;
  *)
    cat >&2 <<USAGE
usage: $0 <command>

  preflight  check tools, primitives, gh auth, and the signing key
  install    install the CLI editable from this checkout, then run the suite
  up         start the engine and the dashboard viewer
  down       SIGTERM the engine so the event store flushes, and stop the viewer
  restart    down, then up
  status     engine, forwarder, listening ports, and live run worktrees
  launch     signalbox launch <issue> [...] against a running engine
  dogfood    launch against this checkout as run sb-<issue>
  forward    tunnel a repo's check_suite deliveries to the github port
  unforward  stop the tunnel
USAGE
    exit 64 ;;
esac
