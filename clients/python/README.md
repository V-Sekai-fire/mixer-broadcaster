<!--
SPDX-FileCopyrightText: 2026-present K. S. Ernest (iFire) Lee

SPDX-License-Identifier: MIT
-->

# Python reference client

A client of the relay in plain Python (MIT). Everything it needs is MIT, Apache or BSD licensed (Python, `aioquic`,
`numpy`, and `mitsuba`, BSD-3-Clause, for rendering), and it imports nothing that is GPL, so it can be embedded in any permissively licensed engine or tool. The
relay's interface is `spec/asyncapi.yaml`; these modules are one implementation of the client side of it.

- `mixer/broadcaster/` the client modules: `wt.py` (WebTransport), `relay.py` (the command path), `relay_transport.py`
  (session, keepalive), `entity.py` (the 100-byte packet and command packets), `geo_publish.py`, `mesh_split.py`,
  `meshlets.py`, `s3.py`, `texture.py`, `client.py`, `common.py`, `socket.py`, `room_bake.py`, `cli_utils.py`.
- `mixer/broadcaster/render.py` renders a room's entities with Mitsuba 3: `render(entities, meshes)` gives an RGB array. An
  entity whose mesh has not arrived is a unit cube. `mitsuba` is imported only when rendering.
- `mixer/broadcaster/frames.py` coordinate frames. Each engine and renderer has its own (Blender Z up, a left-handed Y-up layout,
  Unreal in centimetres, Godot and Mitsuba the wire's own); a `Frame` converts points, rotations and meshes (reversing the
  winding of a left-handed one) to and from the wire's, and nothing else in the client changes a frame. See `docs/frames.md` at the repository root.
- `tools/` probes and checks that run against a relay (`relay_session_check.py`, `zt_stack.py`, ...).
- `tests/hypo/` Hypothesis tests. They need `pytest`, `hypothesis`, `aioquic`, `numpy` and `mitsuba`:

```
cd clients/python
python -m pip install pytest hypothesis aioquic numpy mitsuba
python -m pytest tests/hypo
```

`tests/hypo/test_explode_rule.py` also runs a headless Godot (MIT) when one is configured and is skipped otherwise.
