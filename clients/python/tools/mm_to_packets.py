# MIT. Turn real motion-matching clips (interactor-motion-matching-guest, SOMA30 skeleton) into 100-byte entity packets.
#   python mm_to_packets.py MMG_DIR OUT.bin [--avatars 8] [--ticks 400] [--hz 20]
# One tick = one frame of avatars x 30 joints x 100 bytes, written in order, so the file is TICKS * FRAME bytes. Every
# value comes from the clips: local position and rotation per joint, velocity and acceleration from the change between
# send ticks. Rotation is swing-twist as in contract-entity-packet's SWING_TWIST.md. Nothing is generated.
import math
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from xr_grid_entity_packet import Packet, encode  # noqa: E402  (emitted from the Lean spec)

JOINTS = 30
V_MAX = 500000  # micrometres per tick, full scale of the i16 velocity
A_MAX = 2 * V_MAX
CLIPS = ["walk_1", "jog_1", "run_1", "walk_2", "circles_1", "snake_1", "walk_turns_1", "crouching_1"]


def quat_of_matrix(m):
    r00, r01, r02, r10, r11, r12, r20, r21, r22 = m
    t = r00 + r11 + r22
    if t > 0:
        s = math.sqrt(t + 1.0) * 2
        return ((r21 - r12) / s, (r02 - r20) / s, (r10 - r01) / s, 0.25 * s)
    if r00 > r11 and r00 > r22:
        s = math.sqrt(1.0 + r00 - r11 - r22) * 2
        return (0.25 * s, (r01 + r10) / s, (r02 + r20) / s, (r21 - r12) / s)
    if r11 > r22:
        s = math.sqrt(1.0 + r11 - r00 - r22) * 2
        return ((r01 + r10) / s, 0.25 * s, (r12 + r21) / s, (r02 - r20) / s)
    s = math.sqrt(1.0 + r22 - r00 - r11) * 2
    return ((r02 + r20) / s, (r12 + r21) / s, 0.25 * s, (r10 - r01) / s)


def qmul(a, b):  # Hamilton product; applies b first, as Godot's a * b
    ax, ay, az, aw = a
    bx, by, bz, bw = b
    return (
        aw * bx + ax * bw + ay * bz - az * by,
        aw * by - ax * bz + ay * bw + az * bx,
        aw * bz + ax * by - ay * bx + az * bw,
        aw * bw - ax * bx - ay * by - az * bz,
    )


def swing_twist_codes(q):
    n = math.sqrt(sum(c * c for c in q)) or 1.0
    q = tuple(c / n for c in q)
    x, y, z, w = q
    tn = math.hypot(y, w)
    tw = (0.0, y / tn, 0.0, w / tn) if tn > 1e-12 else (0.0, 0.0, 0.0, 1.0)
    sw = qmul(q, (-tw[0], -tw[1], -tw[2], tw[3]))
    if sw[3] < 0 or (sw[3] == 0 and (sw[0] < 0 or (sw[0] == 0 and sw[2] < 0))):
        sw = tuple(-c for c in sw)
    ang = 2 * math.acos(max(-1.0, min(1.0, sw[3])))
    s = math.sin(ang / 2)
    vx, vz = (ang * sw[0] / s, ang * sw[2] / s) if s > 1e-12 else (0.0, 0.0)
    code = lambda v: max(-32767, min(32767, int(round(v / math.pi * 32767))))
    twist = int(round(2 * math.atan2(tw[1], tw[3]) / (2 * math.pi) * 65536))
    twist = ((twist + 32768) % 65536) - 32768
    return code(vx), code(vz), twist


def clip_frames(mmg, name):
    d = f"{mmg}/data/o3de-motionmatching/{name}"
    frames = int(open(f"{d}/skeleton.txt").read().split("\n")[2].split()[1])
    return d + "/transforms.f32", frames


