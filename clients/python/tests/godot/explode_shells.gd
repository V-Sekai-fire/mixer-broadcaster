# MIT. Runs explode.gd's own _split_shells on the mesh in $SHELLS_IN (JSON: points, tris, xform = 12 numbers: basis rows
# then origin) and prints SHELL <key> <triangles> for every piece it makes. The Python port is checked against this.
extends SceneTree

func _init() -> void:
	var spec = JSON.parse_string(FileAccess.get_file_as_string(OS.get_environment("SHELLS_IN")))
	var ex = load(OS.get_environment("EXPLODE_GD")).new()
	ex.root = Node3D.new()
	var pts := PackedVector3Array()
	for p in spec["points"]:
		pts.append(Vector3(p[0], p[1], p[2]))
	var idx := PackedInt32Array()
	for t in spec["tris"]:
		idx.append_array(PackedInt32Array([t[0], t[1], t[2]]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = pts
	arrays[Mesh.ARRAY_INDEX] = idx
	var m: Array = spec["xform"]
	var xf := Transform3D(Basis(Vector3(m[0], m[3], m[6]), Vector3(m[1], m[4], m[7]), Vector3(m[2], m[5], m[8])), Vector3(m[9], m[10], m[11]))
	ex._split_shells([[arrays, Mesh.PRIMITIVE_TRIANGLES, null, xf, "m", 0, null]])
	for key in ex.part_of:
		var n := 0
		for c in ex.pieces[ex.part_of[key]].get_children():
			if c is MeshInstance3D:
				n += (c.mesh.surface_get_arrays(0)[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
		print("SHELL %s %d" % [key, n])
	quit()
