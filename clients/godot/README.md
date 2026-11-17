# Godot viewer for the closed relay

A Godot project that joins a room as a signed-in player and draws what Blender sends. It signs in with
`mixer_auth.elf` (the guest ELF from `V-Sekai-fire/interactor-mixer-auth-guest`; copy it beside `project.godot`), gets a
token with the read right from the minter, joins over WebTransport, asks the relay for each mesh by digest, fetches the
presigned index and chunks and checks the index hash. A console at the bottom of the window logs every step.

The engine needs `WebTransportPeer` and `Sandbox` (the entities-zone double editor or its template build).

```
MB_PORT=4466 MB_ROOM=live MB_MINTER=http://127.0.0.1:4467 AUTH_ELF=res://mixer_auth.elf \
  godot.macos.editor.double.arm64 --path clients/godot
```

Godot's `WebTransportPeer` reads no reply from a stream, so every question goes out as a datagram and the relay answers
a datagram with datagrams (a long mesh reply arrives as `mesh` then `mesh_more` pieces). It sends a small datagram every
5 s, because QUIC drops a quiet session.

A template build has no `--main-pack`: export the pack with the editor (`--export-pack`), then name it after the binary
(`viewer` and `viewer.pck` in one folder).
