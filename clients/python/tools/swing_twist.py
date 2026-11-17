# MIT. Swing-twist codes of a quaternion, as contract-entity-packet's SWING_TWIST.md defines them.
# q = (x, y, z, w) in the wire frame (Y up, -Z forward). Returns (swing X, swing Z, twist about +Y) as int16 codes.
import math


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
