"""The dashboard palette must survive colour blindness, and be checked by machine.

A palette cannot be reviewed by looking at it: the reviewer sees the colours the
reader who needs help cannot. So the five meanings are simulated through the
three dichromacies and scored, and the numbers are the acceptance criterion.

The shipped palette was chosen by search under exactly these constraints. Its
predecessor scored 3.9 — under deuteranopia `go` and `stop` were the same lamp,
which is to say finished and failed looked identical on a dashboard whose whole
job is telling them apart.
"""

from __future__ import annotations

import itertools
import math
import re
from pathlib import Path

PAGE = Path(__file__).resolve().parents[1] / "src" / "signalbox" / "dashboard.html"

# The ground the lamps sit on, and the meanings that must stay distinct.
GROUND = "#10151d"
MEANINGS = ("go", "work", "judge", "stop", "hold")

# Below this, two lamps read as the same colour to someone scanning a board.
# The shipped set measures 15.7; the floor leaves room to retune without
# silently sliding back toward the 3.9 that prompted this.
SEPARATION_FLOOR = 12.0
# The palette is text colour (`.ev .ty`), so it owes WCAG AA for text, not the
# 3.0 that would apply if these were only dots.
CONTRAST_FLOOR = 4.5


def _read_vars() -> dict[str, str]:
    """The palette as the browser resolves it: --go -> --green -> #86fc82."""
    css = PAGE.read_text(encoding="utf-8")
    literal = dict(re.findall(r"--([a-z-]+)\s*:\s*(#[0-9a-fA-F]{6})\s*;", css))
    alias = dict(re.findall(r"--([a-z-]+)\s*:\s*var\(--([a-z-]+)\)\s*;", css))
    out = {}
    for name in MEANINGS:
        seen = name
        while seen in alias:
            seen = alias[seen]
        assert seen in literal, f"--{name} does not resolve to a literal colour"
        out[name] = literal[seen]
    return out


def _srgb(h: str) -> tuple[float, float, float]:
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))


def _linear(c: float) -> float:
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def _delinear(c: float) -> float:
    c = max(0.0, min(1.0, c))
    return 12.92 * c if c <= 0.0031308 else 1.055 * c ** (1 / 2.4) - 0.055


_RGB2XYZ = ((0.4124564, 0.3575761, 0.1804375),
            (0.2126729, 0.7151522, 0.0721750),
            (0.0193339, 0.1191920, 0.9503041))
_XYZ2RGB = ((3.2404542, -1.5371385, -0.4985314),
            (-0.9692660, 1.8760108, 0.0415560),
            (0.0556434, -0.2040259, 1.0572252))
_XYZ2LMS = ((0.4002, 0.7076, -0.0808),
            (-0.2263, 1.1653, 0.0457),
            (0.0, 0.0, 0.9182))
_LMS2XYZ = ((1.8600666, -1.1294800, 0.2198983),
            (0.3612229, 0.6388043, -0.0000064),
            (0.0, 0.0, 1.0890873))


def _mul(m, v):
    return [sum(m[r][c] * v[c] for c in range(3)) for r in range(3)]


def simulate(hexcolor: str, kind: str) -> str:
    """Project a colour onto the plane a dichromat can still see.

    Viénot, Brettel & Mollon (1999): the missing cone's response is replaced by
    the linear combination of the surviving two that the confusion axis implies.
    """
    lin = [_linear(c) for c in _srgb(hexcolor)]
    if kind != "normal":
        L, M, S = _mul(_XYZ2LMS, _mul(_RGB2XYZ, lin))
        if kind == "protan":
            L = 2.02344 * M - 2.52581 * S
        elif kind == "deutan":
            M = 0.494207 * L + 1.24827 * S
        elif kind == "tritan":
            S = -0.395913 * L + 0.801109 * M
        else:  # pragma: no cover - guards a typo in a caller
            raise ValueError(f"unknown vision type {kind!r}")
        lin = _mul(_XYZ2RGB, _mul(_LMS2XYZ, [L, M, S]))
    return "#%02x%02x%02x" % tuple(round(_delinear(c) * 255) for c in lin)


def _lab(hexcolor: str) -> tuple[float, float, float]:
    X, Y, Z = _mul(_RGB2XYZ, [_linear(c) for c in _srgb(hexcolor)])
    Xn, Yn, Zn = 0.95047, 1.0, 1.08883

    def f(t):
        return t ** (1 / 3) if t > 216 / 24389 else (841 / 108) * t + 4 / 29

    fx, fy, fz = f(X / Xn), f(Y / Yn), f(Z / Zn)
    return 116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)


