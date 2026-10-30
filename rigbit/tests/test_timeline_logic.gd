extends RefCounted

var t  # раннер


func _doc() -> RbDocument:
	var doc := RbDocument.new()
	for n in 2:
		var b := RbBone.new()
		b.id = doc.new_id()
		b.name = "Кость%d" % b.id
		b.length = 100
		doc.rig.bones[b.id] = b
	var l := RbLayer.new()
	l.id = doc.new_id()
	l.name = "Слой"
	doc.layers[l.id] = l
	doc.root.append(l.id)
	return doc


func test_frame_x_roundtrip() -> void:
	for f in [0, 5, 47]:
		var x := RbTimelineLogic.frame_x(f, 3.0, 12.0)
		t.eq(RbTimelineLogic.x_frame(x, 3.0, 12.0, 48), f, "кадр %d обратно из координаты" % f)
	t.eq(RbTimelineLogic.x_frame(-500.0, 0.0, 10.0, 48), 0, "слева прижимается к 0")
	t.eq(RbTimelineLogic.x_frame(9999.0, 0.0, 10.0, 48), 47, "справа прижимается к последнему")


func test_scroll_and_zoom() -> void:
	t.near(RbTimelineLogic.max_scroll(10.0, 200.0, 48), 28.0, "запас прокрутки")
	t.near(RbTimelineLogic.max_scroll(10.0, 600.0, 48), 0.0, "всё помещается")
	t.near(RbTimelineLogic.clamp_scroll(99.0, 10.0, 200.0, 48), 28.0, "не дальше конца")
	t.near(RbTimelineLogic.fit_ppf(100.0, 48), RbTimelineLogic.MIN_PPF, "не мельче 6 px")
	t.near(RbTimelineLogic.fit_ppf(10000.0, 4), RbTimelineLogic.MAX_PPF, "не крупнее 60 px")
	# кадр под пальцем остаётся на месте
	var before := 100.0 / 8.0 + 4.0
	var r := RbTimelineLogic.zoom_at(4.0, 8.0, 16.0, 100.0, 250.0, 96)
	var after: float = 100.0 / float(r[1]) + float(r[0])
	t.near(after, before, "якорь зума")
	var lim := RbTimelineLogic.zoom_at(0.0, 10.0, 500.0, 50.0, 250.0, 96)
	t.near(lim[1], RbTimelineLogic.MAX_PPF, "потолок зума")


func test_label_step_and_show() -> void:
	t.eq(RbTimelineLogic.label_step(40.0), 1, "крупно: каждый кадр")
	t.eq(RbTimelineLogic.label_step(6.0), 6, "мелко: каждые 6")
	t.check(RbTimelineLogic.label_step(7.0) * 7.0 >= 32.0, "подписи не слипаются")
	var s := RbTimelineLogic.scroll_to_show(40, 0.0, 10.0, 200.0, 48)
	t.check(s > 20.0 and s <= 28.0, "прокрутка к кадру справа")
	t.near(RbTimelineLogic.scroll_to_show(2, 20.0, 10.0, 200.0, 48), 2.0, "прокрутка к кадру слева")


func test_build_rows() -> void:
	var doc := _doc()
	var ids := doc.rig.bones.keys()
	var a := RbAnimation.track_key("bone", ids[0], &"pose_angle")
	var b := RbAnimation.track_key("bone", ids[1], &"pose_offset")
	var c := RbAnimation.track_key("layer", doc.root[0], &"opacity")
	doc.anim.set_key(a, 0, 0.0)
	doc.anim.set_key(b, 0, Vector2.ZERO)
	doc.anim.set_key(c, 0, 1.0)
	var only := RbTimelineLogic.build_rows(doc, "bone", ids[0], true)
	t.eq(only.size(), 2, "заголовок и одна дорожка")
	t.eq(only[0]["t"], "head", "первая строка заголовок")
	t.eq(only[1]["label"], "TL_ROT", "ключ локализации поворота")
	var all := RbTimelineLogic.build_rows(doc, "bone", ids[0], false)
	t.eq(all.size(), 6, "три объекта: 3 заголовка и 3 дорожки")
	t.eq(all[0]["kind"], "bone", "кости раньше слоёв")
	t.eq(all[4]["kind"], "layer", "слой в конце")
	var empty := RbTimelineLogic.build_rows(doc, "bone", ids[1], true)
	t.eq(empty.size(), 2, "у кости с ключом: заголовок и дорожка")
	doc.anim.tracks.clear()
	var none := RbTimelineLogic.build_rows(doc, "layer", doc.root[0], true)
	t.eq(none[1]["t"], "empty", "объект без ключей: строка-подсказка")
	t.eq(RbTimelineLogic.build_rows(doc, "", 0, true).size(), 0, "без объекта и без дорожек пусто")
	var tops := RbTimelineLogic.row_tops(none)
	t.near(tops[2], RbTimelineLogic.HEAD_H + RbTimelineLogic.ROW_H, "высота строк")
	t.eq(RbTimelineLogic.row_at(tops, 5.0), 0, "строка под y")
	t.eq(RbTimelineLogic.row_at(tops, RbTimelineLogic.HEAD_H + 1.0), 1, "вторая строка")
	t.eq(RbTimelineLogic.row_at(tops, 9999.0), -1, "ниже строк")


