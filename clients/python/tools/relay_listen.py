# MIT. Copyright (c) 2026-present K. S. Ernest (iFire) Lee
# An admitted client of the relay's Mixer mode that joins a room and prints how each entity's pose changes.
#   MB_PORT MB_CERT MB_ZT_MINTER  python tools/relay_listen.py ROOM SECONDS
import asyncio
import base64
import os
import struct
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.dirname(__file__))
import zt  # noqa: E402
from mixer.broadcaster import common  # noqa: E402
from mixer.broadcaster.common import MessageType as T  # noqa: E402
from mixer.broadcaster.relay import open_relay  # noqa: E402

PORT, CERT = int(os.environ["MB_PORT"]), os.environ["MB_CERT"]
ROOM, SECONDS = sys.argv[1], float(sys.argv[2])


def join_data(room, blender_version, mixer_version):
    return (
        common.encode_string(room)
        + common.encode_string(blender_version)
        + common.encode_string(mixer_version)
        + common.encode_bool(False)
        + common.encode_bool(False)
    )


async def main():
    async with open_relay("127.0.0.1", PORT, CERT) as c:
        priv, pub = zt.gen_key()
        token = base64.urlsafe_b64decode(zt.get_token([ROOM], pub) + "==")
        await c.login(token, pub, lambda n: zt.sign_session(priv, n))
        print("LISTEN admitted", flush=True)
        joined, t0, seen, count, types = False, time.time(), {}, 0, {}
        while time.time() - t0 < SECONDS:
            if not joined:
                c.send_command(T.LIST_ROOMS, b"")
            await asyncio.sleep(0.2)
            while not c.commands.empty():
                t, owner, data = c.commands.get_nowait()
                types[T(t).name if t in T._value2member_map_ else t] = (
                    types.get(T(t).name if t in T._value2member_map_ else t, 0) + 1
                )
                if t == T.LIST_ROOMS and not joined:
                    room = common.decode_json(data, 0)[0].get(ROOM)
                    if room and room.get(
                        "joinable"
                    ):  # join with the room's own versions, as a client that matches it would
                        c.send_command(T.JOIN_ROOM, join_data(ROOM, room["blender_version"], room["mixer_version"]))
                if t == T.JOIN_ROOM and not joined:
                    joined = True
                    print("LISTEN joined", ROOM, flush=True)
                if t == T.ENTITY_REMOVE:
                    print(f"LISTEN t={time.time()-t0:5.1f}s entity {struct.unpack('<I', data)[0]} removed", flush=True)
            while not c.poses.empty():
                d = c.poses.get_nowait()
                if len(d) != 100:
                    continue
                count += 1
                gid = struct.unpack_from("<I", d, 0)[0]
                pos = tuple(round(v / 1e6, 2) for v in struct.unpack_from("<3q", d, 4))
                if seen.get(gid) != pos:
                    seen[gid] = pos
                    print(f"LISTEN t={time.time()-t0:5.1f}s entity {gid} at wire {pos}", flush=True)
        print(f"LISTEN {count} pose packets, entities {sorted(seen)}; commands seen {types}", flush=True)


asyncio.run(main())
