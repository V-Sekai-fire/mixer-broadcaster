# MIT. Keep open through the client's own Client against the closed relay: a room set to keep open outlives its last
# player, one that is not set goes with it. MB_PORT MB_CERT MB_ZT_MINTER from tools/zt_stack.py.
import base64
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import zt  # noqa: E402
from mixer.broadcaster import common  # noqa: E402
from mixer.broadcaster.client import Client  # noqa: E402

T = common.MessageType
Client.relay_cafile = os.environ["MB_CERT"]
STAMP = str(os.getpid())
KEPT, GONE = f"kept-{STAMP}", f"gone-{STAMP}"


def client():
    def creds():
        priv, pub = zt.gen_key()
        return base64.urlsafe_b64decode(zt.get_token([KEPT, GONE], pub) + "=="), pub, lambda n: zt.sign_session(priv, n)

    Client.relay_credentials = creds
    c = Client("127.0.0.1", int(os.environ["MB_PORT"]))
    c.connect()
    c.add_command(common.Command(T.CLIENT_ID))
    return c


def pump(c, seconds=1.2):
    got = []
    end = time.time() + seconds
    while time.time() < end:
        got += c.fetch_commands()
        time.sleep(0.05)
    return got


def rooms_seen(c):
    c.add_command(common.Command(T.LIST_ROOMS))
    out = {}
    for cmd in pump(c):
        if cmd.type == T.LIST_ROOMS:
            out.update(common.decode_json(cmd.data, 0)[0])
    return out


ok = True


def check(label, cond, detail=""):
    global ok
    ok &= bool(cond)
    print(("PASS " if cond else "FAIL ") + label + (f"  [{detail}]" if detail else ""), flush=True)


a, b = client(), client()
try:
    pump(a)
    pump(b)
    a.join_room(KEPT, "5.3", "1", False, False)
    pump(a)
    a.set_room_keep_open(KEPT, True)
    updates = [cmd for cmd in pump(a) if cmd.type == T.ROOM_UPDATE]
    seen = [common.decode_json(u.data, 0)[0] for u in updates]
    check(
        "a is told the room is kept open (ROOM_UPDATE)",
        any(KEPT in u and u[KEPT].get("keep_open") is True for u in seen),
        seen,
    )
    a.leave_room(KEPT)
    pump(a)
    r = rooms_seen(b)
    check("the kept room outlives its last player", KEPT in r and r[KEPT].get("keep_open") is True, list(r))

    a.join_room(GONE, "5.3", "1", False, False)
    pump(a)
    a.leave_room(GONE)
    pump(a)
    r = rooms_seen(b)
    check("control: a room not kept open goes with its last player", GONE not in r, list(r))

    b.join_room(KEPT, "5.3", "1", False, False)
    pump(b)
    b.set_room_keep_open(KEPT, False)
    pump(b)
    b.leave_room(KEPT)
    pump(b)
    r = rooms_seen(a)
    check("keep open turned off: the room goes when the last player leaves", KEPT not in r, list(r))
finally:
    for x in (a, b):
        x.disconnect()
print("RESULT", "ALL PASS" if ok else "FAILED")
sys.exit(0 if ok else 1)
