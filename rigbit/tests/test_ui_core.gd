extends RefCounted
## Ядро для интерфейса: пины, формы параметров, ключи IK, ограничения, эффекты.

var t  # раннер


func _doc_with_chain() -> Array:
	var doc := RbDocument.new()
	var a := RbBone.new()
	a.id = doc.new_id()
	a.length = 100
	doc.rig.bones[a.id] = a
	var b := RbBone.new()
	b.id = doc.new_id()
	b.parent_id = a.id
	b.position = Vector2(100, 0)
	b.length = 80
	doc.rig.bones[b.id] = b
	return [doc, a, b]


func _doc_with_layer() -> Array:
	var doc := RbDocument.new()
	var l := RbLayer.new()
	l.id = doc.new_id()
	l.size = Vector2(100, 100)
	l.make_quad_mesh()
	doc.insert_layer(l)
	return [doc, l]


# ---------------- пины ----------------

func test_pin_helpers() -> void:
	var v := PackedVector2Array([Vector2(0, 0), Vector2(10, 0), Vector2(10, 10)])
	t.eq(RbPins.nearest_vertex(v, Vector2(9, 1)), 1, "ближайшая вершина")
	t.eq(RbPins.nearest_vertex(PackedVector2Array(), Vector2.ZERO), -1, "пустая сетка")
	var pins: Array = []
	pins = RbPins.added(pins, RbPins.new_pin(7, 2))
	pins = RbPins.added(pins, RbPins.new_pin(8, 0))
	t.eq(pins.size(), 2, "два пина")
	t.eq(int(RbPins.at_vertex(pins, 2)["id"]), 7, "пин на вершине 2")
	t.check(RbPins.at_vertex(pins, 1).is_empty(), "на вершине 1 пина нет")
	var rb := RbPins.rebound(pins, 7, 5)
	t.eq(int(rb[0]["bone"]), 5, "привязан к кости 5")
	t.eq(int(pins[0]["bone"]), 0, "исходный список не тронут")
	t.eq(RbPins.removed(pins, 7).size(), 1, "пин удалён")
	t.eq(RbPins.removed(pins, 7)[0]["id"], 8, "остался другой")


func test_pin_offset_helpers() -> void:
	# свободный пин: база = сама вершина
	var lw := Transform2D(0.0, Vector2(100, 50))
	var base := RbPins.base_position(Vector2(10, 0), 0, lw, {}, {})
	t.eq(base, Vector2(10, 0), "свободный пин: база на вершине")
	t.eq(RbPins.offset_for(Vector2(15, 4), base), Vector2(5, 4), "смещение = цель минус база")
	# пин на кости: база уезжает вместе с костью (кость сдвинута на (20, 0) в мире)
	var rest := {3: Transform2D(0.0, Vector2.ZERO)}
	var posed := {3: Transform2D(0.0, Vector2(20, 0))}
	var b2 := RbPins.base_position(Vector2(10, 0), 3, lw, posed, rest)
	t.check(b2.distance_to(Vector2(30, 0)) < 0.001, "база двигается с костью (%s)" % str(b2))


func test_pin_offset_key_undo() -> void:
	var r := _doc_with_layer()
	var doc: RbDocument = r[0]
	var l: RbLayer = r[1]
	var undo := RbUndoStack.new(doc)
	var pin := RbPins.new_pin(doc.new_id(), 2)
	undo.push(RbRigCommands.SetPins.new(l.id, [], [pin]))
	var tk := RbAnimation.track_key("pin", int(pin["id"]), &"offset")
	doc.current_frame = 8
	var rest: Vector2 = doc.rig.find_pin(int(pin["id"])).get("offset", Vector2.ZERO)
	undo.push(RbAnimCommands.SetKeyAuto.new(tk, 8, Vector2(5, 6), rest), false, true)
	undo.push(RbAnimCommands.SetKeyAuto.new(tk, 8, Vector2(7, 9), rest), false, true)
	t.eq(doc.rig.find_pin(int(pin["id"]))["offset"], Vector2(7, 9), "смещение пина в кадре 8")
	t.eq(doc.anim.keys_of(tk).size(), 2, "стартовый ключ на 0 и ключ на 8 (жест склеился)")
	doc.current_frame = 0
	doc.anim.apply_frame(doc, 0)
	t.eq(doc.rig.find_pin(int(pin["id"]))["offset"], Vector2.ZERO, "в кадре 0 смещения нет")
	doc.current_frame = 8
	undo.undo()
	t.check(not doc.anim.tracks.has(tk), "undo жеста убрал дорожку")
	t.eq(doc.rig.find_pin(int(pin["id"]))["offset"], Vector2.ZERO, "undo вернул смещение пина")
	undo.redo()
	t.eq(doc.rig.find_pin(int(pin["id"]))["offset"], Vector2(7, 9), "redo")