def joint_state(fh, f, j):
    """Local rotation matrix and position of joint j at frame f, put into the wire frame (Y up, -Z forward)."""
    fh.seek((f * JOINTS + j) * 48)
    v = struct.unpack("<12f", fh.read(48))
    flip = (-1, 1, -1)
    m = [v[3 * i + k] * flip[i] * flip[k] for i in range(3) for k in range(3)]  # F R F, F = diag(-1, 1, -1)
    p = [v[9 + k] * flip[k] for k in range(3)]
    return m, p


def main(mmg, out, avatars, ticks, hz, clips=None, rotvel=False):
    CLIPS = clips or globals()["CLIPS"]
    step = max(1, round(60 / hz))
    readers = []
    for a in range(avatars):
        path, frames = clip_frames(mmg, CLIPS[a % len(CLIPS)])
        readers.append((open(path, "rb"), frames, (a * 777) % max(1, frames - ticks * step - 2)))
    prev_p = {}
    prev_v = {}
    n = 0
    with open(out, "wb") as fo:
        for tick in range(ticks):
            for a, (fh, frames, start) in enumerate(readers):
                f = start + tick * step
                for j in range(JOINTS):
                    m, p = joint_state(fh, f, j)
                    pu = [int(round(c * 1e6)) for c in p]
                    key = (a, j)
                    dp = [pu[k] - prev_p.get(key, pu)[k] for k in range(3)]
                    vel = [max(-32767, min(32767, int(round(d / V_MAX * 32767)))) for d in dp]
                    acc = [
                        max(
                            -32767,
                            min(32767, int(round((vel[k] - prev_v.get(key, vel)[k]) * V_MAX / 32767 / A_MAX * 32767))),
                        )
                        for k in range(3)
                    ]
                    prev_p[key], prev_v[key] = pu, vel
                    rx, ry, rz = swing_twist_codes(quat_of_matrix(m))
                    payload = bytes(36)
                    if (
                        rotvel
                    ):  # angular velocity: central difference of the codes one 60 fps frame each side, per send tick
                        lo, hi = max(0, f - 1), min(frames - 1, f + 1)
                        c0 = swing_twist_codes(quat_of_matrix(joint_state(fh, lo, j)[0]))
                        c1 = swing_twist_codes(quat_of_matrix(joint_state(fh, hi, j)[0]))
                        span = max(1, hi - lo)
                        w = []
                        for k in range(3):
                            dd = c1[k] - c0[k]
                            if k == 2:
                                dd = ((dd + 32768) % 65536) - 32768
                            w.append(max(-32767, min(32767, int(round(dd * step / span)))))
                        payload = struct.pack("<3h", *w) + bytes(30)
                    pkt = Packet(
                        gid=a * JOINTS + j,
                        pos_um_x=pu[0],
                        pos_um_y=pu[1],
                        pos_um_z=pu[2],
                        vel_x=vel[0],
                        vel_y=vel[1],
                        vel_z=vel[2],
                        accel_x=acc[0],
                        accel_y=acc[1],
                        accel_z=acc[2],
                        hlc=((1_000_000 + tick * (1000 // hz)) << 16) | j,
                        class_owner=(2 << 24) | a,
                        sub_index=j,
                        swing_x=rx,
                        swing_z=ry,
                        twist=rz,
                        payload=payload,
                    )
                    fo.write(encode(pkt))
                    n += 1
    print(
        f"MM wrote {n} packets = {n * 100} bytes: {avatars} avatars x {JOINTS} joints x {ticks} ticks at {hz} Hz "
        f"({avatars * JOINTS * 100} B per tick); clips {[CLIPS[a % len(CLIPS)] for a in range(avatars)]}"
    )


argv = sys.argv[1:]
opt = lambda k, d: type(d)(argv[argv.index(k) + 1]) if k in argv else d
main(
    argv[0],
    argv[1],
    opt("--avatars", 8),
    opt("--ticks", 400),
    opt("--hz", 20),
    opt("--clips", "").split(",") if "--clips" in argv else None,
    "--rotvel" in argv,
)
