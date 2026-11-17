"""Write command packets for the Elixir side to decode and re-encode: type,owner,hlc,data,packet,bulk (hex)."""

import hashlib
import os
import random
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from mixer.broadcaster import entity

rng = random.Random(20261116)
rows = ["type,owner,hlc,data,packet,bulk"]
sizes = [0, 1, 4, 20, 33, 34, 35, 76, 77, 78, 79, 100, 500, 4000]
types = [1, 3, 4, 5, 6, 7, 11, 14, 100, 101, 139, 200, 209, 211, 255, 256, 1000, 65535]
for i in range(96):
    t = types[i % len(types)]
    data = rng.randbytes(rng.choice(sizes))
    if i % 3 == 0 and len(data) >= 8:  # a leading name, as Mixer paths have
        name = rng.randbytes(rng.randint(1, 20)).hex().encode()
        data = len(name).to_bytes(4, "little") + name + data[4 + len(name) :]
    owner, hlc = rng.randrange(1 << 24), rng.randrange(1 << 64)
    got = {}
    pkt = entity.pack_command(t, data, owner, lambda d: got.setdefault("d", d) and hashlib.sha256(d).digest(), hlc)
    rows.append(f"{t},{owner},{hlc},{data.hex()},{pkt.hex()},{'1' if got else '0'}")
out = sys.argv[1]
open(out, "w").write("\n".join(rows) + "\n")
print(len(rows) - 1, "rows,", sum(r.endswith(",1") for r in rows[1:]), "by digest")
