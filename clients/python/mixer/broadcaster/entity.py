# MIT License
#
# Copyright (c) 2026-present K. S. Ernest (iFire) Lee
#
# Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
# documentation files (the "Software"), to deal in the Software without restriction, including without limitation the
# rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit
# persons to whom the Software is furnished to do so, subject to the following conditions: the above copyright notice and
# this permission notice shall be included in all copies or substantial portions of the Software. THE SOFTWARE IS
# PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.

"""
Entity state for the broadcaster: one object's pose, scale and mesh, in the 100-byte entity packet of
contract-entity-packet (https://github.com/V-Sekai-fire/contract-entity-packet).

No `bpy`, no `mixer.*` import: this module belongs to the MIT side of the licence boundary.

What goes where
  gid, pos, rot, hlc, class_owner, sub_index   the packet's own fields, unchanged
  payload[0:32]                                SHA-256 of the mesh's desync index (the mesh is fetched by that name)
  payload[32:36]                               scale, three 10-bit log-scale values in a little-endian u32

Scale is `2 ** ((v - 512) / 64)` per axis, v in 0..1023: 2**-8 to 2**8 in steps of about 1.1%, and 1.0 is v = 512.
The axes are those of the mesh file (Y up), after a Z-up source's local axes are mapped (x, y, z) -> (x, z, y).
Negative scale (a mirror) is not representable; a mirror needs a mesh of its own.
"""

import hashlib
import math
from typing import Sequence, Tuple

Quat = Tuple[float, float, float, float]  # (x, y, z, w)

PAYLOAD_LEN = 36
DIGEST_LEN = 32
SCALE_ZERO = 512
SCALE_PER_OCTAVE = 64


def encode_scale(sx: float, sy: float, sz: float) -> bytes:
    """Three positive scales to four bytes. Anything outside 2**-8 .. 2**8 is clamped to the nearest end."""
    code = 0
    for k, s in enumerate((sx, sy, sz)):
        v = SCALE_ZERO + round(SCALE_PER_OCTAVE * math.log2(max(float(s), 2.0**-9)))
        code |= max(0, min(1023, v)) << (10 * k)
    return code.to_bytes(4, "little")


def decode_scale(data: bytes) -> Tuple[float, float, float]:
    code = int.from_bytes(data[:4], "little")
    return tuple(2.0 ** ((((code >> (10 * k)) & 1023) - SCALE_ZERO) / SCALE_PER_OCTAVE) for k in range(3))


def mesh_digest(index_bytes: bytes) -> bytes:
    """The name of a mesh on the wire: SHA-256 of its desync index."""
    return hashlib.sha256(index_bytes).digest()


def pack_payload(digest: bytes, scale: Tuple[float, float, float] = (1.0, 1.0, 1.0)) -> bytes:
    if len(digest) != DIGEST_LEN:
        raise ValueError("a mesh digest is 32 bytes")
    return digest + encode_scale(*scale)


def unpack_payload(payload: bytes) -> Tuple[bytes, Tuple[float, float, float]]:
    if len(payload) != PAYLOAD_LEN:
        raise ValueError("an entity payload is 36 bytes")
    return payload[:DIGEST_LEN], decode_scale(payload[DIGEST_LEN:])


# ---- rotation: swing-twist codes, as SWING_TWIST.md (q = swing * twist, twist about +Y) ----


def qmul(a: Quat, b: Quat) -> Quat:  # Hamilton product; applies b first, as Godot's a * b
    ax, ay, az, aw = a
    bx, by, bz, bw = b
    return (
        aw * bx + ax * bw + ay * bz - az * by,
        aw * by - ax * bz + ay * bw + az * bx,
        aw * bz + ax * by - ay * bx + az * bw,
        aw * bw - ax * bx - ay * by - az * bz,
    )


