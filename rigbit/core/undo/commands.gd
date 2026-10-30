class_name RbCommands
extends RefCounted
## Набор команд фазы 0.


class AddLayer extends RbCommand:
	var layer_dict: Dictionary
	var image: Image
	var index: int

	func _init(layer: RbLayer, img: Image = null, at_index := -1) -> void:
		label = "Добавить слой"
		layer_dict = layer.to_dict()
		image = img
		index = at_index

	func do_it(doc: RbDocument) -> void:
		var l := RbLayer.from_dict(layer_dict)
		if image and l.image_id != "":
			doc.images[l.image_id] = image
		doc.insert_layer(l, index)

	func undo_it(doc: RbDocument) -> void:
		var l := doc.get_layer(int(layer_dict["id"]))
		if l and l.image_id != "":
			doc.images.erase(l.image_id)
		doc.detach_layer(int(layer_dict["id"]))

	func cost_bytes() -> int:
		return image.get_data_size() if image else 256


class RemoveLayer extends RbCommand:
	var layer_id: int
	var snapshot: Array = []  # слои поддерева (dict)
	var imgs: Dictionary = {}
	var index: int = -1

	func _init(id: int) -> void:
		label = "Удалить слой"
		layer_id = id

	func do_it(doc: RbDocument) -> void:
		snapshot.clear()
		imgs.clear()
		_snap(doc, layer_id)
		index = doc.detach_layer(layer_id)
		for k in imgs:
			doc.images.erase(k)

	func _snap(doc: RbDocument, id: int) -> void:
		var l := doc.get_layer(id)
		if l == null:
			return
		snapshot.append(l.to_dict())
		if l.image_id != "" and doc.images.has(l.image_id):
			imgs[l.image_id] = doc.images[l.image_id]
		for c in l.children:
			_snap(doc, c)

	func undo_it(doc: RbDocument) -> void:
		for k in imgs:
			doc.images[k] = imgs[k]
		var first := true
		for d in snapshot:
			var l := RbLayer.from_dict(d)
			if first:
				doc.insert_layer(l, index)
				first = false
			else:
				doc.layers[l.id] = l  # дети уже перечислены в children родителя
		doc.notify(&"layers")


class MoveLayer extends RbCommand:
	var layer_id: int
	var new_parent: int
	var new_index: int
	var old_parent: int
	var old_index: int

	func _init(id: int, parent: int, index: int) -> void:
		label = "Порядок слоёв"
		layer_id = id
		new_parent = parent
		new_index = index

	func do_it(doc: RbDocument) -> void:
		var r := doc.move_layer(layer_id, new_parent, new_index)
		old_parent = r[0]
		old_index = r[1]

	func undo_it(doc: RbDocument) -> void:
		doc.move_layer(layer_id, old_parent, old_index)


## Сгруппировать слой: новая группа на его месте, слой внутрь.
class GroupLayer extends RbCommand:
	var layer_id: int
	var group_dict: Dictionary

	func _init(doc: RbDocument, id: int, group_name: String) -> void:
		label = "Группа"
		layer_id = id
		var l := doc.get_layer(id)
		var g := RbLayer.new()
		g.id = doc.new_id()
		g.name = group_name
		g.kind = RbLayer.Kind.GROUP
		g.parent_id = l.parent_id
		group_dict = g.to_dict()
		group_dict["index"] = doc.sibling_list(l.parent_id).find(id)

	func do_it(doc: RbDocument) -> void:
		var g := RbLayer.from_dict(group_dict)
		doc.insert_layer(g, int(group_dict["index"]))
		doc.move_layer(layer_id, g.id, 0)

	func undo_it(doc: RbDocument) -> void:
		var gid := int(group_dict["id"])
		doc.move_layer(layer_id, int(group_dict["parent"]), int(group_dict["index"]) + 1)
		doc.detach_layer(gid)


## Изменение свойства слоя. Шаги одного перетаскивания склеиваются.
class SetLayerProp extends RbCommand:
	var layer_id: int
	var prop: StringName
	var old_value: Variant
	var new_value: Variant

	func _init(id: int, p: StringName, old_v: Variant, new_v: Variant) -> void:
		label = "Изменить слой"
		layer_id = id
		prop = p
		old_value = old_v
		new_value = new_v

	func do_it(doc: RbDocument) -> void:
		_apply(doc, new_value)

	func undo_it(doc: RbDocument) -> void:
		_apply(doc, old_value)

	func _apply(doc: RbDocument, v: Variant) -> void:
		var l := doc.get_layer(layer_id)
		if l:
			l.set_prop(prop, v)
			doc.notify(&"transform")

	func merge(newer: RbCommand) -> bool:
		if newer is SetLayerProp and newer.layer_id == layer_id and newer.prop == prop:
			new_value = newer.new_value
			return true
		return false


