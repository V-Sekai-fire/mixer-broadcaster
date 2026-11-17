# SPDX-FileCopyrightText: 2026-present K. S. Ernest (iFire) Lee
#
# SPDX-License-Identifier: MIT
"""
The headless reference consumer's room state (issue #32): what a room holds, in a form every other client's state is
compared against. Pure Python, no GPU, no network, no engine.

A room is the newest packet of each entity. `RoomState.apply` takes the 100-byte packets a client hears (poses, and the
ENTITY_REMOVE command that takes an entity out) and `snapshot` gives, as exact integers:

  count    entities in the room
  digest   SHA-256 over every entity's packet, ordered by id, with the relay's clock field zeroed (two clients hear the
           same packet with the same clock, but a client that sent it holds its own stamp, so the clock is left out)
  zones    the same three numbers per zone: count, bounding box of the entity positions, digest

A zone is a square cell of `zone_size_m` metres on the ground plane (X and Z; Y is up), numbered `(floor(x / size),
floor(z / size))`. The wire has no zone field, so this is the consumer's own partition and the size is a parameter.
The bounding box is of entity positions in micrometres (the wire's unit), not of their meshes: a mesh needs the chunk
store, which this module does not reach.

Order and repetition do not matter: the newest clock wins for an id, an older or equal packet is ignored, and a packet
heard twice changes nothing, so a late joiner (replayed packets) and a live one reach the same state.
"""
import hashlib
import json
from dataclasses import dataclass
from typing import Dict, Iterable, List, Optional, Tuple

from .entity import CLASS_COMMAND, PACKET_SIZE, Entity

ENTITY_REMOVE = 211  # command type; its inline data starts with the removed entity's id (u32 little endian)
_HLC_AT = 40  # byte offset of the clock in the packet; the relay rewrites it
Position = Tuple[int, int, int]  # x, y, z in micrometres
Zone = Tuple[int, int]


