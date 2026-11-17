# SPDX-FileCopyrightText: 2026-present K. S. Ernest (iFire) Lee
#
# SPDX-License-Identifier: MIT
"""Join a room of the closed relay and print its state (count, digest, per-zone box and digest) as JSON.

    MB_TOKEN=<base64url token> MB_KEY=<64 hex characters, the P-256 private scalar> \\
        python tools/room_join.py HOST PORT CERT.pem ROOM [ZONE_SIZE_M]

The token and key come from the environment, not the command line, so they stay out of the process list. Exit 0 with the
state on stdout; exit 2 with the reason on stderr when the relay refuses the door.
"""
import asyncio
import base64
import os
import sys
from typing import List

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from mixer.broadcaster.room_join import join, private_key  # noqa: E402


def main(argv: List[str]) -> int:
    if len(argv) not in (5, 6) or not os.environ.get("MB_TOKEN") or not os.environ.get("MB_KEY"):
        sys.exit(__doc__)
    host, port, cafile, room = argv[1], int(argv[2]), argv[3], argv[4]
    token = base64.urlsafe_b64decode(os.environ["MB_TOKEN"] + "==")
    key = private_key(bytes.fromhex(os.environ["MB_KEY"]))
    zone = float(argv[5]) if len(argv) == 6 else 16.0
    try:
        state = asyncio.run(join(host, port, cafile, room, token, key, zone_size_m=zone))
    except RuntimeError as e:
        print(f"refused: {e}", file=sys.stderr)
        return 2
    print(state.snapshot().to_json())
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
