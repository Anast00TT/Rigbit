class_name RbRigCommands
extends RefCounted
## Команды скелета и весов.


class AddBone extends RbCommand:
	var bone_dict: Dictionary

	func _init(b: RbBone) -> void:
		label = "Добавить кость"
		bone_dict = b.to_dict()

	func do_it(doc: RbDocument) -> void:
		var b := RbBone.from_dict(bone_dict)
		doc.rig.bones[b.id] = b
		doc.notify(&"bones")

	func undo_it(doc: RbDocument) -> void:
		doc.rig.bones.erase(int(bone_dict["id"]))
		doc.notify(&"bones")


## Удалить кость. Дети переходят к её родителю и остаются на своих местах.
## Влияние кости на вершины убирается.
class RemoveBone extends RbCommand:
	var bone_id: int
	var bone_dict: Dictionary
	var children_before: Array = []  # dict детей до переподвешивания
	var weights_before: Dictionary = {}

	func _init(id: int) -> void:
		label = "Удалить кость"
		bone_id = id

	func do_it(doc: RbDocument) -> void:
		var rig := doc.rig
		var b := rig.get_bone(bone_id)
		if b == null:
			return
		bone_dict = b.to_dict()
		children_before.clear()
		weights_before = {}
		for lid in rig.weights:
			var wd: Dictionary = rig.weights[lid]
			weights_before[lid] = {"bones": (wd["bones"] as PackedInt32Array).duplicate(), "w": (wd["w"] as PackedFloat32Array).duplicate()}
		var rest := rig.world_transforms(false)
		var parent_world: Transform2D = rest[b.parent_id] if b.parent_id != 0 else Transform2D.IDENTITY
		for cid in rig.children_of(bone_id):
			var c := rig.get_bone(cid)
			children_before.append(c.to_dict())
			var cw: Transform2D = rest[cid]
			var local := parent_world.affine_inverse() * cw
			c.parent_id = b.parent_id
			c.position = local.origin
			c.angle = local.get_rotation()
		rig.bones.erase(bone_id)
		rig.drop_bone_from_weights(bone_id)
		doc.notify(&"bones")

	func undo_it(doc: RbDocument) -> void:
		var rig := doc.rig
		rig.bones[bone_id] = RbBone.from_dict(bone_dict)
		for cd in children_before:
			var c := RbBone.from_dict(cd)
			var cur := rig.get_bone(c.id)
			if cur:
				cur.parent_id = c.parent_id
				cur.position = c.position
				cur.angle = c.angle
		for lid in weights_before:
			rig.weights[lid] = weights_before[lid]
		doc.notify(&"bones")


## Свойство кости (rest или поза). Шаги одного жеста склеиваются.
class SetBoneProp extends RbCommand:
	var bone_id: int
	var prop: StringName
	var old_value: Variant
	var new_value: Variant

	func _init(id: int, p: StringName, old_v: Variant, new_v: Variant) -> void:
		label = "Изменить кость"
		bone_id = id
		prop = p
		old_value = old_v
		new_value = new_v

	func do_it(doc: RbDocument) -> void:
		_apply(doc, new_value)

	func undo_it(doc: RbDocument) -> void:
		_apply(doc, old_value)

	func _apply(doc: RbDocument, v: Variant) -> void:
		var b := doc.rig.get_bone(bone_id)
		if b:
			b.set_prop(prop, v)
			doc.notify(&"bones")

	func merge(newer: RbCommand) -> bool:
		if newer is SetBoneProp and newer.bone_id == bone_id and newer.prop == prop:
			new_value = newer.new_value
			return true
		return false


## Сменить родителя кости, сохранив её положение на экране.
class ReparentBone extends RbCommand:
	var bone_id: int
	var new_parent: int
	var before: Dictionary

	func _init(id: int, parent: int) -> void:
		label = "Сменить родителя"
		bone_id = id
		new_parent = parent

	func do_it(doc: RbDocument) -> void:
		var rig := doc.rig
		var b := rig.get_bone(bone_id)
		if b == null or new_parent == bone_id or rig.is_descendant(new_parent, bone_id):
			return
		before = b.to_dict()
		var rest := rig.world_transforms(false)
		var pw: Transform2D = rest[new_parent] if new_parent != 0 else Transform2D.IDENTITY
		var local := pw.affine_inverse() * (rest[bone_id] as Transform2D)
		b.parent_id = new_parent
		b.position = local.origin
		b.angle = local.get_rotation()
		doc.notify(&"bones")

	func undo_it(doc: RbDocument) -> void:
		if before.is_empty():
			return
		var b := doc.rig.get_bone(bone_id)
		var o := RbBone.from_dict(before)
		b.parent_id = o.parent_id
		b.position = o.position
		b.angle = o.angle
		doc.notify(&"bones")


## Веса слоя целиком (привязка, автовеса, мазок кисти). Мазки одного жеста склеиваются.
class SetWeights extends RbCommand:
	var layer_id: int
	var old_wd: Dictionary  # пусто = весов не было
	var new_wd: Dictionary

	func _init(lid: int, old_w: Dictionary, new_w: Dictionary, lbl := "Веса") -> void:
		label = lbl
		layer_id = lid
		old_wd = old_w
		new_wd = new_w

	func do_it(doc: RbDocument) -> void:
		_apply(doc, new_wd)

	func undo_it(doc: RbDocument) -> void:
		_apply(doc, old_wd)

	func _apply(doc: RbDocument, wd: Dictionary) -> void:
		if wd.is_empty():
			doc.rig.weights.erase(layer_id)
		else:
			doc.rig.weights[layer_id] = wd
		doc.notify(&"weights")

	func merge(newer: RbCommand) -> bool:
		if newer is SetWeights and newer.layer_id == layer_id:
			new_wd = newer.new_wd
			return true
		return false

	func cost_bytes() -> int:
		return (new_wd.get("w", PackedFloat32Array()) as PackedFloat32Array).size() * 8 + 256

## Пины слоя целиком (добавить/удалить/перепривязать = замена списка). Смещения анимируются ключами.
class SetPins extends RbCommand:
	var layer_id: int
	var old_pins: Array
	var new_pins: Array

	func _init(lid: int, old_p: Array, new_p: Array, lbl := "Пины") -> void:
		label = lbl
		layer_id = lid
		old_pins = _copy(old_p)
		new_pins = _copy(new_p)

	static func _copy(a: Array) -> Array:
		var out: Array = []
		for p in a:
			out.append((p as Dictionary).duplicate())
		return out

	func do_it(doc: RbDocument) -> void:
		_apply(doc, new_pins)

	func undo_it(doc: RbDocument) -> void:
		_apply(doc, old_pins)

	func _apply(doc: RbDocument, pins: Array) -> void:
		if pins.is_empty():
			doc.rig.pins.erase(layer_id)
		else:
			doc.rig.pins[layer_id] = _copy(pins)
		doc.anim.apply_frame(doc, doc.shown_frame())
		doc.notify(&"pins")

	func merge(newer: RbCommand) -> bool:
		if newer is SetPins and newer.layer_id == layer_id:
			new_pins = newer.new_pins
			return true
		return false
