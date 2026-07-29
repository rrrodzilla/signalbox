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

CONTROL_PORT=8100
STREAM_PORT=8101
TOPOLOGY_PORT=8102
DASHBOARD_PORT=8103

say() { printf '%s\n' "$*"; }
fail() { printf 'harness: %s\n' "$*" >&2; exit 1; }

# ── preflight ────────────────────────────────────────────────────────────────
# Fail on a missing tool now rather than twenty minutes into a run, where the
# same absence surfaces as an agent that produced no verdict.

REQUIRED_PRIMITIVES=(exec-source exec-handler exec-sink stream-runner
                     http-source sse-sink topology-viewer)

preflight() {
  local missing=()
  for tool in emergent claude codex gh git jq python3 uv; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
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

  if ! port_held "$DASHBOARD_PORT"; then
    say "starting the dashboard viewer"
    nohup signalbox dashboard >"$DASHBOARD_LOG" 2>&1 &
    sleep 1
  fi

  status
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
  say "engine stopped"
}

status() {
  local pids
  pids="$(engine_pids)"
  if [[ -n "$pids" ]]; then
    say "engine:    up (pid $(tr '\n' ' ' <<<"$pids"))"
  else
    say "engine:    down"
  fi
  for entry in "control:$CONTROL_PORT" "stream:$STREAM_PORT" \
               "topology:$TOPOLOGY_PORT" "dashboard:$DASHBOARD_PORT"; do
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
  launch "$issue" --repo-path "$ROOT" --run-id "sb-$issue" "$@"
}

case "${1:-}" in
  preflight) shift; preflight "$@" ;;
  install)   shift; install "$@" ;;
  up)        shift; up "$@" ;;
  down)      shift; down "$@" ;;
  restart)   shift; down; up ;;
  status)    shift; status "$@" ;;
  launch)    shift; launch "$@" ;;
  dogfood)   shift; dogfood "$@" ;;
  *)
    cat >&2 <<USAGE
usage: $0 <command>

  preflight  check tools, primitives, gh auth, and the signing key
  install    install the CLI editable from this checkout, then run the suite
  up         start the engine and the dashboard viewer
  down       SIGTERM the engine so the event store flushes
  restart    down, then up
  status     engine, listening ports, and live run worktrees
  launch     signalbox launch <issue> [...] against a running engine
  dogfood    launch against this checkout as run sb-<issue>
USAGE
    exit 64 ;;
esac
