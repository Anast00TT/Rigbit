class_name RbViewportView
extends Control
## Вьюпорт: камера (пан/зум/поворот двумя пальцами), разбор жестов, рамка цвета режима.
## Инструменты получают события уже в координатах холста (сигналы drag_*).

signal tap(world: Vector2)
signal double_tap(world: Vector2)
signal drag_begin(world: Vector2)
signal drag_move(world: Vector2)
signal drag_end
signal drag_cancel
signal two_finger_tap
signal three_finger_tap
signal snapped  # камера прилипла к 0/90° или 100%, для тактильного щелчка
signal long_press(world: Vector2)  # палец не двигался LONG_PRESS_S, включается long_press_enabled

const SNAP_ANGLE := deg_to_rad(6.0)
const LONG_PRESS_S := 0.45
const SNAP_ZOOM := 0.06

const TAP_TIME_MS := 280
const TAP_SLOP := 10.0
const DOUBLE_TAP_MS := 320
const MIN_ZOOM := 0.02
const MAX_ZOOM := 32.0

var world := Node2D.new()
var renderer := RbRenderer.new()
var overlay := Control.new()
var view := Transform2D.IDENTITY
var mode_color := Color.ORANGE
var canvas_size := Vector2(1080, 1920)
var show_ghost := false
var hand_mode := false  # один палец двигает холст
var selection := PackedVector2Array()  # контур выделенного, в координатах холста
## Сетка слоя в правке (координаты холста): пары концов рёбер, толстый контур, точки.
var mesh_lines := PackedVector2Array()
var mesh_outline := PackedVector2Array()
var mesh_points := PackedVector2Array()  # внутренние вершины
var mesh_edge_points := PackedVector2Array()  # граничные вершины
var mesh_focus := Vector2.INF  # вершина под пальцем (подсвечивается), INF = нет
var mesh_dim := false  # сетка фоном (инструмент «Пины»): тоньше и прозрачнее, чтобы ручки пинов читались
var long_press_enabled := false  # долгое нажатие вместо тапа/перетаскивания
var double_tap_enabled := true  # выключают, когда быстрые тапы нужны инструменту

var _auto_fit := true
var _touches := {}
var _pair_prev: Array = []
var _single := false
var _dragging := false
var _hand_drag := false
var _start_pos := Vector2.ZERO
var _start_ms := 0
var _max_touches := 0
var _moved := 0.0
var _last_tap_ms := -10000
var _last_tap_pos := Vector2.ZERO
var _mouse_pan := false
var _raw_view := Transform2D.IDENTITY  # камера без магнита, пока идёт щипок
var _snap_state := ""
var _long_timer: Timer
var _consumed := false  # касание уже обработано долгим нажатием, отпускание ничего не шлёт
var show_gizmo := false  # ручки трансформа слоя
var bones_draw: Array = []  # [{a: начало, b: кончик (холст), sel, dim}]
var heat_points := PackedVector2Array()  # вершины для тепловой карты весов (холст)
var heat_values := PackedFloat32Array()
var last_pressure := 0.0
var brush := Vector3.ZERO  # круг кисти: x, y на экране, z = радиус (0 = нет)
var pins_draw: Array = []  # [{p: положение (холст), bound: привязан к кости, sel: выделен}]
var light_arrow := {}  # стрелка света эффектов {c: центр слоя (холст), a: мировой угол}, пусто = нет
var alert_color := Color(0, 0, 0, 0)  # непрозрачный цвет: рамка правки ключевой формы вместо цвета режима

const PIN_R := 11.0
const PIN_COLOR := Color("#E5489B")
const ARROW_LEN := 64.0
const SUN_R := 9.0
const MESH_R := 4.0  # радиус точки сетки, dp
const HANDLE_R := 7.0
const ROT_HANDLE_OFFSET := 30.0


func _ready() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(world)
	world.add_child(renderer)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(overlay)
	overlay.draw.connect(_draw_overlay)
	resized.connect(_on_resized)
	_long_timer = Timer.new()
	_long_timer.one_shot = true
	_long_timer.wait_time = LONG_PRESS_S
	_long_timer.timeout.connect(_on_long_timer)
	add_child(_long_timer)


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), RbTheme.C.vp)


func set_mode_color(c: Color) -> void:
	mode_color = c
	overlay.queue_redraw()


func to_world(p: Vector2) -> Vector2:
	return view.affine_inverse() * p


