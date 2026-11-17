# SPDX-FileCopyrightText: 2026-present K. S. Ernest (iFire) Lee
#
# SPDX-License-Identifier: MIT
"""Print the room state (count, digest, per-zone box and digest) of a file of back-to-back 100-byte packets, as JSON.

    python tools/room_state.py PACKETS.bin [ZONE_SIZE_M]

Two clients that hold the same room print the same text, so `diff` is the comparison.
"""
import os
import sys
from typing import List

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from mixer.broadcaster.room_state import read_packets, state_of  # noqa: E402

def main(argv: List[str]) -> int:
    if len(argv) not in (2, 3):
        sys.exit(__doc__)
    with open(argv[1], "rb") as f:
        packets = read_packets(f.read())
    print(state_of(packets, float(argv[2]) if len(argv) == 3 else 16.0).to_json())
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
