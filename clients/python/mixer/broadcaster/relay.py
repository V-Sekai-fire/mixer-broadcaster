# MIT License
#
# Copyright (c) 2026-present K. S. Ernest (iFire) Lee
#
# Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
# documentation files (the "Software"), to deal in the Software without restriction, including without limitation the
# rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit
# persons to whom the Software is furnished to do so, subject to the following conditions:
# The above copyright notice and this permission notice shall be included in all copies or substantial portions of the
# Software.
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE
# WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
# COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
# OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

"""
A client of the relay's Mixer mode (`/mixer`). No `bpy`, no `mixer.*` import: this module is on the MIT side.

  * One WebTransport session over HTTP/3 (aioquic).
  * The first bidirectional stream carries the login as JSON (`hello`, `challenge`, `auth`). The proof is made by the
    `sign` function the caller passes in, so the key can live in a guest ELF and never in this module.
  * Commands travel as 100-byte packets on one more bidirectional stream (`entity.pack_command`). Bulk data that does not
    fit a packet goes to the chunk store (SeaweedFS S3) under its SHA-256 and the packet holds the digest.
  * Poses are 100-byte datagrams.
"""

import asyncio
from concurrent.futures import ThreadPoolExecutor
import base64
import hashlib
import json
import os
import time
import urllib.request
from typing import Any, AsyncContextManager, Awaitable, Callable, Dict, List, Optional, Tuple, cast

from aioquic.asyncio import QuicConnectionProtocol, connect
from aioquic.h3.connection import H3_ALPN, H3Connection
from aioquic.h3.events import DatagramReceived, HeadersReceived, WebTransportStreamDataReceived
from aioquic.quic.configuration import QuicConfiguration
from aioquic.quic.events import QuicEvent

from . import entity, geo_publish, s3

PATH = b"/mixer"


