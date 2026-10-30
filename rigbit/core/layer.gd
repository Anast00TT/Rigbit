class_name RbLayer
extends RefCounted
## Слой документа. Ядро, никакой зависимости от UI и рендера.
## У каждого растрового слоя всегда есть сетка (rest pose, локальные координаты слоя).
## У простого слоя это 4 угла.

enum Kind { IMAGE, GROUP, SWITCH }

const BLEND_MODES := ["normal", "add", "multiply", "screen", "overlay"]

var id: int = 0
var name: String = ""
var kind: Kind = Kind.IMAGE
var parent_id: int = 0  # 0 = корень документа
var children: Array[int] = []  # порядок отрисовки снизу вверх (только для групп)

var position := Vector2.ZERO
var rotation: float = 0.0
var scale := Vector2.ONE
var opacity: float = 1.0
var visible: bool = true
var blend_mode: String = "normal"
## Свитч-группа: индекс видимого ребёнка (рты, глаза, кисти). Анимируется ступенькой.
var switch_index: int = 0
## Порядок среди соседей поверх обычного: больше = выше (рука перед телом). Анимируется ступенькой.
var z: int = 0
## Маска-обрезка: слой виден только там, где непрозрачен слой mask_id в его текущей позе (0 = нет).
var mask_id: int = 0

var image_id: String = ""  # ключ в RbDocument.images
var size := Vector2.ZERO  # размер картинки в пикселях
## Сетка в локальных координатах слоя, центр картинки = (0,0).
var mesh_vertices := PackedVector2Array()
var mesh_uvs := PackedVector2Array()
var mesh_indices := PackedInt32Array()
## Плотность, с которой строилась сетка (0..1), чтобы ползунок показывал честное значение.
var mesh_density: float = 0.5
## Эффекты композинга (не больше ~5): rim {outside, angle (мировой), distance, blur, hardness, color, opacity, blend},
## grad {a, b, angle, amount, blend}, cc {hue, saturation, brightness, contrast}. Цвета строкой html.
var effects: Dictionary = {}


func local_transform() -> Transform2D:
	return Transform2D(rotation, scale, 0.0, position)


func is_group() -> bool:
	return kind == Kind.GROUP or kind == Kind.SWITCH


## Сетка из 4 углов по размеру картинки.
func make_quad_mesh() -> void:
	var h := size * 0.5
	mesh_vertices = PackedVector2Array([Vector2(-h.x, -h.y), Vector2(h.x, -h.y), Vector2(h.x, h.y), Vector2(-h.x, h.y)])
	mesh_uvs = PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)])
	mesh_indices = PackedInt32Array([0, 1, 2, 0, 2, 3])


func get_prop(prop: StringName) -> Variant:
	return get(prop)


func set_prop(prop: StringName, value: Variant) -> void:
	if prop == &"switch_index" or prop == &"z":
		value = roundi(float(value))  # из JSON и дорожек приходит float
	set(prop, value)


func to_dict() -> Dictionary:
	var d := {
		"id": id, "name": name, "kind": Kind.keys()[kind].to_lower(), "parent": parent_id,
		"position": [position.x, position.y], "rotation": rotation, "scale": [scale.x, scale.y],
		"opacity": opacity, "visible": visible, "blend": blend_mode,
		"fx": effects.duplicate(true),
	}
	if kind == Kind.SWITCH:
		d["switch"] = switch_index
	if z != 0:
		d["z"] = z
	if mask_id != 0:
		d["mask"] = mask_id
	if is_group():
		d["children"] = Array(children)
	else:
		d["image"] = image_id
		d["size"] = [size.x, size.y]
		d["mesh"] = {
			"v": _flat2(mesh_vertices), "uv": _flat2(mesh_uvs), "i": Array(mesh_indices),
			"d": snappedf(mesh_density, 0.0001),
		}
	return d


static func from_dict(d: Dictionary) -> RbLayer:
	var l := RbLayer.new()
	l.id = int(d.get("id", 0))
	l.name = str(d.get("name", ""))
	l.kind = Kind.get(str(d.get("kind", "image")).to_upper(), Kind.IMAGE)
	l.parent_id = int(d.get("parent", 0))
	var p: Array = d.get("position", [0, 0])
	l.position = Vector2(p[0], p[1])
	l.rotation = float(d.get("rotation", 0.0))
	var s: Array = d.get("scale", [1, 1])
	l.scale = Vector2(s[0], s[1])
	l.opacity = float(d.get("opacity", 1.0))
	l.visible = bool(d.get("visible", true))
	l.blend_mode = str(d.get("blend", "normal"))
	l.effects = (d.get("fx", {}) as Dictionary).duplicate(true)
	l.switch_index = int(d.get("switch", 0))
	l.z = int(d.get("z", 0))
	l.mask_id = int(d.get("mask", 0))
	if l.is_group():
		for c in d.get("children", []):
			l.children.append(int(c))
	else:
		l.image_id = str(d.get("image", ""))
		var sz: Array = d.get("size", [0, 0])
		l.size = Vector2(sz[0], sz[1])
		var m: Dictionary = d.get("mesh", {})
		l.mesh_vertices = _unflat2(m.get("v", []))
		l.mesh_uvs = _unflat2(m.get("uv", []))
		l.mesh_indices = PackedInt32Array(m.get("i", []))
		l.mesh_density = clampf(float(m.get("d", 0.5)), 0.0, 1.0)
		if l.mesh_vertices.is_empty():
			l.make_quad_mesh()
	return l


static func _flat2(a: PackedVector2Array) -> Array:
	var out: Array = []
	for v in a:
		out.append(snappedf(v.x, 0.001))
		out.append(snappedf(v.y, 0.001))
	return out


static func _unflat2(a: Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in range(0, a.size() - 1, 2):
		out.append(Vector2(a[i], a[i + 1]))
	return out
