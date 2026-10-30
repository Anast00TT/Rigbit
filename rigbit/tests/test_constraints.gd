extends RefCounted

var t  # раннер


func _chain(doc: RbDocument) -> Array:
	var a := RbBone.new()
	a.id = doc.new_id()
	a.length = 100
	doc.rig.bones[a.id] = a
	var b := RbBone.new()
	b.id = doc.new_id()
	b.parent_id = a.id
	b.position = Vector2(100, 0)
	b.length = 50
	doc.rig.bones[b.id] = b
	return [a, b]


func test_limit() -> void:
	var doc := RbDocument.new()
	var c := _chain(doc)
	c[1].constraints = {"limit": {"min": -0.5, "max": 0.5}}
	c[1].pose_angle = 2.0
	var w := doc.rig.world_transforms(true)
	t.near((w[c[1].id] as Transform2D).get_rotation(), 0.5, "угол упёрся в предел")


func test_independent_angle() -> void:
	var doc := RbDocument.new()
	var c := _chain(doc)
	c[1].constraints = {"independent": true}
	c[0].pose_angle = 1.0
	var w := doc.rig.world_transforms(true)
	t.near((w[c[1].id] as Transform2D).get_rotation(), 0.0, "ребёнок не повернулся вслед за родителем")
	t.check((w[c[1].id] as Transform2D).origin.distance_to(Vector2(cos(1.0), sin(1.0)) * 100) < 0.01, "но начало едет за родителем")


func test_copy_negative() -> void:
	var doc := RbDocument.new()
	var c := _chain(doc)
	var other := RbBone.new()
	other.id = doc.new_id()
	other.position = Vector2(0, 200)
	other.length = 40
	other.constraints = {"copy": {"from": c[0].id, "angle": -1.0}}
	doc.rig.bones[other.id] = other
	c[0].pose_angle = 0.4
	var w := doc.rig.world_transforms(true)
	t.near((w[other.id] as Transform2D).get_rotation(), -0.4, "зеркальный поворот с множителем -1")


func test_target() -> void:
	var doc := RbDocument.new()
	var c := _chain(doc)
	var eye := RbBone.new()
	eye.id = doc.new_id()
	eye.position = Vector2(0, 100)
	eye.length = 10
	eye.constraints = {"target": c[0].id}
	doc.rig.bones[eye.id] = eye
	var w := doc.rig.world_transforms(true)
	t.near((w[eye.id] as Transform2D).get_rotation(), -PI / 2, "смотрит на начало целевой кости")


func test_dynamics_lags_and_settles() -> void:
	var doc := RbDocument.new()
	var c := _chain(doc)
	c[1].constraints = {"dynamics": {"spring": 0.4, "damping": 0.3, "torque": 0.0}}
	var k := RbAnimation.track_key("bone", c[0].id, &"pose_angle")
	doc.anim.set_key(k, 0, 0.0, "linear")
	doc.anim.set_key(k, 6, 1.0, "linear")
	var dyn := RbDynamics.new()
	var at4: float = dyn.offsets(doc, 4).get(c[1].id, 0.0)
	var at7: float = dyn.offsets(doc, 7).get(c[1].id, 0.0)
	var at60: float = dyn.offsets(doc, 60).get(c[1].id, 0.0)
	t.check(absf(at7) > 0.01, "после резкой остановки хвост раскачивается: %f" % at7)
	t.check(absf(at60) < 0.02, "со временем успокаивается: %f" % at60)
	t.eq(doc.current_frame, 0, "симуляция не сбила текущий кадр")
	# детерминированность: повтор даёт тот же результат
	var dyn2 := RbDynamics.new()
	t.near(dyn2.offsets(doc, 4).get(c[1].id, 0.0), at4, "повторяемо")


func test_constraints_saved() -> void:
	var doc := RbDocument.new()
	var c := _chain(doc)
	c[1].constraints = {"limit": {"min": -0.2, "max": 0.3}, "dynamics": {"spring": 0.5}}
	var path := "user://test_constraints.rigbit"
	RbProjectIO.save(doc, path)
	var back := RbProjectIO.load_doc(path)
	var bc: Dictionary = back.rig.get_bone(c[1].id).constraints
	t.near(float(bc["limit"]["max"]), 0.3, "предел сохранился")
	t.check(bc.has("dynamics"), "динамика сохранилась")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
