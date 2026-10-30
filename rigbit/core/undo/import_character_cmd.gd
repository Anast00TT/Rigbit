class_name RbImportCharacterCommand
extends RbCommand
## Импорт персонажа с готовым ригом (Gacha Life 2) одним шагом истории: слои с картинками и SVG,
## кости с констрейнами, веса. canvas: новый холст (пустой документ) или ZERO.

var add: RbAddLayersCommand
var bone_dicts: Array = []
var weights := {}


func _init(res: RbGl2Import.Result, canvas := Vector2i.ZERO) -> void:
	label = "Импорт персонажа"
	add = RbAddLayersCommand.new(res.layers, res.images, canvas, label, res.svgs)
	for b in res.bones:
		bone_dicts.append(b.to_dict())
	weights = res.weights.duplicate()


func do_it(doc: RbDocument) -> void:
	add.do_it(doc)
	for d: Dictionary in bone_dicts:
		var b := RbBone.from_dict(d)
		doc.rig.bones[b.id] = b
		doc.ensure_id(b.id)
	for lid in weights:
		doc.rig.weights[lid] = weights[lid]
	doc.notify(&"bones")
	doc.notify(&"layers")


func undo_it(doc: RbDocument) -> void:
	for lid in weights:
		doc.rig.weights.erase(lid)
	for d: Dictionary in bone_dicts:
		doc.rig.bones.erase(int(d["id"]))
	add.undo_it(doc)
	doc.notify(&"bones")
	doc.notify(&"layers")


func cost_bytes() -> int:
	return add.cost_bytes()
