# MIT License
#
# Copyright (c) 2026-present K. S. Ernest (iFire) Lee
#
# Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
# documentation files (the "Software"), to deal in the Software without restriction. THE SOFTWARE IS PROVIDED "AS IS",
# WITHOUT WARRANTY OF ANY KIND.

"""
The zero-trust test stack: a closed relay and a minter, with keys that stay the same between runs.

  relay    MB_SERVE=1, holds only the root key. Refuses everyone without a token and a signed nonce.
  minter   holds the root key (to issue) and the third-party key (to discharge); the clients know only its address.

Run it, wait for the `ZT READY` line, give the clients the three values it prints, and stop it with a signal.
The two keys are constant: made once, kept in the macOS login Keychain (service mixer-relay-test), and read back on
each run. They sit in this process and the relay's and minter's environments; they are never printed.

  python tools/zt_stack.py [--port 4466] [--minter-port 4467]
"""

import argparse
import hashlib
import json
import os
import secrets
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BROADCASTER = os.environ.get(
    "MIXER_BROADCASTER",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."),
)
SERVICE = "mixer-relay-test"
BAO_NAME = {"root": "root-key", "third-party": "third-party-key"}


def bao_key(account):
    """The key from OpenBao (mount mixer-relay), read as this desk's agent: a certificate login, no stored token.
    None if Bao cannot be reached or the item is not there."""
    home = os.path.expanduser("~")
    agent = os.environ.get("BAO_AGENT", "mac-mini-fire-041138")
    try:
        host = (
            subprocess.run([home + "/.local/bin/bao-active-host"], capture_output=True, text=True, timeout=20)
            .stdout.strip()
            .splitlines()[-1]
        )
    except Exception:
        return None
    d = f"{home}/.bao-creds/{agent}"
    env = dict(
        os.environ,
        BAO_ADDR=f"https://{host}:8200",
        BAO_TLS_SERVER_NAME="weftspun-bao.internal",
        BAO_CACERT=f"{home}/.bao.d/server-ca.pem",
        BAO_CLIENT_CERT=f"{d}/cert-fullchain.pem",
        BAO_CLIENT_KEY=f"{d}/key.pem",
    )
    login = subprocess.run(
        ["bao", "login", "-method=cert", "-no-store", "-token-only"], env=env, capture_output=True, text=True
    )
    if login.returncode != 0:
        return None
    env["BAO_TOKEN"] = login.stdout.strip()
    got = subprocess.run(
        ["bao", "kv", "get", "-mount=mixer-relay", "-field=key", BAO_NAME[account]],
        env=env,
        capture_output=True,
        text=True,
    )
    key = got.stdout.strip()
    return key if got.returncode == 0 and len(key) == 64 else None


def keychain_key(account):
    """A 32-byte key that stays the same from run to run. First choice is OpenBao; if Bao cannot be reached, the macOS
    login Keychain copy. If neither has it, make it and put it in the Keychain. It is never printed."""
    key = bao_key(account)
    if key:
        print(f"ZT key {account}: from OpenBao", flush=True)
        return key
    found = subprocess.run(
        ["security", "find-generic-password", "-s", SERVICE, "-a", account, "-w"], capture_output=True, text=True
    )
    if found.returncode == 0 and len(found.stdout.strip()) == 64:
        print(f"ZT key {account}: from the Keychain (Bao was not reachable)", flush=True)
        return found.stdout.strip()
    key = secrets.token_hex(32)
    made = subprocess.run(
        [
            "security",
            "add-generic-password",
            "-U",
            "-s",
            SERVICE,
            "-a",
            account,
            "-w",
            key,
            "-j",
            "mixer relay test key; the relay's root key or the minter's third-party key",
        ],
        capture_output=True,
        text=True,
    )
    if made.returncode != 0:
        sys.exit("cannot store the key in the Keychain: " + made.stderr.strip()[:120])
    print(f"ZT key {account}: new, in the Keychain", flush=True)
    return key


RELAY_PORT = [4466]
ROOT, TP = keychain_key("root"), keychain_key("third-party")
TTL = 3600


