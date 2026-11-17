# MIT License
#
# Copyright (c) 2026-present K. S. Ernest (iFire) Lee
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

"""
HTTP/3 WebTransport transport for the broadcaster (the only network protocol Mixer speaks).

One WebTransport session per client (`CONNECT :protocol webtransport`, path `/mixer`), and one
bidirectional stream per session that carries Mixer's existing length-prefixed frames unchanged.
No `bpy`, no `mixer.*` import: this module belongs to the MIT side of the licence boundary.

Built on aioquic (BSD-3-Clause). WebTransport over HTTP/3 is an Internet-Draft; aioquic marks it experimental.
"""

import asyncio
import ssl
import struct
from typing import Awaitable, Callable, Dict, Optional

from aioquic.asyncio import QuicConnectionProtocol, connect, serve
from aioquic.asyncio.protocol import QuicStreamHandler
from aioquic.h3.connection import H3Connection
from aioquic.h3.events import H3Event, HeadersReceived, WebTransportStreamDataReceived
from aioquic.quic.configuration import QuicConfiguration
from aioquic.quic.events import ProtocolNegotiated, QuicEvent, StreamDataReceived

ALPN = ["h3"]
PATH = b"/mixer"
_LEN = struct.Struct(">I")

OnFrame = Callable[["Session", bytes], Awaitable[None]]


def frame(payload: bytes) -> bytes:
    """Length-prefix one message so that it survives QUIC stream segmentation."""
    return _LEN.pack(len(payload)) + payload


class FrameBuffer:
    """Reassemble length-prefixed frames from arbitrary chunks."""

    def __init__(self) -> None:
        self._buf = bytearray()

    def feed(self, data: bytes):
        self._buf += data
        while len(self._buf) >= _LEN.size:
            (n,) = _LEN.unpack_from(self._buf)
            if len(self._buf) < _LEN.size + n:
                return
            payload = bytes(self._buf[_LEN.size : _LEN.size + n])
            del self._buf[: _LEN.size + n]
            yield payload


class Session:
    """One WebTransport session: send frames, receive frames."""

    def __init__(self, protocol: "_Protocol", session_id: int) -> None:
        self._protocol = protocol
        self.session_id = session_id
        self._stream_id: Optional[int] = None
        self._frames = FrameBuffer()
        self.inbox: "asyncio.Queue[Optional[bytes]]" = asyncio.Queue()

    def send(self, payload: bytes) -> None:
        if self._stream_id is None:
            self._stream_id = self._protocol._http.create_webtransport_stream(self.session_id)
        self._protocol._quic.send_stream_data(self._stream_id, frame(payload))
        self._protocol.transmit()

    def _received(self, stream_id: int, data: bytes) -> None:
        self._stream_id = stream_id
        for payload in self._frames.feed(data):
            self.inbox.put_nowait(payload)

    async def recv(self) -> bytes:
        payload = await self.inbox.get()
        if payload is None:
            raise ConnectionError("session closed")
        return payload


class _Protocol(QuicConnectionProtocol):
    def __init__(self, *args, on_session=None, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self._http: Optional[H3Connection] = None
        self._sessions: Dict[int, Session] = {}
        self._on_session = on_session
        self._wt_ready: "asyncio.Future[Session]" = asyncio.get_event_loop().create_future()

    def quic_event_received(self, event: QuicEvent) -> None:
        super().quic_event_received(event)  # base class completes wait_connected() on HandshakeCompleted
        if isinstance(event, ProtocolNegotiated):
            self._http = H3Connection(self._quic, enable_webtransport=True)
        if isinstance(event, StreamDataReceived):
            # data on a stream WE opened inside a session carries no WebTransport header: the HTTP/3 layer would
            # misparse it, so route it to the session that owns the stream before HTTP/3 sees it
            for session in self._sessions.values():
                if session._stream_id == event.stream_id:
                    session._received(event.stream_id, event.data)
                    return
        if self._http is not None:
            for h3_event in self._http.handle_event(event):
                self._h3_event(h3_event)

    def _h3_event(self, event: H3Event) -> None:
        if isinstance(event, HeadersReceived):
            headers = dict(event.headers)
            if headers.get(b":method") == b"CONNECT" and headers.get(b":protocol") == b"webtransport":
                # server side: accept the session
                session = Session(self, event.stream_id)
                self._sessions[event.stream_id] = session
                self._http.send_headers(
                    event.stream_id, [(b":status", b"200"), (b"sec-webtransport-http3-draft", b"draft02")]
                )
                self.transmit()
                if self._on_session is not None:
                    asyncio.ensure_future(self._on_session(session))
            elif headers.get(b":status") == b"200" and event.stream_id in self._sessions:
                # client side: session accepted
                if not self._wt_ready.done():
                    self._wt_ready.set_result(self._sessions[event.stream_id])
        elif isinstance(event, WebTransportStreamDataReceived):
            session = self._sessions.get(event.session_id)
            if session is not None:
                session._received(event.stream_id, event.data)

    async def open_session(self, authority: str) -> Session:
        if self._http is None:
            raise ConnectionError(f"HTTP/3 not negotiated (ALPN {self._quic.configuration.alpn_protocols})")
        stream_id = self._quic.get_next_available_stream_id()
        session = Session(self, stream_id)
        self._sessions[stream_id] = session
        self._http.send_headers(
            stream_id,
            [
                (b":method", b"CONNECT"),
                (b":scheme", b"https"),
                (b":authority", authority.encode()),
                (b":path", PATH),
                (b":protocol", b"webtransport"),
                (b"sec-webtransport-http3-draft02", b"1"),
            ],
        )
        self.transmit()
        return await asyncio.wait_for(self._wt_ready, 10)


async def serve_wt(
    host: str, port: int, certificate: str, private_key: str, on_session: Callable[[Session], Awaitable[None]]
):
    """Start a WebTransport server. `on_session` runs once per accepted client session."""
    config = QuicConfiguration(is_client=False, alpn_protocols=ALPN, max_datagram_frame_size=65536)
    config.load_cert_chain(certificate, private_key)
    return await serve(
        host,
        port,
        configuration=config,
        create_protocol=lambda *a, **k: _Protocol(*a, on_session=on_session, **k),
    )


class connect_wt:
    """`async with connect_wt(host, port, ca_cert=...) as session:` (certificate pinned by file, no CERT_NONE)."""

    def __init__(self, host: str, port: int, ca_cert: str) -> None:
        self._host, self._port = host, port
        self._config = QuicConfiguration(is_client=True, alpn_protocols=ALPN, max_datagram_frame_size=65536)
        self._config.load_verify_locations(ca_cert)
        self._config.server_name = "localhost"  # name in the pinned certificate
        self._ctx = None

    async def __aenter__(self) -> Session:
        self._ctx = connect(
            self._host,
            self._port,
            configuration=self._config,
            create_protocol=_Protocol,
        )
        protocol = await self._ctx.__aenter__()
        await protocol.wait_connected()
        return await protocol.open_session(f"{self._host}:{self._port}")

    async def __aexit__(self, *exc) -> None:
        await self._ctx.__aexit__(*exc)
