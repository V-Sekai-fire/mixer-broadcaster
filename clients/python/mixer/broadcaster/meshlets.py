# MIT License. Copyright (c) 2026-present K. S. Ernest (iFire) Lee
# (Permission notice as in the other files of this package.)
"""
meshoptimizer's meshlet builder (meshopt_buildMeshlets, MIT, Arseny Kapoulkine), loaded with ctypes from
mixer/broadcaster/native/ (tools/build_meshopt.sh builds it at the commit remesh.elf pins) or from $MB_MESHOPT.

`build(points, tris, ids, max_triangles)` cuts the triangles `ids` of a mesh into meshlets of at most 255 vertices and
`max_triangles` triangles, and returns them as lists of triangle ids: a partition of `ids`, each meshlet a compact patch
and the list in meshoptimizer's order, which keeps neighbours next to each other. `available()` says whether the library
loaded; mesh_split falls back to its grid cut when it did not.
"""

import ctypes
import os
import sys
from typing import Dict, List, Optional, Sequence, Tuple

MAX_VERTICES = 255


class _Meshlet(ctypes.Structure):
    _fields_ = [
        ("vertex_offset", ctypes.c_uint),
        ("triangle_offset", ctypes.c_uint),
        ("vertex_count", ctypes.c_uint),
        ("triangle_count", ctypes.c_uint),
    ]


_lib = None
_tried = False


def _load():
    global _lib, _tried
    if _tried:
        return _lib
    _tried = True
    here = os.path.join(os.path.dirname(os.path.abspath(__file__)), "native")
    names = {"darwin": "libmeshoptimizer.dylib", "win32": "meshoptimizer.dll"}.get(sys.platform, "libmeshoptimizer.so")
    for path in (os.environ.get("MB_MESHOPT"), os.path.join(here, names)):
        if path and os.path.exists(path):
            try:
                lib = ctypes.CDLL(path)
                lib.meshopt_buildMeshletsBound.restype = ctypes.c_size_t
                lib.meshopt_buildMeshletsBound.argtypes = [ctypes.c_size_t] * 3
                lib.meshopt_buildMeshlets.restype = ctypes.c_size_t
                lib.meshopt_buildMeshlets.argtypes = [
                    ctypes.POINTER(_Meshlet),
                    ctypes.POINTER(ctypes.c_uint),
                    ctypes.POINTER(ctypes.c_ubyte),
                    ctypes.POINTER(ctypes.c_uint),
                    ctypes.c_size_t,
                    ctypes.POINTER(ctypes.c_float),
                    ctypes.c_size_t,
                    ctypes.c_size_t,
                    ctypes.c_size_t,
                    ctypes.c_size_t,
                    ctypes.c_float,
                ]
                _lib = lib
                break
            except OSError:
                continue
    return _lib


def available() -> bool:
    return _load() is not None


def build(
    points: Sequence[Tuple[float, float, float]],
    tris: Sequence[Tuple[int, int, int]],
    ids: Sequence[int],
    max_triangles: int,
) -> List[List[int]]:
    lib = _load()
    if lib is None:
        raise RuntimeError("meshoptimizer is not built: run tools/build_meshopt.sh")
    ids = list(ids)
    if not ids:
        return []
    per = max(4, min(124, max_triangles - max_triangles % 4))  # meshoptimizer wants a multiple of 4
    flat = [c for p in points for c in p]
    index = [v for i in ids for v in tris[i]]
    n = len(index)
    bound = lib.meshopt_buildMeshletsBound(n, MAX_VERTICES, per)
    meshlets = (_Meshlet * bound)()
    mv = (ctypes.c_uint * (bound * MAX_VERTICES))()
    mt = (ctypes.c_ubyte * (bound * per * 3))()
    count = lib.meshopt_buildMeshlets(
        meshlets,
        mv,
        mt,
        (ctypes.c_uint * n)(*index),
        n,
        (ctypes.c_float * len(flat))(*flat),
        len(points),
        12,
        MAX_VERTICES,
        per,
        ctypes.c_float(0.0),
    )
    by_corners: Dict[Tuple[int, int, int], List[int]] = {}
    for i in ids:
        by_corners.setdefault(tuple(sorted(tris[i])), []).append(i)  # type: ignore[arg-type]
    out: List[List[int]] = []
    for k in range(count):
        m = meshlets[k]
        piece = []
        for t in range(m.triangle_count):
            o = m.triangle_offset + 3 * t
            key = tuple(sorted(mv[m.vertex_offset + mt[o + j]] for j in range(3)))
            piece.append(by_corners[key].pop(0))  # a repeated triangle takes its copies in turn
        out.append(piece)
    return out
