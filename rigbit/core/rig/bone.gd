class_name RbBone
extends RefCounted
## Кость. Rest-поза хранится относительно родителя (как в Moho): начало кости в системе
## координат родителя (ось X родителя = направление родителя), угол относительно родителя, длина.
## Поза (то, что анимируется) хранится отдельно как дельты к rest: поворот, сдвиг, масштаб.

var id: int = 0
var name: String = ""
var parent_id: int = 0  # 0 = корень

# rest
var position := Vector2.ZERO  # начало кости в пространстве родителя (у корневой: координаты холста)
var angle: float = 0.0  # относительно родителя
var length: float = 100.0
## Служебная кость (ключица гачи для флекси-биндинга тела): не рисуется и не ловится пальцем,
## но веса и иерархия работают как обычно.
var hidden := false

# поза (дельты к rest; в риге всё нулевое)
var pose_angle: float = 0.0
var pose_offset := Vector2.ZERO  # в пространстве родителя
var pose_scale := Vector2.ONE

## Констрейны (как в Moho), все необязательные:
##   limit: {min, max} — пределы pose_angle (рад) относительно rest
##   independent: true — не наследует поворот родителя
##   copy: {from: id, angle: k, move: k, scale: k} — взять движение другой кости с множителями
##   target: id — смотреть на начало другой кости
##   ik_ignore: true — IK-цепочка от дочерних костей на этой кости обрывается, сама она не гнётся
##   ik: {target: id} — постоянная IK: конец этой кости тянется к началу кости-цели, родитель гнётся вместе с ней
##   dynamics: {spring, damping, torque} — пружинистое запаздывание (кеш по кадрам)
var constraints: Dictionary = {}


func rest_local() -> Transform2D:
	return Transform2D(angle, position)


func pose_local() -> Transform2D:
	return Transform2D(angle + pose_angle, pose_scale, 0.0, position + pose_offset)


func has_pose() -> bool:
	return pose_angle != 0.0 or pose_offset != Vector2.ZERO or pose_scale != Vector2.ONE


func clear_pose() -> void:
	pose_angle = 0.0
	pose_offset = Vector2.ZERO
	pose_scale = Vector2.ONE


func get_prop(prop: StringName) -> Variant:
	return get(prop)


func set_prop(prop: StringName, value: Variant) -> void:
	set(prop, value)


func to_dict() -> Dictionary:
	var d := {
		"id": id, "name": name, "parent": parent_id,
		"position": [position.x, position.y], "angle": angle, "length": length,
		"constraints": constraints.duplicate(true),
	}
	if hidden:
		d["hidden"] = true
	return d


static func from_dict(d: Dictionary) -> RbBone:
	var b := RbBone.new()
	b.id = int(d.get("id", 0))
	b.name = str(d.get("name", ""))
	b.parent_id = int(d.get("parent", 0))
	var p: Array = d.get("position", [0, 0])
	b.position = Vector2(p[0], p[1])
	b.angle = float(d.get("angle", 0.0))
	b.length = float(d.get("length", 100.0))
	b.hidden = bool(d.get("hidden", false))
	b.constraints = (d.get("constraints", {}) as Dictionary).duplicate(true)
	return b
