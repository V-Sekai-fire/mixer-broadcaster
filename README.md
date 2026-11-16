# mixer-broadcaster

The broadcaster for [Mixer](https://github.com/V-Sekai-fire/mixer), in Elixir. **HTTP/3 WebTransport is the only network protocol.**

This repository is MIT. It never imports `bpy` or any GPL code: the Blender add-on (GPLv3) lives in its own repository
and talks to this server over WebTransport only, the same split Adobe uses for its Substance add-on and Integration Tools.
The wire design descends from Ubisoft's MIT broadcaster (`mixer/broadcaster`), see `LICENSE`.

Transport semantics match entities-godot `WebTransportPeer`: unreliable packets are QUIC datagrams, each reliable packet
is its own bidirectional stream sent with FIN.

## Status

Increment 1 (transport): echo server and client, property-tested. Rooms and fan-out are next.

```
mix deps.get
mix test      # StreamData properties against a real QUIC listener on loopback
```

Tests use property testing only (StreamData): GOLDEN fixed packets, INVARIANT any packets come back byte for byte,
CONTROL a silent client receives nothing and a client pinned to the wrong certificate cannot connect.
`mix test` also scans `lib/` for `try`/`rescue`/`catch`/`throw` with a planted control.

Built on [`webtransport`](https://hex.pm/packages/webtransport) (Apache-2.0, pure Erlang QUIC and HTTP/3, no Rust or C).
