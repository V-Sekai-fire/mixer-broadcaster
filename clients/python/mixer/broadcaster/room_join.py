# SPDX-FileCopyrightText: 2026-present K. S. Ernest (iFire) Lee
#
# SPDX-License-Identifier: MIT
"""
Join a room of the closed relay (`/room/<name>`) and read its state (issue #32).

The door, as `MixerBroadcaster.Auth` states it: the player holds a token and a P-256 key; the token names the key by its
thumbprint (SHA-256 of the 65-byte uncompressed public key, 04 || X || Y); after `hello` the relay sends a nonce and the
player signs

    "mixer-relay-v1" || room length (u16, big endian) || room || nonce

with ECDSA P-256 over SHA-256, sent as 64 bytes r || s. After `ready` the relay replays the last packet of every entity
as datagrams (three times, 250 ms apart, because a datagram can be lost), then forwards live ones. `join` listens until
the room has been quiet for `quiet` seconds and returns the room state of what it heard.

The private key here is a plain 32-byte scalar held by the caller. Enrolling through the shared guest ELF
(`mixer_auth.elf`) is a separate step; the proof this module signs is the same bytes the guest signs.
"""
import asyncio
import hashlib
import time

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

from . import entity
from .relay import open_relay
from .room_state import RoomState

_CURVE = ec.SECP256R1()


def private_key(scalar: bytes) -> ec.EllipticCurvePrivateKey:
    if len(scalar) != 32:
        raise ValueError("a P-256 private key is a 32-byte scalar")
    return ec.derive_private_key(int.from_bytes(scalar, "big"), _CURVE)


def public_key(key: ec.EllipticCurvePrivateKey) -> bytes:
    """65 bytes: 04 || X || Y."""
    return key.public_key().public_bytes(Encoding.X962, PublicFormat.UncompressedPoint)


def thumbprint(pub: bytes) -> bytes:
    if len(pub) != 65 or pub[0] != 4:
        raise ValueError("a public key is 65 bytes, 04 || X || Y")
    return hashlib.sha256(pub).digest()


def room_message(room: str, nonce: bytes) -> bytes:
    name = room.encode()
    if len(nonce) != 32 or len(name) > 0xFFFF:
        raise ValueError("a nonce is 32 bytes and a room name fits 16 bits")
    return b"mixer-relay-v1" + len(name).to_bytes(2, "big") + name + nonce


def sign_room(key: ec.EllipticCurvePrivateKey, room: str, nonce: bytes) -> bytes:
    """The proof for a room: 64 bytes r || s."""
    r, s = decode_dss_signature(key.sign(room_message(room, nonce), ec.ECDSA(hashes.SHA256())))
    return r.to_bytes(32, "big") + s.to_bytes(32, "big")


async def join(
    host: str,
    port: int,
    cafile: str,
    room: str,
    token: bytes,
    key: ec.EllipticCurvePrivateKey,
    quiet: float = 1.5,
    limit: float = 30.0,
    zone_size_m: float = 16.0,
) -> RoomState:
    """Enroll in `room` and return what it holds. Raises RuntimeError when the relay refuses the door."""
    state = RoomState(zone_size_m)
    async with open_relay(host, port, cafile, path=f"/room/{room}".encode()) as client:
        await client.login(token, public_key(key), lambda nonce: sign_room(key, room, nonce))
        deadline = time.monotonic() + limit
        while time.monotonic() < deadline:
            try:
                datagram = await client.next_pose(timeout=quiet)
            except asyncio.TimeoutError:
                break  # nothing for `quiet` seconds: the replay has finished
            if len(datagram) == entity.PACKET_SIZE:
                state.apply(datagram)
    return state
