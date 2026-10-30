class_name RbRigTools
extends RefCounted
## Инструменты скелета для главного экрана:
##   bone    (Риг)      тянуть по пустому месту = новая кость (дочерняя к выделенной),
##                      тянуть кончик выделенной = длина и угол, тянуть тело = сдвинуть начало;
##   pose    (Анимация) тянуть кость = повернуть вокруг начала, корневую за начало = сдвинуть,
##                      тянуть кончик кости (до 24 dp) = IK цепочки из двух костей за пальцем;
##                      при правке ключевой формы всё это пишется дельтами формы, а не ключами;
##   weights (Риг)      кисть весов для выделенной кости по выделенному слою.

const PICK_DP := 16.0
const TIP_DP := 24.0
const SNAP_DP := 24.0
const BRUSH_DP := 44.0

var m  # главный экран (ui/main.gd)
var selected_bone := 0

var _mode := ""
var _bone_id := 0
var _start_w := Vector2.ZERO
var _start_val: Variant
var _created := false
var _pushed := false
# IK: цепочка и снимок позы на начало жеста (решение зависит только от цели, локоть не перещёлкивается)
var _ik_chain: Array[int] = []
var _ik_world := {}
var _ik_cur := {}  # id -> локальный угол позы, каким он виден сейчас
var _ik_base := {}  # id -> pose_angle на начало жеста


func _init(main) -> void:
	m = main


func _form_on() -> bool:
	return m.form_tools != null and m.form_tools.active


func doc() -> RbDocument:
	return m.doc


func _zoom() -> float:
	return maxf(m.view.view.get_scale().x, 0.0001)


func _bones_world() -> Dictionary:
	return m.pose.bones if m.mode != 0 else m.pose.bones_rest


## Кость под пальцем: ближайший отрезок в пределах PICK_DP на экране.
func hit_bone(w: Vector2) -> int:
	var best := 0
	var best_d := PICK_DP / _zoom()
	var bw := _bones_world()
	for id in bw:
		var b := doc().rig.get_bone(id)
		var t: Transform2D = bw[id]
		var d := RbRig._dist_to_segment(w, t.origin, t * Vector2(b.length, 0))
		if d < best_d:
			best_d = d
			best = id
	return best


func _parent_world(b: RbBone, posed: bool) -> Transform2D:
	if b.parent_id == 0:
		return Transform2D.IDENTITY
	var bw: Dictionary = m.pose.bones if posed else m.pose.bones_rest
	return bw.get(b.parent_id, Transform2D.IDENTITY)


func tap(w: Vector2) -> void:
	selected_bone = hit_bone(w)
	if m.tool == "weights" and selected_bone == 0:
		return
	m._update_selection()


func drag_begin(w: Vector2) -> void:
	_mode = ""
	_pushed = false
	_created = false
	_start_w = w
	match m.tool:
		"bone":
			_bone_begin(w)
		"pose":
			_pose_begin(w)
		"weights":
			_mode = "paint"
			paint(w)


func _bone_begin(w: Vector2) -> void:
	var rest: Dictionary = m.pose.bones_rest
	var sb := doc().rig.get_bone(selected_bone)
	if sb:
		var tip: Vector2 = (rest[sb.id] as Transform2D) * Vector2(sb.length, 0)
		if (m.view.view * tip).distance_to(m.view.view * w) < TIP_DP:
			_mode = "tip"
			_bone_id = sb.id
			_start_val = [sb.angle, sb.length]
			return
	var hit := hit_bone(w)
	if hit != 0:
		selected_bone = hit
		_mode = "base"
		_bone_id = hit
		_start_val = doc().rig.get_bone(hit).position
		m._update_selection()
		return
	# новая кость: начало прилипает к кончику выделенной
	var base := w
	if sb:
		var tip2: Vector2 = (rest[sb.id] as Transform2D) * Vector2(sb.length, 0)
		if (m.view.view * tip2).distance_to(m.view.view * w) < SNAP_DP * 2.0:
			base = tip2
	var b := RbBone.new()
	b.id = doc().new_id()
	b.name = tr_bone_name()
	b.parent_id = sb.id if sb else 0
	var pw := _parent_world(b, false)
	b.position = pw.affine_inverse() * base
	b.length = 0.0
	doc().rig.bones[b.id] = b
	_mode = "create"
	_bone_id = b.id
	_start_w = base
	_created = true
	selected_bone = b.id


