#!/usr/bin/env bash
# Install and operate the machine-wide Signalbox sink systemd --user service.
#
# Invocation:
#   bin/sink-service.sh install|ensure|status|restart|stop|uninstall
#
# Subcommands:
#   install    atomically refresh the canonical service script and unit
#   ensure     install, enable/start (or restart a changed script), then probe
#   status     show systemd status and probe /healthz
#   restart    restart the unit
#   stop       cleanly stop the unit
#   uninstall  disable/stop and remove only the unit
#
# Configuration:
#   HOME                 owns ~/.local/share/signalbox and ~/.config/systemd
#   SIGNALBOX_SINK_PORT  port baked into the unit and probed (default: 8099)
#
# The configured port is written into the unit as an Environment= line, so the
# service, the health probe, and every forwarder that reads the same variable
# agree on one value; changing it rewrites the unit and restarts the service.
#
# Several repositories can install their own harness, but exactly one process
# may own that port. The unit therefore runs one canonical machine-level copy;
# the most recent harness installer wins by atomically replacing that copy.
#
# Exits 0 on success. `ensure` also exits 0 with a warning when systemctl or a
# user D-Bus session is unavailable (headless/CI). Operational failures and an
# out-of-range SIGNALBOX_SINK_PORT exit 1; a missing/unknown subcommand or
# extra argument exits 64.
set -euo pipefail

usage() {
    echo "usage: sink-service.sh install|ensure|status|restart|stop|uninstall" >&2
}

if [ "$#" -ne 1 ]; then
    usage
    exit 64
fi

COMMAND="$1"
case "$COMMAND" in
    install|ensure|status|restart|stop|uninstall) ;;
    *)
        usage
        exit 64
        ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="$SCRIPT_DIR/sink-serve.sh"
BIN_DIR="$HOME/.local/share/signalbox/bin"
INSTALLED_SCRIPT="$BIN_DIR/sink-serve.sh"
UNIT_DIR="$HOME/.config/systemd/user"
UNIT_FILE="$UNIT_DIR/signalbox-sink.service"
UNIT_NAME="signalbox-sink.service"
SINK_PORT="${SIGNALBOX_SINK_PORT:-8099}"
# The port is written verbatim into a systemd unit, so it is validated rather
# than trusted: only a plain decimal port may reach that file. `stop`,
# `restart`, and `uninstall` never read it, and must stay usable regardless.
case "$COMMAND" in
    install|ensure|status)
        if ! [[ "$SINK_PORT" =~ ^[1-9][0-9]{0,4}$ ]] \
            || [ "$SINK_PORT" -gt 65535 ]; then
            echo "error: SIGNALBOX_SINK_PORT must be an integer from 1 to 65535" \
                >&2
            exit 1
        fi
        ;;
esac
HEALTH_URL="http://127.0.0.1:$SINK_PORT/healthz"
SCRIPT_CHANGED=0
UNIT_CHANGED=0
TMP_SCRIPT=""
TMP_UNIT=""

cleanup() {
    if [ -n "$TMP_SCRIPT" ]; then
        rm -f "$TMP_SCRIPT"
    fi
    if [ -n "$TMP_UNIT" ]; then
        rm -f "$TMP_UNIT"
    fi
}
trap cleanup EXIT

write_unit() {
    # Restart=on-failure does not fight a clean `systemctl --user stop`.
    # Persisting that stop across later starts needs `systemctl --user mask`.
    # The port travels with the unit: without it the service would always bind
    # the 8099 default while probes and forwarders honoured the override.
    cat <<EOF
[Unit]
Description=Signalbox shared SSE sink (machine-wide instance dashboard)
After=default.target

[Service]
Type=simple
Environment=SIGNALBOX_SINK_PORT=$SINK_PORT
ExecStart=%h/.local/share/signalbox/bin/sink-serve.sh
Restart=on-failure
RestartSec=2

[Install]
WantedBy=default.target
EOF
}

