# MIT License. Copyright (c) 2026-present K. S. Ernest (iFire) Lee
# (Permission notice as in the other files of this package.)
"""
Cuts a triangle mesh into pieces of at most `max_tris` triangles, so each piece is a small mesh a viewer can fetch at once.
No `bpy`, no numpy: lists of points and (a, b, c) index triples.

The rule follows what the project already does with models:
  1. shells (model_explode's explode.gd): triangles that share a vertex, vertices welded by position, are one shell; nothing
     is cut, so every piece edge is an edge the artist made;
  2. every shell, big or small, is cut into meshlets by meshoptimizer (meshlets.py) and consecutive meshlets are packed into
     pieces of at most the limit; no triangle is split or copied;
  3. where the library is not built: small shells are packed largest first, and a shell over the limit is cut on a grid
     (godot-splerger's split by grid).

`split(points, tris, max_tris)` returns lists of triangle indices: a partition of range(len(tris)), each at most `max_tris`,
the same for the same input.
"""

import math
from typing import Dict, List, Optional, Sequence, Tuple

Point = Tuple[float, float, float]
Tri = Tuple[int, int, int]


MIN_SHARE = 0.01  # explode.gd: a shell with at least this share of the triangles is a piece of its own
WELD_SHARE = 1e-5  # explode.gd WELD: vertices closer than this share of the model's size are one vertex


def _f32(x: float) -> float:
    """The project's Godot is a double-precision build (precision=double), so its Vector3 holds doubles: identity."""
    return x


def _roundi(x: float) -> int:
    """Godot's roundi: halves go away from zero (Python's round() goes to even)."""
    return int(math.floor(x + 0.5)) if x >= 0 else -int(math.floor(-x + 0.5))


def shells(points: Sequence[Point], tris: Sequence[Tri], world: Optional[Sequence[Point]] = None) -> List[List[int]]:
    """The shells of explode.gd (_split_shells), ported rule for rule: a vertex's weld id is its world position over
    q = max(diagonal of the model's world box x WELD, 1e-9), rounded with roundi, ids handed out in vertex order; the
    three corners of every triangle are united (a-b, b-c; the smaller root wins); a shell is the triangles of one root.
    `world` is the vertices in world space (else `points`). Triangle ids per shell, shells in order of their first
    triangle."""
    pos = world if world is not None else points
    if not pos:
        return []
    lo = [min(p[k] for p in pos) for k in range(3)]
    hi = [max(p[k] for p in pos) for k in range(3)]
    diag = _f32(math.sqrt(sum((hi[k] - lo[k]) ** 2 for k in range(3))))
    q = max(_f32(diag * WELD_SHARE), 1e-9)
    weld: Dict[Tuple[int, int, int], int] = {}
    vid: List[int] = []
    for p in pos:
        key = (_roundi(_f32(p[0]) / q), _roundi(_f32(p[1]) / q), _roundi(_f32(p[2]) / q))
        if key not in weld:
            weld[key] = len(weld)
        vid.append(weld[key])
    up: Dict[int, int] = {}

    def find(a: int) -> int:
        r = a
        while r in up:
            r = up[r]
        while a in up:  # path compression
            n = up[a]
            up[a] = r
            a = n
        return r

    def union(a: int, b: int) -> None:
        ra, rb = find(a), find(b)
        if ra != rb:
            up[max(ra, rb)] = min(ra, rb)

    for a, b, c in tris:
        union(vid[a], vid[b])
        union(vid[b], vid[c])
    groups: Dict[int, List[int]] = {}
    for i, (a, _, _) in enumerate(tris):
        groups.setdefault(find(vid[a]), []).append(i)
    return list(groups.values())  # dict order = the order of each shell's first triangle, as explode.gd emits them


def is_piece(shell_size: int, total: int) -> bool:
    """explode.gd: a shell with at least MIN_SHARE of the triangles (and at least one) is a piece of its own; the rest
    are the small shells that travel together."""
    return float(shell_size) >= max(1.0, MIN_SHARE * float(total))


def _centre(points: Sequence[Point], t: Tri) -> Point:
    a, b, c = points[t[0]], points[t[1]], points[t[2]]
    return ((a[0] + b[0] + c[0]) / 3, (a[1] + b[1] + c[1]) / 3, (a[2] + b[2] + c[2]) / 3)


