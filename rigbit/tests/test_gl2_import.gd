extends RefCounted
## Импорт Gacha Life 2 по фикстуре мода (design/gacha_import.md, п. 7).

var t  # раннер

const FIXTURE := "res://tests/fixtures/gl2_claude.svg"

var _res: RbGl2Import.Result
var _doc: RbDocument


func _built() -> RbGl2Import.Result:
	if _res == null:
		_doc = RbDocument.new()
		var t0 := Time.get_ticks_msec()
		_res = RbGl2Import.build(_doc, FileAccess.get_file_as_string(FIXTURE))
		print("    импорт GL2: %d мс, %d слоёв, %d костей" % [Time.get_ticks_msec() - t0, _res.layers.size(), _res.bones.size()])
	return _res


func _layer(key: String) -> RbLayer:
	var id: int = _built().parts.get(key, 0)
	for l in _res.layers:
		if l.id == id:
			return l
	return null


func _bone(name: String) -> RbBone:
	var id: int = _built().bone_ids.get(name, 0)
	for b in _res.bones:
		if b.id == id:
			return b
	return null


func _world(name: String) -> Transform2D:
	var rig := RbRig.new()
	for b in _built().bones:
		rig.bones[b.id] = b
	return rig.world_transforms(false)[_res.bone_ids[name]]


func test_parse_fixture() -> void:
	var text := FileAccess.get_file_as_string(FIXTURE)
	t.check(RbGl2Import.is_gl2(text), "узнаём GL2-персонажа")
	var root := RbGl2Import.parse(text)
	var piv := RbGl2Import.pivots(root)
	t.eq(piv.size(), 13, "13 пивотов")
	t.near((piv["hand"] as Transform2D).origin.x, 358.5, "пивот кисти")
	var ch := RbGl2Import.find_named(RbGl2Import._find_char(root), "char")
	var names := RbGl2Import.named_children(ch).map(func(c: Dictionary) -> String: return c["a"]["data-name"])
	t.eq(names[0], "shadow", "сзади тень")
	t.eq(names[names.size() - 1], "fx1", "спереди fx1")
	t.check(names.find("body") < names.find("shoulder") and names.find("head") < names.find("handx"), "порядок частей как в игре")


func test_parts_and_switches() -> void:
	var r := _built()
	t.check(r.ok, "импорт прошёл: " + r.error)
	for key in ["body", "headshape", "eye1/sclera", "eye1/eyeball", "eye1/eyeshape", "mouth", "forearm1", "hand1", "sleeve1", "hand2", "foot", "backfoot"]:
		t.check(_layer(key) != null, "часть " + key)
	t.check(r.canvas.y >= 1490 and r.canvas.y <= 1510, "холст под высоту ~1500 px (%d)" % r.canvas.y)
	var kinds := {}
	for l in r.layers:
		kinds[l.name] = l.kind
	for sw in ["eye1", "eye2", "mouth", "hand1", "hand2"]:
		t.eq(kinds.get(sw, -1), RbLayer.Kind.SWITCH, sw + " свитч")
	t.eq(r.svgs.size(), r.images.size(), "у каждой картинки свой SVG")
	t.check((r.svgs[_layer("hand1").image_id] as String).begins_with("<svg"), "SVG части самостоятельный")


func test_eye_mask_not_baked() -> void:
	var ball := _layer("eye1/eyeball")
	var sclera := _layer("eye1/sclera")
	t.eq(ball.mask_id, sclera.id, "зрачок обрезается склерой")
	var top_ball := ball.position.y - ball.size.y * 0.5
	var top_sclera := sclera.position.y - sclera.size.y * 0.5
	t.check(top_ball < top_sclera - 1.0, "зрачок растрирован без клипа: верх радужки выше склеры (%.1f < %.1f)" % [top_ball, top_sclera])
	t.check(not (_built().svgs[ball.image_id] as String).contains("clip-path"), "в SVG зрачка нет clip-path")