## Замена сетки слоя целиком (генерация, правка точек). Снимок: v, uv, i, d (плотность).
## Живое перетаскивание точки применяет сетку само и кладёт команду с already_done.
class SetMesh extends RbCommand:
	var layer_id: int
	var old_state: Dictionary
	var new_state: Dictionary

	func _init(id: int, old_s: Dictionary, new_s: Dictionary) -> void:
		label = "Сетка"
		layer_id = id
		old_state = old_s
		new_state = new_s

	## Снимок сетки слоя (массивы копируются лениво, пока их не меняют).
	static func snap(l: RbLayer) -> Dictionary:
		return {"v": l.mesh_vertices, "uv": l.mesh_uvs, "i": l.mesh_indices, "d": l.mesh_density}

	## Положить снимок в слой. Живой предпросмотр зовёт это без команды.
	static func apply_state(l: RbLayer, s: Dictionary) -> void:
		l.mesh_vertices = s["v"]
		l.mesh_uvs = s["uv"]
		l.mesh_indices = s["i"]
		l.mesh_density = s["d"]

	var old_weights: Dictionary = {}
	var new_weights: Dictionary = {}

	var old_pin_v: Array = []  # индексы вершин пинов до замены сетки

	func do_it(doc: RbDocument) -> void:
		# пины перескакивают на ближайшую вершину новой сетки
		var pins: Array = doc.rig.pins.get(layer_id, [])
		if not pins.is_empty():
			old_pin_v.clear()
			var ov: PackedVector2Array = old_state["v"]
			var nv: PackedVector2Array = new_state["v"]
			for p in pins:
				old_pin_v.append(int(p["v"]))
				var pos: Vector2 = ov[int(p["v"])] if int(p["v"]) < ov.size() else Vector2.ZERO
				var best := 0
				for i in nv.size():
					if nv[i].distance_squared_to(pos) < nv[best].distance_squared_to(pos):
						best = i
				p["v"] = best
		# привязанный слой: веса переносятся со старой сетки на новую
		if doc.rig.weights.has(layer_id):
			if old_weights.is_empty():
				old_weights = doc.rig.weights[layer_id]
				new_weights = remap_weights(old_state, new_state, old_weights)
			doc.rig.weights[layer_id] = new_weights
		_apply(doc, new_state)

	func undo_it(doc: RbDocument) -> void:
		var pins: Array = doc.rig.pins.get(layer_id, [])
		for k in mini(pins.size(), old_pin_v.size()):
			pins[k]["v"] = old_pin_v[k]
		if not old_weights.is_empty():
			doc.rig.weights[layer_id] = old_weights
		_apply(doc, old_state)

	func _apply(doc: RbDocument, s: Dictionary) -> void:
		var l := doc.get_layer(layer_id)
		if l:
			apply_state(l, s)
			doc.notify(&"mesh")

	## Веса новых вершин = барицентрическая смесь весов треугольника старой сетки.
	static func remap_weights(old_s: Dictionary, new_s: Dictionary, wd: Dictionary) -> Dictionary:
		var n4 := RbRig.MAX_INFLUENCES
		var ov: PackedVector2Array = old_s["v"]
		var oi: PackedInt32Array = old_s["i"]
		var nv: PackedVector2Array = new_s["v"]
		var ob: PackedInt32Array = wd["bones"]
		var ow: PackedFloat32Array = wd["w"]
		var bi := PackedInt32Array()
		var w := PackedFloat32Array()
		bi.resize(nv.size() * n4)
		w.resize(nv.size() * n4)
		var old_mesh := {"vertices": ov, "indices": oi}
		for i in nv.size():
			var acc := {}
			var loc := RbMeshGen.locate(old_mesh, nv[i])
			var tri := int(loc.get("tri", -1))
			if tri < 0:
				continue
			var bary: Vector3 = loc["bary"]
			for c in 3:
				var vi := oi[tri * 3 + c]
				var bw: float = bary[c]
				for k in n4:
					var b := ob[vi * n4 + k]
					if b != 0 and ow[vi * n4 + k] > 0.0:
						acc[b] = acc.get(b, 0.0) + ow[vi * n4 + k] * maxf(bw, 0.0)
			var keys := acc.keys()
			keys.sort_custom(func(a: int, b: int) -> bool: return acc[a] > acc[b])
			var total := 0.0
			for k in mini(keys.size(), n4):
				total += acc[keys[k]]
			for k in mini(keys.size(), n4):
				bi[i * n4 + k] = keys[k]
				w[i * n4 + k] = acc[keys[k]] / total if total > 0.0 else 0.0
		return {"bones": bi, "w": w}

	func cost_bytes() -> int:
		return 256 + 2 * ((old_state["v"] as PackedVector2Array).size() + (new_state["v"] as PackedVector2Array).size()) * 16
