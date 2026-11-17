# SPDX-FileCopyrightText: 2026-present K. S. Ernest (iFire) Lee
#
# SPDX-License-Identifier: MIT

"""Render a room's entities with Mitsuba 3 (BSD-3-Clause), the reference renderer of the Python client.

An entity packet is a pose (position in micrometres, swing-twist rotation, log-coded scale) and the digest of a mesh.
`transform` turns the pose into a 4x4 matrix with no dependency; `scene` and `render` need `mitsuba` and import it only
when called. The wire's frame and Mitsuba's are the same (`frames`), so poses are not converted; meshes are built in memory (no OBJ or PLY file) and may come in any other frame, named by `mesh_frame`. An entity whose mesh is not in
`meshes` is drawn as a unit cube, so a room can be looked at before its meshes have arrived.
"""

from typing import Any, Dict, Iterable, List, Mapping, Optional, Sequence, Tuple

from .entity import Entity, quat_of_codes
from .frames import MITSUBA, WIRE, Frame

Matrix = List[List[float]]
Mesh = Tuple[Sequence[Sequence[float]], Sequence[Sequence[int]]]  # points, triangles


def rotation(q: Sequence[float]) -> Matrix:
    """The 3x3 rotation of a unit quaternion (x, y, z, w)."""
    x, y, z, w = q
    return [
        [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
        [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
        [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
    ]


def transform(e: Entity) -> Matrix:
    """The entity's local-to-world matrix: translation, then rotation, then scale."""
    r = rotation(quat_of_codes(*e.rot))
    _, s = e.mesh()
    t = [v / 1_000_000 for v in e.pos]
    return [[r[i][0] * s[0], r[i][1] * s[1], r[i][2] * s[2], t[i]] for i in range(3)] + [[0.0, 0.0, 0.0, 1.0]]


def _world(points: Sequence[Sequence[float]], m: Matrix) -> List[List[float]]:
    return [[sum(m[i][j] * p[j] for j in range(3)) + m[i][3] for i in range(3)] for p in points]


def _mesh(name: str, points: Sequence[Sequence[float]], tris: Sequence[Sequence[int]], colour: Sequence[float]) -> Any:
    """A Mitsuba mesh built in memory from the arrays, no file in between."""
    import mitsuba as mi
    import numpy as np

    props = mi.Properties()
    props["bsdf"] = mi.load_dict({"type": "diffuse", "reflectance": {"type": "rgb", "value": list(colour)}})
    mesh = mi.Mesh(name, vertex_count=len(points), face_count=len(tris), props=props)
    params = mi.traverse(mesh)
    params["vertex_positions"] = np.asarray(points, dtype=np.float32).ravel()
    params["faces"] = np.asarray(tris, dtype=np.uint32).ravel()
    params.update()
    return mesh


def scene(
    entities: Iterable[Entity],
    meshes: Mapping[bytes, Mesh],
    eye: Sequence[float] = (0.0, 2.0, 6.0),
    target: Sequence[float] = (0.0, 0.0, 0.0),
    size: int = 128,
    spp: int = 16,
    mesh_frame: Frame = WIRE,
) -> Dict[str, Any]:
    """A Mitsuba scene dictionary. `meshes` are in `mesh_frame` (default the wire's); poses are always the wire's, and
    Mitsuba's frame is the wire's too (`frames.MITSUBA`), so only a mesh in another frame is converted."""
    import mitsuba as mi

    assert MITSUBA.to_wire == WIRE.to_wire  # the renderer's frame is the wire's: no conversion of poses
    d: Dict[str, Any] = {
        "type": "scene",
        "integrator": {"type": "direct"},
        "sensor": {
            "type": "perspective",
            "fov": 45,
            "to_world": mi.ScalarTransform4f().look_at(origin=list(eye), target=list(target), up=[0, 1, 0]),
            "film": {"type": "hdrfilm", "width": size, "height": size, "rfilter": {"type": "box"}},
            "sampler": {"type": "independent", "sample_count": spp},
        },
        "light": {"type": "constant", "radiance": {"type": "rgb", "value": [1.0, 1.0, 1.0]}},
    }
    for e in entities:
        digest, _ = e.mesh()
        colour = [0.2 + 0.6 * ((e.gid * 37) % 7) / 6, 0.5, 0.5]
        if digest in meshes:
            points, tris = mesh_frame.mesh_to_wire(*meshes[digest])
            d["e%d" % e.gid] = _mesh("e%d" % e.gid, _world(points, transform(e)), tris, colour)
        else:
            d["e%d" % e.gid] = {
                "type": "cube",
                "to_world": mi.ScalarTransform4f(transform(e)),
                "bsdf": {"type": "diffuse", "reflectance": {"type": "rgb", "value": colour}},
            }
    return d


def render(entities: Iterable[Entity], meshes: Optional[Mapping[bytes, Mesh]] = None, **options: Any) -> Any:
    """Render the entities to a numpy array (size, size, 3) of linear RGB floats."""
    import mitsuba as mi
    import numpy as np

    mi.set_variant("scalar_rgb")
    s = mi.load_dict(scene(entities, meshes or {}, **options))
    return np.array(mi.render(s))[:, :, :3]
