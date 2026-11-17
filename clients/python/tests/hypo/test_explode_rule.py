"""
Hypothesis tests that mesh_split.shells is explode.gd's rule: the same meshes go through explode.gd's own _split_shells
(headless Godot, tests/godot/explode_shells.gd) and through the port, and must give the same pieces.
Real meshes only, never made-up primitives: tools/export_real_meshes.py dumps the recovered scene (a scanned character in
nine meshes of about 120k triangles, Suzanne, a torus) and tools/usda_to_real.py the clothed, skinned character of
chibifire-stages/elaina-summerwhitedress-stage (CC-BY-4.0, ScarletJadeDream; fetched into REAL_OUT, never committed).
GOLDEN: each real mesh, at its own world transform, gives the same pieces in explode.gd and in the port.
INVARIANT: for any real mesh, any slice of its triangles and any world scale and offset, the sizes of the pieces (shells
  with at least 1 % of the triangles) and the number of triangles left in the small shells agree.
CONTROL: a slice with every vertex pulled apart (no vertex shared by two triangles) is one shell per triangle in both.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile

import pytest
from hypothesis import given, settings, strategies as st

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))
from mixer.broadcaster import mesh_split  # noqa: E402

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
GODOT = os.environ.get(
    "GODOT_DOUBLE", os.path.join(os.environ.get("TMPDIR", "/tmp"), "ez", "godot.macos.editor.double.arm64")
)
EME = os.environ.get("EME", os.path.expanduser("~/.hermes/cache/scratch/eme"))
pytestmark = pytest.mark.skipif(
    not (os.path.exists(GODOT) and os.path.exists(os.path.join(EME, "addons/model_explode/explode.gd"))),
    reason="needs the double-precision Godot editor and the model_explode add-on (GODOT_DOUBLE, EME)",
)


def explode(points, tris, xform):
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump({"points": points, "tris": tris, "xform": xform}, f)
    env = dict(
        os.environ,
        SHELLS_IN=f.name,
        EXPLODE_GD="res://addons/model_explode/explode.gd",
        DYLD_FALLBACK_LIBRARY_PATH=os.path.dirname(GODOT) + ":/usr/local/lib",
    )
    out = subprocess.run(
        [GODOT, "--headless", "--path", EME, "--script", os.path.join(REPO, "tests/godot/explode_shells.gd")],
        env=env,
        capture_output=True,
        text=True,
        timeout=90,
    ).stdout
    os.unlink(f.name)
    rows = [ln.split() for ln in out.splitlines() if ln.startswith("SHELL ")]
    assert rows, out[-400:]
    return sorted(int(n) for k, n in (r[1:] for r in rows) if k.startswith("shell:")), sum(
        int(n) for k, n in (r[1:] for r in rows) if k.startswith("small:")
    )


def world(points, xform):
    m = xform
    return [
        (
            m[0] * x + m[1] * y + m[2] * z + m[9],
            m[3] * x + m[4] * y + m[5] * z + m[10],
            m[6] * x + m[7] * y + m[8] * z + m[11],
        )
        for x, y, z in points
    ]


def port(points, tris, xform):
    found = mesh_split.shells(points, tris, world(points, xform))
    pieces = sorted(len(s) for s in found if mesh_split.is_piece(len(s), len(tris)))
    return pieces, sum(len(s) for s in found if not mesh_split.is_piece(len(s), len(tris)))


REAL = os.environ.get("REAL_OUT", os.path.join(os.environ.get("TMPDIR", "/tmp"), "real"))
NAMES = sorted(f[:-5] for f in os.listdir(REAL)) if os.path.isdir(REAL) else []
SMALL = [n for n in NAMES if os.path.getsize(os.path.join(REAL, n + ".json")) < 2_000_000]
BIG = [
    n for n in NAMES if n not in SMALL
]  # a scanned character is 120k triangles a mesh: sampled, not all, in the golden
needs_real = pytest.mark.skipif(not NAMES, reason="run tools/export_real_meshes.py (REAL_OUT)")


def load(name, frac=1.0):
    d = json.load(open(os.path.join(REAL, name + ".json")))
    tris = d["tris"][: max(1, int(len(d["tris"]) * frac))]
    return d["points"], tris, d["xform"]


@needs_real
@pytest.mark.parametrize("name", SMALL + BIG[:4])
def test_golden_real_mesh_same_pieces(name):
    p, t, xf = load(name)
    got = port(p, t, xf)
    assert got == explode(p, t, xf)
    assert got[0], "a real mesh has at least one piece"


@needs_real
@settings(max_examples=12, deadline=None)
@given(
    st.sampled_from(NAMES),
    st.floats(0.05, 1.0),
    st.lists(st.sampled_from([0.01, 0.5, 1.0, 3.0, 250.0]), min_size=3, max_size=3),
    st.lists(st.floats(-100, 100), min_size=3, max_size=3),
)
def test_invariant_slices_and_scales_of_real_meshes(name, frac, scale, off):
    p, t, _ = load(name, frac)
    xf = [scale[0], 0, 0, 0, scale[1], 0, 0, 0, scale[2], off[0], off[1], off[2]]
    assert port(p, t, xf) == explode(p, t, xf)


@needs_real
@settings(max_examples=5, deadline=None)
@given(st.sampled_from(SMALL), st.floats(0.05, 1.0))
def test_control_pulled_apart_is_one_shell_per_triangle(name, frac):
    p, t, xf = load(name, frac)
    apart = [p[v] for tri in t for v in tri]  # every corner its own vertex, none shared
    apart = [[x + 1e-3 * i, y, z] for i, (x, y, z) in enumerate(apart)]  # and no two at one position
    idx = [[3 * i, 3 * i + 1, 3 * i + 2] for i in range(len(t))]
    want = ([1] * len(t), 0) if len(t) <= 100 else None
    got = port(apart, idx, xf)
    assert got == explode(apart, idx, xf)
    if want:
        assert got == want