func fit_canvas() -> void:
	var m := 24.0
	var k := minf((size.x - m * 2) / canvas_size.x, (size.y - m * 2) / canvas_size.y)
	k = maxf(k, MIN_ZOOM)
	view = Transform2D(0.0, Vector2(k, k), 0.0, (size - canvas_size * k) * 0.5)
	_auto_fit = true
	_apply()


## Пунктирная рамка пустого холста (пропорции холста, вписана с отступом).
func ghost_rect() -> Rect2:
	var m := 32.0
	var k := minf((size.x - m * 2) / canvas_size.x, (size.y - m * 2) / canvas_size.y)
	var s := canvas_size * maxf(k, 0.0)
	return Rect2((size - s) * 0.5, s)


func _on_resized() -> void:
	if _auto_fit:
		fit_canvas()
	overlay.queue_redraw()


func _apply() -> void:
	world.transform = view
	renderer.queue_redraw()
	overlay.queue_redraw()


func refresh_overlay() -> void:
	overlay.queue_redraw()


# ---------------- жесты ----------------

func _gui_input(e: InputEvent) -> void:
	if e is InputEventScreenTouch:
		_on_touch(e)
		accept_event()
	elif e is InputEventScreenDrag:
		_on_drag(e)
		accept_event()
	elif e is InputEventMouseButton:
		_on_mouse_button(e)
	elif e is InputEventMouseMotion and _mouse_pan:
		_pan(e.relative)
	elif e is InputEventMagnifyGesture:
		_zoom_at(e.position, e.factor)
	elif e is InputEventPanGesture:
		_pan(-e.delta * 20.0)


func _on_touch(e: InputEventScreenTouch) -> void:
	var now := Time.get_ticks_msec()
	if e.pressed:
		_touches[e.index] = e.position
		if _touches.size() == 1:
			_start_ms = now
			_start_pos = e.position
			_max_touches = 1
			_moved = 0.0
			_single = true
			_dragging = false
			_hand_drag = false
			_consumed = false
			if long_press_enabled:
				_long_timer.start()
		else:
			_long_timer.stop()
			_max_touches = maxi(_max_touches, _touches.size())
			if _single and _dragging and not _hand_drag:
				drag_cancel.emit()  # второй палец = это был жест камеры, а не инструмент
			_single = false
			_dragging = false
			_pair_prev = _pair()
			_raw_view = view
	else:
		_touches.erase(e.index)
		_long_timer.stop()
		if _touches.is_empty():
			var quick := now - _start_ms < TAP_TIME_MS and _moved < TAP_SLOP
			if _consumed:
				pass  # долгое нажатие уже сработало: ни тапа, ни конца перетаскивания
			elif quick and _max_touches == 2:
				two_finger_tap.emit()
			elif quick and _max_touches == 3:
				three_finger_tap.emit()
			elif _single and not _dragging and _max_touches == 1:
				_single_tap(e.position, now)
			elif _single and _dragging and not _hand_drag:
				drag_end.emit()
			_single = false
			_dragging = false
			_consumed = false
		else:
			_pair_prev = _pair()


func _on_long_timer() -> void:
	if _touches.size() == 1 and _single and not _dragging and _max_touches == 1 and _moved < TAP_SLOP:
		_consumed = true
		long_press.emit(to_world(_start_pos))


func _on_drag(e: InputEventScreenDrag) -> void:
	var prev: Vector2 = _touches.get(e.index, e.position)
	_touches[e.index] = e.position
	_moved += prev.distance_to(e.position)
	last_pressure = e.pressure  # стилус (S Pen); у пальца обычно 0 или 1
	if _touches.size() == 1 and _single:
		if _consumed:
			return
		if not _dragging and e.position.distance_to(_start_pos) > TAP_SLOP:
			_long_timer.stop()
			_dragging = true
			_hand_drag = hand_mode
			if not _hand_drag:
				drag_begin.emit(to_world(_start_pos))
		if _dragging:
			if _hand_drag:
				_pan(e.position - prev)
			else:
				drag_move.emit(to_world(e.position))
	elif _touches.size() >= 2:
		var cur := _pair()
		if _pair_prev.size() == 2 and cur.size() == 2:
			_pinch(_pair_prev[0], _pair_prev[1], cur[0], cur[1])
		_pair_prev = cur


func _pair() -> Array:
	var keys := _touches.keys()
	keys.sort()
	if keys.size() < 2:
		return []
	return [_touches[keys[0]], _touches[keys[1]]]