def swing_twist_codes(q: Sequence[float]) -> Tuple[int, int, int]:
    """(x, y, z, w) in the wire frame to (swing X, swing Z, twist) int16 codes."""
    n = math.sqrt(sum(c * c for c in q)) or 1.0
    x, y, z, w = (c / n for c in q)
    qn: Quat = (x, y, z, w)
    tn = math.hypot(y, w)
    tw: Quat = (0.0, y / tn, 0.0, w / tn) if tn > 1e-12 else (0.0, 0.0, 0.0, 1.0)
    sw = qmul(qn, (-tw[0], -tw[1], -tw[2], tw[3]))
    if sw[3] < 0 or (sw[3] == 0 and (sw[0] < 0 or (sw[0] == 0 and sw[2] < 0))):
        sw = (-sw[0], -sw[1], -sw[2], -sw[3])
    ang = 2 * math.acos(max(-1.0, min(1.0, sw[3])))
    s = math.sin(ang / 2)
    vx, vz = (ang * sw[0] / s, ang * sw[2] / s) if s > 1e-12 else (0.0, 0.0)
    code = lambda v: max(-32767, min(32767, int(round(v / math.pi * 32767))))
    twist = int(round(2 * math.atan2(tw[1], tw[3]) / (2 * math.pi) * 65536))
    twist = ((twist + 32768) % 65536) - 32768
    return code(vx), code(vz), twist


def quat_of_codes(cx: int, cz: int, twist: int) -> Quat:
    """The inverse: codes back to a unit quaternion (x, y, z, w)."""
    sx, sz = cx * math.pi / 32767, cz * math.pi / 32767
    a = math.hypot(sx, sz)
    swing = (
        (sx / a * math.sin(a / 2), 0.0, sz / a * math.sin(a / 2), math.cos(a / 2))
        if a > 1e-12
        else (0.0, 0.0, 0.0, 1.0)
    )
    t = twist * 2 * math.pi / 65536
    return qmul(swing, (0.0, math.sin(t / 2), 0.0, math.cos(t / 2)))


def angle_between(q1: Sequence[float], q2: Sequence[float]) -> float:
    """Smallest rotation, in radians, that takes one unit quaternion to the other."""
    d = abs(sum(a * b for a, b in zip(q1, q2)))
    return 2 * math.acos(max(-1.0, min(1.0, d)))


# ---- the 100-byte packet (contract-entity-packet), little endian ----
#   0 gid u32 | 4 pos 3 x i64 (micrometres) | 28 vel 3 x i16 | 34 accel 3 x i16 | 40 hlc u64 (ms << 16 | counter)
#   48 class_owner u32 | 52 sub_index u32 | 56 rot: swing X, swing Z, twist (3 x i16) | 62 payload 36 | 98 reserved 2 (zero)

import struct
from dataclasses import dataclass, field

PACKET_SIZE = 100
_PACKET = struct.Struct("<I3q3h3hQII3h36s2s")
assert _PACKET.size == PACKET_SIZE


@dataclass(order=True)
class Entity:
    gid: int
    pos: Tuple[int, int, int] = (0, 0, 0)
    vel: Tuple[int, int, int] = (0, 0, 0)
    accel: Tuple[int, int, int] = (0, 0, 0)
    hlc: int = 0
    class_owner: int = 0
    sub_index: int = 0
    rot: Tuple[int, int, int] = (0, 0, 0)  # swing X, swing Z, twist, as swing_twist_codes
    payload: bytes = field(default=bytes(PAYLOAD_LEN))

    def pack(self) -> bytes:
        if len(self.payload) != PAYLOAD_LEN:
            raise ValueError("an entity payload is 36 bytes")
        try:
            return _PACKET.pack(
                self.gid,
                *self.pos,
                *self.vel,
                *self.accel,
                self.hlc,
                self.class_owner,
                self.sub_index,
                *self.rot,
                self.payload,
                b"\0\0",
            )
        except struct.error as e:
            raise ValueError(f"entity field out of range: {e}") from None

    @classmethod
    def unpack(cls, data: bytes) -> "Entity":
        if len(data) != PACKET_SIZE:
            raise ValueError("an entity packet is 100 bytes")
        f = _PACKET.unpack(data)
        if f[-1] != b"\0\0":
            raise ValueError("the reserved bytes of an entity packet are zero")
        return cls(f[0], tuple(f[1:4]), tuple(f[4:7]), tuple(f[7:10]), f[10], f[11], f[12], tuple(f[13:16]), f[16])

    def mesh(self) -> Tuple[bytes, Tuple[float, float, float]]:
        """(digest of the mesh's desync index, scale) from the payload."""
        return unpack_payload(self.payload)


