class_name RbParams
extends RefCounted
## Ползунки параметров (замена экшенов Moho). Параметр: имя, диапазон, значение по умолчанию.
## Ключевые формы в точках диапазона хранят дельты:
##   bones:    bone_id -> {angle: float, offset: Vector2, scale: Vector2 (добавка к 1)}
##   verts:    layer_id -> PackedVector2Array (дельты вершин сетки в rest-пространстве)
##   opacity:  layer_id -> float (добавка)
##   switch:   group_id -> индекс видимого ребёнка (ступенчато, берётся ближайшая форма)
## Несколько параметров действуют аддитивно. Драйверы: параметр управляет другими
## (target = k * source + b), циклы запрещены. Значение параметра анимируется дорожкой
## "param:<id>:value". Комбинационных ключей нет, но формат им не мешает (forms — словарь).

class Param:
	var id := 0
	var name := ""
	var min_v := 0.0
	var max_v := 1.0
	var default_v := 0.0
	var value := 0.0
	var forms := {}  # точка диапазона (float) -> {bones, verts, opacity, switch}
	var drivers: Array = []  # [{target: id, k: float, b: float}]
	var loop := false  # зацикленный клип (ходьба, моргание)

	func to_dict() -> Dictionary:
		var fs := {}
		for pt in forms:
			fs[str(pt)] = RbParams._enc_form(forms[pt])
		return {"id": id, "name": name, "min": min_v, "max": max_v, "default": default_v,
			"forms": fs, "drivers": drivers.duplicate(true), "loop": loop}

	static func from_dict(d: Dictionary) -> Param:
		var p := Param.new()
		p.id = int(d.get("id", 0))
		p.name = str(d.get("name", ""))
		p.min_v = float(d.get("min", 0.0))
		p.max_v = float(d.get("max", 1.0))
		p.default_v = float(d.get("default", 0.0))
		p.value = p.default_v
		var fs: Dictionary = d.get("forms", {})
		for k in fs:
			p.forms[float(k)] = RbParams._dec_form(fs[k])
		p.drivers = (d.get("drivers", []) as Array).duplicate(true)
		p.loop = bool(d.get("loop", false))
		return p


var params := {}  # id -> Param


func get_param(id: int) -> Param:
	return params.get(id)


## Можно ли добавить драйвер source -> target, не создав цикл.
func can_drive(source: int, target: int) -> bool:
	if source == target:
		return false
	# цикл, если от target по драйверам можно дойти до source
	var stack: Array[int] = [target]
	var seen := {}
	while not stack.is_empty():
		var cur: int = stack.pop_back()
		if cur == source:
			return false
		if seen.has(cur):
			continue
		seen[cur] = true
		var p := get_param(cur)
		if p:
			for d in p.drivers:
				stack.append(int(d["target"]))
	return true


## Шаг 2: драйверы в порядке топологической сортировки. Значения ведомых перезаписываются.
func resolve_drivers() -> void:
	var indeg := {}
	for id in params:
		indeg[id] = 0
	for p: Param in params.values():
		for d in p.drivers:
			if indeg.has(int(d["target"])):
				indeg[int(d["target"])] += 1
	var queue: Array = []
	for id in indeg:
		if indeg[id] == 0:
			queue.append(id)
	var driven := {}
	while not queue.is_empty():
		var id: int = queue.pop_front()
		var p := get_param(id)
		for d in p.drivers:
			var t := get_param(int(d["target"]))
			if t == null:
				continue
			var v := float(d.get("k", 1.0)) * p.value + float(d.get("b", 0.0))
			# несколько драйверов на один параметр складываются
			t.value = clampf((t.value if driven.has(t.id) else 0.0) + v, t.min_v, t.max_v)
			driven[t.id] = true
			indeg[t.id] -= 1
			if indeg[t.id] == 0:
				queue.append(t.id)


## Шаг 3: суммарные дельты всех параметров при текущих значениях.
## Возвращает {bones: {id: {angle, offset, scale}}, verts: {layer: PackedVector2Array}, opacity: {layer: f}, switch: {group: i}}
func blend() -> Dictionary:
	var out := {"bones": {}, "verts": {}, "opacity": {}, "switch": {}}
	for p: Param in params.values():
		if p.forms.is_empty():
			continue
		var forms: Dictionary = p.forms.duplicate()
		if not forms.has(p.default_v):
			forms[p.default_v] = {}  # в точке по умолчанию форма нулевая
		var pts: Array = forms.keys()
		pts.sort()
		var v := clampf(p.value, p.min_v, p.max_v)
		# интерполяция между соседними формами; за краями — по крайней форме
		var lo: float = pts[0]
		var hi: float = pts[pts.size() - 1]
		var t := 0.0
		for i in pts.size() - 1:
			if v >= float(pts[i]) and v <= float(pts[i + 1]):
				lo = pts[i]
				hi = pts[i + 1]
				t = (v - lo) / maxf(hi - lo, 0.000001)
				break
		if v <= float(pts[0]):
			lo = pts[0]
			hi = pts[0]
		elif v >= float(pts[pts.size() - 1]):
			lo = pts[pts.size() - 1]
			hi = lo
		# точка default без формы считается нулевой
		var fa: Dictionary = forms[lo]
		var fb: Dictionary = forms[hi]
		_add_mixed(out, fa, fb, t)
		var nearest: Dictionary = fa if t < 0.5 else fb
		for g in nearest.get("switch", {}):
			out["switch"][g] = nearest["switch"][g]
	return out