def _b64(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


class S3Store:
    """The chunk store: SeaweedFS's S3 gateway, objects at `<bucket>/blob/<hex digest>` named by their SHA-256.
    Keys: AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY. The same layout as the relay's `Store.S3`."""

    def __init__(self, endpoint: str = "http://127.0.0.1:8333", bucket: str = "mixer") -> None:
        self.endpoint, self.bucket = endpoint, bucket

    def put(self, data: bytes) -> bytes:
        digest = hashlib.sha256(data).digest()
        key = f"blob/{digest.hex()}"
        if not s3.exists(self.endpoint, self.bucket, key):  # named by its bytes: never written twice
            s3.put(self.endpoint, self.bucket, key, data)
        return digest

    def put_index(self, data: bytes) -> bytes:
        """Data over 16 MiB: chunked with desync as a mesh is, named by the SHA-256 of its index (env `MB_DESYNC`)."""
        desync = os.environ.get("MB_DESYNC")
        if not desync:
            raise ValueError("a command over 16 MiB needs the desync binary (set MB_DESYNC)")
        return geo_publish.publish(data, desync, self.endpoint, self.bucket)

    def get_index(self, digest: bytes) -> bytes:
        desync = os.environ.get("MB_DESYNC")
        if not desync:
            raise ValueError("a command over 16 MiB needs the desync binary (set MB_DESYNC)")
        return geo_publish.extract(digest, desync, self.endpoint, self.bucket)

    def get(self, digest: bytes) -> bytes:
        data = s3.get(self.endpoint, self.bucket, f"blob/{digest.hex()}")
        if hashlib.sha256(data).digest() != digest:
            raise ValueError("the store returned other bytes than the digest names")
        return data


class RelayClient(QuicConnectionProtocol):
    def __init__(self, *a: Any, **k: Any) -> None:
        super().__init__(*a, **k)
        self.h3 = H3Connection(self._quic, enable_webtransport=True)
        self.session: Optional[int] = None
        self.store = S3Store()
        self.owner = 0
        self._uploading = 0  # commands waiting on, or in, the upload worker
        self._worker = ThreadPoolExecutor(max_workers=1, thread_name_prefix="mixer-upload")
        self._refused: set = set()  # (type, size) of commands refused as too big, so each is reported once
        self.commands: "asyncio.Queue[Tuple[int, int, bytes]]" = asyncio.Queue()  # (type, owner, data)
        self.poses: "asyncio.Queue[bytes]" = asyncio.Queue()
        self.errors: List[str] = []
        self._ready: "asyncio.Future[int]" = asyncio.get_event_loop().create_future()
        self._replies: Dict[int, bytes] = {}
        self._packet_stream: Optional[int] = None
        self._inbuf = bytearray()
        self._hlc_counter = 0

    # ---- events ----

    def quic_event_received(self, event: QuicEvent) -> None:
        for e in self.h3.handle_event(event):
            if isinstance(e, HeadersReceived) and dict(e.headers).get(b":status") == b"200" and not self._ready.done():
                self._ready.set_result(e.stream_id)
            elif isinstance(e, DatagramReceived):
                self.poses.put_nowait(e.data)
            elif isinstance(e, WebTransportStreamDataReceived):
                if e.stream_id == self._packet_stream:
                    self._packets(e.data)
                else:
                    self._replies[e.stream_id] = self._replies.get(e.stream_id, b"") + e.data

    def _packets(self, data: bytes) -> None:
        self._inbuf += data
        while len(self._inbuf) >= entity.PACKET_SIZE:
            raw = bytes(self._inbuf[: entity.PACKET_SIZE])
            del self._inbuf[: entity.PACKET_SIZE]
            try:
                self.commands.put_nowait(entity.unpack_command(raw, self.store.get, self.store.get_index))
            except (ValueError, OSError) as err:
                self.errors.append(str(err))

    # ---- the door ----

    def _session(self) -> int:
        if self.session is None:
            raise ConnectionError("the WebTransport session is not open yet")
        return self.session

    async def _ask(self, obj: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        sid = self.h3.create_webtransport_stream(self._session())
        self._quic.send_stream_data(sid, json.dumps(obj).encode(), end_stream=True)
        self.transmit()
        for _ in range(200):
            await asyncio.sleep(0.05)
            if sid in self._replies:
                reply: Dict[str, Any] = json.loads(self._replies[sid])
                return reply
        return None

    async def login(self, token: bytes, pub: bytes, sign: Callable[[bytes], bytes]) -> None:
        """hello, challenge, auth. `sign(nonce)` returns the 64-byte r||s proof for "mixer-session-v1" + nonce."""
        ch = await self._ask({"t": "hello"})
        if not ch or ch.get("t") != "challenge":
            raise RuntimeError(f"no challenge from the relay: {ch}")
        nonce = base64.urlsafe_b64decode(ch["nonce"] + "==")
        ok = await self._ask({"t": "auth", "token": _b64(token), "key": _b64(pub), "sig": _b64(sign(nonce))})
        if not ok or ok.get("t") != "ready":
            raise RuntimeError(f"the relay refused: {ok}")

    # ---- commands and poses ----

    def _hlc(self) -> int:
        self._hlc_counter = (self._hlc_counter + 1) & 0xFFFF
        return (int(time.time() * 1000) << 16) | self._hlc_counter

    def send_command(self, command_type: int, data: bytes) -> None:
        """One Mixer command as a packet. Data over 77 bytes goes to the chunk store first, and that upload (slow, and
        capped by the uplink) runs on one worker thread, never on the network loop, so poses and animation keep flowing.
        Commands keep their order: while one is uploading, later ones wait behind it."""
        if self._packet_stream is None:
            self._packet_stream = self.h3.create_webtransport_stream(self._session())
        if len(data) <= entity.INLINE_MAX and self._uploading == 0:
            self._emit(command_type, data)
            return
        self._uploading += 1
        loop = asyncio.get_running_loop()
        hlc = self._hlc()  # stamped here, on the loop: the clock is not shared with the worker

        def work() -> None:
            try:
                raw = self._pack(command_type, data, hlc)
            except Exception as e:  # said once per type and size; the loop is not told
                loop.call_soon_threadsafe(self._refuse, command_type, len(data), e)
                raw = None
            loop.call_soon_threadsafe(self._sent, raw)

        self._worker.submit(work)

    def _pack(self, command_type: int, data: bytes, hlc: int) -> bytes:
        return entity.pack_command(command_type, data, self.owner, self.store.put, hlc, self.store.put_index)

    def _emit(self, command_type: int, data: bytes) -> None:
        try:
            raw = self._pack(command_type, data, self._hlc())
        except ValueError as e:
            self._refuse(command_type, len(data), e)
            return
        self._sent(raw, queued=False)

    def _sent(self, raw: Optional[bytes], queued: bool = True) -> None:
        if queued:
            self._uploading -= 1
        if raw is not None and self._packet_stream is not None:
            self._quic.send_stream_data(self._packet_stream, raw)
            self.transmit()

    def _refuse(self, command_type: int, size: int, e: Exception) -> None:
        key = (command_type, size)
        if key not in self._refused:
            self._refused.add(key)
            self.errors.append(f"command type {command_type}, {size / 1048576:.1f} MiB, not sent: {e}")

    def send_pose(self, packet: bytes) -> None:
        if len(packet) != entity.PACKET_SIZE:
            raise ValueError("a pose is one 100-byte packet")
        self.h3.send_datagram(self._session(), packet)
        self.transmit()

    def send_keepalive(self, uid: int) -> None:
        """A QUIC PING frame: the relay sees traffic and keeps the session."""
        self._quic.send_ping(uid)
        self.transmit()

    async def next_command(self, timeout: float = 5.0) -> Tuple[int, int, bytes]:
        return await asyncio.wait_for(self.commands.get(), timeout)

    async def next_pose(self, timeout: float = 5.0) -> bytes:
        return await asyncio.wait_for(self.poses.get(), timeout)


class open_relay:
    """`async with open_relay(host, port, cafile) as client:` opens the WebTransport session at `/mixer`."""

    def __init__(self, host: str, port: int, cafile: str, server_name: str = "localhost") -> None:
        self.host, self.port = host, port
        c = QuicConfiguration(is_client=True, alpn_protocols=H3_ALPN, max_datagram_frame_size=65536)
        c.load_verify_locations(cafile)
        c.server_name = server_name
        self._config = c
        self._ctx: Optional[AsyncContextManager[QuicConnectionProtocol]] = None

    async def __aenter__(self) -> RelayClient:
        self._ctx = connect(self.host, self.port, configuration=self._config, create_protocol=RelayClient)
        ctx = self._ctx
        client = cast(RelayClient, await ctx.__aenter__())
        await client.wait_connected()
        sid = client._quic.get_next_available_stream_id()
        client.h3.send_headers(
            sid,
            [
                (b":method", b"CONNECT"),
                (b":scheme", b"https"),
                (b":authority", f"{self.host}:{self.port}".encode()),
                (b":path", PATH),
                (b":protocol", b"webtransport"),
                (b"sec-webtransport-http3-draft02", b"1"),
            ],
        )
        client.transmit()
        client.session = await asyncio.wait_for(client._ready, 8)
        return client

    async def __aexit__(self, *exc: Any) -> None:
        if self._ctx is not None:
            await self._ctx.__aexit__(*exc)
