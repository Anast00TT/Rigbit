class_name RbTimelineGrid
extends Control
## Сетка таймлайна: линейка, строки дорожек, ключи, плейхед, жесты.
## Слева колонка имён, справа область кадров. Жесты (по одному пальцу):
##   тап/тянуть по пустому месту и по линейке: плейхед на кадр (на линейке при зуме тянуть = двигать вид);
##   тап по ключу: выделить и встать на его кадр; тянуть ключ: сдвиг выделенных (один MoveKeys при отпускании);
##   долгое нажатие: вибро и рамка выделения; тянуть по колонке имён: прокрутка строк.
##   Скраб, сдвиг ключей и рамка у края области кадров сами прокручивают вид.
## Два пальца: щипок = зум кадров, сдвиг центра = прокрутка.

signal frame_requested(f: int)
signal keys_move_requested(refs: Array, delta: int)
signal selection_changed
signal object_picked(kind: String, id: int)
signal filter_toggled
signal haptic(ms: int)

const RULER_H := 24.0
const SUM_H := 44.0  # свёрнутый вид: одна сводная строка
const SLOP := 10.0
const LONG_S := 0.45
const FS := 12
const PAD := 8.0  # зазор между колонкой имён и нулевым кадром
const EDGE := 36.0  # полоса автопрокрутки у краёв области кадров
const EDGE_FPS := 30.0  # потолок скорости автопрокрутки, кадров/с

var doc: RbDocument
var rows: Array = []
var tops := PackedFloat32Array([0.0])
var label_w := 92.0
var collapsed := false
var mode_color := Color("#E5484D")
var focus_kind := ""
var focus_id := 0
var only_focus := true
var scroll := 0.0  # первый видимый кадр (дробный)
var ppf := 10.0  # px на кадр
var vscroll := 0.0
var sel := {}  # "track@frame" -> [track, frame]
var move_delta := 0

var _user_zoomed := false
var _last_count := -1
var _last_frame := -1
var _touches := {}
var _g := ""
var _down := Vector2.ZERO
var _moved := 0.0
var _key_ref: Array = []
var _rect_a := Vector2.ZERO
var _rect_b := Vector2.ZERO
var _pair_prev: Array = []
var _last := Vector2.ZERO  # где сейчас палец одиночного жеста
var _timer: Timer
var _chip_on: StyleBoxFlat
var _chip_off: StyleBoxFlat


func _init() -> void:
	set_process(false)
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE
	_timer = Timer.new()
	_timer.one_shot = true
	_timer.wait_time = LONG_S
	_timer.timeout.connect(_on_long)
	add_child(_timer)
	resized.connect(_apply_fit)
	restyle()


## Стили плашек зависят от темы и цвета режима.
func restyle() -> void:
	_chip_on = RbTheme.sb(Color(mode_color, 0.2), 6, 0, 0, Color(mode_color, 0.7), 1)
	_chip_off = RbTheme.sb(RbTheme.C.p3, 6)
	queue_redraw()


# ---------------- состояние ----------------

func rebuild() -> void:
	if doc == null:
		return
	rows = RbTimelineLogic.build_rows(doc, focus_kind, focus_id, only_focus)
	tops = RbTimelineLogic.row_tops(rows)
	_prune_selection()
	if doc.frame_count != _last_count:
		_last_count = doc.frame_count
		_apply_fit()
	vscroll = clampf(vscroll, 0.0, _max_v())
	scroll = RbTimelineLogic.clamp_scroll(scroll, ppf, _track_w(), doc.frame_count)
	if doc.current_frame != _last_frame:
		_last_frame = doc.current_frame
		if _g == "":
			scroll = RbTimelineLogic.scroll_to_show(doc.current_frame, scroll, ppf, _track_w(), doc.frame_count)
	queue_redraw()


func _prune_selection() -> void:
	var visible := {}
	for r in rows:
		if r["t"] == "track":
			visible[r["track"]] = true
	var changed := false
	for k in sel.keys():
		var ref: Array = sel[k]
		if not visible.has(ref[0]) or doc.anim.key_index(ref[0], int(ref[1])) < 0:
			sel.erase(k)
			changed = true
	if changed:
		selection_changed.emit()


