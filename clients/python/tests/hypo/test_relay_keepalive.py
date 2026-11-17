"""
Hypothesis tests of the client's relay keepalive (QUIC closes a quiet session; an editor is quiet between edits). No engine needed.
GOLDEN: pings go out on a timer with increasing ids while the transport runs.
INVARIANT: for any interval the number of pings is within one of elapsed / interval, and ids never repeat.
CONTROL: a cancelled keepalive sends no more pings; the interval in use is short enough for a 30 s idle timeout.
"""

import asyncio
import os
import sys
import types

from hypothesis import given, settings, strategies as st

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))
from mixer.broadcaster import relay_transport  # noqa: E402


class FakeClient:
    def __init__(self):
        self.pings = []

    def send_keepalive(self, uid):
        self.pings.append(uid)


def run(interval, duration, cancel_at=None):
    """Run the keepalive on a virtual clock, so the count does not depend on the host's timer: Windows sleeps in steps of
    about 15.6 ms, which made 0.2 s at a 0.03 s interval give 5 pings instead of 6. The fake sleep adds its argument to
    the clock and parks forever once the clock passes the stop time; the test waits on that event, not on a timeout."""
    relay_transport.KEEPALIVE_SECONDS = interval
    t = relay_transport.RelayTransport.__new__(relay_transport.RelayTransport)
    c = FakeClient()
    stop_at = cancel_at if cancel_at is not None else duration

    async def go():
        clock = {"now": 0.0}
        parked = asyncio.Event()

        async def fake_sleep(seconds):
            clock["now"] += seconds
            if clock["now"] > stop_at:
                parked.set()
                await asyncio.Event().wait()  # never set: the task is only ever cancelled
            await asyncio.sleep(0)  # let the loop run other tasks, as a real sleep would

        real = relay_transport.asyncio
        relay_transport.asyncio = types.SimpleNamespace(sleep=fake_sleep)
        try:
            task = asyncio.ensure_future(t._keepalive(c))
            await parked.wait()
        finally:
            relay_transport.asyncio = real
        task.cancel()
        n = len(c.pings)
        await asyncio.sleep(0)
        return n

    return asyncio.run(go()), c.pings


def test_golden_pings_with_increasing_ids():
    n, pings = run(0.05, 0.28)
    assert n >= 4 and pings == list(range(1, len(pings) + 1))


@settings(max_examples=8, deadline=None)
@given(st.sampled_from([0.03, 0.05, 0.08]), st.sampled_from([0.2, 0.3]))
def test_invariant_count_follows_the_interval(interval, duration):
    n, pings = run(interval, duration)
    assert abs(n - duration / interval) <= 1 and len(set(pings)) == len(pings)


def test_control_cancelled_stops_and_the_default_is_short_enough():
    n, pings = run(0.03, 0.3, cancel_at=0.1)
    assert len(pings) == n  # nothing after the cancel
    import importlib

    importlib.reload(relay_transport)
    assert relay_transport.KEEPALIVE_SECONDS <= 10.0
