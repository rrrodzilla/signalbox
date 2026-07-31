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
CONFIG="${SIGNALBOX_CONFIG:-$ROOT/emergent.toml}"
LOG_DIR="${SIGNALBOX_LOG_DIR:-$ROOT/.harness}"
EVENT_STORE="${SIGNALBOX_EVENT_STORE:-${XDG_DATA_HOME:-$HOME/.local/share}/emergent/signalbox/events.db}"
ENGINE_LOG="$LOG_DIR/engine.log"
DASHBOARD_LOG="$LOG_DIR/dashboard.log"
DASHBOARD_PIDFILE="$LOG_DIR/dashboard.pid"
FORWARD_LOG="$LOG_DIR/forward.log"
FORWARD_PIDFILE="$LOG_DIR/forward.pid"
FORWARD_CHILD_PIDFILE="$LOG_DIR/forward.child.pid"
FORWARD_READYFILE="$LOG_DIR/forward.ready"
FORWARD_OWNERSHIP_FILE="$LOG_DIR/forward.owner"
FORWARD_SUPERVISED_CHILD=""

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

  local ceiling_message ipc_config ipc_dir ipc_quoted
  if ! ceiling_message="$(python3 "$ROOT/src/signalbox/ceiling.py" "$CONFIG" 2>&1)"; then
    if [[ "$ceiling_message" != "declared primitive connections ("* ]]; then
      fail "connection ceiling check failed: $ceiling_message"
    fi
    # refusal_message ends with the absolute, resolved path selected by the
    # module. Reuse it so the diagnosis and its repair cannot diverge.
    ipc_config="${ceiling_message##* in }"
    ipc_dir="$(dirname "$ipc_config")"
    printf -v ipc_quoted '%q' "$ipc_config"
    fail "$ceiling_message
  repair with: mkdir -p \"$ipc_dir\" && touch $ipc_quoted && awk 'BEGIN { in_limits=0; found_limits=0; set_value=0 } /^\\[limits\\][[:space:]]*$/ { if (in_limits && !set_value) print \"max_connections = 1024\"; in_limits=1; found_limits=1; print; next } /^\\[/ { if (in_limits && !set_value) { print \"max_connections = 1024\"; set_value=1 } in_limits=0 } in_limits && /^[[:space:]]*max_connections[[:space:]]*=/ { print \"max_connections = 1024\"; set_value=1; next } { print } END { if (!found_limits) { if (NR) print \"\"; print \"[limits]\"; print \"max_connections = 1024\" } else if (in_limits && !set_value) print \"max_connections = 1024\" }' $ipc_quoted > $ipc_quoted.tmp && mv $ipc_quoted.tmp $ipc_quoted"
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

# Snapshot the whole primitive tree while the engine is still its root. Once
# SIGTERM makes the engine exit, its direct children are reparented and neither
# their old parent nor deeper model runners can be reconstructed safely. Match
# numeric parent pids only: command-line patterns can match the shell issuing
# the kill and take down the harness itself.
engine_descendant_pids() {
  local engines="$1"
  ps -eo pid=,ppid= | awk -v roots="$engines" -v self="$$" '
    BEGIN {
      count = split(roots, root, /[[:space:]]+/)
      for (i = 1; i <= count; i++) if (root[i] != "") found[root[i]] = 1
    }
    { pid[NR] = $1; ppid[NR] = $2; parent[$1] = $2 }
    END {
      value = self
      while (value != "" && !protected[value]) {
        protected[value] = 1
        value = parent[value]
      }
      do {
        changed = 0
        for (i = 1; i <= NR; i++)
          if (found[ppid[i]] && !found[pid[i]]) {
            found[pid[i]] = 1
            descendant[pid[i]] = 1
            changed = 1
          }
      } while (changed)
      for (value in descendant) if (!protected[value]) print value
    }
  ' || true
}

live_pids() {
  local pid
  while IFS= read -r pid; do
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && printf '%s\n' "$pid"
  done <<<"$1"
  return 0
}

