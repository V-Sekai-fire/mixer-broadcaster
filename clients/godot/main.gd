@tool
extends Node
# MIT. A viewer of the closed relay in Godot. It signs in with the guest ELF (mixer_auth.elf, the same one the other
# clients run), asks the minter for a token that carries the read right, joins the room over WebTransport, asks the
# relay for each mesh by digest, fetches the presigned index and chunks, and draws the mesh at each pose. A console
# at the bottom of the window logs every step and every relay reply. It is a @tool script, so opening main.tscn in the
# editor streams into the editor's own 3D view too (the nodes it adds have no owner, so nothing is saved to the scene).
#   env: MB_PORT (relay UDP port), MB_ROOM, MB_MINTER (http://127.0.0.1:4467), AUTH_ELF (path to mixer_auth.elf)

var peer: WebTransportPeer
var sandbox: Object
var room := "live"
var minter := "http://127.0.0.1:4467"
var priv := PackedByteArray()
var pub := PackedByteArray()
var admitted := false
var replies: Array = []        # JSON replies read off the peer, oldest first
var more: Array = []           # later pieces of a long mesh reply
var meshes := {}               # digest hex -> ArrayMesh, or false while loading / refused
var nodes := {}                # gid -> MeshInstance3D
var last_log := {}             # gid -> msec of the last position line, so the console is not flooded
var packets := 0
var con: RichTextLabel
var status: Label
var mat := StandardMaterial3D.new()
var t0 := Time.get_ticks_msec()
var last_ping := 0
var was_up := true

func _log(msg: String, color := "") -> void:
	var line := "%7.2fs  %s" % [(Time.get_ticks_msec() - t0) / 1000.0, msg]
	print("GODOT ", line)
	if con:
		con.append_text(("[color=%s]%s[/color]\n" % [color, line]) if color != "" else line + "\n")

func _ready() -> void:
	if not Engine.is_editor_hint():
		DisplayServer.window_move_to_foreground()
	room = OS.get_environment("MB_ROOM") if OS.get_environment("MB_ROOM") != "" else room
	minter = OS.get_environment("MB_MINTER") if OS.get_environment("MB_MINTER") != "" else minter
	_build_scene()
	_run.call_deferred()

func _build_scene() -> void:
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color8(20, 20, 20)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.6, 0.6, 0.65)
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	add_child(sun)
	var cam := Camera3D.new()
	cam.position = Vector3(4, 3, 6.5)
	add_child(cam)
	cam.look_at(Vector3.ZERO)
	var floor_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(20, 20)
	floor_mesh.mesh = plane
	var fm := StandardMaterial3D.new()
	fm.albedo_color = Color(0.16, 0.16, 0.18)
	floor_mesh.material_override = fm
	floor_mesh.position.y = -1.5
	add_child(floor_mesh)
	mat.albedo_color = Color(0.85, 0.85, 0.9)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var layer := CanvasLayer.new()
	status = Label.new()
	status.position = Vector2(8, 6)
	status.add_theme_color_override("font_color", Color(0.85, 1, 0.85))
	layer.add_child(status)
	con = RichTextLabel.new()
	con.bbcode_enabled = true
	con.scroll_following = true
	con.anchor_top = 0.62
	con.anchor_right = 1.0
	con.anchor_bottom = 1.0
	con.add_theme_font_size_override("normal_font_size", 13)
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0, 0, 0, 0.78)
	con.add_theme_stylebox_override("normal", bg)
	layer.add_child(con)
	add_child(layer)

func _http(method: int, url: String, body := "", headers := PackedStringArray()) -> PackedByteArray:
	var r := HTTPRequest.new()
	add_child(r)
	if r.request(url, headers, method, body) != OK:
		r.queue_free()
		return PackedByteArray()
	var res: Array = await r.request_completed
	r.queue_free()
	return res[3] if res[1] == 200 else PackedByteArray()

func _b64u(b: PackedByteArray) -> String:
	return Marshalls.raw_to_base64(b).replace("+", "-").replace("/", "_").replace("=", "")

func _unb64u(s: String) -> PackedByteArray:
	s = s.replace("-", "+").replace("_", "/")
	while s.length() % 4 != 0:
		s += "="
	return Marshalls.base64_to_raw(s)

# One question to the relay, as a datagram: the relay answers a datagram with datagrams (this peer reads no replies
# from a stream).
func _ask(obj: Dictionary) -> Dictionary:
	peer.transfer_mode = MultiplayerPeer.TRANSFER_MODE_UNRELIABLE
	peer.put_packet(JSON.stringify(obj).to_utf8_buffer())
	var deadline := Time.get_ticks_msec() + 8000
	while Time.get_ticks_msec() < deadline:
		if replies.size() > 0:
			return replies.pop_front()
		await get_tree().process_frame
	return {}