func _apply_fit() -> void:
	if doc == null:
		return
	if not _user_zoomed:
		ppf = RbTimelineLogic.fit_ppf(_track_w(), doc.frame_count)
		scroll = 0.0
	else:
		scroll = RbTimelineLogic.clamp_scroll(scroll, ppf, _track_w(), doc.frame_count)
	queue_redraw()


func selected_refs() -> Array:
	var out: Array = []
	for k in sel:
		out.append(sel[k])
	return out


func select_refs(refs: Array) -> void:
	sel.clear()
	for r in refs:
		sel[RbTimelineLogic.ref_key(r[0], int(r[1]))] = [r[0], int(r[1])]
	selection_changed.emit()
	queue_redraw()


func clear_selection() -> void:
	if not sel.is_empty():
		sel.clear()
		selection_changed.emit()
	queue_redraw()


# ---------------- геометрия ----------------

func _track_w() -> float:
	return maxf(size.x - label_w - PAD, 1.0)


func _body_top() -> float:
	return 0.0 if collapsed else RULER_H


func _body_h() -> float:
	return maxf(size.y - _body_top(), 0.0)


func _max_v() -> float:
	return maxf(0.0, tops[tops.size() - 1] - _body_h())


func _fx(f: float) -> float:
	return label_w + PAD + RbTimelineLogic.frame_x(f, scroll, ppf)


func _row_y(i: int) -> float:
	return _body_top() + tops[i] - vscroll


func _row_at(y: float) -> int:
	return RbTimelineLogic.row_at(tops, y - _body_top() + vscroll)


func _key_at(p: Vector2) -> Array:
	if p.x < label_w:
		return []
	var cp := Vector2(p.x - label_w - PAD, p.y - _body_top() + vscroll)
	return RbTimelineLogic.key_at(rows, tops, doc.anim, cp, scroll, ppf)


func _scrub_to(x: float) -> void:
	var f := RbTimelineLogic.x_frame(x - label_w - PAD, scroll, ppf, doc.frame_count)
	frame_requested.emit(f)
	queue_redraw()


# ---------------- рисование ----------------

func _text_y(font: Font, fs: int, cy: float) -> float:
	return cy + (font.get_ascent(fs) - font.get_descent(fs)) * 0.5


func _fit_text(font: Font, text: String, max_w: float, fs: int) -> String:
	if font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x <= max_w:
		return text
	var s := text
	while s.length() > 1 and font.get_string_size(s + "…", HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x > max_w:
		s = s.left(s.length() - 1)
	return s + "…"


func _head_name(row: Dictionary) -> String:
	var n: String = row["name"]
	match row["kind"]:
		"pin":
			return tr("TL_PIN_OF") % [int(row.get("n", 0)), n]
		"param":
			return n if n != "" else tr("PARAM_N") % int(row["id"])
		"bone":
			return n if n != "" else tr("BONE_N") % int(row["id"])
	return n


const HEAD_ICONS := {"bone": "bone", "layer": "layers", "param": "sliders", "pin": "pin"}


func _chip_rect(font: Font, y: float, rh: float) -> Rect2:
	var text := tr("TL_FILTER_ON" if only_focus else "TL_FILTER_OFF")
	var tw := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, FS).x
	var cw := minf(tw + 16.0 + (22.0 if only_focus else 0.0), size.x * 0.62)
	return Rect2(size.x - 8.0 - cw, y + (rh - 28.0) * 0.5, cw, 28.0)


func _draw() -> void:
	if doc == null:
		return
	var C: Dictionary = RbTheme.C
	var font := get_theme_default_font()
	var w := size.x
	var h := size.y
	var tx := label_w
	var top := _body_top()
	var f0 := maxi(0, floori(scroll) - 1)
	var f1 := mini(doc.frame_count - 1, ceili(scroll + _track_w() / ppf) + 1)
	draw_rect(Rect2(0, 0, w, h), C.p1)
	draw_rect(Rect2(tx, top, w - tx, h - top), C.seg)
	var line_strong := Color(C.tx, 0.14)
	var line_weak := Color(C.tx, 0.05)
	# линии кадров: каждый кадр слабо, каждый шестой сильнее
	for f in range(f0, f1 + 1):
		var x := _fx(f)
		if x >= tx and x <= w:
			draw_line(Vector2(x, top), Vector2(x, h), line_strong if f % 6 == 0 else line_weak, 1.0)
	if collapsed:
		_draw_summary(font)
	else:
		_draw_rows(font)
		_draw_ruler(font, f0, f1)
	_draw_playhead(font)
	if _g == "rect":
		var r := Rect2(_rect_a, _rect_b - _rect_a).abs()
		draw_rect(r, Color(mode_color, 0.16))
		draw_rect(r, Color(mode_color, 0.9), false, 1.5)
	if not collapsed and _max_v() > 0.5:
		var bh := _body_h()
		var kh := maxf(bh * bh / tops[tops.size() - 1], 16.0)
		var ky := top + (bh - kh) * (vscroll / _max_v())
		draw_rect(Rect2(w - 4.0, ky, 3.0, kh), Color(C.tx, 0.28))