func test_param_and_pin_rows() -> void:
	var doc := _doc()
	var lid: int = doc.root[0]
	var prm := RbParams.Param.new()
	prm.id = doc.new_id()
	prm.name = "Моргание"
	doc.params.params[prm.id] = prm
	var pa := doc.new_id()
	var pb := doc.new_id()
	doc.rig.pins[lid] = [{"id": pa, "v": 0, "bone": 0, "offset": Vector2.ZERO}, {"id": pb, "v": 1, "bone": 0, "offset": Vector2.ZERO}]
	var bid: int = doc.rig.bones.keys()[0]
	doc.anim.set_key(RbAnimation.track_key("pin", pb, &"offset"), 3, Vector2(4, 0))
	doc.anim.set_key(RbAnimation.track_key("param", prm.id, &"value"), 0, 0.5)
	doc.anim.set_key(RbAnimation.track_key("layer", lid, &"opacity"), 0, 1.0)
	doc.anim.set_key(RbAnimation.track_key("bone", bid, &"pose_angle"), 0, 0.0)
	var all := RbTimelineLogic.build_rows(doc, "", 0, false)
	t.eq(all.size(), 8, "четыре объекта: заголовок и дорожка у каждого")
	t.eq([all[0]["kind"], all[2]["kind"], all[4]["kind"], all[6]["kind"]], ["bone", "layer", "param", "pin"], "кости, слои, ползунки, пины")
	t.eq(all[4]["name"], "Моргание", "имя ползунка")
	t.eq(all[5]["label"], "TL_VALUE", "дорожка значения")
	t.eq(all[6]["name"], "Слой", "у пина имя его слоя")
	t.eq(int(all[6]["n"]), 2, "второй пин на слое")
	t.eq(all[7]["label"], "TL_OFFSET", "дорожка сдвига пина")
	var only := RbTimelineLogic.build_rows(doc, "pin", pb, true)
	t.eq(only.size(), 2, "фильтр по пину")
	t.eq(RbTimelineLogic.pin_info(doc, 12345), [0, 0], "чужой пин")
	# удалённый пин и ползунок не дают строк
	doc.rig.pins.erase(lid)
	doc.params.params.erase(prm.id)
	t.eq(RbTimelineLogic.build_rows(doc, "", 0, false).size(), 4, "только кость и слой")


func _anim_doc() -> Array:
	var doc := _doc()
	var bid: int = doc.rig.bones.keys()[0]
	var tk := RbAnimation.track_key("bone", bid, &"pose_angle")
	for f in [0, 6, 12]:
		doc.anim.set_key(tk, f, float(f) * 0.1)
	var tk2 := RbAnimation.track_key("bone", bid, &"pose_scale")
	doc.anim.set_key(tk2, 6, Vector2.ONE, "step")
	return [doc, bid, tk, tk2]


