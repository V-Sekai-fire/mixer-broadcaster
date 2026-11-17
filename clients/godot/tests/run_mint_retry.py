#!/usr/bin/env python3
"""Test the Godot client's token retry: start Godot first, bring the minter up late.

Needs the entities-zone double editor in GODOT (stock Godot lacks WebTransportPeer and Sandbox, so main.gd does not parse).
The minter here is a stand-in that answers POST /mint with {"token": ...}; the real one needs a relay build.
"""
import json, os, socket, subprocess, sys, threading, time
from http.server import BaseHTTPRequestHandler, HTTPServer

GODOT = os.environ.get("GODOT", "godot.macos.editor.double.arm64")
PROJECT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


class Minter(BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get("content-length", 0)))
        body = json.dumps({"token": "stand-in-token"}).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def run(attempts, minter_up_after):
    """Start Godot now; start the minter after `minter_up_after` seconds (None: never)."""
    port = free_port()
    env = dict(os.environ, MB_MINTER=f"http://127.0.0.1:{port}", MB_ATTEMPTS=str(attempts))
    srv = None
    if minter_up_after is not None:
        def late():
            nonlocal srv
            time.sleep(minter_up_after)
            srv = HTTPServer(("127.0.0.1", port), Minter)
            srv.serve_forever()
        threading.Thread(target=late, daemon=True).start()
    p = subprocess.run([GODOT, "--headless", "--path", PROJECT, "-s", "res://tests/mint_retry_test.gd"],
                       env=env, capture_output=True, text=True, timeout=120)
    if srv:
        srv.shutdown()
    return p.returncode, p.stdout + p.stderr


def main():
    failed = []
    cases = [
        ("minter up 2.5s late, 6 attempts: gets the token", 6, 2.5, 0, "MINT_OK"),
        ("control: same late minter, 1 attempt: fails (the old behaviour)", 1, 2.5, 1, "MINT_FAIL"),
        ("minter never up, 3 attempts: gives up with a log", 3, None, 1, "after 3 attempts"),
    ]
    for name, attempts, up, code, needle in cases:
        rc, out = run(attempts, up)
        ok = rc == code and needle in out
        print(("PASS " if ok else "FAIL ") + name)
        if not ok:
            failed.append(name)
            print(out)
        else:
            print("\n".join("    " + l for l in out.splitlines() if "minter" in l or "MINT_" in l))
    sys.exit(1 if failed else 0)


main()