# ---- a pose ----
#
# The wire has one frame: right-handed, X right, Y up, -Z forward, metres (`frames.WIRE`). A pose is always given in it.
# A client in another frame converts first, with `frames.<ENGINE>.point_to_wire` and `quat_to_wire`.

CLASS_PROP = 4  # EntityPacket.Class.prop


def pose_entity(
    gid: int,
    loc: Sequence[float],
    quat_xyzw: Sequence[float],
    scale: Sequence[float],
    hlc: int,
    owner: int = 1,
    digest: bytes = bytes(DIGEST_LEN),
) -> "Entity":
    """The packet for an object's world transform: position in micrometres, swing-twist rotation, scale and the digest of
    its mesh in the payload. `loc` is (x, y, z) in metres and `quat_xyzw` a unit quaternion, both in the wire's frame.
    """
    if not 0 <= owner < (1 << 24):
        raise ValueError("owner is 24 bits: more would spill into the class byte")
    px, py, pz = loc
    cx, cz, tw = swing_twist_codes(quat_xyzw)
    um = lambda v: int(round(v * 1_000_000))  # noqa: E731
    return Entity(
        gid=gid,
        pos=(um(px), um(py), um(pz)),
        hlc=hlc,
        class_owner=(CLASS_PROP << 24) | owner,
        rot=(cx, cz, tw),
        payload=pack_payload(digest, (abs(scale[0]), abs(scale[1]), abs(scale[2]))),
    )


# ---- a command inside the packet ----
#
# A command is one 100-byte packet of class `command` (contract-entity-packet, EntityPacket/Classes.lean, byte 128).
# It has no pose, so its data uses the bytes a pose would: bytes 4..39 then 56..97, read as one run of 78 bytes.
#   gid          the command's key: 32 bits of SHA-256 over the type and the command's leading string (its path or
#                name). Two commands with one key replace each other in a room's stored content. A collision would
#                replace an unrelated command: about 1 in 65,000 per pair at 65,000 keys in a room.
#   class_owner  (128 << 24) | owner, the sending client (24 bits)
#   sub_index    (used << 16) | type: the command type (1..65535, not 210, the pose) and how many bytes of the run are used
#   the run      byte 0 = 0 (inline): bytes 1..used are the data, so inline data is up to 77 bytes
#                byte 0 = 1 (by digest): bytes 1..33 the digest the data is stored under, bytes 33..36 its length
#                (u24, little endian); the rest zero.
#                byte 0 = 2 (by index): bytes 1..33 the SHA-256 of a desync index of the data, which is chunked into the
#                store the way a mesh is; no length (the index has it), for data over 16 MiB. The relay never reads it.
# Unused bytes are zero: the wire is zstd and run-length coded, so they cost almost nothing.

import hashlib as _hashlib
from typing import Callable, Optional, Tuple as _Tuple

POSE = 210
CLASS_COMMAND = 128  # EntityPacket.Class.command
DATA_A = (4, 36)  # offset, length: EntityPacket.COMMAND_DATA_A_*
DATA_B = (56, 42)
RUN_LEN = DATA_A[1] + DATA_B[1]  # 78
INLINE_MAX = RUN_LEN - 1
MODE_INLINE, MODE_DIGEST, MODE_INDEX = 0, 1, 2  # inline; the data's SHA-256 (under 16 MiB); a desync index's SHA-256
MAX_BULK = (1 << 24) - 1


def command_key(command_type: int, data: bytes) -> int:
    """The gid of a command: its type and its leading length-prefixed string, if it has one."""
    lead = b""
    if len(data) >= 4:
        n = int.from_bytes(data[:4], "little")
        if 0 < n <= len(data) - 4:
            lead = data[4 : 4 + n]
    return int.from_bytes(_hashlib.sha256(command_type.to_bytes(2, "little") + lead).digest()[:4], "little")


def _split_run(run: bytes) -> _Tuple[bytes, bytes]:
    return run[: DATA_A[1]], run[DATA_A[1] :]