func test_key_hit_and_rect() -> void:
	var r := _anim_doc()
	var doc: RbDocument = r[0]
	var rows := RbTimelineLogic.build_rows(doc, "bone", r[1], true)
	var tops := RbTimelineLogic.row_tops(rows)
	var ppf := 10.0
	var y_row1 := RbTimelineLogic.HEAD_H + 10.0  # первая дорожка (поворот)
	var x6 := RbTimelineLogic.frame_x(6.0, 0.0, ppf)
	t.eq(RbTimelineLogic.key_at(rows, tops, doc.anim, Vector2(x6 + 3.0, y_row1), 0.0, ppf), [r[2], 6], "ключ рядом")
	t.eq(RbTimelineLogic.key_at(rows, tops, doc.anim, Vector2(x6 + 40.0, y_row1), 0.0, ppf), [], "мимо ключей")
	t.eq(RbTimelineLogic.key_at(rows, tops, doc.anim, Vector2(x6, 5.0), 0.0, ppf), [], "заголовок не ключ")
	# рамка по двум дорожкам захватывает ключи кадров 6 и 12
	var rect := Rect2(x6 - 3.0, 0.0, 70.0, 200.0)
	var refs := RbTimelineLogic.refs_in_rect(rows, tops, doc.anim, rect, 0.0, ppf)
	t.eq(refs.size(), 3, "6 и 12 на повороте, 6 на масштабе")
	var thin := Rect2(x6, y_row1, 1.0, 1.0)
	t.eq(RbTimelineLogic.refs_in_rect(rows, tops, doc.anim, thin, 0.0, ppf), [[r[2], 6]], "точка выделяет один ключ")
	var flipped := Rect2(x6 + 70.0, 200.0, -70.0, -200.0)
	t.eq(RbTimelineLogic.refs_in_rect(rows, tops, doc.anim, flipped, 0.0, ppf).size(), 3, "рамка тянется в любую сторону")
	t.eq(RbTimelineLogic.refs_of_row(rows, 1, doc.anim).size(), 3, "все ключи строки")
	t.eq(RbTimelineLogic.refs_of_row(rows, 0, doc.anim).size(), 0, "у заголовка нет ключей")


func test_move_clamp_and_shift() -> void:
	var refs := [["a", 3], ["a", 10]]
	t.eq(RbTimelineLogic.move_delta_clamped(refs, -9, 48), -3, "не левее нуля")
	t.eq(RbTimelineLogic.move_delta_clamped(refs, 99, 48), 37, "не правее последнего кадра")
	t.eq(RbTimelineLogic.move_delta_clamped(refs, 4, 48), 4, "свободный сдвиг")
	t.eq(RbTimelineLogic.move_delta_clamped([], 4, 48), 0, "пустой набор")
	t.eq(RbTimelineLogic.shifted(refs, 2), [["a", 5], ["a", 12]], "новые кадры")


func test_copy_paste() -> void:
	var r := _anim_doc()
	var doc: RbDocument = r[0]
	var clip := RbTimelineLogic.copy_keys(doc.anim, [[r[2], 6], [r[2], 12], [r[3], 6]])
	t.eq(clip.size(), 3, "скопировано три")
	t.eq(clip[0]["df"], 0, "самый ранний на нуле")
	t.eq(clip[1]["df"], 6, "смещение от самого раннего")
	var pasted := RbTimelineLogic.paste_entries(clip, 20, "", 0, 48)
	t.eq(pasted[0][1], 20, "вставка на плейхед")
	t.eq(pasted[1][1], 26, "смещение сохранилось")
	t.eq(pasted[0][0], r[2], "дорожка прежняя")
	t.eq(pasted[2][3], "step", "интерполяция скопировалась")
	var cut := RbTimelineLogic.paste_entries(clip, 44, "", 0, 48)
	t.eq(cut.size(), 2, "ключи за концом отброшены")
	# на другую кость того же вида
	var other: int = doc.rig.bones.keys()[1]
	var moved := RbTimelineLogic.paste_entries(clip, 0, "bone", other, 48)
	t.eq(moved[0][0], RbAnimation.track_key("bone", other, &"pose_angle"), "дорожка переехала на другую кость")
	var stay := RbTimelineLogic.paste_entries(clip, 0, "layer", doc.root[0], 48)
	t.eq(stay[0][0], r[2], "чужой вид объекта: дорожки остаются")
	t.eq(RbTimelineLogic.common_interp(doc.anim, [[r[2], 0], [r[2], 6]]), "smooth", "общая интерполяция")
	t.eq(RbTimelineLogic.common_interp(doc.anim, [[r[2], 0], [r[3], 6]]), "", "разные интерполяции")