def ciede2000(c1: str, c2: str) -> float:
    """Perceptual distance. Euclidean RGB distance would rank these wrongly."""
    L1, a1, b1 = _lab(c1)
    L2, a2, b2 = _lab(c2)
    C1, C2 = math.hypot(a1, b1), math.hypot(a2, b2)
    Cb = (C1 + C2) / 2
    G = 0.5 * (1 - math.sqrt(Cb ** 7 / (Cb ** 7 + 25 ** 7))) if Cb else 0.0
    a1p, a2p = (1 + G) * a1, (1 + G) * a2
    C1p, C2p = math.hypot(a1p, b1), math.hypot(a2p, b2)
    h1p = math.degrees(math.atan2(b1, a1p)) % 360 if (a1p or b1) else 0.0
    h2p = math.degrees(math.atan2(b2, a2p)) % 360 if (a2p or b2) else 0.0
    dLp, dCp = L2 - L1, C2p - C1p
    if C1p * C2p == 0:
        dhp = 0.0
    elif abs(h2p - h1p) <= 180:
        dhp = h2p - h1p
    else:
        dhp = h2p - h1p - 360 if h2p > h1p else h2p - h1p + 360
    dHp = 2 * math.sqrt(C1p * C2p) * math.sin(math.radians(dhp) / 2)
    Lbp, Cbp = (L1 + L2) / 2, (C1p + C2p) / 2
    if C1p * C2p == 0:
        hbp = h1p + h2p
    elif abs(h1p - h2p) <= 180:
        hbp = (h1p + h2p) / 2
    elif h1p + h2p < 360:
        hbp = (h1p + h2p + 360) / 2
    else:
        hbp = (h1p + h2p - 360) / 2
    T = (1 - 0.17 * math.cos(math.radians(hbp - 30))
         + 0.24 * math.cos(math.radians(2 * hbp))
         + 0.32 * math.cos(math.radians(3 * hbp + 6))
         - 0.20 * math.cos(math.radians(4 * hbp - 63)))
    Rc = 2 * math.sqrt(Cbp ** 7 / (Cbp ** 7 + 25 ** 7)) if Cbp else 0.0
    Sl = 1 + (0.015 * (Lbp - 50) ** 2) / math.sqrt(20 + (Lbp - 50) ** 2)
    Sc, Sh = 1 + 0.045 * Cbp, 1 + 0.015 * Cbp * T
    Rt = -math.sin(math.radians(2 * (30 * math.exp(-(((hbp - 275) / 25) ** 2))))) * Rc
    return math.sqrt((dLp / Sl) ** 2 + (dCp / Sc) ** 2 + (dHp / Sh) ** 2
                     + Rt * (dCp / Sc) * (dHp / Sh))


def contrast(fg: str, bg: str) -> float:
    def lum(h):
        r, g, b = (_linear(c) for c in _srgb(h))
        return 0.2126 * r + 0.7152 * g + 0.0722 * b

    a, b = lum(fg), lum(bg)
    hi, lo = max(a, b), min(a, b)
    return (hi + 0.05) / (lo + 0.05)


def test_every_meaning_resolves_to_a_literal_colour():
    palette = _read_vars()
    assert set(palette) == set(MEANINGS)
    assert len(set(palette.values())) == len(MEANINGS), (
        f"two meanings share a colour: {palette}"
    )


def test_no_two_meanings_collide_under_any_colour_blindness():
    """The invariant the old palette failed silently for its whole life."""
    palette = _read_vars()
    worst = (999.0, "", "", "")
    for kind in ("normal", "protan", "deutan", "tritan"):
        sim = {k: simulate(v, kind) for k, v in palette.items()}
        for a, b in itertools.combinations(MEANINGS, 2):
            d = ciede2000(sim[a], sim[b])
            if d < worst[0]:
                worst = (d, a, b, kind)
    d, a, b, kind = worst
    assert d >= SEPARATION_FLOOR, (
        f"under {kind}, {a} and {b} are the same lamp (dE={d:.1f}, "
        f"floor {SEPARATION_FLOOR}). Do not hand-tune one colour: they are a "
        f"coupled system, and moving one has broken a pair it was not part of."
    )


def test_every_meaning_stays_legible_as_text_on_the_enamel():
    for name, colour in _read_vars().items():
        ratio = contrast(colour, GROUND)
        assert ratio >= CONTRAST_FLOOR, (
            f"--{name} {colour} is {ratio:.2f}:1 on {GROUND}, below WCAG AA "
            f"for text ({CONTRAST_FLOOR}:1); it is used as `.ev .ty` colour"
        )


def test_colour_is_never_the_only_channel():
    """Every meaning also has a glyph, so greyscale still reads."""
    css = PAGE.read_text(encoding="utf-8")
    for name in MEANINGS:
        assert re.search(rf"--glyph-{name}\s*:", css), (
            f"{name} has a colour but no glyph, so it is invisible to a reader "
            f"with no colour vision at all"
        )
        assert re.search(rf"\.sev-{name}\s*{{[^}}]*--glyph\s*:\s*var\(--glyph-{name}\)",
                         css), f".sev-{name} does not carry its glyph"


def test_shard_states_are_distinguished_by_shape_not_only_colour():
    """building vs fixing used to differ only by a red/green ring."""
    css = PAGE.read_text(encoding="utf-8")
    shapes = {}
    for state in ("building", "review", "fixing", "done", "escalated"):
        m = re.search(rf"\.shard-lamp\.s-{state}\s*{{([^}}]*)}}", css)
        assert m, f"no rule for shard state {state}"
        body = m.group(1)
        shapes[state] = ("round" if "border-radius:50%" in body else
                         "diamond" if "rotate(45deg)" in body else "square",
                         "filled" if "background:var(" in body else "hollow")
    assert shapes["building"] != shapes["fixing"], (
        "building and fixing are the same shape, so the only thing separating "
        "ordinary rework from a rejected round is a red/green ring"
    )
    assert len(set(shapes.values())) >= 4, (
        f"shard states collapse into too few shapes: {shapes}"
    )