# A retained worktree is evidence, not liveness: halted runs deliberately keep
# theirs. A run is live only when its newest launch has no later terminal.
in_flight_run() {
  [[ -f "$EVENT_STORE" ]] || return 0
  python3 - "$EVENT_STORE" <<'PY' 2>/dev/null || true
import sqlite3
import sys
from pathlib import Path

path = sys.argv[1]
uri = Path(path).resolve().as_uri() + "?mode=ro"
with sqlite3.connect(uri, uri=True) as connection:
    row = connection.execute(
        """
        WITH requested AS (
          SELECT json_extract(payload_json, '$.run_id') AS run_id, MAX(timestamp_ms) AS requested_at
          FROM events
          WHERE message_type = 'run.requested'
          GROUP BY json_extract(payload_json, '$.run_id')
        )
        SELECT requested.run_id
        FROM requested
        WHERE requested.run_id IS NOT NULL
          AND NOT EXISTS (
            SELECT 1 FROM events terminal
            WHERE terminal.message_type IN ('run.completed', 'run.halted')
              AND json_extract(terminal.payload_json, '$.run_id') = requested.run_id
              AND terminal.timestamp_ms >= requested.requested_at
          )
        ORDER BY requested.requested_at DESC
        LIMIT 1
        """
    ).fetchone()
if row:
    print(row[0])
PY
}

guard_down() {
  local command="$1"
  shift
  local force=0
  while (($#)); do
    case "$1" in
      --force) force=1 ;;
      *) fail "usage: $0 $command [--force]" ;;
    esac
    shift
  done
  ((force)) && return 0
  [[ -n "$(engine_pids)" ]] || return 0
  local run_id=""
  run_id="$(in_flight_run)"
  [[ -z "$run_id" ]] \
    || fail "run $run_id is in flight; stop it anyway with: $0 $command --force"
}

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

