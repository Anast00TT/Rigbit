class_name RbRangeSlider
extends Control
## Ползунок с двумя ручками (диапазон кадров). Тянется ближайшая к пальцу ручка.
## changed(a, b, done): done = палец отпущен.

signal changed(a: int, b: int, done: bool)

const R := 11.0  # радиус ручки
const PAD := 12.0  # поля, чтобы ручка у края не обрезалась

var min_v := 0
var max_v := 1
var a := 0
var b := 1
var _drag := -1  # 0 = левая, 1 = правая


func _init() -> void:
	custom_minimum_size = Vector2(120, 44)
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE


func setup(lo: int, hi: int, va: int, vb: int) -> void:
	min_v = lo
	max_v = maxi(hi, lo + 1)
	a = clampi(mini(va, vb), min_v, max_v)
	b = clampi(maxi(va, vb), min_v, max_v)
	queue_redraw()


func _x(v: int) -> float:
	return PAD + (size.x - PAD * 2.0) * float(v - min_v) / float(max_v - min_v)


func _v(x: float) -> int:
	var k := clampf((x - PAD) / maxf(size.x - PAD * 2.0, 1.0), 0.0, 1.0)
	return min_v + roundi(k * (max_v - min_v))


func _draw() -> void:
	var C: Dictionary = RbTheme.C
	var cy := size.y * 0.5
	draw_line(Vector2(PAD, cy), Vector2(size.x - PAD, cy), C.p3, 3.0, true)
	draw_line(Vector2(_x(a), cy), Vector2(_x(b), cy), C.acc, 3.0, true)
	for v in [a, b]:
		var c := Vector2(_x(v), cy)
		draw_circle(c + Vector2(0, 1), R, Color(0, 0, 0, 0.35))
		draw_circle(c, R, Color.WHITE)


func _gui_input(e: InputEvent) -> void:
	var pos := Vector2.ZERO
	var pressed := false
	var released := false
	var moved := false
	if e is InputEventScreenTouch:
		pos = e.position
		pressed = e.pressed
		released = not e.pressed
	elif e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
		pos = e.position
		pressed = e.pressed
		released = not e.pressed
	elif e is InputEventScreenDrag or (e is InputEventMouseMotion and _drag >= 0):
		pos = e.position
		moved = true
	else:
		return
	accept_event()
	if pressed:
		var da := absf(pos.x - _x(a))
		var db := absf(pos.x - _x(b))
		_drag = 0 if da < db or (da == db and pos.x < _x(a)) else 1
		moved = true
	if moved and _drag >= 0:
		var v := _v(pos.x)
		if _drag == 0:
			a = mini(v, b)
		else:
			b = maxi(v, a)
		queue_redraw()
		changed.emit(a, b, false)
	if released and _drag >= 0:
		_drag = -1
		changed.emit(a, b, true)
