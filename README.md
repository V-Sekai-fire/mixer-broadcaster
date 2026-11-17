# mixer-broadcaster

The broadcaster for [Mixer](https://github.com/V-Sekai-fire/mixer), in Elixir. **HTTP/3 WebTransport is the only network protocol.**

This repository works only with MIT, Apache, BSD and MPL-2.0 licensed engines and libraries. The GPL Blender add-on that used the earlier broadcaster is archived in V-Sekai-fire/mixer and is not part of this project.

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

## Interface

`spec/asyncapi.yaml` is the whole interface of the relay as one AsyncAPI 3.1 document: the room hub, the command
protocol (every command's type number and data layout, in `x-wire`), the demo's HTTP routes, the echo handler, the
errors and the environment variables. `mix test` holds the real relay to it in both directions, with the blob store
mocked by Mox. Validate it with `npx @asyncapi/cli validate spec/asyncapi.yaml`.

## Python reference client

`clients/python` is a client of the relay in plain Python (MIT) with Hypothesis tests and probe tools; see
`clients/python/README.md`.

## Coordinate frames

The wire has one frame (right-handed, X right, Y up, -Z forward, metres) and the relay never converts. A client in another
frame converts at its own edge; see `docs/frames.md`.

## Licences

The relay works with MIT, Apache, BSD and MPL-2.0 licensed engines and libraries only: its own code is MIT, the viewers use
three.js and Godot (MIT), and `test/licence_gate_test.exs` fails if a dependency in `mix.lock` has any other licence.