func test_pin_offset_at_frame_zero_is_base() -> void:
	var r := _doc_with_layer()
	var doc: RbDocument = r[0]
	var l: RbLayer = r[1]
	var undo := RbUndoStack.new(doc)
	var pin := RbPins.new_pin(doc.new_id(), 1)
	undo.push(RbRigCommands.SetPins.new(l.id, [], [pin]))
	var tk := RbAnimation.track_key("pin", int(pin["id"]), &"offset")
	doc.rig_mode = true  # режим Риг: показывает кадр 0
	undo.push(RbAnimCommands.SetKeyAuto.new(tk, 0, Vector2(3, 4), Vector2.ZERO), false, true)
	t.eq(doc.rig.find_pin(int(pin["id"]))["offset"], Vector2(3, 4), "база задана ключом кадра 0")
	undo.undo()
	t.eq(doc.rig.find_pin(int(pin["id"]))["offset"], Vector2.ZERO, "undo базы вернул ноль")
	t.check(not doc.anim.tracks.has(tk), "дорожки нет")


func test_pin_set_remove_bind_undo() -> void:
	var r := _doc_with_layer()
	var doc: RbDocument = r[0]
	var l: RbLayer = r[1]
	var undo := RbUndoStack.new(doc)
	var p := RbPins.new_pin(doc.new_id(), 0)
	undo.push(RbRigCommands.SetPins.new(l.id, [], RbPins.added([], p)))
	t.eq((doc.rig.pins[l.id] as Array).size(), 1, "пин добавлен")
	var cur: Array = doc.rig.pins[l.id]
	undo.push(RbRigCommands.SetPins.new(l.id, cur, RbPins.rebound(cur, int(p["id"]), 9)))
	t.eq(int(doc.rig.pins[l.id][0]["bone"]), 9, "привязан")
	undo.undo()
	t.eq(int(doc.rig.pins[l.id][0]["bone"]), 0, "undo привязки")
	cur = doc.rig.pins[l.id]
	undo.push(RbRigCommands.SetPins.new(l.id, cur, RbPins.removed(cur, int(p["id"]))))
	t.check(not doc.rig.pins.has(l.id), "пин удалён, список пуст")
	undo.undo()
	t.eq((doc.rig.pins[l.id] as Array).size(), 1, "undo удаления")


# ---------------- IK-ключи ----------------

func test_ik_keys_merge_and_undo() -> void:
	var r := _doc_with_chain()
	var doc: RbDocument = r[0]
	var a: RbBone = r[1]
	var b: RbBone = r[2]
	var undo := RbUndoStack.new(doc)
	var ta := RbAnimation.track_key("bone", a.id, &"pose_angle")
	var tb := RbAnimation.track_key("bone", b.id, &"pose_angle")
	doc.current_frame = 6
	undo.push(RbAnimCommands.SetKeysAuto.new([ta, tb], 6, [0.3, -0.4], [0.0, 0.0]), false, true)
	undo.push(RbAnimCommands.SetKeysAuto.new([ta, tb], 6, [0.5, -0.7], [0.3, -0.4]), false, true)
	t.near(a.pose_angle, 0.5, "угол первой кости")
	t.near(b.pose_angle, -0.7, "угол второй кости")
	t.eq(undo.size(), 1, "два шага одного жеста склеились в один")
	t.eq(doc.anim.keys_of(ta).size(), 2, "ключи 0 и 6 у первой кости")
	undo.undo()
	t.check(not doc.anim.tracks.has(ta) and not doc.anim.tracks.has(tb), "undo снял обе дорожки")
	t.near(a.pose_angle, 0.0, "угол первой вернулся")
	t.near(b.pose_angle, 0.0, "угол второй вернулся")
	undo.redo()
	t.near(a.pose_angle, 0.5, "redo первой")
	t.near(b.pose_angle, -0.7, "redo второй")