start_engine() {
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

up() {
  preflight
  start_engine
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
  local pids descendants=""
  pids="$(engine_pids)"
  if [[ -z "$pids" ]]; then
    say "no engine running"
  else
    descendants="$(engine_descendant_pids "$pids")"
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
    local survivors=""
    survivors="$(live_pids "$descendants")"
    if [[ -n "$survivors" ]]; then
      say "stopping orphaned engine processes: $survivors"
      xargs -r kill -TERM <<<"$survivors" || true
      deadline=$((SECONDS + 20))
      while [[ -n "$(live_pids "$descendants")" ]]; do
        if ((SECONDS >= deadline)); then
          say "  orphaned processes did not drain in 20s, forcing"
          xargs -r kill -9 <<<"$(live_pids "$descendants")" || true
          break
        fi
        sleep 1
      done
    fi
  fi
  # The viewer holds no subscription and flushes nothing, but leaving it up means
  # `restart` silently keeps serving the package it started with.
  dashboard_down
  say "engine stopped"
}

status() {
  local pids
  pids="$(engine_pids)"
  if [[ -z "$pids" ]]; then
    say "vault:     unavailable (engine down; no captured environment)"
  else
    local pid environment entry captured first_vault="" readable_count=0
    local captured_count=0 values_disagree=0
    local -a vault_pids=() vault_values=()
    while IFS= read -r pid; do
      [[ -n "$pid" ]] || continue
      if [[ ! -r "/proc/$pid/environ" ]] \
        || ! environment="$(tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null)"; then
        vault_pids+=("$pid")
        vault_values+=("__SIGNALBOX_UNREADABLE__")
        continue
      fi
      readable_count=$((readable_count + 1))
      captured=""
      while IFS= read -r entry; do
        case "$entry" in
          SIGNALBOX_VAULT=*) captured="${entry#SIGNALBOX_VAULT=}"; break ;;
        esac
      done <<<"$environment"
      vault_pids+=("$pid")
      vault_values+=("$captured")
      if ((captured_count == 0)); then
        first_vault="$captured"
      elif [[ "$captured" != "$first_vault" ]]; then
        values_disagree=1
      fi
      captured_count=$((captured_count + 1))
    done <<<"$pids"

    if ((values_disagree)); then
      say "vault:     divergent engine environments"
    fi
    local index value outcome
    for index in "${!vault_pids[@]}"; do
      pid="${vault_pids[$index]}"
      value="${vault_values[$index]}"
      if [[ "$value" == "__SIGNALBOX_UNREADABLE__" ]]; then
        say "vault[$pid]: unavailable (/proc/$pid/environ absent or unreadable)"
        continue
      fi
      if [[ -z "$value" ]]; then
        outcome="notes fail: SIGNALBOX_VAULT is unset"
      elif [[ "$value" != /* ]]; then
        outcome="notes fail: vault is not an absolute path"
      elif [[ ! -d "$value" ]]; then
        outcome="notes fail: vault directory does not exist"
      else
        outcome="notes enabled"
      fi
      if ((${#vault_pids[@]} == 1)); then
        say "vault:     ${value:-<unset>} (engine pid $pid; $outcome)"
      else
        say "vault[$pid]: ${value:-<unset>} ($outcome)"
      fi
      if [[ "${SIGNALBOX_VAULT:-}" != "$value" ]]; then
        say "  invoking shell differs: ${SIGNALBOX_VAULT:-<unset>}"
      fi
    done
    if ((readable_count == 0)); then
      say "  no engine vault could be read at report time"
    fi
  fi
  if [[ -n "$pids" ]]; then
    local declared live engine_pid
    if declared="$(python3 - "$CONFIG" 2>/dev/null <<'PY'
import sys
import tomllib

with open(sys.argv[1], "rb") as config_file:
    config = tomllib.load(config_file)
print(sum(len(config.get(section, ())) for section in ("sources", "handlers", "sinks")))
PY
)"; then
      :
    else
      declared=""
    fi
    engine_pid="$(head -n 1 <<<"$pids")"
    live="$({ pgrep -P "$engine_pid" 2>/dev/null || true; } | wc -l)"
    live="${live//[[:space:]]/}"
    if [[ -z "$declared" ]]; then
      say "engine:    DEGRADED (pid $(tr '\n' ' ' <<<"$pids"); declared primitive count unavailable from $CONFIG)"
    elif [[ "$live" == "$declared" ]]; then
      say "engine:    up (pid $(tr '\n' ' ' <<<"$pids"); primitives $live/$declared)"
    else
      say "engine:    DEGRADED (pid $(tr '\n' ' ' <<<"$pids"); primitives $live/$declared live)"
    fi
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
    if [[ -f "$FORWARD_READYFILE" ]]; then
      say "forwarder: up (pid $fpid, $(cat "$LOG_DIR/forward.repo" 2>/dev/null || echo unknown))"
    else
      say "FORWARDER FAILURE: supervisor up but tunnel is not connected — inspect retries with: tail -f $FORWARD_LOG"
    fi
  else
    say "FORWARDER FAILURE: down — restore it with: $0 forward <owner/name>"
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

process_start_time() {
  local pid="$1" raw="" rest=""
  local -a fields=()
  IFS= read -r raw 2>/dev/null <"/proc/$pid/stat" || true
  [[ -n "$raw" && "$raw" == *") "* ]] || return 0
  # /proc comm may contain spaces and close parens, so field counting starts
  # only after its final `) `. Without readable procfs ownership cannot be
  # proven; stops then leave an orphan for the existing HTTP 422 repair path.
  rest="${raw##*) }"
  read -r -a fields <<<"$rest" 2>/dev/null || true
  printf '%s' "${fields[19]:-}"
}

forward_owns_hook() {
  local pid="$1" rec_pid="" rec_start="" rec_dir=""
  local current_start="" current_dir=""
  [[ -n "$pid" ]] || return 1
  read -r rec_pid rec_start rec_dir 2>/dev/null <"$FORWARD_OWNERSHIP_FILE" || true
  current_start="$(process_start_time "$pid")"
  current_dir="$(cd "$LOG_DIR" 2>/dev/null && pwd -P)" || true
  [[ -n "$rec_pid" && "$rec_pid" == "$pid" \
    && -n "$rec_start" && "$rec_start" == "$current_start" \
    && -n "$rec_dir" && "$rec_dir" == "$current_dir" ]]
}

forward_supervise() {
  local repo="$1"
  local backoff=1
  local stopping=0
  local repaired_stale_hook=0
  local attempt_log="$LOG_DIR/forward.attempt.log"
  FORWARD_SUPERVISED_CHILD=""

  stop_forward_child() {
    stopping=1
    if [[ -n "$FORWARD_SUPERVISED_CHILD" ]]; then
      kill -TERM "$FORWARD_SUPERVISED_CHILD" 2>/dev/null || true
      wait "$FORWARD_SUPERVISED_CHILD" 2>/dev/null || true
    fi
  }
  trap stop_forward_child TERM INT EXIT

  while ((stopping == 0)); do
    rm -f "$FORWARD_READYFILE"
    : >"$attempt_log"
    printf '[%s] starting webhook forwarder for %s\n' "$(date -Is)" "$repo"
    gh webhook forward \
      --repo="$repo" \
      --events=check_suite \
      --url="http://127.0.0.1:$GITHUB_PORT/github" \
      >"$attempt_log" 2>&1 &
    FORWARD_SUPERVISED_CHILD="$!"
    printf '%s' "$FORWARD_SUPERVISED_CHILD" >"$FORWARD_CHILD_PIDFILE"
    sleep 1
    if kill -0 "$FORWARD_SUPERVISED_CHILD" 2>/dev/null; then
      : >"$FORWARD_READYFILE"
      local supervisor_start="" supervisor_dir=""
      supervisor_start="$(process_start_time "$$")"
      supervisor_dir="$(cd "$LOG_DIR" 2>/dev/null && pwd -P)" || true
      if [[ -n "$supervisor_start" && -n "$supervisor_dir" ]]; then
        printf '%s %s %s\n' "$$" "$supervisor_start" "$supervisor_dir" \
          >"$FORWARD_OWNERSHIP_FILE"
      fi
      printf '[%s] webhook forwarder is running\n' "$(date -Is)"
    fi
    wait "$FORWARD_SUPERVISED_CHILD" 2>/dev/null || true
    FORWARD_SUPERVISED_CHILD=""
    cat "$attempt_log"
    rm -f "$FORWARD_CHILD_PIDFILE" "$FORWARD_READYFILE"
    ((stopping == 0)) || break

    if grep -Fq 'HTTP 422' "$attempt_log" \
      && grep -Fq 'Hook already exists on this repository' "$attempt_log"; then
      if ((repaired_stale_hook == 0)); then
        repaired_stale_hook=1
        printf '[%s] stale webhook refused the forwarder; purging it and retrying once\n' "$(date -Is)"
        forward_purge_hooks
        continue
      fi
      printf '[%s] terminal webhook forwarder failure: stale hook remains after repair\n' "$(date -Is)"
      rm -f "$attempt_log"
      return 1
    fi

    printf '[%s] webhook forwarder exited; restarting in %ss\n' "$(date -Is)" "$backoff"
    sleep "$backoff" &
    FORWARD_SUPERVISED_CHILD="$!"
    wait "$FORWARD_SUPERVISED_CHILD" 2>/dev/null || true
    FORWARD_SUPERVISED_CHILD=""
    if ((backoff < 30)); then
      backoff=$((backoff * 2))
      ((backoff > 30)) && backoff=30
    fi
  done
  rm -f "$attempt_log"
}

forward_purge_hooks() {
  local repo=""
  repo="$(cat "$LOG_DIR/forward.repo" 2>/dev/null || true)"
  [[ -n "$repo" ]] || return 0

  local hook_id
  while IFS= read -r hook_id; do
    [[ -n "$hook_id" ]] || continue
    gh api --method DELETE "repos/$repo/hooks/$hook_id" >/dev/null 2>&1 || true
  done < <(
    gh api --paginate "repos/$repo/hooks" \
      --jq '.[] | select((.config.url // "") | contains("webhook-forwarder.github.com")) | .id' \
      2>/dev/null || true
  )
  return 0
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
  rm -f "$FORWARD_READYFILE" "$FORWARD_OWNERSHIP_FILE"
  : >"$FORWARD_LOG"
  say "forwarding $repo check suites to http://127.0.0.1:$GITHUB_PORT/github"
  nohup "$0" _forward-supervise "$repo" >"$FORWARD_LOG" 2>&1 &
  printf '%s' "$!" >"$FORWARD_PIDFILE"

  local deadline=$((SECONDS + 3))
  until [[ -f "$FORWARD_READYFILE" ]] \
    || grep -q 'webhook forwarder exited' "$FORWARD_LOG" 2>/dev/null; do
    ((SECONDS < deadline)) || break
    sleep 0.1
  done
  if [[ -z "$(forward_pid || true)" ]]; then
    say "  forwarder exited immediately:"
    sed 's/^/    /' "$FORWARD_LOG" >&2
    fail "webhook forwarding did not start"
  fi
  if [[ -f "$FORWARD_READYFILE" ]]; then
    say "  forwarder up (pid $(forward_pid))"
  else
    say "  forwarder supervisor up, but the tunnel has not connected; retrying with capped backoff (see $FORWARD_LOG)"
  fi
}

forward_down() {
  local pid owns_hook=0 repo=""
  pid="$(forward_pid || true)"
  if forward_owns_hook "$pid"; then
    owns_hook=1
  fi
  if [[ -z "$pid" ]]; then
    say "no forwarder running"
  else
    say "stopping forwarder: $pid"
    kill -TERM "$pid" 2>/dev/null || true
    local deadline=$((SECONDS + 10))
    while kill -0 "$pid" 2>/dev/null; do
      ((SECONDS < deadline)) || { kill -9 "$pid" 2>/dev/null || true; break; }
      sleep 1
    done
  fi
  local child=""
  [[ -f "$FORWARD_CHILD_PIDFILE" ]] && child="$(cat "$FORWARD_CHILD_PIDFILE" 2>/dev/null || true)"
  if [[ -n "$child" ]] && kill -0 "$child" 2>/dev/null; then
    kill -TERM "$child" 2>/dev/null || true
  fi
  if ((owns_hook)); then
    # A licensed 422 repair can replace this hook while its supervisor remains
    # live; that residual race is safer than every unrelated stop purging it.
    forward_purge_hooks
  else
    repo="$(cat "$LOG_DIR/forward.repo" 2>/dev/null || true)"
    if [[ -n "$repo" ]]; then
      say "hook ownership not proven for $repo; a forwarder hook may remain; recover with: $0 forward $repo"
    fi
  fi
  rm -f "$FORWARD_PIDFILE" "$FORWARD_CHILD_PIDFILE" "$FORWARD_READYFILE" \
    "$FORWARD_OWNERSHIP_FILE"
}

# ── launch ───────────────────────────────────────────────────────────────────
# A thin pass-through to `signalbox launch`, which POSTs one run.requested to
# the control endpoint. The engine decides everything after that.

launch() {
  (($# >= 1)) || fail "usage: $0 launch <issue> [--repo owner/name] [--repo-path DIR] [--no-forwarder] [--run-id ID] ..."
  [[ -n "$(engine_pids)" ]] || fail "no engine running; start one with: $0 up"
  port_held "$CONTROL_PORT" || fail "control endpoint is not listening on $CONTROL_PORT"
  local promote_capable=0
  local no_forwarder=0
  local repo=""
  local repo_path="$PWD"
  local previous=""
  local arg
  local -a launch_args=()
  for arg in "$@"; do
    # #105: this harness-only escape hatch must not reach signalbox argparse.
    if [[ "$arg" == "--no-forwarder" ]]; then
      no_forwarder=1
      continue
    fi
    launch_args+=("$arg")
    if [[ "$previous" == "--repo" ]]; then
      repo="$arg"
      previous=""
      continue
    fi
    if [[ "$previous" == "--repo-path" ]]; then
      repo_path="$arg"
      previous=""
      continue
    fi
    case "$arg" in
      --repo=*) repo="${arg#--repo=}" ;;
      --repo) previous="--repo" ;;
      --repo-path=*) repo_path="${arg#--repo-path=}" ;;
      --repo-path) previous="--repo-path" ;;
    esac
  done
  local repo_root=""
  repo_root="$(git -C "$repo_path" rev-parse --show-toplevel 2>/dev/null || true)"
  local exact_repo_path=""
  exact_repo_path="$(cd "$repo_path" 2>/dev/null && pwd -P || true)"
  if [[ -n "$repo" ]]; then
    local workflow_count=""
    # #105: an explicit remote is the launch target when both target forms are
    # present. An unavailable API leaves workflow state unknown, which cannot
    # escalate the missing-forwarder warning into a refusal.
    workflow_count="$(gh api "repos/$repo/actions/workflows" \
      --jq '.total_count // 0' 2>/dev/null || true)"
    if [[ "$workflow_count" =~ ^[1-9][0-9]*$ ]]; then
      promote_capable=1
    fi
  elif [[ -n "$repo_root" && "$repo_root" == "$exact_repo_path" ]] \
    && git -C "$repo_root" remote get-url origin >/dev/null 2>&1; then
    # #105: a local remote is resolvable only when the exact checkout also has
    # a workflow that can create the check suite promote waits for.
    if find "$repo_root/.github/workflows" -maxdepth 1 -type f \
      \( -name '*.yml' -o -name '*.yaml' \) -print -quit 2>/dev/null \
      | grep -q .; then
      promote_capable=1
    fi
  fi
  if [[ -z "$(forward_pid || true)" ]]; then
    if ((promote_capable && ! no_forwarder)); then
      # #105: expose the classifier result before refusal.
      say "forwarder decision: refuse (resolvable promote path; no forwarder)"
      fail "webhook forwarder is down; restore it with: $0 forward <owner/name>"
    fi
    # #105: no promote path or the explicit override takes the warning branch.
    say "forwarder decision: warn (promote path unresolved or --no-forwarder)"
    say "  warning: webhook forwarder is down; continuing because this run has no resolvable promote path"
  fi
  signalbox launch "${launch_args[@]}"
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
    local repo="${BASH_REMATCH[1]}"
    forward_up "$repo"
    launch "$issue" --repo "$repo" --repo-path "$ROOT" --run-id "sb-$issue" "$@"
  else
    say "  no github origin; skipping webhook forwarding"
    launch "$issue" --repo-path "$ROOT" --run-id "sb-$issue" "$@"
  fi
}

case "${1:-}" in
  preflight) shift; preflight "$@" ;;
  install)   shift; install "$@" ;;
  up)        shift; up "$@" ;;
  down)      shift; guard_down down "$@"; forward_down; down ;;
  restart)   shift; guard_down restart "$@"; preflight; forward_down; down; start_engine ;;
  status)    shift; status "$@" ;;
  launch)    shift; launch "$@" ;;
  dogfood)   shift; dogfood "$@" ;;
  forward)   shift; forward_up "$@" ;;
  unforward) shift; forward_down ;;
  _forward-supervise) shift; forward_supervise "$@" ;;
  *)
    cat >&2 <<USAGE
usage: $0 <command>

  preflight  check tools, primitives, connection ceiling, gh auth, and signing key
  install    install the CLI editable from this checkout, then run the suite
  up         start the engine and the dashboard viewer
  down [--force]
             refuse an in-flight run by default; otherwise stop engine and viewer
  restart [--force]
             refuse an in-flight run by default; otherwise down, then up
  status     engine, forwarder, listening ports, and live run worktrees
  launch     signalbox launch <issue> [--no-forwarder] [...] against a running engine
  dogfood    launch against this checkout as run sb-<issue>
  forward    tunnel a repo's check_suite deliveries to the github port
  unforward  stop the tunnel
USAGE
    exit 64 ;;
esac
