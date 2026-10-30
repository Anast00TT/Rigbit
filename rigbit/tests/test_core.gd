extends RefCounted

var t  # раннер


func _img(w: int, h: int, c := Color.RED) -> Image:
	var img := Image.create_empty(w, h, false, Image.FORMAT_RGBA8)
	img.fill(c)
	return img


func _add(doc: RbDocument, undo: RbUndoStack, w := 100, h := 50) -> RbLayer:
	var r := RbImporter.image_to_layer(doc, _img(w, h), "слой")
	undo.push(RbCommands.AddLayer.new(r.layer, r.image))
	return doc.get_layer(r.layer.id)


func test_add_undo_redo() -> void:
	var doc := RbDocument.new()
	var undo := RbUndoStack.new(doc)
	var l := _add(doc, undo)
	t.eq(doc.root.size(), 1, "слой добавлен")
	t.eq(doc.images.size(), 1, "картинка в документе")
	t.eq(l.mesh_vertices.size(), 4, "у простого слоя сетка из 4 углов")
	undo.undo()
	t.eq(doc.root.size(), 0, "undo убрал слой")
	t.eq(doc.images.size(), 0, "undo убрал картинку")
	undo.redo()
	t.eq(doc.root.size(), 1, "redo вернул слой")
	t.check(doc.get_layer(l.id) != null, "тот же id после redo")


func test_drag_merges_into_one_step() -> void:
	var doc := RbDocument.new()
	var undo := RbUndoStack.new(doc)
	var l := _add(doc, undo)
	var start := l.position
	for i in 10:
		var old := l.position
		l.position += Vector2(5, 0)
		undo.push(RbCommands.SetLayerProp.new(l.id, &"position", old, l.position), true, true)
	undo.end_gesture()
	t.eq(undo.size(), 2, "добавление + одно перетаскивание")
	undo.undo()
	t.eq(doc.get_layer(l.id).position, start, "undo вернул позицию до жеста")
	undo.redo()
	t.eq(doc.get_layer(l.id).position, start + Vector2(50, 0), "redo вернул конец жеста")


func test_two_gestures_not_merged() -> void:
	var doc := RbDocument.new()
	var undo := RbUndoStack.new(doc)
	var l := _add(doc, undo)
	undo.push(RbCommands.SetLayerProp.new(l.id, &"opacity", 1.0, 0.5), false, true)
	undo.end_gesture()
	undo.push(RbCommands.SetLayerProp.new(l.id, &"opacity", 0.5, 0.2), false, true)
	t.eq(undo.size(), 3, "жесты раздельно")
	undo.undo()
	t.near(doc.get_layer(l.id).opacity, 0.5, "откат второго жеста")


func test_new_action_clears_redo() -> void:
	var doc := RbDocument.new()
	var undo := RbUndoStack.new(doc)
	_add(doc, undo)
	undo.undo()
	t.check(undo.can_redo(), "есть redo")
	_add(doc, undo)
	t.check(not undo.can_redo(), "новое действие сбросило redo")


func test_remove_layer_undo() -> void:
	var doc := RbDocument.new()
	var undo := RbUndoStack.new(doc)
	var a := _add(doc, undo)
	var b := _add(doc, undo)
	undo.push(RbCommands.RemoveLayer.new(a.id))
	t.eq(doc.root, [b.id] as Array[int], "a удалён")
	t.check(not doc.images.has(a.image_id), "картинка a убрана")
	undo.undo()
	t.eq(doc.root, [a.id, b.id] as Array[int], "a вернулся на своё место")
	t.check(doc.images.has(a.image_id), "картинка a вернулась")


func test_history_limit() -> void:
	var doc := RbDocument.new()
	var undo := RbUndoStack.new(doc)
	undo.max_steps = 5
	var l := _add(doc, undo)
	for i in 20:
		undo.push(RbCommands.SetLayerProp.new(l.id, &"rotation", float(i), float(i + 1)))
	t.eq(undo.size(), 5, "история обрезана до лимита")


func test_import_downscale_and_fit() -> void:
	var doc := RbDocument.new()
	var r := RbImporter.image_to_layer(doc, _img(5000, 100), "big")
	t.eq(r.error, "", "без ошибки")
	t.check(r.warnings.has("IMPORT_WARN_DOWNSCALED"), "предупреждение об уменьшении")
	t.eq(r.image.get_width(), 4096, "сторона ограничена 4096")
	t.check(r.layer.scale.x < 1.0, "вписан в холст")
	t.eq(r.layer.position, Vector2(doc.canvas_size) * 0.5, "по центру холста")


func test_save_load_roundtrip() -> void:
	var doc := RbDocument.new()
	var undo := RbUndoStack.new(doc)
	doc.fps = 30
	var l := _add(doc, undo, 64, 32)
	l.rotation = 0.5
	l.opacity = 0.25
	var path := "user://test_roundtrip.rigbit"
	t.eq(RbProjectIO.save(doc, path), OK, "сохранение")
	var back := RbProjectIO.load_doc(path)
	t.check(back != null, "загрузка")
	if back == null:
		return
	t.eq(back.fps, 30, "fps")
	t.eq(back.root.size(), 1, "слои")
	var bl := back.get_layer(l.id)
	t.near(bl.rotation, 0.5, "поворот")
	t.near(bl.opacity, 0.25, "прозрачность")
	t.eq(bl.mesh_vertices.size(), 4, "сетка")
	var img: Image = back.images[bl.image_id]
	t.eq(img.get_size(), Vector2i(64, 32), "картинка")
	t.eq(img.get_pixel(3, 3), Color.RED, "пиксели")
	t.check(back.new_id() > l.id, "счётчик id не повторяет старые")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func test_migrate_keeps_current_version() -> void:
	var d := {"format_version": 1, "layers": []}
	t.eq(int(RbProjectIO.migrate(d)["format_version"]), RbDocument.FORMAT_VERSION, "версия")


func test_evaluator_group_transform() -> void:
	var doc := RbDocument.new()
	var g := RbLayer.new()
	g.id = doc.new_id()
	g.kind = RbLayer.Kind.GROUP
	g.position = Vector2(100, 0)
	g.opacity = 0.5
	doc.insert_layer(g)
	var c := RbLayer.new()
	c.id = doc.new_id()
	c.parent_id = g.id
	c.position = Vector2(10, 0)
	c.opacity = 0.5
	c.size = Vector2(4, 4)
	c.make_quad_mesh()
	doc.insert_layer(c)
	var pose := RbEvaluator.new().evaluate(doc, 0)
	t.eq(pose.order, [c.id] as Array[int], "в отрисовке только растровые")
	t.eq(pose.layers[c.id].world.origin, Vector2(110, 0), "мировая позиция через группу")
	t.near(pose.layers[c.id].opacity, 0.25, "прозрачность перемножается")
