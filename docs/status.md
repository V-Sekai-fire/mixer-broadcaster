# Status

Increment 1 (transport): echo server and client, property-tested. Rooms and fan-out are next.

```
mix deps.get
mix test      # StreamData properties against a real QUIC listener on loopback
```

Tests use property testing only (StreamData): GOLDEN fixed packets, INVARIANT any packets come back byte for byte,
CONTROL a silent client receives nothing and a client pinned to the wrong certificate cannot connect.
`mix test` also scans `lib/` for `try`/`rescue`/`catch`/`throw` with a planted control.

Built on [`webtransport`](https://hex.pm/packages/webtransport) (Apache-2.0, pure Erlang QUIC and HTTP/3, no Rust or C).
