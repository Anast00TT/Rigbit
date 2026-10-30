class_name RbEvaluator
extends RefCounted
## Вычисление кадра. Порядок фиксированный, не переставлять без причины:
##   1. значения ползунков на кадре (из ключей)
##   2. ползунки-драйверы считают зависимые (топологическая сортировка)
##   3. ключевые формы параметров (дельты к костям, вершинам, прозрачности, свитчам, эффектам)
##   4. ключи костей кадра
##   5. констрейны
##   6. IK
##   7. динамика (кеш по кадрам)
##   8. мировые трансформы костей
##   9. скиннинг вершин (linear blend skinning)
##  10. ARAP-доводка по пинам
##  11. отрисовка и композинг на GPU (это уже RbRenderer)
## Фаза 0: только иерархия слоёв и их трансформы.


class LayerPose:
	var world := Transform2D.IDENTITY
	var opacity: float = 1.0
	var visible: bool = true
	var vertices := PackedVector2Array()  # итоговые вершины сетки (пока = rest)


## Результат: id слоя -> LayerPose, плюс порядок отрисовки.
class Pose:
	var layers: Dictionary = {}
	var order: Array[int] = []
	var bones: Dictionary = {}  # id кости -> мировой Transform2D (поза)
	var bones_rest: Dictionary = {}  # id кости -> мировой Transform2D (rest)


## posed=false: rest-поза скелета (режим Риг, как в Moho).
func evaluate(doc: RbDocument, _frame: int, posed := true) -> Pose:
	var pose := Pose.new()
	_walk(doc, doc.root, Transform2D.IDENTITY, 1.0, true, pose)
	# 8. мировые трансформы костей
	pose.bones_rest = doc.rig.world_transforms(false)
	# 1. значения ползунков уже записаны apply_frame; 2. драйверы; 3. ключевые формы
	var forms := {}
	if posed and not doc.params.params.is_empty():
		doc.params.resolve_drivers()
		forms = doc.params.blend()
		for lid in forms["verts"]:
			if pose.layers.has(lid):
				var lp0: LayerPose = pose.layers[lid]
				var dv: PackedVector2Array = forms["verts"][lid]
				var vv := lp0.vertices.duplicate()
				for i in mini(vv.size(), dv.size()):
					vv[i] += dv[i]
				lp0.vertices = vv
		for lid in forms["opacity"]:
			if pose.layers.has(lid):
				var lp1: LayerPose = pose.layers[lid]
				lp1.opacity = clampf(lp1.opacity + float(forms["opacity"][lid]), 0.0, 1.0)
	var bone_forms: Dictionary = forms.get("bones", {})
	if posed and (doc.rig.any_posed() or not bone_forms.is_empty()):
		# 5. констрейны внутри world_transforms; 7. динамика из кеша по кадрам
		_watch(doc)
		pose.bones = doc.rig.world_transforms(true, dynamics.offsets(doc, doc.current_frame), bone_forms)
	else:
		pose.bones = pose.bones_rest
	# 9. скиннинг: только если скелет не в покое (в риге слои не пересчитываются вовсе)
	if pose.bones != pose.bones_rest:
		var mats := {}
		for id in pose.bones:
			mats[id] = (pose.bones[id] as Transform2D) * (pose.bones_rest[id] as Transform2D).affine_inverse()
		for id in pose.order:
			var wd: Dictionary = doc.rig.weights.get(id, {})
			if wd.is_empty():
				continue
			var lp: LayerPose = pose.layers[id]
			var world_rest := lp.world * lp.vertices
			lp.vertices = lp.world.affine_inverse() * RbRig.skin(world_rest, wd, mats)
	# 10. ARAP по пинам: свободный пин = rest-точка + смещение, пин на кости следует за костью
	for id in pose.order:
		var pins: Array = doc.rig.pins.get(id, [])
		if pins.is_empty():
			continue
		var l := doc.get_layer(id)
		var lp2: LayerPose = pose.layers[id]
		var active := false
		var idx := PackedInt32Array()
		var targets := PackedVector2Array()
		for p in pins:
			var vi := int(p["v"])
			if vi < 0 or vi >= l.mesh_vertices.size():
				continue
			var base := l.mesh_vertices[vi]
			var bone := int(p["bone"])
			if bone != 0 and pose.bones.has(bone):
				var m: Transform2D = (pose.bones[bone] as Transform2D) * (pose.bones_rest[bone] as Transform2D).affine_inverse()
				base = lp2.world.affine_inverse() * (m * (lp2.world * base))
			var off: Vector2 = p.get("offset", Vector2.ZERO)
			if base.distance_squared_to(l.mesh_vertices[vi]) > 0.0001 or off != Vector2.ZERO:
				active = true
			idx.append(vi)
			targets.append(base + off)
		if not active:
			continue
		var solver := _arap_for(l, idx)
		lp2.vertices = solver.solve(targets, lp2.vertices)
	return pose


## Поза на другом кадре без следа в документе: значения дорожек и текущий кадр возвращаются как были.
## Для экспорта и онион скина (у каждого свой вычислитель, чтобы не мешать кешам вьюпорта).
func pose_at(doc: RbDocument, frame: int) -> Pose:
	var snap := doc.anim.capture(doc)
	var old_frame := doc.current_frame
	doc.current_frame = frame
	doc.anim.apply_frame(doc, frame)
	var pose := evaluate(doc, frame, true)
	RbAnimation.restore(doc, snap)
	doc.current_frame = old_frame
	return pose


var _arap_cache := {}  # layer id -> [подпись, RbArap]
var dynamics := RbDynamics.new()
var _watched: RbDocument


## Кеш динамики сбрасывается, когда меняются ключи или кости.
func _watch(doc: RbDocument) -> void:
	if _watched == doc:
		return
	if _watched and _watched.changed.is_connected(_on_doc_changed):
		_watched.changed.disconnect(_on_doc_changed)
	_watched = doc
	dynamics.invalidate()
	doc.changed.connect(_on_doc_changed)


func _on_doc_changed(what: StringName) -> void:
	if what in [&"keys", &"bones", &"layers"]:
		dynamics.invalidate()


func _arap_for(l: RbLayer, pinned: PackedInt32Array) -> RbArap:
	var sig := hash(l.mesh_vertices) ^ hash(l.mesh_indices) ^ hash(pinned)
	var e: Array = _arap_cache.get(l.id, [])
	if e.is_empty() or e[0] != sig:
		var a := RbArap.new()
		a.prepare(l.mesh_vertices, l.mesh_indices, pinned)
		e = [sig, a]
		_arap_cache[l.id] = e
	return e[1]


func _walk(doc: RbDocument, ids: Array[int], parent: Transform2D, parent_op: float, parent_vis: bool, pose: Pose) -> void:
	for id in ids:
		var l := doc.get_layer(id)
		if l == null:
			continue
		var lp := LayerPose.new()
		lp.world = parent * l.local_transform()
		lp.opacity = parent_op * l.opacity
		lp.visible = parent_vis and l.visible
		lp.vertices = l.mesh_vertices
		pose.layers[id] = lp
		if l.is_group():
			_walk(doc, l.children, lp.world, lp.opacity, lp.visible, pose)
		else:
			pose.order.append(id)
