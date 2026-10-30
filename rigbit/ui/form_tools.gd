class_name RbFormTools
extends RefCounted
## Правка ключевой формы параметра. Пока она включена, перетаскивание костей и точек сетки
## пишется не ключами, а дельтами в param.forms[точка]: кости (угол, сдвиг, масштаб от вычисленной базы)
## и вершины (дельты в rest-пространстве слоя). Правка идёт прямо в параметр, а «Готово» кладёт в историю
## один шаг (RbParamCommands.SetParamForms).

var m  # главный экран (ui/main.gd)
var active := false
var param_id := 0
var point := 0.0

var _saved_value := 0.0
var _old_forms := {}
var _form := {}  # рабочая форма, она же param.forms[point]
var _g := {}  # снимок формы на начало жеста

var _vl := 0  # слой перетаскиваемой вершины
var _vi := -1
var _vstart := Vector2.ZERO
var _vdisp := Vector2.ZERO
var _vgrab := Vector2.ZERO


func _init(main) -> void:
	m = main


func param() -> RbParams.Param:
	return m.doc.params.get_param(param_id)


func enter(id: int, pt: float) -> void:
	var p: RbParams.Param = m.doc.params.get_param(id)
	if p == null:
		return
	active = true
	param_id = id
	point = RbFormEdit.point_key(p, clampf(pt, p.min_v, p.max_v))
	_saved_value = p.value
	_old_forms = p.forms.duplicate(true)
	_form = RbFormEdit.normalized(p.forms.get(point, {}))
	p.forms[point] = _form
	p.value = point
	_vi = -1
	_g = _form.duplicate(true)
	m._form_state_changed()


## Конец правки: одна запись в историю, значение ползунка возвращается.
func finish() -> bool:
	if not active:
		return false
	var p := param()
	active = false
	var changed := false
	if p:
		if RbFormEdit.is_empty(_form):
			p.forms.erase(point)  # пустая форма не хранится
		if not RbUi.same_dict(_old_forms, p.forms):
			m.undo.push(RbParamCommands.SetParamForms.new(param_id, _old_forms, p.forms), true)
			m.undo.end_gesture()
			changed = true
		p.value = _saved_value
		m.doc.anim.apply_frame(m.doc, m.doc.shown_frame())
	_form = {}
	m._form_state_changed()
	return changed


## Выйти без записи (смена документа): форма возвращается как была.
func discard() -> void:
	if not active:
		return
	var p := param()
	active = false
	if p:
		p.forms = _old_forms
		p.value = _saved_value
	_form = {}


## Сбросить форму в этой точке (живая правка, запишется по «Готово»).
func reset_form() -> void:
	if not active:
		return
	_form.clear()
	_form.merge(RbFormEdit.empty_form())
	_g = _form.duplicate(true)
	m.doc.notify(&"params")


func gesture_begin() -> void:
	_g = _form.duplicate(true)


func gesture_cancel() -> void:
	_form.clear()
	_form.merge(_g.duplicate(true))
	m.doc.notify(&"params")


## Дельта кости от начала жеста: prop = "angle" | "offset" | "scale".
func set_bone_delta(bone_id: int, prop: String, delta: Variant) -> void:
	if not active:
		return
	var start: Variant = RbFormEdit.bone_prop(_g, bone_id, prop)
	RbFormEdit.set_bone_prop(_form, bone_id, prop, start + delta)
	m.doc.notify(&"params")


# ---------------- вершины ----------------

## Ближайшая к касанию вершина (какой её сейчас видно) в радиусе 24 dp, -1 если нет.
func mesh_pick(l: RbLayer, w: Vector2) -> int:
	var lp: RbEvaluator.LayerPose = m.pose.layers[l.id]
	var s: Vector2 = m.view.view * w
	var best := 24.0 * 24.0
	var bi := -1
	for i in lp.vertices.size():
		var d: float = (m.view.view * (lp.world * lp.vertices[i])).distance_squared_to(s)
		if d <= best:
			best = d
			bi = i
	return bi


func mesh_begin(w: Vector2) -> void:
	_vi = -1
	var l: RbLayer = m._mesh_layer()
	if l == null:
		m._toast(m.tr("MESH_PICK"))
		return
	var i := mesh_pick(l, w)
	if i < 0:
		return
	gesture_begin()
	var lp: RbEvaluator.LayerPose = m.pose.layers[l.id]
	_vl = l.id
	_vi = i
	_vdisp = lp.vertices[i]
	_vgrab = _vdisp - lp.world.affine_inverse() * w
	_vstart = RbFormEdit.vert_delta(_g, l.id, i)
	m._vibrate(8)
	m._update_selection()


func mesh_move(w: Vector2) -> void:
	if _vi < 0 or not m.pose.layers.has(_vl):
		return
	var l: RbLayer = m.doc.get_layer(_vl)
	var lp: RbEvaluator.LayerPose = m.pose.layers[_vl]
	if l == null:
		return
	var target: Vector2 = lp.world.affine_inverse() * w + _vgrab
	RbFormEdit.set_vert_delta(_form, _vl, _vi, l.mesh_vertices.size(), _vstart + (target - _vdisp))
	m.doc.notify(&"params")


func mesh_end() -> void:
	_vi = -1
	m._update_selection()


func mesh_cancel() -> void:
	if _vi >= 0:
		gesture_cancel()
	_vi = -1
	m._update_selection()


## Какая вершина сейчас под пальцем (для подсветки), -1 если нет.
func dragged_vertex() -> int:
	return _vi if _vi >= 0 else -1


func dragged_layer() -> int:
	return _vl
