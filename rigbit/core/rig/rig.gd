class_name RbRig
extends RefCounted
## Скелет документа и веса вершин. Одна система привязки: каждая вершина сетки слоя
## имеет до 4 пар (кость, вес), веса нормализованы. «Жёстко привязать слой к кости» =
## 100% всех вершин на одну кость.

const MAX_INFLUENCES := 4

var bones: Dictionary = {}  # id -> RbBone
## layer_id -> {"bones": PackedInt32Array (4 на вершину, 0 = пусто), "w": PackedFloat32Array (4 на вершину)}
var weights: Dictionary = {}
## Пины (Puppet Warp): layer_id -> Array[{id, v: индекс вершины, bone: 0 = свободный, offset: Vector2 (локально, анимируется)}]
var pins: Dictionary = {}


func get_bone(id: int) -> RbBone:
	return bones.get(id)


func children_of(id: int) -> Array[int]:
	var out: Array[int] = []
	for b: RbBone in bones.values():
		if b.parent_id == id:
			out.append(b.id)
	out.sort()
	return out


## Кости в порядке «родитель раньше детей».
func order() -> Array[int]:
	var out: Array[int] = []
	var stack: Array[int] = children_of(0)
	stack.reverse()
	while not stack.is_empty():
		var id: int = stack.pop_back()
		out.append(id)
		var ch := children_of(id)
		ch.reverse()
		stack.append_array(ch)
	return out


func is_descendant(id: int, ancestor: int) -> bool:
	var b := get_bone(id)
	while b and b.parent_id != 0:
		if b.parent_id == ancestor:
			return true
		b = get_bone(b.parent_id)
	return false


## Мировые трансформы всех костей. posed=false: rest-поза.
## extra: id -> добавочный локальный угол (динамика), применяется после констрейнов.
## form: id -> {angle, offset, scale} — дельты ключевых форм параметров (шаг 3).
func world_transforms(posed: bool, extra := {}, form := {}) -> Dictionary:
	var out := {}
	var rest := {}
	for id in order():
		var b := get_bone(id)
		var pw: Transform2D = out[b.parent_id] if b.parent_id != 0 and out.has(b.parent_id) else Transform2D.IDENTITY
		var prw: Transform2D = rest[b.parent_id] if b.parent_id != 0 and rest.has(b.parent_id) else Transform2D.IDENTITY
		rest[id] = prw * b.rest_local()
		if not posed:
			out[id] = rest[id]
			continue
		var pa := b.pose_angle
		var po := b.pose_offset
		var ps := b.pose_scale
		var c := b.constraints
		if form.has(id):
			var fd: Dictionary = form[id]
			pa += float(fd.get("angle", 0.0))
			po += fd.get("offset", Vector2.ZERO)
			ps += fd.get("scale", Vector2.ZERO)
		if c.has("copy"):
			var cp: Dictionary = c["copy"]
			var src := get_bone(int(cp.get("from", 0)))
			if src and src.id != id:
				pa += src.pose_angle * float(cp.get("angle", 0.0))
				po += src.pose_offset * float(cp.get("move", 0.0))
				ps *= Vector2.ONE.lerp(src.pose_scale, float(cp.get("scale", 0.0)))
		if c.has("limit"):
			var lim: Dictionary = c["limit"]
			pa = clampf(pa, float(lim.get("min", -PI)), float(lim.get("max", PI)))
		pa += float(extra.get(id, 0.0))
		var w := pw * Transform2D(b.angle + pa, ps, 0.0, b.position + po)
		if c.get("independent", false):
			# угол не наследуется: rest-угол в мире + своя поза
			w = Transform2D((rest[id] as Transform2D).get_rotation() + pa, w.get_scale(), 0.0, w.origin)
		if c.has("target") and out.has(int(c["target"])):
			var to: Vector2 = (out[int(c["target"])] as Transform2D).origin - w.origin
			if to.length() > 0.001:
				w = Transform2D(to.angle(), w.get_scale(), 0.0, w.origin)
		if c.has("ik") and b.parent_id != 0 and out.has(b.parent_id):
			var goal = _ik_goal(int((c["ik"] as Dictionary).get("target", 0)), out, extra)
			if goal != null:
				w = _ik_two(b, out, w, goal)
		out[id] = w
	return out


## Начало кости-цели IK в мире. Цель обычно корневая (ноги к target1/target2): если она
## ещё не посчитана в этом проходе, считаем её сразу. null = цели нет.
func _ik_goal(tid: int, out: Dictionary, extra: Dictionary) -> Variant:
	if out.has(tid):
		return (out[tid] as Transform2D).origin
	var t := get_bone(tid)
	if t == null or t.parent_id != 0:
		return null
	return Transform2D(t.angle + t.pose_angle + float(extra.get(tid, 0.0)), t.pose_scale, 0.0, t.position + t.pose_offset).origin