func _draw_summary(font: Font) -> void:
	var C: Dictionary = RbTheme.C
	var h := size.y
	draw_rect(Rect2(0, 0, label_w, h), C.p1)
	draw_line(Vector2(label_w - 0.5, 0), Vector2(label_w - 0.5, h), C.ln, 1.0)
	var label := _fit_text(font, tr("TL_ALL_KEYS"), label_w - 20.0, FS)
	draw_string(font, Vector2(10, _text_y(font, FS, h * 0.5)), label, HORIZONTAL_ALIGNMENT_LEFT, -1, FS, C.tx2)
	for f in doc.anim.key_frames(""):
		var x := _fx(f)
		if x >= label_w and x <= size.x:
			_draw_key(Vector2(x, h * 0.5), "smooth", false)


func _draw_rows(font: Font) -> void:
	var C: Dictionary = RbTheme.C
	var w := size.x
	var h := size.y
	var tx := label_w
	var top := _body_top()
	var first_head := true
	# дорожки: фон строк и ключи
	for i in rows.size():
		var y := _row_y(i)
		var rh := tops[i + 1] - tops[i]
		if y + rh < top or y > h:
			continue
		var row: Dictionary = rows[i]
		if row["t"] == "track":
			if i % 2 == 1:
				draw_rect(Rect2(tx, y, w - tx, rh), Color(C.tx, 0.03))
			var tk: String = row["track"]
			var cy := y + rh * 0.5
			for k in doc.anim.keys_of(tk):
				var f := int(k["f"])
				var is_sel := sel.has(RbTimelineLogic.ref_key(tk, f))
				var fr := f + (move_delta if is_sel and _g == "keymove" else 0)
				var x := _fx(fr)
				if x < tx - RbTimelineLogic.KEY_HALF or x > w + RbTimelineLogic.KEY_HALF:
					continue
				_draw_key(Vector2(x, cy), str(k["i"]), is_sel)
	# колонка имён поверх ключей, ушедших под неё при прокрутке
	draw_rect(Rect2(0, top, tx, h - top), C.p1)
	draw_line(Vector2(tx - 0.5, top), Vector2(tx - 0.5, h), C.ln, 1.0)
	for i in rows.size():
		var y := _row_y(i)
		var rh := tops[i + 1] - tops[i]
		if y + rh < top or y > h:
			continue
		var row: Dictionary = rows[i]
		match row["t"]:
			"track":
				var label := _fit_text(font, tr(row["label"]), tx - 18.0, FS)
				draw_string(font, Vector2(10, _text_y(font, FS, y + rh * 0.5)), label, HORIZONTAL_ALIGNMENT_LEFT, -1, FS, C.tx2)
				draw_line(Vector2(0, y + rh - 0.5), Vector2(w, y + rh - 0.5), C.ln, 1.0)
			"empty":
				var hint := _fit_text(font, tr("TL_EMPTY_OBJ"), w - tx - 20.0, FS)
				draw_string(font, Vector2(tx + 10, _text_y(font, FS, y + rh * 0.5)), hint, HORIZONTAL_ALIGNMENT_LEFT, -1, FS, C.tx3)
				draw_line(Vector2(0, y + rh - 0.5), Vector2(w, y + rh - 0.5), C.ln, 1.0)
			"head":
				draw_rect(Rect2(0, y, w, rh), C.p2)
				draw_line(Vector2(0, y + rh - 0.5), Vector2(w, y + rh - 0.5), C.ln, 1.0)
				draw_texture_rect(RbIcons.tex(HEAD_ICONS.get(row["kind"], "layers"), 18), Rect2(10, y + (rh - 18.0) * 0.5, 18, 18), false, C.tx2)
				var name_right := w - 8.0
				var show_chip := first_head and focus_kind != ""
				var chip := Rect2()
				if show_chip:
					chip = _chip_rect(font, y, rh)
					name_right = chip.position.x - 8.0
				first_head = false
				var nm := _fit_text(font, _head_name(row), name_right - 36.0, FS + 2)
				draw_string(font, Vector2(36, _text_y(font, FS + 2, y + rh * 0.5)), nm, HORIZONTAL_ALIGNMENT_LEFT, -1, FS + 2, C.tx)
				if show_chip:
					draw_style_box(_chip_on if only_focus else _chip_off, chip)
					var text := tr("TL_FILTER_ON" if only_focus else "TL_FILTER_OFF")
					draw_string(font, Vector2(chip.position.x + 8.0, _text_y(font, FS, chip.get_center().y)), text, HORIZONTAL_ALIGNMENT_LEFT, -1, FS, C.tx)
					if only_focus:
						draw_texture_rect(RbIcons.tex("x", 14), Rect2(chip.end.x - 22.0, chip.get_center().y - 7.0, 14, 14), false, C.tx2)
	if rows.is_empty():
		var msg := tr("TL_EMPTY_ALL")
		draw_multiline_string(font, Vector2(tx + 12, top + 28), msg, HORIZONTAL_ALIGNMENT_CENTER, w - tx - 24.0, FS + 1, 3, C.tx3)


