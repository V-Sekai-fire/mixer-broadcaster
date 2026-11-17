# MIT License. Probe: can an aioquic client (the client library) talk to the Elixir hub?
# Protocol: CONNECT /room/<name>; each reliable message is its own bidi stream sent with FIN; hub answers on
# the same stream and fans out to the other sessions of the room as datagrams.
import asyncio
import json
import ssl
import sys

from aioquic.asyncio import QuicConnectionProtocol, connect
from aioquic.h3.connection import H3_ALPN, H3Connection
from aioquic.h3.events import DatagramReceived, HeadersReceived, WebTransportStreamDataReceived
from aioquic.quic.configuration import QuicConfiguration


class Hub(QuicConnectionProtocol):
    def __init__(self, *a, **k):
        super().__init__(*a, **k)
        self.h3 = H3Connection(self._quic, enable_webtransport=True)
        self.session = None
        self.ready = asyncio.get_event_loop().create_future()
        self.replies = {}  # stream id -> bytes
        self.datagrams = asyncio.Queue()

    def quic_event_received(self, event):
        for e in self.h3.handle_event(event):
            if isinstance(e, HeadersReceived) and dict(e.headers).get(b":status") == b"200":
                if not self.ready.done():
                    self.ready.set_result(e.stream_id)
            elif isinstance(e, WebTransportStreamDataReceived):
                self.replies[e.stream_id] = self.replies.get(e.stream_id, b"") + e.data
            elif isinstance(e, DatagramReceived):
                self.datagrams.put_nowait(json.loads(e.data))

    async def open(self, host, port, room):
        sid = self._quic.get_next_available_stream_id()
        self.h3.send_headers(
            sid,
            [
                (b":method", b"CONNECT"),
                (b":scheme", b"https"),
                (b":authority", f"{host}:{port}".encode()),
                (b":path", f"/room/{room}".encode()),
                (b":protocol", b"webtransport"),
                (b"sec-webtransport-http3-draft02", b"1"),
            ],
        )
        self.transmit()
        self.session = await asyncio.wait_for(self.ready, 8)

    async def send(self, obj):
        sid = self.h3.create_webtransport_stream(self.session)
        self._quic.send_stream_data(sid, json.dumps(obj).encode(), end_stream=True)
        self.transmit()
        for _ in range(60):
            await asyncio.sleep(0.05)
            if sid in self.replies:
                return json.loads(self.replies[sid])
        return None


async def client(host, port, cafile, room):
    cfg = QuicConfiguration(is_client=True, alpn_protocols=H3_ALPN, max_datagram_frame_size=65536)
    cfg.load_verify_locations(cafile)
    cfg.server_name = "localhost"
    ctx = connect(host, port, configuration=cfg, create_protocol=Hub)
    proto = await ctx.__aenter__()
    await proto.wait_connected()
    await proto.open(host, port, room)
    return ctx, proto


async def main(port, cafile):
    ctxa, a = await client("127.0.0.1", port, cafile, "probe")
    hello = await a.send({"t": "hello"})
    print("A hello ->", (hello or {}).get("t"), "(snapshot arrives as a datagram)", flush=True)
    try:
        snap = await asyncio.wait_for(a.datagrams.get(), 3)
        print(
            "A snapshot datagram: patches =", len(snap.get("patches", [])), "patch0 =", snap["patches"][0], flush=True
        )
    except asyncio.TimeoutError:
        print("A got no snapshot datagram", flush=True)
    ctxb, b = await client("127.0.0.1", port, cafile, "probe")
    ack = await b.send({"t": "set", "id": 3, "rgb": [9, 8, 7]})
    print("B set ->", ack, flush=True)
    try:
        got = await asyncio.wait_for(a.datagrams.get(), 3)
        print("A received from B:", got, flush=True)
    except asyncio.TimeoutError:
        print("A received nothing from B", flush=True)
    await ctxb.__aexit__(None, None, None)
    await ctxa.__aexit__(None, None, None)


asyncio.run(main(int(sys.argv[1]), sys.argv[2]))
