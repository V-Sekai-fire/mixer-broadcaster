# SPDX-FileCopyrightText: 2026-present K. S. Ernest (iFire) Lee
#
# SPDX-License-Identifier: MIT

"""Coordinate frames. Every game engine and renderer has its own, and a client has to say which one it speaks.

The wire's frame is fixed: right-handed, X right, Y up, -Z forward, metres (the frame of Godot, glTF and Mitsuba). A
`Frame` says how a point of another frame is written on the wire: a 3x3 matrix `to_wire` of whole numbers (a signed
permutation) and the metres that one unit of the frame is. A frame whose matrix has determinant -1 is the other handedness:
it turns a mesh inside out unless its triangles are wound the other way, so `mesh_to_wire` and `mesh_from_wire` do that.
Nothing else in the client changes a frame: a pose or a mesh enters or leaves through here.
"""

from dataclasses import dataclass
from typing import List, Sequence, Tuple

Vec = Tuple[float, float, float]
Mat = Tuple[Vec, Vec, Vec]


def _det(m: Mat) -> int:
    (a, b, c), (d, e, f), (g, h, i) = m
    return int(a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g))


def _mul(a: Mat, b: Mat) -> Mat:
    return tuple(tuple(sum(a[i][k] * b[k][j] for k in range(3)) for j in range(3)) for i in range(3))  # type: ignore


def _t(m: Mat) -> Mat:
    return tuple(tuple(m[j][i] for j in range(3)) for i in range(3))  # type: ignore


@dataclass(frozen=True)
class Frame:
    name: str
    description: str
    to_wire: Mat  # wire = to_wire @ point, with the point in the frame's own units
    metres: float = 1.0  # metres in one unit of the frame

    @property
    def handed(self) -> int:
        """+1 when the frame has the wire's handedness, -1 when it has the other."""
        return _det(self.to_wire)

    def point_to_wire(self, p: Sequence[float]) -> Vec:
        m = self.to_wire
        return tuple(self.metres * sum(m[i][j] * p[j] for j in range(3)) for i in range(3))  # type: ignore

    def point_from_wire(self, p: Sequence[float]) -> Vec:
        m = _t(self.to_wire)  # a signed permutation's inverse is its transpose
        return tuple(sum(m[i][j] * p[j] for j in range(3)) / self.metres for i in range(3))  # type: ignore

    def rotation_to_wire(self, r: Mat) -> Mat:
        """A rotation matrix of this frame as the same turn on the wire (M R M^T, a proper rotation for either handedness)."""
        return _mul(_mul(self.to_wire, r), _t(self.to_wire))

    def quat_to_wire(self, q: Sequence[float]) -> Tuple[float, float, float, float]:
        """A quaternion (x, y, z, w) of this frame on the wire. The axis is a vector of the frame, so it goes through the
        matrix; a handedness change reverses the sense of a turn about it, so the angle's sign flips with it."""
        x, y, z, w = q
        ax = self.point_to_wire((x, y, z))
        k = self.handed / self.metres  # point_to_wire scaled by metres; the axis is a direction, so undo that
        return (ax[0] * k, ax[1] * k, ax[2] * k, w)

    def mesh_to_wire(self, points: Sequence[Sequence[float]], tris: Sequence[Sequence[int]]):
        pts = [self.point_to_wire(p) for p in points]
        return pts, [tuple(t) if self.handed > 0 else (t[0], t[2], t[1]) for t in tris]

    def mesh_from_wire(self, points: Sequence[Sequence[float]], tris: Sequence[Sequence[int]]):
        pts = [self.point_from_wire(p) for p in points]
        return pts, [tuple(t) if self.handed > 0 else (t[0], t[2], t[1]) for t in tris]


WIRE = Frame("wire", "right-handed, X right, Y up, -Z forward, metres", ((1, 0, 0), (0, 1, 0), (0, 0, 1)))
GODOT = Frame("godot", "the wire's own frame: Godot, glTF", WIRE.to_wire)
MITSUBA = Frame("mitsuba", "right-handed, Y up; the camera looks along its own +Z, which look_at sets", WIRE.to_wire)
BLENDER = Frame("blender", "right-handed, X right, Y forward, Z up, metres", ((1, 0, 0), (0, 0, 1), (0, -1, 0)))
LEFT_Y_UP = Frame("left_y_up", "left-handed, X right, Y up, Z forward, metres (the common left-handed engine layout)", ((1, 0, 0), (0, 1, 0), (0, 0, -1)))
UNREAL = Frame("unreal", "left-handed, X forward, Y right, Z up, centimetres", ((0, 1, 0), (0, 0, 1), (-1, 0, 0)), 0.01)
FRAMES = {f.name: f for f in (WIRE, GODOT, MITSUBA, BLENDER, LEFT_Y_UP, UNREAL)}
