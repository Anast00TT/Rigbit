extends SceneTree
## Проверка экспорта глазами и по времени (нужен GPU, не headless):
##   godot --path rigbit --quit-after 900 -s res://tests/export_shot.gd
## Пишет build/shots/export_f0.png, export_f12.png, build/export_test.gif (+ варианты) и время этапов.

const OUT := "C:/Users/Anastazja/Desktop/rigbit app/build/"


func _initialize() -> void:
	OS.low_processor_usage_mode = false
	_run()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(OUT + "shots")
	var doc := RbDocument.new()
	doc.canvas_size = Vector2i(512, 512)
	doc.background = Color(0.95, 0.85, 0.9, 1)
	doc.frame_count = 24
	doc.fps = 24
	var r := RbImporter.image_to_layer(doc, RbIcons.frog_image(400), "frog")
	var l := r.layer
	doc.images[l.image_id] = r.image
	doc.insert_layer(l)
	var base := l.position
	var kp := RbAnimation.track_key("layer", l.id, &"position")
	var kr := RbAnimation.track_key("layer", l.id, &"rotation")
	doc.anim.set_key(kp, 0, base, "smooth")
	doc.anim.set_key(kp, 12, base + Vector2(0, -90), "smooth")
	doc.anim.set_key(kp, 24, base, "smooth")
	doc.anim.set_key(kr, 0, 0.0, "smooth")
	doc.anim.set_key(kr, 12, 0.35, "smooth")
	doc.anim.set_key(kr, 24, 0.0, "smooth")
	doc.current_frame = 5
	doc.anim.apply_frame(doc, 5)  # документ стоит на кадре 5: после экспорта должен остаться там же
	var pos5 := l.position

	var fr := RbFrameRenderer.new()
	root.add_child(fr)
	OS.low_processor_usage_mode = true
	fr.setup(doc, Vector2i(512, 512), true, Color.WHITE)
	var t0 := Time.get_ticks_msec()
	var frames: Array = []
	for f in 24:
		var img: Image = await fr.render_frame(f)
		if f == 0:
			img.save_png(OUT + "shots/export_f0.png")
		if f == 12:
			img.save_png(OUT + "shots/export_f12.png")
		frames.append(img)
	var render_ms := Time.get_ticks_msec() - t0
	fr.finish()
	print("render 24 кадров 512x512: %d мс (%.1f мс/кадр)" % [render_ms, render_ms / 24.0])
	print("low_processor восстановлен: ", OS.low_processor_usage_mode)
	print("doc.current_frame: ", doc.current_frame, " позиция слоя восстановлена: ", l.position == pos5)
	var px: Color = (frames[0] as Image).get_pixel(2, 2)
	print("угол кадра 0 (прозрачный фон): a=", px.a, "  центр: ", (frames[0] as Image).get_pixel(256, 256))
	# непрозрачный вариант
	fr.setup(doc, Vector2i(256, 256), false, Color(0.2, 0.3, 0.6))
	var opaque: Image = await fr.render_frame(12)
	opaque.save_png(OUT + "shots/export_opaque_256.png")
	fr.finish()
	print("непрозрачный 256: угол ", opaque.get_pixel(1, 1), " формат ", opaque.get_format())

	# GIF: варианты и замеры
	var variants := [
		["export_test.gif", {"per_frame_palette": false, "dither": false}],
		["export_test_dither.gif", {"per_frame_palette": false, "dither": true}],
		["export_test_perframe.gif", {"per_frame_palette": true, "dither": false}],
		["export_test_perframe_dither.gif", {"per_frame_palette": true, "dither": true}],
	]
	for v in variants:
		var enc := RbGifEncoder.new()
		for k in v[1]:
			enc.set(k, v[1][k])
		var t1 := Time.get_ticks_msec()
		var bytes := enc.encode(frames, 24.0)
		var ms := Time.get_ticks_msec() - t1
		RbGifEncoder.save(OUT + v[0], bytes)
		print("%s: %d мс, %d КБ, %s" % [v[0], ms, bytes.size() / 1024, str(enc.last_stats)])
	# непрозрачный GIF
	var opq: Array = []
	fr.setup(doc, Vector2i(512, 512), false, Color(0.95, 0.85, 0.9))
	for f in 24:
		opq.append(await fr.render_frame(f))
	fr.finish()
	var enc2 := RbGifEncoder.new()
	var t2 := Time.get_ticks_msec()
	var b2 := enc2.encode(opq, 24.0)
	print("export_test_opaque.gif: %d мс, %d КБ, %s" % [Time.get_ticks_msec() - t2, b2.size() / 1024, str(enc2.last_stats)])
	RbGifEncoder.save(OUT + "export_test_opaque.gif", b2)

	# декод своим декодером для сверки
	var Dec := load("res://tests/gif_decode.gd")
	var res: Dictionary = Dec.decode(RbGifEncoder.new().encode(frames.slice(0, 3), 24.0))
	print("мини-декод: ok=", res["ok"], " кадров=", res["frames"].size(), " ", res["error"])
	quit()
