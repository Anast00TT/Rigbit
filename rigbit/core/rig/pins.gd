class_name RbPins
extends RefCounted
## Помощники пинов (Puppet Warp). Пин = {id, v: индекс вершины, bone: 0 = свободный, offset: Vector2}.
## offset локальный (в осях слоя) и считается от базы: rest-вершина, сдвинутая костью привязки.


static func new_pin(id: int, vertex: int, bone := 0) -> Dictionary:
	return {"id": id, "v": vertex, "bone": bone, "offset": Vector2.ZERO}


## Ближайшая к точке вершина, -1 если вершин нет.
static func nearest_vertex(vertices: PackedVector2Array, p: Vector2) -> int:
	var best := -1
	var best_d := INF
	for i in vertices.size():
		var d := vertices[i].distance_squared_to(p)
		if d < best_d:
			best_d = d
			best = i
	return best


## Пин, сидящий на вершине, или {}.
static func at_vertex(pins: Array, vertex: int) -> Dictionary:
	for p in pins:
		if int(p["v"]) == vertex:
			return p
	return {}


## База пина в осях слоя: rest-вершина, перенесённая костью привязки (bone = 0 или нет кости: сама вершина).
## bones / bones_rest: мировые трансформы костей (поза и rest).
static func base_position(rest_vertex: Vector2, bone: int, layer_world: Transform2D, bones: Dictionary, bones_rest: Dictionary) -> Vector2:
	if bone == 0 or not bones.has(bone) or not bones_rest.has(bone):
		return rest_vertex
	var m: Transform2D = (bones[bone] as Transform2D) * (bones_rest[bone] as Transform2D).affine_inverse()
	return layer_world.affine_inverse() * (m * (layer_world * rest_vertex))


## Смещение, при котором пин окажется в target (оба в осях слоя).
static func offset_for(target: Vector2, base: Vector2) -> Vector2:
	return target - base


## Копия списка пинов с добавленным.
static func added(pins: Array, pin: Dictionary) -> Array:
	var out := _copy(pins)
	out.append(pin.duplicate())
	return out


## Копия списка пинов без пина id.
static func removed(pins: Array, id: int) -> Array:
	var out: Array = []
	for p in pins:
		if int(p["id"]) != id:
			out.append((p as Dictionary).duplicate())
	return out


## Копия списка пинов, где у пина id другая кость.
static func rebound(pins: Array, id: int, bone: int) -> Array:
	var out := _copy(pins)
	for p in out:
		if int(p["id"]) == id:
			p["bone"] = bone
	return out


static func _copy(pins: Array) -> Array:
	var out: Array = []
	for p in pins:
		out.append((p as Dictionary).duplicate())
	return out