def mint(room, key_b64, ops=()):  # room: one name, or a list of names for a token that covers several
    import base64

    pub = base64.urlsafe_b64decode(key_b64 + "==")
    code = (
        'root = Base.decode16!(System.fetch_env!("MB_ROOT_KEY"), case: :mixed)\n'
        'tp = Base.decode16!(System.fetch_env!("MB_TP_KEY"), case: :mixed)\n'
        'room = case String.split(System.fetch_env!("ZT_ROOM"), "\\n", trim: true) do [one] -> one; many -> many end\n'
        'thumb = Base.decode16!(System.fetch_env!("ZT_THUMB"), case: :lower)\n'
        'ops = String.split(System.get_env("ZT_OPS", ""), "\\n", trim: true)\n'
        't = MixerBroadcaster.Token.issue(root, room, "minter", tp, ops)\n'
        '{:ok, full} = MixerBroadcaster.Token.discharge(t, tp, thumb, String.to_integer(System.fetch_env!("ZT_TTL")), System.os_time(:second))\n'
        'IO.puts("TOKEN " <> Base.url_encode64(full, padding: false))\n'
    )
    env = dict(
        os.environ,
        MB_ROOT_KEY=ROOT,
        MB_TP_KEY=TP,
        ZT_ROOM=(room if isinstance(room, str) else "\n".join(room)),
        ZT_OPS="\n".join(ops),
        ZT_THUMB=hashlib.sha256(pub).hexdigest(),
        ZT_TTL=str(TTL),
        MIX_ENV="dev",
    )
    env.pop("MB_SERVE", None)
    out = subprocess.run(
        ["mix", "run", "--no-start", "-e", code], cwd=BROADCASTER, env=env, capture_output=True, text=True
    )
    for line in out.stdout.splitlines():
        if line.startswith("TOKEN "):
            return line[6:]
    raise RuntimeError("mint failed")


def cert_sha256():
    import ssl

    pem = open(os.path.join(tempfile.gettempdir(), "mb_relay_cert", "cert.pem")).read()
    return list(hashlib.sha256(ssl.PEM_cert_to_DER_cert(pem)).digest())


class Minter(BaseHTTPRequestHandler):
    # The test viewer page is served from here (same origin as /mint), with the relay's address and certificate hash.
    def do_GET(self):
        if self.path.split("?")[0] == "/connection":
            data, kind = (
                json.dumps({"wt_port": RELAY_PORT[0], "cert_sha256": cert_sha256()}).encode(),
                "application/json",
            )
        elif self.path.split("?")[0] in ("/", "/live.html"):
            data, kind = open(os.path.join(BROADCASTER, "priv", "static", "live.html"), "rb").read(), "text/html"
        else:
            self.send_response(404)
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("content-type", kind)
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        try:
            n = int(self.headers.get("content-length", "0"))
            body = json.loads(self.rfile.read(n))
            room = body["rooms"] if "rooms" in body else str(body["room"])
            token = mint(
                room if isinstance(room, str) else [str(r) for r in room],
                str(body["key"]),
                [str(o) for o in body.get("ops", [])],
            )
            data = json.dumps({"token": token}).encode()
            self.send_response(200)
        except Exception:
            data = b'{"error":"mint"}'
            self.send_response(400)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *a):
        pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=4466)
    ap.add_argument("--minter-port", type=int, default=4467)
    a = ap.parse_args()
    RELAY_PORT[0] = a.port
    srv = ThreadingHTTPServer(("127.0.0.1", a.minter_port), Minter)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    env = dict(
        os.environ,
        MB_SERVE="1",
        MB_ROOT_KEY=ROOT,
        MB_WT_PORT=str(a.port),
        MB_BIND="127.0.0.1",
        MIX_ENV="dev",
        MB_ORIGINS=f"http://127.0.0.1:{a.minter_port},http://localhost:{a.minter_port}",
    )  # the test page is served by the minter
    env.pop("MB_TP_KEY", None)  # the relay never sees the third-party key
    relay = subprocess.Popen(
        ["mix", "run", "--no-halt"],
        cwd=BROADCASTER,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    cert = os.path.join(tempfile.gettempdir(), "mb_relay_cert", "cert.pem")
    for line in relay.stdout:
        if line.startswith("relay up"):
            print(f"ZT READY MB_PORT={a.port} MB_CERT={cert} MB_ZT_MINTER=http://127.0.0.1:{a.minter_port}", flush=True)
            break
        if "refuses to start" in line or "** (" in line:
            print("ZT FAILED " + line.strip(), flush=True)
            relay.kill()
            sys.exit(1)
    try:
        with open(os.path.join(tempfile.gettempdir(), "relay.log"), "a") as log:
            for line in relay.stdout:  # keep draining so the relay never blocks on a full pipe; keep it for the error
                log.write(line)
                log.flush()
    except KeyboardInterrupt:
        pass
    finally:
        relay.terminate()


if __name__ == "__main__":
    main()