func test_set_key_auto_adds_rest_key() -> void:
	var r := _doc()
	var bid: int = r.rig.bones.keys()[0]
	var b := r.rig.get_bone(bid)
	var undo := RbUndoStack.new(r)
	var tk := RbAnimation.track_key("bone", bid, &"pose_angle")
	r.current_frame = 12
	b.pose_angle = 0.25
	undo.push(RbAnimCommands.SetKeyAuto.new(tk, 12, 0.25, 0.0))
	t.eq(r.anim.keys_of(tk).size(), 2, "ключ на кадре 12 и стартовый на 0")
	t.near(float(r.anim.keys_of(tk)[0]["v"]), 0.0, "стартовое значение")
	undo.undo()
	t.eq(r.anim.keys_of(tk).size(), 0, "один шаг undo убрал оба")
	t.near(b.pose_angle, 0.0, "кость вернулась к исходному")
	undo.redo()
	t.eq(r.anim.keys_of(tk).size(), 2, "redo вернул оба")
	# следующая правка той же дорожки стартовый ключ уже не добавляет
	r.current_frame = 5
	undo.push(RbAnimCommands.SetKeyAuto.new(tk, 5, 0.1, 0.0))
	t.eq(r.anim.keys_of(tk).size(), 3, "третий ключ без дубля нулевого")
	# на нулевом кадре стартовый ключ не нужен
	var tk2 := RbAnimation.track_key("bone", bid, &"pose_offset")
	r.current_frame = 0
	undo.push(RbAnimCommands.SetKeyAuto.new(tk2, 0, Vector2(3, 4), Vector2.ZERO))
	t.eq(r.anim.keys_of(tk2).size(), 1, "на кадре 0 один ключ")


func test_set_key_auto_gesture_and_interp() -> void:
	var r := _doc()
	var bid: int = r.rig.bones.keys()[0]
	var undo := RbUndoStack.new(r)
	var tk := RbAnimation.track_key("bone", bid, &"pose_angle")
	r.current_frame = 8
	for i in 5:
		undo.push(RbAnimCommands.SetKeyAuto.new(tk, 8, 0.1 * i, 0.0), false, true)
	undo.end_gesture()
	t.eq(undo.size(), 1, "жест = один шаг")
	t.eq(r.anim.keys_of(tk).size(), 2, "ключ жеста и стартовый")
	t.near(float(r.anim.keys_of(tk)[1]["v"]), 0.4, "последнее значение жеста")
	undo.push(RbAnimCommands.SetInterp.new([[tk, 8]], "step"))
	undo.end_gesture()
	r.current_frame = 8
	undo.push(RbAnimCommands.SetKeyAuto.new(tk, 8, 0.9, 0.0))
	t.eq(r.anim.keys_of(tk)[1]["i"], "step", "правка ключа не сбрасывает ступеньку")


func test_paste_keys_and_timing_undo() -> void:
	var r := _anim_doc()
	var doc: RbDocument = r[0]
	var undo := RbUndoStack.new(doc)
	var tk: String = r[2]
	undo.push(RbAnimCommands.PasteKeys.new([[tk, 6, 9.0, "linear"], [tk, 30, 1.0, "smooth"]]))
	t.eq(doc.anim.keys_of(tk).size(), 4, "один заменён, один новый")
	t.near(float(doc.anim.keys_of(tk)[1]["v"]), 9.0, "значение заменено")
	undo.undo()
	t.eq(doc.anim.keys_of(tk).size(), 3, "новый убран")
	t.near(float(doc.anim.keys_of(tk)[1]["v"]), 0.6, "старое значение вернулось")
	doc.current_frame = 40
	undo.push(RbAnimCommands.SetTiming.new(24, 12))
	t.eq(doc.frame_count, 24, "кадров")
	t.eq(doc.fps, 12, "частота")
	t.eq(doc.current_frame, 23, "текущий кадр прижат")
	undo.undo()
	t.eq(doc.frame_count, 48, "кадров вернулось")
	t.eq(doc.fps, 24, "частота вернулась")


# ---------------- жесты сетки (события подаются напрямую) ----------------

func _touch(g: RbTimelineGrid, pressed: bool, pos: Vector2, idx := 0) -> void:
	var e := InputEventScreenTouch.new()
	e.index = idx
	e.pressed = pressed
	e.position = pos
	g._gui_input(e)


func _drag(g: RbTimelineGrid, pos: Vector2, idx := 0) -> void:
	var e := InputEventScreenDrag.new()
	e.index = idx
	e.position = pos
	g._gui_input(e)


func _grid() -> Array:
	var r := _anim_doc()
	var g := RbTimelineGrid.new()
	t.root.add_child(g)
	g.size = Vector2(344, 220)
	g.doc = r[0]
	g.focus_kind = "bone"
	g.focus_id = r[1]
	g.rebuild()
	g._apply_fit()
	return [g, r]


