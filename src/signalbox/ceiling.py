"""Connection-ceiling arithmetic for the Signalbox topology.

This module deliberately has no package-local imports.  The harness invokes it
before Signalbox is installed, so it must also work as a standalone script.
"""

from __future__ import annotations

import os
import sys
import tomllib
from collections.abc import Mapping, Sequence
from pathlib import Path


ACTON_DEFAULT_MAX_CONNECTIONS = 100
INTENDED_MAX_CONNECTIONS = 1024


def declared_primitive_count(config_path: Path | str) -> int:
    """Return the number of IPC clients declared by an emergent config."""
    with Path(config_path).open("rb") as config_file:
        config = tomllib.load(config_file)
    return sum(len(config.get(section, ())) for section in ("sources", "handlers", "sinks"))


def acton_ipc_config_path(environ: Mapping[str, str] | None = None) -> Path:
    """Resolve acton's machine-global IPC config path from the environment."""
    env = os.environ if environ is None else environ
    if xdg_config_home := env.get("XDG_CONFIG_HOME"):
        config_home = Path(xdg_config_home).expanduser()
    elif home := env.get("HOME"):
        config_home = Path(home).expanduser() / ".config"
    else:
        config_home = Path.home() / ".config"
    return (config_home / "acton" / "ipc.toml").resolve()


def effective_connection_ceiling(config_path: Path | str) -> int:
    """Read acton's ceiling, falling back when its config cannot be used."""
    try:
        with Path(config_path).open("rb") as config_file:
            value = tomllib.load(config_file)["limits"]["max_connections"]
        if isinstance(value, bool) or not isinstance(value, int) or value < 1:
            return ACTON_DEFAULT_MAX_CONNECTIONS
        return value
    except (OSError, KeyError, TypeError, tomllib.TOMLDecodeError):
        return ACTON_DEFAULT_MAX_CONNECTIONS


def refusal_message(declared: int, ceiling: int, config_path: Path | str) -> str:
    """Explain why the topology cannot start and name the config to edit."""
    path = Path(config_path).expanduser().resolve()
    return (
        f"declared primitive connections ({declared}) exceed the effective "
        f"acton max_connections ceiling ({ceiling}); set [limits] "
        f"max_connections to at least {declared} in {path}"
    )


def main(argv: Sequence[str] | None = None) -> int:
    """Check an emergent config against the effective machine ceiling."""
    args = list(sys.argv[1:] if argv is None else argv)
    emergent_config = (
        Path(args[0]) if args else Path(__file__).resolve().parents[2] / "emergent.toml"
    )
    ipc_config = acton_ipc_config_path()
    declared = declared_primitive_count(emergent_config)
    ceiling = effective_connection_ceiling(ipc_config)
    if declared > ceiling:
        print(refusal_message(declared, ceiling, ipc_config), file=sys.stderr)
        return 1
    print(f"declared primitive connections: {declared}; effective ceiling: {ceiling}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
