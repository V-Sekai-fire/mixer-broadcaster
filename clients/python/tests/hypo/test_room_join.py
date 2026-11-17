# SPDX-FileCopyrightText: 2026-present K. S. Ernest (iFire) Lee
#
# SPDX-License-Identifier: MIT
"""
Hypothesis tests of the room door's proof (mixer/broadcaster/room_join.py). No network.
GOLDEN: the signed message is "mixer-relay-v1", the room length as two big-endian bytes, the room, then the nonce; a
  public key is 65 bytes and its thumbprint is the SHA-256 of them.
INVARIANT: for any key, room and nonce the proof is 64 bytes and verifies against the public key and the message.
CONTROL: the same proof does not verify for another room, another nonce or another key, so the check can fail.
"""
import hashlib

import pytest
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import encode_dss_signature
from hypothesis import given, settings, strategies as st

from mixer.broadcaster.room_join import private_key, public_key, room_message, sign_room, thumbprint

scalars = st.integers(1, 2**255).map(lambda n: n.to_bytes(32, "big"))
rooms = st.text(min_size=1, max_size=40)
nonces = st.binary(min_size=32, max_size=32)


def verifies(key, room, nonce, proof):
    r, s = int.from_bytes(proof[:32], "big"), int.from_bytes(proof[32:], "big")
    try:
        key.public_key().verify(encode_dss_signature(r, s), room_message(room, nonce), ec.ECDSA(hashes.SHA256()))
        return True
    except InvalidSignature:
        return False


def test_golden_message_and_thumbprint():
    assert room_message("lobby", bytes(range(32))) == b"mixer-relay-v1\x00\x05lobby" + bytes(range(32))
    pub = public_key(private_key((1).to_bytes(32, "big")))
    assert len(pub) == 65 and pub[0] == 4
    assert thumbprint(pub) == hashlib.sha256(pub).digest()
    # the generator point: the public key of scalar 1 is the curve's base point
    assert pub.hex().startswith("046b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296")


@settings(max_examples=60, deadline=None)
@given(scalars, rooms, nonces)
def test_the_proof_verifies(scalar, room, nonce):
    key = private_key(scalar)
    proof = sign_room(key, room, nonce)
    assert len(proof) == 64 and verifies(key, room, nonce, proof)


@settings(max_examples=40, deadline=None)
@given(scalars, scalars, rooms, nonces, nonces)
def test_control_other_room_nonce_or_key_does_not_verify(scalar, other, room, nonce, nonce2):
    key = private_key(scalar)
    proof = sign_room(key, room, nonce)
    assert not verifies(key, room + "x", nonce, proof)
    if nonce2 != nonce:
        assert not verifies(key, room, nonce2, proof)
    if other != scalar:
        assert not verifies(private_key(other), room, nonce, proof)


def test_control_bad_sizes_are_refused():
    with pytest.raises(ValueError):
        private_key(bytes(31))
    with pytest.raises(ValueError):
        room_message("r", bytes(31))
    with pytest.raises(ValueError):
        thumbprint(bytes(64))