func test_grid_tap_and_scrub() -> void:
	var gr := _grid()
	var g: RbTimelineGrid = gr[0]
	var frames: Array = []
	g.frame_requested.connect(func(f: int) -> void: frames.append(f))
	t.near(g.ppf, 6.0, "масштаб по умолчанию")
	# тап по пустому месту дорожки = кадр 20
	_touch(g, true, Vector2(100.0 + 20.5 * 6.0, 80.0))
	_touch(g, false, Vector2(100.0 + 20.5 * 6.0, 80.0))
	t.eq(frames.back(), 20, "тап ставит плейхед")
	# тянуть по пустому месту: плейхед идёт за пальцем
	frames.clear()
	_touch(g, true, Vector2(100.0 + 30.5 * 6.0, 80.0))
	_drag(g, Vector2(100.0 + 36.5 * 6.0, 82.0))
	_drag(g, Vector2(100.0 + 40.5 * 6.0, 82.0))
	_touch(g, false, Vector2(100.0 + 40.5 * 6.0, 82.0))
	t.eq(frames.back(), 40, "скраб до кадра 40")
	# тап по ключу: выделение и кадр ключа
	frames.clear()
	var kx := 100.0 + 6.5 * 6.0
	_touch(g, true, Vector2(kx, 80.0))
	_touch(g, false, Vector2(kx, 80.0))
	t.eq(frames.back(), 6, "тап по ключу встаёт на его кадр")
	t.eq(g.selected_refs().size(), 1, "ключ выделен")
	g.queue_free()


func test_grid_move_keys_and_rect() -> void:
	var gr := _grid()
	var g: RbTimelineGrid = gr[0]
	var tk: String = gr[1][2]
	var moved: Array = []
	g.keys_move_requested.connect(func(refs: Array, d: int) -> void: moved.append([refs, d]))
	var kx := 100.0 + 6.5 * 6.0
	_touch(g, true, Vector2(kx, 80.0))
	_drag(g, Vector2(kx + 19.0, 80.0))
	t.eq(g.move_delta, 3, "превью сдвига на 3 кадра")
	_touch(g, false, Vector2(kx + 19.0, 80.0))
	t.eq(moved.size(), 1, "один сдвиг при отпускании")
	t.eq(moved[0][1], 3, "дельта")
	t.eq(moved[0][0], [[tk, 6]], "сдвигается выделенный ключ")
	t.eq(g.selected_refs(), [[tk, 9]], "выделение поехало вместе с ключом")
	# долгое нажатие: рамка по трём ключам
	g.clear_selection()
	var haptics: Array = []
	g.haptic.connect(func(ms: int) -> void: haptics.append(ms))
	_touch(g, true, Vector2(223.0, 80.0))
	g._on_long()
	t.eq(haptics.size(), 1, "вибро на долгом нажатии")
	_drag(g, Vector2(130.0, 112.0))
	_touch(g, false, Vector2(130.0, 112.0))
	t.eq(g.selected_refs().size(), 3, "рамка выделила три ключа")
	# второй палец отменяет жест, ничего не двигается
	moved.clear()
	_touch(g, true, Vector2(100.0 + 12.5 * 6.0, 80.0))
	_drag(g, Vector2(100.0 + 14.5 * 6.0, 80.0))
	_touch(g, true, Vector2(300.0, 150.0), 1)
	_touch(g, false, Vector2(300.0, 150.0), 1)
	_touch(g, false, Vector2(100.0 + 14.5 * 6.0, 80.0))
	t.eq(moved.size(), 0, "щипок отменил сдвиг ключей")
	g.queue_free()


func test_grid_ruler_pan() -> void:
	var gr := _grid()
	var g: RbTimelineGrid = gr[0]
	g.ppf = 20.0
	g._user_zoomed = true
	var frames: Array = []
	g.frame_requested.connect(func(f: int) -> void: frames.append(f))
	_touch(g, true, Vector2(200.0, 10.0))
	_drag(g, Vector2(120.0, 10.0))
	_touch(g, false, Vector2(120.0, 10.0))
	t.check(g.scroll > 2.0, "тянуть линейку при зуме двигает вид")
	t.eq(frames.size(), 0, "плейхед при этом не двигался")
	g.queue_free()


func test_edge_speed() -> void:
	var v := func(x: float) -> float: return RbTimelineLogic.edge_speed(x, 100.0, 500.0, 40.0, 30.0)
	t.near(v.call(300.0), 0.0, "середина стоит")
	t.near(v.call(140.0), 0.0, "граница полосы слева ещё стоит")
	t.near(v.call(120.0), -15.0, "полпути в полосе: полскорости к началу")
	t.near(v.call(480.0), 15.0, "полпути в полосе справа: вперёд")
	t.near(v.call(20.0), -30.0, "за краем не быстрее потолка")
	t.near(v.call(900.0), 30.0, "за правым краем потолок")
	t.near(RbTimelineLogic.edge_speed(110.0, 100.0, 200.0, 40.0, 30.0), 0.0, "узкая область не крутится")