def meshlet_cut(points: Sequence[Point], tris: Sequence[Tri], ids: List[int], max_tris: int) -> List[List[int]]:
    """One shell over the limit, cut with meshoptimizer's meshlet builder: compact patches in an order that keeps
    neighbours together, then runs of consecutive meshlets packed into pieces of at most max_tris triangles."""
    from mixer.broadcaster import meshlets

    pieces: List[List[int]] = []
    run: List[int] = []
    for m in meshlets.build(points, tris, ids, max_tris):
        if run and len(run) + len(m) > max_tris:
            pieces.append(run)
            run = []
        run.extend(m)
    if run:
        pieces.append(run)
    return pieces


def grid_cut(points: Sequence[Point], tris: Sequence[Tri], ids: List[int], max_tris: int) -> List[List[int]]:
    """Without meshoptimizer: one shell over the limit, cut by a grid over its bounding box, then by medians."""
    centres = {i: _centre(points, tris[i]) for i in ids}
    lo = [min(centres[i][k] for i in ids) for k in range(3)]
    hi = [max(centres[i][k] for i in ids) for k in range(3)]
    want = math.ceil(len(ids) / max_tris) * 2  # twice the cells the count needs: a cell is rarely full
    spans = [max(hi[k] - lo[k], 1e-9) for k in range(3)]
    size = (spans[0] * spans[1] * spans[2] / want) ** (1 / 3) if min(spans) > 1e-6 else max(spans) / want
    size = max(size, 1e-9)
    cells: Dict[Tuple[int, int, int], List[int]] = {}
    for i in ids:
        c = centres[i]
        cells.setdefault(tuple(int((c[k] - lo[k]) / size) for k in range(3)), []).append(i)  # type: ignore[arg-type]
    out: List[List[int]] = []
    for cell in sorted(cells):
        out.extend(_median_cut(centres, cells[cell], max_tris))
    return out


def _median_cut(centres: Dict[int, Point], ids: List[int], max_tris: int) -> List[List[int]]:
    if len(ids) <= max_tris:
        return [ids]
    axis = max(range(3), key=lambda k: max(centres[i][k] for i in ids) - min(centres[i][k] for i in ids))
    ordered = sorted(ids, key=lambda i: (centres[i][axis], i))  # ties by index: the same input cuts the same way
    half = len(ordered) // 2
    return _median_cut(centres, ordered[:half], max_tris) + _median_cut(centres, ordered[half:], max_tris)


def _meshlets_ok() -> bool:
    from mixer.broadcaster import meshlets

    return meshlets.available()


def split(
    points: Sequence[Point], tris: Sequence[Tri], max_tris: int, world: Optional[Sequence[Point]] = None
) -> List[List[int]]:
    if max_tris < 1:
        raise ValueError("max_tris is at least 1")
    if len(tris) <= max_tris:
        return [list(range(len(tris)))] if tris else []
    if max_tris >= 4 and _meshlets_ok():  # every shell, big or small, goes through meshoptimizer's meshlet builder
        from mixer.broadcaster import meshlets

        pieces: List[List[int]] = []
        run: List[int] = []
        found = shells(points, tris, world)  # explode.gd's pieces first, then its small shells that travel together
        ordered = [x for x in found if is_piece(len(x), len(tris))] + [
            x for x in found if not is_piece(len(x), len(tris))
        ]
        for shell in ordered:  # consecutive meshlets, shell by shell, packed into pieces
            for m in meshlets.build(points, tris, shell, max_tris):
                if run and len(run) + len(m) > max_tris:
                    pieces.append(run)
                    run = []
                run.extend(m)
        if run:
            pieces.append(run)
        return pieces
    pieces = []
    small: List[List[int]] = []
    for shell in shells(points, tris, world):
        if len(shell) > max_tris:
            pieces.extend(grid_cut(points, tris, shell, max_tris))
        else:
            small.append(shell)
    bins: List[List[int]] = []
    for shell in sorted(small, key=lambda s: (-len(s), s[0])):  # first fit, largest first
        for b in bins:
            if len(b) + len(shell) <= max_tris:
                b.extend(shell)
                break
        else:
            bins.append(list(shell))
    pieces.extend(sorted(b) for b in bins)
    return pieces


def piece(points: Sequence[Point], tris: Sequence[Tri], ids: Sequence[int]) -> Tuple[List[Point], List[Tri]]:
    """The points and triangles of one piece, with the points it does not use dropped and the indices renumbered."""
    remap: Dict[int, int] = {}
    pts: List[Point] = []
    out: List[Tri] = []
    for i in ids:
        row = []
        for v in tris[i]:
            if v not in remap:
                remap[v] = len(pts)
                pts.append(points[v])
            row.append(remap[v])
        out.append((row[0], row[1], row[2]))
    return pts, out
