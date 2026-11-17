"""
Hypothesis tests of PublishCache: the store never grows with a publish that is not needed. No engine needed.
GOLDEN: the same bytes publish once; new bytes publish again; the digest is what `publish` returned.
INVARIANT: over any run of edits the number of real publishes equals the number of distinct byte strings seen (when the
  interval never blocks), and an object is never ready twice inside the interval.
CONTROL: a cache of capacity 1 still answers right, a failed publish is not remembered, and an object edited inside
  the interval is held back while another object is not.
"""

import hashlib
import os
import sys

import pytest
from hypothesis import given, settings, strategies as st

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))
from mixer.broadcaster.geo_publish import PublishCache  # noqa: E402


class Clock:
    def __init__(self):
        self.t = 0.0

    def __call__(self):
        return self.t


def fake_publish(log):
    def publish(data):
        log.append(data)
        return hashlib.sha256(b"idx" + data).digest()

    return publish


def test_golden_same_bytes_publish_once():
    log, clock = [], Clock()
    c = PublishCache(fake_publish(log), 1.0, clock=clock)
    d1 = c.digest("a", b"mesh-1")
    clock.t = 5
    d2 = c.digest("a", b"mesh-1")
    assert d1 == d2 == hashlib.sha256(b"idx" + b"mesh-1").digest()
    assert c.published == 1 and log == [b"mesh-1"]
    clock.t = 10
    d3 = c.digest("a", b"mesh-2")
    assert d3 != d1 and c.published == 2


def test_golden_undo_returns_to_an_old_mesh_without_publishing():
    log, clock = [], Clock()
    c = PublishCache(fake_publish(log), 0.0, clock=clock)
    first = c.digest("a", b"v1")
    c.digest("a", b"v2")
    assert c.digest("a", b"v1") == first and c.published == 2


def test_golden_a_copy_of_a_mesh_on_another_object_publishes_once():
    log, clock = [], Clock()
    c = PublishCache(fake_publish(log), 0.0, clock=clock)
    assert c.digest("a", b"same") == c.digest("b", b"same") and c.published == 1


def test_control_ready_holds_one_object_not_another():
    clock = Clock()
    c = PublishCache(fake_publish([]), 1.0, clock=clock)
    assert c.ready("a") and c.ready("b")
    c.digest("a", b"x")
    clock.t = 0.5
    assert not c.ready("a") and c.ready("b")
    clock.t = 1.0
    assert c.ready("a")


def test_control_a_failed_publish_is_not_remembered_and_holds_a_retry_back():
    clock, calls = Clock(), []

    def flaky(data):
        calls.append(1)
        if len(calls) == 1:
            raise OSError("store down")
        return b"d" * 32

    c = PublishCache(flaky, 1.0, clock=clock)
    with pytest.raises(OSError):
        c.digest("a", b"m")
    assert c.published == 0 and not c.ready("a")  # no hammering of a store that is down
    clock.t = 2.0
    assert c.ready("a") and c.digest("a", b"m") == b"d" * 32 and c.published == 1


def test_control_capacity_one_forgets_the_older_but_stays_correct():
    c = PublishCache(fake_publish([]), 0.0, capacity=1, clock=Clock())
    d1 = c.digest("a", b"1")
    c.digest("a", b"2")
    assert c.digest("a", b"1") == d1 and c.published == 3  # forgotten, so published again, same digest


@settings(max_examples=200, deadline=None)
@given(st.lists(st.tuples(st.sampled_from(["a", "b", "c"]), st.binary(min_size=1, max_size=6)), max_size=60))
def test_invariant_real_publishes_equal_distinct_meshes(edits):
    c = PublishCache(fake_publish([]), 0.0, capacity=10_000, clock=Clock())
    for name, data in edits:
        c.digest(name, data)
    assert c.published == len({d for _, d in edits})


@settings(max_examples=200, deadline=None)
@given(st.lists(st.floats(min_value=0.0, max_value=0.4), min_size=1, max_size=40))
def test_invariant_never_ready_twice_inside_the_interval(steps):
    clock = Clock()
    c = PublishCache(fake_publish([]), 1.0, clock=clock)
    last = None
    for dt in steps:
        clock.t += dt
        if c.ready("a"):
            assert last is None or clock.t - last >= 1.0
            c.digest("a", str(clock.t).encode())
            last = clock.t