func test_skeleton_from_pivots() -> void:
	var r := _built()
	t.eq(r.bones.size(), 38 - 4, "кости Moho без Hip1/2 и Waist1/2 (изгиб тела дают автовеса)")
	var cx := func(name: String) -> Vector2:
		var root := RbGl2Import.parse(FileAccess.get_file_as_string(FIXTURE))
		var vbs: PackedFloat64Array = str(root["a"]["viewBox"]).split_floats(" ", false)
		var k := RbGl2Import.TARGET_H / vbs[3]
		return ((RbGl2Import.pivots(root)[name] as Transform2D).origin - Vector2(vbs[0], vbs[1])) * k
	t.near(_world("Shoulder1").origin.distance_to(cx.call("shoulder")), 0.0, "плечо в пивоте плеча", 0.5)
	t.near(_world("Forearm1").origin.distance_to(cx.call("arm")), 0.0, "локоть в пивоте arm", 0.5)
	t.near(_world("Brush1").origin.distance_to(cx.call("hand")), 0.0, "запястье в пивоте hand", 0.5)
	t.near(_world("Leg1").origin.distance_to(cx.call("thigh")), 0.0, "бедро в пивоте thigh", 0.5)
	t.near(_world("leg1_2").origin.distance_to(cx.call("foot")), 0.0, "колено в пивоте foot", 0.5)
	t.near(_world("Forearm2").origin.distance_to(cx.call("backarm")), 0.0, "дальний локоть", 0.5)
	t.eq(int(_bone("leg1_2").constraints["ik"]["target"]), r.bone_ids["target1"], "голень тянется к target1")
	t.eq(_bone("target1").parent_id, 0, "цель без родителя")
	t.check(_bone("Body2").constraints.has("limit"), "у Body2 предел угла")


func test_binding() -> void:
	var r := _built()
	var hand: Dictionary = r.weights[_layer("hand1").id]
	t.eq((hand["bones"] as PackedInt32Array)[0], r.bone_ids["Brush1"], "кисть жёстко на Brush1")
	t.eq((r.weights[_layer("eye1/eyeball").id]["bones"] as PackedInt32Array)[0], r.bone_ids["Pupil1"], "зрачок на Pupil1")
	t.eq((r.weights[_layer("backfoot").id]["bones"] as PackedInt32Array)[0], r.bone_ids["leg2_2"], "дальняя голень")
	var body := _layer("body")
	t.check(body.mesh_vertices.size() > 4, "у тела автосетка")
	var allowed := {}
	for nm in RbGl2Import.BODY_BONES:
		allowed[r.bone_ids[nm]] = true
	var bw: Dictionary = r.weights[body.id]
	var bi: PackedInt32Array = bw["bones"]
	var used := {}
	for i in bi.size():
		if bw["w"][i] > 0.0:
			t.check(allowed.has(bi[i]), "тело только на костях корпуса")
			used[bi[i]] = true
			if not allowed.has(bi[i]):
				break
	t.check(used.size() >= 2, "тело гнётся: несколько костей (%d)" % used.size())


func test_command_one_step() -> void:
	var r := _built()
	var undo := RbUndoStack.new(_doc)
	undo.push(RbImportCharacterCommand.new(r, r.canvas))
	t.eq(undo.size(), 1, "один шаг истории")
	t.eq(_doc.layers.size(), r.layers.size(), "слои на месте")
	t.eq(_doc.rig.bones.size(), r.bones.size(), "кости на месте")
	t.eq(_doc.canvas_size, r.canvas, "холст под персонажа")
	var ev := RbEvaluator.new()
	var pose := ev.evaluate(_doc, 0)
	t.check(pose.order.size() >= 30, "всё рисуется (%d)" % pose.order.size())
	# двигаем корпус вниз: стопы держатся IK на месте
	var tip_before := (_doc.rig.world_transforms(true)[r.bone_ids["leg1_2"]] as Transform2D) * Vector2(_doc.rig.get_bone(r.bone_ids["leg1_2"]).length, 0)
	_doc.rig.get_bone(r.bone_ids["Body1"]).pose_offset = Vector2(0, 0)
	_doc.rig.get_bone(r.bone_ids["Main_bone"]).pose_offset = Vector2(-40, 0)
	var tip_after := (_doc.rig.world_transforms(true)[r.bone_ids["leg1_2"]] as Transform2D) * Vector2(_doc.rig.get_bone(r.bone_ids["leg1_2"]).length, 0)
	t.near(tip_after.distance_to(tip_before), 0.0, "присед/сдвиг: стопа стоит на цели", 0.5)
	undo.undo()
	t.eq(_doc.layers.size(), 0, "undo убрал слои")
	t.eq(_doc.rig.bones.size(), 0, "и кости")
	t.eq(_doc.svgs.size(), 0, "и SVG")
