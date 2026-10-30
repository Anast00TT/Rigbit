class_name RbFormEdit
extends RefCounted
## Запись правок в ключевую форму параметра: дельты костей и вершин. Формат формы как в RbParams:
##   bones: id -> {angle: float, offset: Vector2, scale: Vector2 (добавка к 1)}
##   verts: layer_id -> PackedVector2Array (дельты вершин в rest-пространстве слоя)

const EPS := 0.0005


static func empty_form() -> Dictionary:
	return {"bones": {}, "verts": {}, "opacity": {}, "switch": {}}


## Копия формы со всеми четырьмя разделами (форма может быть пустым {} или неполной).
static func normalized(f: Dictionary) -> Dictionary:
	var out := empty_form()
	for k in out:
		if f.has(k):
			out[k] = (f[k] as Dictionary).duplicate(true)
	return out


## Ключ точки диапазона, уже занятой формой (с допуском), иначе value как есть.
static func point_key(p: RbParams.Param, value: float) -> float:
	for k in p.forms:
		if absf(float(k) - value) <= EPS:
			return float(k)
	return value


static func has_form(p: RbParams.Param, value: float) -> bool:
	for k in p.forms:
		if absf(float(k) - value) <= EPS:
			return true
	return false


## Дельта кости из формы: prop = "angle" | "offset" | "scale".
static func bone_prop(form: Dictionary, bone_id: int, prop: String) -> Variant:
	var d: Dictionary = (form.get("bones", {}) as Dictionary).get(bone_id, {})
	if prop == "angle":
		return float(d.get("angle", 0.0))
	return d.get(prop, Vector2.ZERO)


static func set_bone_prop(form: Dictionary, bone_id: int, prop: String, value: Variant) -> void:
	if not form.has("bones"):
		form["bones"] = {}
	var bones: Dictionary = form["bones"]
	var d: Dictionary = bones.get(bone_id, {"angle": 0.0, "offset": Vector2.ZERO, "scale": Vector2.ZERO})
	d[prop] = value
	bones[bone_id] = d


## Дельта вершины index слоя layer_id (нулевая, если формы для слоя нет).
static func vert_delta(form: Dictionary, layer_id: int, index: int) -> Vector2:
	var arr: PackedVector2Array = (form.get("verts", {}) as Dictionary).get(layer_id, PackedVector2Array())
	return arr[index] if index >= 0 and index < arr.size() else Vector2.ZERO


## Задать дельту вершины index; массив растёт до count вершин слоя.
static func set_vert_delta(form: Dictionary, layer_id: int, index: int, count: int, delta: Vector2) -> void:
	if not form.has("verts"):
		form["verts"] = {}
	var verts: Dictionary = form["verts"]
	var arr: PackedVector2Array = verts.get(layer_id, PackedVector2Array())
	if arr.size() < count:
		arr.resize(count)
	if index >= 0 and index < arr.size():
		arr[index] = delta
	verts[layer_id] = arr


## В форме нет ничего ненулевого.
static func is_empty(form: Dictionary) -> bool:
	for id in form.get("bones", {}):
		var d: Dictionary = form["bones"][id]
		if absf(float(d.get("angle", 0.0))) > EPS or (d.get("offset", Vector2.ZERO) as Vector2).length() > EPS \
				or (d.get("scale", Vector2.ZERO) as Vector2).length() > EPS:
			return false
	for lid in form.get("verts", {}):
		for v in (form["verts"][lid] as PackedVector2Array):
			if v.length() > EPS:
				return false
	return (form.get("opacity", {}) as Dictionary).is_empty() and (form.get("switch", {}) as Dictionary).is_empty()
