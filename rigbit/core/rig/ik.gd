class_name RbIK
extends RefCounted
## Обратная кинематика. Возвращает новые pose_angle для костей цепочки.
## Двухкостная цепочка решается аналитически (теорема косинусов, сторона сгиба сохраняется),
## длиннее — FABRIK по точкам суставов.


## chain: id костей от корня цепочки к концу (каждая следующая — ребёнок предыдущей).
## posed_world: мировые трансформы костей в текущей позе (RbRig.world_transforms(true)).
## Результат: id -> новый pose_angle.
static func solve(rig: RbRig, chain: Array[int], posed_world: Dictionary, target: Vector2, iterations := 12) -> Dictionary:
	if chain.is_empty():
		return {}
	var pts: Array[Vector2] = []
	var lens: Array[float] = []
	for id in chain:
		var t: Transform2D = posed_world[id]
		pts.append(t.origin)
		var b := rig.get_bone(id)
		lens.append(b.length * t.get_scale().x)
	var last_t: Transform2D = posed_world[chain[chain.size() - 1]]
	pts.append(last_t * Vector2(rig.get_bone(chain[chain.size() - 1]).length, 0))
	var new_pts: Array[Vector2]
	if chain.size() == 2:
		new_pts = _two_bone(pts, lens, target)
	else:
		new_pts = _fabrik(pts, lens, target, iterations)
	# точки -> мировые углы -> pose_angle относительно родителя и rest
	var out := {}
	var parent_world_angle := 0.0
	var first := rig.get_bone(chain[0])
	if first.parent_id != 0 and posed_world.has(first.parent_id):
		parent_world_angle = (posed_world[first.parent_id] as Transform2D).get_rotation()
	for i in chain.size():
		var b := rig.get_bone(chain[i])
		var world_angle := (new_pts[i + 1] - new_pts[i]).angle()
		var local := wrapf(world_angle - parent_world_angle - b.angle, -PI, PI)
		out[b.id] = local
		parent_world_angle = world_angle
	return out


static func _two_bone(pts: Array[Vector2], lens: Array[float], target: Vector2) -> Array[Vector2]:
	var a := pts[0]
	var l1 := lens[0]
	var l2 := lens[1]
	var to_t := target - a
	var d := clampf(to_t.length(), absf(l1 - l2) + 0.001, l1 + l2 - 0.001)
	var base := to_t.angle()
	# сторона сгиба как сейчас (иначе локоть перещёлкивается)
	var cur := (pts[1] - pts[0]).cross(pts[2] - pts[1])
	var side := -1.0 if cur < 0.0 else 1.0
	var cos_a := clampf((l1 * l1 + d * d - l2 * l2) / (2.0 * l1 * d), -1.0, 1.0)
	var ang1 := base - side * acos(cos_a)
	var elbow := a + Vector2.from_angle(ang1) * l1
	var tip := elbow + (a + Vector2.from_angle(base) * d - elbow).normalized() * l2
	return [a, elbow, tip]


static func _fabrik(pts: Array[Vector2], lens: Array[float], target: Vector2, iterations: int) -> Array[Vector2]:
	var p: Array[Vector2] = pts.duplicate()
	var root: Vector2 = p[0]
	var total := 0.0
	for l in lens:
		total += l
	if root.distance_to(target) >= total:
		# не дотянуться: вытянуть цепочку в сторону цели
		var dir: Vector2 = (target - root).normalized()
		for i in lens.size():
			p[i + 1] = p[i] + dir * lens[i]
		return p
	for _it in iterations:
		p[p.size() - 1] = target
		for i in range(p.size() - 2, -1, -1):
			p[i] = p[i + 1] + (p[i] - p[i + 1]).normalized() * lens[i]
		p[0] = root
		for i in lens.size():
			p[i + 1] = p[i] + (p[i + 1] - p[i]).normalized() * lens[i]
		if p[p.size() - 1].distance_to(target) < 0.05:
			break
	return p


## Цепочка для перетаскивания кончика кости: кость и её предки, не длиннее max_len.
## Предок с констрейном ik_ignore цепочку обрывает (как ключица у гачи: рука гнётся без неё).
static func chain_for(rig: RbRig, bone_id: int, max_len := 2) -> Array[int]:
	var out: Array[int] = []
	var b := rig.get_bone(bone_id)
	while b and out.size() < max_len:
		if not out.is_empty() and b.constraints.get("ik_ignore", false):
			break
		out.push_front(b.id)
		b = rig.get_bone(b.parent_id)
	return out
