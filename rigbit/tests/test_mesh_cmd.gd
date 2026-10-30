extends RefCounted
## Тесты команды SetMesh и плотности сетки в проекте.

var t  # раннер


## Круг с непрозрачным центром: автосетка даёт заведомо больше 4 точек.
func _disc(n: int) -> Image:
	var img := Image.create_empty(n, n, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var c := Vector2(n, n) * 0.5
	for y in n:
		for x in n:
			if Vector2(x + 0.5, y + 0.5).distance_to(c) < n * 0.4:
				img.set_pixel(x, y, Color.RED)
	return img


func _doc_with_layer() -> Array:
	var doc := RbDocument.new()
	var undo := RbUndoStack.new(doc)
	var r := RbImporter.image_to_layer(doc, _disc(96), "круг")
	undo.push(RbCommands.AddLayer.new(r.layer, r.image))
	return [doc, undo, doc.get_layer(r.layer.id)]


func _generate_cmd(l: RbLayer, img: Image, density: float) -> RbCommands.SetMesh:
	var m := RbMeshGen.generate(img, density)
	var new_s := {"v": m["vertices"], "uv": m["uvs"], "i": m["indices"], "d": density}
	return RbCommands.SetMesh.new(l.id, RbCommands.SetMesh.snap(l), new_s)


func test_set_mesh_undo_redo() -> void:
	var a := _doc_with_layer()
	var doc: RbDocument = a[0]
	var undo: RbUndoStack = a[1]
	var l: RbLayer = a[2]
	var seen := []
	doc.changed.connect(func(what: StringName) -> void: seen.append(what))
	t.eq(l.mesh_vertices.size(), 4, "сначала 4 угла")
	t.near(l.mesh_density, 0.5, "плотность по умолчанию")
	undo.push(_generate_cmd(l, doc.images[l.image_id], 0.8))
	var n := l.mesh_vertices.size()
	t.check(n > 4, "сетка стала богаче (%d)" % n)
	t.eq(l.mesh_uvs.size(), n, "uv по числу вершин")
	t.check(l.mesh_indices.size() >= 3 and l.mesh_indices.size() % 3 == 0, "треугольники")
	t.near(l.mesh_density, 0.8, "плотность записана")
	t.check(seen.has(&"mesh"), "уведомление mesh")
	var tris := l.mesh_indices.size()
	undo.undo()
	t.eq(l.mesh_vertices.size(), 4, "undo вернул 4 угла")
	t.eq(l.mesh_indices.size(), 6, "undo вернул треугольники")
	t.near(l.mesh_density, 0.5, "undo вернул плотность")
	undo.redo()
	t.eq(l.mesh_vertices.size(), n, "redo вернул сетку")
	t.eq(l.mesh_indices.size(), tris, "redo вернул индексы")
	t.near(l.mesh_density, 0.8, "redo вернул плотность")


func test_set_mesh_label_and_one_step() -> void:
	var a := _doc_with_layer()
	var doc: RbDocument = a[0]
	var undo: RbUndoStack = a[1]
	var l: RbLayer = a[2]
	var cmd := _generate_cmd(l, doc.images[l.image_id], 0.3)
	t.eq(cmd.label, "Сетка", "название шага")
	var before := undo.size()
	undo.push(cmd)
	t.eq(undo.size(), before + 1, "один шаг истории")


## Как живое перетаскивание: слой уже изменён, команда кладётся с already_done.
func test_set_mesh_already_done() -> void:
	var a := _doc_with_layer()
	var doc: RbDocument = a[0]
	var undo: RbUndoStack = a[1]
	var l: RbLayer = a[2]
	undo.push(_generate_cmd(l, doc.images[l.image_id], 0.6))
	var start := RbCommands.SetMesh.snap(l)
	var mesh := {"vertices": l.mesh_vertices, "uvs": l.mesh_uvs, "indices": l.mesh_indices, "size": l.size}
	var idx := RbMeshGen.nearest_vertex(mesh, Vector2.ZERO, 1000.0)
	var target := l.mesh_vertices[idx] + Vector2(2, 1)
	var moved := RbMeshGen.move_point(mesh, idx, target)
	RbCommands.SetMesh.apply_state(l, {"v": moved["vertices"], "uv": moved["uvs"], "i": moved["indices"], "d": l.mesh_density})
	var end := RbCommands.SetMesh.snap(l)
	t.check(end["v"] != start["v"], "точка сдвинулась")
	undo.push(RbCommands.SetMesh.new(l.id, start, end), true)
	undo.undo()
	t.eq(l.mesh_vertices, start["v"], "undo вернул вершины")
	undo.redo()
	t.eq(l.mesh_vertices, end["v"], "redo вернул сдвиг")


func test_density_roundtrip_project() -> void:
	var a := _doc_with_layer()
	var doc: RbDocument = a[0]
	var undo: RbUndoStack = a[1]
	var l: RbLayer = a[2]
	undo.push(_generate_cmd(l, doc.images[l.image_id], 0.8))
	var n := l.mesh_vertices.size()
	var path := "user://test_mesh_density.rigbit"
	t.eq(RbProjectIO.save(doc, path), OK, "сохранение")
	var back := RbProjectIO.load_doc(path)
	t.check(back != null, "загрузка")
	if back:
		var bl := back.get_layer(l.id)
		t.near(bl.mesh_density, 0.8, "плотность после загрузки", 0.0002)
		t.eq(bl.mesh_vertices.size(), n, "вершины после загрузки")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func test_density_default_is_backward_compatible() -> void:
	var a := _doc_with_layer()
	var l: RbLayer = a[2]
	var d := l.to_dict()
	t.check((d["mesh"] as Dictionary).has("d"), "плотность пишется в mesh.d")
	(d["mesh"] as Dictionary).erase("d")
	var old := RbLayer.from_dict(d)
	t.near(old.mesh_density, 0.5, "старый файл без d даёт 0.5")
	t.eq(old.mesh_vertices.size(), 4, "сетка из старого файла цела")
