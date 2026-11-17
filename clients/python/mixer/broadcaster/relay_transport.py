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
What `Client` talks to when it is pointed at the relay instead of the Python server: the same two calls its socket
had (`write` one command, `read_all` the commands that came in), over `relay.RelayClient` (HTTP/3 WebTransport) run on
a thread of its own, since the host application's own thread must never wait on the network.

Poses (`ENTITY_STATE`) go out as datagrams and come back as datagrams; every other command is a 100-byte packet.
`credentials()` returns `(token, public_key, sign)`; the key stays wherever that function keeps it.
"""

import asyncio
import logging
import queue
import threading
from typing import TYPE_CHECKING, Callable, List, Optional, Tuple

KEEPALIVE_SECONDS = 5.0

from mixer.broadcaster import common
from mixer.broadcaster.common import MessageType

if TYPE_CHECKING:
    from mixer.broadcaster.relay import RelayClient

logger = logging.getLogger(__name__)

Credentials = Callable[[], Tuple[bytes, bytes, Callable[[bytes], bytes]]]


class RelayTransport:
    def __init__(self, host: str, port: int, cafile: str, credentials: Optional[Credentials]) -> None:
        self.host, self.port, self.cafile, self.credentials = host, port, cafile, credentials
        self._loop: Optional[asyncio.AbstractEventLoop] = None
        self._thread: Optional[threading.Thread] = None
        self._client: Optional["RelayClient"] = None
        self._incoming: "queue.Queue[common.Command]" = queue.Queue()
        self._started = threading.Event()
        self._error: Optional[BaseException] = None
        self._stop: Optional["asyncio.Future[None]"] = None

    # ---- life ----

    def start(self, timeout: float = 20.0) -> None:
        self._thread = threading.Thread(target=self._run, name="mixer-relay", daemon=True)
        self._thread.start()
        if not self._started.wait(timeout) or self._error is not None:
            raise ConnectionError(f"could not join the relay at {self.host}:{self.port}: {self._error}")

    def _run(self) -> None:
        loop = asyncio.new_event_loop()
        self._loop = loop
        asyncio.set_event_loop(loop)
        try:
            loop.run_until_complete(self._main(loop))
        except BaseException as e:  # reported to start(), or logged if it happens later
            self._error = e
            logger.error("relay transport stopped: %s", e)
        finally:
            self._started.set()
            loop.close()

    async def _main(self, loop: asyncio.AbstractEventLoop) -> None:
        from mixer.broadcaster.relay import open_relay

        stop: "asyncio.Future[None]" = loop.create_future()
        self._stop = stop
        async with open_relay(self.host, self.port, self.cafile) as client:
            self._client = client
            if self.credentials is not None:
                token, pub, sign = await loop.run_in_executor(None, self.credentials)
                await client.login(token, pub, sign)
            self._started.set()
            pumps = [
                asyncio.ensure_future(self._pump_commands(client)),
                asyncio.ensure_future(self._pump_poses(client)),
                asyncio.ensure_future(self._keepalive(client)),
            ]
            await stop
            for p in pumps:
                p.cancel()
            await asyncio.gather(*pumps, return_exceptions=True)

    async def _pump_commands(self, client: "RelayClient") -> None:
        while True:
            t, _owner, data = await client.commands.get()
            try:
                self._incoming.put(common.Command(MessageType(t), data))
            except ValueError:  # a type this build does not know: dropped, as the Python server's clients drop it
                logger.warning("unknown command type %s dropped", t)

    async def _keepalive(self, client: "RelayClient") -> None:
        """QUIC closes a quiet session (the relay's idle timeout), and an editor is quiet between edits: ping every few
        seconds so the session is still there when the next move comes."""
        uid = 0
        while True:
            await asyncio.sleep(KEEPALIVE_SECONDS)
            uid += 1
            client.send_keepalive(uid)

    async def _pump_poses(self, client: "RelayClient") -> None:
        while True:
            self._incoming.put(common.Command(MessageType.ENTITY_STATE, await client.poses.get()))

    def close(self) -> None:
        if self._loop is not None and self._stop is not None and not self._stop.done():
            self._loop.call_soon_threadsafe(self._stop.set_result, None)
        if self._thread is not None:
            self._thread.join(5)

    # ---- the socket's two calls ----

    def write(self, command: common.Command) -> None:
        if self._client is None or self._loop is None:
            raise common.ClientDisconnectedException()
        t, data = int(command.type), command.data
        if t == MessageType.ENTITY_STATE:
            self._loop.call_soon_threadsafe(self._client.send_pose, data)
        else:
            self._loop.call_soon_threadsafe(self._client.send_command, t, data)

    def read_all(self) -> List[common.Command]:
        if self._error is not None and self._incoming.empty():
            raise common.ClientDisconnectedException()
        out = []
        while True:
            try:
                out.append(self._incoming.get_nowait())
            except queue.Empty:
                return out
