from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

from signalbox.ceiling import (
    ACTON_DEFAULT_MAX_CONNECTIONS,
    INTENDED_MAX_CONNECTIONS,
    acton_ipc_config_path,
    declared_primitive_count,
    effective_connection_ceiling,
    refusal_message,
)


ROOT = Path(__file__).resolve().parent.parent
MODULE = ROOT / "src" / "signalbox" / "ceiling.py"


def test_declared_count_is_derived_from_all_three_primitive_sections(tmp_path: Path):
    config = tmp_path / "emergent.toml"
    config.write_text(
        """
[[sources]]
name = "one"
[[handlers]]
name = "two"
[[handlers]]
name = "three"
[[sinks]]
name = "four"
"""
    )

    assert declared_primitive_count(config) == 4


def test_declared_count_comes_from_the_live_topology():
    count = declared_primitive_count(ROOT / "emergent.toml")

    assert count > ACTON_DEFAULT_MAX_CONNECTIONS
    assert count < INTENDED_MAX_CONNECTIONS


def test_acton_config_path_prefers_xdg_config_home(tmp_path: Path):
    xdg = tmp_path / "xdg"
    home = tmp_path / "home"

    assert acton_ipc_config_path(
        {"XDG_CONFIG_HOME": str(xdg), "HOME": str(home)}
    ) == (xdg / "acton" / "ipc.toml").resolve()


def test_acton_config_path_uses_dot_config_beneath_home(tmp_path: Path):
    assert acton_ipc_config_path({"HOME": str(tmp_path)}) == (
        tmp_path / ".config" / "acton" / "ipc.toml"
    ).resolve()


def test_effective_ceiling_reads_limits_table(tmp_path: Path):
    config = tmp_path / "ipc.toml"
    config.write_text("[limits]\nmax_connections = 321\n")

    assert effective_connection_ceiling(config) == 321


def test_effective_ceiling_falls_back_when_file_is_absent(tmp_path: Path):
    assert (
        effective_connection_ceiling(tmp_path / "missing.toml")
        == ACTON_DEFAULT_MAX_CONNECTIONS
    )


def test_effective_ceiling_falls_back_when_file_is_unreadable_as_config(tmp_path: Path):
    config = tmp_path / "ipc.toml"
    config.write_text("this is not toml = [")

    assert effective_connection_ceiling(config) == ACTON_DEFAULT_MAX_CONNECTIONS


def test_effective_ceiling_falls_back_for_missing_or_invalid_value(tmp_path: Path):
    config = tmp_path / "ipc.toml"
    for contents in (
        "[limits]\nother = 200\n",
        '[limits]\nmax_connections = "many"\n',
        "[limits]\nmax_connections = 0\n",
    ):
        config.write_text(contents)
        assert effective_connection_ceiling(config) == ACTON_DEFAULT_MAX_CONNECTIONS


def test_refusal_names_counts_and_absolute_config_path(tmp_path: Path):
    config = tmp_path / "acton" / "ipc.toml"

    message = refusal_message(7, 5, config)

    assert "7" in message
    assert "5" in message
    assert str(config.resolve()) in message


def test_standalone_entry_point_refuses_without_importing_the_package(tmp_path: Path):
    emergent = tmp_path / "emergent.toml"
    emergent.write_text("".join(f'[[sources]]\nname = "p{i}"\n' for i in range(3)))
    config = tmp_path / "config" / "acton"
    config.mkdir(parents=True)
    (config / "ipc.toml").write_text("[limits]\nmax_connections = 2\n")
    env = {**os.environ, "XDG_CONFIG_HOME": str(tmp_path / "config"), "PYTHONPATH": ""}

    result = subprocess.run(
        [sys.executable, str(MODULE), str(emergent)],
        cwd=tmp_path,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )

    assert result.returncode == 1
    assert "3" in result.stderr
    assert "2" in result.stderr
    assert str((config / "ipc.toml").resolve()) in result.stderr


def test_standalone_entry_point_accepts_a_topology_that_fits(tmp_path: Path):
    emergent = tmp_path / "emergent.toml"
    emergent.write_text('[[sinks]]\nname = "only"\n')
    env = {**os.environ, "HOME": str(tmp_path), "XDG_CONFIG_HOME": "", "PYTHONPATH": ""}

    result = subprocess.run(
        [sys.executable, str(MODULE), str(emergent)],
        cwd=tmp_path,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )

    assert result.returncode == 0
    assert "declared primitive connections: 1" in result.stdout
    assert f"effective ceiling: {ACTON_DEFAULT_MAX_CONNECTIONS}" in result.stdout
