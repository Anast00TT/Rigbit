extends RefCounted

var t  # раннер


func test_ghost_frames() -> void:
	var g := RbOnion.ghost_frames(5, 24, 2)
	t.eq(g.size(), 4, "по два кадра в каждую сторону")
	t.eq(g[g.size() - 1][1] * g[g.size() - 1][1], 1, "ближние в конце списка (поверх)")
	var frames := g.map(func(e: Array) -> int: return e[0])
	frames.sort()
	t.eq(frames, [3, 4, 6, 7], "кадры вокруг текущего")
	t.eq(RbOnion.ghost_frames(0, 24, 2).size(), 2, "у начала только будущие")
	var wrap := RbOnion.ghost_frames(0, 24, 1, true).map(func(e: Array) -> int: return e[0])
	wrap.sort()
	t.eq(wrap, [1, 23], "в цикле прошлое берётся с конца")
	t.eq(RbOnion.ghost_frames(0, 2, 3, true).size(), 1, "короткий цикл без повторов и без текущего")
	t.eq(RbOnion.ghost_frames(3, 24, 0).size(), 0, "выключено")
	t.eq(RbOnion.ghost_frames(10, 48, 9).size(), RbOnion.MAX_N * 2, "не больше потолка")


func test_tint() -> void:
	t.check(RbOnion.tint(-1, 2).r > RbOnion.tint(-1, 2).b, "прошлое красное")
	t.check(RbOnion.tint(1, 2).b > RbOnion.tint(1, 2).r, "будущее голубое")
	t.near(RbOnion.tint(1, 2).a, RbOnion.ALPHA, "ближний самый плотный")
	t.check(RbOnion.tint(2, 2).a < RbOnion.tint(1, 2).a, "дальний прозрачнее")


func test_pose_at_leaves_doc_untouched() -> void:
	var doc := RbDocument.new()
	var b := RbBone.new()
	b.id = doc.new_id()
	doc.rig.bones[b.id] = b
	var tk := RbAnimation.track_key("bone", b.id, &"pose_angle")
	doc.anim.set_key(tk, 0, 0.0, "linear")
	doc.anim.set_key(tk, 10, 1.0, "linear")
	doc.current_frame = 2
	doc.anim.apply_frame(doc, 2)
	b.pose_angle = 0.77  # правка ещё не в ключах
	var ev := RbEvaluator.new()
	var p := ev.pose_at(doc, 10)
	var rot := (p.bones[b.id] as Transform2D).get_rotation()
	t.near(rot, 1.0, "кадр 10 вычислен по ключам")
	t.near(b.pose_angle, 0.77, "значение в кости вернулось")
	t.eq(doc.current_frame, 2, "текущий кадр не сдвинулся")
