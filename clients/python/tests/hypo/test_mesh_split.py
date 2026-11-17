"""
Hypothesis tests of cutting a mesh into pieces (mixer/broadcaster/mesh_split.py). No engine needed.
GOLDEN: two separate cubes are two shells and one piece when they fit together, two when they do not; one big sheet is
  cut on a grid.
INVARIANT: for any triangle soup and limit the pieces are a partition of the triangles (each once, none lost, none
  copied), each at most the limit, and the same input gives the same pieces; shells are never cut unless one is over the limit.
CONTROL: an empty mesh is no pieces; a limit under 1 is refused; a mesh at the limit is one piece.
"""

import os
import sys

import pytest
from hypothesis import given, settings, strategies as st

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))
from mixer.broadcaster import mesh_split  # noqa: E402


def cube(ox):
    p = [(ox + x, y, z) for x in (0, 1) for y in (0, 1) for z in (0, 1)]
    t = [
        (0, 1, 3),
        (0, 3, 2),
        (4, 6, 7),
        (4, 7, 5),
        (0, 4, 5),
        (0, 5, 1),
        (2, 3, 7),
        (2, 7, 6),
        (0, 2, 6),
        (0, 6, 4),
        (1, 5, 7),
        (1, 7, 3),
    ]
    return p, t


def two_cubes():
    p1, t1 = cube(0)
    p2, t2 = cube(5)
    return p1 + p2, t1 + [(a + 8, b + 8, c + 8) for a, b, c in t2]


def sheet(n):
    p = [(x, y, 0.0) for y in range(n + 1) for x in range(n + 1)]
    t = []
    for y in range(n):
        for x in range(n):
            a = y * (n + 1) + x
            t += [(a, a + 1, a + n + 1), (a + 1, a + n + 2, a + n + 1)]
    return p, t


def test_golden_shells_and_packing():
    p, t = two_cubes()
    assert len(mesh_split.shells(p, t)) == 2
    assert [len(x) for x in mesh_split.split(p, t, 24)] == [24]
    assert sorted(len(x) for x in mesh_split.split(p, t, 12)) == [12, 12]


def test_golden_a_big_shell_is_cut_on_a_grid():
    p, t = sheet(20)  # 800 triangles, one shell
    pieces = mesh_split.split(p, t, 100)
    assert len(pieces) >= 8 and all(len(x) <= 100 for x in pieces)
    assert sorted(i for x in pieces for i in x) == list(range(800))


def test_control():
    assert mesh_split.split([], [], 10) == []
    with pytest.raises(ValueError):
        mesh_split.split([(0, 0, 0)], [(0, 0, 0)], 0)
    p, t = sheet(3)
    assert mesh_split.split(p, t, len(t)) == [list(range(len(t)))]


soup = st.integers(1, 40).flatmap(
    lambda n: st.tuples(
        st.lists(st.tuples(*[st.floats(-50, 50)] * 3), min_size=3, max_size=n + 3),
        st.integers(1, 60),
        st.integers(1, 25),
    )
)


@settings(max_examples=60, deadline=None)
@given(soup)
def test_invariant_partition_under_the_limit(args):
    points, ntris, limit = args
    tris = [(i % len(points), (i * 7 + 1) % len(points), (i * 13 + 2) % len(points)) for i in range(ntris)]
    pieces = mesh_split.split(points, tris, limit)
    assert sorted(i for x in pieces for i in x) == list(range(ntris))
    assert all(1 <= len(x) <= limit for x in pieces)
    assert pieces == mesh_split.split(points, tris, limit)


@settings(max_examples=30, deadline=None)
@given(st.integers(2, 12), st.integers(8, 200))
def test_invariant_a_shell_that_fits_is_never_cut(n, limit):
    p, t = sheet(n)
    pieces = mesh_split.split(p, t, limit)
    if len(t) <= limit:
        assert len(pieces) == 1


from mixer.broadcaster import meshlets  # noqa: E402

needs_lib = pytest.mark.skipif(not meshlets.available(), reason="run tools/build_meshopt.sh")


@needs_lib
def test_golden_meshlets_cut_a_big_shell():
    p, t = sheet(30)  # 1800 triangles, one shell
    ms = meshlets.build(p, t, list(range(len(t))), 124)
    assert len(ms) >= 15 and all(1 <= len(m) <= 124 for m in ms)
    assert sorted(i for m in ms for i in m) == list(range(len(t)))
    pieces = mesh_split.split(p, t, 300)
    assert all(len(x) <= 300 for x in pieces) and sorted(i for x in pieces for i in x) == list(range(len(t)))
    assert len(pieces) < len(ms)  # meshlets packed together, not one entity per meshlet


@needs_lib
@settings(max_examples=40, deadline=None)
@given(soup)
def test_invariant_meshlet_pieces_partition(args):
    points, ntris, limit = args
    tris = [(i % len(points), (i * 7 + 1) % len(points), (i * 13 + 2) % len(points)) for i in range(ntris)]
    pieces = mesh_split.split(points, tris, max(limit, 4))
    assert sorted(i for x in pieces for i in x) == list(range(ntris))
    assert all(1 <= len(x) <= max(limit, 4) for x in pieces)


@needs_lib
def test_control_meshlet_cut_loses_nothing_on_a_repeated_triangle():
    p = [(0, 0, 0), (1, 0, 0), (0, 1, 0)]
    t = [(0, 1, 2)] * 6
    pieces = mesh_split.split(p, t, 4)
    assert sorted(i for x in pieces for i in x) == list(range(6)) and all(len(x) <= 4 for x in pieces)


@needs_lib
def test_golden_small_shells_are_meshlet_cut_too():
    p, t = two_cubes()  # two 12-triangle shells: each is a meshlet, a piece never mixes a meshlet's triangles away
    calls = []
    real = meshlets.build
    meshlets.build = lambda *a, **k: (calls.append(len(a[2])), real(*a, **k))[1]
    try:
        pieces = mesh_split.split(p, t, 12)
    finally:
        meshlets.build = real
    assert calls == [12, 12]  # the builder saw each small shell, not only big ones
    assert sorted(len(x) for x in pieces) == [12, 12]
