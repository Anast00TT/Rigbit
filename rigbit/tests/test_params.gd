extends RefCounted

var t  # раннер


func _setup() -> Array:
	var doc := RbDocument.new()
	var b := RbBone.new()
	b.id = doc.new_id()
	b.length = 100
	doc.rig.bones[b.id] = b
	var p := RbParams.Param.new()
	p.id = doc.new_id()
	p.name = "Моргание"
	p.min_v = 0.0
	p.max_v = 1.0
	p.forms[1.0] = {"bones": {b.id: {"angle": 1.0}}}
	doc.params.params[p.id] = p
	return [doc, b, p]


func test_form_interpolates_from_default() -> void:
	var r := _setup()
	var p: RbParams.Param = r[2]
	p.value = 0.5
	var bl: Dictionary = r[0].params.blend()
	t.near(float(bl["bones"][r[1].id]["angle"]), 0.5, "половина значения = половина формы")
	p.value = 0.0
	bl = r[0].params.blend()
	t.near(float(bl["bones"].get(r[1].id, {"angle": 0.0})["angle"]), 0.0, "по умолчанию формы нет")


func test_additive_two_params() -> void:
	var r := _setup()
	var doc: RbDocument = r[0]
	var q := RbParams.Param.new()
	q.id = doc.new_id()
	q.forms[1.0] = {"bones": {r[1].id: {"angle": 0.25}}}
	q.value = 1.0
	doc.params.params[q.id] = q
	(r[2] as RbParams.Param).value = 1.0
	var bl := doc.params.blend()
	t.near(float(bl["bones"][r[1].id]["angle"]), 1.25, "дельты складываются")


func test_evaluator_applies_form() -> void:
	var r := _setup()
	var doc: RbDocument = r[0]
	(r[2] as RbParams.Param).value = 1.0
	var pose := RbEvaluator.new().evaluate(doc, 0, true)
	t.near((pose.bones[r[1].id] as Transform2D).get_rotation(), 1.0, "кость повернулась формой")
	var rest := RbEvaluator.new().evaluate(doc, 0, false)
	t.near((rest.bones[r[1].id] as Transform2D).get_rotation(), 0.0, "в риге формы не действуют")


func test_driver_and_cycle_guard() -> void:
	var r := _setup()
	var doc: RbDocument = r[0]
	var src := RbParams.Param.new()
	src.id = doc.new_id()
	src.min_v = -1.0
	src.max_v = 1.0
	doc.params.params[src.id] = src
	var p: RbParams.Param = r[2]
	t.check(doc.params.can_drive(src.id, p.id), "можно src -> моргание")
	src.drivers.append({"target": p.id, "k": 0.5, "b": 0.0})
	t.check(not doc.params.can_drive(p.id, src.id), "обратная связь запрещена (цикл)")
	t.check(not doc.params.can_drive(p.id, p.id), "сам на себя нельзя")
	src.value = 1.0
	doc.params.resolve_drivers()
	t.near(p.value, 0.5, "ведомый = 0.5 * ведущий")


func test_param_track_and_save() -> void:
	var r := _setup()
	var doc: RbDocument = r[0]
	var p: RbParams.Param = r[2]
	var k := RbAnimation.track_key("param", p.id, &"value")
	doc.anim.set_key(k, 0, 0.0, "linear")
	doc.anim.set_key(k, 10, 1.0, "linear")
	doc.anim.apply_frame(doc, 5)
	t.near(p.value, 0.5, "значение ползунка анимируется дорожкой")
	var path := "user://test_params.rigbit"
	RbProjectIO.save(doc, path)
	var back := RbProjectIO.load_doc(path)
	var bp := back.params.get_param(p.id)
	t.eq(bp.name, "Моргание", "имя")
	t.check(bp.forms.has(1.0), "форма в точке 1")
	t.near(float(bp.forms[1.0]["bones"][r[1].id]["angle"]), 1.0, "дельта кости")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