func _add_mixed(out: Dictionary, a: Dictionary, b: Dictionary, t: float) -> void:
	var ab: Dictionary = a.get("bones", {})
	var bb: Dictionary = b.get("bones", {})
	for id in _union(ab, bb):
		var da: Dictionary = ab.get(id, {})
		var db: Dictionary = bb.get(id, {})
		var cur: Dictionary = out["bones"].get(id, {"angle": 0.0, "offset": Vector2.ZERO, "scale": Vector2.ZERO})
		cur["angle"] += lerpf(float(da.get("angle", 0.0)), float(db.get("angle", 0.0)), t)
		cur["offset"] += (da.get("offset", Vector2.ZERO) as Vector2).lerp(db.get("offset", Vector2.ZERO), t)
		cur["scale"] += (da.get("scale", Vector2.ZERO) as Vector2).lerp(db.get("scale", Vector2.ZERO), t)
		out["bones"][id] = cur
	var av: Dictionary = a.get("verts", {})
	var bv: Dictionary = b.get("verts", {})
	for lid in _union(av, bv):
		var va: PackedVector2Array = av.get(lid, PackedVector2Array())
		var vb: PackedVector2Array = bv.get(lid, PackedVector2Array())
		var n := maxi(va.size(), vb.size())
		var cur: PackedVector2Array = out["verts"].get(lid, PackedVector2Array())
		if cur.size() < n:
			cur.resize(n)
		for i in n:
			var x: Vector2 = va[i] if i < va.size() else Vector2.ZERO
			var y: Vector2 = vb[i] if i < vb.size() else Vector2.ZERO
			cur[i] += x.lerp(y, t)
		out["verts"][lid] = cur
	var ao: Dictionary = a.get("opacity", {})
	var bo: Dictionary = b.get("opacity", {})
	for lid in _union(ao, bo):
		out["opacity"][lid] = float(out["opacity"].get(lid, 0.0)) + lerpf(float(ao.get(lid, 0.0)), float(bo.get(lid, 0.0)), t)


static func _union(a: Dictionary, b: Dictionary) -> Array:
	var s := {}
	for k in a:
		s[k] = true
	for k in b:
		s[k] = true
	return s.keys()


static func _enc_form(f: Dictionary) -> Dictionary:
	var out := {}
	var bones := {}
	for id in f.get("bones", {}):
		var d: Dictionary = f["bones"][id]
		var o: Vector2 = d.get("offset", Vector2.ZERO)
		var s: Vector2 = d.get("scale", Vector2.ZERO)
		bones[str(id)] = {"a": float(d.get("angle", 0.0)), "o": [o.x, o.y], "s": [s.x, s.y]}
	out["bones"] = bones
	var verts := {}
	for lid in f.get("verts", {}):
		var arr: Array = []
		for v in (f["verts"][lid] as PackedVector2Array):
			arr.append(snappedf(v.x, 0.001))
			arr.append(snappedf(v.y, 0.001))
		verts[str(lid)] = arr
	out["verts"] = verts
	var op := {}
	for lid in f.get("opacity", {}):
		op[str(lid)] = f["opacity"][lid]
	out["opacity"] = op
	var sw := {}
	for g in f.get("switch", {}):
		sw[str(g)] = f["switch"][g]
	out["switch"] = sw
	return out


static func _dec_form(d: Dictionary) -> Dictionary:
	var f := {"bones": {}, "verts": {}, "opacity": {}, "switch": {}}
	var bones: Dictionary = d.get("bones", {})
	for k in bones:
		var e: Dictionary = bones[k]
		var o: Array = e.get("o", [0, 0])
		var s: Array = e.get("s", [0, 0])
		f["bones"][int(k)] = {"angle": float(e.get("a", 0.0)), "offset": Vector2(o[0], o[1]), "scale": Vector2(s[0], s[1])}
	var verts: Dictionary = d.get("verts", {})
	for k in verts:
		var arr: Array = verts[k]
		var pv := PackedVector2Array()
		for i in range(0, arr.size() - 1, 2):
			pv.append(Vector2(arr[i], arr[i + 1]))
		f["verts"][int(k)] = pv
	for k in d.get("opacity", {}):
		f["opacity"][int(k)] = float(d["opacity"][k])
	for k in d.get("switch", {}):
		f["switch"][int(k)] = int(d["switch"][k])
	return f


func to_dict() -> Dictionary:
	var arr: Array = []
	for p: Param in params.values():
		arr.append(p.to_dict())
	return {"params": arr}


static func from_dict(d: Dictionary) -> RbParams:
	var r := RbParams.new()
	for pd in d.get("params", []):
		var p := Param.from_dict(pd)
		r.params[p.id] = p
	return r
