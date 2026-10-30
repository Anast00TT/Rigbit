extends RefCounted

var t  # раннер


func _grid(cols: int, rows: int, cell: float) -> Array:
	var v := PackedVector2Array()
	var idx := PackedInt32Array()
	for y in rows:
		for x in cols:
			v.append(Vector2(x, y) * cell)
	for y in rows - 1:
		for x in cols - 1:
			var i := y * cols + x
			idx.append_array([i, i + 1, i + cols, i + 1, i + cols + 1, i + cols])
	return [v, idx]


func test_identity_when_pins_at_rest() -> void:
	var g := _grid(6, 4, 10.0)
	var a := RbArap.new()
	var pins := PackedInt32Array([0, 5])
	a.prepare(g[0], g[1], pins)
	var out := a.solve(PackedVector2Array([g[0][0], g[0][5]]), g[0])
	var err := 0.0
	for i in out.size():
		err = maxf(err, out[i].distance_to(g[0][i]))
	t.check(err < 0.01, "пины на месте: сетка не двигается (%f)" % err)


func test_translation_is_rigid() -> void:
	var g := _grid(6, 4, 10.0)
	var a := RbArap.new()
	a.prepare(g[0], g[1], PackedInt32Array([0, 23]))
	var d := Vector2(30, -12)
	var out := a.solve(PackedVector2Array([g[0][0] + d, g[0][23] + d]), g[0], 4)
	var err := 0.0
	for i in out.size():
		err = maxf(err, out[i].distance_to(g[0][i] + d))
	t.check(err < 0.05, "сдвиг обоих пинов сдвигает сетку целиком (%f)" % err)


func test_pins_followed_and_shape_kept() -> void:
	var g := _grid(10, 3, 10.0)
	var a := RbArap.new()
	a.prepare(g[0], g[1], PackedInt32Array([0, 10, 20, 9]))
	var tg := PackedVector2Array([g[0][0], g[0][10], g[0][20], g[0][9] + Vector2(0, 40)])
	var out: PackedVector2Array
	for k in 6:
		out = a.solve(tg, PackedVector2Array(), 3)
	t.check(out[9].distance_to(tg[3]) < 0.5, "пин дотянут: %s" % out[9])
	t.check(out[0].distance_to(g[0][0]) < 0.5, "закреплённый край на месте")
	# длины рёбер вдоль полосы почти сохраняются (жёсткость)
	var worst := 0.0
	for x in 9:
		worst = maxf(worst, absf(out[x].distance_to(out[x + 1]) - 10.0))
	t.check(worst < 3.0, "рёбра не растянуты сильно: %f" % worst)


func test_band_is_narrow_and_fast() -> void:
	var g := _grid(18, 17, 10.0)  # ~300 вершин
	var a := RbArap.new()
	var t0 := Time.get_ticks_usec()
	a.prepare(g[0], g[1], PackedInt32Array([0, 17, 288, 305]))
	var prep_ms := (Time.get_ticks_usec() - t0) / 1000.0
	t.check(a.band_width() < 40, "лента узкая: %d" % a.band_width())
	t0 = Time.get_ticks_usec()
	a.solve(PackedVector2Array([g[0][0], g[0][17] + Vector2(20, 0), g[0][288], g[0][305]]), PackedVector2Array(), 3)
	var solve_ms := (Time.get_ticks_usec() - t0) / 1000.0
	print("    ARAP 306 вершин: подготовка %.1f мс, кадр %.1f мс, лента %d" % [prep_ms, solve_ms, a.band_width()])
	t.check(solve_ms < 60.0, "кадр укладывается в бюджет на ПК")

func test_pin_in_evaluator() -> void:
	var doc := RbDocument.new()
	var g := _grid(8, 3, 10.0)
	var l := RbLayer.new()
	l.id = doc.new_id()
	l.size = Vector2(70, 20)
	l.mesh_vertices = g[0]
	l.mesh_uvs = g[0]
	l.mesh_indices = g[1]
	doc.insert_layer(l)
	var undo := RbUndoStack.new(doc)
	var pins := [{"id": doc.new_id(), "v": 0, "bone": 0, "offset": Vector2.ZERO}, {"id": doc.new_id(), "v": 7, "bone": 0, "offset": Vector2(0, 25)}]
	undo.push(RbRigCommands.SetPins.new(l.id, [], pins))
	var pose := RbEvaluator.new().evaluate(doc, 0)
	var v: PackedVector2Array = pose.layers[l.id].vertices
	t.check(v[7].distance_to(g[0][7] + Vector2(0, 25)) < 0.5, "свободный пин тянет вершину: %s" % v[7])
	t.check(v[0].distance_to(g[0][0]) < 0.5, "второй пин держит край")
	undo.undo()
	t.check(not doc.rig.pins.has(l.id), "undo убрал пины")
