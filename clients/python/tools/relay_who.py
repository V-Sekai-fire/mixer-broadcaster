# MIT. What the client's panel would show: join the closed relay as a client and print the room list and the
# user list it receives. env: MB_PORT, MB_CERT, MB_ZT_MINTER (from tools/zt_stack.py); argv[1] = the room (default live).
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import base64  # noqa: E402

from mixer.broadcaster import common  # noqa: E402
from mixer.broadcaster.client import Client  # noqa: E402

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import zt  # noqa: E402

Client.relay_cafile = os.environ["MB_CERT"]
room = sys.argv[1] if len(sys.argv) > 1 else "live"


def creds():
    priv, pub = zt.gen_key()
    token = base64.urlsafe_b64decode(zt.get_token([room], pub) + "==")
    return token, pub, lambda nonce: zt.sign_session(priv, nonce)


c = Client("127.0.0.1", int(os.environ["MB_PORT"]))
Client.relay_credentials = creds
c.connect()
for t in (common.MessageType.CLIENT_ID, common.MessageType.LIST_CLIENTS, common.MessageType.LIST_ROOMS):
    c.add_command(common.Command(t))
T = common.MessageType
rooms, clients = {}, {}
end = time.time() + 2
while time.time() < end:
    for cmd in c.fetch_commands():
        if cmd.type == T.LIST_ROOMS:
            rooms.update(common.decode_json(cmd.data, 0)[0])
        elif cmd.type == T.LIST_CLIENTS:
            clients.update(common.decode_json(cmd.data, 0)[0])
        elif cmd.type == T.CLIENT_ID:
            me = cmd.data.decode()
    time.sleep(0.05)
print("WHO rooms", {k: {a: v for a, v in d.items() if a in ("keep_open", "command_count")} for k, d in rooms.items()})
print("WHO clients", {k: (d.get("room"), d.get("user_name")) for k, d in clients.items()})
