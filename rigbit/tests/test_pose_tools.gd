extends RefCounted

var t  # раннер


func _bone(rig: RbRig, id: int, name: String, parent := 0) -> RbBone:
	var b := RbBone.new()
	b.id = id
	b.name = name
	b.parent_id = parent
	rig.bones[id] = b
	return b


func test_mirror_name() -> void:
	t.eq(RbPoseTools.mirror_name("arm_L"), "arm_R", "суффикс L")
	t.eq(RbPoseTools.mirror_name("Left Leg"), "Right Leg", "Left с заглавной")
	t.eq(RbPoseTools.mirror_name("hand.r"), "hand.l", "строчная r")
	t.eq(RbPoseTools.mirror_name("Левая рука"), "Правая рука", "русская основа")
	t.eq(RbPoseTools.mirror_name("нога правая"), "нога левая", "в конце")
	t.eq(RbPoseTools.mirror_name("Глаз Л"), "Глаз П", "одна буква")
	t.eq(RbPoseTools.mirror_name("LEFT_EYE"), "RIGHT_EYE", "капсом")
	t.eq(RbPoseTools.mirror_name("Голова"), "", "без стороны")
	t.eq(RbPoseTools.mirror_name("Lip"), "", "буква внутри слова не сторона")
	t.eq(RbPoseTools.mirror_name("Плечо"), "", "«П» внутри слова не сторона")


func test_mirror_map() -> void:
	var rig := RbRig.new()
	_bone(rig, 1, "Тело")
	_bone(rig, 2, "Рука Л", 1)
	_bone(rig, 3, "Рука П", 1)
	_bone(rig, 4, "Нога L", 1)  # пары нет
	var mp := RbPoseTools.mirror_map(rig)
	t.eq(int(mp[2]), 3, "Л -> П")
	t.eq(int(mp[3]), 2, "П -> Л")
	t.eq(int(mp[1]), 1, "центр сам в себя")
	t.eq(int(mp[4]), 4, "без пары сама в себя")


func test_mirrored_pose() -> void:
	var rig := RbRig.new()
	_bone(rig, 1, "Тело")
	_bone(rig, 2, "arm_L", 1)
	_bone(rig, 3, "arm_R", 1)
	var pose := {1: [0.3, Vector2(5, 2), Vector2.ONE], 2: [0.5, Vector2(1, 4), Vector2(1.2, 1)], 3: [-0.1, Vector2.ZERO, Vector2.ONE]}
	var m := RbPoseTools.mirrored(rig, pose)
	t.near(m[1][0], -0.3, "центр: угол с обратным знаком")
	t.eq(m[1][1], Vector2(-5, 2), "корень: сдвиг по x отражён")
	t.near(m[3][0], -0.5, "левая рука ушла на правую")
	t.eq(m[3][1], Vector2(1, -4), "дочерняя: отражение поперёк родителя")
	t.eq(m[3][2], Vector2(1.2, 1), "масштаб как был")
	t.near(m[2][0], 0.1, "правая на левую")
	# двойное отражение = исходная поза
	var back := RbPoseTools.mirrored(rig, m)
	for id in pose:
		t.near(back[id][0], pose[id][0], "угол %d обратно" % id)
		t.eq(back[id][1], pose[id][1], "сдвиг %d обратно" % id)


## Симметричный риг: отражённая поза даёт зеркальные мировые координаты кончиков.
func test_mirror_is_geometric() -> void:
	var doc := RbDocument.new()
	var rig := doc.rig
	var body := _bone(rig, 1, "Тело")
	body.position = Vector2(0, 0)
	body.angle = -PI / 2.0  # вверх
	var l := _bone(rig, 2, "Рука L", 1)
	l.position = Vector2(50, 0)
	l.angle = PI / 2.0
	var r := _bone(rig, 3, "Рука R", 1)
	r.position = Vector2(50, 0)
	r.angle = -PI / 2.0
	for b: RbBone in rig.bones.values():
		b.length = 40
	l.pose_angle = 0.4
	l.pose_offset = Vector2(3, -6)
	body.pose_angle = 0.2
	body.pose_offset = Vector2(7, 1)
	var tip_before := _tip(doc, 2)
	var m := RbPoseTools.mirrored(rig, RbPoseTools.snapshot(rig))
	for id in m:
		var b := rig.get_bone(int(id))
		b.pose_angle = m[id][0]
		b.pose_offset = m[id][1]
		b.pose_scale = m[id][2]
	var tip_after := _tip(doc, 3)
	t.near(tip_after.x, -tip_before.x, "кончик правой = отражённый кончик левой (x)")
	t.near(tip_after.y, tip_before.y, "кончик правой = отражённый кончик левой (y)")


func _tip(doc: RbDocument, id: int) -> Vector2:
	var w := RbEvaluator.new().evaluate(doc, 0, true).bones[id] as Transform2D
	return w * Vector2(doc.rig.get_bone(id).length, 0)


func test_key_entries() -> void:
	var doc := RbDocument.new()
	var b := _bone(doc.rig, 1, "Тело")
	b.pose_angle = 0.2
	var e := RbPoseTools.key_entries(doc, RbPoseTools.rest_pose([1]))
	t.eq(e.size(), 1, "меняется только угол")
	t.eq(e[0][0], RbAnimation.track_key("bone", 1, &"pose_angle"), "дорожка угла")
	t.near(e[0][2], 0.2, "прежнее значение для отката")
	doc.anim.set_key(RbAnimation.track_key("bone", 1, &"pose_scale"), 0, Vector2.ONE)
	t.eq(RbPoseTools.key_entries(doc, RbPoseTools.rest_pose([1])).size(), 2, "дорожка с ключами тоже получает ключ")