def pack_command(
    command_type: int,
    data: bytes,
    owner: int,
    store: Callable[[bytes], bytes],
    hlc: int = 0,
    store_index: Optional[Callable[[bytes], bytes]] = None,
) -> bytes:
    """A command as 100 bytes. `store(data) -> digest` puts bulk data in the chunk store; it is called only when the
    data does not fit inside the packet. Over 16 MiB, `store_index(data) -> digest of the desync index` is used instead.
    """
    if not 1 <= command_type <= 0xFFFF or command_type == POSE:
        raise ValueError("this message type does not ride as a command")
    if not 0 <= owner < (1 << 24):
        raise ValueError("owner is 24 bits")
    if len(data) <= INLINE_MAX:
        run, used = bytes([MODE_INLINE]) + data, 1 + len(data)
    elif len(data) > MAX_BULK:
        if store_index is None:
            raise ValueError("a command's data is under 16 MiB unless it can go by desync index")
        digest = store_index(data)
        if len(digest) != DIGEST_LEN:
            raise ValueError("a digest is 32 bytes")
        run, used = bytes([MODE_INDEX]) + digest, 1 + DIGEST_LEN
    else:
        digest = store(data)
        if len(digest) != DIGEST_LEN:
            raise ValueError("a digest is 32 bytes")
        run, used = bytes([MODE_DIGEST]) + digest + len(data).to_bytes(3, "little"), 36
    run = run + bytes(RUN_LEN - len(run))
    a, b = _split_run(run)
    out = bytearray(PACKET_SIZE)
    out[0:4] = command_key(command_type, data).to_bytes(4, "little")
    out[DATA_A[0] : DATA_A[0] + DATA_A[1]] = a
    out[40:48] = hlc.to_bytes(8, "little")
    out[48:52] = ((CLASS_COMMAND << 24) | owner).to_bytes(4, "little")
    out[52:56] = ((used << 16) | command_type).to_bytes(4, "little")
    out[DATA_B[0] : DATA_B[0] + DATA_B[1]] = b
    return bytes(out)


def unpack_command(
    raw: bytes, fetch: Callable[[bytes], bytes], fetch_index: Optional[Callable[[bytes], bytes]] = None
) -> _Tuple[int, int, bytes]:
    """(command type, owner, data). `fetch(digest) -> data` reads bulk data back; the length must match.
    `fetch_index(digest) -> data` reads data named by a desync index (mode 2)."""
    if len(raw) != PACKET_SIZE:
        raise ValueError("a packet is 100 bytes")
    class_owner = int.from_bytes(raw[48:52], "little")
    sub_index = int.from_bytes(raw[52:56], "little")
    if class_owner >> 24 != CLASS_COMMAND:
        raise ValueError("not a command packet")
    command_type, used, owner = sub_index & 0xFFFF, sub_index >> 16, class_owner & 0xFFFFFF
    if not 1 <= command_type <= 0xFFFF or command_type == POSE or not 1 <= used <= RUN_LEN:
        raise ValueError("a malformed command header")
    if raw[98:100] != b"\0\0":
        raise ValueError("the reserved bytes are zero")
    run = raw[DATA_A[0] : DATA_A[0] + DATA_A[1]] + raw[DATA_B[0] : DATA_B[0] + DATA_B[1]]
    if any(run[used:]):
        raise ValueError("bytes past the used length are zero")
    if run[0] == MODE_INLINE:
        data = bytes(run[1:used])
    elif run[0] == MODE_DIGEST:
        length = int.from_bytes(run[33:36], "little")
        if used != 36 or length <= INLINE_MAX:
            raise ValueError("a malformed command by digest")
        data = fetch(bytes(run[1:33]))
        if len(data) != length:
            raise ValueError("the stored data is not the length the packet says")
    elif run[0] == MODE_INDEX:
        if used != 1 + DIGEST_LEN:
            raise ValueError("a malformed command by index")
        if fetch_index is None:
            raise ValueError("a command by index needs a way to read an index")
        data = fetch_index(bytes(run[1:33]))
    else:
        raise ValueError("unknown command mode")
    return command_type, owner, data
