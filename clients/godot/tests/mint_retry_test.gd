extends SceneTree
# Calls the shipped main.gd's _mint_with_retry against MB_MINTER, with MB_ATTEMPTS tries.
# Prints MINT_OK or MINT_FAIL; the exit code is 0 only for MINT_OK. tests/run_mint_retry.py drives it.

func _init() -> void:
	var main: Node = load("res://main.gd").new()
	main.minter = OS.get_environment("MB_MINTER")
	root.add_child(main)
	await process_frame
	var attempts := int(OS.get_environment("MB_ATTEMPTS")) if OS.get_environment("MB_ATTEMPTS") != "" else 6
	var t0 := Time.get_ticks_msec()
	var minted: Variant = await main._mint_with_retry(JSON.stringify({"room": "t", "key": "k", "ops": ["read"]}), attempts)
	var secs := (Time.get_ticks_msec() - t0) / 1000.0
	if typeof(minted) == TYPE_DICTIONARY and minted.has("token"):
		print("MINT_OK token=%s after %.1fs" % [minted["token"], secs])
		quit(0)
	else:
		print("MINT_FAIL after %.1fs" % secs)
		quit(1)
