extends RefCounted

var t  # раннер


func _doc_with_bone() -> Array:
	var doc := RbDocument.new()
	var b := RbBone.new()
	b.id = doc.new_id()
	b.length = 100
	doc.rig.bones[b.id] = b
	return [doc, b]


func test_sample_linear_and_hold() -> void:
	var a := RbAnimation.new()
	var k := RbAnimation.track_key("bone", 1, &"pose_angle")
	a.set_key(k, 0, 0.0, "linear")
	a.set_key(k, 10, 1.0, "linear")
	t.near(a.sample(k, 5), 0.5, "середина")
	t.near(a.sample(k, -3), 0.0, "до первого ключа держит первый")
	t.near(a.sample(k, 30), 1.0, "после последнего держит последний")


func test_interps() -> void:
	var a := RbAnimation.new()
	var k := "bone:1:pose_angle"
	a.set_key(k, 0, 0.0, "step")
	a.set_key(k, 10, 1.0)
	t.near(a.sample(k, 9), 0.0, "ступенька держит")
	a.set_key(k, 0, 0.0, "ease_in")
	t.check(a.sample(k, 5) < 0.5, "ease in медленный старт")
	a.set_key(k, 0, 0.0, "ease_out")
	t.check(a.sample(k, 5) > 0.5, "ease out быстрый старт")
	a.set_key(k, 0, 0.0, "bounce")
	var over := false
	for f in range(1, 10):
		if a.sample(k, f) > 1.0:
			over = true
	t.check(over, "отскок перелетает цель")


func test_vector_track() -> void:
	var a := RbAnimation.new()
	var k := "layer:3:position"
	a.set_key(k, 0, Vector2(0, 0), "linear")
	a.set_key(k, 4, Vector2(8, 4), "linear")
	t.eq(a.sample(k, 2), Vector2(4, 2), "вектор интерполируется")


func test_setkey_undo_and_apply() -> void:
	var r := _doc_with_bone()
	var doc: RbDocument = r[0]
	var b: RbBone = r[1]
	var undo := RbUndoStack.new(doc)
	var k := RbAnimation.track_key("bone", b.id, &"pose_angle")
	undo.push(RbAnimCommands.SetKey.new(k, 0, 0.0))
	doc.current_frame = 10
	undo.push(RbAnimCommands.SetKey.new(k, 10, 1.2))
	t.near(b.pose_angle, 1.2, "ключ записан в кость на текущем кадре")
	doc.current_frame = 5
	doc.anim.apply_frame(doc, 5)
	t.check(b.pose_angle > 0.0 and b.pose_angle < 1.2, "промежуточный кадр")
	doc.current_frame = 10
	undo.undo()
	t.eq(doc.anim.keys_of(k).size(), 1, "undo убрал ключ")
	t.near(b.pose_angle, 0.0, "кость вернулась к оставшемуся ключу")


func test_drag_merges_key() -> void:
	var r := _doc_with_bone()
	var doc: RbDocument = r[0]
	var undo := RbUndoStack.new(doc)
	var k := "bone:%d:pose_angle" % r[1].id
	for i in 5:
		undo.push(RbAnimCommands.SetKey.new(k, 0, i * 0.1), false, true)
	undo.end_gesture()
	t.eq(undo.size(), 1, "жест = один шаг")
	undo.undo()
	t.eq(doc.anim.keys_of(k).size(), 0, "undo убрал ключ жеста целиком")


func test_move_and_remove_keys() -> void:
	var r := _doc_with_bone()
	var doc: RbDocument = r[0]
	var undo := RbUndoStack.new(doc)
	var k := "bone:%d:pose_angle" % r[1].id
	doc.anim.set_key(k, 0, 0.0)
	doc.anim.set_key(k, 5, 1.0)
	doc.anim.set_key(k, 8, 2.0)
	undo.push(RbAnimCommands.MoveKeys.new([[k, 5]], 3))
	t.eq(doc.anim.keys_of(k).size(), 2, "ключ наехал на кадр 8 и заменил его")
	t.near(doc.anim.sample(k, 8), 1.0, "на 8 теперь бывший ключ 5")
	undo.undo()
	t.eq(doc.anim.keys_of(k).size(), 3, "undo вернул все три")
	t.near(doc.anim.sample(k, 8), 2.0, "и старое значение на 8")
	undo.push(RbAnimCommands.RemoveKeys.new([[k, 0], [k, 8]]))
	t.eq(doc.anim.keys_of(k).size(), 1, "удалены два")
	undo.undo()
	t.eq(doc.anim.keys_of(k).size(), 3, "вернулись")


func test_anim_save_load() -> void:
	var r := _doc_with_bone()
	var doc: RbDocument = r[0]
	doc.anim.set_key("bone:%d:pose_offset" % r[1].id, 3, Vector2(1, 2), "bounce")
	var path := "user://test_anim.rigbit"
	t.eq(RbProjectIO.save(doc, path), OK, "сохранение")
	var back := RbProjectIO.load_doc(path)
	var ks := back.anim.keys_of("bone:%d:pose_offset" % r[1].id)
	t.eq(ks.size(), 1, "ключ")
	t.eq(ks[0]["v"], Vector2(1, 2), "вектор")
	t.eq(ks[0]["i"], "bounce", "интерполяция")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
