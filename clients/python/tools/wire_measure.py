# MIT. How small does zstd with the previous state make real motion? Pure Python (zstandard wheels, nothing to compile).
#   python wire_measure.py FRAMES.bin ENTITIES [--hz 20]
# FRAMES.bin is ticks x ENTITIES x 100 bytes (mm_to_packets.py). Every method is decoded again and compared byte for byte.
import statistics
import sys
import time

import zstandard as zstd

PKT = 100
path, ents = sys.argv[1], int(sys.argv[2])
hz = int(sys.argv[sys.argv.index("--hz") + 1]) if "--hz" in sys.argv else 20
data = open(path, "rb").read()
FRAME = ents * PKT
ticks = len(data) // FRAME
frames = [data[i * FRAME : (i + 1) * FRAME] for i in range(ticks)]
raw = lambda d: zstd.ZstdCompressionDict(d, dict_type=zstd.DICT_TYPE_RAWCONTENT)  # the previous state, as content only


def run(name, level, base_of, frame_of=lambda t: frames[t], first=8):
    sizes, tc, td = [], [], []
    for t in range(first, ticks):
        cur = frame_of(t)
        b = base_of(t)
        c = zstd.ZstdCompressor(level=level, dict_data=raw(b) if b is not None else None, write_content_size=True)
        t0 = time.perf_counter()
        z = c.compress(cur)
        t1 = time.perf_counter()
        d = zstd.ZstdDecompressor(dict_data=raw(b) if b is not None else None)
        back = d.decompress(z)
        t2 = time.perf_counter()
        assert back == cur, f"{name}: tick {t} did not decode exactly"
        sizes.append(len(z))
        tc.append((t1 - t0) * 1e6)
        td.append((t2 - t1) * 1e6)
    n = len(frames[0])
    mean = statistics.mean(sizes)
    print(
        f"WIRE {name:36s} {mean:8.0f} B/tick  {mean * hz * 8 / 1000:7.1f} kbps  {n / mean:5.1f}x  "
        f"compress {statistics.median(tc):6.0f} us  decode {statistics.median(td):5.0f} us  EXACT",
        flush=True,
    )


print(
    f"WIRE ==== {path.split('/')[-1]}: {ticks} ticks x {ents} entities x {PKT} B = {FRAME} B raw per tick at {hz} Hz "
    f"({FRAME * hz * 8 / 1000:.0f} kbps) ===="
)
run("zstd L1, no dictionary", 1, lambda t: None)
run("zstd L3, no dictionary", 3, lambda t: None)
run("zstd L1, prefix = previous tick", 1, lambda t: frames[t - 1])
run("zstd L3, prefix = previous tick", 3, lambda t: frames[t - 1])
for lag in (2, 4, 8):
    run(f"zstd L1, prefix = acked -{lag} ticks", 1, lambda t, lag=lag: frames[t - lag])

# the case that matters for a relay that forwards one datagram at a time: one 100-byte packet against that entity's own
# previous packet (no whole frame), measured over every entity and tick
sizes, tc = [], []
for t in range(8, min(ticks, 48)):
    for e in range(ents):
        cur = frames[t][e * PKT : (e + 1) * PKT]
        prev = frames[t - 1][e * PKT : (e + 1) * PKT]
        c = zstd.ZstdCompressor(level=1, dict_data=raw(prev), write_content_size=False)
        t0 = time.perf_counter()
        z = c.compress(cur)
        tc.append((time.perf_counter() - t0) * 1e6)
        assert zstd.ZstdDecompressor(dict_data=raw(prev)).decompress(z, max_output_size=PKT) == cur
        sizes.append(len(z))
m = statistics.mean(sizes)
print(
    f"WIRE {'one packet vs its previous packet':36s} {m * ents:8.0f} B/tick  {m * ents * hz * 8 / 1000:7.1f} kbps  "
    f"{PKT / m:5.1f}x  ({m:.1f} B per 100 B packet, median {statistics.median(sizes):.0f}; compress {statistics.median(tc):.0f} us)  EXACT"
)

# what actually changes between ticks, byte by byte
changed = sum(a != b for t in range(1, ticks) for a, b in zip(frames[t], frames[t - 1]))
print(f"WIRE bytes that differ from the previous tick: {changed / ((ticks - 1) * FRAME) * 100:.1f}%")