func _pinch(a0: Vector2, b0: Vector2, a1: Vector2, b1: Vector2) -> void:
	var d0 := b0 - a0
	var d1 := b1 - a1
	if d0.length() < 1.0:
		return
	var k := d1.length() / d0.length()
	var cur_zoom := view.get_scale().x
	k = clampf(cur_zoom * k, MIN_ZOOM, MAX_ZOOM) / cur_zoom
	var ang := d1.angle() - d0.angle()
	var c0 := (a0 + b0) * 0.5
	var c1 := (a1 + b1) * 0.5
	_raw_view = Transform2D(ang, Vector2(k, k), 0.0, c1) * Transform2D(0.0, Vector2.ONE, 0.0, -c0) * _raw_view
	view = _magnet(_raw_view, c1)
	_auto_fit = false
	_apply()


## Магнит: поворот к 0/90/180/270°, масштаб к 100%. Сырое значение копится отдельно,
## поэтому из магнита легко выйти, продолжая жест.
func _magnet(raw: Transform2D, pivot: Vector2) -> Transform2D:
	var v := raw
	var state := ""
	var a := v.get_rotation()
	var nearest := roundf(a / (PI * 0.5)) * PI * 0.5
	if absf(a - nearest) < SNAP_ANGLE:
		if absf(a - nearest) > 0.00001:
			v = Transform2D(nearest - a, Vector2.ONE, 0.0, pivot) * Transform2D(0.0, Vector2.ONE, 0.0, -pivot) * v
		state += "r%d" % int(roundf(nearest / (PI * 0.5)))
	var z := v.get_scale().x
	if absf(z - 1.0) < SNAP_ZOOM:
		v = Transform2D(0.0, Vector2.ONE / z, 0.0, pivot) * Transform2D(0.0, Vector2.ONE, 0.0, -pivot) * v
		state += "z"
	if state != "" and state != _snap_state:
		snapped.emit()
	_snap_state = state
	return v


func _single_tap(pos: Vector2, now: int) -> void:
	if double_tap_enabled and now - _last_tap_ms < DOUBLE_TAP_MS and pos.distance_to(_last_tap_pos) < 40.0:
		_last_tap_ms = -10000
		double_tap.emit(to_world(pos))
	else:
		_last_tap_ms = now
		_last_tap_pos = pos
		tap.emit(to_world(pos))


func _on_mouse_button(e: InputEventMouseButton) -> void:
	match e.button_index:
		MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN:
			if e.pressed:
				var f := 1.12 if e.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 1.12
				if e.ctrl_pressed:
					_rotate_at(e.position, deg_to_rad(5.0 if f > 1.0 else -5.0))
				else:
					_zoom_at(e.position, f)
				accept_event()
		MOUSE_BUTTON_MIDDLE, MOUSE_BUTTON_RIGHT:
			_mouse_pan = e.pressed
			accept_event()


func _pan(d: Vector2) -> void:
	view = Transform2D(0.0, Vector2.ONE, 0.0, d) * view
	_auto_fit = false
	_apply()


func _zoom_at(p: Vector2, f: float) -> void:
	var z := view.get_scale().x
	f = clampf(z * f, MIN_ZOOM, MAX_ZOOM) / z
	view = Transform2D(0.0, Vector2(f, f), 0.0, p) * Transform2D(0.0, Vector2.ONE, 0.0, -p) * view
	_auto_fit = false
	_apply()


func _rotate_at(p: Vector2, a: float) -> void:
	view = Transform2D(a, Vector2.ONE, 0.0, p) * Transform2D(0.0, Vector2.ONE, 0.0, -p) * view
	_auto_fit = false
	_apply()


# ---------------- оверлей ----------------

## Углы выделения на экране (0..3: лево-верх, право-верх, право-низ, лево-низ).
func selection_screen() -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in selection:
		out.append(view * p)
	return out


## Ручка поворота: над серединой верхней стороны, наружу от центра.
func rotate_handle() -> Vector2:
	var s := selection_screen()
	if s.size() != 4:
		return Vector2.INF
	var top := (s[0] + s[1]) * 0.5
	var c := (s[0] + s[2]) * 0.5
	var d := (top - c).normalized() if top.distance_to(c) > 0.5 else Vector2.UP
	return top + d * ROT_HANDLE_OFFSET


func _handle(p: Vector2, round_one: bool) -> void:
	overlay.draw_circle(p, HANDLE_R + 1.5, mode_color)
	overlay.draw_circle(p, HANDLE_R - 0.5, Color.WHITE if not round_one else RbTheme.C.vp)
	if round_one:
		overlay.draw_arc(p, HANDLE_R - 3.0, -PI * 0.9, PI * 0.4, 12, mode_color, 1.5, true)