func _run() -> void:
	var elf := OS.get_environment("AUTH_ELF") if OS.get_environment("AUTH_ELF") != "" else "res://mixer_auth.elf"
	sandbox = ClassDB.instantiate("Sandbox")
	if sandbox == null:
		_log("this engine has no Sandbox class", "red")
		return
	sandbox.set("program", load(elf))
	var rng := Crypto.new()
	if int(sandbox.vmcall("auth_init", rng.generate_random_bytes(32))) != 1:
		_log("guest auth_init failed", "red")
		return
	var kp := PackedByteArray()
	while kp.size() != 97:
		kp = sandbox.vmcall("auth_keygen", rng.generate_random_bytes(32))
	priv = kp.slice(0, 32)
	pub = kp.slice(32, 97)
	var tp: PackedByteArray = sandbox.vmcall("auth_thumbprint", pub)
	_log("guest made a key; thumbprint %s" % tp.hex_encode().left(16), "lightgreen")

	_log("asking the minter for a token (read)")
	var body := JSON.stringify({"room": room, "key": _b64u(pub), "ops": ["read"]})
	var raw: PackedByteArray = await _http(HTTPClient.METHOD_POST, minter + "/mint", body, PackedStringArray(["content-type: application/json"]))
	var minted: Variant = JSON.parse_string(raw.get_string_from_utf8())
	if typeof(minted) != TYPE_DICTIONARY or not minted.has("token"):
		_log("the minter gave no token: %s" % raw.get_string_from_utf8().left(120), "red")
		return
	_log("token minted, %d chars" % String(minted["token"]).length(), "lightgreen")

	peer = WebTransportPeer.new()
	var port := int(OS.get_environment("MB_PORT")) if OS.get_environment("MB_PORT") != "" else 4466
	_log("connecting to the relay on port %d, room %s" % [port, room])
	if peer.create_client("127.0.0.1", port, "/room/" + room) != OK:
		_log("create_client failed", "red")
		return
	if peer.get_quic() != null:
		peer.get_quic().set_tls_options(TLSOptions.client_unsafe())
	while peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		peer.poll()
		await get_tree().process_frame
	_log("WebTransport open", "lightgreen")
	var ch := await _ask({"t": "hello"})
	if ch.get("t", "") != "challenge":
		_log("no challenge from the relay: %s" % JSON.stringify(ch), "red")
		return
	var nonce := _unb64u(ch["nonce"])
	var sig: PackedByteArray = sandbox.vmcall("auth_sign", priv, room, nonce)
	var ok := await _ask({"t": "auth", "token": minted["token"], "key": _b64u(pub), "sig": _b64u(sig)})
	if ok.get("t", "") != "ready":
		_log("the relay refused: %s" % JSON.stringify(ok), "red")
		return
	admitted = true
	_log("admitted: relay said ready (signed by the guest ELF)", "lightgreen")

func _process(delta: float) -> void:
	# updates arrive about 10 times a second; ease each object toward its latest pose so the motion is smooth
	var w := 1.0 - exp(-18.0 * delta)
	for n in nodes.values():
		if n.has_meta("tp"):
			n.position = n.position.lerp(n.get_meta("tp"), w)
			n.quaternion = n.quaternion.slerp(n.get_meta("tq"), w)
	if status:
		status.text = "room %s  admitted %s  packets %d  entities %d  meshes %d" % [room, admitted, packets, nodes.size(), meshes.values().filter(func(m): return m is Mesh).size()]
	if peer == null:
		return
	peer.poll()
	var st := peer.get_connection_status()
	if st != MultiplayerPeer.CONNECTION_CONNECTED and was_up and admitted:
		was_up = false
		_log("connection to the relay lost (status %d)" % st, "red")
	# QUIC drops a quiet session: a small datagram every 5 s keeps it open (the snapshot it draws is ignored)
	if admitted and st == MultiplayerPeer.CONNECTION_CONNECTED and Time.get_ticks_msec() - last_ping > 5000:
		last_ping = Time.get_ticks_msec()
		peer.transfer_mode = MultiplayerPeer.TRANSFER_MODE_UNRELIABLE
		peer.put_packet('{"t":"hello"}'.to_utf8_buffer())
	while peer.get_available_packet_count() > 0:
		var b := peer.get_packet()
		if b.size() == 100:
			_on_pose(b)
		elif b.size() > 0 and b[0] == 123:
			var j: Variant = JSON.parse_string(b.get_string_from_utf8())
			if typeof(j) == TYPE_DICTIONARY:
				if j.get("t", "") == "mesh_more":
					more.append(j)
				else:
					replies.append(j)

