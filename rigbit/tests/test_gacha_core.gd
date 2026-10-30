extends RefCounted
## Ядро под импорт Gacha Life 2: свитч, порядок слоёв, постоянная IK, маска.

var t  # раннер


func _layer(doc: RbDocument, name: String, parent := 0, kind := RbLayer.Kind.IMAGE) -> RbLayer:
	var l := RbLayer.new()
	l.id = doc.new_id()
	l.name = name
	l.kind = kind
	l.size = Vector2(10, 10)
	l.make_quad_mesh()
	l.parent_id = parent
	doc.layers[l.id] = l
	if parent == 0:
		doc.root.append(l.id)
	else:
		doc.get_layer(parent).children.append(l.id)
	return l


func test_switch_group() -> void:
	var doc := RbDocument.new()
	var sw := _layer(doc, "mouth", 0, RbLayer.Kind.SWITCH)
	var a := _layer(doc, "rest", sw.id)
	var b := _layer(doc, "O", sw.id)
	var ev := RbEvaluator.new()
	var p := ev.evaluate(doc, 0)
	t.check(p.layers[a.id].visible and not p.layers[b.id].visible, "виден только первый вариант")
	var tk := RbAnimation.track_key("layer", sw.id, &"switch_index")
	doc.anim.set_key(tk, 0, 0, "smooth")
	doc.anim.set_key(tk, 10, 1, "smooth")
	doc.anim.apply_frame(doc, 9.5)
	t.eq(sw.switch_index, 0, "свитч ступенькой даже с плавной интерполяцией")
	doc.anim.apply_frame(doc, 10)
	p = ev.evaluate(doc, 10)
	t.check(not p.layers[a.id].visible and p.layers[b.id].visible, "на кадре 10 второй вариант")
	# ключевая форма ползунка выбирает вариант поверх ключей
	var prm := RbParams.Param.new()
	prm.id = doc.new_id()
	prm.forms[1.0] = {"bones": {}, "verts": {}, "opacity": {}, "switch": {sw.id: 0}}
	prm.value = 1.0
	doc.params.params[prm.id] = prm
	p = ev.evaluate(doc, 10)
	t.check(p.layers[a.id].visible and not p.layers[b.id].visible, "форма ползунка переключает свитч")
	var back := RbLayer.from_dict(sw.to_dict())
	t.eq(back.switch_index, 1, "индекс свитча сохраняется")


func test_z_order() -> void:
	var doc := RbDocument.new()
	var body := _layer(doc, "body")
	var hand := _layer(doc, "hand")
	var head := _layer(doc, "head")
	var ev := RbEvaluator.new()
	t.eq(ev.evaluate(doc, 0).order, [body.id, hand.id, head.id] as Array[int], "порядок дерева")
	hand.z = -1
	t.eq(ev.evaluate(doc, 0).order, [hand.id, body.id, head.id] as Array[int], "рука за телом")
	hand.z = 1
	t.eq(ev.evaluate(doc, 0).order, [body.id, head.id, hand.id] as Array[int], "рука поверх всего")
	var tk := RbAnimation.track_key("layer", hand.id, &"z")
	doc.anim.set_key(tk, 0, -1)
	doc.anim.set_key(tk, 6, 1)
	doc.anim.apply_frame(doc, 3)
	t.eq(hand.z, -1, "порядок меняется ступенькой")
	t.eq(RbLayer.from_dict(hand.to_dict()).z, -1, "z сохраняется")


func test_ik_constraint() -> void:
	var rig := RbRig.new()
	var hip := RbBone.new()
	hip.id = 1
	hip.position = Vector2(0, 0)
	hip.angle = PI / 2.0  # вниз
	hip.length = 50
	rig.bones[1] = hip
	var shin := RbBone.new()
	shin.id = 2
	shin.parent_id = 1
	shin.position = Vector2(50, 0)
	shin.angle = 0.2  # чуть согнута: задаёт сторону сгиба
	shin.length = 50
	rig.bones[2] = shin
	var target := RbBone.new()
	target.id = 3
	target.position = Vector2(30, 70)
	target.length = 10
	rig.bones[3] = target
	shin.constraints = {"ik": {"target": 3}}
	var w := rig.world_transforms(true)
	var tip := (w[2] as Transform2D) * Vector2(50, 0)
	t.near(tip.distance_to(Vector2(30, 70)), 0.0, "конец голени в цели", 0.05)
	t.near((w[2] as Transform2D).origin.distance_to((w[1] as Transform2D).origin), 50.0, "длина бедра сохранена", 0.05)
	target.pose_offset = Vector2(10, -5)  # двигаем цель позой: нога следует
	w = rig.world_transforms(true)
	tip = (w[2] as Transform2D) * Vector2(50, 0)
	t.near(tip.distance_to(Vector2(40, 65)), 0.0, "за сдвинутой целью", 0.05)
	target.pose_offset = Vector2(500, 500)
	w = rig.world_transforms(true)
	var dir := ((w[2] as Transform2D) * Vector2(50, 0) - Vector2.ZERO).normalized()
	t.near(dir.dot(Vector2(530, 570).normalized()), 1.0, "не дотянуться: нога вытянута к цели", 0.01)