## Сетка в правке: тонкие рёбра, толстый контур, внутренние точки (белые с кольцом цвета режима),
## граничные точки (цвет режима с белым кольцом, чуть крупнее). Рёбра рисуются над подложкой, чтобы читались на любой картинке.
func _draw_mesh() -> void:
	if mesh_lines.is_empty() and mesh_points.is_empty() and mesh_edge_points.is_empty():
		return
	var fade := 0.4 if mesh_dim else 1.0
	if mesh_lines.size() >= 2:
		var seg := PackedVector2Array()
		for p in mesh_lines:
			seg.append(view * p)
		overlay.draw_multiline(seg, Color(0, 0, 0, 0.35 * fade), 2.5, true)
		overlay.draw_multiline(seg, Color(mode_color, 0.85 * fade), 1.0, true)
	if mesh_outline.size() >= 2:
		var seg := PackedVector2Array()
		for p in mesh_outline:
			seg.append(view * p)
		overlay.draw_multiline(seg, Color(0, 0, 0, 0.35 * fade), 3.5, true)
		overlay.draw_multiline(seg, Color(mode_color, fade), 2.0, true)
	# точки мельчают вместе со средней длиной ребра на экране, чтобы на плотной сетке не слипались
	var r := MESH_R
	if mesh_lines.size() >= 2:
		var total := 0.0
		var n := 0
		for i in range(0, mesh_lines.size() - 1, 2 * maxi(1, int(mesh_lines.size() / 400.0))):
			total += view.basis_xform(mesh_lines[i + 1] - mesh_lines[i]).length()
			n += 1
		r = clampf(total / maxf(n, 1) * 0.15, 1.4, MESH_R)
	for p in mesh_points:
		var s := view * p
		overlay.draw_circle(s, r + 1.2, Color(mode_color, fade))
		overlay.draw_circle(s, r - 0.2, Color(1, 1, 1, fade))
	for p in mesh_edge_points:
		var s := view * p
		overlay.draw_circle(s, r + 1.8, Color(1, 1, 1, fade))
		overlay.draw_circle(s, r + 0.6, Color(mode_color, fade))
	if mesh_focus != Vector2.INF:
		var f := view * mesh_focus
		overlay.draw_arc(f, MESH_R + 9.0, 0.0, TAU, 32, Color.WHITE, 2.0, true)
		overlay.draw_arc(f, MESH_R + 9.0, 0.0, TAU, 32, Color(mode_color, 0.9), 1.0, true)


## Кости как в Moho: вытянутый ромб от начала к кончику. Выделенная яркая с белой обводкой.
func _draw_rig() -> void:
	# тепловая карта весов: синий (0) -> красный (1)
	for i in heat_points.size():
		var v := heat_values[i]
		var c := Color.from_hsv(0.66 * (1.0 - v), 0.85, 1.0, 0.95)
		var p := view * heat_points[i]
		overlay.draw_circle(p, 4.5, Color(0, 0, 0, 0.35))
		overlay.draw_circle(p, 3.5, c)
	for bd in bones_draw:
		var a: Vector2 = view * (bd["a"] as Vector2)
		var b: Vector2 = view * (bd["b"] as Vector2)
		var sel: bool = bd.get("sel", false)
		var dim: bool = bd.get("dim", false)
		var d := b - a
		var l := d.length()
		var col := mode_color if not dim else Color(mode_color, 0.45)
		if l < 2.0:
			overlay.draw_circle(a, 5.0, col)
			continue
		var n := Vector2(-d.y, d.x) / l
		var w := clampf(l * 0.12, 4.0, 11.0)
		var mid := a + d * 0.18
		var poly := PackedVector2Array([a, mid + n * w, b, mid - n * w])
		overlay.draw_colored_polygon(poly, Color(col, 0.95 if sel else 0.4))
		poly.append(a)
		overlay.draw_polyline(poly, Color.WHITE if sel else col, 2.0 if sel else 1.5, true)
		overlay.draw_circle(a, 4.5, Color.WHITE)
		overlay.draw_circle(a, 3.0, col)
		if sel:
			overlay.draw_circle(b, 6.5, Color.WHITE)
			overlay.draw_circle(b, 4.5, col)
	if brush.z > 0.0:
		overlay.draw_arc(Vector2(brush.x, brush.y), brush.z, 0.0, TAU, 48, Color(1, 1, 1, 0.9), 1.5, true)
		overlay.draw_arc(Vector2(brush.x, brush.y), brush.z + 1.5, 0.0, TAU, 48, Color(0, 0, 0, 0.5), 1.0, true)