func _on_pose(b: PackedByteArray) -> void:
	packets += 1
	var gid := b.decode_u32(0)
	if b.decode_u8(51) == 128:
		return
	var pos := Vector3(b.decode_s64(4), b.decode_s64(12), b.decode_s64(20)) / 1e6
	var hex := b.slice(62, 94).hex_encode()
	if hex.replace("0", "") != "" and not meshes.has(hex):
		meshes[hex] = false
		_load_mesh(hex)
	if meshes.get(hex, false) is Mesh:
		if not nodes.has(gid) or nodes[gid].get_meta("hex") != hex:
			if nodes.has(gid):
				nodes[gid].queue_free()
			var mi := MeshInstance3D.new()
			mi.mesh = meshes[hex]
			mi.material_override = mat
			mi.set_meta("hex", hex)
			add_child(mi)
			nodes[gid] = mi
			_log("entity %d first seen" % gid)
	if nodes.has(gid):
		var n: MeshInstance3D = nodes[gid]
		if not n.has_meta("tp"):
			n.position = pos
		n.set_meta("tp", pos)
		var sx := float(b.decode_s16(56)) * PI / 32767.0
		var sz := float(b.decode_s16(58)) * PI / 32767.0
		var ang := sqrt(sx * sx + sz * sz)
		var swing := Quaternion(Vector3(sx / ang, 0, sz / ang), ang) if ang > 1e-9 else Quaternion.IDENTITY
		var q := swing * Quaternion(Vector3.UP, float(b.decode_s16(60)) * TAU / 65536.0)
		if not n.has_meta("tq"):
			n.quaternion = q
		n.set_meta("tq", q)
		if Time.get_ticks_msec() - int(last_log.get(gid, -10000)) > 700:
			last_log[gid] = Time.get_ticks_msec()
			_log("entity %d at (%.2f, %.2f, %.2f)" % [gid, pos.x, pos.y, pos.z])

func _nums(text: String) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	var re := RegEx.new()
	re.compile("-?[0-9]+(?:\\.[0-9]+)?(?:e-?[0-9]+)?")
	for m in re.search_all(text):
		out.append(float(m.get_string()))
	return out

func _array_after(text: String, key: String) -> String:
	var i := text.find(key)
	if i < 0:
		return ""
	var a := text.find("[", i)
	var depth := 0
	for j in range(a, text.length()):
		if text[j] == "[":
			depth += 1
		elif text[j] == "]":
			depth -= 1
			if depth == 0:
				return text.substr(a + 1, j - a - 1)
	return ""

func _load_mesh(hex: String) -> void:
	while not admitted:
		await get_tree().process_frame
	_log("asking the relay for mesh %s" % hex.left(8))
	var r := await _ask({"t": "mesh", "digest": hex})
	if r.get("t", "") != "mesh":
		_log("relay answered: %s" % JSON.stringify(r), "red")
		return
	var urls: Array = r["chunks"].duplicate()
	var want := int(r.get("n", urls.size()))
	var give_up := Time.get_ticks_msec() + 6000
	while urls.size() < want and Time.get_ticks_msec() < give_up:
		for m in more.duplicate():
			if m["digest"] == hex and int(m["from"]) == urls.size():
				urls.append_array(m["chunks"])
				more.erase(m)
		await get_tree().process_frame
	if urls.size() < want:
		_log("only %d of %d chunk urls arrived" % [urls.size(), want], "red")
		return
	_log("relay answered: urls for the index and %d chunk(s), good for %ss" % [urls.size(), r["expires"]], "lightgreen")
	var index: PackedByteArray = await _http(HTTPClient.METHOD_GET, r["index"])
	var h := HashingContext.new()
	h.start(HashingContext.HASH_SHA256)
	h.update(index)
	if h.finish().hex_encode() != hex:
		_log("the index is not the one the digest names", "red")
		return
	var all := PackedByteArray()
	for url in urls:
		var z: PackedByteArray = await _http(HTTPClient.METHOD_GET, url)
		# Godot cannot stream-decompress zstd, so give it room: a chunk is at most 64 KiB before compression
		var raw := z.decompress(1 << 24, FileAccess.COMPRESSION_ZSTD)
		_log("chunk: %d bytes fetched, %d bytes after zstd" % [z.size(), raw.size()])
		all.append_array(raw)
	var text := all.get_string_from_utf8()
	var pts := _nums(_array_after(text, "points = "))
	var tri := _nums(_array_after(text, "faceVertexIndices = "))
	var verts := PackedVector3Array()
	for k in tri.size():
		var vi := int(tri[k])
		verts.append(Vector3(pts[vi * 3], pts[vi * 3 + 1], pts[vi * 3 + 2]))
	var normals := PackedVector3Array()
	for t in range(verts.size() / 3):
		var nrm := (verts[t * 3 + 1] - verts[t * 3]).cross(verts[t * 3 + 2] - verts[t * 3]).normalized()
		for _k in 3:
			normals.append(nrm)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	meshes[hex] = mesh
	_log("mesh %s: index hash ok, %d chunk(s), %d triangles" % [hex.left(8), urls.size(), tri.size() / 3], "lightgreen")
