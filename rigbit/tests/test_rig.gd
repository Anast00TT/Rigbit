extends RefCounted

var t  # раннер


## Рука: плечо (0,0)->(100,0), предплечье (100,0)->(200,0).
func _arm(doc: RbDocument) -> Array:
	var a := RbBone.new()
	a.id = doc.new_id()
	a.name = "плечо"
	a.length = 100
	doc.rig.bones[a.id] = a
	var b := RbBone.new()
	b.id = doc.new_id()
	b.name = "предплечье"
	b.parent_id = a.id
	b.position = Vector2(100, 0)
	b.length = 100
	doc.rig.bones[b.id] = b
	return [a, b]


func _strip_layer(doc: RbDocument) -> RbLayer:
	var l := RbLayer.new()
	l.id = doc.new_id()
	l.size = Vector2(200, 20)
	l.position = Vector2(100, 0)
	l.make_quad_mesh()
	# добавить точки вдоль полосы, чтобы было что гнуть
	l.mesh_vertices = PackedVector2Array([Vector2(-100, -10), Vector2(0, -10), Vector2(100, -10), Vector2(100, 10), Vector2(0, 10), Vector2(-100, 10)])
	l.mesh_uvs = PackedVector2Array([Vector2(0, 0), Vector2(0.5, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0.5, 1), Vector2(0, 1)])
	l.mesh_indices = PackedInt32Array([0, 1, 4, 0, 4, 5, 1, 2, 3, 1, 3, 4])
	doc.insert_layer(l)
	return l


func test_world_transforms() -> void:
	var doc := RbDocument.new()
	var arm := _arm(doc)
	(arm[0] as RbBone).angle = PI / 2
	var w := doc.rig.world_transforms(false)
	var tip: Vector2 = (w[arm[1].id] as Transform2D) * Vector2(100, 0)
	t.check(tip.distance_to(Vector2(0, 200)) < 0.01, "кончик предплечья после поворота плеча: %s" % tip)


func test_order_parents_first() -> void:
	var doc := RbDocument.new()
	var arm := _arm(doc)
	var o := doc.rig.order()
	t.check(o.find(arm[0].id) < o.find(arm[1].id), "родитель раньше ребёнка")


func test_rigid_and_skin() -> void:
	var doc := RbDocument.new()
	var arm := _arm(doc)
	var l := _strip_layer(doc)
	doc.rig.weights[l.id] = RbRig.rigid_weights(l.mesh_vertices.size(), arm[1].id)
	var ev := RbEvaluator.new()
	var rest := ev.evaluate(doc, 0)
	t.eq(rest.layers[l.id].vertices, l.mesh_vertices, "в покое вершины не меняются")
	(arm[1] as RbBone).pose_angle = PI / 2
	var posed := ev.evaluate(doc, 0)
	var lp: RbEvaluator.LayerPose = posed.layers[l.id]
	# вершина (100,-10) local -> world (200,-10); вокруг (100,0) на 90° -> (110, 100)
	var wv := lp.world * lp.vertices[2]
	t.check(wv.distance_to(Vector2(110, 100)) < 0.01, "жёсткая привязка поворачивает вершину: %s" % wv)


func test_auto_weights() -> void:
	var doc := RbDocument.new()
	var arm := _arm(doc)
	var verts := PackedVector2Array([Vector2(10, 5), Vector2(190, 5), Vector2(100, 5)])
	var wd := doc.rig.auto_weights(verts)
	var w0 := RbRig.bone_weight_per_vertex(wd, arm[0].id, 3)
	var w1 := RbRig.bone_weight_per_vertex(wd, arm[1].id, 3)
	t.check(w0[0] > 0.9, "у плеча вершина плеча: %f" % w0[0])
	t.check(w1[1] > 0.9, "у кисти вершина кисти: %f" % w1[1])
	t.check(absf(w0[2] - w1[2]) < 0.2, "локоть делится поровну: %f / %f" % [w0[2], w1[2]])
	for i in 3:
		t.near(w0[i] + w1[i], 1.0, "нормализация")


func test_paint() -> void:
	var doc := RbDocument.new()
	var arm := _arm(doc)
	var verts := PackedVector2Array([Vector2(10, 0), Vector2(150, 0)])
	var wd := RbRig.rigid_weights(2, arm[0].id)
	var p := RbRig.paint(wd, verts, Vector2(150, 0), 30, arm[1].id, 0.5)
	var w1 := RbRig.bone_weight_per_vertex(p, arm[1].id, 2)
	var w0 := RbRig.bone_weight_per_vertex(p, arm[0].id, 2)
	t.near(w1[1], 0.5, "кисть добавила 50%")
	t.near(w0[1] + w1[1], 1.0, "сумма 1")
	t.near(w1[0], 0.0, "вне радиуса не тронуто")


func test_remove_bone_keeps_child() -> void:
	var doc := RbDocument.new()
	var arm := _arm(doc)
	(arm[0] as RbBone).angle = 0.3
	var before: Transform2D = doc.rig.world_transforms(false)[arm[1].id]
	var undo := RbUndoStack.new(doc)
	undo.push(RbRigCommands.RemoveBone.new(arm[0].id))
	t.check(doc.rig.get_bone(arm[0].id) == null, "кость удалена")
	var after: Transform2D = doc.rig.world_transforms(false)[arm[1].id]
	t.check(after.origin.distance_to(before.origin) < 0.01 and absf(after.get_rotation() - before.get_rotation()) < 0.001, "ребёнок остался на месте")
	undo.undo()
	t.eq(doc.rig.get_bone(arm[1].id).parent_id, arm[0].id, "undo вернул родителя")