def zone_of(pos: Position, zone_size_m: float) -> Zone:
    """The zone of a position in micrometres: a cell on X and Z."""
    cell = round(zone_size_m * 1_000_000)
    return (pos[0] // cell, pos[2] // cell)


# Future: zones as rectangular prisms (boxes) instead of equal square columns, cut the way AV1 cuts a frame. AV1 splits
# a superblock recursively, and each node picks a partition type (NONE, HORZ, VERT, SPLIT, HORZ_A, HORZ_B, VERT_A,
# VERT_B, HORZ_4, VERT_4), so a crowded corner gets small blocks and an empty field gets one large one. Here the block
# is a prism with its own width, height and depth, and a cut runs along X, Y or Z: NONE keeps the box, SPLIT_X, SPLIT_Y
# and SPLIT_Z halve it, SPLIT_XYZ makes eight octants (each splits again), and the _A/_B and _4 forms give uneven cuts
# and four slabs along one axis. A node splits wherever it holds more than `max_entities`, and a zone key becomes
# `(x0, y0, z0, w, h, d)` in micrometres. Y counts, so a tower and the room under it land in different boxes (the square
# column puts them in one). The tree is a pure function of the entity positions, so two clients that hold the same
# room cut it the same way and the per-zone digests still compare.
# Not built: `zone_of` and the fixed square column stay the only rule, and nothing calls `blocks_of`.
PARTITION_TYPES = (
    "NONE", "SPLIT_X", "SPLIT_Y", "SPLIT_Z", "SPLIT_XYZ", "X_A", "X_B", "Y_A", "Y_B", "Z_A", "Z_B", "X_4", "Y_4", "Z_4"
)
Block = Tuple[int, int, int, int, int, int]  # (x0, y0, z0, width, height, depth) in micrometres
def blocks_of(positions: Iterable[Position], superblock_m: float, max_entities: int) -> List[Block]:
    """Stub for the AV1-style partition: the rectangular prisms that cover `positions`, one per zone. Not implemented."""
    raise NotImplementedError("AV1-style prism zones are a future step; use zone_of")
def _bounds(pos: List[Position]) -> Tuple[Position, Position]:
    """The corner with the smallest and the corner with the largest coordinate on each axis."""
    return (
        (min(p[0] for p in pos), min(p[1] for p in pos), min(p[2] for p in pos)),
        (max(p[0] for p in pos), max(p[1] for p in pos), max(p[2] for p in pos)),
    )


def _without_clock(packet: bytes) -> bytes:
    return packet[:_HLC_AT] + bytes(8) + packet[_HLC_AT + 8 :]


def _digest(packets: Iterable[Tuple[int, bytes]]) -> str:
    h = hashlib.sha256()
    for _, p in sorted(packets):
        h.update(_without_clock(p))
    return h.hexdigest()


@dataclass(frozen=True)
class ZoneState:
    count: int
    lo: Position
    hi: Position
    digest: str


@dataclass(frozen=True)
class Snapshot:
    count: int
    digest: str
    zones: Dict[Zone, ZoneState]

    def to_json(self) -> str:
        """Stable text, so two clients' states compare with `==` and diff readably."""
        zones = {
            f"{x},{z}": {"count": s.count, "lo": list(s.lo), "hi": list(s.hi), "digest": s.digest}
            for (x, z), s in sorted(self.zones.items())
        }
        return json.dumps({"count": self.count, "digest": self.digest, "zones": zones}, sort_keys=True, indent=2)


class RoomState:
    def __init__(self, zone_size_m: float = 16.0) -> None:
        if not zone_size_m > 0:
            raise ValueError("a zone is larger than zero metres")
        self.zone_size_m = zone_size_m
        self._packets: Dict[int, bytes] = {}
        self._hlc: Dict[int, int] = {}

    def __len__(self) -> int:
        return len(self._packets)

    def apply(self, packet: bytes) -> bool:
        """Take one packet; True when it changed the room. A wrong size, set reserved bytes, an older packet and a
        command other than ENTITY_REMOVE change nothing."""
        if len(packet) != PACKET_SIZE:
            return False
        try:
            e = Entity.unpack(packet)
        except ValueError:
            return False
        if e.class_owner >> 24 == CLASS_COMMAND:
            return self._command(e, packet)
        if e.gid in self._packets and e.hlc <= self._hlc[e.gid]:
            return False
        self._packets[e.gid] = packet
        self._hlc[e.gid] = e.hlc
        return True

    def _command(self, e: Entity, packet: bytes) -> bool:
        used, kind = e.sub_index >> 16, e.sub_index & 0xFFFF
        run = packet[4:40] + packet[56:98]
        if kind != ENTITY_REMOVE or used < 5 or run[0] != 0:
            return False
        gid = int.from_bytes(run[1:5], "little")
        self._hlc.pop(gid, None)
        return self._packets.pop(gid, None) is not None

    def entities(self) -> List[Entity]:
        return [Entity.unpack(p) for _, p in sorted(self._packets.items())]

    def snapshot(self) -> Snapshot:
        by_zone: Dict[Zone, List[Tuple[int, bytes]]] = {}
        for gid, p in self._packets.items():
            by_zone.setdefault(zone_of(Entity.unpack(p).pos, self.zone_size_m), []).append((gid, p))
        zones: Dict[Zone, ZoneState] = {}
        for z, members in by_zone.items():
            lo, hi = _bounds([Entity.unpack(p).pos for _, p in members])
            zones[z] = ZoneState(len(members), lo, hi, _digest(members))
        return Snapshot(len(self._packets), _digest(self._packets.items()), zones)


def state_of(packets: Iterable[bytes], zone_size_m: float = 16.0) -> Snapshot:
    s = RoomState(zone_size_m)
    for p in packets:
        s.apply(p)
    return s.snapshot()


def read_packets(data: bytes) -> List[bytes]:
    """Split a byte string of back-to-back 100-byte packets; a ragged tail is an error, not silently dropped."""
    if len(data) % PACKET_SIZE:
        raise ValueError(f"{len(data)} bytes is not a whole number of {PACKET_SIZE}-byte packets")
    return [data[i : i + PACKET_SIZE] for i in range(0, len(data), PACKET_SIZE)]
