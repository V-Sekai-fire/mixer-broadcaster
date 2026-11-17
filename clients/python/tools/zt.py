# MIT License
#
# Copyright (c) 2026-present K. S. Ernest (iFire) Lee
#
# Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
# documentation files (the "Software"), to deal in the Software without restriction. THE SOFTWARE IS PROVIDED "AS IS",
# WITHOUT WARRANTY OF ANY KIND.

"""
Zero trust for the test clients. A client holds its own key and nothing else: it asks the minter for a token bound to
its key and room, then proves it holds the key by signing the relay's nonce. It never sees the relay's root key or the
minter's third-party key. The relay is the closed one (MB_SERVE=1); there is no open mode in a test.

  MB_ZT_MINTER   http://127.0.0.1:<port>   where to get a token (set by tools/zt_stack.py)

`ZTHub` is the mixin a client's Hub class takes to read replies on bidirectional streams; `admit` runs the handshake.
"""

import asyncio
import base64
import json
import os
import urllib.request

from aioquic.h3.events import WebTransportStreamDataReceived
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat


def b64(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def gen_key():
    priv = ec.generate_private_key(ec.SECP256R1())
    return priv, priv.public_key().public_bytes(Encoding.X962, PublicFormat.UncompressedPoint)


def sign_session(priv, nonce):
    """The proof for a Mixer session: no room in it (each join is checked on its own)."""
    r, s = decode_dss_signature(priv.sign(b"mixer-session-v1" + nonce, ec.ECDSA(hashes.SHA256())))
    return r.to_bytes(32, "big") + s.to_bytes(32, "big")


def sign(priv, room, nonce):
    msg = b"mixer-relay-v1" + len(room.encode()).to_bytes(2, "big") + room.encode() + nonce
    r, s = decode_dss_signature(priv.sign(msg, ec.ECDSA(hashes.SHA256())))
    return r.to_bytes(32, "big") + s.to_bytes(32, "big")


def get_token(room, pub, ops=None):
    """`room` is one name, or a list of names for a token that covers several rooms. `ops` (such as ["read"]) asks the
    minter for those operations in the token."""
    url = os.environ["MB_ZT_MINTER"]
    field = {"rooms": list(room)} if isinstance(room, (list, tuple)) else {"room": room}
    req = urllib.request.Request(
        url + "/mint",
        data=json.dumps({**field, "key": b64(pub), **({"ops": list(ops)} if ops else {})}).encode(),
        headers={"content-type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)["token"]


class ZTHub:
    """Mixin for an aioquic Hub class: remember what comes back on streams, and ask a question on a new one."""

    def zt_init(self):
        self.replies = {}

    def zt_event(self, e):
        if isinstance(e, WebTransportStreamDataReceived):
            self.replies[e.stream_id] = self.replies.get(e.stream_id, b"") + e.data

    async def ask(self, obj):
        sid = self.h3.create_webtransport_stream(self.session)
        self._quic.send_stream_data(sid, json.dumps(obj).encode(), end_stream=True)
        self.transmit()
        for _ in range(100):
            await asyncio.sleep(0.05)
            if sid in self.replies:
                return json.loads(self.replies[sid])
        return None


async def admit(hub, room, key=None, ops=None):
    """hello, challenge, auth. Returns the key used. Raises if the relay does not say ready."""
    priv, pub = key or gen_key()
    token = await asyncio.get_event_loop().run_in_executor(None, get_token, room, pub, ops)
    ch = await hub.ask({"t": "hello"})
    if not ch or ch.get("t") != "challenge":
        raise RuntimeError(f"no challenge from the relay: {ch}")
    nonce = base64.urlsafe_b64decode(ch["nonce"] + "==")
    ok = await hub.ask({"t": "auth", "token": token, "key": b64(pub), "sig": b64(sign(priv, room, nonce))})
    if not ok or ok.get("t") != "ready":
        raise RuntimeError(f"the relay refused: {ok}")
    return priv, pub


async def admit_session(hub, rooms, key=None):
    """hello, challenge, auth for a Mixer session. `rooms` is the list the token should cover."""
    priv, pub = key or gen_key()
    token = await asyncio.get_event_loop().run_in_executor(None, get_token, list(rooms), pub)
    ch = await hub.ask({"t": "hello"})
    if not ch or ch.get("t") != "challenge":
        raise RuntimeError(f"no challenge from the relay: {ch}")
    nonce = base64.urlsafe_b64decode(ch["nonce"] + "==")
    ok = await hub.ask({"t": "auth", "token": token, "key": b64(pub), "sig": b64(sign_session(priv, nonce))})
    if not ok or ok.get("t") != "ready":
        raise RuntimeError(f"the relay refused: {ok}")
    return priv, pub
