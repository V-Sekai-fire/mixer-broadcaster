# MIT. Copyright (c) 2026-present K. S. Ernest (iFire) Lee
# Does residual FSQ with fitted stage scales beat plain bit-crushing on real motion?
#   python rfsq_fit.py FRAMES.bin AVATARS JOINTS
# FRAMES.bin is ticks x avatars x joints x 100 bytes (mm_to_packets.py, the 32 bit clock layout: pos at 4, rot at 52).
# The signal is the residual of a constant velocity prediction: x[t] - (2 x[t-1] - x[t-2]), per channel, open loop.
# Nothing is trained. A scheme's stage ranges are fitted from the data by one rule: stage 1 covers a quantile of |r|,
# and each later stage covers the largest error the stage before it can leave (half its step), which is the scale the paper
# learns (RFSQ "scale conditioning"). The naive scheme reuses stage 1's range for every stage.
import math
import struct
import sys
from collections import Counter

path, avatars, joints = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
data = open(path, "rb").read()
PKT = 100
per_tick = avatars * joints
ticks = len(data) // (per_tick * PKT)


def channel(offset, fmt, n):
    """series[e][c] = list over ticks, for each entity e and channel c."""
    out = [[[] for _ in range(n)] for _ in range(per_tick)]
    for t in range(ticks):
        base = t * per_tick * PKT
        for e in range(per_tick):
            vals = struct.unpack_from(fmt, data, base + e * PKT + offset)
            for c in range(n):
                out[e][c].append(vals[c])
    return out


def residuals(series):
    r = []
    for ent in series:
        for ch in ent:
            r.extend(ch[t] - (2 * ch[t - 1] - ch[t - 2]) for t in range(2, len(ch)))
    return r


def quantile(xs, q):
    s = sorted(xs)
    return s[min(len(s) - 1, int(q * len(s)))]


def entropy(symbols):
    n = len(symbols)
    return -sum(c / n * math.log2(c / n) for c in Counter(symbols).values())


def run(r, bits, scale, q):
    """Quantise every value of r with len(bits) stages. bits[k] is stage k's bits. scale: True fits each later stage to the
    error the stage before can leave; False reuses stage 1's range. q < 1 clips stage 1 at that quantile of |r| and sends
    the clipped values exactly (an escape code). Returns (fixed bits, entropy bits, max err, p99 err, rms, escape rate).
    """
    mags = [abs(v) for v in r]
    R = [quantile(mags, q) if q < 1 else max(mags)]
    L = [2**b for b in bits]
    esc = 0
    codes = [[] for _ in bits]
    errs = []
    for k in range(1, len(bits)):
        R.append(R[k - 1] / L[k - 1] if scale else R[0])  # half a step of the stage before: step = 2R/L
    for v in r:
        if abs(v) > R[0]:
            esc += 1
            for c in codes:
                c.append(-1)
            errs.append(0.0)  # sent exactly
            continue
        rem = v
        for k in range(len(bits)):
            step = 2 * R[k] / L[k]
            i = max(0, min(L[k] - 1, int((rem + R[k]) / step)))
            q_ = -R[k] + (i + 0.5) * step
            codes[k].append(i)
            rem -= q_
        errs.append(abs(rem))
    n = len(r)
    ent = sum(entropy(c) for c in codes)
    fixed = sum(bits) + (1 if q < 1 else 0)
    errs.sort()
    return fixed, ent, errs[-1], errs[int(0.99 * n)], math.sqrt(sum(e * e for e in errs) / n), esc / n


def show(name, r, unit, to_unit):
    print(
        f"\n== {name}: {len(r)} residuals; |r| p50 {to_unit(quantile([abs(v) for v in r], .5)):.4g} {unit}, "
        f"p99 {to_unit(quantile([abs(v) for v in r], .99)):.4g}, max {to_unit(max(abs(v) for v in r)):.4g}"
    )
    print(
        f"{'scheme':38s} {'bits':>4s} {'entropy':>8s} {'max err':>10s} {'p99 err':>10s} {'rms':>10s} {'escape':>7s}   ({unit})"
    )
    for label, bits, scale, qq in [
        ("one stage, covers max (bit-crush)", [8], True, 1),
        ("one stage, covers max (bit-crush)", [10], True, 1),
        ("one stage, covers max (bit-crush)", [12], True, 1),
        ("one stage, p99 + escape", [8], True, 0.99),
        ("one stage, p99 + escape", [10], True, 0.99),
        ("2 stages 5+5, naive (no scale)", [5, 5], False, 1),
        ("2 stages 5+5, scaled", [5, 5], True, 1),
        ("2 stages 5+5, scaled, p99 + escape", [5, 5], True, 0.99),
        ("3 stages 4+3+3, naive", [4, 3, 3], False, 1),
        ("3 stages 4+3+3, scaled", [4, 3, 3], True, 1),
        ("3 stages 4+3+3, scaled, p99 + escape", [4, 3, 3], True, 0.99),
        ("3 stages 6+4+2 (more early), scaled, p99+esc", [6, 4, 2], True, 0.99),
        ("4 stages 3+3+3+3, scaled, p99 + escape", [3, 3, 3, 3], True, 0.99),
    ]:
        f, e, mx, p99, rms, es = run(r, bits, scale, qq)
        print(
            f"{label:38s} {f:4d} {e:8.2f} {to_unit(mx):10.4g} {to_unit(p99):10.4g} {to_unit(rms):10.4g} {es * 100:6.2f}%"
        )


pos = residuals(channel(4, "<3q", 3))
show("position, constant velocity residual", pos, "mm", lambda v: v / 1000.0)
rot = residuals(channel(52, "<3h", 3))
show("rotation (swing x, swing z, twist codes), constant velocity residual", rot, "deg", lambda v: v * 180.0 / 32767.0)
