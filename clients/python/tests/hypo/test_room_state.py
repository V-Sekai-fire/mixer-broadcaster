# SPDX-FileCopyrightText: 2026-present K. S. Ernest (iFire) Lee
#
# SPDX-License-Identifier: MIT
"""
Hypothesis tests of the headless reference consumer's room state (mixer/broadcaster/room_state.py). No network, no GPU.
GOLDEN: three poses in two zones give a fixed count, a fixed box and a fixed digest per zone; an ENTITY_REMOVE takes one out.
INVARIANT: for any packets, the order they arrive in and repeats do not change the state; the zones partition the entities
  (counts add up, every position is inside its zone's box); the clock the relay stamps is not part of any digest.
CONTROL: a client that heard nothing has an empty state; changing one entity changes the digest of its zone and no other;
  a consumer that lets the last packet heard win (not the newest clock) is shown to differ, so the order check can fail;
  a ragged byte string is refused.
"""
import hashlib

import pytest
from hypothesis import given, settings, strategies as st

from mixer.broadcaster import entity
from mixer.broadcaster.room_state import ENTITY_REMOVE, RoomState, read_packets, state_of

GOLDEN_DIGEST = "2b325e780f5eef7d4b27f2e827416cfb7bc9e3014e304c8918c0651a2e369352"
IDENT = (0.0, 0.0, 0.0, 1.0)
ONE = (1.0, 1.0, 1.0)


def pose(gid, loc, hlc, digest=bytes(32)):
    return entity.pose_entity(gid, loc, IDENT, ONE, hlc, digest=digest).pack()


def remove(gid, hlc):
    return entity.pack_command(ENTITY_REMOVE, gid.to_bytes(4, "little"), 1, lambda d: d, hlc)


def test_golden_two_zones():
    a, b, c = pose(1, (1, 0, 1), 10), pose(2, (2, 5, 3), 11), pose(3, (20, 0, -1), 12)
    s = state_of([a, b, c], 16.0)
    assert s.count == 3
    assert sorted(s.zones) == [(0, 0), (1, -1)]
    z = s.zones[(0, 0)]
    assert (z.count, z.lo, z.hi) == (2, (1_000_000, 0, 1_000_000), (2_000_000, 5_000_000, 3_000_000))
    assert s.zones[(1, -1)].count == 1
    # the digest is SHA-256 of the packets by id with the clock field (bytes 40..47) zeroed
    want = hashlib.sha256(b"".join(p[:40] + bytes(8) + p[48:] for p in (a, b, c))).hexdigest()
    assert s.digest == want
    assert s.digest == GOLDEN_DIGEST


def test_golden_remove():
    s = RoomState(16.0)
    for p in (pose(1, (1, 0, 1), 10), pose(2, (2, 5, 3), 11)):
        assert s.apply(p)
    assert s.apply(remove(2, 12))
    snap = s.snapshot()
    assert snap.count == 1 and snap.zones[(0, 0)].count == 1
    assert not s.apply(remove(2, 13))  # an id nobody holds changes nothing


packets = st.lists(
    st.tuples(
        st.integers(0, 12),
        st.tuples(*[st.integers(-40, 40)] * 3),
        st.integers(1, 10_000),
    ),
    min_size=0,
    max_size=40,
    unique_by=lambda t: t[2],  # a clock value is used once
).map(lambda ts: [pose(g, loc, h) for g, loc, h in ts])


@settings(max_examples=150, deadline=None)
@given(packets, st.randoms(use_true_random=False), st.integers(0, 3))
def test_order_and_repeats_do_not_matter(ps, rnd, repeats):
    want = state_of(sorted(ps, key=lambda p: entity.Entity.unpack(p).hlc))
    shuffled = ps * (1 + repeats)
    rnd.shuffle(shuffled)
    assert state_of(shuffled) == want


@settings(max_examples=150, deadline=None)
@given(packets, st.sampled_from([1.0, 4.0, 16.0]))
def test_zones_partition_the_room(ps, size):
    s = state_of(ps, size)
    assert sum(z.count for z in s.zones.values()) == s.count == len({entity.Entity.unpack(p).gid for p in ps})
    room = RoomState(size)
    for p in ps:
        room.apply(p)
    cell = round(size * 1_000_000)
    for e in room.entities():
        zx, zz = e.pos[0] // cell, e.pos[2] // cell
        z = s.zones[(zx, zz)]
        assert all(l <= c <= h for l, c, h in zip(z.lo, e.pos, z.hi))


@settings(max_examples=100, deadline=None)
@given(packets, st.integers(1, 1000))
def test_the_relays_clock_is_not_in_the_digest(ps, bump):
    def restamp(p):
        e = entity.Entity.unpack(p)
        return p[:40] + (e.hlc + bump).to_bytes(8, "little") + p[48:]

    assert state_of([restamp(p) for p in ps]).digest == state_of(ps).digest


def test_control_a_client_that_heard_nothing_holds_nothing():
    s = RoomState().snapshot()
    assert s.count == 0 and s.zones == {}
    assert s != state_of([pose(1, (0, 0, 0), 1)])


def test_control_one_change_moves_one_zone_digest():
    base = [pose(1, (1, 0, 1), 10), pose(2, (20, 0, -1), 11)]
    moved = [pose(1, (1.5, 0, 1), 12), base[1]]
    a, b = state_of(base), state_of(moved)
    assert a.digest != b.digest
    assert a.zones[(0, 0)].digest != b.zones[(0, 0)].digest
    assert a.zones[(1, -1)].digest == b.zones[(1, -1)].digest


def test_control_last_heard_wins_is_not_the_rule():
    new, old = pose(1, (5, 0, 5), 20), pose(1, (9, 0, 9), 10)
    right = state_of([new, old])  # the older packet arrives last
    naive = RoomState()
    naive._packets = {1: old}  # what a last-heard-wins consumer holds
    assert right != naive.snapshot()
    assert right.zones[(0, 0)].lo == (5_000_000, 0, 5_000_000)


def test_control_bad_input_is_refused():
    with pytest.raises(ValueError):
        read_packets(bytes(150))
    s = RoomState()
    assert not s.apply(bytes(99))
    assert not s.apply(pose(1, (0, 0, 0), 1)[:98] + b"\x01\x01")  # reserved bytes set
    with pytest.raises(ValueError):
        RoomState(0)