install_files() {
    if [ ! -f "$SOURCE" ]; then
        echo "error: sink service source not found: $SOURCE" >&2
        return 1
    fi
    mkdir -p "$BIN_DIR" "$UNIT_DIR"

    if [ ! -f "$INSTALLED_SCRIPT" ] || ! cmp -s "$SOURCE" "$INSTALLED_SCRIPT"; then
        TMP_SCRIPT="$(mktemp "$BIN_DIR/.sink-serve.sh.tmp.XXXXXX")"
        cp "$SOURCE" "$TMP_SCRIPT"
        chmod +x "$TMP_SCRIPT"
        mv "$TMP_SCRIPT" "$INSTALLED_SCRIPT"
        TMP_SCRIPT=""
        SCRIPT_CHANGED=1
    elif [ ! -x "$INSTALLED_SCRIPT" ]; then
        chmod +x "$INSTALLED_SCRIPT"
    fi

    TMP_UNIT="$(mktemp "$UNIT_DIR/.signalbox-sink.service.tmp.XXXXXX")"
    write_unit >"$TMP_UNIT"
    if [ ! -f "$UNIT_FILE" ] || ! cmp -s "$TMP_UNIT" "$UNIT_FILE"; then
        mv "$TMP_UNIT" "$UNIT_FILE"
        TMP_UNIT=""
        UNIT_CHANGED=1
    else
        rm -f "$TMP_UNIT"
        TMP_UNIT=""
    fi
}

need_systemctl() {
    if ! command -v systemctl >/dev/null 2>&1; then
        echo "error: systemctl is required for '$COMMAND'" >&2
        return 1
    fi
}

health_probe() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsS --max-time 1 "$HEALTH_URL" >/dev/null 2>&1
        return
    fi
    python3 - "$HEALTH_URL" >/dev/null 2>&1 <<'PYEOF'
import sys
import urllib.request

with urllib.request.urlopen(sys.argv[1], timeout=1) as response:
    if response.status != 200:
        raise SystemExit(1)
PYEOF
}

ensure_service() {
    install_files
    if ! command -v systemctl >/dev/null 2>&1; then
        echo "warning: systemctl is unavailable; shared sink was installed but not started" >&2
        return 0
    fi
    if ! systemctl --user show-environment >/dev/null 2>&1; then
        echo "warning: no systemd user D-Bus session; shared sink was installed but not started" >&2
        return 0
    fi

    systemctl --user daemon-reload
    systemctl --user enable --now "$UNIT_NAME"
    # A rewritten unit needs the restart too: enable --now leaves an already
    # running service on its old port after the configured port changes.
    if [ "$SCRIPT_CHANGED" -eq 1 ] || [ "$UNIT_CHANGED" -eq 1 ]; then
        systemctl --user restart "$UNIT_NAME"
    fi

    for ATTEMPT in 1 2 3 4 5 6 7 8 9 10; do
        if health_probe; then
            echo "signalbox sink is healthy: $HEALTH_URL"
            return 0
        fi
        sleep 0.5
    done
    echo "error: signalbox sink did not become healthy within 5 seconds: $HEALTH_URL" >&2
    return 1
}

case "$COMMAND" in
    install)
        install_files
        need_systemctl
        systemctl --user daemon-reload
        ;;
    ensure)
        ensure_service
        ;;
    status)
        need_systemctl
        RESULT=0
        if ! systemctl --user status --no-pager "$UNIT_NAME"; then
            RESULT=1
        fi
        if health_probe; then
            echo "healthz: ok ($HEALTH_URL)"
        else
            echo "healthz: unavailable ($HEALTH_URL)" >&2
            RESULT=1
        fi
        exit "$RESULT"
        ;;
    restart)
        need_systemctl
        systemctl --user restart "$UNIT_NAME"
        ;;
    stop)
        need_systemctl
        systemctl --user stop "$UNIT_NAME"
        ;;
    uninstall)
        need_systemctl
        systemctl --user disable --now "$UNIT_NAME" 2>/dev/null || true
        rm -f "$UNIT_FILE"
        systemctl --user daemon-reload
        ;;
esac