func tr_bone_name() -> String:
	return m.tr("BONE_N") % (doc().rig.bones.size() + 1)


## Кость, у которой кончик в пределах TIP_DP от касания (для коротких костей зона уже), 0 = нет.
func tip_bone(w: Vector2) -> int:
	var s: Vector2 = m.view.view * w
	var bw := _bones_world()
	var best := 0
	var best_d := INF
	for id in bw:
		var b := doc().rig.get_bone(id)
		var t: Transform2D = bw[id]
		var tip_s: Vector2 = m.view.view * (t * Vector2(b.length, 0))
		var base_s: Vector2 = m.view.view * t.origin
		var zone := minf(TIP_DP, maxf(12.0, tip_s.distance_to(base_s) * 0.4))
		var d := tip_s.distance_to(s)
		if d <= zone and d < best_d:
			best_d = d
			best = id
	return best


func _ik_begin(id: int) -> void:
	var rig := doc().rig
	_ik_chain = RbIK.chain_for(rig, id, 2)
	_ik_world = (_bones_world() as Dictionary).duplicate()
	_ik_cur.clear()
	_ik_base.clear()
	for cid in _ik_chain:
		var b := rig.get_bone(cid)
		var t: Transform2D = _ik_world[cid]
		var pa := 0.0
		if b.parent_id != 0 and _ik_world.has(b.parent_id):
			pa = (_ik_world[b.parent_id] as Transform2D).get_rotation()
		_ik_cur[cid] = wrapf(t.get_rotation() - pa - b.angle, -PI, PI)
		_ik_base[cid] = b.pose_angle
	selected_bone = id
	_bone_id = id
	_mode = "ik"
	m._update_selection()


func _ik_move(w: Vector2) -> void:
	var sol := RbIK.solve(doc().rig, _ik_chain, _ik_world, w)
	var tracks := []
	var vals := []
	var olds := []
	for id in _ik_chain:
		var b := doc().rig.get_bone(id)
		# от вида на начало жеста считаем сдвиг угла: так не теряются добавки форм и констрейнов
		var d := wrapf(float(sol[id]) - float(_ik_cur[id]), -PI, PI)
		if _form_on():
			m.form_tools.set_bone_delta(id, "angle", d)
			continue
		tracks.append(RbAnimation.track_key("bone", id, &"pose_angle"))
		vals.append(wrapf(float(_ik_base[id]) + d, -PI, PI))
		olds.append(b.pose_angle)
	if _form_on():
		return
	if m.mode == 1:
		m.undo.push(RbAnimCommands.SetKeysAuto.new(tracks, doc().current_frame, vals, olds), false, true)
	else:
		for i in tracks.size():
			doc().rig.get_bone(_ik_chain[i]).pose_angle = vals[i]
		doc().notify(&"bones")
	_pushed = true


func _pose_begin(w: Vector2) -> void:
	if _form_on():
		m.form_tools.gesture_begin()
	var tip := tip_bone(w)
	if tip != 0:
		_ik_begin(tip)
		return
	var hit := hit_bone(w)
	if hit == 0:
		hit = selected_bone
	var b := doc().rig.get_bone(hit)
	if b == null:
		return
	selected_bone = hit
	_bone_id = hit
	var bw := _bones_world()
	var base: Vector2 = (bw[hit] as Transform2D).origin
	if b.parent_id == 0 and (m.view.view * base).distance_to(m.view.view * w) < TIP_DP:
		_mode = "pose_move"
		_start_val = b.pose_offset
	else:
		_mode = "pose_rot"
		_start_val = b.pose_angle
	m._update_selection()


