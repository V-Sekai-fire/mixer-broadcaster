# SPDX-FileCopyrightText: 2026-present K. S. Ernest (iFire) Lee
#
# SPDX-License-Identifier: MIT

"""GOLDEN: a posed entity becomes the matrix its pose says, and a cube at the origin renders as a lit shape on a lit
background. INVARIANT: for any pose the matrix's rotation block is orthonormal (before scale) and its translation is the
packet's position. CONTROL: an entity moved out of view leaves the picture as empty as no entity at all."""

import math

import pytest
from hypothesis import given, settings, strategies as st

from mixer.broadcaster import entity, render

metres = st.floats(-100, 100, allow_nan=False)
quats = st.tuples(*[st.floats(-1, 1)] * 4).filter(lambda q: sum(c * c for c in q) > 0.1)


def unit(q):
    n = math.sqrt(sum(c * c for c in q))
    return tuple(c / n for c in q)


def test_golden_identity_pose_is_a_translation():
    e = entity.pose_entity(1, (1.0, 2.0, 3.0), (0, 0, 0, 1), (1, 1, 1), hlc=1)
    m = render.transform(e)  # the pose is the wire's, so the matrix holds it as given
    assert [m[i][3] for i in range(3)] == [1.0, 2.0, 3.0]
    for i in range(3):
        assert m[i][i] == pytest.approx(1.0, abs=1e-3)


@settings(max_examples=60, deadline=None)
@given(metres, metres, metres, quats)
def test_invariant_rotation_block_is_orthonormal(x, y, z, q):
    e = entity.pose_entity(2, (x, y, z), unit(q), (1, 1, 1), hlc=1)
    m = render.transform(e)
    _, s = e.mesh()
    cols = [[m[i][j] for i in range(3)] for j in range(3)]
    for a in range(3):
        for b in range(3):
            dot = sum(cols[a][i] * cols[b][i] for i in range(3)) / (s[a] * s[b])
            assert dot == pytest.approx(1.0 if a == b else 0.0, abs=1e-3)
    assert m[0][3] == pytest.approx(x, abs=2e-6)


def test_render_golden_and_control():
    pytest.importorskip("mitsuba")
    np = pytest.importorskip("numpy")
    cube = entity.pose_entity(3, (0, 0, 0), (0, 0, 0, 1), (1, 1, 1), hlc=1)
    away = entity.pose_entity(3, (500, 0, 0), (0, 0, 0, 1), (1, 1, 1), hlc=1)
    with_cube = render.render([cube], size=32, spp=4)
    without = render.render([], size=32, spp=4)
    moved = render.render([away], size=32, spp=4)
    assert with_cube.shape == (32, 32, 3)
    assert np.abs(with_cube - without).max() > 0.05  # the cube is seen
    assert np.abs(moved - without).max() < 1e-6  # control: out of view leaves the picture alone
    centre, corner = with_cube[16, 16], with_cube[0, 0]
    assert not np.allclose(centre, corner)


def test_render_uses_the_mesh_of_a_digest():
    pytest.importorskip("mitsuba")
    np = pytest.importorskip("numpy")
    digest = bytes(range(32))
    e = entity.pose_entity(4, (0, 0, 0), (0, 0, 0, 1), (1, 1, 1), hlc=1, digest=digest)
    tri = ([(-1, -1, 0), (1, -1, 0), (0, 1, 0)], [(0, 1, 2)])  # a flat triangle, wide in the view
    cube = render.render([entity.pose_entity(4, (0, 0, 0), (0, 0, 0, 1), (1, 1, 1), hlc=1)], size=32, spp=4)
    mesh = render.render([e], {digest: tri}, size=32, spp=4)
    assert np.abs(cube - mesh).max() > 0.05  # the triangle is drawn, not the placeholder cube


from mixer.broadcaster import frames  # noqa: E402

pts = st.tuples(*[st.floats(-50, 50, allow_nan=False)] * 3)


@settings(max_examples=60, deadline=None)
@given(st.sampled_from(sorted(frames.FRAMES)), pts)
def test_invariant_a_point_round_trips_through_any_frame(name, p):
    f = frames.FRAMES[name]
    back = f.point_from_wire(f.point_to_wire(p))
    assert back == pytest.approx(p, abs=1e-9)


def test_golden_frames():
    assert not hasattr(entity, "to_wire_point")  # the wire has one frame; conversion lives in frames only
    assert frames.BLENDER.point_to_wire((1, 2, 3)) == (1, 3, -2)
    assert frames.LEFT_Y_UP.point_to_wire((1, 2, 3)) == (1, 2, -3)
    assert frames.UNREAL.point_to_wire((100, 200, 300)) == pytest.approx((2.0, 3.0, -1.0))  # cm, X forward
    assert [frames.FRAMES[n].handed for n in ("wire", "godot", "mitsuba", "blender", "left_y_up", "unreal")] == [
        1,
        1,
        1,
        1,
        -1,
        -1,
    ]


def test_control_a_left_handed_mesh_is_wound_the_other_way():
    tri = ([(0, 0, 0), (1, 0, 0), (0, 1, 0)], [(0, 1, 2)])
    assert frames.LEFT_Y_UP.mesh_to_wire(*tri)[1] == [(0, 2, 1)]
    assert frames.BLENDER.mesh_to_wire(*tri)[1] == [(0, 1, 2)]


@settings(max_examples=60, deadline=None)
@given(st.sampled_from(sorted(frames.FRAMES)), quats)
def test_invariant_a_quaternion_and_its_matrix_cross_a_frame_alike(name, q):
    f = frames.FRAMES[name]
    q = unit(q)
    via_matrix = f.rotation_to_wire(tuple(map(tuple, render.rotation(q))))
    via_quat = render.rotation(f.quat_to_wire(q))
    for i in range(3):
        assert via_matrix[i] == pytest.approx(via_quat[i], abs=1e-9)


def test_render_a_mesh_from_another_frame_looks_the_same():
    pytest.importorskip("mitsuba")
    np = pytest.importorskip("numpy")
    digest = bytes(range(32))
    e = entity.pose_entity(5, (0, 0, 0), (0, 0, 0, 1), (1, 1, 1), hlc=1, digest=digest)
    wire = ([(-1, -1, 0), (1, -1, 0), (0, 1, 0)], [(0, 1, 2)])
    left = frames.LEFT_Y_UP.mesh_from_wire(*wire)  # the same triangle written in a left-handed frame and its winding
    a = render.render([e], {digest: wire}, size=32, spp=4)
    b = render.render([e], {digest: left}, size=32, spp=4, mesh_frame=frames.LEFT_Y_UP)
    assert np.abs(a - b).max() < 1e-6
