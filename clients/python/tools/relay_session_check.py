# MIT. Copyright (c) 2026-present K. S. Ernest (iFire) Lee
# The relay's Mixer mode, end to end, over HTTP/3 WebTransport, on the closed relay (tools/zt_stack.py must be running).
#   MB_PORT MB_CERT MB_ZT_MINTER come from zt_stack.py.  python tools/relay_session_check.py
#
#   a  token for rooms m1 and m2: creates m1, stores a 6 KB command (by digest through the SeaweedFS filer) and a pose
#   b  token for m1: joins late, must be replayed the command and the pose, then hear a live pose
#   c  token for m2 only: asks to join m1 and must be refused; must hear nothing of m1; its room list leaves m1 out
#   d  never logs in: its join gets nothing, its pose goes nowhere
import asyncio
import os
import struct
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.dirname(__file__))
import zt  # noqa: E402
from mixer.broadcaster import common, entity  # noqa: E402
from mixer.broadcaster.common import MessageType as T  # noqa: E402
from mixer.broadcaster.relay import open_relay  # noqa: E402

PORT, CERT = int(os.environ["MB_PORT"]), os.environ["MB_CERT"]
ROOM = os.environ.get("ROOM", "m1")
BULK = os.urandom(3000).hex().encode()  # 6000 bytes: far over the 77 a packet holds


def join_data(room):
    return (
        common.encode_string(room)
        + common.encode_string("5.3")
        + common.encode_string("1")
        + common.encode_bool(False)
        + common.encode_bool(False)
    )


def pose(gid, x):
    return struct.pack("<I", gid) + bytes([x]) * 94 + bytes(2)  # the two reserved bytes are zero


async def login(client, rooms):
    priv, pub = zt.gen_key()
    token = await asyncio.get_event_loop().run_in_executor(
        None, lambda: __import__("base64").urlsafe_b64decode(zt.get_token(rooms, pub) + "==")
    )
    await client.login(token, pub, lambda n: zt.sign_session(priv, n))


async def drain(client, wait=1.0):
    """Everything that arrives within `wait` seconds: (commands, poses)."""
    cmds, poses = [], []
    deadline = asyncio.get_event_loop().time() + wait
    while (left := deadline - asyncio.get_event_loop().time()) > 0:
        try:
            cmds.append(await client.next_command(left))
        except asyncio.TimeoutError:
            break
    while not client.poses.empty():
        poses.append(client.poses.get_nowait())
    return cmds, poses


def names(cmds):
    return [T(t).name if t in T._value2member_map_ else t for t, _, _ in cmds]


ok = True


def check(label, cond, detail=""):
    detail = str(detail) if detail != "" else ""
    global ok
    ok &= bool(cond)
    print(("PASS " if cond else "FAIL ") + label + (f"  [{detail}]" if detail else ""), flush=True)


async def main():
    async with open_relay("127.0.0.1", PORT, CERT) as a, open_relay("127.0.0.1", PORT, CERT) as b, open_relay(
        "127.0.0.1", PORT, CERT
    ) as c, open_relay("127.0.0.1", PORT, CERT) as d:
        await asyncio.gather(
            login(a, ["m1", "m2"]), login(b, ["m1"]), login(c, os.environ.get("C_ROOMS", "m2").split(","))
        )
        print("admitted: a (m1,m2), b (m1), c (m2); d stays out", flush=True)

        a.send_command(T.JOIN_ROOM, join_data(ROOM))
        cmds, _ = await drain(a)
        check(
            "a creates the room and is asked for the content", names(cmds)[:2] == ["JOIN_ROOM", "CONTENT"], names(cmds)
        )
        a.send_command(T.CONTENT, b"")
        a.send_command(120, common.encode_string("/Cube") + BULK)  # bulk: by digest through the filer
        a.send_pose(pose(7, 1))
        await drain(a, 0.8)

        b.send_command(T.JOIN_ROOM, join_data(ROOM))
        cmds, poses = await drain(b, 1.5)
        bulk = [d_ for t, _, d_ in cmds if t == 120]
        check(
            "b joins late: cleared, replayed, then joined",
            "CLEAR_CONTENT" in names(cmds) and names(cmds)[-1] in ("JOIN_ROOM", "ROOM_UPDATE", "CLIENT_UPDATE"),
            names(cmds),
        )
        check(
            "b gets the 6 KB command whole, from the store",
            bulk == [common.encode_string("/Cube") + BULK],
            f"{len(bulk)} copies",
        )
        check(
            "b gets the stored pose of entity 7",
            any(p[:4] == struct.pack("<I", 7) for p in poses),
            f"{len(poses)} poses",
        )

        a.send_pose(pose(7, 9))
        _, poses = await drain(b, 1.0)
        live = [p for p in poses if p[:4] == struct.pack("<I", 7)]
        check(
            "b hears a's live pose, stamped by the relay",
            live and live[-1][4:5] == bytes([9]) and struct.unpack_from("<Q", live[-1], 40)[0] != 0,
        )
        _, poses_a = await drain(a, 0.5)
        check("a does not hear its own pose", not [p for p in poses_a if p[4:5] == bytes([9])])

        c.send_command(T.JOIN_ROOM, join_data(ROOM))
        cmds, _ = await drain(c, 1.0)
        check(
            "c (token for m2 only) is refused m1",
            "SEND_ERROR" in names(cmds) and "JOIN_ROOM" not in names(cmds),
            names(cmds),
        )
        c.send_command(T.LIST_ROOMS, b"")
        cmds, _ = await drain(c, 1.0)
        listed = [common.decode_json(d_, 0)[0] for t, _, d_ in cmds if t == T.LIST_ROOMS]
        check("c's room list leaves m1 out", listed == [{}], listed)
        a.send_pose(pose(7, 33))
        cmds, poses = await drain(c, 1.0)
        check("c hears nothing of m1: no pose, no room or client update", not poses and not cmds, names(cmds))

        d.send_command(T.JOIN_ROOM, join_data(ROOM))
        d.send_pose(pose(7, 77))
        cmds, poses = await drain(d, 1.0)
        check("d (no login) hears nothing", not cmds and not poses)
        _, poses_b = await drain(b, 0.5)
        check("d's pose never reached the room", not [p for p in poses_b if p[4:5] == bytes([77])])
        check(
            "no malformed packets seen by any client",
            not (a.errors or b.errors or c.errors),
            a.errors + b.errors + c.errors,
        )
    print("RESULT", "ALL PASS" if ok else "FAILED")
    sys.exit(0 if ok else 1)


asyncio.run(main())