func test_ik_solution_reaches_target() -> void:
	var r := _doc_with_chain()
	var doc: RbDocument = r[0]
	var chain := RbIK.chain_for(doc.rig, r[2].id, 2)
	t.eq(chain.size(), 2, "цепочка из двух костей")
	var posed := doc.rig.world_transforms(true)
	var target := Vector2(120, 90)
	var sol := RbIK.solve(doc.rig, chain, posed, target)
	for id in sol:
		doc.rig.get_bone(id).pose_angle = sol[id]
	var w := doc.rig.world_transforms(true)
	var tip: Vector2 = (w[r[2].id] as Transform2D) * Vector2(80, 0)
	t.check(tip.distance_to(target) < 0.5, "кончик дошёл до цели (%s)" % str(tip))


# ---------------- параметры ----------------

func _param(doc: RbDocument, nm := "Моргание") -> RbParams.Param:
	var p := RbParams.Param.new()
	p.id = doc.new_id()
	p.name = nm
	return p


func test_param_add_remove_undo() -> void:
	var doc := RbDocument.new()
	var undo := RbUndoStack.new(doc)
	var a := _param(doc, "A")
	var b := _param(doc, "B")
	undo.push(RbParamCommands.AddParam.new(a))
	undo.push(RbParamCommands.AddParam.new(b))
	a.value = 0.0
	var pa := doc.params.get_param(a.id)
	pa.drivers.append({"target": b.id, "k": 1.0, "b": 0.0})
	var tk := RbAnimation.track_key("param", b.id, &"value")
	doc.anim.set_key(tk, 0, 0.5, "linear")
	undo.push(RbParamCommands.RemoveParam.new(b.id))
	t.check(doc.params.get_param(b.id) == null, "параметр удалён")
	t.eq(pa.drivers.size(), 0, "драйверы на него сняты")
	t.check(not doc.anim.tracks.has(tk), "его дорожка снята")
	undo.undo()
	t.check(doc.params.get_param(b.id) != null, "undo вернул параметр")
	t.eq(pa.drivers.size(), 1, "драйвер вернулся")
	t.check(doc.anim.tracks.has(tk), "дорожка вернулась")
	t.eq(doc.params.params.keys(), [a.id, b.id], "порядок в списке прежний")
	undo.undo()
	undo.undo()
	t.eq(doc.params.params.size(), 0, "два undo убрали оба")


func test_param_props_undo() -> void:
	var doc := RbDocument.new()
	var undo := RbUndoStack.new(doc)
	var p := _param(doc)
	undo.push(RbParamCommands.AddParam.new(p))
	var cur := doc.params.get_param(p.id)
	cur.value = 0.9
	var old := RbParamCommands.SetParamProps.snap(cur)
	undo.push(RbParamCommands.SetParamProps.new(p.id, old, {"name": "Улыбка", "min": -1.0, "max": 0.5, "default": 0.0}))
	t.eq(cur.name, "Улыбка", "имя")
	t.near(cur.max_v, 0.5, "максимум")
	t.near(cur.value, 0.5, "значение подрезано под диапазон")
	undo.undo()
	t.eq(cur.name, "Моргание", "undo имени")
	t.near(cur.max_v, 1.0, "undo диапазона")


func test_param_forms_command_one_step() -> void:
	var doc := RbDocument.new()
	var undo := RbUndoStack.new(doc)
	var b := RbBone.new()
	b.id = doc.new_id()
	doc.rig.bones[b.id] = b
	var p := _param(doc)
	undo.push(RbParamCommands.AddParam.new(p))
	var cur := doc.params.get_param(p.id)
	var old := cur.forms.duplicate(true)
	# живая правка: форма пишется прямо в параметр, шаг истории один, в конце
	var f := RbFormEdit.empty_form()
	RbFormEdit.set_bone_prop(f, b.id, "angle", 0.2)
	RbFormEdit.set_bone_prop(f, b.id, "angle", 0.6)
	RbFormEdit.set_vert_delta(f, 5, 1, 3, Vector2(2, 3))
	cur.forms[1.0] = f
	undo.push(RbParamCommands.SetParamForms.new(p.id, old, cur.forms), true)
	t.eq(undo.size(), 2, "добавление и одна форма")
	cur.value = 1.0
	var bl := doc.params.blend()
	t.near(float(bl["bones"][b.id]["angle"]), 0.6, "форма действует в точке 1")
	t.eq((bl["verts"][5] as PackedVector2Array)[1], Vector2(2, 3), "дельта вершины")
	undo.undo()
	t.check(cur.forms.is_empty(), "undo убрал форму целиком")
	undo.redo()
	t.check(cur.forms.has(1.0), "redo вернул форму")
	t.near(float(cur.forms[1.0]["bones"][b.id]["angle"]), 0.6, "значение формы после redo")


