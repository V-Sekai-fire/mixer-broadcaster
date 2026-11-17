# MIT. Reads the meshes of a .usda (points, faceVertexCounts, faceVertexIndices; fan-triangulated) and writes each as
# $REAL_OUT/<prefix>_<mesh>.json beside the other dumps, for tests/hypo/test_explode_rule.py.
# usage: python3 tools/usda_to_real.py <prefix> <file.usda>...
import json, os, re, sys

out = os.environ["REAL_OUT"]
os.makedirs(out, exist_ok=True)
prefix, files = sys.argv[1], sys.argv[2:]
num = re.compile(r"-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?")
for path in files:
    text = open(path).read()
    for k, m in enumerate(re.finditer(r'def Mesh "([^"]+)"', text)):
        end = text.find("def Mesh", m.end())
        body = text[m.end() : end if end > 0 else len(text)]

        def arr(name, ints):
            a = re.search(re.escape(name) + r"\s*=\s*\[(.*?)\]\s*\n", body, re.S)
            return [int(x) for x in num.findall(a.group(1))] if ints else [float(x) for x in num.findall(a.group(1))]

        pts = arr("point3f[] points", False)
        counts = arr("int[] faceVertexCounts", True)
        idx = arr("int[] faceVertexIndices", True)
        points = [pts[i : i + 3] for i in range(0, len(pts), 3)]
        tris, o = [], 0
        for c in counts:
            for j in range(1, c - 1):
                tris.append([idx[o], idx[o + j], idx[o + j + 1]])
            o += c
        json.dump(
            {"points": points, "tris": tris, "xform": [1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0]},
            open(os.path.join(out, f"{prefix}_{m.group(1)}.json"), "w"),
        )
        print(prefix, m.group(1), len(points), "points", len(tris), "triangles")
