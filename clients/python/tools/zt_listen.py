# An admitted listener on the closed relay: prints how each entity's pose changes. Usage: zt_listen.py ROOM SECONDS
import asyncio, os, struct, sys, time

sys.path.insert(0, os.path.dirname(__file__))
import zt
from aioquic.asyncio import QuicConnectionProtocol, connect
from aioquic.h3.connection import H3_ALPN, H3Connection
from aioquic.h3.events import DatagramReceived, HeadersReceived
from aioquic.quic.configuration import QuicConfiguration

PORT, CERT = int(os.environ["MB_PORT"]), os.environ["MB_CERT"]
ROOM, SECONDS = sys.argv[1], float(sys.argv[2])


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
                self.got.append((time.time(), e.data))


async def fetch_meshes(h):
    """Ask for each mesh digest seen, then fetch what the relay presigned and check it end to end."""
    import hashlib
    import urllib.request

    import zstandard

    digests = sorted({d[62:94].hex() for _, d in h.got if len(d) == 100 and any(d[62:94])})
    print("LISTEN asking for", len(digests), "mesh(es)", flush=True)
    for dg in digests + ["00" * 32]:
        r = await h.ask({"t": "mesh", "digest": dg})
        if r is None or r.get("t") != "mesh":
            print("LISTEN mesh", dg[:8], "->", r, flush=True)
            continue
        get = lambda u: urllib.request.urlopen(u, timeout=20).read()  # noqa: E731
        index = get(r["index"])
        assert hashlib.sha256(index).hexdigest() == dg, "the index is not the one the digest names"
        ids, off = [], 48 + 16
        while index[off : off + 8] != bytes(8):
            ids.append(index[off + 8 : off + 40])
            off += 40
        assert len(ids) == len(r["chunks"])
        out = b""
        for cid, url in zip(ids, r["chunks"]):
            raw = zstandard.ZstdDecompressor().decompress(get(url), max_output_size=1 << 26)
            assert hashlib.new("sha512_256", raw).digest() == cid, "a chunk is not the one the index names"
            out += raw
        print(f"LISTEN mesh {dg[:8]} ok: {len(ids)} chunk(s), {len(out)} bytes, expires {r['expires']}s", flush=True)
        print(
            "LISTEN   " + out.decode().splitlines()[0],
            "|",
            [l for l in out.decode().splitlines() if "def Mesh" in l][0],
            flush=True,
        )
        try:
            get(r["index"].replace(dg, "0" * 64))
            print("LISTEN   ERROR: another object was readable with this signature", flush=True)
        except Exception as e:
            print("LISTEN   a signature does not open another object:", getattr(e, "code", e), flush=True)


async def main():
    c = QuicConfiguration(is_client=True, alpn_protocols=H3_ALPN, max_datagram_frame_size=65536)
    c.load_verify_locations(CERT)
    c.server_name = "localhost"
    async with connect("127.0.0.1", PORT, configuration=c, create_protocol=Hub) as h:
        await h.wait_connected()
        sid = h._quic.get_next_available_stream_id()
        h.h3.send_headers(
            sid,
            [
                (b":method", b"CONNECT"),
                (b":scheme", b"https"),
                (b":authority", f"127.0.0.1:{PORT}".encode()),
                (b":path", f"/room/{ROOM}".encode()),
                (b":protocol", b"webtransport"),
                (b"sec-webtransport-http3-draft02", b"1"),
            ],
        )
        h.transmit()
        h.session = await asyncio.wait_for(h.ready, 8)
        ops = [o for o in os.environ.get("LISTEN_OPS", "").split(",") if o]
        await zt.admit(h, ROOM, ops=ops)
        print("LISTEN admitted", "with" if ops else "without", ops, flush=True)
        await asyncio.sleep(SECONDS)
        if os.environ.get("LISTEN_MESH"):
            await fetch_meshes(h)
    seen, t0 = {}, None
    for t, d in h.got:
        if len(d) != 100:
            continue
        gid = struct.unpack_from("<I", d, 0)[0]
        pos = tuple(round(v / 1e6, 2) for v in struct.unpack_from("<3q", d, 4))
        dg = d[62:94].hex()
        if any(d[62:94]) and seen.get(("dg", gid)) != dg:
            seen[("dg", gid)] = dg
            print("LISTEN digest", dg, flush=True)
        t0 = t0 or t
        if seen.get(gid, [None])[-1] != pos:
            seen.setdefault(gid, []).append(pos)
            print(f"LISTEN t={t - t0:5.1f}s entity {gid} at {pos}", flush=True)
    print(
        f"LISTEN {sum(1 for _, d in h.got if len(d) == 100)} packets, entities {sorted(k for k in seen if isinstance(k, int))}"
    )


asyncio.run(main())