func test_form_edit_helpers() -> void:
	var f := RbFormEdit.empty_form()
	t.check(RbFormEdit.is_empty(f), "новая форма пуста")
	RbFormEdit.set_bone_prop(f, 4, "offset", Vector2(1, 2))
	t.eq(RbFormEdit.bone_prop(f, 4, "offset"), Vector2(1, 2), "сдвиг записан")
	t.near(float(RbFormEdit.bone_prop(f, 4, "angle")), 0.0, "угол по умолчанию ноль")
	t.eq(RbFormEdit.bone_prop(f, 99, "scale"), Vector2.ZERO, "нет кости: ноль")
	t.check(not RbFormEdit.is_empty(f), "с дельтой кости форма не пуста")
	var g := RbFormEdit.empty_form()
	RbFormEdit.set_vert_delta(g, 2, 3, 6, Vector2(4, 0))
	t.eq((g["verts"][2] as PackedVector2Array).size(), 6, "массив вершин вырос до числа вершин слоя")
	t.eq(RbFormEdit.vert_delta(g, 2, 3), Vector2(4, 0), "дельта вершины")
	t.eq(RbFormEdit.vert_delta(g, 2, 50), Vector2.ZERO, "вне массива: ноль")
	RbFormEdit.set_vert_delta(g, 2, 3, 6, Vector2.ZERO)
	t.check(RbFormEdit.is_empty(g), "обнулили: форма пуста")
	var doc := RbDocument.new()
	var p := _param(doc)
	p.forms[0.5] = RbFormEdit.empty_form()
	t.near(RbFormEdit.point_key(p, 0.5003), 0.5, "точка с допуском находит существующую форму")
	t.near(RbFormEdit.point_key(p, 0.7), 0.7, "свободная точка как есть")
	t.check(RbFormEdit.has_form(p, 0.5), "форма есть")
	t.check(not RbFormEdit.has_form(p, 0.9), "формы нет")
	t.check((RbFormEdit.normalized({}) as Dictionary).has("verts"), "normalized дополняет разделы")


func test_form_survives_save() -> void:
	var doc := RbDocument.new()
	var b := RbBone.new()
	b.id = doc.new_id()
	doc.rig.bones[b.id] = b
	var p := _param(doc)
	var f := RbFormEdit.empty_form()
	RbFormEdit.set_bone_prop(f, b.id, "angle", 0.75)
	p.forms[1.0] = f
	doc.params.params[p.id] = p
	var path := "user://test_ui_core.rigbit"
	RbProjectIO.save(doc, path)
	var back := RbProjectIO.load_doc(path)
	t.near(float(back.params.get_param(p.id).forms[1.0]["bones"][b.id]["angle"]), 0.75, "форма пережила сохранение")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func test_param_value_autokey_undo() -> void:
	var doc := RbDocument.new()
	var undo := RbUndoStack.new(doc)
	var p := _param(doc)
	undo.push(RbParamCommands.AddParam.new(p))
	var cur := doc.params.get_param(p.id)
	var tk := RbAnimation.track_key("param", p.id, &"value")
	doc.current_frame = 5
	undo.push(RbAnimCommands.SetKeyAuto.new(tk, 5, 0.8, cur.value), false, true)
	t.near(cur.value, 0.8, "ползунок на кадре 5 = 0.8")
	undo.undo()
	t.near(cur.value, 0.0, "undo вернул значение ползунка")
	t.check(not doc.anim.tracks.has(tk), "дорожки нет")


func test_param_drivers_command() -> void:
	var doc := RbDocument.new()
	var undo := RbUndoStack.new(doc)
	var a := _param(doc, "A")
	var b := _param(doc, "B")
	undo.push(RbParamCommands.AddParam.new(a))
	undo.push(RbParamCommands.AddParam.new(b))
	t.check(doc.params.can_drive(a.id, b.id), "A -> B можно")
	undo.push(RbParamCommands.SetParamDrivers.new(a.id, [], [{"target": b.id, "k": 2.0, "b": 0.0}]))
	t.check(not doc.params.can_drive(b.id, a.id), "B -> A теперь цикл")
	var pa := doc.params.get_param(a.id)
	pa.value = 0.25
	doc.params.resolve_drivers()
	t.near(doc.params.get_param(b.id).value, 0.5, "B = 2 * A")
	undo.undo()
	t.eq(pa.drivers.size(), 0, "undo снял драйвер")
	t.check(doc.params.can_drive(b.id, a.id), "цикла больше нет")


