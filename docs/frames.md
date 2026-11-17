<!--
SPDX-FileCopyrightText: 2026-present K. S. Ernest (iFire) Lee

SPDX-License-Identifier: MIT
-->

# Coordinate frames

The wire has one frame: right-handed, X right, Y up, -Z forward, metres. Every position, rotation and mesh a client sends
or receives is in it. A client whose engine or renderer uses another frame converts at its own edge, before it builds a
packet and after it reads one. The relay never converts.

`clients/python/mixer/broadcaster/frames.py` holds the conversions. Each `Frame` is a signed permutation matrix and the
metres in one unit:

| Name        | Handedness | X       | Y     | Z        | Unit |
| ----------- | ---------- | ------- | ----- | -------- | ---- |
| `WIRE`      | right      | right   | up    | backward | m    |
| `GODOT`     | right      | right   | up    | backward | m    |
| `MITSUBA`   | right      | right   | up    | backward | m    |
| `BLENDER`   | right      | right   | forward | up     | m    |
| `LEFT_Y_UP` | left       | right   | up    | forward  | m    |
| `UNREAL`    | left       | forward | right | up       | cm   |

(`WIRE` has -Z forward, so its Z points backward. A Blender point (x, y, z) is (x, z, -y) on the wire.)

## Use

```python
from mixer.broadcaster import entity, frames

x, y, z = frames.BLENDER.point_to_wire((1.0, 2.0, 3.0))          # (1.0, 3.0, -2.0)
q = frames.BLENDER.quat_to_wire((qx, qy, qz, qw))                 # a unit quaternion (x, y, z, w)
points, tris = frames.LEFT_Y_UP.mesh_to_wire(points, tris)        # also reverses the triangle winding
e = entity.pose_entity(gid, (x, y, z), q, (1, 1, 1), hlc=hlc)    # wire values only
```

- A frame of the other handedness turns a mesh inside out unless its triangles are wound the other way. `mesh_to_wire`
  and `mesh_from_wire` do that; `point_to_wire` alone does not.
- `rotation_to_wire` and `quat_to_wire` agree with each other for every frame (tested).
- `pose_entity` takes wire values only. There is no per-call frame argument, so one packet cannot be in two frames.

## Adding a frame

Add a `Frame` to `frames.py` with its matrix and unit, add it to `FRAMES`, and add its golden point to
`test_golden_frames` in `clients/python/tests/hypo/test_render.py`. The round-trip and quaternion tests cover it
automatically. The wire does not change, and no frame name is ever sent.

## Rendering

`mixer/broadcaster/render.py` draws a room with Mitsuba 3 (BSD-3-Clause), whose frame is the wire's. `render(entities,
meshes)` returns an RGB array of shape (size, size, 3). `meshes` maps a mesh digest to `(points, triangles)` in
`mesh_frame` (default the wire's); an entity whose mesh has not arrived is a unit cube. Meshes are built in memory with
`mi.Mesh`; no OBJ or PLY file is written.
