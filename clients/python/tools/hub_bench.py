# MIT. Measure the relay from outside: handshake time, set -> fan-out latency, delivery. Writes /tmp/relay_data.json.
import asyncio, json, statistics, sys, time

sys.argv = [sys.argv[0]] + sys.argv[1:]
from aioquic.asyncio import connect
from aioquic.h3.connection import H3_ALPN
from aioquic.quic.configuration import QuicConfiguration

sys.path.insert(0, __file__.rsplit("/", 1)[0])
import importlib.util

spec = importlib.util.spec_from_file_location("hbc_hub", __file__.replace("hub_bench.py", "hub_probe.py"))

# reuse the Hub protocol class from hub_probe without running its main()
src = open(__file__.replace("hub_bench.py", "hub_probe.py")).read().split("async def client")[0]
ns = {}
exec(compile(src, "hub_probe_head", "exec"), ns)
Hub = ns["Hub"]


async def join(port, cert, room):
    cfg = QuicConfiguration(is_client=True, alpn_protocols=H3_ALPN, max_datagram_frame_size=65536)
    cfg.load_verify_locations(cert)
    cfg.server_name = "localhost"
    t0 = time.perf_counter()
    ctx = connect("127.0.0.1", port, configuration=cfg, create_protocol=Hub)
    p = await ctx.__aenter__()
    await p.wait_connected()
    await p.open("127.0.0.1", port, room)
    return ctx, p, (time.perf_counter() - t0) * 1000


async def main(port, cert):
    hs = []
    for i in range(15):
        ctx, p, ms = await join(port, cert, f"hs{i}")
        hs.append(ms)
        await ctx.__aexit__(None, None, None)
    ca, a, _ = await join(port, cert, "bench")
    cb, b, _ = await join(port, cert, "bench")
    sent, lat = {}, []
    N = 200
    orig = a.datagrams.put_nowait  # stamp each datagram the instant QUIC hands it over,
    a.datagrams.put_nowait = lambda m: orig((time.perf_counter(), m))  # not when this loop gets around to it
    for i in range(N):
        t = time.perf_counter()
        ack = await b.send({"t": "set", "id": i % 24, "rgb": [i % 256, (i * 7) % 256, (i * 13) % 256]})
        assert ack and ack.get("t") == "ok", ack
        try:
            arrived, m = await asyncio.wait_for(a.datagrams.get(), 1.0)
            lat.append((arrived - t) * 1000)
        except asyncio.TimeoutError:
            pass
    q = sorted(lat)
    out = {
        "handshake_ms": {"n": len(hs), "p50": round(statistics.median(hs), 1), "max": round(max(hs), 1)},
        "fanout_ms": {
            "n_sent": N,
            "n_delivered": len(lat),
            "p50": round(q[len(q) // 2], 2),
            "p95": round(q[int(len(q) * 0.95)], 2),
            "max": round(q[-1], 2),
        },
    }
    print(json.dumps(out))
    open("/tmp/relay_data.json", "w").write(json.dumps(out))
    await cb.__aexit__(None, None, None)
    await ca.__aexit__(None, None, None)


asyncio.run(main(int(sys.argv[1]), sys.argv[2]))
