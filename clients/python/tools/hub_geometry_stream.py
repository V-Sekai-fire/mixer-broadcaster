# MIT. A client streams geometry through the relay.
# 1. Build meshes (a tetrahedron and Suzanne, every face one patch of the 24-patch chart).
# 2. Write each as .usda, chunk it with desync into the SeaweedFS chunk store, put the index beside it.
# 3. Stream 100-byte entity packets (contract-entity-packet) over WebTransport datagrams: the packet carries the
#    pose (position orbit, twist about +Y) and, in its payload, the SHA-256 of the desync index.
#   python hub_geometry_stream.py PORT CERT ROOM GEODIR [--seconds N] [--hz 64]
import asyncio
import hashlib
import json
import math
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request

sys.path.insert(0, os.path.dirname(__file__))
import zt
from xr_grid_entity_packet import Packet, encode  # emitted from contract-entity-packet, never edited

from aioquic.asyncio import QuicConnectionProtocol, connect
from aioquic.h3.connection import H3_ALPN, H3Connection
from aioquic.h3.events import HeadersReceived
from aioquic.quic.configuration import QuicConfiguration

FILER = "http://127.0.0.1:8888"


def hlc_send(state, pt_ms):
    """The traditional rule for a local or send event; state is (l, c)."""
    l0, c0 = state
    l = max(l0, pt_ms)
    c = c0 + 1 if l == l0 else 0
    if c > 0xFFFF:
        raise OverflowError("hlc counter full")
    return (l, c)


def publish(geodir, name):
    """desync make into the filer chunk store, then put the index under its own SHA-256. Returns the digest."""
    idx = f"{geodir}/{name}.caibx"
    subprocess.run(
        [f"{geodir}/desync", "make", "-s", f"{FILER}/chunks", idx, f"{geodir}/usd/{name}.usda"],
        check=True,
        capture_output=True,
    )
    data = open(idx, "rb").read()
    digest = hashlib.sha256(data).digest()
    req = urllib.request.Request(f"{FILER}/index/{digest.hex()}.caibx", data=data, method="PUT")
    urllib.request.urlopen(req).read()
    pub = os.path.join(tempfile.gettempdir(), "mixer_geo_usd")  # the demo page's copy, named by the same digest
    os.makedirs(pub, exist_ok=True)
    shutil.copy(f"{geodir}/usd/{name}.usda", os.path.join(pub, digest.hex() + ".usda"))
    return digest


class Hub(zt.ZTHub, QuicConnectionProtocol):
    def __init__(self, *a, **k):
        super().__init__(*a, **k)
        self.zt_init()
        self.h3 = H3Connection(self._quic, enable_webtransport=True)
        self.ready = asyncio.get_event_loop().create_future()

    def quic_event_received(self, event):
        for e in self.h3.handle_event(event):
            self.zt_event(e)
            if isinstance(e, HeadersReceived) and dict(e.headers).get(b":status") == b"200" and not self.ready.done():
                self.ready.set_result(e.stream_id)

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

    def datagram(self, data):
        self.h3.send_datagram(self.session, data)
        self.transmit()


async def main(port, cert, room, geodir, seconds, hz):
    entities = []
    shapes = [("chart", 0.0, 0.0)] if "--chart" in sys.argv else [("monkey", 3.0, 0.5), ("tet", 2.0, 1.0)]
    for gid, (name, radius, turns) in enumerate(shapes, start=1):
        d = publish(geodir, name)
        entities.append((gid, name, d, radius, turns))
        print(f"SENDER published {name}: index sha256 {d.hex()[:16]}...", flush=True)
    cfg = QuicConfiguration(is_client=True, alpn_protocols=H3_ALPN, max_datagram_frame_size=65536)
    cfg.load_verify_locations(cert)
    cfg.server_name = "localhost"
    async with connect("127.0.0.1", port, configuration=cfg, create_protocol=Hub) as hub:
        await hub.wait_connected()
        await hub.open("127.0.0.1", port, room)
        if not os.environ.get("MB_ZT_MINTER"):
            sys.exit("no MB_ZT_MINTER: tests join the closed relay (tools/zt_stack.py), never the open demo")
        await zt.admit(hub, room)
        print("SENDER admitted by the relay", flush=True)
        clock, sent, t0 = (0, 0), 0, time.time()
        while time.time() - t0 < seconds:
            t = time.time() - t0
            for gid, name, digest, radius, turns in entities:
                clock = hlc_send(clock, int(time.time() * 1000))
                ang = 2 * math.pi * turns * t / 4.0
                twist = int(round(ang * 65536 / (2 * math.pi)))
                twist = ((twist + 32768) % 65536) - 32768  # circular: pi and -pi are one code
                orbit = 2 * math.pi * 0.1 * t
                p = Packet(
                    gid=gid,
                    pos_um_x=int(radius * 1e6 * math.cos(orbit + gid)),
                    pos_um_y=0,
                    pos_um_z=int(radius * 1e6 * math.sin(orbit + gid)),
                    hlc=(clock[0] << 16) | clock[1],
                    class_owner=(1 << 24) | 1,
                    sub_index=0,
                    swing_x=0,
                    swing_z=0,
                    twist=twist,
                    payload=digest + bytes(4),
                )
                hub.datagram(encode(p))
                sent += 1
            await asyncio.sleep(1.0 / hz)
        await asyncio.sleep(0.3)
        print(f"SENDER streamed {sent} packets ({sent * 100} bytes) in {time.time() - t0:.1f} s", flush=True)


argv = sys.argv[1:]
seconds = float(argv[argv.index("--seconds") + 1]) if "--seconds" in argv else 6
hz = float(argv[argv.index("--hz") + 1]) if "--hz" in argv else 64
asyncio.run(main(int(argv[0]), argv[1], argv[2], argv[3], seconds, hz))
