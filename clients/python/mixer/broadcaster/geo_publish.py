# MIT License. Copyright (c) 2026-present K. S. Ernest (iFire) Lee
# (Permission notice as in the other files of this package.)
"""
A mesh as the viewers read it: ASCII USD (Y up) chunked by `desync make` into the SeaweedFS filer's chunk store, with the
index stored under its own SHA-256 (that digest is the mesh's name in an entity packet's payload). No `bpy` here.
"""

import hashlib
import os
import subprocess
import tempfile
import time
from collections import OrderedDict
from typing import Callable, Dict, List, Sequence, Tuple

from mixer.broadcaster import s3
from mixer.broadcaster.entity import DIGEST_LEN


def usda(name: str, points_zup: Sequence[Tuple[float, float, float]], tris: Sequence[Tuple[int, int, int]]) -> bytes:
    """One Mesh prim. A Z-up point (x, y, z) is written as (x, z, -y), the wire's frame."""
    n = len(points_zup)
    if any(not 0 <= i < n for t in tris for i in t):
        raise ValueError("a triangle names a point that does not exist")
    f = lambda v: "(%.6f, %.6f, %.6f)" % v  # noqa: E731
    lines = [
        "#usda 1.0",
        "(",
        '    defaultPrim = "%s"' % name,
        '    upAxis = "Y"',
        "    metersPerUnit = 1",
        ")",
        "",
        'def Mesh "%s"' % name,
        "{",
        "    int[] faceVertexCounts = [%s]" % ", ".join("3" for _ in tris),
        "    int[] faceVertexIndices = [%s]" % ", ".join(str(i) for t in tris for i in t),
        "    point3f[] points = [%s]" % ", ".join(f((x, z, -y)) for x, y, z in points_zup),
        "}",
        "",
    ]
    return "\n".join(lines).encode()


def publish(data: bytes, desync: str, endpoint: str, bucket: str = "mixer") -> bytes:
    """desync make into SeaweedFS's S3 (`bucket`/chunks), put the index at `bucket`/index/<digest>.caibx; return the
    32-byte digest. Credentials come from AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY."""
    store = "s3+" + endpoint.rstrip("/") + f"/{bucket}/chunks"
    with tempfile.TemporaryDirectory() as d:
        src, idx = os.path.join(d, "m.usda"), os.path.join(d, "m.caibx")
        open(src, "wb").write(data)
        # chunk first without a store: the index names the data, and if it is already in the store so are its chunks
        # (the index is written last), so nothing is written twice
        subprocess.run([desync, "make", idx, src], check=True, capture_output=True)
        index = open(idx, "rb").read()
        digest = hashlib.sha256(index).digest()
        assert len(digest) == DIGEST_LEN
        key = f"index/{digest.hex()}.caibx"
        if s3.exists(endpoint, bucket, key):
            return digest
        os.remove(idx)
        subprocess.run([desync, "make", "-s", store, idx, src], check=True, capture_output=True)
        index = open(idx, "rb").read()
    assert hashlib.sha256(index).digest() == digest
    s3.put(endpoint, bucket, key, index)
    return digest


def extract(digest: bytes, desync: str, endpoint: str, bucket: str = "mixer") -> bytes:
    """The data a desync index names: the index is read from the store, checked against `digest`, and extracted from
    the chunk store."""
    index = s3.get(endpoint, bucket, f"index/{digest.hex()}.caibx")
    if hashlib.sha256(index).digest() != digest:
        raise ValueError("the store returned another index than the digest names")
    store = "s3+" + endpoint.rstrip("/") + f"/{bucket}/chunks"
    with tempfile.TemporaryDirectory() as d:
        idx, out = os.path.join(d, "m.caibx"), os.path.join(d, "out")
        open(idx, "wb").write(index)
        subprocess.run([desync, "extract", "-s", store, idx, out], check=True, capture_output=True)
        return open(out, "rb").read()


class PublishCache:
    """Keeps the store from growing with every edit: a mesh is published at most once per `min_interval` seconds for
    each object, and a mesh whose bytes were published before is not published again (undo, an object copied, a
    restart of the client, an unchanged mesh that its source reports as updated). Nothing is ever deleted from the store,
    so every publish that is not needed is disk that stays used. `publish(data) -> digest` does the real work."""

    def __init__(
        self,
        publish: Callable[[bytes], bytes],
        min_interval: float = 1.0,
        capacity: int = 256,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self._publish = publish
        self._interval = min_interval
        self._capacity = capacity
        self._clock = clock
        self._known: "OrderedDict[bytes, bytes]" = OrderedDict()  # sha256 of the bytes -> digest, newest last
        self._last: Dict[str, float] = {}
        self.published = 0  # how many times `publish` really ran

    def ready(self, name: str) -> bool:
        """May this object's mesh be published now? Ask before building the (costly) bytes."""
        last = self._last.get(name)
        return last is None or self._clock() - last >= self._interval

    def digest(self, name: str, data: bytes) -> bytes:
        """The mesh's digest, publishing it only when its bytes are new. Counts as this object's publish time."""
        key = hashlib.sha256(data).digest()
        self._last[name] = self._clock()
        if key in self._known:
            self._known.move_to_end(key)
            return self._known[key]
        digest = self._publish(data)
        self.published += 1
        self._known[key] = digest
        while len(self._known) > self._capacity:
            self._known.popitem(last=False)
        return digest

    def forget(self, name: str) -> None:
        self._last.pop(name, None)
