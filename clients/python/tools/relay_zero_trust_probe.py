# MIT. Zero-trust probe: attack a running relay over real HTTP/3 WebTransport and report what got through.
#   python relay_zero_trust_probe.py PORT CERT_PEM [--room NAME]
# Environment: MB_ROOT_KEY (the relay's root key, hex) and MB_TP_KEY (the minter's third-party key, hex) are
# needed only to mint genuine tokens; the relay itself never sees MB_TP_KEY. MIXER_BROADCASTER is the checkout
# whose Token module mints. Exit status 0 means every attack was refused and the honest players got in.
import asyncio
import base64
import hashlib
import json
import os
import subprocess
import sys
import time

from aioquic.asyncio import QuicConnectionProtocol, connect
from aioquic.h3.connection import H3_ALPN, H3Connection
from aioquic.h3.events import DatagramReceived, HeadersReceived, WebTransportStreamDataReceived
from aioquic.quic.configuration import QuicConfiguration
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

BROADCASTER = os.environ.get(
    "MIXER_BROADCASTER",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."),
)


def b64(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def gen_key():
    priv = ec.generate_private_key(ec.SECP256R1())
    return priv, priv.public_key().public_bytes(Encoding.X962, PublicFormat.UncompressedPoint)


def sign(priv, room, nonce):
    msg = b"mixer-relay-v1" + len(room.encode()).to_bytes(2, "big") + room.encode() + nonce
    r, s = decode_dss_signature(priv.sign(msg, ec.ECDSA(hashes.SHA256())))
    return r.to_bytes(32, "big") + s.to_bytes(32, "big")


def mint(room, pub, ttl=3600, now_offset=0):
    """A genuine token for this room and this key, made by the Elixir Token module, as the minter would."""
    code = (
        'root = Base.decode16!(System.fetch_env!("MB_ROOT_KEY"), case: :mixed)\n'
        'tp = Base.decode16!(System.fetch_env!("MB_TP_KEY"), case: :mixed)\n'
        'room = System.fetch_env!("PROBE_ROOM")\n'
        'thumb = Base.decode16!(System.fetch_env!("PROBE_THUMB"), case: :lower)\n'
        't = MixerBroadcaster.Token.issue(root, room, "minter", tp)\n'
        'now = System.os_time(:second) + String.to_integer(System.fetch_env!("PROBE_NOW_OFFSET"))\n'
        '{:ok, full} = MixerBroadcaster.Token.discharge(t, tp, thumb, String.to_integer(System.fetch_env!("PROBE_TTL")), now)\n'
        'IO.puts("TOKEN " <> Base.url_encode64(full, padding: false))\n'
    )
    env = dict(
        os.environ,
        PROBE_ROOM=room,
        PROBE_THUMB=hashlib.sha256(pub).hexdigest(),
        PROBE_TTL=str(ttl),
        PROBE_NOW_OFFSET=str(now_offset),
        MIX_ENV="dev",
    )
    out = subprocess.run(
        ["mix", "run", "--no-start", "-e", code], cwd=BROADCASTER, env=env, capture_output=True, text=True
    )
    for line in out.stdout.splitlines():
        if line.startswith("TOKEN "):
            return line[6:]
    raise RuntimeError("mint failed: " + out.stderr[-300:])


class Hub(QuicConnectionProtocol):
    def __init__(self, *a, **k):
        super().__init__(*a, **k)
        self.h3 = H3Connection(self._quic, enable_webtransport=True)
        self.ready = asyncio.get_event_loop().create_future()
        self.replies = {}
        self.heard = []

    def quic_event_received(self, event):
        for e in self.h3.handle_event(event):
            if isinstance(e, HeadersReceived) and dict(e.headers).get(b":status") == b"200" and not self.ready.done():
                self.ready.set_result(e.stream_id)
            elif isinstance(e, WebTransportStreamDataReceived):
                self.replies[e.stream_id] = self.replies.get(e.stream_id, b"") + e.data
            elif isinstance(e, DatagramReceived):
                self.heard.append(e.data)

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

    async def ask(self, obj):
        sid = self.h3.create_webtransport_stream(self.session)
        self._quic.send_stream_data(sid, json.dumps(obj).encode(), end_stream=True)
        self.transmit()
        for _ in range(80):
            await asyncio.sleep(0.05)
            if sid in self.replies:
                return json.loads(self.replies[sid])
        return None


class Session:
    def __init__(self, port, cert, room, insecure):
        self.port, self.cert, self.room, self.insecure = port, cert, room, insecure

    async def __aenter__(self):
        import ssl

        cfg = QuicConfiguration(is_client=True, alpn_protocols=H3_ALPN, max_datagram_frame_size=65536)
        if self.insecure:
            cfg.verify_mode = ssl.CERT_NONE
        else:
            cfg.load_verify_locations(self.cert)
        cfg.server_name = "localhost"
        self.ctx = connect("127.0.0.1", self.port, configuration=cfg, create_protocol=Hub)
        self.hub = await self.ctx.__aenter__()
        await self.hub.wait_connected()
        await self.hub.open("127.0.0.1", self.port, self.room)
        return self.hub

    async def __aexit__(self, *a):
        await self.ctx.__aexit__(*a)


async def challenge(hub):
    r = await hub.ask({"t": "hello"})
    if not r or r.get("t") != "challenge":
        return None
    return base64.urlsafe_b64decode(r["nonce"] + "==")


async def login(hub, room, token, pub, priv):
    nonce = await challenge(hub)
    if nonce is None:
        return {"t": "no-challenge"}
    return await hub.ask({"t": "auth", "token": token, "key": b64(pub), "sig": b64(sign(priv, room, nonce))})


async def main(port, cert, room, insecure):
    results = []

    def record(name, ok, detail=""):
        results.append(ok)
        print(("PASS " if ok else "FAIL ") + name + (("  (" + detail + ")") if detail else ""), flush=True)

    S = lambda r=room: Session(port, cert, r, insecure)
    k1, k2, k3 = gen_key(), gen_key(), gen_key()
    tok1, tok2 = mint(room, k1[1]), mint(room, k2[1])

    # 1. a stranger who never logs in is refused whatever he sends
    async with S() as h:
        r = await h.ask({"t": "set", "id": 1, "rgb": [1, 2, 3]})
        record("A  stranger's set is refused", bool(r) and r.get("t") == "error", str(r))

    # 2. honest players get in, and an unadmitted listener in the same room hears nothing
    async with S() as p1, S() as p2, S() as lurker:
        await challenge(lurker)  # the lurker says hello and waits, admitted by nobody
        r1 = await login(p1, room, tok1, k1[1], k1[0])
        r2 = await login(p2, room, tok2, k2[1], k2[0])
        record("B  honest player 1 admitted", bool(r1) and r1.get("t") == "ready", str(r1))
        record("B  honest player 2 admitted", bool(r2) and r2.get("t") == "ready", str(r2))
        ack = await p1.ask({"t": "set", "id": 7, "rgb": [9, 8, 7]})
        await asyncio.sleep(0.6)
        record("B  admitted set is acknowledged", bool(ack) and ack.get("t") == "ok", str(ack))
        record(
            "B  the other admitted player hears it", any(b'"set"' in d for d in p2.heard), f"{len(p2.heard)} datagrams"
        )
        record("B  the unadmitted listener hears nothing", len(lurker.heard) == 0, f"{len(lurker.heard)} datagrams")

    # 3. a forged token
    async with S() as h:
        r = await login(h, room, b64(os.urandom(120)), k3[1], k3[0])
        record("C  a forged token is denied", bool(r) and r.get("reason") == "denied", str(r))

    # 4. a genuine token, but the signature is from another key (no proof of possession)
    async with S() as h:
        r = await login(h, room, tok1, k1[1], k3[0])
        record("D  a stolen token without its key is denied", bool(r) and r.get("reason") == "denied", str(r))

    # 5. a genuine token for another room
    other = mint(room + "-other", k1[1])
    async with S() as h:
        r = await login(h, room, other, k1[1], k1[0])
        record("E  a token for another room is denied", bool(r) and r.get("reason") == "denied", str(r))

    # 6. an expired token
    old = mint(room, k1[1], ttl=60, now_offset=-7200)
    async with S() as h:
        r = await login(h, room, old, k1[1], k1[0])
        record("F  an expired token is denied", bool(r) and r.get("reason") == "denied", str(r))

    # 7. a recorded login replayed on a new connection (a new nonce, so the old signature is worthless)
    async with S() as h1:
        nonce = await challenge(h1)
        if nonce is None:
            record(
                "G  a replayed login is denied",
                False,
                "the relay issued no challenge, so there is no door to replay against",
            )
        else:
            sig = b64(sign(k1[0], room, nonce))
            async with S() as h2:
                await challenge(h2)
                r = await h2.ask({"t": "auth", "token": tok1, "key": b64(k1[1]), "sig": sig})
                record("G  a replayed login is denied", bool(r) and r.get("reason") == "denied", str(r))

    # 8. three failures lock the session even for the right credentials
    async with S() as h:
        for _ in range(3):
            await login(h, room, b64(os.urandom(120)), k3[1], k3[0])
        r = await h.ask({"t": "hello"})
        r2 = await login(h, room, tok1, k1[1], k1[0])
        record(
            "H  three failures lock the session",
            bool(r) and r.get("reason") == "locked" and r2.get("t") != "ready",
            f"{r} / {r2}",
        )

    # 9. a 100-byte packet from a stranger goes nowhere
    async with S() as stranger, S() as p2:
        await login(p2, room, mint(room, k2[1]), k2[1], k2[0])
        stranger.h3.send_datagram(stranger.session, bytes(98) + b"\x00\x00")
        stranger.transmit()
        await asyncio.sleep(0.6)
        record(
            "I  a stranger's packet is not forwarded",
            not any(len(d) == 100 for d in p2.heard),
            f"{len(p2.heard)} datagrams",
        )

    bad = results.count(False)
    print(
        f"{len(results) - bad} of {len(results)} checks as expected" + ("" if not bad else f"  --  {bad} FAILED"),
        flush=True,
    )
    return 1 if bad else 0


argv = sys.argv[1:]
room = argv[argv.index("--room") + 1] if "--room" in argv else "zt-" + hashlib.sha256(os.urandom(8)).hexdigest()[:8]
sys.exit(asyncio.run(main(int(argv[0]), argv[1], room, "--insecure" in argv)))
