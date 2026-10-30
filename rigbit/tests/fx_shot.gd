extends SceneTree
## Проверка эффектов глазами: 4 лягушки с разными эффектами -> build/shots/fx.png
## Запуск (не headless): godot --path rigbit -s res://tests/fx_shot.gd

func _initialize() -> void:
	OS.low_processor_usage_mode = false
	RbIcons.scale = 1.0
	DisplayServer.window_set_size(Vector2i(1200, 420))
	root.size = Vector2i(1200, 420)
	var bg := ColorRect.new()
	bg.color = Color("#3a3a46")
	bg.size = Vector2(1200, 420)
	root.add_child(bg)
	var variants := [
		{},
		{"rim": {"angle": -PI / 4, "distance": 14.0, "blur": 4.0, "hardness": 0.6, "color": "fff0b0", "blend": "add"}},
		{"rim": {"outside": true, "angle": -PI / 4, "distance": 10.0, "blur": 2.0, "hardness": 0.8, "color": "ff6ad5"}},
		{"grad": {"a": "ff7ab6", "b": "5a8cff", "angle": PI / 2, "amount": 0.45, "blend": "screen"},
			"cc": {"hue": 0.0, "saturation": 1.3, "brightness": 0.03, "contrast": 1.1}},
	]
	for i in variants.size():
		var doc := RbDocument.new()
		doc.background = Color(0, 0, 0, 0)
		doc.canvas_size = Vector2i(1, 1)
		var r := RbImporter.image_to_layer(doc, RbIcons.frog_image(240), "f")
		var l := r.layer
		l.scale = Vector2.ONE
		l.position = Vector2(150 + i * 300, 210)
		l.rotation = 0.35 if i == 1 else 0.0  # повёрнутый: свет должен остаться сверху-справа
		l.effects = variants[i]
		doc.images[l.image_id] = r.image
		doc.insert_layer(l)
		var ren := RbRenderer.new()
		root.add_child(ren)
		ren.sync(doc, RbEvaluator.new().evaluate(doc, 0))
	for i in 6:
		await process_frame
	await RenderingServer.frame_post_draw
	var out := ProjectSettings.globalize_path("res://").path_join("../build/shots").simplify_path()
	DirAccess.make_dir_recursive_absolute(out)
	root.get_texture().get_image().save_png(out.path_join("fx.png"))
	quit()
