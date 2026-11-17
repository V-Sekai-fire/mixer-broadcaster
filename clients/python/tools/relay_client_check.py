# MIT. Copyright (c) 2026-present K. S. Ernest (iFire) Lee
# The client's own `Client` class, pointed at the closed relay, with two clients: create, store, late join, scope.
#   MB_PORT MB_CERT MB_ZT_MINTER from tools/zt_stack.py.   python tools/relay_client_check.py
import base64
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.dirname(__file__))
import zt  # noqa: E402
from mixer.broadcaster import common, entity  # noqa: E402
from mixer.broadcaster.client import Client  # noqa: E402
from mixer.broadcaster.common import MessageType as T  # noqa: E402

PORT, CERT = int(os.environ["MB_PORT"]), os.environ["MB_CERT"]
Client.relay_cafile = CERT


def credentials_for(rooms):
    def creds():
        priv, pub = zt.gen_key()
        token = base64.urlsafe_b64decode(zt.get_token(list(rooms), pub) + "==")
        return token, pub, lambda nonce: zt.sign_session(priv, nonce)

    return creds


def client(rooms):
    c = Client("127.0.0.1", PORT)
    Client.relay_credentials = credentials_for(rooms)  # read through the class at connect
    c.connect()
    c.add_command(common.Command(T.CLIENT_ID))  # the client asks for its id and the lists at connect
    c.add_command(common.Command(T.LIST_CLIENTS))
    c.add_command(common.Command(T.LIST_ROOMS))
    return c


def pump(clients, seconds=1.5):
    got = {id(c): [] for c in clients}
    end = time.time() + seconds
    while time.time() < end:
        for c in clients:
            got[id(c)] += c.fetch_commands()
        time.sleep(0.05)
    return got


ok = True


def check(label, cond, detail=""):
    global ok
    ok &= bool(cond)
    print(("PASS " if cond else "FAIL ") + label + (f"  [{detail}]" if detail else ""), flush=True)


a, b, c = client(["w1", "w2"]), client(["w1"]), client(["w2"])
try:
    pump([a, b, c], 1.0)
    check(
        "the client's clients are connected and have their ids",
        a.client_id and b.client_id and a.client_id != b.client_id,
        (a.client_id, b.client_id),
    )

    a.join_room("w1", "5.3", "1", False, False)
    pump([a], 1.0)
    check("a created w1 (current_room set by the client's own handler)", a.current_room == "w1", a.current_room)
    a.send_command(common.Command(T.CONTENT))
    mesh = os.urandom(2000).hex().encode()
    a.send_command(common.Command(T.GREASE_PENCIL_MESH, common.encode_string("/Mesh") + mesh))
    pose = (7).to_bytes(4, "little") + bytes([5]) * 94 + bytes(2)
    a.send_command(common.Command(T.ENTITY_STATE, pose))
    pump([a], 1.0)

    b.join_room("w1", "5.3", "1", False, False)
    got = pump([b], 2.0)[id(b)]
    types = [x.type for x in got]
    check("b joined late through the client class", b.current_room == "w1" and T.JOIN_ROOM in types, b.current_room)
    meshes = [x.data for x in got if x.type == T.GREASE_PENCIL_MESH]
    check(
        "b got the 4 KB command whole (bulk through the store)",
        meshes == [common.encode_string("/Mesh") + mesh],
        len(meshes),
    )
    check(
        "b got the stored pose as ENTITY_STATE",
        any(x.type == T.ENTITY_STATE and x.data[:4] == (7).to_bytes(4, "little") for x in got),
        [t.name for t in types],
    )

    a.send_command(common.Command(T.ENTITY_REMOVE, (7).to_bytes(4, "little")))
    got = pump([b], 1.0)[id(b)]
    check("b hears ENTITY_REMOVE", any(x.type == T.ENTITY_REMOVE and x.data == (7).to_bytes(4, "little") for x in got))

    c.join_room("w1", "5.3", "1", False, False)
    got = pump([c], 1.5)[id(c)]
    check(
        "c (token for w2) is refused w1",
        c.current_room is None and T.SEND_ERROR in [x.type for x in got],
        [x.type.name for x in got],
    )
finally:
    for x in (a, b, c):
        x.disconnect()
print("RESULT", "ALL PASS" if ok else "FAILED")
sys.exit(0 if ok else 1)