func drag_move(w: Vector2) -> void:
	var b := doc().rig.get_bone(_bone_id)
	match _mode:
		"create", "tip":
			var pw := _parent_world(b, false)
			var base: Vector2 = pw * b.position
			var local_dir := pw.affine_inverse().basis_xform(w - base)
			b.angle = local_dir.angle()
			b.length = local_dir.length()
			if _mode == "tip":
				_set_bone(b, &"angle", (_start_val as Array)[0], b.angle)
				_set_bone(b, &"length", (_start_val as Array)[1], b.length)
			else:
				doc().notify(&"bones")
		"base":
			var pw2 := _parent_world(b, false)
			var np: Vector2 = (_start_val as Vector2) + pw2.affine_inverse().basis_xform(w - _start_w)
			_set_bone(b, &"position", b.position, np)
		"pose_rot":
			var base2: Vector2 = (_bones_world()[b.id] as Transform2D).origin
			var a: float = (_start_val as float) + (w - base2).angle() - (_start_w - base2).angle()
			_set_bone(b, &"pose_angle", b.pose_angle, wrapf(a, -PI, PI))
		"pose_move":
			var pw3 := _parent_world(b, true)
			var off: Vector2 = (_start_val as Vector2) + pw3.affine_inverse().basis_xform(w - _start_w)
			_set_bone(b, &"pose_offset", b.pose_offset, off)
		"ik":
			_ik_move(w)
		"paint":
			paint(w)


func _set_bone(b: RbBone, prop: StringName, old: Variant, v: Variant) -> void:
	if _form_on() and String(prop).begins_with("pose_"):
		# правка ключевой формы: кость сама не меняется, в форму пишется сдвиг от начала жеста
		var fp: String = String(prop).trim_prefix("pose_")
		var d: Variant = v - old
		if fp == "angle":
			d = wrapf(float(d), -PI, PI)
		m.form_tools.set_bone_delta(b.id, fp, d)
		return
	b.set_prop(prop, v)
	if m.mode == 1 and String(prop).begins_with("pose_"):
		# режим Анимация: правка позы = ключ на текущем кадре (команда сама пишет значение в кость)
		var track := RbAnimation.track_key("bone", b.id, prop)
		m.undo.push(RbAnimCommands.SetKeyAuto.new(track, doc().current_frame, v, old), false, true)
	else:
		m.undo.push(RbRigCommands.SetBoneProp.new(b.id, prop, old, v), true, true)
	_pushed = true
	doc().notify(&"bones")


func drag_end() -> void:
	if _mode == "create":
		var b := doc().rig.get_bone(_bone_id)
		if b.length * _zoom() < 12.0:
			# слишком короткая: это был не жест создания
			doc().rig.bones.erase(_bone_id)
			selected_bone = b.parent_id
			doc().notify(&"bones")
		else:
			m.undo.push(RbRigCommands.AddBone.new(b), true)
			m._vibrate(15)
	m.view.brush = Vector3.ZERO
	m.undo.end_gesture()
	_mode = ""
	m._update_selection()


func drag_cancel() -> void:
	if _mode == "create":
		doc().rig.bones.erase(_bone_id)
		selected_bone = 0
		doc().notify(&"bones")
	elif _form_on() and m.tool == "pose":
		m.form_tools.gesture_cancel()
	elif _pushed:
		m.undo.cancel_last()
	m.view.brush = Vector3.ZERO
	m.undo.end_gesture()
	_mode = ""


# ---------------- веса ----------------

