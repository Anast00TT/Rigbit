class_name RbPinTools
extends RefCounted
## Инструмент «Пины» (Puppet Warp) для выделенного слоя с картинкой:
##   тап по слою = пин на ближайшей вершине сетки (если сетка из 4 углов, она строится сама),
##   тяни пин = сдвиг: в Анимации ключ "pin:<id>:offset" на текущем кадре, в Риге ключ базы на кадре 0,
##   долгое нажатие по пину = меню: привязать к выделенной кости, отвязать, удалить.

const PICK_DP := 24.0

var m  # главный экран (ui/main.gd)
var selected := 0  # id выделенного пина

var _drag := 0
var _grab := Vector2.ZERO  # сдвиг от касания до пина, локальный
var _pushed := false


func _init(main) -> void:
	m = main


func layer() -> RbLayer:
	return m._mesh_layer()


func pins_of(l: RbLayer) -> Array:
	return m.doc.rig.pins.get(l.id, [])


## Где пин нарисован сейчас: на вершине деформированной сетки (в координатах холста).
func handle_world(l: RbLayer, p: Dictionary) -> Vector2:
	var lp: RbEvaluator.LayerPose = m.pose.layers[l.id]
	var v := int(p["v"])
	if v < 0 or v >= lp.vertices.size():
		return Vector2.INF
	return lp.world * lp.vertices[v]


## Пин под пальцем (ближайший в PICK_DP на экране) или {}.
func pick(l: RbLayer, w: Vector2) -> Dictionary:
	var s: Vector2 = m.view.view * w
	var best := PICK_DP * PICK_DP
	var out := {}
	for p in pins_of(l):
		var pos := handle_world(l, p)
		if pos == Vector2.INF:
			continue
		var d: float = (m.view.view * pos).distance_squared_to(s)
		if d <= best:
			best = d
			out = p
	return out


func tap(w: Vector2) -> void:
	var l := layer()
	if l == null:
		_select_layer_at(w)
		return
	var hit := pick(l, w)
	if not hit.is_empty():
		selected = int(hit["id"])
		m._update_selection()
		return
	var top: int = m._hit(w)
	if top != l.id:
		_select_layer_at(w)
		return
	_add_pin(l, w)


func _select_layer_at(w: Vector2) -> void:
	var id: int = m._hit(w)
	if id != 0 and not m.doc.get_layer(id).is_group():
		m.selected_id = id
		selected = 0
		m._update_selection()
	else:
		m._toast(m.tr("PIN_TAP_LAYER"))


func _add_pin(l: RbLayer, w: Vector2) -> void:
	var built := false
	if l.mesh_vertices.size() <= 4:
		# у четырёх углов пинам делать нечего: строим сетку
		var img: Image = m.doc.images.get(l.image_id)
		if img == null:
			m._toast(m.tr("MESH_FAIL"))
			return
		m._mesh_commit(l, RbMeshGen.generate(img, l.mesh_density), l.mesh_density)
		built = true
		m._toast(m.tr("PIN_MESH_BUILT"))
	var lw: Transform2D = m._mesh_world(l)
	var verts: PackedVector2Array = l.mesh_vertices if built else (m.pose.layers[l.id] as RbEvaluator.LayerPose).vertices
	var v := RbPins.nearest_vertex(verts, lw.affine_inverse() * w)
	if v < 0:
		return
	var old := pins_of(l)
	var there := RbPins.at_vertex(old, v)
	if not there.is_empty():
		selected = int(there["id"])
		m._toast(m.tr("PIN_EXISTS"))
		m._update_selection()
		return
	var pin: Dictionary = RbPins.new_pin(m.doc.new_id(), v, 0)
	m.undo.push(RbRigCommands.SetPins.new(l.id, old, RbPins.added(old, pin), "Пин"))
	m.undo.end_gesture()
	selected = int(pin["id"])
	m._vibrate(12)
	m._update_selection()