## Постоянная IK-цель (констрейн ik: {target}): родитель и сама кость решаются двухкостно,
## конец кости тянется к цели, сторона сгиба как в текущей позе. Родитель перезаписывается в out;
## его другие дети, посчитанные раньше этой кости, IK не увидят (у ног и рук их нет).
func _ik_two(b: RbBone, out: Dictionary, w: Transform2D, goal: Vector2) -> Transform2D:
	var pid := b.parent_id
	var pw: Transform2D = out[pid]
	var p := get_bone(pid)
	var tip := w * Vector2(b.length, 0)
	var pts: Array[Vector2] = [pw.origin, w.origin, tip]
	var lens: Array[float] = [pw.origin.distance_to(w.origin), b.length * w.get_scale().x]
	if lens[0] < 0.001 or lens[1] < 0.001:
		return w
	var np := RbIK._two_bone(pts, lens, goal)
	# родитель поворачивается так, чтобы его кость смотрела на новый сустав (сохраняя смещение сустава)
	var joint_local := pw.affine_inverse() * w.origin
	var turn := (np[1] - np[0]).angle() - (w.origin - pw.origin).angle()
	var npw := Transform2D(pw.get_rotation() + turn, pw.get_scale(), pw.get_skew(), pw.origin)
	out[pid] = npw
	var joint := npw * joint_local
	return Transform2D((np[2] - np[1]).angle(), w.get_scale(), w.get_skew(), joint)


## Кости с динамикой.
func dynamic_bones() -> Array[int]:
	var out: Array[int] = []
	for id in order():
		if get_bone(id).constraints.has("dynamics"):
			out.append(id)
	return out


func any_posed() -> bool:
	for b: RbBone in bones.values():
		if b.has_pose() or not b.constraints.is_empty():
			return true
	return false


# ---------------- веса ----------------

func has_weights(layer_id: int) -> bool:
	return weights.has(layer_id)


## Все вершины слоя на одну кость.
static func rigid_weights(vertex_count: int, bone_id: int) -> Dictionary:
	var bi := PackedInt32Array()
	var w := PackedFloat32Array()
	bi.resize(vertex_count * MAX_INFLUENCES)
	w.resize(vertex_count * MAX_INFLUENCES)
	for i in vertex_count:
		bi[i * MAX_INFLUENCES] = bone_id
		w[i * MAX_INFLUENCES] = 1.0
	return {"bones": bi, "w": w}


## Автовеса: по расстоянию от вершины до отрезка кости, затухание, топ-4, нормализация.
## world_vertices: вершины сетки в координатах холста (rest). bone_ids: какие кости учитывать (пусто = все).
func auto_weights(world_vertices: PackedVector2Array, bone_ids: Array = []) -> Dictionary:
	var rest := world_transforms(false)
	var ids: Array = bone_ids if not bone_ids.is_empty() else bones.keys()
	var segs: Array = []
	for id in ids:
		var b := get_bone(id)
		if b == null:
			continue
		var t: Transform2D = rest[id]
		segs.append([id, t.origin, t * Vector2(b.length, 0.0), maxf(b.length, 1.0)])
	var n := world_vertices.size()
	var bi := PackedInt32Array()
	var w := PackedFloat32Array()
	bi.resize(n * MAX_INFLUENCES)
	w.resize(n * MAX_INFLUENCES)
	if segs.is_empty():
		return {"bones": bi, "w": w}
	for i in n:
		var p := world_vertices[i]
		var cand: Array = []  # [вес, id]
		var nearest := INF
		for s in segs:
			var d := _dist_to_segment(p, s[1], s[2])
			nearest = minf(nearest, d)
			cand.append([d, s[0], s[3]])
		var picked: Array = []
		for c in cand:
			# дальше 2.5× ближайшей кости — не влияет (иначе рука тянет живот)
			if c[0] <= nearest * 2.5 + 2.0:
				var falloff := maxf(c[0], c[2] * 0.02)
				picked.append([1.0 / (falloff * falloff), c[1]])
		picked.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
		picked.resize(mini(picked.size(), MAX_INFLUENCES))
		var total := 0.0
		for c in picked:
			total += c[0]
		for k in picked.size():
			var v: float = picked[k][0] / total
			if v < 0.02:
				continue
			bi[i * MAX_INFLUENCES + k] = picked[k][1]
			w[i * MAX_INFLUENCES + k] = v
		_normalize(w, i)
	return {"bones": bi, "w": w}


static func _normalize(w: PackedFloat32Array, i: int) -> void:
	var s := 0.0
	for k in MAX_INFLUENCES:
		s += w[i * MAX_INFLUENCES + k]
	if s > 0.0:
		for k in MAX_INFLUENCES:
			w[i * MAX_INFLUENCES + k] /= s