func _draw_ruler(font: Font, f0: int, f1: int) -> void:
	var C: Dictionary = RbTheme.C
	var w := size.x
	var tx := label_w
	draw_rect(Rect2(0, 0, w, RULER_H), C.p2)
	draw_line(Vector2(0, RULER_H - 0.5), Vector2(w, RULER_H - 0.5), C.ln, 1.0)
	draw_string(font, Vector2(10, _text_y(font, 11, RULER_H * 0.5)), "%d fps" % doc.fps, HORIZONTAL_ALIGNMENT_LEFT, tx - 14.0, 11, C.tx3)
	var step := RbTimelineLogic.label_step(ppf)
	for f in range(f0, f1 + 1):
		var x := _fx(f)
		if x < tx or x > w:
			continue
		var strong := f % 6 == 0
		draw_line(Vector2(x, RULER_H - (7.0 if strong else 4.0)), Vector2(x, RULER_H), Color(C.tx3, 0.9 if strong else 0.5), 1.0)
		if f % step == 0:
			var t := str(f)
			var tw := font.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
			if x - tw * 0.5 >= tx + 2.0 and x + tw * 0.5 <= w - 2.0:
				draw_string(font, Vector2(x - tw * 0.5, _text_y(font, 11, 9.0)), t, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, C.tx3)


func _draw_playhead(font: Font) -> void:
	var x := _fx(doc.current_frame)
	if x < label_w or x > size.x:
		return
	draw_line(Vector2(x, 0), Vector2(x, size.y), mode_color, 2.0)
	if collapsed:
		return
	var t := str(doc.current_frame)
	var tw := font.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
	var bw := maxf(tw + 12.0, 26.0)
	var bx := clampf(x - bw * 0.5, label_w, size.x - bw)
	draw_style_box(RbTheme.sb(mode_color, 5), Rect2(bx, 2, bw, RULER_H - 5.0))
	draw_string(font, Vector2(bx + (bw - tw) * 0.5, _text_y(font, 11, 2.0 + (RULER_H - 5.0) * 0.5)), t, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color.WHITE)


## Круг = плавный ключ, квадрат = ступенька. Выделенный красный с белым кольцом.
func _draw_key(c: Vector2, interp: String, selected: bool) -> void:
	var r := RbTimelineLogic.KEY_HALF
	var red: Color = RbTheme.MODE_COLORS[1]
	if interp == "step":
		var q := r - 1.0
		if selected:
			draw_rect(Rect2(c - Vector2(q + 2.0, q + 2.0), Vector2((q + 2.0) * 2.0, (q + 2.0) * 2.0)), Color.WHITE)
		draw_rect(Rect2(c - Vector2(q, q), Vector2(q * 2.0, q * 2.0)), red if selected else RbTheme.MODE_COLORS[2])
	else:
		if selected:
			draw_circle(c, r + 2.0, Color.WHITE)
		draw_circle(c, r, red if selected else RbTheme.C.tx2.lerp(RbTheme.C.tx, 0.45))