func test_reparent_no_cycles() -> void:
	var doc := RbDocument.new()
	var arm := _arm(doc)
	var undo := RbUndoStack.new(doc)
	undo.push(RbRigCommands.ReparentBone.new(arm[0].id, arm[1].id))
	t.eq(doc.rig.get_bone(arm[0].id).parent_id, 0, "нельзя сделать предка ребёнком потомка")


func test_mesh_change_remaps_weights() -> void:
	var doc := RbDocument.new()
	var arm := _arm(doc)
	var l := _strip_layer(doc)
	doc.rig.weights[l.id] = doc.rig.auto_weights(l.mesh_vertices)
	var undo := RbUndoStack.new(doc)
	var old := RbCommands.SetMesh.snap(l)
	var img := Image.create_empty(200, 20, false, Image.FORMAT_RGBA8)
	img.fill(Color.WHITE)
	var m := RbMeshGen.generate(img, 0.6)
	var ns := {"v": m["vertices"], "uv": m["uvs"], "i": m["indices"], "d": 0.6}
	undo.push(RbCommands.SetMesh.new(l.id, old, ns))
	var wd: Dictionary = doc.rig.weights[l.id]
	var n := l.mesh_vertices.size()
	t.eq((wd["w"] as PackedFloat32Array).size(), n * 4, "веса на каждую новую вершину")
	var w0 := RbRig.bone_weight_per_vertex(wd, arm[0].id, n)
	var w1 := RbRig.bone_weight_per_vertex(wd, arm[1].id, n)
	var ok := true
	for i in n:
		if absf(w0[i] + w1[i] - 1.0) > 0.01:
			ok = false
	t.check(ok, "сумма весов 1 у всех новых вершин")
	undo.undo()
	t.eq((doc.rig.weights[l.id]["w"] as PackedFloat32Array).size(), 6 * 4, "undo вернул старые веса")


func _tip_after(doc: RbDocument, arm: Array, angles: Dictionary) -> Vector2:
	for id in angles:
		doc.rig.get_bone(id).pose_angle = angles[id]
	var w := doc.rig.world_transforms(true)
	return (w[arm[1].id] as Transform2D) * Vector2(100, 0)


func test_ik_two_bone_reaches() -> void:
	var doc := RbDocument.new()
	var arm := _arm(doc)
	(arm[1] as RbBone).pose_angle = 0.3  # чуть согнуть, чтобы была сторона сгиба
	var chain: Array[int] = [arm[0].id, arm[1].id]
	var target := Vector2(120, 80)
	var res := RbIK.solve(doc.rig, chain, doc.rig.world_transforms(true), target)
	var tip := _tip_after(doc, arm, res)
	t.check(tip.distance_to(target) < 0.5, "кончик дотянулся: %s" % tip)
	t.check((arm[1] as RbBone).pose_angle > 0.0, "сторона сгиба сохранена")


func test_ik_out_of_reach_straightens() -> void:
	var doc := RbDocument.new()
	var arm := _arm(doc)
	var chain: Array[int] = [arm[0].id, arm[1].id]
	var res := RbIK.solve(doc.rig, chain, doc.rig.world_transforms(true), Vector2(0, 500))
	var tip := _tip_after(doc, arm, res)
	t.check(tip.distance_to(Vector2(0, 200)) < 1.0, "цепь вытянута к цели: %s" % tip)


func test_ik_fabrik_three() -> void:
	var doc := RbDocument.new()
	var arm := _arm(doc)
	var c := RbBone.new()
	c.id = doc.new_id()
	c.parent_id = arm[1].id
	c.position = Vector2(100, 0)
	c.length = 100
	doc.rig.bones[c.id] = c
	var chain := RbIK.chain_for(doc.rig, c.id, 3)
	t.eq(chain.size(), 3, "цепочка из трёх")
	var target := Vector2(150, 120)
	var res := RbIK.solve(doc.rig, chain, doc.rig.world_transforms(true), target)
	for id in res:
		doc.rig.get_bone(id).pose_angle = res[id]
	var w := doc.rig.world_transforms(true)
	var tip: Vector2 = (w[c.id] as Transform2D) * Vector2(100, 0)
	t.check(tip.distance_to(target) < 1.0, "FABRIK дотянулся: %s" % tip)


func test_rig_save_load() -> void:
	var doc := RbDocument.new()
	var arm := _arm(doc)
	var l := _strip_layer(doc)
	doc.rig.weights[l.id] = doc.rig.auto_weights(l.mesh_vertices)
	var path := "user://test_rig.rigbit"
	t.eq(RbProjectIO.save(doc, path), OK, "сохранение")
	var back := RbProjectIO.load_doc(path)
	t.eq(back.rig.bones.size(), 2, "кости")
	t.eq(back.rig.get_bone(arm[1].id).parent_id, arm[0].id, "иерархия")
	t.check(back.rig.weights.has(l.id), "веса")
	t.check(back.new_id() > arm[1].id, "id не повторяются")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