static func _dist_to_segment(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var l2 := ab.length_squared()
	if l2 < 0.0001:
		return p.distance_to(a)
	var t := clampf((p - a).dot(ab) / l2, 0.0, 1.0)
	return p.distance_to(a + ab * t)


## Кисть весов: вершинам в радиусе прибавить влияние bone_id (strength 0..1, с затуханием к краю),
## остальные кости вершины пропорционально уменьшаются. Возвращает новые веса.
static func paint(wd: Dictionary, world_vertices: PackedVector2Array, center: Vector2, radius: float,
		bone_id: int, strength: float) -> Dictionary:
	var bi: PackedInt32Array = (wd["bones"] as PackedInt32Array).duplicate()
	var w: PackedFloat32Array = (wd["w"] as PackedFloat32Array).duplicate()
	for i in world_vertices.size():
		var d := world_vertices[i].distance_to(center)
		if d > radius:
			continue
		var amount := strength * (1.0 - d / radius)
		var base := i * MAX_INFLUENCES
		var slot := -1
		for k in MAX_INFLUENCES:
			if bi[base + k] == bone_id:
				slot = k
		if slot == -1:
			# заменить самое слабое влияние
			slot = 0
			for k in MAX_INFLUENCES:
				if w[base + k] < w[base + slot]:
					slot = k
			bi[base + slot] = bone_id
			w[base + slot] = 0.0
		var cur := w[base + slot]
		var target := clampf(cur + amount * (1.0 - cur) if amount >= 0.0 else cur + amount * cur, 0.0, 1.0)
		var others := 1.0 - cur
		var new_others := 1.0 - target
		for k in MAX_INFLUENCES:
			if k == slot:
				w[base + k] = target
			elif others > 0.00001:
				w[base + k] *= new_others / others
		_normalize(w, i)
	return {"bones": bi, "w": w}


## Вес одной кости в каждой вершине (для тепловой подсветки).
static func bone_weight_per_vertex(wd: Dictionary, bone_id: int, n: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(n)
	var bi: PackedInt32Array = wd["bones"]
	var w: PackedFloat32Array = wd["w"]
	for i in n:
		for k in MAX_INFLUENCES:
			if bi[i * MAX_INFLUENCES + k] == bone_id:
				out[i] += w[i * MAX_INFLUENCES + k]
	return out


## Linear blend skinning. world_rest_vertices -> вершины в координатах холста после позы.
static func skin(world_rest_vertices: PackedVector2Array, wd: Dictionary, skin_mats: Dictionary) -> PackedVector2Array:
	var n := world_rest_vertices.size()
	var out := PackedVector2Array()
	out.resize(n)
	var bi: PackedInt32Array = wd["bones"]
	var w: PackedFloat32Array = wd["w"]
	if bi.size() < n * MAX_INFLUENCES:
		return world_rest_vertices
	for i in n:
		var p := world_rest_vertices[i]
		var acc := Vector2.ZERO
		var total := 0.0
		for k in MAX_INFLUENCES:
			var wk := w[i * MAX_INFLUENCES + k]
			if wk <= 0.0:
				continue
			var m: Variant = skin_mats.get(bi[i * MAX_INFLUENCES + k])
			if m == null:
				continue
			acc += (m as Transform2D) * p * wk
			total += wk
		out[i] = acc / total if total > 0.0 else p
	return out


## Убрать кость из весов (вершины перераспределяются на оставшиеся влияния).
func drop_bone_from_weights(bone_id: int) -> void:
	for lid in weights:
		var wd: Dictionary = weights[lid]
		var bi: PackedInt32Array = wd["bones"]
		var w: PackedFloat32Array = wd["w"]
		for j in bi.size():
			if bi[j] == bone_id:
				bi[j] = 0
				w[j] = 0.0
		for i in bi.size() / MAX_INFLUENCES:
			_normalize(w, i)
		wd["bones"] = bi
		wd["w"] = w


func to_dict() -> Dictionary:
	var bs: Array = []
	for id in order():
		bs.append(get_bone(id).to_dict())
	var ws := {}
	for lid in weights:
		var wd: Dictionary = weights[lid]
		ws[str(lid)] = {"b": Array(wd["bones"]), "w": Array(wd["w"]).map(func(x: float) -> float: return snappedf(x, 0.0001))}
	var ps := {}
	for lid in pins:
		var arr: Array = []
		for p in pins[lid]:
			arr.append({"id": p["id"], "v": p["v"], "bone": p["bone"]})
		ps[str(lid)] = arr
	return {"bones": bs, "weights": ws, "pins": ps}


static func from_dict(d: Dictionary) -> RbRig:
	var r := RbRig.new()
	for bd in d.get("bones", []):
		var b := RbBone.from_dict(bd)
		r.bones[b.id] = b
	var ws: Dictionary = d.get("weights", {})
	for k in ws:
		var e: Dictionary = ws[k]
		r.weights[int(k)] = {"bones": PackedInt32Array(e.get("b", [])), "w": PackedFloat32Array(e.get("w", []))}
	var ps: Dictionary = d.get("pins", {})
	for k in ps:
		var arr: Array = []
		for p in ps[k]:
			arr.append({"id": int(p["id"]), "v": int(p["v"]), "bone": int(p.get("bone", 0)), "offset": Vector2.ZERO})
		r.pins[int(k)] = arr
	return r


func find_pin(pin_id: int) -> Dictionary:
	for lid in pins:
		for p in pins[lid]:
			if int(p["id"]) == pin_id:
				return p
	return {}