# ---------------- констрейны и эффекты ----------------

func test_constraints_command_merge_and_dynamics_reset() -> void:
	var r := _doc_with_chain()
	var doc: RbDocument = r[0]
	var b: RbBone = r[2]
	var undo := RbUndoStack.new(doc)
	var ev := RbEvaluator.new()
	b.constraints = {"dynamics": {"spring": 0.5, "damping": 0.4, "torque": 0.0}}
	doc.frame_count = 10
	doc.current_frame = 4
	ev.evaluate(doc, 0, true)
	t.check(ev.dynamics._states.size() > 0, "динамика посчитана и закеширована")
	for k in [0.1, 0.2, 0.3]:
		var old := b.constraints.duplicate(true)
		var nw := old.duplicate(true)
		nw["dynamics"]["spring"] = k
		undo.push(RbRigCommands.SetBoneProp.new(b.id, &"constraints", old, nw), false, true)
	t.eq(undo.size(), 1, "шаги слайдера склеились")
	t.check(ev.dynamics._states.size() == 0, "правка констрейнов сбросила кеш динамики")
	t.near(float(b.constraints["dynamics"]["spring"]), 0.3, "последнее значение")
	undo.undo()
	t.near(float(b.constraints["dynamics"]["spring"]), 0.5, "undo вернул исходный словарь")
	undo.redo()
	t.near(float(b.constraints["dynamics"]["spring"]), 0.3, "redo")


func test_effects_command_deep_copy_and_merge() -> void:
	var r := _doc_with_layer()
	var doc: RbDocument = r[0]
	var l: RbLayer = r[1]
	var undo := RbUndoStack.new(doc)
	for v in [4.0, 8.0, 12.0]:
		var old := l.effects.duplicate(true)
		var nw := {"rim": {"outside": false, "angle": -0.78, "distance": v}}
		undo.push(RbCommands.SetLayerProp.new(l.id, &"effects", old, nw), false, true)
	t.eq(undo.size(), 1, "жест эффектов склеился")
	t.near(float(l.effects["rim"]["distance"]), 12.0, "последнее значение")
	var keep: Dictionary = l.effects
	var edit := l.effects.duplicate(true)
	edit["rim"]["distance"] = 99.0
	t.near(float(keep["rim"]["distance"]), 12.0, "копия не меняет слой")
	undo.undo()
	t.check(l.effects.is_empty(), "undo вернул пустые эффекты")
	var path := "user://test_fx.rigbit"
	undo.redo()
	l.effects["grad"] = {"a": "ff99cc", "b": "6699ff", "angle": 1.5, "amount": 0.3, "blend": "screen"}
	RbProjectIO.save(doc, path)
	var back := RbProjectIO.load_doc(path)
	var bl := back.get_layer(l.id)
	t.near(float(bl.effects["rim"]["distance"]), 12.0, "эффект после сохранения")
	t.eq(bl.effects["grad"]["a"], "ff99cc", "цвет градиента")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func test_same_dict_detects_form_changes() -> void:
	var doc := RbDocument.new()
	var p := _param(doc)
	var f := RbFormEdit.empty_form()
	RbFormEdit.set_bone_prop(f, 3, "angle", 0.5)
	RbFormEdit.set_vert_delta(f, 7, 2, 4, Vector2(1, 2))
	p.forms[1.0] = f
	var a := p.forms.duplicate(true)
	t.check(RbUi.same_dict(a, p.forms), "копия равна оригиналу")
	RbFormEdit.set_vert_delta(p.forms[1.0], 7, 2, 4, Vector2(1, 3))
	t.check(not RbUi.same_dict(a, p.forms), "правка вершины видна")
	var b := p.forms.duplicate(true)
	RbFormEdit.set_bone_prop(p.forms[1.0], 3, "angle", 0.6)
	t.check(not RbUi.same_dict(b, p.forms), "правка кости видна")
	var c := p.forms.duplicate(true)
	p.forms.erase(1.0)
	t.check(not RbUi.same_dict(c, p.forms), "удаление точки видно")
	t.check(RbUi.same_dict({"a": 1, "b": 2}, {"b": 2, "a": 1}), "порядок ключей не важен")
