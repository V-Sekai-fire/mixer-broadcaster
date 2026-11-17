<!--
SPDX-FileCopyrightText: 2026 K. S. Ernest (iFire) Lee

SPDX-License-Identifier: MIT
-->

# Changelog

The record of the frontier-learning iterations over the relay's interface. `mix frontier` (no arguments) runs every
level against the real closed relay over WebTransport and prints passes over problems per level; `FRONTIER_N` sets the
problems per level (default 8). 1.000 covers only the problems written so far.

## Frontier iteration 1: the document against the code

Levels, low to high: 1 room door, 2 refusals, 3 chart, 4 poses, 5 meshes, 6 commands, 7 demo HTTP, 8 configuration,
9 late joiners, removal and bulk data, 10 departures and the command door, 11 the client library. Every client is
admitted with a minted token and a signed nonce; the control level plants a wrong reply and must fail the checker.

Baseline: levels 1 to 10 passed n/n on the first run; level 11 (the client library) was 0/4.

Level 11, kept: `Client.recv_reliable/4` waited only for `stream` events, but a reply the relay sends with FIN arrives
as a `stream_fin` event, so every JSON reply timed out with 0 bytes. It now reads `stream_fin` too. Level 11 is 4/4 and
no lower level dropped.

Not measured: a level with no problems is unmeasured, for example the closed relay under datagram loss (`MB_LOSS`),
a browser origin that `MB_ORIGINS` allows, and meshes larger than one datagram over a real connection.

## Frontier iteration 2: the document against the AsyncAPI 3.1.0 specification

Read the specification itself (Channel Object: every message sent to a channel must be valid against one and only one
of its messages; Message Object: `headers` define application headers; Data Type Formats: `binary` is a `format`).

Kept: the command path was one channel whose empty-payload commands (`leaveRoom`, `listRooms`, `content` and the relay's
`leaveRoomOk`, `contentOffer`, `clearContent`) were all the same schema, so a packet fit several messages. The path is
now two channels, `commandsIn` and `commandsOut`, and each command message carries its type number in `headers`, so a
packet fits exactly one. A test checks every type number from 1 to 1200 on both channels. The packet schema now says
`format: binary` instead of `contentEncoding: binary`. All frontier levels stay n/n and the AsyncAPI CLI validates.

## Frontier iteration 3: the document against the AsyncAPI 3.1.0 text, point by point

Read again against the specification and the HTTP binding (version 0.3.0). Kept:

- The echo server, channel and operations are not run by the relay, and the specification says everything outside
  `components` MUST be used by the application, so they moved into `components`.
- The demo's GET routes were operations whose messages were the pages. A request is what the application receives and
  the page is its reply, so each now has `messages: []` and the page, with its `statusCode` (200, and 404 for
  `notFound`), in `reply`; the HTTP binding says `statusCode` is only read on reply messages.
- Examples carry `headers` as well as `payload`, and a message example MUST validate against both.

New checks in `test/asyncapi_test.exs`, each shown to fail on a planted fault: every `$ref` resolves, component keys
match the allowed pattern, an operation's and its reply's messages are among their channel's, everything outside
`components` is used, a channel address names exactly its parameters, an HTTP reply has a status code, and an example of
any message fits that message and no other on its channel. All frontier levels stay n/n.

## Frontier iteration 4: field by field

Compared every object of the document with the fixed fields the AsyncAPI 3.1.0 text lists for it. The document had no
field the specification does not define, no URL in a `host`, no query or fragment in an address, and no reference with
extra fields, so the only change to the spec is `info.version` (0.2.0 to 0.3.0), because the channel layout changed in
iterations 2 and 3. New tests in `test/asyncapi_test.exs`, each rule shown to fail on a planted fault (a misspelt
operation field, a URL as a host, a query in an address): only defined fields or `x-` extensions, the required fields,
a specific media type for `contentType`, empty reserved HTTP server and channel bindings, HTTP operation and message
bindings limited to their defined fields, a reference holds only `$ref`, and root operations and channels point at the
root. Not covered: Security Scheme objects, because admission is an in-protocol handshake (token, key, signed nonce).

## Python reference client

Moved the MIT client code out of the Blender add-on's repository: `mixer/broadcaster` (without the old TCP server),
the probe tools that need no `bpy`, and the Hypothesis tests that import only those modules, now in `clients/python`.
The tools that import `bpy` and the tests that need Blender stay in the add-on's repository, so no MIT code is left to
maintain there. 151 tests pass, 4 skipped (Godot), on the first run in the new place; CI runs them on both systems.

## Permissive licences only

The relay works with MIT, Apache, BSD and MPL-2.0 licensed engines and libraries only (MPL-2.0 allowed by the operator, so the Python tests may use Hypothesis). `test/licence_gate_test.exs` reads the
licence each package in `mix.lock` states and fails on anything else (copyleft, unknown, none); the controls show it
refuses GPL, LGPL, AGPL, MPL-1.1, SSPL, an empty licence and a package with none. Dropped the unused lock entries
`mix deps.unlock --unused` found (`hkdf_erlang`, `jason`, `nimble_pool`, `req` and others), which had no package behind them. The Python
client drops the remaining wording about a GPL host application and renames its Z-up helpers (`points_blender` is
`points_zup`); the wire constants inherited from the earlier numbering are unchanged.

## Mitsuba 3 renderer

`clients/python/mixer/broadcaster/render.py` renders a room's entities with Mitsuba 3 (BSD-3-Clause): `transform` turns a
packet's pose into a matrix (no dependency), `render` builds a scene (OBJ from a mesh by digest, a unit cube when the mesh
has not arrived) and returns an RGB array. Meshes are built in memory from arrays, not written as OBJ files. Tests: the pose matrix is orthonormal for any pose (Hypothesis), a cube is
seen, a mesh replaces the cube, and an entity moved out of view leaves the picture unchanged (control).

## Frames

`clients/python/mixer/broadcaster/frames.py` names the coordinate frame of the wire (right-handed, Y up, -Z forward, metres)
and of Godot, Mitsuba, Blender, a left-handed Y-up layout and Unreal, each as a signed permutation and a unit. A frame converts a point, a
rotation or a mesh to the wire and back; a left-handed frame also reverses triangle winding. The renderer declares that
its frame is the wire's and takes a `mesh_frame` for meshes. Tests: round trip for any point in any frame, a quaternion and
its matrix cross a frame alike, golden points per engine, a left-handed mesh renders the same as the wire's, and the winding control.

The wire has one frame (right-handed, X right, Y up, -Z forward, metres), now stated in `info.description` of the spec. `pose_entity` takes wire values only (`quat_xyzw`), and `to_wire_point` and `to_wire_quat`, which converted from Blender's frame, are removed from `entity.py`; conversion from any other frame lives in `frames.py` and is done by the client before it builds a packet.
