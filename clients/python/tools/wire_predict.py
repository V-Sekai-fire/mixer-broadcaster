# MIT. Extrapolate the next frame from the last four, with the modified Akima tangent of Predict.lean (integer maths,
# truncating division as in C), and use the extrapolated frame as the zstd prefix. Decoder and encoder run the same
# function on the same acked frames, so the prefix is identical at both ends. Nothing here is drawn on screen.
#   python wire_predict.py FRAMES.bin ENTITIES
import statistics
import struct
import sys

import zstandard as zstd

PKT = 100


def tdiv(n, d):  # C division: truncate toward zero
    q = abs(n) // abs(d)
    return q if (n >= 0) == (d > 0) else -q


def tang(p0, p1, p2, p3):  # EntityPacket.tang, verbatim
    w1 = 2 * abs(p3 - p2) + abs(p3 + p2)
    w2 = 2 * abs(p1 - p0) + abs(p1 + p0)
    s = w1 + w2
    return tdiv(p1 + p2, 2) if s == 0 else tdiv(w1 * p1 + w2 * p2, s)


def makima_next(a, b, c, d, wrap=0):
    """Value at the next tick from samples a, b, c, d (oldest to newest). Slopes at the end use Akima's edge rule."""

    def sl(x, y):
        v = y - x
        return ((v + wrap // 2) % wrap) - wrap // 2 if wrap else v

    s1, s2, s3 = sl(a, b), sl(b, c), sl(c, d)
    s4 = 2 * s3 - s2
    s5 = 2 * s4 - s3
    t = tang(s2, s3, s4, s5)  # tangent at d, in units per tick
    return d + t


# (offset, struct code, lo, hi, wrap) of the fields that change; the rest are held
FIELDS = [(4, "q", None, None, 0), (12, "q", None, None, 0), (20, "q", None, None, 0)]
FIELDS += [(o, "h", -32767, 32767, 0) for o in (28, 30, 32, 34, 36, 38, 56, 58)]
FIELDS += [(60, "h", -32768, 32767, 65536)]  # twist: circular
FIELDS += [(o, "h", -32767, 32767, 0) for o in (62, 64, 66)]  # angular velocity, if the stream carries it
ROT = ((56, 62, 0), (58, 64, 0), (60, 66, 65536))  # rot code offset, its velocity offset, wrap
HLC = 40


def predict(frames, t, ents, kind):
    """Frame t predicted from frames t-4..t-1. kind: 'hold', 'linear', 'makima'."""
    if kind == "hold":
        return frames[t - 1]
    out = bytearray(frames[t - 1])
    for e in range(ents):
        base = e * PKT
        for off, code, lo, hi, wrap in FIELDS:
            w = struct.calcsize(code)
            v = [struct.unpack_from("<" + code, frames[t - k], base + off)[0] for k in (4, 3, 2, 1)]
            rv = [r for r in ROT if r[0] == off]
            if kind in ("rv1", "rv2") and rv:
                _, voff, wr = rv[0]
                vs = [struct.unpack_from("<h", frames[t - k], base + voff)[0] for k in (4, 3, 2, 1)]
                step = (
                    vs[3] if kind == "rv1" else (vs[3] + makima_next(*vs)) // 2
                )  # integrate the velocity over the tick
                p = v[3] + step
            elif kind == "linear":
                p = v[3] + (((v[3] - v[2]) + wrap // 2) % wrap - wrap // 2 if wrap else v[3] - v[2])
            else:
                p = makima_next(*v, wrap=wrap)
            if wrap:
                p = ((p + wrap // 2) % wrap) - wrap // 2
            elif lo is not None:
                p = max(lo, min(hi, p))
            struct.pack_into("<" + code, out, base + off, p)
        h = [struct.unpack_from("<Q", frames[t - k], base + HLC)[0] for k in (2, 1)]
        struct.pack_into("<Q", out, base + HLC, (2 * h[1] - h[0]) & (2**64 - 1))
    return bytes(out)


if __name__ == "__main__":
    path, ents = sys.argv[1], int(sys.argv[2])
    d = open(path, "rb").read()
    F = ents * PKT
    fr = [d[i * F : (i + 1) * F] for i in range(len(d) // F)]
    raw = lambda b: zstd.ZstdCompressionDict(b, dict_type=zstd.DICT_TYPE_RAWCONTENT)
    base = None
    for kind in ("hold", "linear", "makima", "rv1", "rv2"):
        sizes = []
        for t in range(8, len(fr)):
            pre = predict(fr, t, ents, kind)
            z = zstd.ZstdCompressor(level=1, dict_data=raw(pre), write_content_size=True).compress(fr[t])
            assert zstd.ZstdDecompressor(dict_data=raw(pre)).decompress(z) == fr[t]
            sizes.append(len(z))
        m = statistics.mean(sizes)
        base = base or m
        print(
            f"PRED prefix = {kind:7s} {m:7.0f} B/tick  {m * 20 * 8 / 1000:6.1f} kbps  {F / m:5.1f}x  vs hold {100 * (base - m) / base:+5.1f}%  EXACT",
            flush=True,
        )