func drag_begin(w: Vector2) -> void:
	_drag = 0
	_pushed = false
	var l := layer()
	if l == null:
		return
	var hit := pick(l, w)
	if hit.is_empty():
		return
	_drag = int(hit["id"])
	selected = _drag
	var lw: Transform2D = m._mesh_world(l)
	var inv := lw.affine_inverse()
	_grab = inv * handle_world(l, hit) - inv * w  # палец держит пин со сдвигом, без рывка
	m._vibrate(8)
	m._update_selection()


func drag_move(w: Vector2) -> void:
	if _drag == 0:
		return
	var l := layer()
	var pin: Dictionary = m.doc.rig.find_pin(_drag)
	if l == null or pin.is_empty():
		return
	var lw: Transform2D = m._mesh_world(l)
	var target: Vector2 = lw.affine_inverse() * w + _grab
	var rest_v: Vector2 = l.mesh_vertices[int(pin["v"])]
	var base: Vector2 = RbPins.base_position(rest_v, int(pin["bone"]), lw, m.pose.bones, m.pose.bones_rest)
	var off := RbPins.offset_for(target, base)
	var old: Vector2 = pin.get("offset", Vector2.ZERO)
	var tk := RbAnimation.track_key("pin", _drag, &"offset")
	# Анимация: ключ на текущем кадре. Риг: база пина = ключ кадра 0 (Риг показывает кадр 0)
	var frame: int = m.doc.current_frame if m.mode == 1 else 0
	m.undo.push(RbAnimCommands.SetKeyAuto.new(tk, frame, off, old), false, true)
	_pushed = true


func drag_end() -> void:
	m.undo.end_gesture()
	_drag = 0
	m._update_selection()


func drag_cancel() -> void:
	if _drag != 0 and _pushed:
		m.undo.cancel_last()
	m.undo.end_gesture()
	_drag = 0


func long_press(w: Vector2) -> void:
	var l := layer()
	if l == null:
		return
	var hit := pick(l, w)
	if hit.is_empty():
		return
	var id := int(hit["id"])
	selected = id
	m._vibrate(30)
	m._update_selection()
	var s: Vector2 = m.view.view * handle_world(l, hit)
	var ar := Rect2(m.view.global_position + s - Vector2(22, 22), Vector2(44, 44))
	m._open_menu_rect(ar, [
		["chain", "PIN_BIND", func() -> void: _bind(l, id)],
		["x", "PIN_UNBIND", func() -> void: _unbind(l, id)],
		["trash", "PIN_DELETE", func() -> void: _delete(l, id)],
	])


func _commit(l: RbLayer, new_pins: Array) -> void:
	m.undo.push(RbRigCommands.SetPins.new(l.id, pins_of(l), new_pins, "Пины"))
	m.undo.end_gesture()
	m._update_selection()


func _bind(l: RbLayer, id: int) -> void:
	var bone: int = m.rig_tools.selected_bone
	if bone == 0 or m.doc.rig.get_bone(bone) == null:
		m._toast(m.tr("BIND_PICK_BONE"))
		return
	_commit(l, RbPins.rebound(pins_of(l), id, bone))


func _unbind(l: RbLayer, id: int) -> void:
	var pin: Dictionary = m.doc.rig.find_pin(id)
	if pin.is_empty() or int(pin["bone"]) == 0:
		m._toast(m.tr("PIN_NOT_BOUND"))
		return
	_commit(l, RbPins.rebound(pins_of(l), id, 0))


func _delete(l: RbLayer, id: int) -> void:
	if selected == id:
		selected = 0
	_commit(l, RbPins.removed(pins_of(l), id))


## Ручки пинов во вьюпорт (только в инструменте «Пины»).
func update_overlay() -> void:
	var v: RbViewportView = m.view
	v.pins_draw = []
	if m.tool != "pins":
		return
	var l := layer()
	if l == null:
		return
	for p in pins_of(l):
		var pos := handle_world(l, p)
		if pos != Vector2.INF:
			v.pins_draw.append({"p": pos, "bound": int(p["bone"]) != 0, "sel": int(p["id"]) == selected})