## Круглые ручки пинов: белый диск с розовой серединой (точки сетки мельче и без диска).
## Привязанный к кости пин обведён кольцом цвета кости, выделенный окружён мягким ореолом.
func _draw_pins() -> void:
	for pd in pins_draw:
		var p: Vector2 = view * (pd["p"] as Vector2)
		if pd["sel"]:
			overlay.draw_circle(p, PIN_R + 6.0, Color(mode_color, 0.3))
		if pd["bound"]:
			overlay.draw_arc(p, PIN_R + 4.0, 0.0, TAU, 32, mode_color, 2.5, true)
		overlay.draw_circle(p, PIN_R + 1.5, Color(0, 0, 0, 0.45))
		overlay.draw_circle(p, PIN_R, Color.WHITE)
		overlay.draw_circle(p, PIN_R - 3.0, PIN_COLOR)
		overlay.draw_circle(p, 2.0, Color.WHITE)


## Экранная позиция ручки стрелки света, INF если стрелки нет.
func light_tip() -> Vector2:
	if light_arrow.is_empty():
		return Vector2.INF
	var c: Vector2 = view * (light_arrow["c"] as Vector2)
	var dir := view.basis_xform(Vector2.from_angle(float(light_arrow["a"]))).normalized()
	return c + dir * ARROW_LEN


## Стрелка света: от центра слоя к «солнцу». Мировой угол, поэтому при повороте вида стрелка остаётся верной.
func _draw_light() -> void:
	var tip := light_tip()
	if tip == Vector2.INF:
		return
	var c: Vector2 = view * (light_arrow["c"] as Vector2)
	var dir := (tip - c) / ARROW_LEN
	var sun := Color("#FFD54F")
	overlay.draw_line(c, tip - dir * SUN_R, Color(0, 0, 0, 0.4), 5.0, true)
	overlay.draw_line(c, tip - dir * SUN_R, sun, 2.5, true)
	overlay.draw_circle(c, 6.0, Color(0, 0, 0, 0.4))
	overlay.draw_circle(c, 5.0, Color.WHITE)
	overlay.draw_circle(c, 2.5, sun)
	for i in 8:
		var d := Vector2.from_angle(float(i) * TAU / 8.0)
		overlay.draw_line(tip + d * (SUN_R + 2.5), tip + d * (SUN_R + 7.0), Color(0, 0, 0, 0.4), 4.0, true)
		overlay.draw_line(tip + d * (SUN_R + 2.5), tip + d * (SUN_R + 7.0), sun, 2.0, true)
	overlay.draw_circle(tip, SUN_R + 1.5, Color(0, 0, 0, 0.4))
	overlay.draw_circle(tip, SUN_R, sun)
	overlay.draw_arc(tip, SUN_R, 0.0, TAU, 24, Color.WHITE, 2.0, true)


func _draw_overlay() -> void:
	if show_ghost:
		var g := ghost_rect()
		var col: Color = RbTheme.C.tx3
		var pts := [g.position, Vector2(g.end.x, g.position.y), g.end, Vector2(g.position.x, g.end.y)]
		for i in 4:
			overlay.draw_dashed_line(pts[i], pts[(i + 1) % 4], col, 1.5, 6.0)
		var font := get_theme_default_font()
		var label := "%d × %d" % [int(canvas_size.x), int(canvas_size.y)]
		var fs := 12
		var tw := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		if g.position.y >= 28.0:
			overlay.draw_string(font, Vector2(g.get_center().x - tw * 0.5, g.position.y - 10.0), label,
				HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)
	if selection.size() >= 3:
		var pts := PackedVector2Array()
		for p in selection:
			pts.append(view * p)
		pts.append(pts[0])
		overlay.draw_polyline(pts, mode_color, 1.5, true)
		if show_gizmo and selection.size() == 4:
			var top := (pts[0] + pts[1]) * 0.5
			var rh := rotate_handle()
			overlay.draw_line(top, rh, mode_color, 1.5, true)
			_handle(rh, true)
			for i in 4:
				_handle(pts[i], false)
		else:
			for i in pts.size() - 1:
				overlay.draw_circle(pts[i], 4.0, mode_color)
	_draw_mesh()
	_draw_rig()
	_draw_pins()
	_draw_light()
	# рамка режима поверх всего (при правке ключевой формы потолще и другого цвета)
	var frame := StyleBoxFlat.new()
	frame.draw_center = false
	frame.border_color = alert_color if alert_color.a > 0.0 else mode_color
	frame.set_border_width_all(4 if alert_color.a > 0.0 else 2)
	frame.set_corner_radius_all(6)
	frame.anti_aliasing = true
	overlay.draw_style_box(frame, Rect2(Vector2.ZERO, size))
