"""
Hypothesis tests of mode 2 of a command packet: data over 16 MiB named by the SHA-256 of its desync index. No engine needed.
GOLDEN: data of 16 MiB and one byte goes by index (mode 2, used 33, the digest, no length, the data's key) and reads
  back through `fetch_index`; data of exactly 16 MiB - 1 is still by digest.
INVARIANT: for any digest, owner, clock, type and size past the limit the packet round trips and is 100 bytes.
CONTROL: no `store_index` refuses the data; no `fetch_index` refuses the packet; a wrong used length, a dirty tail and an
  unknown mode are refused.
"""

import os
import sys

import pytest
from hypothesis import given, settings, strategies as st

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))
from mixer.broadcaster import entity  # noqa: E402

BIG = entity.MAX_BULK + 1
D = bytes([0x11]) * 32


def no_store(_):
    raise AssertionError("the whole-blob store must not be used over the limit")


def test_golden_over_the_limit_goes_by_index():
    data = bytes(BIG)
    pkt = entity.pack_command(77, data, 9, no_store, 1234, lambda d: D)
    assert len(pkt) == 100
    assert pkt[0:4] == entity.command_key(77, data).to_bytes(4, "little")
    assert pkt[4] == entity.MODE_INDEX and pkt[5:37] == D and pkt[37:40] == bytes(3)
    assert int.from_bytes(pkt[52:56], "little") == (33 << 16) | 77
    assert entity.unpack_command(pkt, no_store, lambda d: data if d == D else b"") == (77, 9, data)


def test_golden_just_under_the_limit_is_by_digest():
    pkt = entity.pack_command(77, bytes(entity.MAX_BULK), 1, lambda d: bytes([0x22]) * 32, 0, lambda d: D)
    assert pkt[4] == entity.MODE_DIGEST


def test_control_refusals():
    with pytest.raises(ValueError):
        entity.pack_command(77, bytes(BIG), 1, no_store, 0)
    pkt = entity.pack_command(77, bytes(BIG), 1, no_store, 0, lambda d: D)
    with pytest.raises(ValueError):
        entity.unpack_command(pkt, no_store)
    fetch = lambda d: b"x"  # noqa: E731
    for used in (1, 32, 34, 36):
        b = bytearray(pkt)
        b[52:56] = ((used << 16) | 77).to_bytes(4, "little")
        with pytest.raises(ValueError):
            entity.unpack_command(bytes(b), no_store, fetch)
    for pos, val in ((60, 1), (4, 3)):  # a dirty tail, an unknown mode
        b = bytearray(pkt)
        b[pos] = val
        with pytest.raises(ValueError):
            entity.unpack_command(bytes(b), no_store, fetch)


@settings(max_examples=40, deadline=None)
@given(
    t=st.integers(1, 0xFFFF).filter(lambda x: x != entity.POSE),
    owner=st.integers(0, (1 << 24) - 1),
    hlc=st.integers(0, (1 << 64) - 1),
    digest=st.binary(min_size=32, max_size=32),
    extra=st.integers(0, 64),
)
def test_invariant_round_trip(t, owner, hlc, digest, extra):
    data = bytes(BIG + extra)
    pkt = entity.pack_command(t, data, owner, no_store, hlc, lambda d: digest)
    assert len(pkt) == 100
    assert entity.unpack_command(pkt, no_store, lambda d: data if d == digest else b"") == (t, owner, data)
