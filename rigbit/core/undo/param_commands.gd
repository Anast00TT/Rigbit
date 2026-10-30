class_name RbParamCommands
extends RefCounted
## Команды ползунков параметров: создание, удаление, свойства, ключевые формы, драйверы.
## Значение ползунка в режиме Анимация идёт ключом "param:<id>:value" (RbAnimCommands.SetKeyAuto).


class AddParam extends RbCommand:
	var param_dict: Dictionary

	func _init(p: RbParams.Param) -> void:
		label = "Добавить параметр"
		param_dict = p.to_dict()

	func do_it(doc: RbDocument) -> void:
		var p := RbParams.Param.from_dict(param_dict)
		doc.params.params[p.id] = p
		doc.notify(&"params")

	func undo_it(doc: RbDocument) -> void:
		doc.params.params.erase(int(param_dict["id"]))
		doc.notify(&"params")


## Удалить параметр вместе с его дорожкой значения и драйверами других параметров на него.
class RemoveParam extends RbCommand:
	var param_id: int
	var param_dict: Dictionary
	var index := 0
	var dropped_tracks := {}
	var dropped_drivers: Array = []  # [[source_id, driver_dict], ...]

	func _init(id: int) -> void:
		label = "Удалить параметр"
		param_id = id

	func do_it(doc: RbDocument) -> void:
		var p := doc.params.get_param(param_id)
		if p == null:
			return
		param_dict = p.to_dict()
		index = doc.params.params.keys().find(param_id)
		dropped_drivers.clear()
		for q: RbParams.Param in doc.params.params.values():
			var keep: Array = []
			for d in q.drivers:
				if int(d["target"]) == param_id:
					dropped_drivers.append([q.id, (d as Dictionary).duplicate(true)])
				else:
					keep.append(d)
			q.drivers = keep
		dropped_tracks = doc.anim.drop_object("param", param_id)
		doc.params.params.erase(param_id)
		doc.notify(&"params")

	func undo_it(doc: RbDocument) -> void:
		if param_dict.is_empty():
			return
		var restored := RbParams.Param.from_dict(param_dict)
		# порядок в списке возвращается на прежнее место
		var items: Array = doc.params.params.values()
		items.insert(clampi(index, 0, items.size()), restored)
		doc.params.params = {}
		for q: RbParams.Param in items:
			doc.params.params[q.id] = q
		for e in dropped_drivers:
			var src := doc.params.get_param(int(e[0]))
			if src:
				src.drivers.append((e[1] as Dictionary).duplicate(true))
		for k in dropped_tracks:
			doc.anim.tracks[k] = dropped_tracks[k]
		doc.anim.apply_frame(doc, doc.shown_frame())
		doc.notify(&"params")


## Имя, диапазон и значение по умолчанию: {name, min, max, default}.
class SetParamProps extends RbCommand:
	var param_id: int
	var old_props: Dictionary
	var new_props: Dictionary

	func _init(id: int, old_p: Dictionary, new_p: Dictionary) -> void:
		label = "Параметр"
		param_id = id
		old_props = old_p.duplicate()
		new_props = new_p.duplicate()

	static func snap(p: RbParams.Param) -> Dictionary:
		return {"name": p.name, "min": p.min_v, "max": p.max_v, "default": p.default_v}

	func do_it(doc: RbDocument) -> void:
		_apply(doc, new_props)

	func undo_it(doc: RbDocument) -> void:
		_apply(doc, old_props)

	func _apply(doc: RbDocument, s: Dictionary) -> void:
		var p := doc.params.get_param(param_id)
		if p == null:
			return
		p.name = str(s["name"])
		p.min_v = float(s["min"])
		p.max_v = float(s["max"])
		p.default_v = float(s["default"])
		p.value = clampf(p.value, p.min_v, p.max_v)
		doc.notify(&"params")


## Все ключевые формы параметра одним шагом (правка формы от входа до «Готово» = один шаг истории).
class SetParamForms extends RbCommand:
	var param_id: int
	var old_forms: Dictionary
	var new_forms: Dictionary

	func _init(id: int, old_f: Dictionary, new_f: Dictionary) -> void:
		label = "Ключевая форма"
		param_id = id
		old_forms = old_f.duplicate(true)
		new_forms = new_f.duplicate(true)

	func do_it(doc: RbDocument) -> void:
		_apply(doc, new_forms)

	func undo_it(doc: RbDocument) -> void:
		_apply(doc, old_forms)

	func _apply(doc: RbDocument, f: Dictionary) -> void:
		var p := doc.params.get_param(param_id)
		if p:
			p.forms = f.duplicate(true)
			doc.notify(&"params")

	func merge(newer: RbCommand) -> bool:
		if newer is SetParamForms and newer.param_id == param_id:
			new_forms = newer.new_forms
			return true
		return false

	func cost_bytes() -> int:
		var n := 256
		for pt in new_forms:
			for lid in (new_forms[pt] as Dictionary).get("verts", {}):
				n += ((new_forms[pt]["verts"][lid]) as PackedVector2Array).size() * 16
		return n * 2


## Драйверы параметра: [{target, k, b}, ...].
class SetParamDrivers extends RbCommand:
	var param_id: int
	var old_drivers: Array
	var new_drivers: Array

	func _init(id: int, old_d: Array, new_d: Array) -> void:
		label = "Драйвер"
		param_id = id
		old_drivers = old_d.duplicate(true)
		new_drivers = new_d.duplicate(true)

	func do_it(doc: RbDocument) -> void:
		_apply(doc, new_drivers)

	func undo_it(doc: RbDocument) -> void:
		_apply(doc, old_drivers)

	func _apply(doc: RbDocument, d: Array) -> void:
		var p := doc.params.get_param(param_id)
		if p:
			p.drivers = d.duplicate(true)
			doc.notify(&"params")