# ---------------- ввод ----------------

func _gui_input(e: InputEvent) -> void:
	if doc == null:
		return
	if e is InputEventScreenTouch:
		_on_touch(e)
		accept_event()
	elif e is InputEventScreenDrag:
		_on_drag(e)
		accept_event()
	elif e is InputEventMouseButton:
		_on_wheel(e)
	elif e is InputEventMagnifyGesture:
		_zoom_x(e.position.x, e.factor)
	elif e is InputEventPanGesture:
		_pan(Vector2(-e.delta.x, -e.delta.y) * 20.0)


func _on_touch(e: InputEventScreenTouch) -> void:
	if e.pressed:
		_touches[e.index] = e.position
		if _touches.size() == 1:
			_begin(e.position)
		else:
			_cancel_single()
			_g = "pinch"
			_pair_prev = _pair()
	else:
		var was := _touches.size()
		_touches.erase(e.index)
		_timer.stop()
		if was == 1:
			_end(e.position)
			_g = ""
		else:
			_g = "dead"  # остался один палец после щипка: ничего не делает
			if _touches.is_empty():
				_g = ""
		queue_redraw()


func _begin(pos: Vector2) -> void:
	_down = pos
	_moved = 0.0
	_g = ""
	move_delta = 0
	_key_ref = []
	if collapsed:
		_g = "track_wait" if pos.x >= label_w else "dead"
		return
	if pos.y < RULER_H:
		_g = "ruler_wait" if pos.x >= label_w else "dead"
		return
	var row := _row_at(pos.y)
	if row >= 0 and rows[row]["t"] == "head":
		_g = "head_wait"
	elif pos.x < label_w:
		_g = "label_wait"
	else:
		_key_ref = _key_at(pos)
		_g = "key_wait" if not _key_ref.is_empty() else "track_wait"
		_timer.start()


func _cancel_single() -> void:
	_timer.stop()
	move_delta = 0
	queue_redraw()


func _on_long() -> void:
	if _touches.size() == 1 and (_g == "track_wait" or _g == "key_wait") and _moved < SLOP:
		_g = "rect"
		_rect_a = _down
		_rect_b = _down
		haptic.emit(30)
		queue_redraw()


func _on_drag(e: InputEventScreenDrag) -> void:
	var prev: Vector2 = _touches.get(e.index, e.position)
	_touches[e.index] = e.position
	if _touches.size() >= 2:
		var cur := _pair()
		if _pair_prev.size() == 2 and cur.size() == 2:
			_pinch(_pair_prev, cur)
		_pair_prev = cur
		return
	_moved += prev.distance_to(e.position)
	var p := e.position
	_last = p
	if _g.ends_with("_wait") and p.distance_to(_down) > SLOP:
		_timer.stop()
		_start_drag(p)
	_drag_to(p, prev)
	set_process(_g in ["scrub", "keymove", "rect"])


func _drag_to(p: Vector2, prev: Vector2) -> void:
	match _g:
		"scrub":
			_scrub_to(p.x)
		"pan":
			scroll = RbTimelineLogic.clamp_scroll(scroll - (p.x - prev.x) / ppf, ppf, _track_w(), doc.frame_count)
		"vscroll":
			vscroll = clampf(vscroll - (p.y - prev.y), 0.0, _max_v())
		"keymove":
			move_delta = RbTimelineLogic.move_delta_clamped(selected_refs(), roundi((p.x - _down.x) / ppf), doc.frame_count)
		"rect":
			_rect_b = p
	queue_redraw()


## Автопрокрутка: пока палец стоит у края, вид едет, а точка начала жеста едет вместе с содержимым,
## чтобы сдвиг ключей и рамка считались от того же кадра.
func _process(delta: float) -> void:
	if not (_g in ["scrub", "keymove", "rect"]) or _touches.size() != 1:
		set_process(false)
		return
	var v := RbTimelineLogic.edge_speed(_last.x, label_w + PAD, size.x, EDGE, EDGE_FPS)
	if v == 0.0:
		return
	var ns := RbTimelineLogic.clamp_scroll(scroll + v * delta, ppf, _track_w(), doc.frame_count)
	var ds := ns - scroll
	if absf(ds) < 0.0001:
		return
	scroll = ns
	_down.x -= ds * ppf
	_rect_a.x -= ds * ppf
	_drag_to(_last, _last)


