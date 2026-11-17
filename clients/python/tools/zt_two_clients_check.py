# Two admitted clients and one outsider, all against the closed relay (tools/zt_stack.py).
# The sender is tools/hub_geometry_stream.py; the listener is admitted; the outsider joins the room but never logs in.
# Exit 0 only if the listener heard the sender and the outsider heard nothing.
import asyncio, os, subprocess, sys, time

sys.path.insert(0, os.path.dirname(__file__))
import zt
from aioquic.asyncio import QuicConnectionProtocol, connect
from aioquic.h3.connection import H3_ALPN, H3Connection
from aioquic.h3.events import DatagramReceived, HeadersReceived
from aioquic.quic.configuration import QuicConfiguration

PORT, CERT, ROOM = int(os.environ["MB_PORT"]), os.environ["MB_CERT"], sys.argv[1] if len(sys.argv) > 1 else "zt2"
GEO = os.path.expanduser("~/.hermes/cache/scratch/geo")


class Hub(zt.ZTHub, QuicConnectionProtocol):
    def __init__(self, *a, **k):
        super().__init__(*a, **k)
        self.zt_init()
        self.h3 = H3Connection(self._quic, enable_webtransport=True)
        self.ready = asyncio.get_event_loop().create_future()
        self.got = []

    def quic_event_received(self, event):
        for e in self.h3.handle_event(event):
            self.zt_event(e)
            if isinstance(e, HeadersReceived) and dict(e.headers).get(b":status") == b"200" and not self.ready.done():
                self.ready.set_result(e.stream_id)
            elif isinstance(e, DatagramReceived):
                self.got.append(e.data)

    async def open(self, room):
        sid = self._quic.get_next_available_stream_id()
        self.h3.send_headers(
            sid,
            [
                (b":method", b"CONNECT"),
                (b":scheme", b"https"),
                (b":authority", f"127.0.0.1:{PORT}".encode()),
                (b":path", f"/room/{room}".encode()),
                (b":protocol", b"webtransport"),
                (b"sec-webtransport-http3-draft02", b"1"),
            ],
        )
        self.transmit()
        self.session = await asyncio.wait_for(self.ready, 8)


def cfg():
    c = QuicConfiguration(is_client=True, alpn_protocols=H3_ALPN, max_datagram_frame_size=65536)
    c.load_verify_locations(CERT)
    c.server_name = "localhost"
    return c


async def main():
    async with connect("127.0.0.1", PORT, configuration=cfg(), create_protocol=Hub) as listener, connect(
        "127.0.0.1", PORT, configuration=cfg(), create_protocol=Hub
    ) as outsider:
        await listener.wait_connected()
        await outsider.wait_connected()
        await listener.open(ROOM)
        await outsider.open(ROOM)
        await zt.admit(listener, ROOM)
        print("listener admitted; the outsider stays logged out", flush=True)
        sender = subprocess.Popen(
            [
                sys.executable,
                os.path.join(os.path.dirname(__file__), "hub_geometry_stream.py"),
                str(PORT),
                CERT,
                ROOM,
                GEO,
                "--seconds",
                "5",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        await asyncio.sleep(9)
        out = sender.communicate()[0]
        admitted = "admitted by the relay" in out
        streamed = [l for l in out.splitlines() if "streamed" in l]
        heard = sum(1 for d in listener.got if len(d) == 100)
        outsider_heard = len(outsider.got)
        print(f"sender admitted={admitted}; {streamed[0] if streamed else 'no stream line'}")
        print(f"listener heard {heard} packets; outsider heard {outsider_heard}")
        ok = admitted and heard > 100 and outsider_heard == 0
        print("PASS" if ok else "FAIL")
        sys.exit(0 if ok else 1)


asyncio.run(main())
