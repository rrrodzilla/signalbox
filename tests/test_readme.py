"""The checked-in topology pictures are generated, not hand-maintained."""

from __future__ import annotations

import re
import tomllib
from pathlib import Path

from signalbox.topology_diagram import render_topology

ROOT = Path(__file__).resolve().parent.parent


def test_shape_section_matches_the_resolved_topology_byte_for_byte():
    readme = (ROOT / "README.md").read_text()
    start = readme.index("## The shape")
    end = readme.index("## Principles the wiring enforces", start)
    shape = readme[start:end]
    blocks = re.findall(r"```\n(.*?)\n```", shape, re.DOTALL)
    assert len(blocks) == 2, "## The shape must contain its two topology fences"

    # Loading here, rather than at import time, makes every assertion observe
    # the current emergent.toml bytes.
    with (ROOT / "emergent.toml").open("rb") as stream:
        expected_main, expected_remediation, expected_counts = render_topology(
            tomllib.load(stream)
        )

    assert blocks[0] == expected_main
    assert blocks[1] == expected_remediation
    assert expected_counts in shape
    assert shape.count(expected_counts) == 1