func _start_drag(p: Vector2) -> void:
	match _g:
		"track_wait":
			var d := p - _down
			if not collapsed and absf(d.y) > absf(d.x) * 2.0 and _max_v() > 0.5:
				_g = "vscroll"
			else:
				_g = "scrub"
		"key_wait":
			if not sel.has(RbTimelineLogic.ref_key(_key_ref[0], _key_ref[1])):
				select_refs([_key_ref])
			_g = "keymove"
		"ruler_wait":
			_g = "pan" if RbTimelineLogic.max_scroll(ppf, _track_w(), doc.frame_count) > 0.01 else "scrub"
		_:
			_g = "vscroll"


func _end(pos: Vector2) -> void:
	match _g:
		"track_wait", "ruler_wait":
			_scrub_to(pos.x)
		"key_wait":
			select_refs([_key_ref])
			frame_requested.emit(int(_key_ref[1]))
		"keymove":
			var refs := selected_refs()
			var d := move_delta
			move_delta = 0
			if d != 0:
				keys_move_requested.emit(refs, d)
				select_refs(RbTimelineLogic.shifted(refs, d))
		"rect":
			var r := Rect2(_rect_a, _rect_b - _rect_a).abs()
			var cr := Rect2(r.position.x - label_w - PAD, r.position.y - _body_top() + vscroll, r.size.x, r.size.y)
			select_refs(RbTimelineLogic.refs_in_rect(rows, tops, doc.anim, cr, scroll, ppf))
		"head_wait":
			_head_tap(pos)
		"label_wait":
			var i := _row_at(pos.y)
			if i >= 0 and rows[i]["t"] == "track":
				select_refs(RbTimelineLogic.refs_of_row(rows, i, doc.anim))


func _head_tap(pos: Vector2) -> void:
	var i := _row_at(pos.y)
	if i < 0:
		return
	var font := get_theme_default_font()
	var y := _row_y(i)
	var rh := tops[i + 1] - tops[i]
	var first := true
	for j in i:
		if rows[j]["t"] == "head":
			first = false
	if first and focus_kind != "" and pos.x >= _chip_rect(font, y, rh).position.x - 8.0:
		filter_toggled.emit()
	else:
		object_picked.emit(rows[i]["kind"], int(rows[i]["id"]))


func _pair() -> Array:
	var keys := _touches.keys()
	keys.sort()
	if keys.size() < 2:
		return []
	return [_touches[keys[0]], _touches[keys[1]]]


func _pinch(prev: Array, cur: Array) -> void:
	var d0: Vector2 = prev[1] - prev[0]
	var d1: Vector2 = cur[1] - cur[0]
	var c0: Vector2 = (prev[0] + prev[1]) * 0.5
	var c1: Vector2 = (cur[0] + cur[1]) * 0.5
	if d0.length() > 8.0:
		_zoom_x(c0.x, d1.length() / d0.length())
	_pan(c1 - c0)


func _zoom_x(screen_x: float, k: float) -> void:
	var r := RbTimelineLogic.zoom_at(scroll, ppf, ppf * k, screen_x - label_w - PAD, _track_w(), doc.frame_count)
	scroll = r[0]
	ppf = r[1]
	_user_zoomed = true
	queue_redraw()


## Сдвинуть вид на d пальцем: контент идёт за пальцем.
func _pan(d: Vector2) -> void:
	scroll = RbTimelineLogic.clamp_scroll(scroll - d.x / ppf, ppf, _track_w(), doc.frame_count)
	vscroll = clampf(vscroll - d.y, 0.0, _max_v())
	queue_redraw()


func _on_wheel(e: InputEventMouseButton) -> void:
	if not e.pressed:
		return
	var up := e.button_index == MOUSE_BUTTON_WHEEL_UP
	if e.button_index != MOUSE_BUTTON_WHEEL_UP and e.button_index != MOUSE_BUTTON_WHEEL_DOWN:
		return
	if e.ctrl_pressed:
		_zoom_x(e.position.x, 1.15 if up else 1.0 / 1.15)
	elif e.shift_pressed:
		_pan(Vector2(40.0 if up else -40.0, 0.0))
	else:
		_pan(Vector2(0.0, 36.0 if up else -36.0))
	accept_event()