func paint(w: Vector2) -> void:
	var l: RbLayer = doc().get_layer(m.selected_id)
	var radius := BRUSH_DP / _zoom()
	var s: Vector2 = m.view.view * w
	m.view.brush = Vector3(s.x, s.y, BRUSH_DP)
	if l == null or l.is_group() or not doc().rig.weights.has(l.id) or selected_bone == 0:
		m.view.refresh_overlay()
		return
	var lp: RbEvaluator.LayerPose = m.pose.layers[l.id]
	var wv: PackedVector2Array = lp.world * l.mesh_vertices
	var old: Dictionary = doc().rig.weights[l.id]
	var pressure: float = m.view.last_pressure if m.view.last_pressure > 0.0 else 1.0
	var nw := RbRig.paint(old, wv, w, radius, selected_bone, 0.18 * pressure)
	doc().rig.weights[l.id] = nw
	m.undo.push(RbRigCommands.SetWeights.new(l.id, old, nw, "Кисть весов"), true, true)
	_pushed = true
	doc().notify(&"weights")


# ---------------- привязка ----------------

func bind_rigid(l: RbLayer) -> bool:
	if selected_bone == 0:
		return false
	var old: Dictionary = doc().rig.weights.get(l.id, {})
	m.undo.push(RbRigCommands.SetWeights.new(l.id, old, RbRig.rigid_weights(l.mesh_vertices.size(), selected_bone), "Привязать к кости"))
	return true


func bind_auto(l: RbLayer) -> bool:
	if doc().rig.bones.is_empty():
		return false
	var lp: RbEvaluator.LayerPose = m.pose.layers[l.id]
	var old: Dictionary = doc().rig.weights.get(l.id, {})
	m.undo.push(RbRigCommands.SetWeights.new(l.id, old, doc().rig.auto_weights(lp.world * l.mesh_vertices), "Автовеса"))
	return true


func unbind(l: RbLayer) -> void:
	var old: Dictionary = doc().rig.weights.get(l.id, {})
	if not old.is_empty():
		m.undo.push(RbRigCommands.SetWeights.new(l.id, old, {}, "Отвязать"))


## Короткое описание привязки слоя: «не привязан» / имена костей.
func bind_status(l: RbLayer) -> String:
	var wd: Dictionary = doc().rig.weights.get(l.id, {})
	if wd.is_empty():
		return m.tr("BIND_NONE")
	var names := {}
	var bi: PackedInt32Array = wd["bones"]
	for b in bi:
		if b != 0 and doc().rig.get_bone(b):
			names[doc().rig.get_bone(b).name] = true
	var list := ", ".join(PackedStringArray(names.keys()))
	return m.tr("BIND_TO") % list


# ---------------- оверлей ----------------

func update_overlay() -> void:
	var v: RbViewportView = m.view
	v.bones_draw = []
	v.heat_points = PackedVector2Array()
	v.heat_values = PackedFloat32Array()
	if doc().rig.get_bone(selected_bone) == null:
		selected_bone = 0
	var show_bones: bool = m.tool in ["bone", "pose", "weights"] or (m.mode <= 1 and not doc().rig.bones.is_empty())
	if not show_bones:
		return
	var bw := _bones_world()
	var dim: bool = m.tool not in ["bone", "pose", "weights"]
	for id in bw:
		var b := doc().rig.get_bone(id)
		var t: Transform2D = bw[id]
		v.bones_draw.append({"a": t.origin, "b": t * Vector2(b.length, 0), "sel": id == selected_bone and not dim, "dim": dim})
	if m.tool == "weights":
		var l: RbLayer = doc().get_layer(m.selected_id)
		if l and not l.is_group() and doc().rig.weights.has(l.id) and selected_bone != 0 and m.pose.layers.has(l.id):
			var lp: RbEvaluator.LayerPose = m.pose.layers[l.id]
			v.heat_points = lp.world * lp.vertices
			v.heat_values = RbRig.bone_weight_per_vertex(doc().rig.weights[l.id], selected_bone, l.mesh_vertices.size())
